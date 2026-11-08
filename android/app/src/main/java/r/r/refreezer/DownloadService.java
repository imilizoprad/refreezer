package r.r.refreezer;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.RemoteException;
import android.util.Log;

import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.net.UnknownHostException;
import java.nio.channels.FileChannel;
import java.text.DecimalFormat;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

import javax.net.ssl.HttpsURLConnection;

import r.r.refreezer.models.Lyrics;
import r.r.refreezer.models.LyricsClassic;

/**
 * Download engine.
 *
 * Design notes (see DEVELOPMENT_STATUS.md for the user facing changelog):
 * - The queue, the database and all state transitions live on the main thread. Worker threads
 *   only do network/IO work and report back through {@link #postState} / {@link #postFailure},
 *   which removes the re-entrancy races the previous implementation had.
 * - Every job goes through: resolve -> download (resumable, validated) -> decrypt -> validate
 *   -> staging file -> atomic rename -> tags -> DONE. A job is only DONE when a non-empty,
 *   correctly sized file exists at its destination.
 * - Failures are classified so that auth, unavailable tracks, storage problems and transient
 *   network errors are handled differently; transient failures retry with bounded backoff.
 */
public class DownloadService extends Service {

    // --- Message commands (kept stable, new ones appended) ---
    static final int SERVICE_LOAD_DOWNLOADS = 1;
    static final int SERVICE_START_DOWNLOAD = 2;
    static final int SERVICE_ON_PROGRESS = 3;
    static final int SERVICE_SETTINGS_UPDATE = 4;
    static final int SERVICE_STOP_DOWNLOADS = 5;
    static final int SERVICE_ON_STATE_CHANGE = 6;
    static final int SERVICE_REMOVE_DOWNLOAD = 7;
    static final int SERVICE_RETRY_DOWNLOADS = 8;
    static final int SERVICE_REMOVE_DOWNLOADS = 9;
    /** Pause a single job: pause {"id"} */
    static final int SERVICE_PAUSE_DOWNLOAD = 10;
    /** Resume a single paused job: resume {"id"} */
    static final int SERVICE_RESUME_DOWNLOAD = 11;
    /** Cancel a single job (kept in history): cancel {"id"} */
    static final int SERVICE_CANCEL_DOWNLOAD = 12;
    /** Retry a single failed/cancelled job: retry {"id"} */
    static final int SERVICE_RETRY_DOWNLOAD = 13;
    /** Change priority: {"id", "priority"} 0 high, 1 normal, 2 low */
    static final int SERVICE_SET_PRIORITY = 14;
    /** Move a queued job: {"id", "beforeId"} (beforeId 0 = move to front) */
    static final int SERVICE_MOVE_DOWNLOAD = 15;

    static final String NOTIFICATION_CHANNEL_ID = "refreezerdownloads";
    static final String NOTIFICATION_CHANNEL_EVENTS_ID = "refreezerdownloads_events";
    static final int NOTIFICATION_ID_START = 6969;
    static final int NOTIFICATION_ID_SUMMARY = 6968;

    private static final String PREFS = "refreezer_downloads";
    private static final String PREF_RUNNING = "running";

    /** Anything smaller than this is not a playable track and must never count as complete. */
    private static final long MIN_VALID_AUDIO_BYTES = 16384;
    private static final long BACKOFF_BASE_MS = 3000;
    private static final long BACKOFF_MAX_MS = 5 * 60 * 1000;

    boolean running = false;
    DownloadSettings settings = DownloadSettings.defaults();
    /** Settings must arrive before anything is scheduled (arl is required to resolve streams). */
    boolean settingsReceived = false;
    /** True when the previous process left the queue running (restored on next start). */
    boolean restoreRunning = false;

    Context context;
    SQLiteDatabase db;
    Deezer deezer = new Deezer();

    Messenger serviceMessenger;
    Messenger activityMessenger;
    /** True while an Activity is bound; an idle, unbound service shuts itself down. */
    boolean bound = false;
    NotificationManagerCompat notificationManager;
    SharedPreferences prefs;

    final ArrayList<Download> downloads = new ArrayList<>();
    final Map<Integer, DownloadThread> threads = new LinkedHashMap<>();
    final Handler mainHandler = new Handler(Looper.getMainLooper());
    Handler progressUpdateHandler;
    DownloadLog logger = new DownloadLog();

    int completedThisSession = 0;

    public DownloadService() {
    }

    @Override
    public void onCreate() {
        super.onCreate();

        context = this;
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        restoreRunning = prefs.getBoolean(PREF_RUNNING, false);

        notificationManager = NotificationManagerCompat.from(context);
        createNotificationChannels();
        createProgressUpdateHandler();

        logger.open(context);
        deezer.init(logger, "");

        DownloadsDatabase dbHelper = new DownloadsDatabase(getApplicationContext());
        db = dbHelper.getWritableDatabase();

        // Recover queue state and clean orphaned temporary files.
        loadDownloads();
        purgeOrphanTemporaryFiles();
    }

    @Override
    public void onDestroy() {
        running = false;
        persistRunningFlag();
        for (DownloadThread thread : new ArrayList<>(threads.values())) {
            thread.requestPause();
        }
        threads.clear();
        if (progressUpdateHandler != null) progressUpdateHandler.removeCallbacksAndMessages(null);
        notificationManager.cancel(NOTIFICATION_ID_SUMMARY);
        notificationManager.cancelAll();
        logger.close();
        if (db != null && db.isOpen()) db.close();
        super.onDestroy();
    }

    @Override
    public boolean onUnbind(Intent intent) {
        bound = false;
        // The activity is gone: if nothing is queued or running, free the process.
        if (!running && threads.isEmpty() && !hasSchedulableWork()) {
            if (progressUpdateHandler != null) progressUpdateHandler.removeCallbacksAndMessages(null);
            stopSelf();
        }
        return super.onUnbind(intent);
    }

    @Override
    public IBinder onBind(Intent intent) {
        bound = true;
        serviceMessenger = new Messenger(new IncomingHandler(this));
        if (intent != null) activityMessenger = intent.getParcelableExtra("activityMessenger");
        return serviceMessenger.getBinder();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            activityMessenger = intent.getParcelableExtra("activityMessenger");
        }
        return START_STICKY;
    }

    private void createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nManager = getSystemService(NotificationManager.class);
            if (nManager == null) return;
            NotificationChannel progress = new NotificationChannel(NOTIFICATION_CHANNEL_ID,
                    "Download progress", NotificationManager.IMPORTANCE_MIN);
            progress.setShowBadge(false);
            nManager.createNotificationChannel(progress);

            NotificationChannel events = new NotificationChannel(NOTIFICATION_CHANNEL_EVENTS_ID,
                    "Download results", NotificationManager.IMPORTANCE_LOW);
            events.setShowBadge(true);
            nManager.createNotificationChannel(events);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Queue state
    // ---------------------------------------------------------------------------------------------

    private void persistRunningFlag() {
        try {
            prefs.edit().putBoolean(PREF_RUNNING, running).apply();
        } catch (Exception e) {
            Log.w("DOWN", "Could not persist running flag: " + e);
        }
    }

    /** Map a job that was interrupted by process death back onto a schedulable state. */
    private void recoverInterruptedState(Download download) {
        if (download.state.isBusy()) {
            download.state = Download.DownloadState.NONE;
            download.errorKind = "interrupted";
            download.errorMessage = "Download was interrupted and will resume.";
            // Keep the partial file: resume is validated against the server response.
        }
        if (download.state == Download.DownloadState.NONE && download.createdAt <= 0) {
            download.createdAt = System.currentTimeMillis();
        }
    }

    /** Load the queue from the database, recovering interrupted jobs and dropping duplicates. */
    void loadDownloads() {
        ArrayList<Download> loaded = new ArrayList<>();
        HashMap<String, Download> seen = new HashMap<>();

        Cursor cursor = null;
        try {
            cursor = db.query("Downloads", null, null,
                    null, null, null, "priority ASC, createdAt ASC, id ASC");
            while (cursor.moveToNext()) {
                Download d = Download.fromSQL(cursor);
                recoverInterruptedState(d);

                // Duplicate prevention: one job per (track, destination, quality, privacy).
                String key = d.dedupeKey();
                Download previous = seen.get(key);
                if (previous != null) {
                    if (previous.state.isFinished() && previous.state != Download.DownloadState.DONE) {
                        // Prefer the older job and cancel the newer duplicate.
                        d.state = Download.DownloadState.CANCELLED;
                        d.errorKind = "duplicate";
                        d.errorMessage = "Duplicate queue entry.";
                        persistState(d);
                    } else if (!previous.state.isFinished()) {
                        d.state = Download.DownloadState.CANCELLED;
                        d.errorKind = "duplicate";
                        d.errorMessage = "Duplicate queue entry.";
                        persistState(d);
                    }
                } else {
                    seen.put(key, d);
                }
                loaded.add(d);
            }
        } catch (Exception e) {
            logger.error("Unable to load downloads: " + e);
            e.printStackTrace();
        } finally {
            if (cursor != null) cursor.close();
        }

        downloads.clear();
        downloads.addAll(loaded);
        sortQueue();

        // If the previous process wanted to run, resume as soon as settings exist.
        if (restoreRunning && settingsReceived) {
            running = true;
        }
        updateState();
    }

    private void sortQueue() {
        downloads.sort((a, b) -> {
            int byPriority = Integer.compare(a.priority, b.priority);
            if (byPriority != 0) return byPriority;
            int byCreated = Long.compare(a.createdAt, b.createdAt);
            if (byCreated != 0) return byCreated;
            return Integer.compare(a.id, b.id);
        });
    }

    /** Pick the next schedulable job that is not waiting for its retry time. */
    private Download nextReadyDownload() {
        long now = System.currentTimeMillis();
        Download best = null;
        for (Download d : downloads) {
            if (!d.state.isSchedulable()) continue;
            if (threads.containsKey(d.id)) continue;
            if (d.nextRetryAt > now) continue;
            if (best == null) {
                best = d;
                continue;
            }
            int byPriority = Integer.compare(d.priority, best.priority);
            if (byPriority < 0) {
                best = d;
            } else if (byPriority == 0) {
                int byCreated = Long.compare(d.createdAt, best.createdAt);
                if (byCreated < 0 || (byCreated == 0 && d.id < best.id)) best = d;
            }
        }
        return best;
    }

    /** Start as many jobs as the concurrency limit allows. Main thread only. */
    private void schedule() {
        if (!running || !settingsReceived) return;
        if (settings.arl == null || settings.arl.isEmpty()) {
            // No credentials: keep the queue intact instead of failing every entry.
            return;
        }

        int limit = Math.max(1, Math.min(settings.downloadThreads, 8));
        // Never start work when the service is stopping.
        int guard = 0;
        while (threads.size() < limit && guard++ < 64) {
            Download next = nextReadyDownload();
            if (next == null) break;
            if (next.attempts > settings.maxRetries && next.attempts > 0) {
                // Defensive: a job that already used up its retries must not restart silently.
                next.state = Download.DownloadState.ERROR;
                next.errorKind = "network";
                next.errorMessage = "Retries exhausted.";
                persistState(next);
                continue;
            }
            next.state = Download.DownloadState.DOWNLOADING;
            next.received = 0;
            next.filesize = next.bytesTotal;
            persistState(next);

            DownloadThread thread = new DownloadThread(next);
            threads.put(next.id, thread);
            thread.start();
        }

        if (threads.isEmpty()) {
            boolean pending = false;
            for (Download d : downloads) {
                if (d.state == Download.DownloadState.NONE) {
                    pending = true;
                    break;
                }
            }
            if (!pending) running = false;
        }
    }

    /** Main entry point used after every state change. */
    private void updateQueue() {
        // Remove finished threads
        List<Integer> stale = new ArrayList<>();
        for (Map.Entry<Integer, DownloadThread> entry : threads.entrySet()) {
            if (!entry.getValue().isAlive()) stale.add(entry.getKey());
        }
        for (Integer id : stale) threads.remove(id);

        schedule();
        sortQueue();
        updateState();
        updateProgress();
        updateSummaryNotification();
    }

    private void updateState() {
        Bundle b = new Bundle();
        b.putBoolean("running", running);
        int queued = 0, active = 0, paused = 0, failed = 0, completed = 0, cancelled = 0;
        long totalBytes = 0, doneBytes = 0;
        for (Download d : downloads) {
            switch (d.state) {
                case NONE:
                    queued++;
                    break;
                case DOWNLOADING:
                case POST:
                    active++;
                    break;
                case PAUSED:
                    paused++;
                    break;
                case ERROR:
                case DEEZER_ERROR:
                    failed++;
                    break;
                case DONE:
                    completed++;
                    break;
                case CANCELLED:
                    cancelled++;
                    break;
            }
            totalBytes += Math.max(0, d.bytesTotal);
            if (d.state == Download.DownloadState.DONE) doneBytes += Math.max(0, d.bytesTotal);
        }
        b.putInt("queueSize", queued);
        b.putInt("active", active);
        b.putInt("paused", paused);
        b.putInt("failed", failed);
        b.putInt("completed", completed);
        b.putInt("cancelled", cancelled);
        b.putLong("totalBytes", totalBytes);
        b.putLong("doneBytes", doneBytes);
        b.putString("blockReason", (settings.arl == null || settings.arl.isEmpty()) ? "auth" : null);
        sendMessage(SERVICE_ON_STATE_CHANGE, b);
    }

    // ---------------------------------------------------------------------------------------------
    // Transitions (always on the main thread)
    // ---------------------------------------------------------------------------------------------

    private void onMain(Runnable runnable) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            runnable.run();
        } else {
            mainHandler.post(runnable);
        }
    }

    private void postState(final Download download, final Download.DownloadState state,
                           final String errorKind, final String errorMessage,
                           final String metadataWarning) {
        onMain(() -> applyState(download, state, errorKind, errorMessage, metadataWarning));
    }

    private void applyState(Download download, Download.DownloadState state, String errorKind,
                            String errorMessage, String metadataWarning) {
        Download current = findDownload(download.id);
        if (current == null) return; // removed while the worker was running

        current.state = state;
        current.errorKind = errorKind;
        current.errorMessage = errorMessage;
        current.metadataWarning = metadataWarning;
        if (state == Download.DownloadState.DONE) {
            current.errorKind = null;
            current.errorMessage = null;
            current.nextRetryAt = 0;
            current.received = current.filesize;
            if (current.bytesTotal <= 0) current.bytesTotal = current.filesize;
        }
        if (state != Download.DownloadState.NONE) {
            current.nextRetryAt = 0;
        }

        persistState(current);
        threads.remove(current.id);

        if (state == Download.DownloadState.DONE) {
            completedThisSession++;
        }
        if (state == Download.DownloadState.CANCELLED) {
            deleteTemporaryFiles(current);
        }
        if (state == Download.DownloadState.DONE && !current.priv) {
            try {
                Uri uri = Uri.fromFile(new File(current.destinationPath));
                sendBroadcast(new Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, uri));
            } catch (Exception ignored) {
            }
        }

        maybeNotifyResult(current, state);
        updateQueue();
    }

    /** Failure handling with classification, bounded exponential backoff and jitter. */
    private void postFailure(final Download download, final FailureKind kind, final String message,
                             final long retryAfterMs) {
        onMain(() -> {
            Download current = findDownload(download.id);
            if (current == null) return;

            current.errorKind = kind.code;
            current.errorMessage = message;
            threads.remove(current.id);

            boolean retryable = kind.retryable;
            if (retryable && current.attempts < settings.maxRetries) {
                current.attempts++;
                long delay = backoffMillis(current.attempts, retryAfterMs);
                current.nextRetryAt = System.currentTimeMillis() + delay;
                current.state = Download.DownloadState.NONE;
                logger.warn("Retry " + current.attempts + "/" + settings.maxRetries
                        + " for " + current.title + " in " + (delay / 1000) + "s (" + kind.code + ")");
            } else {
                current.state = kind == FailureKind.UNAVAILABLE
                        ? Download.DownloadState.DEEZER_ERROR
                        : Download.DownloadState.ERROR;
                current.nextRetryAt = 0;
                logger.error("Download failed (" + kind.code + "): " + message, current);
            }
            persistState(current);
            maybeNotifyResult(current, current.state);
            updateQueue();
        });
    }

    private static long backoffMillis(int attempt, long retryAfterMs) {
        if (retryAfterMs > 0) return Math.min(retryAfterMs, BACKOFF_MAX_MS);
        long exp = Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * (1L << Math.min(attempt - 1, 10)));
        double jitter = 0.8 + (ThreadLocalRandom.current().nextDouble() * 0.4); // 80% - 120%
        return Math.max(500, (long) (exp * jitter));
    }

    void persistState(Download download) {
        try {
            ContentValues values = download.stateToSQL();
            values.put("quality", download.quality);
            db.update("Downloads", values, "id == ?", new String[]{Integer.toString(download.id)});
        } catch (Exception e) {
            logger.error("Unable to persist download state: " + e, download);
            e.printStackTrace();
        }
    }

    private Download findDownload(int id) {
        for (Download d : downloads) {
            if (d.id == id) return d;
        }
        return null;
    }

    private void deleteTemporaryFiles(Download download) {
        deleteTemporaryFiles(download.id);
    }

    private void deleteTemporaryFiles(int downloadId) {
        try {
            File part = new File(getCacheDir(), downloadId + ".part");
            if (part.exists()) part.delete();
            File dec = new File(getCacheDir(), downloadId + ".part.DEC");
            if (dec.exists()) dec.delete();
            File legacy = new File(getCacheDir(), downloadId + ".ENC");
            if (legacy.exists()) legacy.delete();
            File legacyDec = new File(getCacheDir(), downloadId + ".ENC.DEC");
            if (legacyDec.exists()) legacyDec.delete();
        } catch (Exception ignored) {
        }
    }

    /** Remove temporary files that belong to no queue entry (e.g. after a crash or removal). */
    private void purgeOrphanTemporaryFiles() {
        try {
            File[] files = getCacheDir().listFiles();
            if (files == null) return;
            for (File file : files) {
                String name = file.getName();
                if (!(name.endsWith(".part") || name.endsWith(".part.DEC")
                        || name.endsWith(".ENC") || name.endsWith(".ENC.DEC"))) continue;
                String idPart = name.split("\\.")[0];
                int id;
                try {
                    id = Integer.parseInt(idPart);
                } catch (Exception e) {
                    continue;
                }
                boolean known = false;
                for (Download d : downloads) {
                    if (d.id == id && d.state != Download.DownloadState.CANCELLED) {
                        known = true;
                        break;
                    }
                }
                if (!known) file.delete();
            }
        } catch (Exception e) {
            logger.warn("Could not purge temporary files: " + e);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------------------------------

    private void startQueue() {
        if (downloads.isEmpty()) loadDownloads();
        running = true;
        settingsReceived = settingsReceived || !settings.arl.isEmpty();
        persistRunningFlag();
        // Give retries and paused jobs a chance to start immediately after an explicit start.
        for (Download d : downloads) {
            if (d.state == Download.DownloadState.PAUSED) {
                d.state = Download.DownloadState.NONE;
                d.nextRetryAt = 0;
                persistState(d);
            }
        }
        updateQueue();
    }

    /** "Stop" from the UI pauses the queue; nothing is cancelled or deleted. */
    private void pauseAll() {
        running = false;
        persistRunningFlag();
        for (DownloadThread thread : new ArrayList<>(threads.values())) {
            thread.requestPause();
        }
        updateState();
        updateSummaryNotification();
    }

    private void pauseDownload(int id) {
        Download d = findDownload(id);
        if (d == null) return;
        DownloadThread thread = threads.get(id);
        if (thread != null) {
            thread.requestPause();
            return; // the worker reports PAUSED itself
        }
        if (d.state == Download.DownloadState.NONE) {
            d.state = Download.DownloadState.PAUSED;
            d.nextRetryAt = 0;
            persistState(d);
            updateQueue();
        }
    }

    private void resumeDownload(int id) {
        Download d = findDownload(id);
        if (d == null) return;
        if (d.state == Download.DownloadState.PAUSED || d.state == Download.DownloadState.CANCELLED) {
            d.state = Download.DownloadState.NONE;
            d.nextRetryAt = 0;
            d.errorKind = null;
            d.errorMessage = null;
            persistState(d);
            if (!running) startQueue();
            else updateQueue();
        }
    }

    private void cancelDownload(int id, boolean deleteFile) {
        Download d = findDownload(id);
        if (d == null) return;
        DownloadThread thread = threads.get(id);
        if (thread != null) {
            thread.requestCancel();
            // Temporary files are deleted once the worker reports CANCELLED.
        } else {
            d.state = Download.DownloadState.CANCELLED;
            d.errorKind = "cancelled";
            d.errorMessage = "Cancelled by user.";
            d.nextRetryAt = 0;
            persistState(d);
            deleteTemporaryFiles(d);
            updateQueue();
        }
        if (deleteFile) deleteDestination(d);
    }

    /** Deletes the downloaded audio file (used only when the user explicitly asks for it). */
    private void deleteDestination(Download d) {
        try {
            if (d.destinationPath != null) {
                File f = new File(d.destinationPath);
                if (f.exists()) f.delete();
            }
        } catch (Exception e) {
            logger.warn("Could not delete file for " + d.id + ": " + e);
        }
    }

    private void retryDownload(int id) {
        Download d = findDownload(id);
        if (d == null) return;
        if (d.state.isBusy()) return;
        d.state = Download.DownloadState.NONE;
        d.attempts = 0;
        d.nextRetryAt = 0;
        d.errorKind = null;
        d.errorMessage = null;
        d.metadataWarning = null;
        persistState(d);
        running = true;
        persistRunningFlag();
        updateQueue();
    }

    private void setPriority(int id, int priority) {
        Download d = findDownload(id);
        if (d == null) return;
        d.priority = Math.max(Download.PRIORITY_HIGH, Math.min(Download.PRIORITY_LOW, priority));
        persistState(d);
        sortQueue();
        updateQueue();
    }

    private void moveDownload(int id, int beforeId) {
        Download d = findDownload(id);
        if (d == null) return;

        long newCreatedAt;
        Download before = findDownload(beforeId);
        if (before != null && before.id != d.id) {
            newCreatedAt = before.createdAt - 1;
        } else {
            long min = Long.MAX_VALUE;
            for (Download other : downloads) {
                if (other.id != d.id) min = Math.min(min, other.createdAt);
            }
            newCreatedAt = (min == Long.MAX_VALUE || min <= 0) ? System.currentTimeMillis() : min - 1000;
        }
        d.createdAt = newCreatedAt;
        try {
            ContentValues values = new ContentValues();
            values.put("createdAt", newCreatedAt);
            db.update("Downloads", values, "id == ?", new String[]{Integer.toString(id)});
        } catch (Exception e) {
            logger.warn("Could not persist queue order: " + e);
        }
        sortQueue();
        updateState();
    }

    // ---------------------------------------------------------------------------------------------
    // Progress loop, notifications
    // ---------------------------------------------------------------------------------------------

    private void createProgressUpdateHandler() {
        progressUpdateHandler = new Handler(Looper.getMainLooper());
        progressUpdateHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                tick();
                progressUpdateHandler.postDelayed(this, 500);
            }
        }, 500);
    }

    /** Periodic maintenance: start due retries, refresh progress and notifications. */
    private void tick() {
        try {
            if (running) {
                for (Download d : downloads) {
                    if (d.state == Download.DownloadState.NONE && d.nextRetryAt > 0
                            && d.nextRetryAt <= System.currentTimeMillis()) {
                        d.nextRetryAt = 0;
                        persistState(d);
                    }
                }
                if (threads.size() < Math.max(1, Math.min(settings.downloadThreads, 8))) {
                    schedule();
                }
            }
            updateProgress();
            updateSummaryNotification();

            // Retries scheduled but the queue is marked running: keep the flag honest.
            if (running && threads.isEmpty() && !hasSchedulableWork()) {
                running = false;
                persistRunningFlag();
                updateState();
                notifyQueueFinished();
            }

            // Idle and nothing bound to us: do not keep a 500 ms loop alive in the background.
            if (!running && !bound && threads.isEmpty() && !hasSchedulableWork()) {
                if (progressUpdateHandler != null) {
                    progressUpdateHandler.removeCallbacksAndMessages(null);
                }
                stopSelf();
            }
        } catch (Exception e) {
            Log.w("DOWN", "tick failed: " + e);
        }
    }

    private boolean hasSchedulableWork() {
        for (Download d : downloads) {
            if (d.state == Download.DownloadState.NONE) return true;
        }
        return false;
    }

    private void updateProgress() {
        if (threads.isEmpty()) return;
        Bundle b = new Bundle();
        ArrayList<Bundle> down = new ArrayList<>();
        for (DownloadThread thread : threads.values()) {
            down.add(createProgressBundle(thread.download));
        }
        b.putParcelableArrayList("downloads", down);
        sendMessage(SERVICE_ON_PROGRESS, b);
        updatePerDownloadNotifications();
    }

    private Bundle createProgressBundle(Download download) {
        Bundle bundle = new Bundle();
        bundle.putInt("id", download.id);
        bundle.putLong("received", download.received);
        bundle.putLong("filesize", download.filesize > 0 ? download.filesize : download.bytesTotal);
        bundle.putInt("quality", download.quality);
        bundle.putInt("state", download.state.getValue());
        bundle.putLong("speed", download.currentSpeed());
        return bundle;
    }

    private boolean notificationsAllowed() {
        return ActivityCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED;
    }

    private boolean wantsPerDownloadNotifications() {
        return "all".equals(settings.notifications);
    }

    /** One summary notification for the whole queue (never one per track by default). */
    private void updateSummaryNotification() {
        if (!notificationsAllowed()) return;
        int active = 0, queued = 0;
        long received = 0, total = 0;
        for (Download d : downloads) {
            if (d.state == Download.DownloadState.DOWNLOADING || d.state == Download.DownloadState.POST) {
                active++;
                received += d.received;
                total += d.filesize > 0 ? d.filesize : d.bytesTotal;
            } else if (d.state == Download.DownloadState.NONE) {
                queued++;
            }
        }
        if (active == 0 && queued == 0) {
            notificationManager.cancel(NOTIFICATION_ID_SUMMARY);
            return;
        }

        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_logo)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setOnlyAlertOnce(true)
                .setOngoing(running)
                .setSilent(true);

        if (active > 0) {
            builder.setContentTitle(active == 1 ? "Downloading 1 track" : "Downloading " + active + " tracks");
            String text = queued > 0 ? queued + " waiting" : "Finishing up";
            if (total > 0) {
                text += " · " + formatFilesize(received) + " / " + formatFilesize(total);
                builder.setProgress(100, (int) ((received / (float) total) * 100), false);
            } else {
                builder.setProgress(0, 0, true);
            }
            builder.setContentText(text);
        } else {
            builder.setContentTitle(queued + (queued == 1 ? " track queued" : " tracks queued"));
            builder.setContentText(running ? "Starting…" : "Paused");
            builder.setProgress(0, 0, false);
        }
        try {
            notificationManager.notify(NOTIFICATION_ID_SUMMARY, builder.build());
        } catch (SecurityException ignored) {
        }
    }

    /** Per-download progress notifications, opt-in only. */
    private void updatePerDownloadNotifications() {
        if (!notificationsAllowed() || !wantsPerDownloadNotifications()) return;
        for (DownloadThread thread : threads.values()) {
            Download download = thread.download;
            if (download.state == Download.DownloadState.NONE || download.state.isFinished()) {
                notificationManager.cancel(NOTIFICATION_ID_START + download.id);
                continue;
            }
            NotificationCompat.Builder builder = new NotificationCompat.Builder(context,
                    NOTIFICATION_CHANNEL_ID)
                    .setContentTitle(download.title == null ? "Downloading" : download.title)
                    .setSmallIcon(R.drawable.ic_logo)
                    .setPriority(NotificationCompat.PRIORITY_MIN)
                    .setOnlyAlertOnce(true)
                    .setSilent(true);

            if (download.state == Download.DownloadState.DOWNLOADING) {
                long size = download.filesize > 0 ? download.filesize : 1;
                builder.setContentText(String.format("%s / %s",
                        formatFilesize(download.received), formatFilesize(size)));
                builder.setProgress(100, (int) ((download.received / (float) size) * 100), false);
            } else {
                builder.setContentText("Finishing up…");
                builder.setProgress(0, 0, true);
            }
            notificationManager.notify(NOTIFICATION_ID_START + download.id, builder.build());
        }
    }

    private void maybeNotifyResult(Download download, Download.DownloadState state) {
        // Only the summary notification by default; individual results are opt-in.
        if (!notificationsAllowed()) return;
        if (!wantsPerDownloadNotifications()) return;
        if (state != Download.DownloadState.DONE && state != Download.DownloadState.ERROR
                && state != Download.DownloadState.DEEZER_ERROR) return;

        String title;
        String text;
        if (state == Download.DownloadState.DONE) {
            title = "Downloaded";
            text = download.title == null ? "" : download.title;
        } else {
            title = "Download failed";
            text = (download.title == null ? "" : download.title + " · ")
                    + humanReason(download.errorKind);
        }
        NotificationCompat.Builder builder = new NotificationCompat.Builder(context,
                NOTIFICATION_CHANNEL_EVENTS_ID)
                .setSmallIcon(R.drawable.ic_logo)
                .setContentTitle(title)
                .setContentText(text)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_LOW);
        try {
            notificationManager.notify((int) (System.currentTimeMillis() % 100000) + 1000, builder.build());
        } catch (SecurityException ignored) {
        }
    }

    private void notifyQueueFinished() {
        if (!notificationsAllowed()) return;
        if (completedThisSession <= 0) return;
        if ("none".equals(settings.notifications)) {
            completedThisSession = 0;
            return;
        }
        String text = completedThisSession == 1
                ? "1 track downloaded"
                : completedThisSession + " tracks downloaded";
        NotificationCompat.Builder builder = new NotificationCompat.Builder(context,
                NOTIFICATION_CHANNEL_EVENTS_ID)
                .setSmallIcon(R.drawable.ic_logo)
                .setContentTitle("Downloads finished")
                .setContentText(text)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_LOW);
        try {
            notificationManager.notify(NOTIFICATION_ID_SUMMARY + 1, builder.build());
        } catch (SecurityException ignored) {
        }
        completedThisSession = 0;
    }

    static String humanReason(String errorKind) {
        if (errorKind == null) return "Unknown error";
        switch (errorKind) {
            case "network":
                return "Network problem";
            case "timeout":
                return "Connection timed out";
            case "server":
                return "Server is busy";
            case "auth":
                return "Please sign in again";
            case "storage":
                return "Not enough space";
            case "permission":
                return "Storage permission missing";
            case "unavailable":
                return "Not available for download";
            case "processing":
                return "Could not process the file";
            case "metadata":
                return "Audio saved, tags failed";
            case "cancelled":
                return "Cancelled";
            case "interrupted":
                return "Interrupted";
            default:
                return "Download error";
        }
    }

    //https://stackoverflow.com/questions/3263892/format-file-size-as-mb-gb-etc
    public static String formatFilesize(long size) {
        if (size <= 0) return "0B";
        final String[] units = new String[]{"B", "KB", "MB", "GB", "TB"};
        @SuppressWarnings("ConstantConditions")
        int digitGroups = (int) (Math.log10(size) / Math.log10(1024));
        if (digitGroups >= units.length) digitGroups = units.length - 1;
        return new DecimalFormat("#,##0.##").format(size / Math.pow(1024, digitGroups)) + " " + units[digitGroups];
    }

    // ---------------------------------------------------------------------------------------------
    // Failure classification
    // ---------------------------------------------------------------------------------------------

    enum FailureKind {
        NETWORK("network", true),
        TIMEOUT("timeout", true),
        SERVER("server", true),
        AUTH("auth", false),
        STORAGE("storage", true),
        PERMISSION("permission", false),
        UNAVAILABLE("unavailable", false),
        PROCESSING("processing", true),
        UNKNOWN("unknown", true);

        final String code;
        final boolean retryable;

        FailureKind(String code, boolean retryable) {
            this.code = code;
            this.retryable = retryable;
        }
    }

    static FailureKind classifyHttp(int code) {
        if (code == 401 || code == 403) return FailureKind.AUTH;
        if (code == 404 || code == 410) return FailureKind.UNAVAILABLE;
        if (code == 408) return FailureKind.TIMEOUT;
        if (code == 429) return FailureKind.SERVER;
        if (code >= 500) return FailureKind.SERVER;
        if (code >= 400) return FailureKind.UNKNOWN;
        return FailureKind.UNKNOWN;
    }

    static FailureKind classifyException(Throwable t) {
        if (t instanceof SocketTimeoutException) return FailureKind.TIMEOUT;
        if (t instanceof UnknownHostException) return FailureKind.NETWORK;
        if (t instanceof ConnectException) return FailureKind.NETWORK;
        if (t instanceof IOException) {
            String message = t.getMessage() == null ? "" : t.getMessage().toLowerCase();
            if (message.contains("enospc") || message.contains("no space")) return FailureKind.STORAGE;
            if (message.contains("eacces") || message.contains("permission")) return FailureKind.PERMISSION;
            return FailureKind.NETWORK;
        }
        return FailureKind.UNKNOWN;
    }

    /** Abort a worker because the job was paused or cancelled. */
    static class DownloadAbort extends RuntimeException {
        DownloadAbort() {
            super("aborted");
        }
    }

    /** Stop a worker because its state was already reported (e.g. skipped, already downloaded). */
    static class SilentAbort extends RuntimeException {
        SilentAbort() {
            super("finished");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Worker
    // ---------------------------------------------------------------------------------------------

    class DownloadThread extends Thread {

        Download download;
        File parentDir;
        File outFile;
        JSONObject trackJson;
        JSONObject albumJson;
        JSONObject privateJson;
        Lyrics lyricsData = null;
        Deezer.QualityInfo qualityInfo;

        volatile boolean stopRequested = false;
        volatile boolean pauseRequested = false;
        /** Set when the row itself is being removed: the file is deleted after cancelling. */
        volatile boolean cancelAfterStop = false;
        /** Connection of the current transfer, disconnected on pause/cancel to abort quickly. */
        volatile HttpsURLConnection activeConnection;

        DownloadThread(Download download) {
            this.download = download;
            setName("download-" + download.id);
        }

        void requestPause() {
            pauseRequested = true;
            disconnectActive();
        }

        void requestCancel() {
            stopRequested = true;
            disconnectActive();
        }

        private void disconnectActive() {
            HttpsURLConnection connection = activeConnection;
            if (connection != null) {
                try {
                    connection.disconnect();
                } catch (Exception ignored) {
                }
            }
        }

        private boolean aborted() {
            return stopRequested || pauseRequested;
        }

        /** Report the abort reason and finish the worker. */
        private void finishAborted() {
            int id = download.id;
            Download d = findDownload(id);
            if (d == null) return;
            if (stopRequested) {
                if (cancelAfterStop) {
                    // Removing the entry while it was running: drop the row and its file.
                    postState(d, Download.DownloadState.CANCELLED, "cancelled", "Cancelled by user.", null);
                    onMain(() -> {
                        downloads.remove(d);
                        db.delete("Downloads", "id == ?", new String[]{Integer.toString(d.id)});
                        deleteDestination(d);
                        updateQueue();
                    });
                } else {
                    postState(d, Download.DownloadState.CANCELLED, "cancelled", "Cancelled by user.", null);
                }
            } else {
                postState(d, Download.DownloadState.PAUSED, null, null, null);
            }
        }

        @Override
        public void run() {
            download.attemptStartedAt = System.currentTimeMillis();
            download.attemptStartBytes = 0;
            download.received = 0;

            try {
                if (!ensureAuthorized()) return;
                resolveStream();
                resolveDestination();
                downloadToTemporaryFile();
                if (aborted()) {
                    finishAborted();
                    return;
                }
                String decrypted = decryptIfNeeded();
                validatePayload(decrypted);
                finalizeToDestination(decrypted);
                if (aborted()) {
                    finishAborted();
                    return;
                }
                String warning;
                try {
                    warning = postProcess();
                } catch (Throwable metadataError) {
                    logger.error("Post processing failed, audio kept: " + metadataError, download);
                    warning = "tags";
                }
                postState(download, Download.DownloadState.DONE, null, null, warning);
            } catch (DownloadAbort abort) {
                finishAborted();
            } catch (SilentAbort silent) {
                // State already reported by the worker; nothing else to do.
            } catch (Failure failure) {
                if (aborted()) {
                    finishAborted();
                } else {
                    postFailure(download, failure.kind, failure.getMessage(), failure.retryAfterMs);
                }
            } catch (Throwable t) {
                if (aborted()) {
                    finishAborted();
                } else {
                    logger.error("Unexpected download error: " + t, download);
                    t.printStackTrace();
                    postFailure(download, classifyException(t), String.valueOf(t), 0);
                }
            }
        }

        /** Thrown for classified, user-visible failures. */
        private class Failure extends Exception {
            final FailureKind kind;
            final long retryAfterMs;

            Failure(FailureKind kind, String message, long retryAfterMs) {
                super(message);
                this.kind = kind;
                this.retryAfterMs = retryAfterMs;
            }
        }

        private boolean ensureAuthorized() {
            if (settings.arl == null || settings.arl.isEmpty()) {
                postFailure(download, FailureKind.AUTH, "No Deezer ARL configured.", 0);
                return false;
            }
            if (!deezer.authorized && !deezer.authorizing) {
                deezer.authorize();
            }
            int waited = 0;
            while (deezer.authorizing && waited < 15000) {
                try {
                    Thread.sleep(50);
                    waited += 50;
                } catch (InterruptedException ignored) {
                }
            }
            if (!deezer.authorized) {
                postFailure(download, FailureKind.AUTH, "Deezer authentication failed. Please sign in again.", 0);
                return false;
            }
            return true;
        }

        private void resolveStream() throws Failure {
            // Metadata (public API) for filenames and tags
            if (!download.isUserUploaded()) {
                try {
                    trackJson = deezer.callPublicAPI("track", download.trackId);
                    if (trackJson == null) throw new IOException("Empty response from track API");
                    albumJson = deezer.callPublicAPI("album",
                            Integer.toString(trackJson.getJSONObject("album").getInt("id")));
                } catch (Exception e) {
                    if (aborted()) throw new DownloadAbort();
                    // Distinguish metadata failure from transfer failure: no bytes were wasted.
                    throw new Failure(classifyException(e), "Could not load track information: " + e, 0);
                }
            }

            qualityInfo = new Deezer.QualityInfo(download.quality, download.streamTrackId,
                    download.trackToken, download.md5origin, download.mediaVersion, logger);

            String sUrl;
            try {
                sUrl = qualityInfo.fallback(deezer);
            } catch (Exception e) {
                if (aborted()) throw new DownloadAbort();
                throw new Failure(classifyException(e), "Could not resolve stream URL: " + e, 0);
            }
            if (sUrl == null) {
                if (aborted()) throw new DownloadAbort();
                throw new Failure(FailureKind.UNAVAILABLE,
                        "This track is not available for download.", 0);
            }
            download.streamUrl = sUrl;
            download.encrypted = qualityInfo.encrypted;
            if (qualityInfo.quality > 0) download.quality = qualityInfo.quality;
            download.decryptTrackId = qualityInfo.trackId != null
                    ? qualityInfo.trackId : download.streamTrackId;
        }

        private void resolveDestination() throws Failure {
            try {
                if (download.priv) {
                    outFile = new File(download.path);
                } else if (download.isUserUploaded()) {
                    outFile = new File(Deezer.generateUserUploadedMP3Filename(download.path, download.title));
                } else {
                    outFile = new File(Deezer.generateFilename(download.path, trackJson, albumJson,
                            qualityInfo.quality));
                }
            } catch (Exception e) {
                throw new Failure(FailureKind.STORAGE, "Could not build the destination file name: " + e, 0);
            }
            if (outFile == null) throw new Failure(FailureKind.STORAGE, "Destination path is empty.", 0);
            parentDir = outFile.getParentFile();
            if (parentDir == null) throw new Failure(FailureKind.STORAGE, "Destination folder is invalid.", 0);
            download.destinationPath = outFile.getAbsolutePath();

            if (outFile.exists()) {
                long length = outFile.length();
                boolean plausible = length >= MIN_VALID_AUDIO_BYTES;
                if (!settings.overwriteDownload && plausible) {
                    // Already there: nothing to do, and never re-download over good audio.
                    download.filesize = length;
                    download.received = length;
                    postState(download, Download.DownloadState.DONE, null, null, null);
                    throw new SilentAbort();
                }
                // The existing (incomplete) file is intentionally kept until the replacement has
                // been fully downloaded, decrypted and validated: a failed retry must not destroy
                // whatever the user already has.
            }
        }

        private File temporaryFile() {
            File legacy = new File(getCacheDir(), download.id + ".ENC");
            File part = new File(getCacheDir(), download.id + ".part");
            if (!part.exists() && legacy.exists()) {
                // Migrate the temporary file name used by older versions.
                if (!legacy.renameTo(part) && legacy.exists()) return legacy;
            }
            return part;
        }

        private void downloadToTemporaryFile() throws Failure {
            File partFile = temporaryFile();
            long existing = partFile.exists() ? partFile.length() : 0;
            download.received = existing;
            download.attemptStartBytes = existing;

            HttpsURLConnection connection = null;
            try {
                boolean resume = existing > 0;
                for (int attempt = 0; attempt < 2; attempt++) {
                    connection = openConnection(download.streamUrl, resume ? existing : 0);
                    int code = connection.getResponseCode();
                    if (code == 416) {
                        // The server rejects our resume offset: start over.
                        connection.disconnect();
                        truncate(partFile);
                        existing = 0;
                        download.received = 0;
                        download.attemptStartBytes = 0;
                        resume = false;
                        continue;
                    }
                    if (code >= 400) {
                        long retryAfter = parseRetryAfter(connection.getHeaderField("Retry-After"));
                        connection.disconnect();
                        throw new Failure(classifyHttp(code), "Server returned HTTP " + code, retryAfter);
                    }
                    if (resume && code != 206) {
                        // The server ignored our Range request; appending would corrupt the file.
                        connection.disconnect();
                        truncate(partFile);
                        existing = 0;
                        download.received = 0;
                        download.attemptStartBytes = 0;
                        resume = false;
                        continue;
                    }
                    break;
                }
                if (connection == null) {
                    throw new Failure(FailureKind.NETWORK, "Could not open the download connection.", 0);
                }

                long contentLength = parseContentLength(connection);
                long total = (existing > 0 ? existing + contentLength : contentLength);
                if (contentLength < 0) total = 0;
                download.filesize = total > 0 ? total : download.filesize;
                if (total > 0) download.bytesTotal = total;
                download.received = existing;

                activeConnection = connection;
                InputStream inputStream = new BufferedInputStream(connection.getInputStream());
                OutputStream outputStream = new FileOutputStream(partFile.getPath(), existing > 0);
                byte[] buffer = new byte[16 * 1024];
                long written = existing;
                int read;
                try {
                    while ((read = inputStream.read(buffer)) != -1) {
                        outputStream.write(buffer, 0, read);
                        written += read;
                        download.received = written;
                        if (aborted()) {
                            outputStream.flush();
                            throw new DownloadAbort();
                        }
                    }
                    outputStream.flush();
                } finally {
                    try {
                        outputStream.close();
                    } catch (Exception ignored) {
                    }
                    try {
                        inputStream.close();
                    } catch (Exception ignored) {
                    }
                    connection.disconnect();
                    activeConnection = null;
                }

                long actual = partFile.length();
                if (actual < MIN_VALID_AUDIO_BYTES) {
                    partFile.delete();
                    throw new Failure(FailureKind.NETWORK,
                            "Transfer too short (" + actual + " bytes).", 0);
                }
                if (total > 0 && actual != total) {
                    // Incomplete transfer: keep the partial file so the next attempt resumes it.
                    throw new Failure(FailureKind.NETWORK,
                            "Incomplete transfer: " + actual + " of " + total + " bytes.", 0);
                }
                download.received = actual;
                download.filesize = actual;
                download.bytesTotal = actual;
            } catch (DownloadAbort abort) {
                throw abort;
            } catch (Failure failure) {
                throw failure;
            } catch (Exception e) {
                if (aborted()) throw new DownloadAbort();
                throw new Failure(classifyException(e), "Download error: " + e, 0);
            }
        }

        private HttpsURLConnection openConnection(String url, long offset) throws IOException {
            HttpsURLConnection connection = (HttpsURLConnection) new URL(url).openConnection();
            connection.setConnectTimeout(30000);
            connection.setReadTimeout(45000);
            connection.setInstanceFollowRedirects(true);
            connection.setRequestMethod("GET");
            connection.setRequestProperty("User-Agent",
                    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36");
            connection.setRequestProperty("Accept-Language", "*");
            connection.setRequestProperty("Accept", "*/*");
            if (offset > 0) connection.setRequestProperty("Range", "bytes=" + offset + "-");
            connection.connect();
            return connection;
        }

        private long parseContentLength(HttpsURLConnection connection) {
            try {
                String header = connection.getHeaderField("Content-Length");
                if (header == null) return -1;
                return Long.parseLong(header.trim());
            } catch (Exception e) {
                return -1;
            }
        }

        private long parseRetryAfter(String header) {
            if (header == null) return 0;
            try {
                // Retry-After may be seconds or an HTTP date; only the seconds form is used here.
                return Math.max(0, Long.parseLong(header.trim())) * 1000L;
            } catch (Exception e) {
                return 0;
            }
        }

        private void truncate(File file) {
            try {
                new FileOutputStream(file, false).close();
            } catch (Exception ignored) {
            }
        }

        /** Decrypt in place; returns the playable file. Encryption must never be skipped silently. */
        private String decryptIfNeeded() throws Failure {
            File partFile = temporaryFile();
            if (!download.encrypted) return partFile.getPath();

            File decFile = new File(partFile.getPath() + ".DEC");
            if (decFile.exists() && !decFile.delete()) {
                throw new Failure(FailureKind.STORAGE, "Could not clear a stale decrypted file.", 0);
            }
            try {
                DeezerDecryptor decryptor = new DeezerDecryptor(
                        download.decryptTrackId != null ? download.decryptTrackId : download.streamTrackId);
                decryptor.decryptFile(partFile.getPath(), decFile.getPath());
            } catch (Exception e) {
                // Keep the encrypted file: a retry can decrypt again without re-downloading.
                if (decFile.exists()) decFile.delete();
                throw new Failure(FailureKind.PROCESSING, "Decryption failed: " + e, 0);
            }
            if (!decFile.exists() || decFile.length() < MIN_VALID_AUDIO_BYTES) {
                if (decFile.exists()) decFile.delete();
                throw new Failure(FailureKind.PROCESSING, "Decryption produced an invalid file.", 0);
            }
            partFile.delete();
            download.received = decFile.length();
            download.filesize = decFile.length();
            return decFile.getPath();
        }

        private void validatePayload(String path) throws Failure {
            File file = new File(path);
            if (!file.exists() || file.length() < MIN_VALID_AUDIO_BYTES) {
                throw new Failure(FailureKind.PROCESSING, "Downloaded file is empty or truncated.", 0);
            }
        }

        /**
         * Write the finished audio into a staging file inside the destination folder and rename it
         * atomically, so a crash can never leave a half-written track at the destination path.
         */
        private void finalizeToDestination(String sourcePath) throws Failure {
            File source = new File(sourcePath);
            if (!parentDir.exists() && !parentDir.mkdirs() && !parentDir.exists()) {
                throw new Failure(FailureKind.STORAGE,
                        "Could not create the destination folder: " + parentDir.getPath(), 0);
            }
            File staging = new File(parentDir, outFile.getName() + ".rfs-partial");
            if (staging.exists() && !staging.delete()) {
                throw new Failure(FailureKind.STORAGE, "Could not clear a stale staging file.", 0);
            }
            try {
                moveOrCopy(source, staging);
            } catch (Exception e) {
                if (staging.exists()) staging.delete();
                throw new Failure(classifyException(e), "Could not write the file: " + e, 0);
            }

            if (staging.length() < MIN_VALID_AUDIO_BYTES) {
                staging.delete();
                throw new Failure(FailureKind.STORAGE, "File was truncated while writing.", 0);
            }

            // POSIX rename replaces the destination atomically. Only if the platform refuses do we
            // fall back to deleting the old file first, which is the only window where the old
            // audio is missing - and by then the new file is complete and validated.
            if (!staging.renameTo(outFile)) {
                try {
                    if (outFile.exists() && !outFile.delete()) {
                        throw new IOException("Could not replace the existing file");
                    }
                    if (!staging.renameTo(outFile)) {
                        moveOrCopy(staging, outFile);
                        staging.delete();
                    }
                } catch (Exception e) {
                    staging.delete();
                    if (outFile.exists() && outFile.length() < MIN_VALID_AUDIO_BYTES) outFile.delete();
                    throw new Failure(classifyException(e), "Could not finalise the file: " + e, 0);
                }
            }
            long length = outFile.length();
            if (length < MIN_VALID_AUDIO_BYTES) {
                outFile.delete();
                throw new Failure(FailureKind.STORAGE, "Final file was empty.", 0);
            }
            download.received = length;
            download.filesize = length;
            download.bytesTotal = length;
            // Temporary source removed only after a successful, validated move.
            if (!source.getAbsolutePath().equals(outFile.getAbsolutePath()) && source.exists()) {
                source.delete();
            }
        }

        private void moveOrCopy(File source, File target) throws IOException {
            if (source.renameTo(target)) return;
            FileInputStream inputStream = null;
            FileOutputStream outputStream = null;
            try {
                inputStream = new FileInputStream(source);
                outputStream = new FileOutputStream(target);
                FileChannel inputChannel = inputStream.getChannel();
                FileChannel outputChannel = outputStream.getChannel();
                long size = inputChannel.size();
                long transferred = 0;
                while (transferred < size) {
                    long step = inputChannel.transferTo(transferred, size - transferred, outputChannel);
                    if (step <= 0) break;
                    transferred += step;
                }
                outputStream.flush();
                outputStream.getFD().sync();
                if (target.length() != size) {
                    throw new IOException("Short write: " + target.length() + " of " + size);
                }
            } finally {
                try {
                    if (inputStream != null) inputStream.close();
                } catch (Exception ignored) {
                }
                try {
                    if (outputStream != null) outputStream.close();
                } catch (Exception ignored) {
                }
            }
        }

        /**
         * Cover, lyrics and tags. Failures here never invalidate the audio: the job is completed
         * with a warning so the user knows the file is playable but not fully tagged.
         */
        private String postProcess() {
            if (download.priv || download.isUserUploaded()) return null;

            String warning = null;
            File coverFile = new File(outFile.getPath().substring(0, outFile.getPath().lastIndexOf('.')) + ".jpg");

            try {
                downloadCover(trackJson, coverFile);
            } catch (Exception e) {
                logger.warn("Error downloading cover: " + e, download);
                warning = "cover";
            }

            if (settings.downloadLyrics || settings.tags.lyrics) {
                try {
                    lyricsData = deezer.getlyricsNew(download.trackId);
                    if (lyricsData == null || !lyricsData.isLoaded()) {
                        JSONObject privateRaw = deezer.callGWAPI("deezer.pageTrack",
                                "{\"sng_id\": \"" + download.trackId + "\"}");
                        privateJson = privateRaw.getJSONObject("results").getJSONObject("DATA");
                        if (privateRaw.getJSONObject("results").has("LYRICS")) {
                            lyricsData = new LyricsClassic(privateRaw.getJSONObject("results")
                                    .getJSONObject("LYRICS"));
                        }
                    }
                } catch (Exception e) {
                    logger.warn("Unable to fetch lyrics data: " + e, download);
                }
            }

            if (settings.downloadLyrics) {
                if (lyricsData == null || !lyricsData.isSynced()) {
                    logger.warn("No synced lyrics for track, skipping lyrics file", download);
                } else {
                    try {
                        String lrcData = Deezer.generateLRC(lyricsData, trackJson);
                        String lrcFilename = outFile.getPath().substring(0,
                                outFile.getPath().lastIndexOf(".") + 1) + "lrc";
                        FileOutputStream fileOutputStream = new FileOutputStream(lrcFilename);
                        fileOutputStream.write(lrcData.getBytes());
                        fileOutputStream.close();
                    } catch (Exception e) {
                        logger.warn("Error writing lyrics file: " + e, download);
                    }
                }
            }

            try {
                deezer.tagTrack(outFile.getPath(), trackJson, albumJson, coverFile.getPath(),
                        lyricsData, privateJson, settings);
            } catch (Exception e) {
                logger.error("Tagging failed, audio kept: " + e, download);
                warning = "tags";
            }

            if (!settings.trackCover) coverFile.delete();

            if (settings.albumCover) {
                try {
                    downloadAlbumCover(albumJson);
                } catch (Exception e) {
                    logger.warn("Error downloading album cover: " + e, download);
                    if (warning == null) warning = "albumArt";
                }
            }
            return warning;
        }

        /** Cover download with explicit timeouts and atomic replace. */
        private void downloadCover(JSONObject publicTrack, File coverFile) throws IOException {
            if (publicTrack == null || !publicTrack.has("md5_image")) return;
            File staging = new File(coverFile.getPath() + ".rfs-partial");
            HttpURLConnection connection = null;
            InputStream inputStream = null;
            OutputStream outputStream = null;
            try {
                URL url = new URL("https://e-cdn-images.deezer.com/images/cover/"
                        + publicTrack.getString("md5_image") + "/"
                        + settings.albumArtResolution + "x" + settings.albumArtResolution
                        + "-000000-80-0-0.jpg");
                connection = (HttpURLConnection) url.openConnection();
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(20000);
                connection.setRequestMethod("GET");
                connection.connect();
                if (connection.getResponseCode() >= 400) {
                    throw new IOException("HTTP " + connection.getResponseCode());
                }
                inputStream = connection.getInputStream();
                outputStream = new FileOutputStream(staging);
                byte[] buffer = new byte[8192];
                int read;
                while ((read = inputStream.read(buffer)) != -1) {
                    outputStream.write(buffer, 0, read);
                }
                outputStream.flush();
                outputStream.close();
                outputStream = null;
                if (staging.length() <= 0) throw new IOException("Empty cover");
                if (coverFile.exists()) coverFile.delete();
                if (!staging.renameTo(coverFile)) {
                    moveOrCopy(staging, coverFile);
                    staging.delete();
                }
            } catch (IOException e) {
                if (staging.exists()) staging.delete();
                throw e;
            } finally {
                try {
                    if (inputStream != null) inputStream.close();
                } catch (Exception ignored) {
                }
                try {
                    if (outputStream != null) outputStream.close();
                } catch (Exception ignored) {
                }
                if (connection != null) connection.disconnect();
            }
        }

        /** Each track has its own album art; this writes the shared cover.jpg once per album. */
        void downloadAlbumCover(JSONObject albumJson) {
            if (albumJson == null || !albumJson.has("md5_image")) return;
            File coverFile = new File(parentDir, "cover.jpg");
            if (coverFile.exists()) return;
            if (download.path == null || !download.path.matches(".*/.*%album%.*/.*")) return;

            File staging = new File(parentDir, "cover.jpg.rfs-partial");
            HttpURLConnection connection = null;
            InputStream inputStream = null;
            OutputStream outputStream = null;
            try {
                URL url = new URL("https://e-cdn-images.deezer.com/images/cover/"
                        + albumJson.getString("md5_image") + "/"
                        + settings.albumArtResolution + "x" + settings.albumArtResolution
                        + "-000000-80-0-0.jpg");
                connection = (HttpURLConnection) url.openConnection();
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(20000);
                connection.setRequestMethod("GET");
                connection.connect();
                if (connection.getResponseCode() >= 400) throw new IOException("HTTP " + connection.getResponseCode());
                inputStream = connection.getInputStream();
                outputStream = new FileOutputStream(staging);
                byte[] buffer = new byte[8192];
                int read;
                while ((read = inputStream.read(buffer)) != -1) {
                    outputStream.write(buffer, 0, read);
                }
                outputStream.flush();
                outputStream.close();
                outputStream = null;
                if (staging.length() <= 0) throw new IOException("Empty cover");
                if (!staging.renameTo(coverFile)) {
                    moveOrCopy(staging, coverFile);
                    staging.delete();
                }
                if (settings.nomediaFiles) {
                    File nomedia = new File(parentDir, ".nomedia");
                    if (!nomedia.exists()) nomedia.createNewFile();
                }
            } catch (Exception e) {
                if (staging.exists()) staging.delete();
                logger.warn("Error downloading album cover: " + e, download);
            } finally {
                try {
                    if (inputStream != null) inputStream.close();
                } catch (Exception ignored) {
                }
                try {
                    if (outputStream != null) outputStream.close();
                } catch (Exception ignored) {
                }
                if (connection != null) connection.disconnect();
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Messenger plumbing
    // ---------------------------------------------------------------------------------------------

    class IncomingHandler extends Handler {
        IncomingHandler(Context context) {
            super(Looper.getMainLooper());
        }

        @Override
        public void handleMessage(Message msg) {
            try {
                handle(msg);
            } catch (Exception e) {
                logger.error("Download command failed: " + e);
                e.printStackTrace();
            }
        }

        private void handle(Message msg) {
            switch (msg.what) {
                case SERVICE_LOAD_DOWNLOADS:
                    loadDownloads();
                    if (running) updateQueue();
                    break;

                case SERVICE_START_DOWNLOAD:
                    startQueue();
                    break;

                case SERVICE_SETTINGS_UPDATE:
                    settings = DownloadSettings.fromBundle(msg.getData());
                    deezer.arl = settings.arl;
                    deezer.contentLanguage = settings.deezerLanguage;
                    settingsReceived = true;
                    if (restoreRunning) {
                        restoreRunning = false;
                        running = true;
                        updateQueue();
                    }
                    break;

                case SERVICE_STOP_DOWNLOADS:
                    pauseAll();
                    break;

                case SERVICE_PAUSE_DOWNLOAD:
                    pauseDownload(msg.getData().getInt("id"));
                    break;

                case SERVICE_RESUME_DOWNLOAD:
                    resumeDownload(msg.getData().getInt("id"));
                    break;

                case SERVICE_CANCEL_DOWNLOAD:
                    cancelDownload(msg.getData().getInt("id"),
                            msg.getData().getBoolean("deleteFile", false));
                    break;

                case SERVICE_RETRY_DOWNLOAD:
                    retryDownload(msg.getData().getInt("id"));
                    break;

                case SERVICE_SET_PRIORITY:
                    setPriority(msg.getData().getInt("id"), msg.getData().getInt("priority"));
                    break;

                case SERVICE_MOVE_DOWNLOAD:
                    moveDownload(msg.getData().getInt("id"), msg.getData().getInt("beforeId", 0));
                    break;

                case SERVICE_REMOVE_DOWNLOAD: {
                    int downloadId = msg.getData().getInt("id");
                    boolean deleteFile = msg.getData().getBoolean("deleteFile", false);
                    Download d = findDownload(downloadId);
                    DownloadThread thread = threads.get(downloadId);
                    if (thread != null) {
                        // Never delete the row of a running job: cancel first.
                        if (deleteFile) thread.cancelAfterStop = true;
                        thread.requestCancel();
                        break;
                    }
                    downloads.remove(d);
                    deleteTemporaryFiles(downloadId);
                    db.delete("Downloads", "id == ?", new String[]{Integer.toString(downloadId)});
                    if (deleteFile && d != null) deleteDestination(d);
                    updateQueue();
                    break;
                }

                case SERVICE_RETRY_DOWNLOADS: {
                    int retried = 0;
                    for (Download d : downloads) {
                        if (d.state == Download.DownloadState.ERROR
                                || d.state == Download.DownloadState.DEEZER_ERROR
                                || d.state == Download.DownloadState.CANCELLED) {
                            d.state = Download.DownloadState.NONE;
                            d.attempts = 0;
                            d.nextRetryAt = 0;
                            d.errorKind = null;
                            d.errorMessage = null;
                            persistState(d);
                            retried++;
                        }
                    }
                    if (retried > 0) {
                        running = true;
                        persistRunningFlag();
                    }
                    updateQueue();
                    break;
                }

                case SERVICE_REMOVE_DOWNLOADS: {
                    Download.DownloadState state = Download.DownloadState.fromValue(
                            msg.getData().getInt("state"));
                    if (state == Download.DownloadState.DOWNLOADING || state == Download.DownloadState.POST) {
                        break;
                    }
                    // History cleanup: removes rows only, never the audio files.
                    for (int i = downloads.size() - 1; i >= 0; i--) {
                        Download d = downloads.get(i);
                        if (d.state == state) {
                            deleteTemporaryFiles(d);
                            downloads.remove(i);
                        }
                    }
                    db.delete("Downloads", "state == ?",
                            new String[]{Integer.toString(state.getValue())});
                    updateQueue();
                    break;
                }

                case SERVICE_ON_PROGRESS:
                case SERVICE_ON_STATE_CHANGE:
                    // Messages flowing back to the service are ignored.
                    break;

                default:
                    super.handleMessage(msg);
            }
        }
    }

    //Send message to MainActivity
    void sendMessage(int type, Bundle data) {
        if (activityMessenger == null) return;
        Message msg = Message.obtain(null, type);
        if (data != null) msg.setData(data);
        try {
            activityMessenger.send(msg);
        } catch (RemoteException e) {
            // Activity gone: keep the queue running, the service is still alive.
            Log.w("DOWN", "Could not reach the UI: " + e);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Settings
    // ---------------------------------------------------------------------------------------------

    static class DownloadSettings {

        int downloadThreads;
        boolean overwriteDownload;
        boolean downloadLyrics;
        boolean trackCover;
        String arl;
        boolean albumCover;
        boolean nomediaFiles;
        String artistSeparator;
        int albumArtResolution;
        String deezerLanguage = "en";
        String deezerCountry = "US";
        SelectedTags tags;
        /** Maximum automatic retries per job (0 disables retries). */
        int maxRetries = 4;
        /** "all" (per track), "summary" (queue only) or "none". */
        String notifications = "summary";

        private DownloadSettings(int downloadThreads, boolean overwriteDownload, boolean downloadLyrics,
                                 boolean trackCover, String arl, boolean albumCover, boolean nomediaFiles,
                                 String artistSeparator, int albumArtResolution, String deezerLanguage,
                                 String deezerCountry, SelectedTags tags) {
            this.downloadThreads = downloadThreads;
            this.overwriteDownload = overwriteDownload;
            this.downloadLyrics = downloadLyrics;
            this.trackCover = trackCover;
            this.arl = arl;
            this.albumCover = albumCover;
            this.nomediaFiles = nomediaFiles;
            this.artistSeparator = artistSeparator;
            this.albumArtResolution = albumArtResolution;
            this.deezerLanguage = deezerLanguage;
            this.deezerCountry = deezerCountry;
            this.tags = tags;
        }

        /** Safe defaults so the service never runs with a null settings object. */
        static DownloadSettings defaults() {
            return new DownloadSettings(2, false, false, true, "", true, true, ", ", 500,
                    "en", "US", new SelectedTags(new JSONArray()));
        }

        static DownloadSettings fromBundle(Bundle b) {
            DownloadSettings fallback = defaults();
            if (b == null) return fallback;
            try {
                JSONObject json = new JSONObject(b.getString("json"));
                DownloadSettings settings = new DownloadSettings(
                        json.optInt("downloadThreads", fallback.downloadThreads),
                        json.optBoolean("overwriteDownload", fallback.overwriteDownload),
                        json.optBoolean("downloadLyrics", fallback.downloadLyrics),
                        json.optBoolean("trackCover", fallback.trackCover),
                        json.optString("arl", ""),
                        json.optBoolean("albumCover", fallback.albumCover),
                        json.optBoolean("nomediaFiles", fallback.nomediaFiles),
                        json.optString("artistSeparator", fallback.artistSeparator),
                        json.optInt("albumArtResolution", fallback.albumArtResolution),
                        json.optString("deezerLanguage", fallback.deezerLanguage),
                        json.optString("deezerCountry", fallback.deezerCountry),
                        new SelectedTags(json.optJSONArray("tags") == null
                                ? new JSONArray() : json.optJSONArray("tags"))
                );
                settings.maxRetries = Math.max(0, Math.min(10, json.optInt("maxRetries", 4)));
                String notifications = json.optString("notifications", "summary");
                if (!"all".equals(notifications) && !"none".equals(notifications)
                        && !"summary".equals(notifications)) {
                    notifications = "summary";
                }
                settings.notifications = notifications;
                return settings;
            } catch (Exception e) {
                Log.e("ERR", "Error loading settings, using defaults: " + e);
                return fallback;
            }
        }
    }

    static class SelectedTags {
        boolean title = false;
        boolean album = false;
        boolean artist = false;
        boolean track = false;
        boolean disc = false;
        boolean albumArtist = false;
        boolean date = false;
        boolean label = false;
        boolean isrc = false;
        boolean upc = false;
        boolean trackTotal = false;
        boolean bpm = false;
        boolean lyrics = false;
        boolean genre = false;
        boolean contributors = false;
        boolean albumArt = false;

        SelectedTags(JSONArray json) {
            try {
                for (int i = 0; i < json.length(); i++) {
                    switch (json.getString(i)) {
                        case "title": title = true; break;
                        case "album": album = true; break;
                        case "artist": artist = true; break;
                        case "track": track = true; break;
                        case "disc": disc = true; break;
                        case "albumArtist": albumArtist = true; break;
                        case "date": date = true; break;
                        case "label": label = true; break;
                        case "isrc": isrc = true; break;
                        case "upc": upc = true; break;
                        case "trackTotal": trackTotal = true; break;
                        case "bpm": bpm = true; break;
                        case "lyrics": lyrics = true; break;
                        case "genre": genre = true; break;
                        case "contributors": contributors = true; break;
                        case "art": albumArt = true; break;
                    }
                }
            } catch (Exception e) {
                Log.e("ERR", "Error toggling tag: " + e);
            }
        }
    }
}

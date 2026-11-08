package r.r.refreezer;

import android.content.ContentValues;
import android.database.Cursor;

import java.util.HashMap;

/**
 * A single download job.
 *
 * The class is intentionally a plain data holder: the {@link DownloadService} owns queue logic,
 * scheduling and persistence. New fields are additive so that older rows (and older Flutter
 * builds) keep working; every SQL read goes through named columns with safe defaults.
 */
public class Download {

    // --- persisted columns (see DownloadsDatabase) ---
    int id;
    String path;
    boolean priv;
    int quality;
    String trackId;
    String streamTrackId;
    String trackToken;
    String md5origin;
    String mediaVersion;
    DownloadState state;
    String title;
    String image;

    // Scheduling / diagnostics (schema v2)
    int priority = PRIORITY_NORMAL;
    int attempts = 0;
    long nextRetryAt = 0;
    String errorKind;
    String errorMessage;
    long bytesTotal = 0;
    long createdAt = 0;
    String groupId;
    String metadataWarning;

    // --- runtime only (not persisted) ---
    volatile long received;
    volatile long filesize;
    /** Resolved stream URL for the current attempt. */
    String streamUrl;
    /** Whether the resolved stream is Blowfish encrypted (Deezer streams always are). */
    boolean encrypted = true;
    /** Track id used for the decryption key (may differ after a Deezer fallback). */
    String decryptTrackId;
    /** Absolute path of the finished file; also used by the media scanner. */
    String destinationPath;
    /** Epoch millis when the current attempt started; used for speed calculation. */
    long attemptStartedAt;
    /** Bytes already downloaded when the current attempt started (for speed). */
    long attemptStartBytes;

    public static final int PRIORITY_HIGH = 0;
    public static final int PRIORITY_NORMAL = 1;
    public static final int PRIORITY_LOW = 2;

    Download(int id, String path, boolean priv, int quality, DownloadState state, String trackId,
             String md5origin, String mediaVersion, String title, String image, String trackToken,
             String streamTrackId) {
        this.id = id;
        this.path = path;
        this.priv = priv;
        this.trackId = trackId;
        this.md5origin = md5origin;
        this.state = state;
        this.mediaVersion = mediaVersion;
        this.title = title;
        this.image = image;
        this.quality = quality;
        this.trackToken = trackToken;
        this.streamTrackId = streamTrackId;
        this.createdAt = System.currentTimeMillis();
    }

    enum DownloadState {
        /** Waiting in the queue (also used for "resume me"). */
        NONE(0),
        /** Transferring bytes. */
        DOWNLOADING(1),
        /** Transfer done, decrypting / tagging / finalising. */
        POST(2),
        /** Finished successfully. */
        DONE(3),
        /** The item itself cannot be downloaded (not available, wrong account tier, ...). */
        DEEZER_ERROR(4),
        /** Transfer or local IO failure. */
        ERROR(5),
        /** Explicitly paused by the user (kept, resumable). */
        PAUSED(6),
        /** Explicitly cancelled by the user (kept for history, resumable via retry). */
        CANCELLED(7);

        private final int value;

        DownloadState(int value) {
            this.value = value;
        }

        public int getValue() {
            return value;
        }

        static DownloadState fromValue(int value) {
            DownloadState[] all = DownloadState.values();
            if (value < 0 || value >= all.length) return NONE;
            return all[value];
        }

        /** States that the scheduler may pick up. */
        boolean isSchedulable() {
            return this == NONE;
        }

        /** States whose worker thread is still alive. */
        boolean isBusy() {
            return this == DOWNLOADING || this == POST;
        }

        /** States where no further automatic work happens. */
        boolean isFinished() {
            return this == DONE || this == ERROR || this == DEEZER_ERROR
                    || this == CANCELLED || this == PAUSED;
        }
    }

    /** Negative track ids are user-uploaded MP3s. */
    public boolean isUserUploaded() {
        return trackId != null && trackId.startsWith("-");
    }

    /** Stable identity used for duplicate prevention: the same audio into the same destination. */
    String dedupeKey() {
        return (trackId == null ? "" : trackId)
                + "|" + (path == null ? "" : path)
                + "|" + quality
                + "|" + (priv ? "1" : "0");
    }

    /** Column index helper that never throws for older/partial schemas. */
    private static int index(Cursor cursor, String column) {
        return cursor.getColumnIndex(column);
    }

    private static String getString(Cursor cursor, String column, String fallback) {
        int i = index(cursor, column);
        if (i < 0 || cursor.isNull(i)) return fallback;
        return cursor.getString(i);
    }

    private static long getLong(Cursor cursor, String column, long fallback) {
        int i = index(cursor, column);
        if (i < 0 || cursor.isNull(i)) return fallback;
        return cursor.getLong(i);
    }

    private static int getInt(Cursor cursor, String column, int fallback) {
        int i = index(cursor, column);
        if (i < 0 || cursor.isNull(i)) return fallback;
        return cursor.getInt(i);
    }

    /** Build a download from a SQL row. Works with both schema v1 and v2 rows. */
    static Download fromSQL(Cursor cursor) {
        Download d = new Download(
                getInt(cursor, "id", 0),
                getString(cursor, "path", null),
                getInt(cursor, "private", 0) == 1,
                getInt(cursor, "quality", 0),
                DownloadState.fromValue(getInt(cursor, "state", 0)),
                getString(cursor, "trackId", null),
                getString(cursor, "md5origin", null),
                getString(cursor, "mediaVersion", null),
                getString(cursor, "title", null),
                getString(cursor, "image", null),
                getString(cursor, "trackToken", null),
                getString(cursor, "streamTrackId", null)
        );
        d.priority = getInt(cursor, "priority", PRIORITY_NORMAL);
        d.attempts = getInt(cursor, "attempts", 0);
        d.nextRetryAt = getLong(cursor, "nextRetryAt", 0);
        d.errorKind = getString(cursor, "errorKind", null);
        d.errorMessage = getString(cursor, "errorMessage", null);
        d.bytesTotal = getLong(cursor, "bytesTotal", 0);
        d.createdAt = getLong(cursor, "createdAt", 0);
        d.groupId = getString(cursor, "groupId", null);
        d.metadataWarning = getString(cursor, "metadataWarning", null);
        d.filesize = d.bytesTotal;
        return d;
    }

    /** Convert a Flutter map (see lib/api/download.dart) into SQL values. */
    static ContentValues flutterToSQL(HashMap data) {
        ContentValues values = new ContentValues();
        values.put("path", (String) data.get("path"));
        values.put("private", (Boolean.TRUE.equals(data.get("private"))) ? 1 : 0);
        values.put("state", DownloadState.NONE.getValue());
        values.put("trackId", (String) data.get("trackId"));
        values.put("md5origin", (String) data.get("md5origin"));
        values.put("mediaVersion", (String) data.get("mediaVersion"));
        values.put("title", (String) data.get("title"));
        values.put("image", (String) data.get("image"));
        values.put("quality", data.get("quality") == null ? 0 : ((Number) data.get("quality")).intValue());
        values.put("trackToken", (String) data.get("trackToken"));
        values.put("streamTrackId", (String) data.get("streamTrackId"));
        // v2 columns (optional in the map)
        Object priority = data.get("priority");
        values.put("priority", priority == null ? PRIORITY_NORMAL : ((Number) priority).intValue());
        values.put("attempts", 0);
        values.put("nextRetryAt", 0L);
        Object groupId = data.get("groupId");
        values.put("groupId", groupId == null ? null : groupId.toString());
        Object expectedBytes = data.get("expectedBytes");
        values.put("bytesTotal", expectedBytes == null ? 0L : ((Number) expectedBytes).longValue());
        values.put("createdAt", System.currentTimeMillis());
        return values;
    }

    /** Persisted state as ContentValues. */
    ContentValues stateToSQL() {
        ContentValues values = new ContentValues();
        values.put("state", state.getValue());
        values.put("quality", quality);
        values.put("priority", priority);
        values.put("attempts", attempts);
        values.put("nextRetryAt", nextRetryAt);
        values.put("errorKind", errorKind);
        values.put("errorMessage", errorMessage);
        values.put("bytesTotal", bytesTotal);
        values.put("metadataWarning", metadataWarning);
        return values;
    }

    /** Send to Flutter. Keys are additive; the Dart model ignores unknown ones. */
    HashMap toHashMap() {
        HashMap map = new HashMap();
        map.put("id", id);
        map.put("path", path);
        map.put("private", priv);
        map.put("quality", quality);
        map.put("trackId", trackId);
        map.put("state", state.getValue());
        map.put("title", title);
        map.put("image", image);
        map.put("priority", priority);
        map.put("attempts", attempts);
        map.put("nextRetryAt", nextRetryAt);
        map.put("errorKind", errorKind);
        map.put("errorMessage", errorMessage);
        map.put("createdAt", createdAt);
        map.put("groupId", groupId);
        map.put("metadataWarning", metadataWarning);
        map.put("filesize", bytesTotal);
        map.put("received", 0);
        return map;
    }

    /** Bytes per second for the current attempt (0 when unknown). */
    long currentSpeed() {
        long elapsed = System.currentTimeMillis() - attemptStartedAt;
        if (elapsed <= 0) return 0;
        long bytes = received - attemptStartBytes;
        if (bytes <= 0) return 0;
        return Math.max(0, (bytes * 1000) / elapsed);
    }

    /** Copy of the runtime progress fields, for progress events. */
    HashMap progressToHashMap() {
        HashMap map = new HashMap();
        map.put("id", id);
        map.put("state", state.getValue());
        map.put("received", received);
        map.put("filesize", filesize > 0 ? filesize : bytesTotal);
        map.put("quality", quality);
        map.put("errorKind", errorKind);
        map.put("attempts", attempts);
        map.put("nextRetryAt", nextRetryAt);
        map.put("metadataWarning", metadataWarning);
        return map;
    }
}

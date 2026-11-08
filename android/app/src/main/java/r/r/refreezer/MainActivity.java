package r.r.refreezer;

import android.content.ComponentName;
import android.content.ContentValues;
import android.content.Intent;
import android.content.ServiceConnection;
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
import android.os.Parcelable;
import android.os.RemoteException;
import android.provider.Settings;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.ryanheise.audioservice.AudioServiceActivity;

import java.lang.ref.WeakReference;
import java.security.KeyManagementException;
import java.security.NoSuchAlgorithmException;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.HashMap;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends AudioServiceActivity {
    private static final String CHANNEL = "r.r.refreezer/native";
    private static final String EVENT_CHANNEL = "r.r.refreezer/downloads";
    EventChannel.EventSink eventSink;

    boolean serviceBound = false;
    Messenger serviceMessenger;
    Messenger activityMessenger;
    SQLiteDatabase db;
    StreamServer streamServer;

    //Data if started from intent
    String intentPreload;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        Intent intent = getIntent();
        intentPreload = intent.getStringExtra("preload");
        super.onCreate(savedInstanceState);
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        // Initialize ChangeIconPlugin
        ChangeIconPlugin changeIconPlugin = new ChangeIconPlugin(this);
        changeIconPlugin.initWith(flutterEngine.getDartExecutor().getBinaryMessenger());
        changeIconPlugin.tryFixLauncherIconIfNeeded();

        //Flutter method channel
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL).setMethodCallHandler(((call, result) -> {

            //Add downloads to DB, then refresh service.
            //Returns {added, existing, requeued} so the UI can report duplicates truthfully.
            if (call.method.equals("addDownloads")) {
                ArrayList<HashMap<?,?>> downloads = call.arguments();

                if (downloads != null) {
                    int added = 0, existing = 0, requeued = 0;
                    db.beginTransaction();
                    try {
                        for (int i = 0; i < downloads.size(); i++) {
                            HashMap<?,?> data = downloads.get(i);
                            String trackId = (String) data.get("trackId");
                            String path = (String) data.get("path");
                            int quality = data.get("quality") == null
                                    ? 0 : ((Number) data.get("quality")).intValue();

                            //Duplicate check on the full identity (track + destination + quality).
                            Cursor cursor = db.rawQuery(
                                    "SELECT id, state FROM Downloads WHERE trackId == ? AND path == ? AND quality == ?",
                                    new String[]{trackId, path, Integer.toString(quality)});
                            try {
                                if (cursor.moveToNext()) {
                                    int id = cursor.getInt(0);
                                    Download.DownloadState state =
                                            Download.DownloadState.fromValue(cursor.getInt(1));
                                    if (state == Download.DownloadState.ERROR
                                            || state == Download.DownloadState.DEEZER_ERROR
                                            || state == Download.DownloadState.CANCELLED) {
                                        //User asked again for something that failed: requeue it.
                                        ContentValues values = new ContentValues();
                                        values.put("state", Download.DownloadState.NONE.getValue());
                                        values.put("attempts", 0);
                                        values.put("nextRetryAt", 0);
                                        values.putNull("errorKind");
                                        values.putNull("errorMessage");
                                        values.putNull("metadataWarning");
                                        db.update("Downloads", values, "id == ?",
                                                new String[]{Integer.toString(id)});
                                        requeued++;
                                    } else {
                                        //Queued, downloading or done: never duplicate the job.
                                        existing++;
                                    }
                                    continue;
                                }
                            } finally {
                                cursor.close();
                            }

                            ContentValues row = Download.flutterToSQL(data);
                            db.insert("Downloads", null, row);
                            added++;
                        }
                        db.setTransactionSuccessful();
                    } catch (Exception e) {
                        Log.e("ERR", "Error adding downloads: " + e);
                    } finally {
                        db.endTransaction();
                    }
                    //Update service
                    sendMessage(DownloadService.SERVICE_LOAD_DOWNLOADS, null);

                    HashMap<String, Object> summary = new HashMap<>();
                    summary.put("added", added);
                    summary.put("existing", existing);
                    summary.put("requeued", requeued);
                    result.success(summary);
                    return;
                }
            }

            //Get all downloads from DB
            if (call.method.equals("getDownloads")) {
                Cursor cursor = db.query("Downloads", null, null, null, null, null, null);
                ArrayList<HashMap<?,?>> downloads = new ArrayList<>();
                //Parse downloads
                while (cursor.moveToNext()) {
                    Download download = Download.fromSQL(cursor);
                    downloads.add(download.toHashMap());
                }
                cursor.close();
                result.success(downloads);
                return;
            }
            //Update settings from UI
            if (call.method.equals("updateSettings")) {
                Bundle bundle = new Bundle();
                bundle.putString("json", call.argument("json").toString());
                sendMessage(DownloadService.SERVICE_SETTINGS_UPDATE, bundle);

                result.success(null);
                return;
            }
            //Load downloads from DB in service
            if (call.method.equals("loadDownloads")) {
                sendMessage(DownloadService.SERVICE_LOAD_DOWNLOADS, null);
                result.success(null);
                return;
            }
            //Start/Resume downloading
            if (call.method.equals("start")) {
                //Connected
                sendMessage(DownloadService.SERVICE_START_DOWNLOAD, null);
                result.success(serviceBound);
                return;
            }
            //Stop downloading
            if (call.method.equals("stop")) {
                sendMessage(DownloadService.SERVICE_STOP_DOWNLOADS, null);
                result.success(null);
                return;
            }
            //Remove download (deleteFile false keeps the audio file on disk)
            if (call.method.equals("removeDownload")) {
                Bundle bundle = new Bundle();
                bundle.putInt("id", (int)call.argument("id"));
                Boolean deleteFile = call.argument("deleteFile");
                bundle.putBoolean("deleteFile", deleteFile != null && deleteFile);
                sendMessage(DownloadService.SERVICE_REMOVE_DOWNLOAD, bundle);
                result.success(null);
                return;
            }
            //Pause a single download
            if (call.method.equals("pauseDownload")) {
                Bundle bundle = new Bundle();
                bundle.putInt("id", (int)call.argument("id"));
                sendMessage(DownloadService.SERVICE_PAUSE_DOWNLOAD, bundle);
                result.success(null);
                return;
            }
            //Resume a single download
            if (call.method.equals("resumeDownload")) {
                Bundle bundle = new Bundle();
                bundle.putInt("id", (int)call.argument("id"));
                sendMessage(DownloadService.SERVICE_RESUME_DOWNLOAD, bundle);
                result.success(null);
                return;
            }
            //Cancel a single download, keeping it in the history
            if (call.method.equals("cancelDownload")) {
                Bundle bundle = new Bundle();
                bundle.putInt("id", (int)call.argument("id"));
                Boolean deleteFile = call.argument("deleteFile");
                bundle.putBoolean("deleteFile", deleteFile != null && deleteFile);
                sendMessage(DownloadService.SERVICE_CANCEL_DOWNLOAD, bundle);
                result.success(null);
                return;
            }
            //Retry a single download
            if (call.method.equals("retryDownload")) {
                Bundle bundle = new Bundle();
                bundle.putInt("id", (int)call.argument("id"));
                sendMessage(DownloadService.SERVICE_RETRY_DOWNLOAD, bundle);
                result.success(null);
                return;
            }
            //Change the priority of a queued download (0 high, 1 normal, 2 low)
            if (call.method.equals("setDownloadPriority")) {
                Bundle bundle = new Bundle();
                bundle.putInt("id", (int)call.argument("id"));
                bundle.putInt("priority", (int)call.argument("priority"));
                sendMessage(DownloadService.SERVICE_SET_PRIORITY, bundle);
                result.success(null);
                return;
            }
            //Move a queued download before another one (beforeId 0 = move to front)
            if (call.method.equals("moveDownload")) {
                Bundle bundle = new Bundle();
                bundle.putInt("id", (int)call.argument("id"));
                Integer beforeId = call.argument("beforeId");
                bundle.putInt("beforeId", beforeId == null ? 0 : beforeId);
                sendMessage(DownloadService.SERVICE_MOVE_DOWNLOAD, bundle);
                result.success(null);
                return;
            }
            //Retry download
            if (call.method.equals("retryDownloads")) {
                sendMessage(DownloadService.SERVICE_RETRY_DOWNLOADS, null);
                result.success(null);
                return;
            }
            //Remove downloads by state (history cleanup: never deletes audio files)
            if (call.method.equals("removeDownloads")) {
                Bundle bundle = new Bundle();
                bundle.putInt("state", (int)call.argument("state"));
                sendMessage(DownloadService.SERVICE_REMOVE_DOWNLOADS, bundle);
                result.success(null);
                return;
            }
            //Pause the whole queue
            if (call.method.equals("pauseAll")) {
                sendMessage(DownloadService.SERVICE_STOP_DOWNLOADS, new Bundle());
                result.success(null);
                return;
            }
            //Resume the whole queue
            if (call.method.equals("resumeAll")) {
                sendMessage(DownloadService.SERVICE_START_DOWNLOAD, new Bundle());
                result.success(null);
                return;
            }
            //If app was started with preload info (Android Auto)
            if (call.method.equals("getPreloadInfo")) {
                result.success(intentPreload);
                intentPreload = null;
                return;
            }
            //Get architecture
            if (call.method.equals("arch")) {
                result.success(System.getProperty("os.arch"));
                return;
            }
            //Start streaming server
            if (call.method.equals("startServer")) {
                if (streamServer == null) {
                    //Get offline path
                    String offlinePath = getExternalFilesDir("offline").getAbsolutePath();
                    //Start server
                    streamServer = new StreamServer(call.argument("arl"), offlinePath);
                    streamServer.start();
                }
                result.success(null);
                return;
            }
            //Get quality info from stream
            if (call.method.equals("getStreamInfo")) {
                if (streamServer == null) {
                    result.success(null);
                    return;
                }
                StreamServer.StreamInfo info = streamServer.streams.get(call.argument("id").toString());
                if (info != null)
                    result.success(info.toJSON());
                else
                    result.success(null);
                return;
            }
            //Stop services
            if (call.method.equals("kill")) {
                Intent intent = new Intent(this, DownloadService.class);
                stopService(intent);
                if (streamServer != null) {
                    streamServer.stop();
                    streamServer = null;
                }
                //System.exit(0);
                result.success(null);
                return;
            }
            
            result.error("0", "Not implemented!", "Not implemented!");
        }));

        //Event channel (for download updates)
        EventChannel eventChannel = new EventChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), EVENT_CHANNEL);
        eventChannel.setStreamHandler((new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                eventSink = events;
            }

            @Override
            public void onCancel(Object arguments) {
                eventSink = null;
            }
        }));
    }

    //Start/Bind/Reconnect to download service
    private void connectService() {
        if (serviceBound)
            return;
        //Create messenger
        activityMessenger = new Messenger(new IncomingHandler(this));
        //Start
        Intent intent = new Intent(this, DownloadService.class);
        intent.putExtra("activityMessenger", activityMessenger);
        startService(intent);
        bindService(intent, connection, BIND_AUTO_CREATE);
    }

    @Override
    protected void onStart() {
        super.onStart();

        connectService();
        //Get DB (and leave open!)
        DownloadsDatabase dbHelper = new DownloadsDatabase(getApplicationContext());
        db = dbHelper.getWritableDatabase();

        //Trust all SSL Certs - Credits to Kilowatt36
        TrustManager[] trustAllCerts = new TrustManager[]{
                new X509TrustManager() {
                    public java.security.cert.X509Certificate[] getAcceptedIssuers() {
                        return null;
                    }
                    public void checkClientTrusted(X509Certificate[] certs, String authType) {
                    }
                    public void checkServerTrusted(X509Certificate[] certs, String authType) {
                    }
                }
        };
        SSLContext sc;
        try {
            sc = SSLContext.getInstance("SSL");
            sc.init(null, trustAllCerts, new java.security.SecureRandom());
            HttpsURLConnection.setDefaultSSLSocketFactory(sc.getSocketFactory());
        } catch (NoSuchAlgorithmException | KeyManagementException e) {
            Log.e(this.getLocalClassName(), e.getMessage());
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        //Try reconnect
        connectService();
    }

    @Override
    protected void onStop() {
        super.onStop();
        db.close();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        //Stop server
        if (streamServer != null)
            streamServer.stop();

        //Unbind service on exit
        if (serviceBound) {
            unbindService(connection);
            serviceBound = false;
        }
    }

    //Connection to download service
    private final ServiceConnection connection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName componentName, IBinder iBinder) {
            serviceMessenger = new Messenger(iBinder);
            serviceBound = true;
            Log.d("DD", "Service Bound!");
        }

        @Override
        public void onServiceDisconnected(ComponentName componentName) {
            serviceMessenger = null;
            serviceBound = false;
            Log.d("DD", "Service UnBound!");
        }
    };

    //Handler for incoming messages from service
    private static class IncomingHandler extends Handler {
        private final WeakReference<MainActivity> weakReference;
        IncomingHandler(MainActivity activity) {
            super(Looper.getMainLooper());
            this.weakReference = new WeakReference<>(activity);
        }

        @Override
        public void handleMessage(@NonNull Message msg) {
            MainActivity activity = weakReference.get();

            if (activity != null) {
                EventChannel.EventSink eventSink = activity.eventSink;
                switch (msg.what) {
                    //Forward to flutter.
                    case DownloadService.SERVICE_ON_PROGRESS:
                        if (eventSink == null) break;
                        ArrayList<Bundle> downloads = getParcelableArrayList(msg.getData(), "downloads", Bundle.class);
                        if (downloads != null && downloads.size() > 0) {
                            //Generate HashMap ArrayList for sending to flutter
                            ArrayList<HashMap<String, Number>> data = new ArrayList<>();
                            for (Bundle bundle : downloads) {
                                HashMap<String, Number> out = new HashMap<>();
                                out.put("id", bundle.getInt("id"));
                                out.put("state", bundle.getInt("state"));
                                out.put("received", bundle.getLong("received"));
                                out.put("filesize", bundle.getLong("filesize"));
                                out.put("quality", bundle.getInt("quality"));
                                out.put("speed", bundle.getLong("speed"));
                                data.add(out);
                            }
                            //Wrapper
                            HashMap<String, Object> out = new HashMap<>();
                            out.put("action", "onProgress");
                            out.put("data", data);
                            eventSink.success(out);
                        }

                        break;
                    //State change, forward to flutter
                    case DownloadService.SERVICE_ON_STATE_CHANGE:
                        if (eventSink == null) break;
                        Bundle b = msg.getData();
                        HashMap<String, Object> out = new HashMap<>();
                        out.put("running", b.getBoolean("running"));
                        out.put("queueSize", b.getInt("queueSize"));
                        out.put("active", b.getInt("active"));
                        out.put("paused", b.getInt("paused"));
                        out.put("failed", b.getInt("failed"));
                        out.put("completed", b.getInt("completed"));
                        out.put("cancelled", b.getInt("cancelled"));
                        out.put("totalBytes", b.getLong("totalBytes"));
                        out.put("doneBytes", b.getLong("doneBytes"));
                        out.put("blockReason", b.getString("blockReason"));

                        //Wrapper info
                        out.put("action", "onStateChange");

                        eventSink.success(out);
                        break;

                    default:
                        super.handleMessage(msg);
                }
            }
        }
    }

    //Send message to service
    void sendMessage(int type, Bundle data) {
        if (serviceBound && serviceMessenger != null) {
            Message msg = Message.obtain(null, type);
            msg.setData(data);
            try {
                serviceMessenger.send(msg);
            } catch (RemoteException e) {
                e.printStackTrace();
            }
        }
    }

    @Nullable
    public static <T extends Parcelable>  ArrayList<T> getParcelableArrayList(@Nullable Bundle bundle, @Nullable String key, @NonNull Class<T> clazz) {
        if (bundle != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                return bundle.getParcelableArrayList(key, clazz);
            } else {
                return bundle.getParcelableArrayList(key);
            }
        }
        return null;
    }
}

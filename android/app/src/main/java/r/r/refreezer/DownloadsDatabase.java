package r.r.refreezer;

import android.content.Context;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.util.Log;

/**
 * Database for the download queue/history.
 *
 * Version 2 adds scheduling and diagnostics columns. The migration is strictly additive:
 * no table is dropped and no user data is discarded. {@link #ensureColumns(SQLiteDatabase)}
 * is idempotent and also repairs databases that were only partially migrated by an older
 * (broken) upgrade path.
 */
public class DownloadsDatabase extends SQLiteOpenHelper {

    public static final int DATABASE_VERSION = 2;

    static final String TABLE = "Downloads";

    /** All columns that must exist for schema v2, with their ADD COLUMN definitions. */
    private static final String[][] V2_COLUMNS = {
            {"priority", "INTEGER DEFAULT 1"},
            {"attempts", "INTEGER DEFAULT 0"},
            {"nextRetryAt", "INTEGER DEFAULT 0"},
            {"errorKind", "TEXT"},
            {"errorMessage", "TEXT"},
            {"bytesTotal", "INTEGER DEFAULT 0"},
            {"createdAt", "INTEGER DEFAULT 0"},
            {"groupId", "TEXT"},
            {"metadataWarning", "TEXT"}
    };

    public DownloadsDatabase(Context context) {
        super(context, context.getDatabasePath("downloads").toString(), null, DATABASE_VERSION);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        /*
        Downloads:
        id - primary key
        path - destination path template / final path (private downloads store the full path)
        private - 1 = offline (app-private), 0 = external download
        quality - Deezer quality int
        state - Download.DownloadState value
        trackId - track id
        md5origin / mediaVersion / trackToken / streamTrackId - stream resolution data
        title / image - display data
        priority - 0 high, 1 normal, 2 low
        attempts - failed attempts so far
        nextRetryAt - epoch millis of the earliest automatic retry (0 = ready now)
        errorKind - machine readable failure reason (network, auth, storage, unavailable, processing)
        errorMessage - last technical error text (shown in the log viewer)
        bytesTotal - expected size in bytes (0 = unknown)
        createdAt - epoch millis when the job was queued (stable ordering)
        groupId - optional collection id (album/playlist) for grouping in the UI
        metadataWarning - set when tagging failed but audio was preserved
        */
        db.execSQL("CREATE TABLE IF NOT EXISTS " + TABLE + " (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT, "
                + "private INTEGER, quality INTEGER, state INTEGER, trackId TEXT, md5origin TEXT, "
                + "mediaVersion TEXT, title TEXT, image TEXT, trackToken TEXT, streamTrackId TEXT, "
                + "priority INTEGER DEFAULT 1, attempts INTEGER DEFAULT 0, nextRetryAt INTEGER DEFAULT 0, "
                + "errorKind TEXT, errorMessage TEXT, bytesTotal INTEGER DEFAULT 0, "
                + "createdAt INTEGER DEFAULT 0, groupId TEXT, metadataWarning TEXT);");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        Log.i("DOWN", "Upgrading downloads database " + oldVersion + " -> " + newVersion);
        if (oldVersion < 2) {
            migrateToV2(db);
        }
        // Future versions: append further additive migrations here.
        ensureColumns(db);
    }

    @Override
    public void onDowngrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        // Do not destroy data on downgrade; the older code ignores unknown columns.
        Log.w("DOWN", "Downloads database downgrade " + oldVersion + " -> " + newVersion + " (data preserved)");
    }

    @Override
    public void onOpen(SQLiteDatabase db) {
        super.onOpen(db);
        // Self-heal rows created by a partially migrated database.
        ensureColumns(db);
    }

    /** Additive v1 -> v2 migration. Never drops the table. */
    private void migrateToV2(SQLiteDatabase db) {
        for (String[] column : V2_COLUMNS) {
            addColumnIfMissing(db, column[0], column[1]);
        }
        // Existing rows get a stable creation order based on their id.
        try {
            db.execSQL("UPDATE " + TABLE + " SET createdAt = id WHERE createdAt IS NULL OR createdAt = 0");
        } catch (Exception e) {
            Log.w("DOWN", "Could not backfill createdAt: " + e);
        }
    }

    /** Idempotent column check; safe to call on every open. */
    static void ensureColumns(SQLiteDatabase db) {
        for (String[] column : V2_COLUMNS) {
            addColumnIfMissing(db, column[0], column[1]);
        }
    }

    private static void addColumnIfMissing(SQLiteDatabase db, String name, String definition) {
        if (hasColumn(db, name)) return;
        try {
            db.execSQL("ALTER TABLE " + TABLE + " ADD COLUMN " + name + " " + definition);
        } catch (Exception e) {
            Log.w("DOWN", "Could not add column " + name + ": " + e);
        }
    }

    private static boolean hasColumn(SQLiteDatabase db, String name) {
        android.database.Cursor cursor = null;
        try {
            cursor = db.rawQuery("PRAGMA table_info(" + TABLE + ")", null);
            int nameIndex = cursor.getColumnIndex("name");
            while (cursor.moveToNext()) {
                if (nameIndex >= 0 && name.equals(cursor.getString(nameIndex))) return true;
            }
        } catch (Exception e) {
            Log.w("DOWN", "Could not read table info: " + e);
        } finally {
            if (cursor != null) cursor.close();
        }
        return false;
    }
}

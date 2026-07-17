// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.

package __APP_PACKAGE__;

import android.content.Context;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.sqlite.db.SupportSQLiteDatabase;
import androidx.sqlite.db.SupportSQLiteOpenHelper;

// [BB_DYNAMICS-MIGRATION] Dynamics SQLiteOpenHelper — wraps the secure container database.
import com.good.gd.database.sqlite.SQLiteDatabase;
import com.good.gd.database.sqlite.SQLiteOpenHelper;

/**
 * SupportSQLiteOpenHelper implementation backed by Dynamics SQLite.
 *
 * Room calls this helper's getReadableDatabase() / getWritableDatabase() to get
 * a SupportSQLiteDatabase. We return a GDRoomDatabase that wraps the Dynamics
 * SQLiteDatabase, ensuring all data is encrypted inside the secure container.
 */
// [BB_DYNAMICS-MIGRATION] Implements Room's SupportSQLiteOpenHelper using Dynamics secure SQLite.
final class GDRoomOpenHelper implements SupportSQLiteOpenHelper {

    private final SupportSQLiteOpenHelper.Configuration configuration;
    private final InternalHelper gdHelper;

    GDRoomOpenHelper(@NonNull SupportSQLiteOpenHelper.Configuration configuration) {
        this.configuration = configuration;
        this.gdHelper = new InternalHelper(
                configuration.context,
                configuration.name,
                configuration.callback.version
        );
    }

    @Nullable
    @Override
    public String getDatabaseName() {
        return configuration.name;
    }

    @Override
    public void setWriteAheadLoggingEnabled(boolean enabled) {
        gdHelper.setWriteAheadLoggingEnabled(enabled);
    }

    @NonNull
    @Override
    public SupportSQLiteDatabase getWritableDatabase() {
        return new GDRoomDatabase(gdHelper.getWritableDatabase());
    }

    @NonNull
    @Override
    public SupportSQLiteDatabase getReadableDatabase() {
        return new GDRoomDatabase(gdHelper.getReadableDatabase());
    }

    @Override
    public void close() {
        gdHelper.close();
    }

    // -------------------------------------------------------------------------
    // Inner class: wraps Dynamics SQLiteOpenHelper lifecycle callbacks so Room's
    // SupportSQLiteOpenHelper.Callback.onCreate/onUpgrade/onOpen are invoked.
    // -------------------------------------------------------------------------
    private final class InternalHelper extends SQLiteOpenHelper {

        InternalHelper(Context context, String name, int version) {
            super(context, name, null, version);
        }

        @Override
        public void onCreate(SQLiteDatabase db) {
            configuration.callback.onCreate(new GDRoomDatabase(db));
        }

        @Override
        public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
            configuration.callback.onUpgrade(new GDRoomDatabase(db), oldVersion, newVersion);
        }

        @Override
        public void onOpen(SQLiteDatabase db) {
            configuration.callback.onOpen(new GDRoomDatabase(db));
        }
    }
}

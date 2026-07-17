// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.

package __APP_PACKAGE__

import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
// [BB_DYNAMICS-MIGRATION] Dynamics SQLiteOpenHelper — wraps the secure container database.
import com.good.gd.database.sqlite.SQLiteDatabase
import com.good.gd.database.sqlite.SQLiteOpenHelper

// [BB_DYNAMICS-MIGRATION] Implements Room's SupportSQLiteOpenHelper using Dynamics secure SQLite.
internal class GDRoomOpenHelper(
    private val configuration: SupportSQLiteOpenHelper.Configuration
) : SupportSQLiteOpenHelper {

    private val gdHelper = InternalHelper(
        configuration.context,
        configuration.name,
        configuration.callback.version
    )

    override fun getDatabaseName(): String? = configuration.name

    override fun setWriteAheadLoggingEnabled(enabled: Boolean) {
        gdHelper.setWriteAheadLoggingEnabled(enabled)
    }

    override fun getWritableDatabase(): SupportSQLiteDatabase =
        GDRoomDatabase(gdHelper.writableDatabase)

    override fun getReadableDatabase(): SupportSQLiteDatabase =
        GDRoomDatabase(gdHelper.readableDatabase)

    override fun close() = gdHelper.close()

    private inner class InternalHelper(
        context: android.content.Context,
        name: String?,
        version: Int
    ) : SQLiteOpenHelper(context, name, null, version) {

        override fun onCreate(db: SQLiteDatabase) =
            configuration.callback.onCreate(GDRoomDatabase(db))

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) =
            configuration.callback.onUpgrade(GDRoomDatabase(db), oldVersion, newVersion)

        override fun onOpen(db: SQLiteDatabase) =
            configuration.callback.onOpen(GDRoomDatabase(db))
    }
}

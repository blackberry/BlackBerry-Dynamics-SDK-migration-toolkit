// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / Dynamics-GettingStarted (Apache-2.0).
// Source: ColorDbHelper.kt — see templates/_LICENSE-NOTICE.md for full attribution.
//
// NOTE: Dynamics SDK exposes only Java APIs. com.good.gd.database.sqlite.* types
// are Java platform types in Kotlin.
//
// MIGRATION RULE — two-import swap, nothing else:
//   REMOVE: import android.database.sqlite.SQLiteOpenHelper
//   REMOVE: import android.database.sqlite.SQLiteDatabase
//   ADD:    import com.good.gd.database.sqlite.SQLiteOpenHelper
//   ADD:    import com.good.gd.database.sqlite.SQLiteDatabase
//
// UNCHANGED IMPORTS (keep exactly as-is):
//   import android.database.Cursor
//   import android.content.ContentValues
//   import android.database.sqlite.SQLiteException           // no Dynamics equivalent
//   import android.database.sqlite.SQLiteConstraintException // no Dynamics equivalent
//   import android.database.sqlite.SQLiteBlobTooBigException // no Dynamics equivalent
//
// This is NOT the right template for Room. For Room, use sql/room-bridge/.
// All database access MUST happen after onAuthorized() fires.

package __APP_PACKAGE__

import android.content.Context

// [BB_DYNAMICS-MIGRATION] Replaced android.database.sqlite.SQLiteDatabase with Dynamics secure equivalent.
import com.good.gd.database.sqlite.SQLiteDatabase
// [BB_DYNAMICS-MIGRATION] Replaced android.database.sqlite.SQLiteOpenHelper with Dynamics secure equivalent.
import com.good.gd.database.sqlite.SQLiteOpenHelper

/**
 * Example of a Dynamics-migrated SQLiteOpenHelper.
 *
 * The migration is exactly two import lines. The entire class body is unchanged.
 * The Dynamics SQLite API is identical to Android SQLite.
 */
class DynamicsDbHelper(context: Context) : SQLiteOpenHelper(
    context,
    DATABASE_NAME,
    null,
    DATABASE_VERSION
) {
    companion object {
        const val DATABASE_NAME = "__DB_NAME__"
        const val DATABASE_VERSION = __DB_VERSION__
    }

    override fun onCreate(db: SQLiteDatabase) {
        // TODO: Replace with your actual CREATE TABLE statement(s).
        db.execSQL("CREATE TABLE example (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // TODO: Replace with your actual schema migration logic.
        db.execSQL("DROP TABLE IF EXISTS example")
        onCreate(db)
    }
}

// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / Dynamics-GettingStarted (Apache-2.0).
// Source: ColorDbHelper.java — see templates/_LICENSE-NOTICE.md for full attribution.
//
// HOW TO USE (raw SQLiteOpenHelper — NOT Room):
//   1. Replace __APP_PACKAGE__ with your application package.
//   2. Replace __DB_NAME__ with your database file name (e.g., "photos.db").
//   3. Replace __DB_VERSION__ with your schema version integer.
//   4. In your existing SQLiteOpenHelper subclass, change ONLY the two imports below.
//      The entire class body — constructor, onCreate, onUpgrade — is UNCHANGED.
//   5. If your class currently extends android.database.sqlite.SQLiteOpenHelper,
//      change it to extend com.good.gd.database.sqlite.SQLiteOpenHelper.
//      The constructor and all method signatures are identical.
//
// MIGRATION RULE — two-import swap, nothing else:
//   REMOVE: import android.database.sqlite.SQLiteOpenHelper;
//   REMOVE: import android.database.sqlite.SQLiteDatabase;
//   ADD:    import com.good.gd.database.sqlite.SQLiteOpenHelper;
//   ADD:    import com.good.gd.database.sqlite.SQLiteDatabase;
//
// UNCHANGED IMPORTS (keep these exactly as-is):
//   import android.database.Cursor;          // no Dynamics equivalent needed
//   import android.content.ContentValues;    // no Dynamics equivalent needed
//   import android.database.sqlite.SQLiteException;           // no Dynamics equivalent
//   import android.database.sqlite.SQLiteConstraintException; // no Dynamics equivalent
//   import android.database.sqlite.SQLiteBlobTooBigException; // no Dynamics equivalent
//
// This is NOT the right template for Room. For Room, use sql/room-bridge/.
//
// All database access MUST happen after onAuthorized() fires.

package __APP_PACKAGE__;

import android.content.Context;

// [BB_DYNAMICS-MIGRATION] Replaced android.database.sqlite.SQLiteDatabase with Dynamics secure equivalent.
import com.good.gd.database.sqlite.SQLiteDatabase;
// [BB_DYNAMICS-MIGRATION] Replaced android.database.sqlite.SQLiteOpenHelper with Dynamics secure equivalent.
import com.good.gd.database.sqlite.SQLiteOpenHelper;

/**
 * Example of a Dynamics-migrated SQLiteOpenHelper.
 *
 * The migration is exactly two import lines. Everything else — constructor
 * signature, onCreate, onUpgrade, all query/insert/update/delete methods — is
 * completely unchanged. The Dynamics SQLite API is identical to Android SQLite.
 */
public class DynamicsDbHelper extends SQLiteOpenHelper {

    public static final String DATABASE_NAME = "__DB_NAME__";
    public static final int DATABASE_VERSION = __DB_VERSION__;

    // Constructor is UNCHANGED — same signature as android.database.sqlite.SQLiteOpenHelper.
    public DynamicsDbHelper(Context context) {
        super(context, DATABASE_NAME, null, DATABASE_VERSION);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        // TODO: Replace with your actual CREATE TABLE statement(s).
        db.execSQL("CREATE TABLE example (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        // TODO: Replace with your actual schema migration logic.
        db.execSQL("DROP TABLE IF EXISTS example");
        onCreate(db);
    }
}

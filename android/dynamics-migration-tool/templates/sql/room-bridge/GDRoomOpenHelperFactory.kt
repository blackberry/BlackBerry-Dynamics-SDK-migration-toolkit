// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.
//
// HOW TO USE:
//   1. Replace __APP_PACKAGE__ with your application package.
//   2. Wire into Room.databaseBuilder:
//
//        val db = Room.databaseBuilder(context, AppDatabase::class.java, "my_db")
//            .openHelperFactory(GDRoomOpenHelperFactory())   // ← add this line
//            .build()
//
// ANTI-PATTERN (do NOT produce this):
//   override fun create(config: SupportSQLiteOpenHelper.Configuration): SupportSQLiteOpenHelper {
//       touchDynamicsClasses()
//       return FrameworkSQLiteOpenHelperFactory().create(config)  // ← still standard SQLite
//   }

package __APP_PACKAGE__

import androidx.sqlite.db.SupportSQLiteOpenHelper

// [BB_DYNAMICS-MIGRATION] Factory that creates a Dynamics-backed SupportSQLiteOpenHelper for Room.
class GDRoomOpenHelperFactory : SupportSQLiteOpenHelper.Factory {
    override fun create(configuration: SupportSQLiteOpenHelper.Configuration): SupportSQLiteOpenHelper {
        // [BB_DYNAMICS-MIGRATION] Returns GDRoomOpenHelper backed by Dynamics SQLite.
        return GDRoomOpenHelper(configuration)
    }
}

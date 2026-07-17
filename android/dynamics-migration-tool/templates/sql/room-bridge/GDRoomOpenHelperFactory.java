// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored (no public sample covers Room+SupportSQLiteOpenHelper bridge).
// License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.
//
// HOW TO USE:
//   1. Copy all five files in this directory into your app source tree under a package
//      such as <your.package>.dynamics.db (e.g., com.example.myapp.dynamics.db).
//   2. Replace __APP_PACKAGE__ in each file with that package name.
//   3. In the class that calls Room.databaseBuilder(...), chain .openHelperFactory():
//
//        AppDatabase db = Room.databaseBuilder(context, AppDatabase.class, "my_db")
//            .openHelperFactory(new GDRoomOpenHelperFactory())   // ← add this line
//            .build();
//
//   4. Do NOT call .fallbackToDestructiveMigration() unless you intend to drop data.
//   5. Run ./gradlew assembleDebug — fix any compile errors before proceeding.
//
// ANTI-PATTERN (do NOT produce this):
//   public SupportSQLiteOpenHelper create(Configuration config) {
//       touchDynamicsClasses();
//       return new FrameworkSQLiteOpenHelperFactory().create(config);  // ← still standard SQLite
//   }
// The factory MUST return a GDRoomOpenHelper, not a framework helper.

package __APP_PACKAGE__;

import androidx.annotation.NonNull;
import androidx.sqlite.db.SupportSQLiteOpenHelper;

// [BB_DYNAMICS-MIGRATION] Factory that creates a Dynamics-backed SupportSQLiteOpenHelper for Room.
public final class GDRoomOpenHelperFactory implements SupportSQLiteOpenHelper.Factory {

    @NonNull
    @Override
    public SupportSQLiteOpenHelper create(@NonNull SupportSQLiteOpenHelper.Configuration configuration) {
        // [BB_DYNAMICS-MIGRATION] Returns a GDRoomOpenHelper backed by Dynamics SQLite.
        // The Dynamics secure container encrypts all data written by Room through this helper.
        return new GDRoomOpenHelper(configuration);
    }
}

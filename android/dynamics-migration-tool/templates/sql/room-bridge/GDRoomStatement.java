// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.

package __APP_PACKAGE__;

import androidx.annotation.NonNull;
import androidx.sqlite.db.SupportSQLiteStatement;

// [BB_DYNAMICS-MIGRATION] Dynamics SQLiteStatement — wraps compiled SQL inside the secure container.
import com.good.gd.database.sqlite.SQLiteStatement;

import java.io.IOException;

/**
 * SupportSQLiteStatement adapter wrapping a Dynamics SQLiteStatement.
 *
 * IMPORTANT — close() must declare throws IOException (from java.io.Closeable).
 */
// [BB_DYNAMICS-MIGRATION] Implements Room's SupportSQLiteStatement wrapping Dynamics SQLiteStatement.
final class GDRoomStatement implements SupportSQLiteStatement {

    private final SQLiteStatement stmt;

    GDRoomStatement(@NonNull SQLiteStatement stmt) {
        this.stmt = stmt;
    }

    // ---- Execution ----------------------------------------------------------

    @Override
    public void execute() {
        stmt.execute();
    }

    @Override
    public long executeInsert() {
        return stmt.executeInsert();
    }

    @Override
    public int executeUpdateDelete() {
        return stmt.executeUpdateDelete();
    }

    @Override
    public long simpleQueryForLong() {
        return stmt.simpleQueryForLong();
    }

    @Override
    public String simpleQueryForString() {
        return stmt.simpleQueryForString();
    }

    // ---- Bindings (from SupportSQLiteProgram) --------------------------------

    @Override
    public void bindNull(int index) {
        stmt.bindNull(index);
    }

    @Override
    public void bindLong(int index, long value) {
        stmt.bindLong(index, value);
    }

    @Override
    public void bindDouble(int index, double value) {
        stmt.bindDouble(index, value);
    }

    @Override
    public void bindString(int index, @NonNull String value) {
        stmt.bindString(index, value);
    }

    @Override
    public void bindBlob(int index, @NonNull byte[] value) {
        stmt.bindBlob(index, value);
    }

    @Override
    public void clearBindings() {
        stmt.clearBindings();
    }

    // IMPORTANT: throws IOException, NOT throws Exception.
    @Override
    public void close() throws IOException {
        stmt.close();
    }
}

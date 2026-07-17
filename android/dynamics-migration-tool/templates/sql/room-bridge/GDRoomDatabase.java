// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.

package __APP_PACKAGE__;

import android.content.ContentValues;
import android.database.Cursor;
import android.os.CancellationSignal;
import android.util.Pair;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.sqlite.db.SupportSQLiteDatabase;
import androidx.sqlite.db.SupportSQLiteQuery;
import androidx.sqlite.db.SupportSQLiteStatement;

// [BB_DYNAMICS-MIGRATION] Dynamics SQLiteDatabase wraps the secure container's database.
import com.good.gd.database.sqlite.SQLiteDatabase;

import java.io.IOException;
import java.util.List;
import java.util.Locale;

/**
 * SupportSQLiteDatabase adapter that wraps a Dynamics SQLiteDatabase.
 *
 * Room calls this interface for all SQL operations. Every method delegates to
 * the underlying Dynamics db, which writes encrypted data inside the container.
 *
 * IMPORTANT — close() must declare throws IOException (from java.io.Closeable).
 * Do NOT change it to throws Exception — the class will fail to compile.
 */
// [BB_DYNAMICS-MIGRATION] Implements Room's SupportSQLiteDatabase wrapping Dynamics SQLiteDatabase.
final class GDRoomDatabase implements SupportSQLiteDatabase {

    // [BB_DYNAMICS-MIGRATION] The Dynamics secure database — all I/O is encrypted by the container.
    private final SQLiteDatabase db;

    GDRoomDatabase(@NonNull SQLiteDatabase db) {
        this.db = db;
    }

    // ---- Queries ------------------------------------------------------------

    @Override
    public Cursor query(@NonNull String sql) {
        return db.rawQuery(sql, null);
    }

    @Override
    public Cursor query(@NonNull String sql, @NonNull Object[] bindArgs) {
        String[] strArgs = toStringArray(bindArgs);
        return db.rawQuery(sql, strArgs);
    }

    @Override
    public Cursor query(@NonNull SupportSQLiteQuery query) {
        GDRoomQueryBindingHelper helper = new GDRoomQueryBindingHelper();
        query.bindTo(helper);
        return db.rawQuery(query.getSql(), helper.getBindings());
    }

    @Override
    public Cursor query(@NonNull SupportSQLiteQuery query, @Nullable CancellationSignal cancellationSignal) {
        // CancellationSignal not supported by Dynamics SQLite — delegate without it.
        return query(query);
    }

    // ---- DML ----------------------------------------------------------------

    @Override
    public long insert(@NonNull String table, int conflictAlgorithm, @NonNull ContentValues values) {
        return db.insertWithOnConflict(table, null, values, conflictAlgorithm);
    }

    @Override
    public int delete(@NonNull String table, @Nullable String whereClause, @Nullable Object[] whereArgs) {
        return db.delete(table, whereClause, toStringArray(whereArgs));
    }

    @Override
    public int update(@NonNull String table, int conflictAlgorithm,
                      @NonNull ContentValues values,
                      @Nullable String whereClause, @Nullable Object[] whereArgs) {
        return db.updateWithOnConflict(table, values, whereClause, toStringArray(whereArgs), conflictAlgorithm);
    }

    @Override
    public void execSQL(@NonNull String sql) {
        db.execSQL(sql);
    }

    @Override
    public void execSQL(@NonNull String sql, @NonNull Object[] bindArgs) {
        db.execSQL(sql, bindArgs);
    }

    // ---- Compiled statements ------------------------------------------------

    @NonNull
    @Override
    public SupportSQLiteStatement compileStatement(@NonNull String sql) {
        return new GDRoomStatement(db.compileStatement(sql));
    }

    // ---- Transactions -------------------------------------------------------

    @Override
    public void beginTransaction() {
        db.beginTransaction();
    }

    @Override
    public void beginTransactionNonExclusive() {
        db.beginTransactionNonExclusive();
    }

    @Override
    public void beginTransactionWithListener(
            @NonNull android.database.sqlite.SQLiteTransactionListener listener) {
        // [BB_DYNAMICS-MIGRATION] Android SQLiteTransactionListener must be wrapped to
        // satisfy Dynamics SQLiteDatabase.beginTransactionWithListener() parameter type.
        db.beginTransactionWithListener(new com.good.gd.database.sqlite.SQLiteTransactionListener() {
            @Override public void onBegin()    { listener.onBegin(); }
            @Override public void onCommit()   { listener.onCommit(); }
            @Override public void onRollback() { listener.onRollback(); }
        });
    }

    @Override
    public void beginTransactionWithListenerNonExclusive(
            @NonNull android.database.sqlite.SQLiteTransactionListener listener) {
        db.beginTransactionWithListenerNonExclusive(
                new com.good.gd.database.sqlite.SQLiteTransactionListener() {
                    @Override public void onBegin()    { listener.onBegin(); }
                    @Override public void onCommit()   { listener.onCommit(); }
                    @Override public void onRollback() { listener.onRollback(); }
                });
    }

    @Override
    public void endTransaction() {
        db.endTransaction();
    }

    @Override
    public void setTransactionSuccessful() {
        db.setTransactionSuccessful();
    }

    @Override
    public boolean inTransaction() {
        return db.inTransaction();
    }

    // ---- State --------------------------------------------------------------

    @Override
    public boolean isDbLockedByCurrentThread() {
        return db.isDbLockedByCurrentThread();
    }

    @Override
    public boolean yieldIfContendedSafely() {
        return db.yieldIfContendedSafely();
    }

    @Override
    public boolean yieldIfContendedSafely(long sleepAfterYieldDelay) {
        return db.yieldIfContendedSafely(sleepAfterYieldDelay);
    }

    @Override
    public int getVersion() {
        return db.getVersion();
    }

    @Override
    public void setVersion(int version) {
        db.setVersion(version);
    }

    @Override
    public long getMaximumSize() {
        return db.getMaximumSize();
    }

    @Override
    public long setMaximumSize(long numBytes) {
        return db.setMaximumSize(numBytes);
    }

    @Override
    public long getPageSize() {
        return db.getPageSize();
    }

    @Override
    public void setPageSize(long numBytes) {
        db.setPageSize(numBytes);
    }

    @Nullable
    @Override
    public String getPath() {
        return db.getPath();
    }

    @Override
    public boolean isOpen() {
        return db.isOpen();
    }

    @Override
    public boolean needUpgrade(int newVersion) {
        return db.needUpgrade(newVersion);
    }

    @Override
    public boolean isReadOnly() {
        return db.isReadOnly();
    }

    @Override
    public boolean isWriteAheadLoggingEnabled() {
        return db.isWriteAheadLoggingEnabled();
    }

    @Override
    public void setForeignKeyConstraintsEnabled(boolean enable) {
        db.setForeignKeyConstraintsEnabled(enable);
    }

    @Override
    public boolean enableWriteAheadLogging() {
        return db.enableWriteAheadLogging();
    }

    @Override
    public void disableWriteAheadLogging() {
        db.disableWriteAheadLogging();
    }

    @Nullable
    @Override
    public List<Pair<String, String>> getAttachedDbs() {
        return db.getAttachedDbs();
    }

    @Override
    public boolean isDatabaseIntegrityOk() {
        return db.isDatabaseIntegrityOk();
    }

    // Commonly missed — from SupportSQLiteDatabase interface.
    @Override
    public void setMaxSqlCacheSize(int cacheSize) {
        db.setMaxSqlCacheSize(cacheSize);
    }

    @Override
    public void setLocale(@NonNull Locale locale) {
        db.setLocale(locale);
    }

    // IMPORTANT: close() MUST declare throws IOException (from java.io.Closeable).
    // Declaring throws Exception will NOT satisfy the interface and causes a compile error.
    @Override
    public void close() throws IOException {
        db.close();
    }

    // ---- Helpers ------------------------------------------------------------

    @Nullable
    private static String[] toStringArray(@Nullable Object[] args) {
        if (args == null) return null;
        String[] result = new String[args.length];
        for (int i = 0; i < args.length; i++) {
            if (args[i] instanceof byte[]) {
                throw new UnsupportedOperationException(
                        "BLOB argument at index " + i
                                + " cannot be passed through rawQuery/delete/update String[] bindings. "
                                + "Use a compiled SQLiteStatement with bindBlob() for BLOB predicates."
                );
            }
            result[i] = args[i] == null ? null : String.valueOf(args[i]);
        }
        return result;
    }
}

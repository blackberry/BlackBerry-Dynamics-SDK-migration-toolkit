// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.
//
// PURPOSE: Room binds query parameters by calling SupportSQLiteQuery.bindTo(SupportSQLiteProgram).
// Dynamics rawQuery() takes a String[] instead. This class captures the bindings
// from bindTo() and converts them to String[] for rawQuery().
//
// IMPORTANT: SimpleSQLiteQuery.bind() and SimpleSQLiteQuery.Companion.bind() are
// private — do NOT attempt to call them. Use this class instead.
//
// KNOWN LIMITATION — BLOB bindings:
//   rawQuery(String, String[]) passes every argument to SQLite as TEXT (sqlite3_bind_text).
//   There is no way to carry a BLOB through the String[] API regardless of formatting.
//   Note: placing "X'..'" hex-literal syntax inside a bound parameter does NOT help;
//   the X'...' notation is only interpreted by the SQL parser when it appears in the SQL
//   text itself, not when passed as a parameterised value — SQLite sees it as the literal
//   text string X'...' (TEXT affinity), not as a BLOB.
//   Consequence: BLOB-typed WHERE-clause predicates routed through this helper will
//   bind as TEXT, which will not compare equal to BLOB-stored values under SQLite's
//   strict type-ordering rules. This is an inherent constraint of rawQuery(String, String[]).
//   Workaround: for BLOB-keyed queries, compile the statement via db.compileStatement()
//   and call bindBlob() on the resulting SQLiteStatement directly (as GDRoomStatement does).

package __APP_PACKAGE__;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.sqlite.db.SupportSQLiteProgram;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

/**
 * Captures Room query parameter bindings and exposes them as a {@code String[]}
 * for use with Dynamics {@code SQLiteDatabase.rawQuery()}.
 */
// [BB_DYNAMICS-MIGRATION] Bridges Room's SupportSQLiteProgram binding model to Dynamics rawQuery().
final class GDRoomQueryBindingHelper implements SupportSQLiteProgram {

    private final Map<Integer, String> bindings = new HashMap<>();

    /**
     * Returns the captured bindings as a {@code String[]}, or {@code null} if no
     * parameters were bound. Indices are 1-based (Room convention); the returned
     * array is 0-based with nulls for unbound positions.
     */
    @Nullable
    public String[] getBindings() {
        if (bindings.isEmpty()) return null;
        int maxIndex = 0;
        for (int key : bindings.keySet()) {
            if (key > maxIndex) maxIndex = key;
        }
        String[] result = new String[maxIndex];
        for (Map.Entry<Integer, String> entry : bindings.entrySet()) {
            result[entry.getKey() - 1] = entry.getValue();
        }
        return result;
    }

    @Override
    public void bindNull(int index) {
        bindings.put(index, null);
    }

    @Override
    public void bindLong(int index, long value) {
        bindings.put(index, String.valueOf(value));
    }

    @Override
    public void bindDouble(int index, double value) {
        bindings.put(index, String.valueOf(value));
    }

    @Override
    public void bindString(int index, @NonNull String value) {
        bindings.put(index, value);
    }

    @Override
    public void bindBlob(int index, @NonNull byte[] value) {
        throw new UnsupportedOperationException(
                "Room query attempted to bind a BLOB at index " + index
                        + ". Dynamics rawQuery(String, String[]) only supports TEXT/NULL args. "
                        + "Use a compiled SQLiteStatement with bindBlob() for BLOB predicates."
        );
    }

    @Override
    public void clearBindings() {
        bindings.clear();
    }

    // No-op: this helper is transient and holds no resources.
    @Override
    public void close() throws IOException { }

}

// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.
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

package __APP_PACKAGE__

import androidx.sqlite.db.SupportSQLiteProgram
import java.io.IOException

/**
 * Captures Room query parameter bindings and exposes them as [Array<String?>]
 * for Dynamics [com.good.gd.database.sqlite.SQLiteDatabase.rawQuery].
 *
 * IMPORTANT: [SimpleSQLiteQuery.bind] is private — do NOT attempt to call it.
 */
// [BB_DYNAMICS-MIGRATION] Bridges Room's SupportSQLiteProgram binding model to Dynamics rawQuery().
internal class GDRoomQueryBindingHelper : SupportSQLiteProgram {

    private val bindings = mutableMapOf<Int, String?>()

    fun getBindings(): Array<String?>? {
        if (bindings.isEmpty()) return null
        val maxIndex = bindings.keys.max()
        return Array(maxIndex) { i -> bindings[i + 1] }
    }

    override fun bindNull(index: Int) { bindings[index] = null }
    override fun bindLong(index: Int, value: Long) { bindings[index] = value.toString() }
    override fun bindDouble(index: Int, value: Double) { bindings[index] = value.toString() }
    override fun bindString(index: Int, value: String) { bindings[index] = value }
    override fun bindBlob(index: Int, value: ByteArray) {
        throw UnsupportedOperationException(
            "Room query attempted to bind a BLOB at index $index. " +
                "Dynamics rawQuery(String, String[]) only supports TEXT/NULL args. " +
                "Use a compiled SQLiteStatement with bindBlob() for BLOB predicates."
        )
    }
    override fun clearBindings() { bindings.clear() }

    @Throws(IOException::class)
    override fun close() { /* no-op */ }
}

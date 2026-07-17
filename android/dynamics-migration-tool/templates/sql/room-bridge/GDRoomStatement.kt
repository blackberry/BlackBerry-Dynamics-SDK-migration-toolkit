// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.

package __APP_PACKAGE__

import androidx.sqlite.db.SupportSQLiteStatement
// [BB_DYNAMICS-MIGRATION] Dynamics SQLiteStatement — compiled SQL inside the secure container.
import com.good.gd.database.sqlite.SQLiteStatement
import java.io.IOException

// [BB_DYNAMICS-MIGRATION] Implements Room's SupportSQLiteStatement wrapping Dynamics SQLiteStatement.
internal class GDRoomStatement(private val stmt: SQLiteStatement) : SupportSQLiteStatement {

    override fun execute() = stmt.execute()
    override fun executeInsert(): Long = stmt.executeInsert()
    override fun executeUpdateDelete(): Int = stmt.executeUpdateDelete()
    override fun simpleQueryForLong(): Long = stmt.simpleQueryForLong()
    override fun simpleQueryForString(): String? = stmt.simpleQueryForString()

    override fun bindNull(index: Int) = stmt.bindNull(index)
    override fun bindLong(index: Int, value: Long) = stmt.bindLong(index, value)
    override fun bindDouble(index: Int, value: Double) = stmt.bindDouble(index, value)
    override fun bindString(index: Int, value: String) = stmt.bindString(index, value)
    override fun bindBlob(index: Int, value: ByteArray) = stmt.bindBlob(index, value)
    override fun clearBindings() = stmt.clearBindings()

    // IMPORTANT: throws IOException (from Closeable), NOT throws Exception.
    @Throws(IOException::class)
    override fun close() = stmt.close()
}

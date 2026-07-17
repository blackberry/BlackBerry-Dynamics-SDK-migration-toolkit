// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.

package __APP_PACKAGE__

import android.content.ContentValues
import android.database.Cursor
import android.os.CancellationSignal
import android.util.Pair
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteQuery
import androidx.sqlite.db.SupportSQLiteStatement
// [BB_DYNAMICS-MIGRATION] Dynamics SQLiteDatabase — all data encrypted by the secure container.
import com.good.gd.database.sqlite.SQLiteDatabase
import java.io.IOException
import java.util.Locale

// [BB_DYNAMICS-MIGRATION] Implements Room's SupportSQLiteDatabase wrapping Dynamics SQLiteDatabase.
internal class GDRoomDatabase(private val db: SQLiteDatabase) : SupportSQLiteDatabase {

    override fun query(sql: String): Cursor = db.rawQuery(sql, null)

    override fun query(sql: String, bindArgs: Array<out Any?>): Cursor =
        db.rawQuery(sql, bindArgs.toStringArray())

    override fun query(query: SupportSQLiteQuery): Cursor {
        val helper = GDRoomQueryBindingHelper()
        query.bindTo(helper)
        return db.rawQuery(query.sql, helper.getBindings())
    }

    override fun query(query: SupportSQLiteQuery, cancellationSignal: CancellationSignal?): Cursor =
        query(query)

    override fun insert(table: String, conflictAlgorithm: Int, values: ContentValues): Long =
        db.insertWithOnConflict(table, null, values, conflictAlgorithm)

    override fun delete(table: String, whereClause: String?, whereArgs: Array<out Any?>?): Int =
        db.delete(table, whereClause, whereArgs?.toStringArray())

    override fun update(
        table: String, conflictAlgorithm: Int, values: ContentValues,
        whereClause: String?, whereArgs: Array<out Any?>?
    ): Int = db.updateWithOnConflict(table, values, whereClause, whereArgs?.toStringArray(), conflictAlgorithm)

    override fun execSQL(sql: String) = db.execSQL(sql)

    override fun execSQL(sql: String, bindArgs: Array<out Any?>) = db.execSQL(sql, bindArgs)

    override fun compileStatement(sql: String): SupportSQLiteStatement =
        GDRoomStatement(db.compileStatement(sql))

    override fun beginTransaction() = db.beginTransaction()
    override fun beginTransactionNonExclusive() = db.beginTransactionNonExclusive()

    override fun beginTransactionWithListener(
        listener: android.database.sqlite.SQLiteTransactionListener
    ) {
        // [BB_DYNAMICS-MIGRATION] Wrap Android SQLiteTransactionListener for Dynamics parameter type.
        db.beginTransactionWithListener(object : com.good.gd.database.sqlite.SQLiteTransactionListener {
            override fun onBegin() = listener.onBegin()
            override fun onCommit() = listener.onCommit()
            override fun onRollback() = listener.onRollback()
        })
    }

    override fun beginTransactionWithListenerNonExclusive(
        listener: android.database.sqlite.SQLiteTransactionListener
    ) {
        db.beginTransactionWithListenerNonExclusive(
            object : com.good.gd.database.sqlite.SQLiteTransactionListener {
                override fun onBegin() = listener.onBegin()
                override fun onCommit() = listener.onCommit()
                override fun onRollback() = listener.onRollback()
            })
    }

    override fun endTransaction() = db.endTransaction()
    override fun setTransactionSuccessful() = db.setTransactionSuccessful()
    override fun inTransaction(): Boolean = db.inTransaction()
    override fun isDbLockedByCurrentThread(): Boolean = db.isDbLockedByCurrentThread
    override fun yieldIfContendedSafely(): Boolean = db.yieldIfContendedSafely()
    override fun yieldIfContendedSafely(sleepAfterYieldDelay: Long): Boolean =
        db.yieldIfContendedSafely(sleepAfterYieldDelay)

    override fun getVersion(): Int = db.version
    override fun setVersion(version: Int) { db.version = version }
    override fun getMaximumSize(): Long = db.maximumSize
    override fun setMaximumSize(numBytes: Long): Long = db.setMaximumSize(numBytes)
    override fun getPageSize(): Long = db.pageSize
    override fun setPageSize(numBytes: Long) { db.pageSize = numBytes }
    override fun getPath(): String? = db.path
    override fun isOpen(): Boolean = db.isOpen
    override fun needUpgrade(newVersion: Int): Boolean = db.needUpgrade(newVersion)
    override fun isReadOnly(): Boolean = db.isReadOnly
    override fun isWriteAheadLoggingEnabled(): Boolean = db.isWriteAheadLoggingEnabled
    override fun setForeignKeyConstraintsEnabled(enable: Boolean) =
        db.setForeignKeyConstraintsEnabled(enable)

    override fun enableWriteAheadLogging(): Boolean = db.enableWriteAheadLogging()
    override fun disableWriteAheadLogging() = db.disableWriteAheadLogging()
    override fun getAttachedDbs(): MutableList<Pair<String, String>>? = db.attachedDbs
    override fun isDatabaseIntegrityOk(): Boolean = db.isDatabaseIntegrityOk

    // Commonly missed — setMaxSqlCacheSize and setLocale.
    override fun setMaxSqlCacheSize(cacheSize: Int) = db.setMaxSqlCacheSize(cacheSize)
    override fun setLocale(locale: Locale) = db.setLocale(locale)

    // IMPORTANT: close() throws IOException (from Closeable). NOT throws Exception.
    @Throws(IOException::class)
    override fun close() = db.close()

    private fun Array<out Any?>.toStringArray(): Array<String?> =
        Array(size) { i ->
            val value = this[i]
            if (value is ByteArray) {
                throw UnsupportedOperationException(
                    "BLOB argument at index $i cannot be passed through " +
                        "rawQuery/delete/update String[] bindings. " +
                        "Use a compiled SQLiteStatement with bindBlob() for BLOB predicates."
                )
            }
            value?.toString()
        }
}

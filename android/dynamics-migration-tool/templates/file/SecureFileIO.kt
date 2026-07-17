// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / Dynamics-GettingStarted (Apache-2.0).
// Source: FileFragment.kt — see templates/_LICENSE-NOTICE.md for full attribution.
//
// NOTE: Dynamics SDK exposes only Java APIs.
//   - GDFileSystem.openFileOutput() returns com.good.gd.file.FileOutputStream! (platform type).
//   - GDFileSystem.openFileInput()  returns com.good.gd.file.FileInputStream!  (platform type).
//   - Treat return values as nullable; use null-safe operators, not !!.
//
// MIGRATION RULE — direct call-site substitution, no scaffolding:
//   BEFORE: context.openFileOutput(name, MODE)  →  AFTER: GDFileSystem.openFileOutput(name, MODE)
//   BEFORE: context.openFileInput(name)          →  AFTER: GDFileSystem.openFileInput(name)
//   BEFORE: FileOutputStream(path)               →  AFTER: com.good.gd.file.FileOutputStream(path)
//   BEFORE: FileInputStream(path)                →  AFTER: com.good.gd.file.FileInputStream(path)
//
// All secure file access MUST happen after onAuthorized() fires.

package __APP_PACKAGE__

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
// [BB_DYNAMICS-MIGRATION] Replaced java.io.FileInputStream/FileOutputStream with Dynamics secure equivalents.
import com.good.gd.file.FileInputStream
import com.good.gd.file.FileOutputStream
// [BB_DYNAMICS-MIGRATION] Added GDFileSystem for Dynamics secure file I/O entry point.
import com.good.gd.file.GDFileSystem
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.Reader
import java.io.Writer
import java.nio.charset.Charset

/**
 * Shows the correct pattern for writing and reading files inside the Dynamics secure container.
 *
 * Key points:
 * - GDFileSystem is the entry point for named-file access (analogous to Context.openFileX).
 * - com.good.gd.file.FileOutputStream / FileInputStream are used for path-based access.
 * - Context.MODE_PRIVATE is UNCHANGED.
 * - Standard java.io stream wrappers (BufferedReader, InputStreamReader) are UNCHANGED.
 * - Must only be called after onAuthorized() has fired.
 */
object SecureFileIO {

    /**
     * Writes text to a named file inside the Dynamics secure container.
     */
    @Throws(java.io.IOException::class)
    fun writeFile(filename: String, content: String) {
        // [BB_DYNAMICS-MIGRATION] Replaced context.openFileOutput() with GDFileSystem.openFileOutput()
        // for Dynamics encrypted storage. Context.MODE_PRIVATE constant is unchanged.
        val outputStream: FileOutputStream = GDFileSystem.openFileOutput(filename, Context.MODE_PRIVATE)
            ?: throw java.io.IOException("GDFileSystem.openFileOutput returned null for: $filename")
        outputStream.use { it.write(content.toByteArray()) }
    }

    /**
     * Reads text from a named file inside the Dynamics secure container.
     * Returns null if the file does not exist.
     */
    @Throws(java.io.IOException::class)
    fun readFile(filename: String): String? {
        // [BB_DYNAMICS-MIGRATION] Replaced context.openFileInput() with GDFileSystem.openFileInput()
        // for Dynamics encrypted storage.
        val inputStream: FileInputStream = GDFileSystem.openFileInput(filename) ?: return null
        return inputStream.use { stream ->
            stream.bufferedReader().use { it.readText() }
        }
    }

    /**
     * Writes raw bytes to a path inside the Dynamics secure container.
     * Use when you need a path-based FileOutputStream (e.g., media/photos/img.jpg).
     */
    @Throws(java.io.IOException::class)
    fun writeBytes(containerPath: String, bytes: ByteArray) {
        // [BB_DYNAMICS-MIGRATION] Replaced FileOutputStream(path) with
        // com.good.gd.file.FileOutputStream(path) for Dynamics container path access.
        FileOutputStream(containerPath).use { it.write(bytes) }
    }

    /**
     * Reads raw bytes from a path inside the Dynamics secure container.
     */
    @Throws(java.io.IOException::class)
    fun readBytes(containerPath: String): ByteArray {
        // [BB_DYNAMICS-MIGRATION] Replaced FileInputStream(path) with
        // com.good.gd.file.FileInputStream(path) for Dynamics container path access.
        return FileInputStream(containerPath).use { it.readBytes() }
    }

    // ------------------------------------------------------------------
    // Stream-layer closure helpers (see steering/40-secure-file-storage.md §5)
    //
    // Each helper below collapses one of the well-known kotlin.io / JDK
    // anti-patterns (writeText, readText, BitmapFactory.decodeFile,
    // FileReader/FileWriter, deleteRecursively, Files.readAllBytes/Files.write, ...) into a
    // single call that goes through com.good.gd.file streams.
    //
    // NEVER replace these with kotlin.io or java.nio.file helpers — those
    // bypass the secure container even when the File argument is
    // com.good.gd.file.File. The kotlin.io extensions are defined on
    // java.io.File; com.good.gd.file.File resolves through java.io
    // interop, so `gdFile.writeText(...)` compiles and silently opens a
    // java.io.FileOutputStream against an Android sandbox path.
    // ------------------------------------------------------------------

    /** Container-relative path of a com.good.gd.file.File. */
    private fun gdPath(file: com.good.gd.file.File): String = file.absolutePath

    /**
     * Writes [text] to a container path as UTF-8 (or [charset]) via a GD
     * stream. Canonical replacement for `file.writeText(text)`.
     */
    @Throws(java.io.IOException::class)
    fun writeText(containerPath: String, text: String, charset: Charset = Charsets.UTF_8) {
        FileOutputStream(containerPath).use { it.write(text.toByteArray(charset)) }
    }

    /** Overload accepting a [com.good.gd.file.File] receiver. */
    @Throws(java.io.IOException::class)
    fun writeText(file: com.good.gd.file.File, text: String, charset: Charset = Charsets.UTF_8) {
        writeText(gdPath(file), text, charset)
    }

    /**
     * Reads container path as text. Returns null if the file does not
     * exist. Canonical replacement for `file.readText()`.
     */
    @Throws(java.io.IOException::class)
    fun readText(containerPath: String, charset: Charset = Charsets.UTF_8): String? {
        val gdFile = com.good.gd.file.File(containerPath)
        if (!gdFile.exists()) return null
        return FileInputStream(containerPath).use { it.readBytes().toString(charset) }
    }

    /** Overload accepting a [com.good.gd.file.File] receiver. */
    @Throws(java.io.IOException::class)
    fun readText(file: com.good.gd.file.File, charset: Charset = Charsets.UTF_8): String? =
        readText(gdPath(file), charset)

    /**
     * Appends [text] to a container path via a GD stream (append mode).
     * Canonical replacement for `file.appendText(text)`.
     */
    @Throws(java.io.IOException::class)
    fun appendText(containerPath: String, text: String, charset: Charset = Charsets.UTF_8) {
        FileOutputStream(containerPath, /* append = */ true).use {
            it.write(text.toByteArray(charset))
        }
    }

    /** Overload accepting a [com.good.gd.file.File] receiver. */
    @Throws(java.io.IOException::class)
    fun appendText(file: com.good.gd.file.File, text: String, charset: Charset = Charsets.UTF_8) {
        appendText(gdPath(file), text, charset)
    }

    /** Overload of [writeBytes] accepting a [com.good.gd.file.File]. */
    @Throws(java.io.IOException::class)
    fun writeBytes(file: com.good.gd.file.File, bytes: ByteArray) {
        writeBytes(gdPath(file), bytes)
    }

    /**
     * Reads container path as raw bytes, or null if absent. Canonical
     * replacement for `file.readBytes()` / `Files.readAllBytes(path)`.
     */
    @Throws(java.io.IOException::class)
    fun readBytesOrNull(containerPath: String): ByteArray? {
        val gdFile = com.good.gd.file.File(containerPath)
        if (!gdFile.exists()) return null
        return FileInputStream(containerPath).use { it.readBytes() }
    }

    /** Overload accepting a [com.good.gd.file.File] receiver. */
    @Throws(java.io.IOException::class)
    fun readBytesOrNull(file: com.good.gd.file.File): ByteArray? =
        readBytesOrNull(gdPath(file))

    /**
     * Decodes a Bitmap from a container path via a GD input stream.
     * Canonical replacement for `BitmapFactory.decodeFile(path)`.
     */
    fun decodeBitmap(containerPath: String, opts: BitmapFactory.Options? = null): Bitmap? {
        val gdFile = com.good.gd.file.File(containerPath)
        if (!gdFile.exists()) return null
        return try {
            FileInputStream(containerPath).use { BitmapFactory.decodeStream(it, null, opts) }
        } catch (e: java.io.IOException) {
            null
        }
    }

    /** Overload accepting a [com.good.gd.file.File] receiver. */
    fun decodeBitmap(file: com.good.gd.file.File, opts: BitmapFactory.Options? = null): Bitmap? =
        decodeBitmap(gdPath(file), opts)

    /**
     * Compresses a Bitmap to a container path via a GD output stream.
     * Canonical replacement for `bmp.compress(fmt, q, new FileOutputStream(path))`.
     */
    @Throws(java.io.IOException::class)
    fun compressBitmap(
        containerPath: String,
        bitmap: Bitmap,
        format: Bitmap.CompressFormat,
        quality: Int,
    ): Boolean = FileOutputStream(containerPath).use { bitmap.compress(format, quality, it) }

    /** Overload accepting a [com.good.gd.file.File] receiver. */
    @Throws(java.io.IOException::class)
    fun compressBitmap(
        file: com.good.gd.file.File,
        bitmap: Bitmap,
        format: Bitmap.CompressFormat,
        quality: Int,
    ): Boolean = compressBitmap(gdPath(file), bitmap, format, quality)

    /**
     * Returns a [Reader] backed by a GD input stream. Canonical
     * replacement for `new FileReader(file)` / `file.bufferedReader()`.
     * Caller closes.
     */
    @Throws(java.io.IOException::class)
    fun newReader(containerPath: String, charset: Charset = Charsets.UTF_8): Reader =
        InputStreamReader(FileInputStream(containerPath), charset)

    /** Overload accepting a [com.good.gd.file.File] receiver. */
    @Throws(java.io.IOException::class)
    fun newReader(file: com.good.gd.file.File, charset: Charset = Charsets.UTF_8): Reader =
        newReader(gdPath(file), charset)

    /**
     * Returns a [Writer] backed by a GD output stream. Canonical
     * replacement for `new FileWriter(file)` / `file.bufferedWriter()`.
     * Caller closes.
     */
    @Throws(java.io.IOException::class)
    fun newWriter(containerPath: String, charset: Charset = Charsets.UTF_8): Writer =
        OutputStreamWriter(FileOutputStream(containerPath), charset)

    /** Overload accepting a [com.good.gd.file.File] receiver. */
    @Throws(java.io.IOException::class)
    fun newWriter(file: com.good.gd.file.File, charset: Charset = Charsets.UTF_8): Writer =
        newWriter(gdPath(file), charset)

    /**
     * Copies bytes from [srcPath] to [dstPath], both container-relative,
     * via GD streams. Canonical replacement for `srcFile.copyTo(dstFile)`
     * / `Files.copy(src, dst)`.
     */
    @Throws(java.io.IOException::class)
    fun copy(srcPath: String, dstPath: String) {
        FileInputStream(srcPath).use { input ->
            FileOutputStream(dstPath).use { output ->
                val buf = ByteArray(8192)
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    output.write(buf, 0, n)
                }
            }
        }
    }

    /** Overload accepting [com.good.gd.file.File] receivers. */
    @Throws(java.io.IOException::class)
    fun copy(src: com.good.gd.file.File, dst: com.good.gd.file.File) {
        copy(gdPath(src), gdPath(dst))
    }

    /**
     * GD-aware recursive delete for secure-container paths. This is the
     * canonical replacement for kotlin.io `file.deleteRecursively()`
     * when the receiver is (or should be) `com.good.gd.file.File`.
     */
    fun deleteRecursively(containerPath: String): Boolean =
        deleteRecursively(com.good.gd.file.File(containerPath))

    /**
     * Deletes [file] and all descendants from the Dynamics container.
     * Uses children-first traversal with defensive handling around
     * `listFiles()` because GD may throw for non-existent directories.
     */
    fun deleteRecursively(file: com.good.gd.file.File): Boolean {
        if (!file.exists()) return true

        if (file.isDirectory) {
            val children: Array<java.io.File>? = try {
                file.listFiles()
            } catch (_: RuntimeException) {
                null
            }

            children?.forEach { child ->
                val gdChild = if (child is com.good.gd.file.File) {
                    child
                } else {
                    com.good.gd.file.File(child.absolutePath)
                }
                if (!deleteRecursively(gdChild)) return false
            }
        }

        return file.delete()
    }
}

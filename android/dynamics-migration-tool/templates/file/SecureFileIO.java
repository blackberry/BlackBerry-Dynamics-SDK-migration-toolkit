// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / Dynamics-GettingStarted (Apache-2.0).
// Source: FileFragment.java — see templates/_LICENSE-NOTICE.md for full attribution.
//
// HOW TO USE:
//   This is a reference showing the CORRECT call-site substitution pattern.
//   It is NOT meant to be copied wholesale — use it as the pattern when
//   migrating EACH file-I/O call site identified in your migration inventory.
//
// MIGRATION RULE — direct call-site substitution, no scaffolding:
//   BEFORE: getContext().openFileOutput(name, MODE)  →  AFTER: GDFileSystem.openFileOutput(name, MODE)
//   BEFORE: getContext().openFileInput(name)          →  AFTER: GDFileSystem.openFileInput(name)
//   BEFORE: new java.io.FileOutputStream(path)        →  AFTER: new com.good.gd.file.FileOutputStream(path)
//   BEFORE: new java.io.FileInputStream(path)         →  AFTER: new com.good.gd.file.FileInputStream(path)
//
// ANTI-PATTERN (do NOT produce this):
//   Class<?> anchor = GDFileSystem.class;   // ← dead-reference anchor; does NOT migrate I/O
//   new java.io.FileOutputStream(path);      // ← still writing to the standard sandbox
//
// All secure file access MUST happen after onAuthorized() fires.

package __APP_PACKAGE__;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

// [BB_DYNAMICS-MIGRATION] Replaced java.io.FileInputStream/FileOutputStream with Dynamics secure equivalents.
import com.good.gd.file.FileInputStream;
import com.good.gd.file.FileOutputStream;
// [BB_DYNAMICS-MIGRATION] Added GDFileSystem for Dynamics secure file I/O entry point.
import com.good.gd.file.GDFileSystem;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Reader;
import java.io.Writer;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;

/**
 * Shows the correct pattern for writing and reading a file inside the
 * Dynamics secure container.
 *
 * Key points:
 * - GDFileSystem.openFileOutput / openFileInput are the entry points for named files.
 * - com.good.gd.file.FileOutputStream / FileInputStream are used for path-based access.
 * - android.content.Context.MODE_PRIVATE constant is UNCHANGED — same value, same import.
 * - java.io.BufferedReader, InputStreamReader etc. are UNCHANGED — they wrap the GD streams.
 * - This must only be called after onAuthorized() has fired.
 */
public class SecureFileIO {

    /**
     * Writes text to a named file inside the Dynamics secure container.
     *
     * @param filename  File name (relative, no path separator). Stored in the container root.
     * @param content   Content to write.
     * @throws IOException on write failure.
     */
    public static void writeFile(String filename, String content) throws IOException {
        // [BB_DYNAMICS-MIGRATION] Replaced context.openFileOutput() with GDFileSystem.openFileOutput()
        // for Dynamics encrypted storage. Context.MODE_PRIVATE constant is unchanged.
        try (FileOutputStream outputStream =
                     GDFileSystem.openFileOutput(filename, Context.MODE_PRIVATE)) {
            outputStream.write(content.getBytes());
        }
    }

    /**
     * Reads text from a named file inside the Dynamics secure container.
     *
     * @param filename  File name (same value passed to writeFile).
     * @return File contents, or null if the file does not exist.
     * @throws IOException on read failure (other than file-not-found).
     */
    public static String readFile(String filename) throws IOException {
        // [BB_DYNAMICS-MIGRATION] Replaced context.openFileInput() with GDFileSystem.openFileInput()
        // for Dynamics encrypted storage.
        FileInputStream raw = GDFileSystem.openFileInput(filename);
        if (raw == null) {
            return null;
        }
        try (FileInputStream inputStream = raw;
             BufferedReader bufferedReader =
                     new BufferedReader(new InputStreamReader(inputStream))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = bufferedReader.readLine()) != null) {
                sb.append(line);
            }
            return sb.toString();
        }
    }

    /**
     * Writes raw bytes to a path inside the Dynamics secure container.
     * Use this form when you need a path-based FileOutputStream (e.g., for a subdirectory).
     *
     * @param containerPath  Path relative to the container root (e.g., "media/photos/img.jpg").
     * @param bytes          Bytes to write.
     * @throws IOException on write failure.
     */
    public static void writeBytes(String containerPath, byte[] bytes) throws IOException {
        // [BB_DYNAMICS-MIGRATION] Replaced new java.io.FileOutputStream(path) with
        // new com.good.gd.file.FileOutputStream(path) for Dynamics container path access.
        try (FileOutputStream out = new FileOutputStream(containerPath)) {
            out.write(bytes);
        }
    }

    /**
     * Reads raw bytes from a path inside the Dynamics secure container.
     *
     * @param containerPath  Path relative to the container root.
     * @return Bytes read.
     * @throws IOException if the file does not exist or cannot be read.
     */
    public static byte[] readBytes(String containerPath) throws IOException {
        // [BB_DYNAMICS-MIGRATION] Replaced new java.io.FileInputStream(path) with
        // new com.good.gd.file.FileInputStream(path) for Dynamics container path access.
        try (FileInputStream in = new FileInputStream(containerPath)) {
            return in.readAllBytes();
        }
    }

    // ----------------------------------------------------------------------
    // Stream-layer closure helpers (see steering/40-secure-file-storage.md §5)
    //
    // Each helper below collapses one of the well-known kotlin.io / JDK
    // anti-patterns (writeText, readText, BitmapFactory.decodeFile,
    // FileReader/FileWriter, deleteRecursively, Files.readAllBytes/Files.write, ...) into a
    // single call routed through com.good.gd.file streams.
    //
    // NEVER replace these with kotlin.io or java.nio.file helpers — those
    // bypass the secure container even when the File argument is
    // com.good.gd.file.File. java.nio.file.Files.* and Kotlin extensions
    // on java.io.File compile against the GD File type via java.io
    // interop and silently open a java.io.FileOutputStream against an
    // Android sandbox path.
    // ----------------------------------------------------------------------

    private static String gdPath(com.good.gd.file.File file) {
        return file.getAbsolutePath();
    }

    /** Canonical replacement for {@code file.writeText(text)} / {@code Files.writeString(path, s)}. */
    public static void writeText(String containerPath, String text, Charset charset) throws IOException {
        try (FileOutputStream out = new FileOutputStream(containerPath)) {
            out.write(text.getBytes(charset));
        }
    }

    public static void writeText(String containerPath, String text) throws IOException {
        writeText(containerPath, text, StandardCharsets.UTF_8);
    }

    public static void writeText(com.good.gd.file.File file, String text, Charset charset) throws IOException {
        writeText(gdPath(file), text, charset);
    }

    public static void writeText(com.good.gd.file.File file, String text) throws IOException {
        writeText(gdPath(file), text, StandardCharsets.UTF_8);
    }

    /** Canonical replacement for {@code file.readText()} / {@code Files.readString(path)}. Returns null if absent. */
    public static String readText(String containerPath, Charset charset) throws IOException {
        com.good.gd.file.File gdFile = new com.good.gd.file.File(containerPath);
        if (!gdFile.exists()) {
            return null;
        }
        try (FileInputStream in = new FileInputStream(containerPath)) {
            return new String(in.readAllBytes(), charset);
        }
    }

    public static String readText(String containerPath) throws IOException {
        return readText(containerPath, StandardCharsets.UTF_8);
    }

    public static String readText(com.good.gd.file.File file, Charset charset) throws IOException {
        return readText(gdPath(file), charset);
    }

    public static String readText(com.good.gd.file.File file) throws IOException {
        return readText(gdPath(file), StandardCharsets.UTF_8);
    }

    /** Canonical replacement for {@code file.appendText(text)}. */
    public static void appendText(String containerPath, String text, Charset charset) throws IOException {
        try (FileOutputStream out = new FileOutputStream(containerPath, /* append = */ true)) {
            out.write(text.getBytes(charset));
        }
    }

    public static void appendText(String containerPath, String text) throws IOException {
        appendText(containerPath, text, StandardCharsets.UTF_8);
    }

    public static void appendText(com.good.gd.file.File file, String text, Charset charset) throws IOException {
        appendText(gdPath(file), text, charset);
    }

    public static void appendText(com.good.gd.file.File file, String text) throws IOException {
        appendText(gdPath(file), text, StandardCharsets.UTF_8);
    }

    public static void writeBytes(com.good.gd.file.File file, byte[] bytes) throws IOException {
        writeBytes(gdPath(file), bytes);
    }

    /** Returns null if the file is absent. Canonical replacement for {@code Files.readAllBytes(path)}. */
    public static byte[] readBytesOrNull(String containerPath) throws IOException {
        com.good.gd.file.File gdFile = new com.good.gd.file.File(containerPath);
        if (!gdFile.exists()) {
            return null;
        }
        try (FileInputStream in = new FileInputStream(containerPath)) {
            return in.readAllBytes();
        }
    }

    public static byte[] readBytesOrNull(com.good.gd.file.File file) throws IOException {
        return readBytesOrNull(gdPath(file));
    }

    /** Canonical replacement for {@code BitmapFactory.decodeFile(path)}. */
    public static Bitmap decodeBitmap(String containerPath, BitmapFactory.Options opts) {
        com.good.gd.file.File gdFile = new com.good.gd.file.File(containerPath);
        if (!gdFile.exists()) {
            return null;
        }
        try (FileInputStream in = new FileInputStream(containerPath)) {
            return BitmapFactory.decodeStream(in, null, opts);
        } catch (IOException e) {
            return null;
        }
    }

    public static Bitmap decodeBitmap(String containerPath) {
        return decodeBitmap(containerPath, null);
    }

    public static Bitmap decodeBitmap(com.good.gd.file.File file, BitmapFactory.Options opts) {
        return decodeBitmap(gdPath(file), opts);
    }

    public static Bitmap decodeBitmap(com.good.gd.file.File file) {
        return decodeBitmap(gdPath(file), null);
    }

    /** Canonical replacement for {@code bmp.compress(fmt, q, new FileOutputStream(path))}. */
    public static boolean compressBitmap(
            String containerPath,
            Bitmap bitmap,
            Bitmap.CompressFormat format,
            int quality) throws IOException {
        try (FileOutputStream out = new FileOutputStream(containerPath)) {
            return bitmap.compress(format, quality, out);
        }
    }

    public static boolean compressBitmap(
            com.good.gd.file.File file,
            Bitmap bitmap,
            Bitmap.CompressFormat format,
            int quality) throws IOException {
        return compressBitmap(gdPath(file), bitmap, format, quality);
    }

    /** Canonical replacement for {@code new FileReader(file)}. Caller closes. */
    public static Reader newReader(String containerPath, Charset charset) throws IOException {
        return new InputStreamReader(new FileInputStream(containerPath), charset);
    }

    public static Reader newReader(String containerPath) throws IOException {
        return newReader(containerPath, StandardCharsets.UTF_8);
    }

    public static Reader newReader(com.good.gd.file.File file, Charset charset) throws IOException {
        return newReader(gdPath(file), charset);
    }

    public static Reader newReader(com.good.gd.file.File file) throws IOException {
        return newReader(gdPath(file), StandardCharsets.UTF_8);
    }

    /** Canonical replacement for {@code new FileWriter(file)}. Caller closes. */
    public static Writer newWriter(String containerPath, Charset charset) throws IOException {
        return new OutputStreamWriter(new FileOutputStream(containerPath), charset);
    }

    public static Writer newWriter(String containerPath) throws IOException {
        return newWriter(containerPath, StandardCharsets.UTF_8);
    }

    public static Writer newWriter(com.good.gd.file.File file, Charset charset) throws IOException {
        return newWriter(gdPath(file), charset);
    }

    public static Writer newWriter(com.good.gd.file.File file) throws IOException {
        return newWriter(gdPath(file), StandardCharsets.UTF_8);
    }

    /** Canonical replacement for {@code srcFile.copyTo(dstFile)} / {@code Files.copy(src, dst)}. */
    public static void copy(String srcPath, String dstPath) throws IOException {
        try (FileInputStream in = new FileInputStream(srcPath);
             FileOutputStream out = new FileOutputStream(dstPath)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
        }
    }

    public static void copy(com.good.gd.file.File src, com.good.gd.file.File dst) throws IOException {
        copy(gdPath(src), gdPath(dst));
    }

    /**
     * GD-aware recursive delete for secure-container paths.
     * Canonical replacement for Kotlin {@code file.deleteRecursively()}.
     */
    public static boolean deleteRecursively(String containerPath) {
        return deleteRecursively(new com.good.gd.file.File(containerPath));
    }

    /**
     * Deletes {@code file} and descendants from the Dynamics container.
     * Uses children-first traversal and defensively handles listFiles()
     * because GD may throw on non-existent directory paths.
     */
    public static boolean deleteRecursively(com.good.gd.file.File file) {
        if (!file.exists()) {
            return true;
        }

        if (file.isDirectory()) {
            java.io.File[] children;
            try {
                children = file.listFiles();
            } catch (RuntimeException ex) {
                children = null;
            }

            if (children != null) {
                for (java.io.File child : children) {
                    com.good.gd.file.File gdChild =
                            (child instanceof com.good.gd.file.File)
                                    ? (com.good.gd.file.File) child
                                    : new com.good.gd.file.File(child.getAbsolutePath());
                    if (!deleteRecursively(gdChild)) {
                        return false;
                    }
                }
            }
        }

        return file.delete();
    }
}

// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Kit-authored (Apache-2.0). See templates/_LICENSE-NOTICE.md.
//
// Class C small-media capture (steering/41-secure-media.md, prompt 05c):
//   MemoryFile (seekable RAM FD) → MediaRecorder.setOutputFile(fd)
//   On stop, copy bytes through com.good.gd.file.FileOutputStream.
//
// MUST run the GD copy from an authorized Activity (runOnAuthorized),
// never from Service.onCreate — GD File throws GDNotAuthorizedError there.
//
// Do NOT use ParcelFileDescriptor.createPipe() for MPEG-4 / 3GP / WEBM
// (or omitted setOutputFormat). Sequential AAC_ADTS / AMR may use a pipe.
// Do NOT stage in getCacheDir() / getFilesDir() / createTempFile().

package __APP_PACKAGE__

import android.media.MediaRecorder
import android.os.MemoryFile
import com.good.gd.file.FileOutputStream
import java.io.Closeable
import java.io.FileDescriptor
import java.io.IOException

/**
 * Seekable in-memory capture buffer that MediaRecorder can mux into,
 * then persist into the Dynamics container.
 *
 * Default cap is 32 MiB (steering/41). For large video use
 * [android.os.storage.StorageManager.openProxyFileDescriptor] backed by
 * [com.good.gd.file.RandomAccessFile] instead of holding the clip in RAM.
 */
object SeekableGdMediaCapture {

    const val DEFAULT_CAP_BYTES: Int = 32 * 1024 * 1024

    class Session internal constructor(
        private val memoryFile: MemoryFile,
        val fileDescriptor: FileDescriptor,
    ) : Closeable {

        /**
         * Copy the MemoryFile contents into the Dynamics container.
         * Call from an authorized Activity after [MediaRecorder.stop].
         */
        @Throws(IOException::class)
        fun persistToContainer(containerPath: String) {
            memoryFile.inputStream.use { input ->
                FileOutputStream(containerPath).use { output ->
                    input.copyTo(output)
                }
            }
        }

        override fun close() {
            memoryFile.close()
        }
    }

    @Throws(IOException::class)
    fun open(label: String = "gd-media-capture", capBytes: Int = DEFAULT_CAP_BYTES): Session {
        val memoryFile = MemoryFile(label, capBytes)
        return Session(memoryFile, fileDescriptorOf(memoryFile))
    }

    /**
     * Hidden [MemoryFile.getFileDescriptor] is the seekable ashmem FD.
     * Public alternative on API 27+: [android.os.SharedMemory.create].
     */
    @Throws(IOException::class)
    fun fileDescriptorOf(memoryFile: MemoryFile): FileDescriptor {
        return try {
            val method = MemoryFile::class.java.getDeclaredMethod("getFileDescriptor")
            method.isAccessible = true
            method.invoke(memoryFile) as FileDescriptor
        } catch (e: ReflectiveOperationException) {
            throw IOException(
                "Seekable MemoryFile FD is unavailable; use SharedMemory (API 27+) " +
                    "or StorageManager.openProxyFileDescriptor",
                e,
            )
        }
    }

    /** Bind [MediaRecorder] to this session's seekable FD (not a pipe, not a GD path). */
    @Throws(IOException::class)
    fun bindRecorder(recorder: MediaRecorder, session: Session) {
        recorder.setOutputFile(session.fileDescriptor)
    }
}

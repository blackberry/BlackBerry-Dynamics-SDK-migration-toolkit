// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Kit-authored (Apache-2.0). See templates/_LICENSE-NOTICE.md.
//
// Class C small-media playback (steering/41-secure-media.md, prompt 05c):
//   GD FileInputStream → MemoryFile → MediaPlayer.setDataSource(fd)
//
// MUST load GD bytes from an authorized Activity (runOnAuthorized),
// never from Service.onCreate.
//
// Do NOT pass gdFile.path / absolutePath to setDataSource or setVideoPath.
// Do NOT stage in getCacheDir() / getFilesDir() / createTempFile().

package __APP_PACKAGE__

import android.media.MediaPlayer
import android.os.MemoryFile
import com.good.gd.file.FileInputStream
import java.io.Closeable
import java.io.FileDescriptor
import java.io.IOException

/**
 * Loads a container object into a seekable MemoryFile so MediaPlayer /
 * MediaMetadataRetriever can use a kernel FD.
 *
 * Default cap is 32 MiB. For large video use a proxy FD backed by
 * [com.good.gd.file.RandomAccessFile] so playback can seek without RAM-holding
 * the whole clip.
 */
object SeekableGdMediaPlayback {

    const val DEFAULT_CAP_BYTES: Int = 32 * 1024 * 1024

    class Session internal constructor(
        private val memoryFile: MemoryFile,
        val fileDescriptor: FileDescriptor,
    ) : Closeable {

        @Throws(IOException::class)
        fun bindPlayer(player: MediaPlayer) {
            player.setDataSource(fileDescriptor)
        }

        override fun close() {
            memoryFile.close()
        }
    }

    /**
     * Read [containerPath] from the Dynamics store into a MemoryFile.
     * Call from an authorized Activity.
     */
    @Throws(IOException::class)
    fun loadFromContainer(
        containerPath: String,
        capBytes: Int = DEFAULT_CAP_BYTES,
        label: String = "gd-media-playback",
    ): Session {
        val memoryFile = MemoryFile(label, capBytes)
        FileInputStream(containerPath).use { input ->
            memoryFile.outputStream.use { output ->
                input.copyTo(output)
            }
        }
        return Session(memoryFile, SeekableGdMediaCapture.fileDescriptorOf(memoryFile))
    }
}

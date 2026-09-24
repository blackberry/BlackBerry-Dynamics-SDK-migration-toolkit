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

package __APP_PACKAGE__;

import android.media.MediaPlayer;
import android.os.MemoryFile;

import com.good.gd.file.FileInputStream;

import java.io.Closeable;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.OutputStream;

/**
 * Loads a container object into a seekable MemoryFile so MediaPlayer /
 * MediaMetadataRetriever can use a kernel FD.
 *
 * Default cap is 32 MiB. For large video use a proxy FD backed by
 * {@code com.good.gd.file.RandomAccessFile} so playback can seek without
 * RAM-holding the whole clip.
 */
public final class SeekableGdMediaPlayback {

    public static final int DEFAULT_CAP_BYTES = 32 * 1024 * 1024;

    private SeekableGdMediaPlayback() {}

    public static final class Session implements Closeable {
        private final MemoryFile memoryFile;
        public final FileDescriptor fileDescriptor;

        Session(MemoryFile memoryFile, FileDescriptor fileDescriptor) {
            this.memoryFile = memoryFile;
            this.fileDescriptor = fileDescriptor;
        }

        public void bindPlayer(MediaPlayer player) throws IOException {
            player.setDataSource(fileDescriptor);
        }

        @Override
        public void close() {
            memoryFile.close();
        }
    }

    /**
     * Read {@code containerPath} from the Dynamics store into a MemoryFile.
     * Call from an authorized Activity.
     */
    public static Session loadFromContainer(String containerPath) throws IOException {
        return loadFromContainer(containerPath, DEFAULT_CAP_BYTES, "gd-media-playback");
    }

    public static Session loadFromContainer(String containerPath, int capBytes, String label)
            throws IOException {
        MemoryFile memoryFile = new MemoryFile(label, capBytes);
        try (FileInputStream input = new FileInputStream(containerPath);
                OutputStream output = memoryFile.getOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = input.read(buf)) >= 0) {
                output.write(buf, 0, n);
            }
        }
        return new Session(memoryFile, SeekableGdMediaCapture.fileDescriptorOf(memoryFile));
    }
}

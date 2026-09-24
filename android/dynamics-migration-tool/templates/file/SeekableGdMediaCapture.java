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

package __APP_PACKAGE__;

import android.media.MediaRecorder;
import android.os.MemoryFile;

import com.good.gd.file.FileOutputStream;

import java.io.Closeable;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Method;

/**
 * Seekable in-memory capture buffer that MediaRecorder can mux into,
 * then persist into the Dynamics container.
 *
 * Default cap is 32 MiB (steering/41). For large video use
 * {@code StorageManager.openProxyFileDescriptor} backed by
 * {@code com.good.gd.file.RandomAccessFile} instead of holding the clip in RAM.
 */
public final class SeekableGdMediaCapture {

    public static final int DEFAULT_CAP_BYTES = 32 * 1024 * 1024;

    private SeekableGdMediaCapture() {}

    public static final class Session implements Closeable {
        private final MemoryFile memoryFile;
        public final FileDescriptor fileDescriptor;

        Session(MemoryFile memoryFile, FileDescriptor fileDescriptor) {
            this.memoryFile = memoryFile;
            this.fileDescriptor = fileDescriptor;
        }

        /**
         * Copy the MemoryFile contents into the Dynamics container.
         * Call from an authorized Activity after {@link MediaRecorder#stop()}.
         */
        public void persistToContainer(String containerPath) throws IOException {
            try (InputStream input = memoryFile.getInputStream();
                    FileOutputStream output = new FileOutputStream(containerPath)) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = input.read(buf)) >= 0) {
                    output.write(buf, 0, n);
                }
            }
        }

        @Override
        public void close() {
            memoryFile.close();
        }
    }

    public static Session open() throws IOException {
        return open("gd-media-capture", DEFAULT_CAP_BYTES);
    }

    public static Session open(String label, int capBytes) throws IOException {
        MemoryFile memoryFile = new MemoryFile(label, capBytes);
        return new Session(memoryFile, fileDescriptorOf(memoryFile));
    }

    /**
     * Hidden {@code MemoryFile.getFileDescriptor()} is the seekable ashmem FD.
     * Public alternative on API 27+: {@code SharedMemory.create}.
     */
    public static FileDescriptor fileDescriptorOf(MemoryFile memoryFile) throws IOException {
        try {
            Method method = MemoryFile.class.getDeclaredMethod("getFileDescriptor");
            method.setAccessible(true);
            Object result = method.invoke(memoryFile);
            if (result instanceof FileDescriptor) {
                return (FileDescriptor) result;
            }
            throw new IOException("MemoryFile.getFileDescriptor returned unexpected type");
        } catch (ReflectiveOperationException e) {
            throw new IOException(
                    "Seekable MemoryFile FD is unavailable; use SharedMemory (API 27+) "
                            + "or StorageManager.openProxyFileDescriptor",
                    e);
        }
    }

    /** Bind {@link MediaRecorder} to this session's seekable FD (not a pipe, not a GD path). */
    public static void bindRecorder(MediaRecorder recorder, Session session) throws IOException {
        recorder.setOutputFile(session.fileDescriptor);
    }
}

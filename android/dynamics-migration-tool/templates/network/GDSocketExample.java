// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / Dynamics-GettingStarted (Apache-2.0).
// Source: SocketFragment.java — see templates/_LICENSE-NOTICE.md for full attribution.
//
// MIGRATION RULE — import and construction:
//   REMOVE: import java.net.Socket;
//   REMOVE: import javax.net.ssl.SSLSocket;
//   ADD:    import com.good.gd.net.GDSocket;
//
// WRONG package path:
//   import com.good.gd.net.ssl.GDSocket;   ← WRONG — validator will catch this
//
// LIFECYCLE: Use socket.close(), never socket.disconnect() (GDSocket has no disconnect()).

package __APP_PACKAGE__;

// [BB_DYNAMICS-MIGRATION] Replaced java.net.Socket with com.good.gd.net.GDSocket.
import com.good.gd.net.GDSocket;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Shows the correct pattern for socket I/O using GDSocket.
 * All connections are routed through the Dynamics secure container.
 * Must be called after onAuthorized() fires and off the main thread.
 */
public final class GDSocketExample {

    /**
     * Opens a GDSocket connection, sends a request string, and returns up to
     * maxBytes bytes of the response.
     *
     * @param host         Remote host.
     * @param port         Remote port.
     * @param timeoutMs    Connection timeout in milliseconds.
     * @param requestBytes Bytes to send after connecting.
     * @param maxBytes     Maximum response bytes to read.
     * @return Response bytes.
     * @throws IOException on connect or I/O failure.
     */
    public static byte[] sendAndReceive(
            String host, int port, int timeoutMs,
            byte[] requestBytes, int maxBytes) throws IOException {

        // [BB_DYNAMICS-MIGRATION] Replaced new java.net.Socket() with new GDSocket().
        // GDSocket constructor takes no args; use connect(host, port, timeout) to open.
        GDSocket socket = new GDSocket();
        InputStream in = null;
        OutputStream out = null;

        try {
            socket.connect(host, port, timeoutMs);

            in  = socket.getInputStream();
            out = socket.getOutputStream();

            out.write(requestBytes);

            ByteArrayOutputStream buffer = new ByteArrayOutputStream(maxBytes);
            byte[] chunk = new byte[1024];
            int bytesRead;
            while ((bytesRead = in.read(chunk)) != -1) {
                buffer.write(chunk, 0, bytesRead);
                if (buffer.size() >= maxBytes) break;
            }
            return buffer.toByteArray();
        } finally {
            if (in  != null) { try { in.close();  } catch (IOException ignored) {} }
            if (out != null) { try { out.close(); } catch (IOException ignored) {} }
            // [BB_DYNAMICS-MIGRATION] Use socket.close(), NOT socket.disconnect() — GDSocket has no disconnect().
            socket.close();
        }
    }
}

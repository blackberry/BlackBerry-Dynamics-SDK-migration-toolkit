// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / Dynamics-GettingStarted (Apache-2.0).
// Source: HttpFragment.java — see templates/_LICENSE-NOTICE.md for full attribution.
//
// WHEN TO USE THIS TEMPLATE:
//   Your app currently uses java.net.HttpURLConnection / java.net.URL.openConnection().
//   Replace that code with GDHttpClient (Apache HTTP 4.x style API).
//   If your app already uses OkHttp, use OkHttpDynamicsClient instead.
//
// MIGRATION RULE — import and construction:
//   REMOVE: import java.net.HttpURLConnection;
//   REMOVE: import java.net.URL;
//   ADD:    import com.good.gd.apache.http.HttpResponse;
//   ADD:    import com.good.gd.apache.http.client.methods.HttpGet; (or HttpPost, etc.)
//   ADD:    import com.good.gd.net.GDHttpClient;
//
// WRONG package paths (validator will catch these):
//   import org.apache.http.*           ← WRONG — must be com.good.gd.apache.http.*
//   import org.apache.http.client.*    ← WRONG

package __APP_PACKAGE__;

// [BB_DYNAMICS-MIGRATION] Replaced java.net.HttpURLConnection + URL with Dynamics GDHttpClient.
import com.good.gd.apache.http.HttpResponse;
import com.good.gd.apache.http.client.methods.HttpGet;
import com.good.gd.net.GDHttpClient;

import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.Reader;

/**
 * Shows the correct pattern for HTTP GET using GDHttpClient.
 * All requests are routed through the Dynamics secure container.
 * Must be called after onAuthorized() fires.
 */
public final class GDHttpClientExample {

    /**
     * Performs an HTTP GET request and returns the response body as a String.
     * Must be called off the main thread.
     *
     * @param url Full URL string (http:// or https://).
     * @return Response body, truncated to maxChars characters.
     * @throws IOException on network failure.
     */
    public static String get(String url, int maxChars) throws IOException {
        // [BB_DYNAMICS-MIGRATION] Replaced new URL(url).openConnection() with GDHttpClient.execute().
        GDHttpClient httpClient = new GDHttpClient();
        try {
            HttpGet request = new HttpGet(url);
            HttpResponse response = httpClient.execute(request);
            InputStream stream = response.getEntity().getContent();
            try {
                Reader reader = new InputStreamReader(stream, "UTF-8");
                char[] buffer = new char[maxChars];
                int read = reader.read(buffer);
                return read > 0 ? new String(buffer, 0, read) : "";
            } finally {
                stream.close();
            }
        } finally {
            // [BB_DYNAMICS-MIGRATION] GDHttpClient docs: always shutdown the connection manager before
            // releasing the client (sockets, threads, SSL verification state).
            httpClient.getConnectionManager().shutdown();
        }
    }
}

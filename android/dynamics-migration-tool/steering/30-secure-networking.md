# Steering: Secure Networking with BlackBerry Dynamics

Dynamics enforces secure networking policies.
You must analyze and adapt existing network usage accordingly.

---

## Analysis Required

You must locate:
- OkHttp usage
- Retrofit usage
- HttpURLConnection usage
- Socket usage
- WebView network access
- Any custom networking layers

---

## Decision Framework

For each networking path:
- Supported Dynamics path (prove exact routing)
- Supported with configuration changes
- Not supported or unproven → Manual intervention required

Explain your reasoning clearly.

Treat these as the supported Dynamics-compatible paths in this toolkit:

- `GDHttpClient`
- `GDSocket`
- OkHttp via `BBCustomInterceptor` (and `BBCookieJar` as needed)
- Retrofit only when wired to a proven interceptor-wired `OkHttpClient`
- BlackBerry WebSocket project based on `GDSocket`

### TLS 1.3 (SDK 15.1)

Dynamics 15.1 supports **TLS 1.3 with AES-GCM cipher suites**. AES-CCM
is not supported. This is a runtime stack change, not an app API swap.
Do not invent TLS configuration types. After migration, regress
`GDHttpClient`, `GDSocket`, and OkHttp+`BBCustomInterceptor` against
enterprise endpoints that negotiate TLS 1.3, TLS 1.2 fallback, mutual
TLS, and proxies.

Treat these as unsupported/unproven until replaced or proven routed through the
supported list above:

- Ktor
- Cronet
- gRPC
- `DownloadManager`
- arbitrary WebSocket libraries
- `DatagramSocket` / raw `SSLSocket` primitives
- dependency-owned or generated client stacks with unproven routing

---

## HTTP Migration: HttpURLConnection → GDHttpClient

### Import Changes

```java
// REMOVE these imports
import java.net.HttpURLConnection;
import java.net.URL;

// ADD these imports
import com.good.gd.net.GDHttpClient;
import com.good.gd.apache.http.HttpResponse;
import com.good.gd.apache.http.client.methods.HttpGet;
import com.good.gd.apache.http.client.methods.HttpPost;
```

### Code Migration Pattern

```java
// OLD: HttpURLConnection
URL url = new URL(urlString);
HttpURLConnection conn = (HttpURLConnection) url.openConnection();
conn.setRequestMethod("GET");
InputStream stream = conn.getInputStream();

// NEW: GDHttpClient (Apache HTTP style)
GDHttpClient httpclient = new GDHttpClient();
HttpGet request = new HttpGet(urlString);
HttpResponse response = httpclient.execute(request);
InputStream stream = response.getEntity().getContent();
```

### POST Request Example

```java
GDHttpClient httpclient = new GDHttpClient();
HttpPost request = new HttpPost(urlString);
request.setEntity(new StringEntity(jsonBody));
request.setHeader("Content-Type", "application/json");
HttpResponse response = httpclient.execute(request);
```

### Important Notes

- GDHttpClient uses Apache HTTP client API style, not HttpURLConnection
- References to HttpURLConnection in Javadoc comments are acceptable (validation will flag but can be ignored)
- All HTTP traffic goes through Dynamics secure tunnel
- **Do not import `org.apache.http.*`** for migrated code paths — use
  `com.good.gd.apache.http.*` classes provided by the Dynamics SDK.

---

## Socket Migration: java.net.Socket → GDSocket

### Import Changes

```java
// REMOVE this import
import java.net.Socket;

// ADD this import
import com.good.gd.net.GDSocket;
```

### Code Migration Pattern

```java
// OLD: java.net.Socket
Socket socket = new Socket(host, port);
InputStream in = socket.getInputStream();
OutputStream out = socket.getOutputStream();

// NEW: GDSocket
GDSocket socket = new GDSocket();
socket.connect(host, port, timeoutMs);  // e.g., socket.connect("example.com", 80, 1000);
InputStream in = socket.getInputStream();
OutputStream out = socket.getOutputStream();
```

### Complete Example

```java
GDSocket socket = null;
InputStream inputStream = null;
OutputStream outputStream = null;

try {
    socket = new GDSocket();
    socket.connect("your-server.example.com", 80, 1000);
    
    inputStream = socket.getInputStream();
    outputStream = socket.getOutputStream();
    
    // Write request
    String request = "GET / HTTP/1.1\r\nHost: your-server.example.com\r\n\r\n";
    outputStream.write(request.getBytes());
    
    // Read response
    byte[] buffer = new byte[1024];
    int bytesRead = inputStream.read(buffer);
    String response = new String(buffer, 0, bytesRead);
    
} finally {
    if (inputStream != null) inputStream.close();
    if (outputStream != null) outputStream.close();
    if (socket != null) socket.close();
}
```

### Key Differences

- GDSocket constructor takes no arguments
- Connection is established via `connect(host, port, timeout)` method
- Stream APIs remain the same after connection
- Use `socket.close()` for cleanup
- **Do not use `com.good.gd.net.ssl.GDSocket`** (wrong package)
- **Do not use `socket.disconnect()`** (not the expected cleanup pattern)

---

## CRITICAL: Secure Networking Requires an Unlocked Container

Dynamics secure networking APIs (`GDHttpClient`, `GDSocket`) route traffic
through the Dynamics infrastructure. This infrastructure is only available
after the encrypted container is unlocked via `onAuthorized()`.

This means:
- On **first launch**, the SDK must complete activation (provisioning with
  UEM) before any network request can be made through Dynamics APIs.
- On **subsequent launches**, the container must be unlocked (user
  authenticates) before network access is available.
- Any call to `GDHttpClient.execute()` or `GDSocket.connect()` before the
  container is unlocked will throw `GDNotAuthorizedError` and crash the app.

**Fix**: Move all network initialization and requests into `onAuthorized()`
or a method called from it. See `20-auth-initialization.md` for the full
two-phase initialization pattern and container lifecycle details.

---

## OkHttp Migration: Using BBCustomInterceptor

If the app uses OkHttp, the Dynamics SDK provides `BBCustomInterceptor`
and `BBCookieJar` to route OkHttp traffic through the Dynamics secure
communication system. This is the preferred approach for OkHttp-based apps.

### Common Mistake: Wrong Import Path

> **Do NOT use `com.blackberry.bbhttp.BBCustomInterceptor`** — that package
> does not exist and will cause an immediate build failure.
>
> The correct import is:
> ```java
> import com.blackberry.okhttpsupport.interceptor.BBCustomInterceptor;
> ```
>
> The class lives in the `com.blackberry.okhttpsupport.interceptor` package,
> not in any `bbhttp` package. This is a common hallucination by AI agents
> and a frequent cause of build failures during migration.

### Gradle Dependency

No additional dependency is needed — OkHttp support is included in the
main Dynamics SDK (uses OkHttp 4.9.1 internally).

### Code Migration Pattern

Use `dynamics-migration-tool/templates/network/OkHttpDynamicsClient.java` (or `.kt`) as
your reference. The template is derived from the official BlackBerry Dynamics SDK sample
`BlackBerry-Dynamics-Android-Samples / 2-Features / OkHttpBD / MainActivity.java`
(Apache-2.0).

**Canonical wiring (source: OkHttpBD sample):**

```java
import com.blackberry.okhttpsupport.interceptor.BBCustomInterceptor;

// [BB_DYNAMICS-MIGRATION] OkHttpClient routes through Dynamics secure transport via BBCustomInterceptor.
BBCustomInterceptor bbCustomInterceptor = new BBCustomInterceptor();
OkHttpClient client = new OkHttpClient().newBuilder()
        // App-side interceptors (logging, auth headers) go HERE, BEFORE bbCustomInterceptor.
        .addInterceptor(bbCustomInterceptor)   // Dynamics transport — must be last.
        .build();
```

**Interceptor ordering is mandatory**: `BBCustomInterceptor` must be the **last** interceptor
in the chain. App interceptors (auth headers, logging, retry) must come before it. The OkHttpBD
sample adds the app's `ReactiveBasicAuthInterceptor` before `bbCustomInterceptor` — follow
the same pattern.

**Interceptor type is mandatory**: `BBCustomInterceptor` must be attached with
`addInterceptor(...)`, not `addNetworkInterceptor(...)`.

**`BBCookieJar` is optional**: Add `.cookieJar(new BBCookieJar())` only when your app
relies on cookie-based session management that the Dynamics container should manage.
Most apps do not need it. The public OkHttpBD sample does not use it.

```java
import com.blackberry.okhttpsupport.cookie.BBCookieJar;

// Optional — only when the app needs Dynamics-managed cookie sessions.
OkHttpClient client = new OkHttpClient().newBuilder()
        .addInterceptor(bbCustomInterceptor)
        .cookieJar(new BBCookieJar())
        .build();
```

### OkHttp Limitations Under Dynamics

| Feature | Status |
|---------|--------|
| Caching | Not supported |
| Proxy | Supported via UEM config (PAC file or manual). Do not set proxy via `OkHttpClient.proxy()`. Per-user proxy credentials not supported. |
| Authentication | Kerberos PKINIT/KCD supported. NTLM via third-party interceptors. SPNEGO not supported. User-supplied credentials via `BBCustomAuthenticator`. |
| Timeouts | Only connection timeouts supported. Read/write timeouts not configurable. |
| Certificate pinning / trust controls | SDK exposes trust-downgrade methods (for troubleshooting/testing), but enterprise migration policy forbids their use in production migrations. |

### Retrofit

If the app uses Retrofit, it builds on OkHttp. Add `BBCustomInterceptor`
to the underlying `OkHttpClient` and Retrofit will automatically use
Dynamics secure networking:

```java
OkHttpClient client = new OkHttpClient.Builder()
    .addInterceptor(new BBCustomInterceptor())
    .cookieJar(new BBCookieJar())
    .build();

Retrofit retrofit = new Retrofit.Builder()
    .baseUrl("https://api.example.com/")
    .client(client)
    .build();
```

**Note**: Import `BBCustomInterceptor` from `com.blackberry.okhttpsupport.interceptor`
and `BBCookieJar` from `com.blackberry.okhttpsupport.cookie`.

---

## Preferred Approach

- If OkHttp/Retrofit is present, use `BBCustomInterceptor` (preferred)
- For raw HTTP without OkHttp, use `GDHttpClient`
- For raw TCP sockets, use `GDSocket`
- Avoid introducing new networking libraries unless required
- **All secure network access MUST happen after `onAuthorized()` fires**
- Secondary activities launched after authorization can make network
  requests normally (the container is already unlocked by then)

When an unsupported/unproven stack remains, mark it as
`Manual intervention required` and keep it blocking for release readiness
until it is replaced, removed, or proven routed through a supported path.

---

## Output

- Table of networking paths and compatibility
- Summary of changes made
- Any known limitations under Dynamics policy

## Enterprise Hardening Addendum (Transport)

Hard failures in this kit:

- Explicit trust bypass calls: `disableHostVerification()`, `disablePeerVerification()`, `trustAllCerts`, and always-allow host verifier patterns
- Manifest cleartext traffic enablement
- `network_security_config` cleartext enablement (`cleartextTrafficPermitted="true"`)

Review warnings (manual decision required):

- Generic TLS customization primitives (`X509TrustManager`, `HostnameVerifier`, `sslSocketFactory`, `CertificatePinner`) because these may be legitimate in some non-bypass configurations.
- `network_security_config` user trust anchors (`certificates src="user"`) because this can be legitimate in managed PKI setups but must be explicitly justified.

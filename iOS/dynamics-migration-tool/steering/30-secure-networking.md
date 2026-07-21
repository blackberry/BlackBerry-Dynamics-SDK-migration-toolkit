# Steering: Secure Networking (iOS)

The Dynamics SDK provides secure networking that routes traffic through the
Dynamics infrastructure, enabling access to enterprise resources behind
firewalls without a VPN.

Critical naming guardrail:
- Do **not** invent fictional GD URL-session replacement class names.
- Keep `URLSession`/`NSURLConnection` where supported and enforce
  post-authorization request timing.

---

## How the SDK Secures Networking (Auto-Swizzling)

The Dynamics SDK uses Objective-C runtime method swizzling to
**transparently intercept** standard iOS networking APIs. When the SDK
authorizes the app, it automatically:

1. Registers an internal SDK `NSURLProtocol` interceptor globally via
   `[NSURLProtocol registerClass:]`, intercepting all `NSURLConnection`
   requests.
2. Swizzles `NSURLSession` and `NSURLSessionConfiguration` factory and
   instance methods so that all session-based requests route through the
   Dynamics networking stack.
3. Swizzles `NSURLRequest` and `NSMutableURLRequest` initializers and
   setters so request metadata is captured.
4. Swizzles `WKWebsiteDataStore` and `WKHTTPCookieStore` for secure
   cookie management in `WKWebView`.

**This happens automatically on authorization** inside the SDK's
`GDActivationAdapter::onStartupCallback` — the app does NOT need to
call `GDURLLoadingSystem.enableSecureCommunication()` manually.

### What Is Auto-Swizzled

| Standard API | Intercepted? | Notes |
|---|---|---|
| `URLSession.shared` | YES | Transparently routes through Dynamics |
| `URLSession(configuration:)` | YES | All configurations intercepted |
| `URLSession.dataTask(with:)` | YES | All task creation methods |
| `URLSession.uploadTask(with:)` | YES | Upload tasks included |
| `URLSession.downloadTask(with:)` | YES | Download tasks included |
| `URLSession.streamTask(withHostName:port:)` | YES | Stream tasks included |
| `NSURLConnection` | YES | Legacy API, also intercepted |
| `NSMutableURLRequest` setters | YES | `setHTTPBody`, `setHTTPMethod`, etc. |
| `NSHTTPCookieStorage.cookiesForURL` | YES | Cookie interception |
| Alamofire / Moya / other `URLSession` wrappers | YES | They use `URLSession` internally |
| async/await `URLSession.data(from:)` | YES | Built on `URLSession` |
| Direct sockets (`NWConnection`, `CFSocket`) | NO | Must use `GDSocket` explicitly |
| `GCDAsyncSocket` | NO | Must replace with `GDSocket` |

### When Swizzling Activates

The SDK enables secure communication when ALL of these are true:
- The app has been authorized (`GDAppEventAuthorized`)
- The startup layer reports connectivity is allowed
- The container has not been wiped

This means:
- **Pre-authorization**: No networking swizzling is active. Standard
  `URLSession` calls go through Apple's networking stack.
- **Post-authorization**: All `URLSession` / `NSURLConnection` traffic
  is automatically routed through the Dynamics infrastructure.

### GDURLLoadingSystem.enableSecureCommunication()

This public API exists but **does not need to be called manually** in most
apps. The SDK calls it internally on authorization. It is useful only for:
- Re-enabling after an explicit `disableSecureCommunication()` call
- Test code that toggles secure communication

If legacy code already calls `enableSecureCommunication()` in
`onAuthorized()`, it is harmless (idempotent) but unnecessary.

## Prompt 06 Call-Site Contract (G19)

For every `secureNetworking` call site, Prompt 06 should capture:
- transport family
- request initiation point + lifecycle reachability
- session configuration and delegate handling
- custom `URLProtocol` decision
- pinning/trust decision
- background/foreground execution mode and background-session decision
- socket host/port/TLS mode and direct-socket migration decision
- replacement API and catalog row ID

Low-confidence wrapper paths must be explicit (`blocked`/`deferred`) instead of
implicitly treated as migrated.

---

## GDSocket (Direct Socket Access)

For apps that use raw socket connections (`CFStreamCreatePairWithSocketToHost`,
`NSStream`, `CFSocket`, `NWConnection`, `GCDAsyncSocket`), swizzling does
NOT apply. These must be migrated to `GDSocket` explicitly.

**GDSocket API** (from `GDNETiOS.h`):
- `init:onPort:andUseSSL:` — constructor that takes C-string host, int port,
  and BOOL ssl. This configures the socket but does NOT connect.
- `connect` — no-argument method that initiates the async connection.
  On success, `GDSocketDelegate.onOpen:` is called.
- `write` — sends data from the `writeStream` buffer (a `GDDirectByteBuffer`).
- `disconnect` — terminates the connection. `onClose:` is called when done.

**CRITICAL**: `GDSocket` does NOT have `connect:onPort:andUseSSL:` or
`connect(toHost:onPort:)`. The host/port/SSL are set in the **initializer**,
and `connect` takes no arguments.

**CRITICAL — Two-step write pattern**: Writing data with `GDSocket` requires
TWO calls, not one:
1. `[socket.writeStream write:...]` — buffers the data (does NOT send)
2. `[socket write]` — flushes the buffer and sends over the network
If you omit `[socket write]`, data sits in the buffer, the server never
receives it, and eventually times out and disconnects.

### Before (NSStream / CFSocket)

```objc
CFStreamCreatePairWithSocketToHost(NULL,
    (__bridge CFStringRef)host, port, &readStream, &writeStream);
outputStream = (__bridge NSOutputStream *)writeStream;
inputStream = (__bridge NSInputStream *)readStream;
[outputStream setDelegate:self];
[inputStream setDelegate:self];
[outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
[inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
[outputStream open];
[inputStream open];
```

### After (GDSocket — Objective-C)

```objc
@import BlackBerryDynamics.SecureCommunication;

// [BB_DYNAMICS-MIGRATION] Replaced CFStream/NSStream with GDSocket
// Step 1: Create socket with host, port, SSL in the INITIALIZER
self.gdSocket = [[GDSocket alloc] init:[host UTF8String]
                                onPort:port
                             andUseSSL:NO];
// Step 2: Set delegate BEFORE connecting
self.gdSocket.delegate = self;
// Step 3: Connect (no arguments — host/port already set in init)
[self.gdSocket connect];
```

### After (GDSocket — Swift)

```swift
import BlackBerryDynamics.SecureCommunication

// [BB_DYNAMICS-MIGRATION] Replaced raw socket with GDSocket
// Step 1: Create socket with host, port, SSL in the INITIALIZER
let gdSocket = GDSocket("server.example.com", onPort: 443, andUseSSL: true)
// Step 2: Set delegate BEFORE connecting
gdSocket.delegate = self
// Step 3: Connect (no arguments)
gdSocket.connect()
```

### Swift Signature Notes (GDSocket / GDDirectByteBuffer)

When migrating Swift socket code, use the SDK header as source of truth
(`GDNETiOS.h`) and match Swift-bridged signatures:

- If `gdSocket` is non-optional, use `gdSocket.delegate = self` (no `?.`).
- Optional chaining is valid only if `gdSocket` is declared optional.
- For writing bytes, `GDDirectByteBuffer.writeData(_:)` may appear in ObjC
  docs but be imported in Swift as `write(_:)`.

Swift-safe write pattern:

```swift
let payloadData = Data("hello".utf8)
gdSocket.writeStream?.write(payloadData)   // write(_:) in Swift
gdSocket.write()                           // flush to network
```

If the compiler says `'writeData' has been renamed to 'write(_:)'`, use the
`write(_:)` form above.

### Writing Data with GDSocket

`GDSocket` uses `GDDirectByteBuffer` for I/O instead of `NSStream`:

```objc
// Writing data (replaces NSOutputStream write:maxLength:)
[self.gdSocket.writeStream write:[data UTF8String]];
[self.gdSocket write]; // sends the buffered data

// Reading data (in onRead: delegate callback)
NSMutableString *received = [self.gdSocket.readStream unreadDataAsString];
```

### GDSocketDelegate Threading

**CRITICAL**: All `GDSocketDelegate` callbacks (`onOpen:`, `onRead:`,
`onClose:`, `onErr:inSocket:`) fire on a **background thread**, NOT the
main thread. This differs from `NSStreamDelegate`, which fires on whichever
run loop the stream was scheduled on (typically the main run loop).

Any UI updates inside delegate callbacks **must** be dispatched to the main
thread via `dispatch_async(dispatch_get_main_queue(), ...)` (ObjC) or
`DispatchQueue.main.async { ... }` (Swift).

**Do NOT use `dispatch_sync` / `DispatchQueue.main.sync`** — it risks
deadlock if the main thread is blocked waiting on the socket operation.
Without dispatching at all, UI updates are silently dropped on newer iOS
versions, causing the app to appear non-functional.

### GDSocketDelegate (Objective-C)

```objc
// [BB_DYNAMICS-MIGRATION] Replaces NSStreamDelegate stream:handleEvent:
// IMPORTANT: All callbacks fire on a background thread.
// Wrap ALL UI updates in dispatch_async(dispatch_get_main_queue(), ...).
- (void)onOpen:(id)socket {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = @"Connected";
    });
}

- (void)onRead:(id)socket {
    GDSocket *gdSocket = (GDSocket *)socket;
    NSString *data = [gdSocket.readStream unreadDataAsString];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.textView.text = data;
    });
    [gdSocket disconnect];
}

- (void)onClose:(id)socket {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = @"Disconnected";
    });
}

- (void)onErr:(int)error inSocket:(id)socket {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = [NSString stringWithFormat:@"Error %d", error];
    });
}
```

### GDSocketDelegate (Swift)

```swift
extension NetworkManager: GDSocketDelegate {
    func onOpen(_ socket: Any) {
        DispatchQueue.main.async {
            self.statusLabel.text = "Connected"
        }
    }

    func onRead(_ socket: Any) {
        guard let gdSocket = socket as? GDSocket else { return }
        let data = gdSocket.readStream?.unreadDataAsString()
        DispatchQueue.main.async {
            self.textView.text = data as String?
        }
        gdSocket.disconnect()
    }

    func onClose(_ socket: Any) {
        DispatchQueue.main.async {
            self.statusLabel.text = "Disconnected"
        }
    }

    func onErr(_ error: Int32, inSocket socket: Any) {
        DispatchQueue.main.async {
            self.statusLabel.text = "Error \(error)"
        }
    }
}
```

---

## GDHttpRequest (Low-Level HTTP)

`GDHttpRequest` exists in the SDK but is deprecated in current headers.
Default migration guidance remains:
- use standard `URLSession`/supported Foundation APIs post-authorization
- avoid introducing new `GDHttpRequest` usage unless there is a verified,
  documented requirement that cannot be met with routed `URLSession`

If `GDHttpRequest` remains in legacy code, classify it explicitly in the call-site
contract and report.

---

## Migration Patterns

### Pattern 1: URLSession (Most Common — No Code Changes Needed)

**Before:**
```swift
let session = URLSession.shared
let task = session.dataTask(with: url) { data, response, error in
    // handle response
}
task.resume()
```

**After:**
```swift
// [BB_DYNAMICS-MIGRATION] No change needed — the SDK auto-swizzles
// NSURLSession after authorization. All URLSession traffic is
// automatically routed through the Dynamics infrastructure.
let session = URLSession.shared
let task = session.dataTask(with: url) { data, response, error in
    // handle response
}
task.resume()
```

### Pattern 2: Alamofire

Alamofire uses `URLSession` internally. After SDK authorization,
Alamofire requests are automatically routed through Dynamics:

```swift
// [BB_DYNAMICS-MIGRATION] No Alamofire code changes needed —
// the SDK's auto-swizzle intercepts the underlying URLSession
AF.request("https://api.example.com/data").responseDecodable(of: MyModel.self) { response in
    // handle response
}
```

### Pattern 3: async/await URLSession

```swift
// [BB_DYNAMICS-MIGRATION] Auto-swizzled — no code changes needed
let (data, response) = try await URLSession.shared.data(from: url)
```

### Pattern 4: Authentication Challenges

While `URLSession` requests are auto-intercepted, apps that handle
server trust or client certificate challenges may need to implement
`URLSessionDelegate` methods:

```swift
func urlSession(_ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
        completionHandler(.performDefaultHandling, nil)
    case NSURLAuthenticationMethodHTTPBasic:
        let credential = URLCredential(user: username, password: password, persistence: .forSession)
        completionHandler(.useCredential, credential)
    case NSURLAuthenticationMethodClientCertificate:
        completionHandler(.performDefaultHandling, nil)
    case NSURLAuthenticationMethodNTLM:
        let credential = URLCredential(user: username, password: password, persistence: .forSession)
        completionHandler(.useCredential, credential)
    default:
        completionHandler(.performDefaultHandling, nil)
    }
}
```

### Pattern 5: Background Session Classification (No G12 Implementation Here)

When `URLSessionConfiguration.background(withIdentifier:)` or equivalent
background callbacks are detected:
- classify whether work can defer until foreground post-auth
- if autonomous secure work is required, mark explicit G12 dependency
  (`blocked`/`deferred`) with rationale
- do not claim complete autonomous background secure networking in Tranche 4

---

## What NOT to Migrate

- **Push notifications** (APNs) — these bypass Dynamics networking and
  use Apple's push infrastructure directly. Dynamics has its own push
  channel (`GDPushChannel`) for server-initiated communication.
- **Bonjour / mDNS** — local network discovery is not routed through Dynamics
- **WebRTC** — has its own Dynamics integration path

---

## Common Issues

1. **Network requests fail before authorization** — the SDK only swizzles
   networking after authorization. Defer all network access to
   post-authorization (see `20-auth-initialization.md`).
2. **Certificate pinning conflicts** — if the app pins certificates,
   Dynamics infrastructure certificates may not match. Use Dynamics
   certificate management instead.
3. **Custom URLProtocol** — may conflict with the SDK's global URLProtocol
   registration.
   Test thoroughly and record an explicit compatibility decision. The SDK registers its protocol via
   `[NSURLProtocol registerClass:]`, which affects global request routing.
4. **Background URLSession** — classify as foreground-deferrable vs G12-dependent.
   Do not implement Background Authorize in Prompt 06.
5. **Legacy code calls `enableSecureCommunication()` pre-auth** — this
   will assert/crash. If the call exists, ensure it runs post-auth, or
   remove it (the SDK calls it automatically).

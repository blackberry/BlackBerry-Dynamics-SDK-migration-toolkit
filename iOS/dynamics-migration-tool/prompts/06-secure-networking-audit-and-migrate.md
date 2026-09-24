## Task: Secure Networking Audit and Migration

Goal: Verify that Dynamics secure networking covers all network
communications and migrate any direct socket usage.

**Prerequisites**:
- Prompts 00-03b must be complete
- The analysis (Prompt 00) identified networking usage

**Skip this prompt if the app does not use networking for sensitive data.**

---

## SDK Header Verification (Mandatory Before Changes)

Before making any code changes, verify the networking headers are accessible:

```bash
rg "GDURLLoadingSystem|GDSocket" \
  Pods/BlackBerryDynamics --include="*.h" -l 2>/dev/null | head -5
```

Do **not** probe for `GDHttpRequest` / `GDHttpRequestDelegate`. Those classes
are deprecated in 15.x and are dropped from the SDK headers in 16.0; their
absence is expected and must never be treated as a missing or broken SDK
install.

If not found, `pod install` has not been run. Confirm before proceeding.
Do NOT write migration code based on assumed signatures — confirm
`enableSecureCommunication`, `GDSocket` constructor, and callback names
against the installed header versions.

---

## Background: Auto-Swizzling

The Dynamics SDK **automatically intercepts** `NSURLSession`,
`NSURLConnection`, and related APIs via Objective-C runtime method
swizzling after authorization. This means:

- `URLSession.shared` and custom sessions are transparently routed
  through the Dynamics networking stack.
- Libraries built on `URLSession` (Alamofire, Moya, etc.) work
  automatically with no code changes.
- The app does **NOT** need to call
  `GDURLLoadingSystem.enableSecureCommunication()` — the SDK calls
  it internally when the app is authorized.

The only networking APIs that are **NOT** auto-swizzled are direct
socket connections (`NWConnection`, `CFSocket`, `GCDAsyncSocket`).
These must be migrated to `GDSocket`.

---

## Steps

### 1. Process Every Owned Call Site First (Mandatory)

Read `output/migration-analysis.json` and isolate
`executionPlan[].domainId == "secureNetworking"` call sites.

For **each** call site, classify and record:
- transport family (`URLSession`/`NSURLConnection`/direct socket/websocket/custom wrapper)
- request initiation point (`startup`, `authorized callback`, `user action`, `background callback`)
- authorization reachability (`pre-auth`, `post-auth`, `unknown`)
- session/config/delegate handling
- custom `URLProtocol` usage and decision
- certificate pinning/trust decision
- background-session classification and whether it depends on G12
- socket host/port/TLS mode and migration decision when direct sockets are present
- replacement API and API catalog row ID

Do not skip low-confidence or wrapper-based paths: classify them explicitly and
choose `migrated`, `removed`, `blocked`, `deferred`, or `notApplicable`.

### 2. URLSession / NSURLConnection Treatment

`URLSession` and `NSURLConnection` are auto-routed by Dynamics **after**
authorization.

Required handling:
- Keep supported standard APIs in place (do not replace with fictional APIs).
- Do **not** introduce any fictional GD URL-session replacement class.
- Verify request initiation is post-authorization.
- Verify session/delegate behavior is preserved.
- Review custom session configurations (`default`, `ephemeral`, `background`).
- Review custom `URLProtocol` and trust/pinning delegates for routing conflicts.

If legacy code calls `GDURLLoadingSystem.enableSecureCommunication()`, ensure it
is not used as a pre-auth bypass. The SDK auto-enables secure communication at
authorization.

**Withdrawn HTTP classes**: `GDHttpRequest` and `GDHttpRequestDelegate` are
dropped from the SDK in 16.0, so they are never a valid replacement API and
must not appear in migrated code. If legacy code still uses them, rewrite each
call site onto `URLRequest`/`URLSession` post-authorization (catalog row
`ios-networking-006`): map URL, method, headers, and body to `URLRequest`, and
replace `onStatusChange:` handling with the `URLSession` completion handler or
`URLSessionDelegate`, reading status from `HTTPURLResponse`. Where the rewrite
cannot be proven safe, record `blocked`/`deferred` with rationale — leaving the
removed class in place is not a valid disposition.

### 3. Direct Sockets and Wrappers

Replace direct sockets with verified `GDSocket` patterns where support is
provable:
- `NWConnection`
- `CFSocket`
- `CFStreamCreatePairWithSocketToHost`
- `NSStream` / `InputStream` / `OutputStream` socket paths
- `GCDAsyncSocket` / CocoaAsyncSocket wrappers
- WebSocket wrappers that bypass Foundation routing

For opaque third-party wrappers where secure migration cannot be proven, block
the call site and record rationale.

**CRITICAL**: `GDSocket` host/port/SSL are set in the **initializer**, NOT
in `connect`. The `connect` method takes NO arguments.

**Objective-C (CocoaPods)**:
```objc
@import BlackBerryDynamics.SecureCommunication;

// Before (CFStream / NSStream / NWConnection / etc.)
// CFStreamCreatePairWithSocketToHost(NULL, host, port, &readStream, &writeStream);

// After
// [BB_DYNAMICS-MIGRATION] Replaced raw socket with GDSocket
self.gdSocket = [[GDSocket alloc] init:[host UTF8String]
                                onPort:port
                             andUseSSL:NO];
self.gdSocket.delegate = self;
[self.gdSocket connect]; // no arguments — host/port already set
```

**Swift**:
```swift
import BlackBerryDynamics.SecureCommunication

// Before
// let connection = NWConnection(host: "server.example.com", port: 443, using: .tcp)

// After
// [BB_DYNAMICS-MIGRATION] Replaced direct socket with GDSocket
let gdSocket = GDSocket("server.example.com", onPort: 443, andUseSSL: true)
gdSocket.delegate = self
gdSocket.connect() // no arguments — host/port set in init
```

**Swift API compatibility guardrails (mandatory)**:
- If a socket variable is declared non-optional (`let gdSocket = ...` or
  `var gdSocket: GDSocket`), do **not** use optional chaining (`gdSocket?.delegate`).
- If optional chaining is used, the declaration must be optional
  (`var gdSocket: GDSocket?`).
- For outbound bytes, prefer Swift-bridged `write(_:)` on `GDDirectByteBuffer`:
  ```swift
  gdSocket.writeStream?.write(payloadData)
  gdSocket.write()
  ```
  Do not use `writeData(...)` in Swift if the compiler indicates it has been
  renamed to `write(_:)`.

Also replace `NSStreamDelegate` (`stream:handleEvent:`) with
`GDSocketDelegate` (`onOpen:`, `onRead:`, `onClose:`, `onErr:inSocket:`).
See steering `30-secure-networking.md` for the full delegate migration
pattern and data I/O via `GDDirectByteBuffer`.

**CRITICAL — Threading**: All `GDSocketDelegate` callbacks fire on a
**background thread**, unlike `NSStreamDelegate` which fires on the
scheduling run loop (typically main). All UI updates inside delegate
callbacks MUST be dispatched to the main thread.

Use `DispatchQueue.main.async { ... }` (Swift) or
`dispatch_async(dispatch_get_main_queue(), ...)` (ObjC).

**Do NOT use `DispatchQueue.main.sync`** — it risks deadlock if the
callback is already executing on the main queue or if the main thread
is blocked waiting on the socket operation. Apple's documentation for
`sync(execute:)` explicitly warns: "Calling this function and targeting
the current queue results in deadlock."

### 4. Handle Authentication Challenges (if applicable)

If the app implements `URLSessionDelegate` for server trust or client
certificate challenges, review the handlers. The Dynamics infrastructure
handles enterprise certificate trust, but the app may need to handle:
- HTTP Basic / Digest authentication
- NTLM authentication
- Client certificate selection

```swift
func urlSession(_ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
        completionHandler(.performDefaultHandling, nil)
    case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodNTLM:
        let credential = URLCredential(user: username, password: password, persistence: .forSession)
        completionHandler(.useCredential, credential)
    default:
        completionHandler(.performDefaultHandling, nil)
    }
}
```

### 5. Handle Certificate Pinning and Trust Handling

**STOP — ask the developer before making any pinning changes.**

Certificate pinning is an explicit security control. Auto-removing it
changes the app's threat model. Present the developer with the following
and wait for explicit direction:

> "The app implements certificate pinning via [detected library/method].
> BlackBerry Dynamics manages certificate trust centrally via UEM policy,
> so custom pinning can conflict with SDK-managed TLS. Options are:
> (a) Remove custom pinning and rely on UEM policy (recommended for
> fully Dynamics-managed apps); (b) Keep pinning if the endpoints are
> not proxied by Dynamics infrastructure and the developer confirms no
> conflict. How should we proceed?"

Only proceed with removal if the developer explicitly confirms option (a).
If removed, document as a security-model change in the migration report's
`manualTodos` section with the original pinning implementation and the
rationale for removal.

### 6. Classify Background Sessions (No G12 Implementation in This Tranche)

Do **not** implement Background Authorize in this prompt.

For every background networking candidate:
- record why background execution exists
- determine whether work can be deferred until foreground post-auth
- if secure work requires autonomous background authorization, mark as
  `blocked`/`deferred` with explicit G12 dependency and manual follow-up
- never claim this tranche provides autonomous background secure networking

### 7. Verify Networking Timing

All network access must happen post-authorization:
- The SDK only swizzles networking APIs after authorization
- No `URLSession` requests should fire before the
  `GDAppEventAuthorized` event
- Direct `GDSocket` connections also require authorization

### 8. Build and Verify

Run `xcodebuild` to verify compilation. Classify any failures as
pre-existing (per developer clean-build attestation/history), step-introduced, or unrelated.

**Socket-specific compile sanity checks** (if `GDSocket` was migrated):
- No `cannot use optional chaining on non-optional value of type 'GDSocket'`
- No `'writeData' has been renamed to 'write(_:)'` errors
- If either appears, re-check Swift declaration optionality and use
  `write(_:)` on `writeStream`.

### 9. Run Scoped Validation (Required)

```bash
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt 06
```

Resolve all failures before recording prompt completion. Hard failures include:
- definite pre-auth request initiation
- active unmanaged direct socket path
- unknown/unreviewed custom protocol or pinning decision
- background secure work marked complete while requiring G12
- stale reachability/network evidence
- missing/wrong-owner ledger disposition
- invented Dynamics APIs (for example fictional GD URL-session class names)
- removed Dynamics APIs (`GDHttpRequest` / `GDHttpRequestDelegate`) used as a
  replacement, or a legacy call site on them left unmigrated

---

## Closure Ledger Update (Required)

Before recording Prompt 06 as `completed`, write call-site dispositions for
the `secureNetworking` domain using the atomic updater:

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "06" \
  --domain-id "secureNetworking" \
  --updates-file /tmp/secure-networking-updates.json
```

Do not edit `output/migration-plan-state.json` directly.
Missing dispositions block recorder completion.

---

## Output

- Confirmed `URLSession` traffic is auto-intercepted (no code changes)
- Direct socket connections replaced with `GDSocket` (if applicable)
- Authentication challenge handlers reviewed
- Custom protocol / certificate pinning / trust decisions recorded
- Background session candidates classified with explicit G12 dependency where required
- All network access deferred to post-authorization
- Build verification result
- Scoped validation (`--check-prompt 06`) passed

See `30-secure-networking.md` for the full steering reference.

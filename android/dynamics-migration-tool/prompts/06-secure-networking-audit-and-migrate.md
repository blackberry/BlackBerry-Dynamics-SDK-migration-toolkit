## Task: Secure Networking Migration

Goal: Ensure all network traffic is routed through the Dynamics secure
communication system, or documented as not applicable.

**Prerequisite**: Authorization (prompt 03) and deferral audit (prompt 03b)
must be complete. Network access requires the container to be unlocked
via `onAuthorized()`.

---

## Module map context (read first)

Load `dynamics-migration-tool/output/module-map.json` and resolve
`${in_scope_main_src}` (every primary + library `src/main/java` and
`src/main/kotlin` directory). OkHttp clients, Retrofit factories, and
HttpURLConnection helpers commonly live in dedicated networking
library modules (`network/`, `core/network`, `data/api`); every
search below scans this full set so library-side network builders
are not missed. If `module-map.json` is missing, STOP and re-run
`00pre-bootstrap.md`.

---

## Steps

### 0. SDK Class Availability (consult bootstrap)

The Dynamics networking classes were already verified by prompt
`00pre-bootstrap.md` and the result is recorded in
`output/bootstrap.json` under `sdkClassIndex`. Confirm the relevant
entries are `"found"`:

- `com.blackberry.okhttpsupport.interceptor.BBCustomInterceptor`
- `com.blackberry.okhttpsupport.cookie.BBCookieJar`
- `com.good.gd.net.GDSocket`
- `com.good.gd.apache.http.client.HttpClient`

If any is missing or `bootstrap.json` itself is missing/invalid, STOP
and re-run `00pre-bootstrap.md`. The class index has to be authoritative
before this prompt makes code changes. Do NOT run `./gradlew
dependencies` yourself; that probe belongs to the bootstrap.

Do NOT abort if applicability says `secureNetworking` is
`not-applicable` — just record the prompt as `skipped` (see "Record
execution" below) and move on.

### 1. Inventory All Networking Usage

Search the entire source tree for:
- `java.net.HttpURLConnection` / `java.net.URL.openConnection()`
- `java.net.Socket` / `javax.net.ssl.SSLSocket`
- OkHttp (`OkHttpClient`, `Request`, `Response`)
- Retrofit (`Retrofit.Builder`, `@GET`, `@POST`, etc.)
- Ktor (`io.ktor.*`)
- Cronet (`org.chromium.net.*`, `CronetEngine`)
- gRPC (`io.grpc.*`, `ManagedChannelBuilder`, `OkHttpChannelBuilder`)
- `android.app.DownloadManager`
- WebSocket clients (`WebSocketClient`, `okhttp3.WebSocket`, third-party WebSocket SDKs)
- `java.net.DatagramSocket` / raw `SSLSocket` primitives
- Any custom HTTP clients or networking wrappers
- Third-party libraries that make network calls (analytics, crash reporting, etc.)
- **Native (NDK / C / C++) socket usage** — BSD socket calls in
  `*.c`/`*.cc`/`*.cpp`/`*.cxx`/`*.h`/`*.hpp`: `socket`, `connect`,
  `bind`, `listen`, `accept`, `send`, `recv`, `sendto`, `recvfrom`,
  `shutdown`, `getaddrinfo`, `gethostbyname`. Prompt 00 step 2b must
  have already recorded these as `secureNetworking` `callSites[]`
  with `language: "C"` or `"C++"`. If any are missing, fix the analysis
  before migrating.

### 2. Classify Each Networking Path

For each networking usage, determine:
- **Supported Dynamics path** — `GDHttpClient`, `GDSocket`, OkHttp via `BBCustomInterceptor` (and `BBCookieJar` if needed), Retrofit only when wired to that proven OkHttp client, or BlackBerry WebSocket project based on `GDSocket`
- **Not applicable** — app has no networking (fully offline app)
- **Manual intervention required** — unsupported or unproven transport path (Ktor/Cronet/gRPC/DownloadManager/arbitrary WebSocket/DatagramSocket/SSLSocket/dependency-owned generated clients without proven Dynamics routing)

If any path is `Manual intervention required`, you must keep `secureNetworking`
open and ensure prompt 10 records `manualTodos[]` with `blocking: true` for
each unresolved transport.

### 3. Migrate Each Networking Path — Use the Template

Work through every call site from your inventory in step 1. Use the templates as your
exact reference. The templates are derived from the official BlackBerry Dynamics SDK
samples (`OkHttpBD` and `Dynamics-GettingStarted`).

---

#### 3a. OkHttp / Retrofit — use `OkHttpDynamicsClient` template

Use `dynamics-migration-tool/templates/network/OkHttpDynamicsClient.java` (or `.kt`).

Find every `OkHttpClient.Builder` construction in your app:
```bash
rg "OkHttpClient\(\)|OkHttpClient\.Builder\(\)" -g "*.java" -g "*.kt" ${in_scope_main_src}
```

For each hit, chain `.addInterceptor(bbCustomInterceptor)` as the **last** interceptor:

```java
// [BB_DYNAMICS-MIGRATION] OkHttpClient routes through Dynamics secure transport via BBCustomInterceptor.
BBCustomInterceptor bbCustomInterceptor = new BBCustomInterceptor();
OkHttpClient client = new OkHttpClient().newBuilder()
        // Your existing app interceptors (logging, auth headers) stay here — BEFORE BB interceptor.
        .addInterceptor(bbCustomInterceptor)  // Dynamics transport — must be last.
        .build();
```

**INTERCEPTOR ORDERING IS MANDATORY**: `BBCustomInterceptor` must be added **after**
all app-side interceptors. App interceptors see the request before it enters the
Dynamics transport stack. Getting this wrong causes requests to bypass UEM policy.

**INTERCEPTOR TYPE IS MANDATORY**: attach `BBCustomInterceptor` with
`addInterceptor(...)` only. Do not use `addNetworkInterceptor(...)`.

**`BBCookieJar` is optional** — add `.cookieJar(new BBCookieJar())` only when your
app relies on cookie-based session management that needs to survive container lock/unlock.
Most apps do not need it.

After migration, verify every `OkHttpClient` instance has the interceptor:
```bash
rg "OkHttpClient" -g "*.java" -g "*.kt" ${in_scope_main_src} -l
```
Open each file and confirm `BBCustomInterceptor` is present and `addInterceptor`-ed.

---

#### 3b. HttpURLConnection → GDHttpClient

Use `dynamics-migration-tool/templates/network/GDHttpClientExample.java`.

```java
// BEFORE
URL url = new URL(urlString);
HttpURLConnection conn = (HttpURLConnection) url.openConnection();

// AFTER
// [BB_DYNAMICS-MIGRATION] Replaced HttpURLConnection with GDHttpClient.
import com.good.gd.apache.http.HttpResponse;
import com.good.gd.apache.http.client.methods.HttpGet;
import com.good.gd.net.GDHttpClient;

GDHttpClient httpClient = new GDHttpClient();
HttpGet request = new HttpGet(urlString);
HttpResponse response = httpClient.execute(request);
```

**Wrong package paths (validator will catch these):**
```java
import org.apache.http.*;                 // WRONG — must be com.good.gd.apache.http.*
import org.apache.http.client.methods.*;  // WRONG
```

---

#### 3c. java.net.Socket → GDSocket

Use `dynamics-migration-tool/templates/network/GDSocketExample.java`.

```java
// BEFORE
Socket socket = new Socket(host, port);

// AFTER
// [BB_DYNAMICS-MIGRATION] Replaced java.net.Socket with com.good.gd.net.GDSocket.
import com.good.gd.net.GDSocket;   // Correct — NOT com.good.gd.net.ssl.GDSocket

GDSocket socket = new GDSocket();  // No-arg constructor
socket.connect(host, port, timeoutMillis);
// ...
socket.close();  // Use close(), NEVER socket.disconnect() — GDSocket has no disconnect()
```

#### 3d. Native (NDK / C / C++) sockets → Dynamics C API

If prompt 00 step 2b recorded `secureNetworking` `callSites[]` with
`language: "C"` or `"C++"`, migrate them here using the canonical
mapping in `steering/14-api-provenance-and-replacement-catalog.md`
"Native (NDK) Direct Replacement Catalog" — Networking section, and the
classification rules in `steering/46-native-ndk-direct-replacement.md`.

Replacements (only use entries that appear in the BlackBerry C Language
Programming Interface or in the installed
`sdk/libs/handheld/libs/gd/inc/` headers — do not invent):

| Standard C / POSIX | Dynamics C API |
|---|---|
| `socket` | `GD_socket` |
| `connect` | `GD_connect` |
| `bind` | `GD_bind` |
| `listen` | `GD_listen` |
| `accept` | `GD_accept` |
| `send` / `sendto` | `GD_send` / `GD_sendto` |
| `recv` / `recvfrom` | `GD_recv` / `GD_recvfrom` |
| `shutdown` | `GD_shutdown` |
| `getaddrinfo` / `freeaddrinfo` | `GD_getaddrinfo` / `GD_freeaddrinfo` |
| `gethostbyname` | `GD_gethostbyname` |

If a POSIX call has no documented `GD_*` equivalent, do **not** invent
one — record a manual TODO and mark the call site unsupported per
`steering/13-unsupported-feature-detection-matrix.md`.

Prebuilt `.so` libraries with no in-repo source remain high-priority
`manualTodos` per prompt 00 step 2b. They do **not** auto-close
`secureNetworking`; closure requires either in-repo source migration or
a developer-signed-off deferral in `bootstrap.json deferredDomains[]`.

#### 3e. Unsupported / Unproven Network Stacks (mandatory)

Treat these as `Manual intervention required` unless you can prove routing
through supported Dynamics paths above:

- Ktor
- Cronet
- gRPC
- `DownloadManager`
- arbitrary WebSocket libraries
- `DatagramSocket` / raw `SSLSocket` primitives
- dependency-owned or generated client stacks with unproven routing

For each unresolved stack:

1. keep the call site/domain open (do not mark secure networking as closed),
2. document the stack and owning module for prompt 10, and
3. require a blocking report item (`manualTodos[].blocking=true`) until replaced
   or removed.

### 3b. Import and API Guardrails (Mandatory)

Use ONLY the package paths and cleanup methods defined in
`steering/30-secure-networking.md`.

Do NOT introduce these incorrect forms:

```java
// WRONG
import org.apache.http.*;
import org.apache.http.client.methods.*;
import com.good.gd.net.ssl.GDSocket;
socket.disconnect();
```

Correct forms:

```java
// CORRECT
import com.good.gd.apache.http.HttpResponse;
import com.good.gd.apache.http.client.methods.HttpGet;
import com.good.gd.net.GDSocket;
socket.close();
```

**No networking**:
If the app is fully offline, document this as not-applicable and skip.

### 4. Handle Certificate Pinning

**STOP — ask the developer before making any pinning changes.**

Certificate pinning is an explicit security control. Auto-removing it
changes the app's threat model. Search for pinning usage:

```bash
rg "CertificatePinner|certificatePinner|network_security_config|pin-set|TrustManager|X509TrustManager" \
  -g "*.java" -g "*.kt" -g "*.xml" -n
```

If detected, present the developer with the following and wait for
explicit direction:

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

### 5. Verify Container Lifecycle

All network initialization and requests MUST happen after `onAuthorized()`.
Check for network calls in `onCreate()`, `onResume()`, `Application.onCreate()`,
and background services.

### 6. Document Limitations

OkHttp under Dynamics has limitations:
- No caching support
- Only connection timeouts (no read/write timeouts)
- API exposes host/peer verification disable methods, but enterprise migrations must not use them
- Do not use `OkHttpClient.proxy(...)`; proxy routing is controlled by UEM policy
- SPNEGO not supported
- Per-user proxy credentials not supported

### 7. Evidence Baseline (Mandatory)

For transport and trust decisions, use kit-contained evidence only:
- Rules in this prompt and `steering/30-secure-networking.md`
- Canonical templates under `templates/network/`
- Validator outcomes from `tooling/validate.sh`

Do not state "cannot" when APIs exist but are disallowed by policy; phrase as
"available in SDK, prohibited by this migration kit for enterprise posture."

---

## Output

- Networking inventory table (library, usage, migration approach)
- Code changes with explanation
- Certificate pinning conflicts resolved (or documented as kept)
- Limitations that affect the app
- Testing instructions (verify requests succeed through Dynamics)
- **`dynamics-migration-tool/output/migration-plan-state.json` updated** —
  merge/upsert one `dispositions[]` entry per `secureNetworking` call
  site from prompt 00, preserving existing `egressFeatureDecisions[]`
  and other domains' `dispositions[]`, then full-file overwrite (see
  `steering/79-migration-plan-state-and-call-site-closure.md`).

  Required field names (matched by `record-prompt-execution.sh` and the
  bundled schema `dynamics-migration-tool/schemas/migration-plan-state.schema.v1.1.0.json`):

  ```json
  {
    "schemaVersion": "1.1.0",
    "runId": "<copied unchanged from bootstrap.json / existing migration-plan-state.json>",
    "egressFeatureDecisions": [
      {
        "featureId": "<existing value or new prompt-owned feature id>",
        "domain": "secureFileStorage|secureNetworking|icc|secureClipboard|secureUiWidgets|policyManagement",
        "outcome": "REMOVE|REPLACE_WITH_DYNAMICS|MANUAL_INTERVENTION_REQUIRED|BLOCKED_UNTIL_APPROVED",
        "module": "<optional module path from module-map.json>",
        "note": "<optional detail>",
        "secureAlternative": "<optional string or null>",
        "uiDisposition": "removed|disabled|replaced|flagged",
        "codePathReachable": false
      }
    ],
    "dispositions": [
      {
        "callSiteId": "<id from migration-analysis.executionPlan[].callSites[].id>",
        "domain": "secureNetworking",
        "status": "migrated",
        "module": "<module path from module-map.json, e.g. app>",
        "note": "optional free text"
      }
    ]
  }
  ```

  Do not invent alternative field names (`disposition`, `state`,
  `verdict`, etc.) — the recorder hard-fails on schema mismatch.
  Preserve the existing top-level `runId` exactly; never regenerate it.
  Keep `egressFeatureDecisions[]` present even when unchanged.

See `30-secure-networking.md` for the full steering reference.

---

## Record execution

After this prompt completes — whether it migrated networking or
skipped because `secureNetworking` is `not-applicable` — append the
execution record so prompt 10's hard gate sees that the plan was
honored:

```bash
# Migrated case (M2: closure requires migration-plan-state.json dispositions)
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 06 \
    --status completed \
    --files-touched <comma-separated relative paths including migration-plan-state.json>

# Skipped case (domain marked not-applicable in migration-analysis.json)
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 06 \
    --status skipped \
    --note "secureNetworking not-applicable per executionPlan"
```

This records prompt progress only. For an immediate diagnostic, run
`validate.sh --check-prompt 06` (Phase 6 networking + Phase 6b WebView
hardening + Phase 10 API audit). Prompt `10` remains the mandatory final
source/report gate.

Before recording **`completed`**, ensure every applicable `callSites[].id`
for prompt **06** has a matching disposition in `migration-plan-state.json`.

## Enterprise Hardening Addendum (Transport Trust)

- `disableHostVerification()` and `disablePeerVerification()` (on `GDHttpClient`, `GDSocket`, or `BBCustomInterceptor`) are explicit trust downgrades and are not allowed in this kit.
- `trustAllCerts` and always-allow host verifier patterns are not allowed in this kit.
- `android:usesCleartextTraffic="true"` and `network_security_config` cleartext enablement are not allowed in this kit.
- `network_security_config` user trust anchors (`certificates src="user"`) require explicit enterprise PKI justification in the report.
- Retained pinning requires explicit enterprise security sign-off and must not use trust-bypass primitives.
- `validate.sh` enforces explicit bypasses and cleartext enablement as hard failures under `transportHardening`, while generic TLS customization primitives and user trust anchors are review warnings.

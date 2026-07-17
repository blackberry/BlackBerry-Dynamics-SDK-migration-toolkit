# Steering: Android API Provenance and Replacement Catalog

> **Source of truth:** The machine-readable catalog is
> `contracts/api-catalog.v1.0.0.json` (current `catalogVersion: 1.2.0`,
> `sdkVersionVerified: 15.0.8513.64`).
> The filename is the stable contract path; bump `catalogVersion` inside
> the JSON when catalog rows change structurally. This Markdown file is the
> **human-readable view** of the same data. When the two diverge, the JSON
> catalog wins. Validators and report generators should consume the JSON;
> this file exists for steering context and developer readability.

This file maps native Android APIs to Dynamics APIs, with provenance to
**public documentation**, the **installed Dynamics SDK distribution**, and
**public sample repositories** only.

> **Standalone kit rule:** This migration tool is consumed by third-party
> developers who do not have access to BlackBerry internal SDK source trees.
> Do **not** reference, require, or search company-internal repositories
> (for example internal `msdk/` or `endpoint/` checkouts). Verify every
> replacement against the developer's installed SDK, the official API
> reference, and the C API documentation linked below.

## Source Provenance

- **Official docs:** BlackBerry Dynamics Android Development Guide + API
  reference (https://developers.blackberry.com/us/en/resources/api-reference.html).
- **Public samples:** https://github.com/blackberry/BlackBerry-Dynamics-Android-Samples
- **Installed SDK (authoritative for agents):**
  - Java/Kotlin APIs: packages documented in the API reference (resolved via
    the project's `com.blackberry.blackberrydynamics:*` Maven dependencies).
  - Native C APIs: headers under
    `sdk/libs/handheld/libs/gd/inc/` in the Dynamics SDK install tree
    (see the [C Language Programming Interface](https://developer.blackberry.com/files/blackberry-dynamics/android/capi.html)).

| Public surface | Where developers find it | Representative APIs |
|----------------|--------------------------|---------------------|
| Secure filesystem (Java) | API reference — `com.good.gd.file` | `File`, `FileInputStream`, `FileOutputStream`, `GDFileSystem`, `RandomAccessFile` |
| Secure SQLite (Java) | API reference — `com.good.gd.database.sqlite` | `SQLiteDatabase`, `SQLiteOpenHelper`, … |
| Secure networking (Java) | API reference — `com.good.gd.net`, OkHttp integration | `GDHttpClient`, `GDSocket`, `BBCustomInterceptor`, `BBCookieJar` |
| Authorization & policy | API reference — `com.good.gd` | `GDAndroid`, `GDStateListener`, `GDAndroid.getInstance().getApplicationPolicy()`, `GDAndroid.getInstance().getApplicationConfig()` |
| App event listener | API reference — `com.good.gd` | `GDAppEventListener`, `GDAppEvent` (see WI-00 verified table below) |
| SSO / identity | API reference — `com.good.gd.utility` | `GDUtility`, `GDAuthTokenCallback` (see WI-00 verified table below) |
| Push Channel | API reference — `com.good.gd.push` + `GDAndroid` local broadcasts | `PushChannel`, `PushChannel.prepareIntentFilter()`, `GDAndroid.getInstance().registerReceiver(...)`, `PushChannelState`, `PushChannelEventType` (see WI-00 verified table below; **not** `GDPushChannel*`, not `GDLocalBroadcastManager`) |
| Secure UI (DLP widgets) | API reference — `com.good.gd.widget` | `GDEditText`, `GDTextView`, `GDAppCompatEditText`, … |
| Secure WebView | API reference — `com.blackberry.bbwebview` | `BBWebView`, `BBWebViewClient`, `BBWebChromeClient` |
| Secure clipboard | API reference — `com.good.gd.content` | `ClipboardManager` |
| ICC | API reference — AppKinetics / GDService | `GDService`, `GDServiceClient` |
| Native stdio & directories (C) | `GD_C_FileSystem.h` in installed `gd/inc/` | `GD_fopen`, `GD_mkdir`, `GD_opendir`, `GD_stat`, … |
| Native fd I/O (C) | `GD_C_unistd.h`, `GD_C_sys_stat.h` | `GD_UNISTD_open`, `GD_UNISTD_read`, `GD_UNISTD_fstat`, … |
| Native sockets & DNS (C) | `GD_C_sys_socket.h`, `GD_C_netdb.h` | `GD_socket`, `GD_connect`, `GD_getaddrinfo`, `GD_gethostbyname`, … |

## Target SDK release

This toolkit revision targets **BlackBerry Dynamics SDK for Android 15.0**
(public API reference build **15.0.8513.64**).

Release-note deltas that affect migration steering (not every app needs
code changes):

| Area | SDK 15.0 change | Migration action |
|------|-----------------|------------------|
| OpenSSL | Upgraded to OpenSSL 3.5.4 | Review any `GDCryptoPKCS7` / PKCS#7 call sites for stricter flag handling (`GDPKCS7_BINARY`, `GDPKCS7_DETACHED`) |
| FIPS | Provider upgraded to FIPS 140-3 | Prefer AES-128/256-CBC over Triple-DES for S/MIME when FIPS is enabled; see `74-fips-obfuscation-backup.md` |
| SecureStorage | New activations use AES-GCM; existing stay AES-CBC | No app API swap; note in report if storage crypto posture matters |
| Native libs | Ships `libgdndk.so` + `libsbgse.so` | No extra Gradle wiring required |
| Protect Mobile | Malware / safe browsing / SMS URL scan removed | Remove `android_handheld_blackberry_protect_support` and Protect API usage |
| Build toolchain | Gradle ≥ 8.11.1, AGP 8.9.1, NDK 27.3.13750724 | Record toolchain gaps in bootstrap / report; do not silently downgrade |
| UEM profile | "Open files unencrypted in other selected non-Dynamics apps" | Policy-driven; keep outbound file transfer on Dynamics-controlled paths |

Official notes:
https://docs.blackberry.com/en/blackberry-dynamics-sdk/15.x/blackberry-dynamics-sdk-for-android/blackberry-dynamics-sdk-for-android-release-notes/blackberry-dynamics-sdk-for-android-version-15.0

## WI-00 verified public APIs (2026 Q2, revalidated for SDK 15.0)

Symbols below were confirmed with `javap -public` against
`com.blackberry.blackberrydynamics:android_handheld_platform` (originally
**14.1.8215.34**; public API reference for this toolkit cut is
**15.0.8513.64** — resolve `libs/gd.jar` inside the AAR — `classes.jar`
may be empty). Maintainer transcript:
`_maintainer/notes/sdk-verification-2026Q2.md`. Re-run `javap` against the
installed 15.0 AAR when Maven publishes the artifact locally.

**Kit scope:** Push Channel rows (`push-java-*`) ship with prompt
`11-push-channel.md` and Phase `12`. Application config cache row
`appconfig-java-001` ships with `steering/73a-app-config-read-and-refresh.md`
and Phase `7` warn-only cache scan (WI-03). SSO and `GDAppEventListener`
recipes remain follow-on (WI-11, WI-11a). Do **not** invent `GDPushChannel*`
or other symbols absent from the installed SDK.

| Domain | Public type | Verified signature (installed SDK) | API reference |
|--------|-------------|-----------------------------------|-----------------|
| App config | `com.good.gd.GDAndroid` | `Map<String, Object> getApplicationConfig() throws GDNotAuthorizedError` | [GDAndroid](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_android.html) |
| App config refresh | `com.good.gd.GDStateListener` | `void onUpdateConfig(Map<String, Object> settings)` | [GDStateListener](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_state_listener.html) |
| App events | `com.good.gd.GDAppEventListener` | `void onGDEvent(GDAppEvent event)` | [GDAppEventListener](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_app_event_listener.html) |
| App events (payload) | `com.good.gd.GDAppEvent` | `GDAppEvent(String, GDAppResultCode, GDAppEventType)`; getters `getMessage()`, `getResultCode()`, `getEventType()` | [GDAppEvent](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_app_event.html) |
| SSO / tokens | `com.good.gd.utility.GDUtility` | `void getGDAuthToken(String challenge, String serverName, GDAuthTokenCallback callback)`; `static void getEIDToken(String, String, String, BBDJWTokenCallback, boolean)`; `String getDynamicsSharedUserID() throws GDNotAuthorizedError` | [GDUtility](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1utility_1_1_g_d_utility.html) |
| SSO callback | `com.good.gd.utility.GDAuthTokenCallback` | `void onGDAuthTokenSuccess(String)`; `void onGDAuthTokenFailure(int, String)` | [GDAuthTokenCallback](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1utility_1_1_g_d_auth_token_callback.html) |
| Push Channel | `com.good.gd.push.PushChannel` | `PushChannel(String pushChannelId)`; `connect()`; `disconnect()`; `PushChannelState getState()`; static intent helpers `getEventType`, `getToken`, `getMessage`, `getErrorCode`, `getPingFailCode`; `IntentFilter prepareIntentFilter()` | [PushChannel](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1push_1_1_push_channel.html) |
| Push Channel receiver | `com.good.gd.GDAndroid` | `void registerReceiver(BroadcastReceiver receiver, IntentFilter filter)`; `void unregisterReceiver(BroadcastReceiver receiver)` | [GDAndroid](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_android.html) |
| Push Channel | `com.good.gd.push.PushChannelState` | enum: `None`, `Open`, `Error`, `Closed` | [PushChannelState](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1push_1_1_push_channel_state.html) |
| Push Channel | `com.good.gd.push.PushChannelEventType` | enum: `None`, `Open`, `Close`, `Error`, `Message`, `PingFail`; `get(int)`; `getCode()` | [PushChannelEventType](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1push_1_1_push_channel_event_type.html) |

`PushChannelListener` remains present in the public API reference but is
deprecated. Do not use it as a migration target; replace listener-based
handling with `PushChannel.prepareIntentFilter()` plus
`GDAndroid.getInstance().registerReceiver(...)`.

`GDAndroid` wiring verified for app events: `setGDAppEventListener(GDAppEventListener)`;
`authorize(GDAppEventListener) throws GDInitializationError`.

Authorization policy note: the public SDK also documents alternative Activity
monitoring and authorization patterns such as direct `authorize(...)`,
`GDMonitorActivity`, Dynamics replacement Activity classes,
`GDStateAction` state broadcasts, and `applicationInit(...)` receiver-before-
auth flows. This kit standardizes on global `GDStateListener` +
`activityInit()` for main-process Activities so validation can prove a single
startup model. Treat existing alternatives as supported SDK patterns to
convert or deliberately preserve, not as nonexistent APIs.

Background Authorize (public overload only — no no-arg form):

| | |
|---|---|
| Signature | `boolean canAuthorizeAutonomously(Context context)` |
| Doc | [GDAndroid#canAuthorizeAutonomously](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_android.html) |
| Pairing | Call before `boolean serviceInit(Context context)` on the same `Service` instance (`this`). |

## Deterministic Replacement Rules

| Domain | Native API / Pattern | Dynamics Replacement | Tier | Notes |
|---|---|---|---|---|
| Authorization | direct startup data access before auth, or existing non-kit Dynamics authorization/Activity monitoring pattern | Kit policy: `GDAndroid.getInstance()` + Application-scoped `GDStateListener` + `activityInit()` exactly once per main-process Activity | tier1 | Public SDK has other supported entry paths (`authorize(...)`, `GDMonitorActivity`, replacement Activity classes, `GDStateAction`, `applicationInit(...)`). Convert to kit policy by default; preserve only with explicit rationale. |
| Background Authorize | secure-API access from `FirebaseMessagingService`, `JobIntentService` / `JobService`, `WorkManager` worker, or `BroadcastReceiver` chain | `GDAndroid.getInstance().canAuthorizeAutonomously(Service)` then `GDAndroid.getInstance().serviceInit(Service)` + `com.blackberry.dynamics.settings.json` `GDEnableBackgroundAuthorize: true` | tier1 | Service context must be the `Service` instance (`this`). `serviceInit` returns `boolean`; `false` means no callback will fire. Throws `com.good.gd.error.GDInitializationError`. See `70-background-authorize.md`. |
| Secure files | `java.io.File` / sandbox file-storage flows | `com.good.gd.file.*` APIs | tier1 | Remove plaintext temp file patterns |
| **External storage — high-level APIs** (SECURITY BLOCKER, non-waivable) | `Environment.getExternalStorageDirectory()`, `Environment.getExternalStoragePublicDirectory(...)`, `Context.getExternalFilesDir(...)`, `Context.getExternalFilesDirs(...)`, `Context.getExternalCacheDir()`, `Context.getExternalMediaDirs()`, `Environment.DIRECTORY_DOWNLOADS / PICTURES / DOCUMENTS / MOVIES / MUSIC / DCIM / ...` | `com.good.gd.file.*` container paths (`com.good.gd.file.File` + `com.good.gd.file.FileOutputStream`, rooted via `com.good.gd.file.GDFileSystem`). Catalog rows: `fs-java-ext-001`, `fs-java-ext-002`. | tier1 | **Always hard-fail.** Phase 4 raises `[SECURITY-BLOCKER][externalStorage/api-surface]`. Phase 0 rejects `externalStorage` from `deferredDomains[]`. See `40-secure-file-storage.md` §9. |
| **External storage — MediaStore writes** (SECURITY BLOCKER, non-waivable) | `ContentResolver.insert / update / delete` against `MediaStore.{Images,Video,Audio,Downloads,Files,Documents}.EXTERNAL_CONTENT_URI`, `MediaStore.createWriteRequest / createDeleteRequest / createTrashRequest` | Write to `com.good.gd.file.FileOutputStream` in the container. For user-initiated export, use AppKinetics `GDServiceClient.sendTo` (`icc-java-001`) or a **one-shot** `ACTION_CREATE_DOCUMENT` with a `manualTodos[]` entry using `blocking: true` for sign-off. Catalog row: `fs-java-ext-003`. | tier1 | MediaStore shared collections are world-readable to apps with the relevant scoped-storage permission. Reads (e.g. user-picked image ingestion) are not flagged; writes are. |
| **External storage — raw paths** (SECURITY BLOCKER, non-waivable) | String literals `"/sdcard/..."`, `"/storage/emulated/..."`, `"/storage/self/..."`, `"/mnt/sdcard/..."`, `"/storage/<volume>/{Download,Downloads,Pictures,Documents,DCIM,Movies,Music}"` in any `java.io.File(...)`, stream constructor, native call, or library load | Container-relative `com.good.gd.file.File` paths (no leading `/sdcard`, `/storage`, or `/data`). Catalog row: `fs-java-ext-004`. | tier1 | Common silent-leak vector — slips past API-level detection. Phase 4 scans the literals directly. |
| **External storage — SAF persisted tree** (SECURITY BLOCKER, non-waivable) | `ACTION_OPEN_DOCUMENT_TREE`, `DocumentFile.fromTreeUri`, `DocumentsContract.buildChildDocumentsUriUsingTree`, `DocumentsContract.createDocument`, `takePersistableUriPermission` | One-shot `ACTION_CREATE_DOCUMENT` for a single user-initiated export, OR AppKinetics `GDServiceClient.sendTo` (`icc-java-001`) for inter-Dynamics-app transfer. Catalog row: `fs-java-ext-005`. | tier1 | A persisted tree URI mounts an external folder for repeated writes of app data; every write leaves the container. Never persist a tree URI for application data. |
| **`DocumentFile.fromFile()` with GD paths** (FORBIDDEN) | `DocumentFile.fromFile(com.good.gd.file.File)` | Direct GD stream access: `com.good.gd.file.FileInputStream` / `com.good.gd.file.FileOutputStream`. Do not wrap GD `File` objects with `DocumentFile`. Catalog row: `fs-java-docfile-001`. | tier1 | `DocumentFile.fromFile()` constructs a `file://` URI from `absolutePath`. GD container-relative paths are virtual — the URI is always invalid for `ContentResolver`. Compiles cleanly; crashes at runtime with `IllegalArgumentException` or `FileNotFoundException`. Phase 4 rule 4M (`FS-DOCFILE-001`). |
| **SAF inbound import** | `ACTION_OPEN_DOCUMENT`, `ACTION_GET_CONTENT`, `ACTION_PICK`, `ActivityResultContracts.OpenDocument`, `ActivityResultContracts.OpenMultipleDocuments`, `ActivityResultContracts.GetContent`, `ActivityResultContracts.GetMultipleContents`, `ContentResolver.openInputStream` against external URIs | Read external content directly into `com.good.gd.file.FileOutputStream` (container path). No plaintext staging. Validate file type/size. Catalog row: `saf-java-inbound-001`. | tier1 | Trust-boundary crossing: external data enters the container. Not a security blocker but requires explicit secure-copy migration. See `44-saf-trust-boundary.md` §1a. |
| **SAF outbound export** (SECURITY BLOCKER, non-waivable without developer approval) | `ACTION_CREATE_DOCUMENT`, `ActivityResultContracts.CreateDocument`, `ContentResolver.openOutputStream` for export, writable `ParcelFileDescriptor` to external URIs, `DocumentFile` write operations | Default: **BLOCK**. Disable UI action, prevent picker launch. After explicit developer approval: DLP policy check via `GDAndroid.getInstance().getApplicationPolicy()` then stream from `com.good.gd.file.FileInputStream` to `ContentResolver.openOutputStream(uri)`. Catalog row: `saf-java-outbound-001`. | tier1 | Data exfiltration risk. Defaults to `BLOCKED_PENDING_DEVELOPER_APPROVAL`. Phase 4 raises `[SECURITY-BLOCKER][externalStorage/saf-outbound-export]`. See `44-saf-trust-boundary.md` §1b. |
| **SAF Activity Result Contracts** | `ActivityResultContracts.OpenDocument`, `OpenMultipleDocuments`, `CreateDocument`, `OpenDocumentTree`, `GetContent`, `GetMultipleContents` | Same directional rules as intent-based equivalents. Inbound: secure-copy into container. Outbound: block until developer approval + DLP. Catalog row: `saf-java-contracts-001`. | tier1 | Jetpack Activity Result API wrappers for SAF intents. Phase 4 SAF scanner detects these alongside raw intent actions. |
| **SAF URI sharing** (SECURITY BLOCKER, non-waivable without developer approval) | `FLAG_GRANT_READ_URI_PERMISSION`, `FLAG_GRANT_WRITE_URI_PERMISSION`, `Intent.setClipData` with content URIs, `ClipData.newUri`, `Intent.EXTRA_STREAM` for Dynamics data | Default: **BLOCK**. Remove URI grants, prevent external intent launch. After approval: ICC `GDServiceClient.sendTo` or DLP-gated content share. Catalog row: `saf-java-uri-sharing-001`. | tier2 | URI permission grants transfer data access to external components. Write grants especially dangerous. See `44-saf-trust-boundary.md` §1d. |
| **SAF external primary storage** (SECURITY BLOCKER, non-waivable) | `ACTION_OPEN_DOCUMENT_TREE` + `takePersistableUriPermission` as canonical data store, persisted `content://` URIs in databases/prefs, URI-backed repositories | Replace with `com.good.gd.file.*` container-backed repository. Remove persisted tree URIs. Catalog row: `saf-java-primary-storage-001`. | tier1 | Persisted URI permission is NOT equivalent to secure storage. See `44-saf-trust-boundary.md` §1c. |
| Secure SQLite | `android.database.sqlite.*` runtime persistence | `com.good.gd.database.sqlite.*` | tier1 | Handle helper/refactor carefully |
| Secure networking | `HttpURLConnection`, raw socket, plain OkHttp | `GDHttpClient`, `GDSocket`, `BBCustomInterceptor` | tier1 | Keep transport under Dynamics control |
| Secure WebView | `android.webkit.WebView` enterprise data | `BBWebView` family | tier2 | Validate JS bridge and upload behavior |
| ICC / sharing | generic `ACTION_SEND` for secure enterprise payloads | `GDService` / `GDServiceClient` flows | tier2 | Keep external sharing as explicit TODO |
| Secure widgets — text input | `android.widget.EditText` (every covered call site, not just "sensitive" ones — see `45-secure-ui-widgets.md`) | `com.good.gd.widget.GDEditText` | tier2 | Custom subclasses often manual |
| Secure widgets — text display | `android.widget.TextView` / `MaterialTextView` (every covered call site) | `com.good.gd.widget.GDTextView` | tier2 | `MaterialTextView` requires Java/Kotlin binding type to change to `GDTextView` |
| Secure widgets — autocomplete | `android.widget.AutoCompleteTextView` | `com.good.gd.widget.GDAutoCompleteTextView` | tier2 | Drop-in replacement |
| Secure widgets — multi-autocomplete | `android.widget.MultiAutoCompleteTextView` | `com.good.gd.widget.GDMultiAutoCompleteTextView` | tier2 | Drop-in replacement |
| Secure widgets — search | `android.widget.SearchView` / `androidx.appcompat.widget.SearchView` | `com.good.gd.widget.GDSearchView` / `com.good.gd.widget.GDAppCompatSearchView` | tier2 | Pick the AppCompat variant if app uses AppCompat-themed activities |
| Secure widgets — AppCompat text input | `androidx.appcompat.widget.AppCompatEditText` | `com.good.gd.widget.GDAppCompatEditText` | tier2 | Required for system copy/paste action-bar DLP |
| Secure widgets — AppCompat text display | `androidx.appcompat.widget.AppCompatTextView` | `com.good.gd.widget.GDAppCompatTextView` | tier2 | |
| Secure widgets — AppCompat checked text | `androidx.appcompat.widget.AppCompatCheckedTextView` | `com.good.gd.widget.GDAppCompatCheckedTextView` | tier2 | |
| Secure widgets — AppCompat autocomplete | `androidx.appcompat.widget.AppCompatAutoCompleteTextView` | `com.good.gd.widget.GDAppCompatAutoCompleteTextView` | tier2 | |
| Secure widgets — AppCompat multi-autocomplete | `androidx.appcompat.widget.AppCompatMultiAutoCompleteTextView` | `com.good.gd.widget.GDAppCompatMultiAutoCompleteTextView` | tier2 | |
| Secure clipboard | `android.content.ClipboardManager` | `com.good.gd.content.ClipboardManager` | tier2 | DLP checks mandatory |
| Secure clipboard (Compose interim) | `androidx.compose.ui.platform.LocalClipboardManager` | `__APP_PACKAGE__.GDClipboardAdapter` (kit template; routes through `com.good.gd.content.ClipboardManager`) | tier2 | Stop-gap until official Compose-native Dynamics clipboard APIs exist; catalog row `clipboard-compose-001` |
| Secure clipboard (Compose interim) | `androidx.compose.ui.platform.LocalClipboard` | `__APP_PACKAGE__.GDClipboardAdapter` | tier2 | Same interim adapter pattern; catalog row `clipboard-compose-002` |
| Secure clipboard (Compose interim) | `androidx.compose.ui.platform.ClipboardManager` / `Clipboard` / `ClipEntry` usage in `@Composable` code | `GDClipboardAdapter` plain-text `setPlainText` / `getPlainText` where deterministic | tier2 | Rich `ClipEntry` payloads may require manual remediation; catalog row `clipboard-compose-003` |
| ICC chooser (Compose) | `MaterialAlertDialogBuilder` / `AlertDialog.Builder` for ICC provider list in `@Composable` screens | `GDICCProviderShareDialog` (kit template) + existing `sendFiles` / `GDServiceClient.sendTo` | tier2 | UX-layer only; catalog row `icc-compose-001` |
| ICC chooser (Compose) | `TransferFileService.showShareChooser(Activity, …)` from `@Composable` entry points | Compose state + `GDICCProviderShareDialog` + `sendFiles` on selection | tier2 | catalog row `icc-compose-002` |
| Policy management | unmanaged restrictions access | `GDAndroid.getApplicationPolicy()` | tier2 | Validate policy keys and defaults |

> **WebView note**: `android.webkit.WebView` migrates to
> `com.blackberry.bbwebview.BBWebView` (already listed above). The
> deprecated `com.good.gd.widget.GDWebView` is **not** a valid target
> in this catalog. If a row claims `GDWebView`, treat the row as
> invalid and migrate the call site to `BBWebView` per
> `50-webview-bbwebview.md`.

## Native (NDK) Direct Replacement Catalog

BlackBerry Dynamics ships a C Language Programming Interface for NDK
apps. The headers are installed by the Android SDK distribution under
`sdk/libs/handheld/libs/gd/inc/`. The Dynamics functions mirror C and
POSIX names with a `GD_` or `GD_UNISTD_` prefix. See:

- C Language Programming Interface (Android):
  https://developer.blackberry.com/files/blackberry-dynamics/android/capi.html
- C Language Programming Interface list:
  https://developer.blackberry.com/files/blackberry-dynamics/ios/group__capilist.html
  (URL currently resolves under `/ios/` but the function set applies to
  Android as well, per the Android C API page that links to it.)

Use only entries you can verify in the BlackBerry C API list or in the
locally installed `sdk/libs/handheld/libs/gd/inc/` headers. If a POSIX
call has no documented `GD_*` / `GD_UNISTD_*` equivalent, do **not**
invent one — record a manual TODO and treat the call site as
unsupported per `13-unsupported-feature-detection-matrix.md`.

**Header families (installed SDK — verify in `sdk/libs/handheld/libs/gd/inc/`):**

| C / POSIX family | Shipped header(s) |
|------------------|-------------------|
| stdio + directory (`fopen`, `mkdir`, `opendir`, `stat`, …) | `GD_C_FileSystem.h` |
| fd I/O (`open`, `read`, `write`, `lseek`, `unlink`, `rmdir`, `fstat`) | `GD_C_unistd.h`, `GD_C_sys_stat.h` |
| sockets + DNS | `GD_C_sys_socket.h`, `GD_C_netdb.h` |

**Naming families:** stdio-style and directory APIs use plain `GD_*`
(`GD_fopen`, `GD_mkdir`, `GD_opendir`, …) declared in
`GD_C_FileSystem.h`. POSIX file-descriptor I/O uses `GD_UNISTD_*` in
`GD_C_unistd.h` / `GD_C_sys_stat.h`. BSD sockets and DNS use `GD_*`
without the `UNISTD` prefix in `GD_C_sys_socket.h` / `GD_C_netdb.h`.
If a symbol is absent from the installed headers and the public C API
list, treat it as unsupported — do not invent a replacement.

### Storage (stdio + POSIX file descriptors)

| Domain | C / POSIX call | Dynamics C API replacement | Tier | Notes |
|---|---|---|---|---|
| secureFileStorage | `fopen` | `GD_fopen` | tier1 | Stream-style, returns `FILE *` |
| secureFileStorage | `fclose` | `GD_fclose` | tier1 | |
| secureFileStorage | `fread` | `GD_fread` | tier1 | |
| secureFileStorage | `fwrite` | `GD_fwrite` | tier1 | |
| secureFileStorage | `fseek` | `GD_fseek` | tier1 | |
| secureFileStorage | `ftell` | `GD_ftell` | tier1 | |
| secureFileStorage | `fflush` | `GD_fflush` | tier1 | |
| secureFileStorage | `feof` / `ferror` / `clearerr` | `GD_feof` / `GD_ferror` / `GD_clearerr` | tier1 | |
| secureFileStorage | `remove` | `GD_remove` | tier1 | |
| secureFileStorage | `rename` | `GD_rename` | tier1 | |
| secureFileStorage | `open` | `GD_UNISTD_open` | tier1 | POSIX `int` fd path |
| secureFileStorage | `close` | `GD_UNISTD_close` | tier1 | |
| secureFileStorage | `read` | `GD_UNISTD_read` | tier1 | |
| secureFileStorage | `write` | `GD_UNISTD_write` | tier1 | |
| secureFileStorage | `lseek` | `GD_UNISTD_lseek` | tier1 | |
| secureFileStorage | `unlink` | `GD_UNISTD_unlink` | tier1 | |
| secureFileStorage | `mkdir` | `GD_mkdir` | tier1 | In `GD_C_FileSystem.h`, not `GD_UNISTD_*` |
| secureFileStorage | `rmdir` | `GD_UNISTD_rmdir` | tier1 | |
| secureFileStorage | `opendir` | `GD_opendir` | tier1 | In `GD_C_FileSystem.h` |
| secureFileStorage | `readdir` | `GD_readdir` | tier1 | `GD_readdir_r` also available |
| secureFileStorage | `closedir` | `GD_closedir` | tier1 | In `GD_C_FileSystem.h` |
| secureFileStorage | `stat` | `GD_stat` | tier1 | In `GD_C_FileSystem.h` |
| secureFileStorage | `fstat` | `GD_UNISTD_fstat` | tier1 | In `GD_C_sys_stat.h` |

### Networking (BSD-style sockets)

| Domain | C / POSIX call | Dynamics C API replacement | Tier | Notes |
|---|---|---|---|---|
| secureNetworking | `socket` | `GD_socket` | tier1 | `GD_C_sys_socket.h` |
| secureNetworking | `connect` | `GD_connect` | tier1 | |
| secureNetworking | `bind` | `GD_bind` | tier1 | |
| secureNetworking | `listen` | `GD_listen` | tier1 | |
| secureNetworking | `accept` | `GD_accept` | tier1 | |
| secureNetworking | `send` / `sendto` | `GD_send` / `GD_sendto` | tier1 | |
| secureNetworking | `recv` / `recvfrom` | `GD_recv` / `GD_recvfrom` | tier1 | |
| secureNetworking | `shutdown` | `GD_shutdown` | tier1 | |
| secureNetworking | `getaddrinfo` / `freeaddrinfo` | `GD_getaddrinfo` / `GD_freeaddrinfo` | tier1 | `GD_C_netdb.h` |
| secureNetworking | `gethostbyname` | `GD_gethostbyname` | tier1 | Direct 1:1 in `GD_C_netdb.h`; `GD_getaddrinfo` preferred for new code |

### Native build-system signals

These are not direct replacements but tell the agent that native code
exists in scope:

- `CMakeLists.txt` referenced from `externalNativeBuild { cmake { … } }`
- `Android.mk` / `Application.mk` referenced from
  `externalNativeBuild { ndkBuild { … } }`
- JNI bindings: `System.loadLibrary("…")` / `System.load("…")`
- Prebuilt native libraries under `src/main/jniLibs/<abi>/lib*.so`

When any of these are present, run the native discovery and
classification steps in prompts `00`, `05a`, `05b`, `05c`, and `06` and
in `40-secure-file-storage.md` §8 (file I/O) and `46-native-ndk-direct-replacement.md` (networking).

## Kotlin/JDK helpers that silently bypass the container

> **Source of truth** for the kit's stream-layer rule. See
> `40-secure-file-storage.md` §5 for the full invariant, anti-pattern
> list, and worked examples; this section is the cross-cutting catalog
> that prompts (`05a`, `05b`) and `validate.sh` Phase 4 point at.
>
> See `40-secure-file-storage.md` §5 "Kotlin `File` extensions are
> compile-time traps" for the canonical wording used in prompts and
> migration-plan-state closure checks.

Dynamics secure I/O is determined by the **stream constructor** actually
used at a call site, **not** by the static type of the `File` handle that
names the byte source. The following Kotlin and JDK convenience helpers
accept a `File` (or `Path` / `String`) argument and silently open a
`java.io.FileInputStream` / `FileOutputStream` against an Android
sandbox path — **even when the `File` argument is declared
`com.good.gd.file.File`** — because Kotlin's extensions are defined on
`java.io.File` and `com.good.gd.file.File` resolves through `java.io`
interop.

Treat every API in the table below as a first-class anti-pattern on any
`secureFileStorage` call site. Replace one-for-one with a GD
stream call or the corresponding `SecureFileIO` helper in
`templates/file/SecureFileIO.{kt,java}`.

### Kotlin `kotlin.io.*` extensions on `File`

| Anti-pattern | Canonical Dynamics replacement |
|---|---|
| `f.writeText(s, charset = UTF_8)` | `com.good.gd.file.FileOutputStream(f.absolutePath).use { it.write(s.toByteArray(charset)) }` or `SecureFileIO.writeText(f, s, charset)` |
| `f.readText(charset = UTF_8)` | `com.good.gd.file.FileInputStream(f.absolutePath).use { it.readBytes().toString(charset) }` or `SecureFileIO.readText(f, charset)` |
| `f.appendText(s)` | `com.good.gd.file.FileOutputStream(path, /* append = */ true).use { it.write(s.toByteArray()) }` or `SecureFileIO.appendText(f, s)` |
| `f.writeBytes(b)` / `f.readBytes()` | GD `FileOutputStream` / `FileInputStream` + `write` / `readBytes`; `SecureFileIO.writeBytes` / `readBytesOrNull` |
| `f.forEachLine { … }` / `f.readLines()` / `f.useLines { … }` | `BufferedReader(InputStreamReader(com.good.gd.file.FileInputStream(path)))` then iterate lines |
| `f.bufferedReader()` / `f.bufferedWriter()` / `f.printWriter()` | wrap a GD stream with `InputStreamReader` / `OutputStreamWriter`; `SecureFileIO.newReader` / `newWriter` |
| `f.inputStream()` / `f.outputStream()` | `com.good.gd.file.FileInputStream(path)` / `com.good.gd.file.FileOutputStream(path)` |
| `f.copyTo(dst)` / `f.copyRecursively(dst)` | `SecureFileIO.copy(src, dst)` or a buffer loop over GD streams |
| `f.deleteRecursively()` | `SecureFileIO.deleteRecursively(f)` or equivalent GD-aware traversal helper (children-first, guarded `listFiles`) |

### JDK helpers (`java.nio.file` and friends)

| Anti-pattern | Canonical Dynamics replacement |
|---|---|
| `java.nio.file.Files.readAllBytes(p)` | `com.good.gd.file.FileInputStream(p.toString()).use { it.readBytes() }` |
| `java.nio.file.Files.write(p, b)` | `com.good.gd.file.FileOutputStream(p.toString()).use { it.write(b) }` |
| `Files.readString(p)` / `Files.writeString(p, s)` | GD stream + `toString(UTF_8)` / `toByteArray(UTF_8)` |
| `Files.newInputStream(p)` / `Files.newOutputStream(p)` | `com.good.gd.file.FileInputStream(p.toString())` / `FileOutputStream(p.toString())` |
| `Files.newBufferedReader(p)` / `Files.newBufferedWriter(p)` | `BufferedReader(InputStreamReader(GDFIS))` / `BufferedWriter(OutputStreamWriter(GDFOS))` |
| `Files.lines(p)` | `BufferedReader(InputStreamReader(GDFIS)).lineSequence()` |
| `new FileReader(file)` | `InputStreamReader(com.good.gd.file.FileInputStream(file.absolutePath))` or `SecureFileIO.newReader(file)` |
| `new FileWriter(file)` | `OutputStreamWriter(com.good.gd.file.FileOutputStream(file.absolutePath))` or `SecureFileIO.newWriter(file)` |
| `new PrintWriter(file)` | `PrintWriter(OutputStreamWriter(GDFOS))` |
| `new Scanner(file)` | `Scanner(InputStreamReader(GDFIS))` |
| `new RandomAccessFile(file, mode)` | Re-architect to streaming GD I/O; no random-access GD-backed equivalent |

### Image / serialization sinks bound to a path

| Anti-pattern | Canonical Dynamics replacement |
|---|---|
| `BitmapFactory.decodeFile(path)` | `com.good.gd.file.FileInputStream(path).use { BitmapFactory.decodeStream(it, null, opts) }` or `SecureFileIO.decodeBitmap(path)` |
| `bmp.compress(fmt, q, new java.io.FileOutputStream(path))` | `com.good.gd.file.FileOutputStream(path).use { bmp.compress(fmt, q, it) }` or `SecureFileIO.compressBitmap(path, bmp, fmt, q)` |
| `new ObjectInputStream(new FileInputStream(path))` | `ObjectInputStream(com.good.gd.file.FileInputStream(path))` |
| `new ObjectOutputStream(new FileOutputStream(path))` | `ObjectOutputStream(com.good.gd.file.FileOutputStream(path))` |
| `Properties.load(new FileInputStream(path))` | `com.good.gd.file.FileInputStream(path).use { props.load(it) }` |
| `new ZipFile(File\|String)` over a container path | Read bytes via GD stream into a `ZipInputStream(com.good.gd.file.FileInputStream(path))` |
| `FileChannel` / `transferTo` / `transferFrom` on GD streams | Buffer loop over GD `FileInputStream` / `FileOutputStream` (already enforced by Phase 4 GD-follow-on rule) |

### Path-domain rule (cross-link)

A `com.good.gd.file.File` constructed from `context.filesDir.absolutePath`
is still an Android-sandbox path string. Container paths must be
container-relative. The Phase 4 detector `gdFileFromSandbox` flags
`com.good.gd.file.File(...)` constructors whose argument references
`getFilesDir` / `getCacheDir` / `filesDir` / `cacheDir`. See
`40-secure-file-storage.md` §7 and §5d.

`validate.sh` Phase 4 fails every row in the tables above when matched
in files importing `com.good.gd.file.*`, routed through
`fail_or_defer "secureFileStorage"` (deferrable only via
`bootstrap.json deferredDomains[]`).

## SDK 15.0 crypto notes (`GDCryptoPKCS7` / OpenSSL 3.x)

SDK 15.0 upgrades OpenSSL to **3.5.4**. Every flag that is semantically
relevant to a PKCS#7 operation must be supplied at every call site
(`GDPKCS7_add_signer`, `GDPKCS7_final`, `GDPKCS7_write`,
`GDPKCS7_verify`, …). Missing flags can cause silent data corruption or
verification failures.

| Scenario | Required flags / inputs |
|---|---|
| Binary (non-MIME) signature | Pass `GDPKCS7_BINARY` to `GDPKCS7_add_signer`, `GDPKCS7_final`, and `GDPKCS7_write` |
| Detached signature | Pass `GDPKCS7_DETACHED \| GDPKCS7_BINARY`; on verify, supply original content via the `indata` parameter of `GDPKCS7_verify` |

Public reference:
https://developer.blackberry.com/devzone/files/blackberry-dynamics/android/group__cryptolist.html

Most Java/Kotlin migrations never call these C APIs. When Prompt 00 finds
native PKCS#7 / S/MIME usage, treat flag review as a blocking crypto
follow-up and record it in `manualTodos`.

## Unsupported or Advisory Patterns

| Pattern | Tier | Required Action |
|---|---|---|
| External storage for app data | tier3 | Redesign to container or ICC |
| Broad file sharing to non-Dynamics apps | tier3 | Restrict or replace with secure transfer patterns; honor UEM "Open files unencrypted in other selected non-Dynamics apps" when present |
| BlackBerry Protect Mobile (malware / safe browsing / SMS URL scan) | tier3 | **Removed in SDK 15.0** — delete Protect dependencies and API usage |
| Pre-auth secure API usage in app startup graph | tier3 | Refactor startup sequence |
| Non-native cross-platform stacks with opaque storage/network layers | tier3 | Assisted/manual migration plan required |

## Catalog Usage Rules

- **Machine-readable source of truth:** `contracts/api-catalog.v1.0.0.json`.
  Every row has a stable `id` (the `catalogRow` value). Validators and
  report generators should cross-check `apisReplaced[].catalogRow` against
  this JSON.
- Use this catalog when generating `apisReplaced` in `migration-report.json`.
  Set `apisReplaced[].catalogRow` to the matching row `id`.
- Every replacement entry should map to exactly one row in the JSON catalog.
- If no row applies, add a `manualTodo` and mark domain as `partial`.
- Do not invent replacement APIs that are absent from public docs or the
  installed SDK packages/headers.
- When adding new rows, update `contracts/api-catalog.v1.0.0.json` **first**
  (bump `catalogVersion` if the change is structural), then mirror the row
  in this Markdown view.

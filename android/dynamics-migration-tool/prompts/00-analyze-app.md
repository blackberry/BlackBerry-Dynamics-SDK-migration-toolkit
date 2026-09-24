## Task: Analyze Application for Dynamics Migration

Goal: Understand the existing application's architecture, APIs, and data
flows before making any changes. This analysis drives the migration plan.

**This prompt MUST run after `00pre-bootstrap.md`** (which writes
`output/bootstrap.json` and `output/module-map.json`) **and before
`01-gradle-integration.md` and every later prompt.** Canonical order:
`00pre` → **`00` (this prompt)** → optional `00b` (when
`--with-diagrams` was requested) → `01` … `10`.

---

## Module map context (read first)

Before any analysis, load `dynamics-migration-tool/output/module-map.json`
(emitted by `00pre-bootstrap.md`). Resolve these placeholders that are
used throughout this prompt:

- `${primary}` — `primaryAppModule.path`. The single application module
  being migrated this run. For canonical projects this is `app`. For
  multi-module projects it can be any Gradle module path (e.g.
  `app-primary/app-primary`).
- `${primary_main_src}` — `${primary}/src/main/java`. If the module is
  Kotlin-only, also include `${primary}/src/main/kotlin`.
- `${primary_main_manifest}` — `${primary}/src/main/AndroidManifest.xml`.
- `${primary_res_dirs}` — every res directory listed under the primary
  module's `main` source set (and any product flavors / build types
  enumerated by `module-map.json`).
- `${in_scope_res_dirs}` — every `res` directory listed for the primary
  module and every `libraryModulesInScope[]` module/source set. Use this
  for layout/menu/provider-path resource discovery in prompts `07`,
  `08`, and `09`.
- `${in_scope_manifests}` — every manifest listed for the primary module
  and every `libraryModulesInScope[]` module/source set. Use this for
  provider, service, receiver, WebView, and share/ICC discovery. Do not
  use an undefined `${primary_manifests}` placeholder.
- `${in_scope_modules}` — the primary module path plus every entry in
  `libraryModulesInScope[]`. Use this set when the prompt asks for
  project-wide source scans (audit comments, API call sites, etc.).
- `${in_scope_main_src}` — for each module in `${in_scope_modules}`,
  its `src/main/java` and `src/main/kotlin` directories. Pass the
  expanded list of paths to `rg`.

When this prompt's commands say `${primary}/...` or `${in_scope_main_src}`,
expand to the actual paths from `module-map.json` before invoking. If
`module-map.json` is missing, STOP and re-run `00pre-bootstrap.md` —
do NOT fall back to a literal `app/` path.

API call-site discovery in this prompt scans **every in-scope module**
(primary + libraries). The migration plan emitted at the end records,
per call-site, the owning module so later prompts can plan per-module
edits. Test source sets (`src/test`, `src/androidTest`) and modules
flagged `excludedTestOnlyModules` in `module-map.json` are skipped.

Also load `dynamics-migration-tool/output/bootstrap.json` → **`processModel`**
(see `steering/22-multi-process-app-handling.md`). Do **not** invent separate-process
`activityInit` rules in this analysis — reference `processModel` classifications only.

Classify the app's **complexity tier** (A/B/C) per
`steering/12-capability-and-support-model.md` and record it in the analysis
output. This tier drives release-readiness expectations in Prompt 10.

---

## Steps

### -1. Remove Stale Migration Outputs (If Any — Run Before Anything Else)

On a **first migration run**, `00pre-bootstrap.md` has already created
`dynamics-migration-tool/output/` with `bootstrap.json` (and maybe
`.bootstrap-probe.json`, `.gitkeep`). That is expected — **do not**
delete the `output/` directory or treat it as stale.

This step only removes **named migration artifacts from a prior analysis
or report run** when those specific files still exist on disk. If none
exist, the script prints a no-op message and you continue immediately.

Run once from the project root:

```bash
bash dynamics-migration-tool/tooling/clean-stale-outputs.sh
```

The script never removes:

- `output/bootstrap.json` — single source of truth from `00pre-bootstrap.md`
- `output/.bootstrap-probe.json` — probe/cache artifact from bootstrap, if present
- `output/.gitkeep` — keeps the directory in version control
- The `output/` directory itself

Do **not** run `rm -rf dynamics-migration-tool/output`, blanket-delete
`output/*.json`, or invent extra cleanup commands beyond
`clean-stale-outputs.sh`.

Do NOT proceed with analysis only if stale `migration-analysis.json`,
`migration-report.json`, `migration-plan-state.json`, or
`architecture-diagrams.md` from a **prior** run are still present after
the script (for example because the script was skipped).

### 0. Build Readiness Baseline

Do **not** run a baseline build in this prompt.

Prompt `00pre-bootstrap.md` already captures the developer's build-readiness
attestation. Do not re-ask for the same confirmation in prompt 00.

If needed, the developer can run optional diagnostics manually:
- `./dynamics-migration-tool/tooling/validate.sh --preflight`

### 0a. Detect Language, Framework, and SDK Version Compatibility

Capture the project's language and build configuration early — these drive
API usage patterns throughout the migration.

```bash
# Detect Kotlin vs Java (or mixed). Scan every in-scope module (primary +
# libraries) so multi-module Kotlin projects are not misread as Java-only
# when only the primary module happens to be Java.
rg "\.kt$" --files ${in_scope_main_src} 2>/dev/null | head -5
rg "\.java$" --files ${in_scope_main_src} 2>/dev/null | head -5

# Check minSdk and targetSdk from Gradle
rg "minSdk|targetSdk|compileSdk" -g "*.gradle" -g "*.gradle.kts" -n

# Check Kotlin version
rg "kotlin" -g "*.gradle" -g "*.gradle.kts" -n | head -10

# Check for Compose usage
rg "compose|@Composable" -g "*.kt" -g "*.gradle" -g "*.gradle.kts" -l 2>/dev/null | head -5
```

**Record these values** in the analysis output.

**minSdk / toolchain rules for Dynamics SDK 15.1:**
- BlackBerry Dynamics SDK 15.1 requires `minSdk` >= **33** (Android 13).
  Android 12 (API 31–32) is not supported.
- If the project already targets 33 or higher, **keep the existing target**.
  Only raise it to 33 if it is below 33. Never lower a higher target.
- If the project targets a version above 33, it may use APIs unavailable at
  API 33. Flag these as `preExistingApiAvailabilityRisks` in the analysis
  artifact if the target must change.
- SDK 15.1 software requirements: Gradle **≥ 9.3.1**, Android Gradle
  Plugin **9.1.1**, NDK **27.3.13750724**, compile/target **API 36**
  (Android 17-ready). Record gaps; do not silently downgrade the app
  toolchain.
- Flag and plan removal of `android_handheld_blackberry_protect_support`
  and Protect Mobile API usage (unsupported as of SDK 15.0).
- Flag native `GDCryptoPKCS7` / PKCS#7 call sites for OpenSSL 3.x flag
  review (`GDPKCS7_BINARY`, `GDPKCS7_DETACHED`).
- Record TLS 1.3 AES-GCM regression for networking paths (AES-CCM is not
  supported). No app API swap.

**Language awareness:**
- Detect whether the project uses Kotlin, Java, or mixed.
- Kotlin-only projects with Compose will use different patterns (e.g.,
  `LaunchedEffect` for authorization state, `mutableStateOf` for deferral).
- Java-only projects will use `LiveData`/callbacks for authorization state.

### 0b. Read Bootstrap Artifact (Mandatory)

Read `dynamics-migration-tool/output/bootstrap.json` (produced by prompt
`00pre-bootstrap.md`). This file is the single source of truth for:

- UEM credentials (`uem.gdApplicationId`, `uem.gdApplicationVersion`)
- Stable run provenance (`runId`, `catalogVersion`, `provenance.*`)
- Resolved Dynamics SDK version (`sdkProbe.dynamicsSdkResolvedVersion`)
- Per-class SDK availability (`sdkClassIndex`) — every entry must report
  `"found"`; the bootstrap aborts if any required class is missing
- Environment fingerprint (`environment` block — JDK, Gradle, language,
  minSdk, compileSdk, projectShape, working directory)
- Developer attestations (`attestations`)
- Pre-existing developer-deferred domains (`deferredDomains`)

If `bootstrap.json` does not exist or `sdkProbe.dynamicsSdkResolvedVersion`
is `null`, STOP. The migration cannot proceed — re-run
`00pre-bootstrap.md` to regenerate the bootstrap. Do NOT run any
ad-hoc `./gradlew dependencies` probe in this step; the bootstrap has
already done that and recorded the result authoritatively.

Use the bootstrap's `environment` and `appSummary`-equivalent fields to
seed the `appSummary` block in `migration-analysis.json` (re-detection
in step 1 is allowed for app-specific details, but the language /
minSdk / compileSdk values must match the bootstrap to within the
agent's normal best-effort detection).
Also copy `bootstrap.json.runId` into both `migration-analysis.json` and
`migration-plan-state.json`. Do not generate a new UUID in this prompt.

### 1. Project Structure Discovery

- Identify the build system (Groovy Gradle vs Kotlin DSL, single vs multi-module)
- Read `build.gradle` (root and app) — note minSdk, targetSdk, dependencies,
  productFlavors, buildTypes, ProGuard/R8 configuration
- Read `gradle.properties` — check for AndroidX, Jetifier, JVM args
- Read `settings.gradle` — check for multi-module setup
- Read `AndroidManifest.xml` — note:
  - Package name
  - Application class (if any)
  - All Activities (including secondary/detail screens)
  - Services, BroadcastReceivers, ContentProviders
  - Permissions
  - `APP_RESTRICTIONS` metadata (managed configurations)
  - Launch mode of each Activity

### 2. Source Code Inventory

Read ALL Java/Kotlin source files in the project. For each file, identify:

- **File I/O**: `java.io.File`, `FileInputStream`, `FileOutputStream`,
  `Context.openFileInput()`, `Context.openFileOutput()`, `getFilesDir()`,
  `getCacheDir()`, external storage access
- **SharedPreferences Runtime Usage**: `getSharedPreferences()`,
  `PreferenceManager.getDefaultSharedPreferences()`,
  `EncryptedSharedPreferences` — inventory every steady-state preference
  persistence path. Do **not** plan a leftover `SharedPreferences` copy
  helper (`18-fresh-dynamics-install.md`). Runtime `SharedPreferences`
  usage must be migrated to Dynamics secure storage (see Prompt 05a/05b/05c/05z).
- **SQLite/Database**: `android.database.sqlite.SQLiteOpenHelper`,
  `SQLiteDatabase`, Room database (`@Database`, `Room.databaseBuilder()`),
  `ContentProvider` with database backing, SQLCipher or other encryption
  libraries (`net.zetetic:sqlcipher-android`, `net.sqlcipher.*`)
- **Networking**: `HttpURLConnection`, `URL.openConnection()`, OkHttp,
  Retrofit, `java.net.Socket`, WebSocket, any custom HTTP clients
- **WebView**: `android.webkit.WebView`, `WebViewClient`, `WebChromeClient`,
  JavaScript bridges
- **Policy/Managed Config**: `RestrictionsManager`, `APP_RESTRICTIONS`,
  `BroadcastReceiver` for `ACTION_APPLICATION_RESTRICTIONS_CHANGED`
- **Covered UI Widgets**: every instance of the **direct-replacement
  widget family** defined in `steering/45-secure-ui-widgets.md` §
  "Widget Mapping (direct replacement family)". Sensitivity is recorded
  but does **not** decide migration — all covered widgets migrate
  unless the developer defers `secureUiWidgets` in
  `bootstrap.json.deferredDomains[]`. Also identify custom subclasses
  extending any covered base per the same steering file § "Custom
  Subclasses". WebView is out of scope for this category (see prompt
  `07`).
- **Sharing/ICC — Outbound Data Leakage Risk**: Search for the generic
  sharing detection signals listed in
  `steering/13-unsupported-feature-detection-matrix.md` row "Generic
  file sharing to non-Dynamics apps". If **any** pattern matches,
  prompt 08 (ICC) is **applicable** — do not skip it. See
  `60-icc-transferfileservice.md` for implementation guidance.
- **Compose ICC chooser** (when Jetpack Compose is present and ICC
  sharing applies): in `@Composable` screens, flag
  `MaterialAlertDialogBuilder`, `AlertDialog.Builder`, or
  `TransferFileService.showShareChooser(Activity, …)` used for provider
  selection. Compose-first ICC UX must use the kit
  `GDICCProviderShareDialog` pattern (`templates/icc/GDICCProviderShareDialog.kt`)
  and call `sendFiles` / `GDServiceClient.sendTo` from the selection
  callback — not View-system chooser dialogs inside Compose call chains.
- **Clipboard** (`secureClipboard` domain — prompt `09`): treat **both**
  direct Android clipboard APIs **and** indirect Jetpack Compose clipboard
  abstractions as DLP-sensitive surfaces. See
  `steering/45-secure-ui-widgets.md` § "Secure Clipboard".
  - **Platform clipboard**: `android.content.ClipboardManager`,
    `CLIPBOARD_SERVICE`, `ClipData.newPlainText()` / `setPrimaryClip()` /
    `getPrimaryClip()`, clipboard utility helpers, custom views.
  - **Compose clipboard** (even when `android.content.ClipboardManager`
    is never imported): `LocalClipboardManager.current`,
    `LocalClipboard.current`, imports from
    `androidx.compose.ui.platform.LocalClipboardManager`,
    `LocalClipboard`, `ClipboardManager`, `Clipboard`, `ClipEntry`,
    `clipboardManager.setText()` / `getText()`,
    `clipboard.setClipEntry()` / `getClipEntry()`, `ClipEntry(...)`, and
    variables named `clipboard` / `clipboardManager` assigned from those
    Compose locals.
  - When scanning, include both direct Android clipboard APIs and indirect
    framework clipboard abstractions. Jetpack Compose
    `LocalClipboardManager` and `LocalClipboard` are clipboard surfaces
    even when `android.content.ClipboardManager` is not referenced.
  - Do **not** mark `secureClipboard` as `not-applicable` when only Compose
    clipboard usage is present.
- **Background Processing**: `Service`, `JobIntentService`, `WorkManager`,
  `JobScheduler`, `AlarmManager`, FCM/push notification handling
- **Startup Flow**: What happens in `Application.onCreate()` and the
  launch Activity's `onCreate()` — specifically what data access (database,
  files, network, policy) happens during initialization
- **Version-Gated Code**: `Build.VERSION.SDK_INT` checks against API levels
  below 33 — these become dead code after minSdk bump and may cause compile
  errors if the `else` branch references resources or APIs that don't exist
  at the new minSdk level
- **Third-Party File Libraries and Library-Consumed `File` Arguments**:
  Any API that accepts `java.io.File` or a path string and opens a
  `java.io` stream internally bypasses the Dynamics container. See
  `steering/40-secure-file-storage.md` §5c for the invariant and
  `steering/13-unsupported-feature-detection-matrix.md` rows
  CameraX / ZipFile / ExifInterface / MediaMuxer / MediaRecorder /
  MediaPlayer / PdfRenderer for
  detection signals, `kind` values, and `replacementHint` strings.
  For each detected call site, emit a `callSites[]` entry on the
  `secureFileStorage` execution-plan row with the `kind`, `library`,
  and `replacementHint` values defined in those steering files. Media
  capture/playback/retriever sites that need a seekable FD (class C in
  `steering/41-secure-media.md`) MUST set `ownerPrompt` `"05c"` on the
  matching `egressFeatures[]` entry or on analysis notes consumed by
  prompt 05c, and MUST NOT use `ParcelFileDescriptor.createPipe` as the
  replacementHint for MPEG-4. Also flag image-loading libraries
  (Glide, Picasso, Coil) that expect `java.io.File` per `steering/13`
  row "Unsupported third-party APIs requiring raw filesystem".
- **Redundant Features**: Features that Dynamics replaces at the
  container level — flag for removal per
  `steering/15-redundant-feature-removal.md`. That file defines five
  categories with detection signals and removal guidance:
  biometric/lock screen (Cat 1), app-level backup (Cat 2), database
  encryption/SQLCipher (Cat 3), FLAG_SECURE/screenshot prevention
  (Cat 4), and app-level AES/custom encryption engine (Cat 5). Use
  the "What to Look For" checklist in each category to drive
  detection.
- **Temp File / Plaintext-on-Disk Leakage**: Any code that writes
  sensitive data to the standard Android filesystem, even temporarily.
  See `steering/40-secure-file-storage.md` for the temp-file invariant
  and `steering/13-unsupported-feature-detection-matrix.md` row
  "CameraX `OutputFileOptions.Builder(File)`" for the canonical
  detection signal. Flag for mandatory replacement with in-memory
  processing.
- **Secure media inventory (MANDATORY)**: Scan for MediaRecorder,
  MediaPlayer, VideoView, MediaMuxer, MediaMetadataRetriever,
  ThumbnailUtils, CameraX `androidx.camera.video`, ExoPlayer
  `FileDataSource`, `ACTION_IMAGE_CAPTURE` / `ACTION_VIDEO_CAPTURE`.
  Emit `mediaCapabilities[]` (see JSON template). Classify each entry
  A/B/C/D per `steering/41-secure-media.md`. Class C/D call sites stay
  on domain `secureFileStorage` with `ownerPrompt` `"05c"` (still-capture
  `OutputStream` may remain 05a). Empty inventory makes prompt 05c
  skippable.
- **External / Secondary Storage Data Leakage**: Features that write
  sensitive data outside the Dynamics container. See
  `steering/13-unsupported-feature-detection-matrix.md` row
  "External/secondary storage of sensitive data" for detection signals.
  Flag as high-priority post-migration TODOs per that matrix.
- **Egress Capability Inventory (MANDATORY)**: When a feature's purpose is
  to move protected data outside the Dynamics container, do not treat it as
  a routine API migration. Create a stable `egressFeatures[]` entry for each
  detected capability and classify it using the taxonomy from
  `steering/13-unsupported-feature-detection-matrix.md`:
  `REMOVE`, `REPLACE_WITH_DYNAMICS`, `MANUAL_INTERVENTION_REQUIRED`, or
  `BLOCKED_UNTIL_APPROVED`.
  Typical examples include:
  - Android Auto Backup / backup rules / backup-restore UI
  - manual backup/export/restore outside the container
  - public Downloads / Gallery / MediaStore export
  - generic Android share/open-with/email/viewer/editor flows
  - FileProvider-based sharing / URI-grant workflows
  - unmanaged printing
  - unmanaged clipboard/drag-and-drop export
  - diagnostics/log export, consumer-cloud export, nearby-device transfer,
    local HTTP/desktop transfer, or public-provider export
  For each feature record:
  - stable `id`
  - owning `domain`
  - `ownerPrompt` (`05a`, `05c`, `08`, `09`, or `10`)
  - `category`
  - `featureName`
  - `recommendedOutcome`
  - `userEntryPoint` when user-visible
  - `targetMechanism`
  - `sourceFiles[]`
  - `evidence[]`
  - `secureAlternativeHint` when a Dynamics-safe replacement exists
  Prompt 00 should prefer **feature-level decisions** over trying to model
  every UI affordance as a storage call site.
- **SAF / content-URI trust-boundary flows**: Assign stable call-site IDs
  during analysis for every Storage Access Framework and URI egress/import
  pattern, including:
  - `ACTION_OPEN_DOCUMENT`, `ACTION_GET_CONTENT`, `ACTION_PICK`
  - `ACTION_CREATE_DOCUMENT`, `ActivityResultContracts.CreateDocument`
  - `ActivityResultContracts.OpenDocument`, `OpenMultipleDocuments`,
    `GetContent`, `GetMultipleContents`, `OpenDocumentTree`
  - `ContentResolver.openInputStream`, `openOutputStream`,
    `openFileDescriptor`, `openAssetFileDescriptor`
  - `ACTION_OPEN_DOCUMENT_TREE`, `DocumentFile.fromTreeUri`,
    `takePersistableUriPermission`, persisted `content://` strings
  - `ACTION_SEND`, `ACTION_SEND_MULTIPLE`, `ACTION_VIEW`, `ACTION_EDIT`,
    `Intent.EXTRA_STREAM`, `Intent.setData` / `setDataAndType`,
    `ClipData.newUri`, `Intent.setClipData`, `FLAG_GRANT_*_URI_PERMISSION`
  - `FileProvider.getUriForFile` and provider-path resources

  Classification and ownership:
  - `SAF_INBOUND_IMPORT` -> `secureFileStorage` call site,
    `direction: "inbound"`, `migrationDecision: "MIGRATE_SECURE_COPY"`.
  - `SAF_OUTBOUND_EXPORT` -> `secureFileStorage` call site,
    `direction: "outbound"`, default
    `migrationDecision: "BLOCKED_PENDING_DEVELOPER_APPROVAL"`.
  - `SAF_EXTERNAL_PRIMARY_STORAGE` and `SAF_PLAINTEXT_STAGING` ->
    `secureFileStorage` call site, non-waivable migration/removal.
  - `SAF_URI_SHARING` (`ACTION_SEND`, `ACTION_VIEW`, `EXTRA_STREAM`,
    URI grants, `FileProvider`) -> `icc` call site owned by prompt `08`;
    do not put generic URI-sharing approval in the file-storage row.

  Each SAF call site must include `module`, `direction`,
  `migrationDecision`, `uiEntryPoint` when user-visible, and
  `targetMechanism`. These fields let prompts `05a`, `08`, and `10`
  close/report the same stable ID without rediscovering a different site.
- **Storage Write-Read Pairs (Save/Download/Export Features)**: For each
  external storage write path identified above, also identify the
  **read-back / retrieval chain** — the code that later uses the stored
  reference (URI, path, filename) to find and open the saved file. This
  includes:
  - **Reference producers**: the code that generates the URI or path
    after writing (e.g., `MediaStore.insert()` returns a `content://` URI,
    `SAF` returns a document URI, `File.absolutePath` returns a path)
  - **Reference stores**: where the reference is persisted (DataStore,
    Room, SharedPreferences, protobuf, in-memory list)
  - **Reference consumers**: the code that reads the stored reference to
    display or open the file (e.g., recent documents list,
    `ContentResolver.openInputStream(uri)`, `File(path).exists()`)
  - **UI location text**: string resources that display the save location
    to the user (e.g., "Saved to Downloads")
  
  Record these as `writeReadPair` entries on the `secureFileStorage`
  execution-plan call sites. Each external-storage write site that powers
  a user-facing save/download/export feature should have its read-back
  chain documented so prompt `05a` step 4d can verify the entire
  round-trip is migrated, not just the write path. See
  `steering/40-secure-file-storage.md` §7a.

### 2b. Native / NDK Source Inventory (Mandatory when present)

If the app ships any native code, that code can bypass the Java/Kotlin
Dynamics container surface entirely. Inventory it so the secure-file and
secure-networking domain plans include native call sites, not just
Java/Kotlin.

**Canonical references for this step:**

- `steering/14-api-provenance-and-replacement-catalog.md` § "Native
  (NDK) Direct Replacement Catalog" — the authoritative C/POSIX → `GD_*`
  / `GD_UNISTD_*` mapping tables, header families, and naming rules.
- `steering/13-unsupported-feature-detection-matrix.md` row "Native
  (NDK / C / C++) source bypassing secure container" — detection
  signals, build-config markers, and expected report actions.
- `steering/40-secure-file-storage.md` §1b/§8 — native file I/O
  context.
- `steering/46-native-ndk-direct-replacement.md` — native networking
  context.

Scan every in-scope module for native source files (`*.c`, `*.cc`,
`*.cpp`, `*.cxx`, `*.h`, `*.hpp` under `src/main/`), native build
configuration (`CMakeLists.txt`, `Android.mk`, `externalNativeBuild`),
JNI loading (`System.loadLibrary`, `System.load`), and prebuilt `.so`
libraries (`jniLibs/`).

For each native source file under app control, search for the
direct-replacement call-site patterns listed in
`steering/14` § "Storage (stdio + POSIX file descriptors)" and
§ "Networking (BSD-style sockets)".

Classify each native artifact as one of:

1. **App-controlled native source** — direct replacement applies.
   Every call site must appear as a `callSites[]` entry on the
   matching `executionPlan` row (`secureFileStorage` / `05z` for file
   calls; `secureNetworking` / `06` for socket calls). Set `language`
   to `"C"` or `"C++"`.
2. **Prebuilt `.so` (no source available)** — record as a
   high-priority `manualTodoCandidates[]` entry **and** an
   `unsupportedDetections[]` entry naming the library, the owning
   module, the JNI surface that loads it, and the reason source-level
   proof is unavailable. Do not auto-close any secure domain on
   behalf of prebuilt libraries.
3. **Vendored third-party native source** — treat as case 2 unless
   the developer attests they will edit it in-tree; if they will, treat
   as case 1.

If a POSIX call has no documented `GD_*` / `GD_UNISTD_*` equivalent
in `steering/14`, do **not** invent one — record a manual TODO and
mark the call site unsupported per `steering/13`.

### 3. Layout File Inventory

Read ALL XML layout files. Identify (all of these are in-scope for
migration regardless of whether the call site appears sensitive —
sensitivity is recorded as inventory metadata only, not as a gate):
- Every covered text/search widget tag: `EditText`, `TextView`,
  `AutoCompleteTextView`, `MultiAutoCompleteTextView`, `SearchView`,
  their `AppCompat*` variants, `MaterialTextView`, and
  `TextInputEditText` (see `tooling/lib/ui-widget-catalog.json`
  `replaceRows[]` / `inventoryKinds[]`). The Prompt 00 recorder loads
  that catalog at runtime — do not invent extra widget kinds, and do
  not register `keepNativeRows[]` tags as replace call sites. Note the
  data each carries for the inventory column and lane context; these
  are replace targets per `prompts/09-migrate-ui-widgets.md`.
- Catalog `keepNativeRows[]` widgets (`Button`, `Chip`, `Switch`,
  `Preference*`, Compose text fields, etc.) as residual-risk inventory
  entries only — do not register them as `secureUiWidgets` replace
  call sites.
- `WebView` widgets (handled by prompt `07`).
- Custom `EditText`/`TextView`/etc. subclasses used in layouts —
  these need parent class migration (`GDAppCompatViewInflater`
  cannot auto-substitute custom subclasses).

**Prompt-00 recorder hard gate (layout coverage):**
- `record-prompt-execution.sh --prompt-id 00 --status completed` now
  cross-checks `module-map` in-scope `res/layout*/*.xml` covered widget
  tags against `executionPlan.secureUiWidgets.callSites[]`.
- If any covered layout widget is missing from `callSites[]`, prompt 00
  completion is rejected and you must re-run this analysis before prompt 09.

### 4. Data Sensitivity Classification

Classify the data flowing through each API usage. Sensitivity drives
migration **for storage / networking / sharing / sharedprefs domains**
(filesystem, SharedPreferences, ICC, etc. — see prompts `05a`, `05z`,
`08`). It is **reporting metadata only** for cataloged UI replacement
rows (prompt `09` / steering `45`): every `replaceRows[]` widget migrates
regardless of sensitivity.

- **Sensitive**: Must be migrated to Dynamics secure APIs (credentials,
  PII, business data, tokens, encryption keys)
- **Semi-sensitive**: Should be migrated (user-generated content, messages,
  app state)
- **Non-sensitive**: May remain native with justification (UI cache,
  temporary layout data, public static content) — applies to storage
  and networking domains; **not** an escape for the secureUiWidgets
  domain.

Non-sensitive native-storage exceptions never apply to public storage,
external storage, SAF outbound transfer, URI sharing, FileProvider
exposure, MediaStore writes, URI permission grants, or plaintext staging
of enterprise data. Those surfaces must still receive stable call-site
IDs and a secure migration/removal/blocking decision.

### 5. Produce Migration Plan

Based on the analysis, produce a structured migration plan:

```
## Application Summary
- App name: [from manifest/strings]
- Package: [from manifest]
- Application class: [exists / needs creation]
- Activities: [list all with their roles]
- Services/Receivers: [list all]

## API Usage Inventory

| Category | File | API Used | Data Sensitivity | Migration Action |
|----------|------|----------|-----------------|-----------------|
| File I/O | FileFragment.java | Context.openFileOutput() | Sensitive | → GDFileSystem |
| SQL | ColorDbHelper.java | android.database.sqlite | Sensitive | → com.good.gd.database.sqlite |
| HTTP | HttpFragment.java | HttpURLConnection | Sensitive | → GDHttpClient |
| Socket | SocketFragment.java | java.net.Socket | Sensitive | → GDSocket |
| Policy | PolicyFragment.java | RestrictionsManager | N/A | → GDAndroid.getApplicationPolicy() |
| UI | fragment_file.xml | EditText | Semi-sensitive | → GDEditText |

## Startup Flow Analysis
- Application class: [exists / needs creation]
- Launch Activity onCreate() accesses: [list secure APIs called]
- Data that must be deferred to onAuthorized(): [list]

## Migration Phases (in order)

1. [ ] Gradle integration (SDK dependency, minSdk, Maven repo)
2. [ ] settings.json creation (UEM IDs from `bootstrap.json` via prompt 02 — no UEM prompts here)
3. [ ] Authorization & initialization (Application class, GDStateListener,
       kit-standard activityInit in main-process Activities, supported
       non-kit auth patterns identified, two-phase startup restructuring)
3b.[ ] Authorization deferral audit (ViewModels, Fragments, widgets, receivers, migrations)
4. [ ] Secure SQL database (if applicable — most complex, do first)
5. [ ] Secure file storage (if applicable)
6. [ ] Secure networking (if applicable)
7. [ ] WebView → BBWebView (if applicable)
8. [ ] ICC / secure sharing (if applicable)
9. [ ] Secure UI widgets (if applicable)
3c.[ ] Background Authorize — interactive intent capture per
       `processModel.backgroundEntryPoints[]` candidate. Runs **after**
       the secure-data domains close so the developer can see exactly
       which secure surfaces each background entry point would touch
       before opting in. Migrates, defers, or marks not-applicable on
       a per-candidate basis.
10.[ ] Migration report generation

## Risks and Considerations

Flag the following (detail comes from the canonical steering files — do
not re-enumerate detection signals here):

- Complex patterns, third-party libraries, or edge cases
- Pre-auth secure API access in startup code
- Background processing that needs container access
- Room database usage (bridge layer, not simple import swap)
- Redundant features per `steering/15` (SQLCipher, biometric/lock,
  backup, FLAG_SECURE, app-level encryption engine)
- Temp-file / plaintext-on-disk leakage per `steering/40` §5
- External / secondary storage writes per `steering/13`
- Generic file sharing (ICC required) per `steering/13`
- Library-consumed `File` arguments per `steering/13` + `steering/14`
- UI widget custom subclasses per `steering/45`
- Legacy `GDWebView` usage per `steering/13`
- Native / NDK source per `steering/14` native catalog + `steering/13`
- `Build.VERSION.SDK_INT` checks that become dead code after minSdk bump
```

### 6. Write Structured Analysis Artifact (Required)

**IMPORTANT — File Write Method**: Use a **full-file overwrite** (not a
patch or append) to create this file. In AI IDEs, use the Write/CreateFile
tool — do NOT use StrReplace, ApplyPatch, or any patch-based tool on JSON
output files. Patch tools can append to existing files instead of replacing
them, producing invalid JSON with multiple root objects. If the file
already exists from a previous run, the full-file write will correctly
replace it.

Create `dynamics-migration-tool/output/migration-analysis.json` with:

```json
{
  "schemaVersion": "1.2.0",
  "runId": "copied from bootstrap.json runId",
  "platform": "Android",
  "generatedAt": "ISO-8601",
  "appSummary": {
    "name": "string",
    "package": "string",
    "language": "Java|Kotlin|Mixed",
    "projectShape": "single-module|multi-module",
    "minSdk": "number"
  },
  "domains": [
    {
      "name": "authorization|backgroundAuthorize|securePush|secureFileStorage|secureSql|secureNetworking|webview|icc|secureUiWidgets|secureClipboard|policyManagement|playIntegrity",
      "tier": "tier1|tier2|tier3",
      "status": "applicable|not-applicable",
      "evidence": ["string"],
      "risks": ["string"]
    }
  ],
  "executionPlan": [
    {
      "applicable": true,
      "domain": "secureSql",
      "promptId": "04",
      "rationale": "string — why this prompt must run / why it does not",
      "callSites": [
        {
          "id": "secureSql-app-src-main-java-com-example-DataStore-88",
          "file": "app/src/main/java/com/example/DataStore.java",
          "line": 88,
          "language": "Java",
          "kind": "SQLiteOpenHelper",
          "context": "App database helper extends SQLiteOpenHelper",
          "library": "(optional) top-level package of the library, e.g. androidx.camera.core, java.util.zip, androidx.exifinterface.media, android.media, android.graphics.pdf — present for library-consumed File call sites",
          "replacementHint": "(optional) machine-readable hint mapping 1:1 to a row in the 05a/05c migration sub-table, e.g. Builder(OutputStream)+com.good.gd.file.FileOutputStream, ZipInputStream+com.good.gd.file.FileInputStream, ExifInterface(InputStream)+com.good.gd.file.FileInputStream, MediaMuxer(seekable FileDescriptor)+MemoryFile, MediaRecorder.setOutputFile(MemoryFile fd) — NEVER ParcelFileDescriptor.createPipe for MPEG-4. Downstream prompts and validate.sh consume these when present",
          "writeReadPair": "(optional) present when this write site powers a user-facing save/download/export feature. Object with: { referenceProducer: 'what generates the URI/path after writing', referenceStore: 'where the reference is persisted (DataStore/Room/SharedPreferences/etc.)', referenceConsumers: ['files/methods that read the reference back'], uiLocationText: 'string resource key showing the save location to the user, if any' }. Prompt 05a step 4d uses this to verify the full write-read round-trip is migrated. See steering/40-secure-file-storage.md §7a.",
          "redesignPath": "(optional) in-container | saf-boundary | feature-removal | null for public-storage/SAF/file-sharing redesign sites",
          "direction": "(optional, required for SAF) inbound | outbound | bidirectional",
          "migrationDecision": "(optional, required for SAF) MIGRATE_SECURE_COPY | BLOCKED_PENDING_DEVELOPER_APPROVAL | BLOCK | ALLOW_WITH_DLP_ENFORCEMENT | REPLACE_WITH_SECURE_INTERNAL_FLOW | MANUAL_REDESIGN_REQUIRED",
          "uiEntryPoint": "(optional, required for user-visible SAF/export/share flows) button/menu/deep-link/worker that initiates the flow",
          "targetMechanism": "(optional, required for SAF) ACTION_CREATE_DOCUMENT | ACTION_SEND | ContentResolver.openOutputStream | FileProvider | etc."
        }
      ]
    },
    {
      "applicable": false,
      "domain": "secureFileStorage",
      "promptId": "05z",
      "rationale": "No java.io file or Context.openFile* usage detected",
      "callSites": []
    }
  ],
  "egressFeatures": [
    {
      "id": "egress-share-main-001",
      "domain": "icc",
      "ownerPrompt": "08",
      "category": "generic-sharing",
      "featureName": "External file sharing",
      "recommendedOutcome": "REPLACE_WITH_DYNAMICS",
      "userEntryPoint": "Share menu item",
      "targetMechanism": "ACTION_SEND + FileProvider",
      "sourceFiles": ["app/src/main/java/com/example/ShareHelper.kt"],
      "evidence": ["ACTION_SEND", "FileProvider.getUriForFile", "share menu item"],
      "secureAlternativeHint": "AppKinetics ICC TransferFile with runtime provider discovery"
    }
  ],
  "mediaCapabilities": [
    {
      "id": "media-audio-record-001",
      "kind": "preview|still-capture|audio-record|audio-play|video-record|video-play|metadata-thumb|capture-intent|mediastore-publish",
      "closureClass": "A|B|C|D",
      "ownerPrompt": "05c",
      "apis": ["android.media.MediaRecorder.setOutputFile"],
      "files": ["app/src/main/java/com/example/AudioRecordService.kt"],
      "notes": "Classify per steering/41-secure-media.md. Omit this array or use [] when no media APIs exist (prompt 05c skips)."
    }
  ],
  "unsupportedDetections": [
    {
      "feature": "string",
      "files": ["string"],
      "reason": "string",
      "workaroundDetected": true
    }
  ],
  "manualTodoCandidates": [
    {
      "priority": "blocker|high|medium|low",
      "description": "string",
      "reason": "string"
    }
  ],
  "recommendedPromptOrder": ["00pre","00","01","02","03","03b","04","05a","05b","05c","05z","06","07","08","09","11","03c","10","12"],
  "optionalPromptOrder": ["00b after 00 when architecture diagrams are requested", "12 after 10 when the developer opts in"]
}
```

#### `executionPlan` is mandatory and binding

`executionPlan` is the contract between this analysis and prompt 10's
hard gate (step 9). It maps every conditionally-applicable domain to the
prompt that will migrate it. Required entries (one per row, exactly):

| `domain` | `promptId` |
|---|---|
| `backgroundAuthorize` | `03c` |
| `secureSql` | `04` |
| `secureFileStorage` | `05z` |
| `secureNetworking` | `06` |
| `webview` | `07` |
| `icc` | `08` |
| `secureUiWidgets` | `09` |
| `secureClipboard` | `09` |
| `securePush` | `11` |

Set `securePush` to `applicable: true` when the inventory finds a
`FirebaseMessagingService` subclass and/or `com.good.gd.push` usage.
When neither is present, set `applicable: false` with
`rationale: "no FCM or Push Channel usage detected"`.

Applicability for `backgroundAuthorize` is determined in **two stages**,
reflecting the BlackBerry Dynamics SDK 15.0 posture that Background
Authorize is generally available but **opt-in** at both the app config
and UEM profile levels:

1. **Candidate discovery (this prompt, deterministic).** Set
   `applicable: true` if and only if
   `bootstrap.json.processModel.backgroundEntryPoints[]` is **non-empty**,
   and copy each entry's `name` / `module` / `kind` / `baseClass` /
   `manifest` into the `callSites[]` array (`id` = stable
   `backgroundAuthorize-<module>-<name>-<kind>`). When the bootstrap
   recorded zero entries, set `applicable: false` with
   `rationale: "no background entry points detected"` and Phase 3b
   becomes a no-op.
2. **Developer intent capture (prompt 03c, interactive).** Each
   candidate carries a status of *needs a decision* until prompt
   `03c-background-authorize.md` records per-candidate
   `intent ∈ { migrate, deferred, not-applicable }` into
   `bootstrap.json.backgroundAuthorize.decisions[]`. The mapping from
   intent to closure is:
   - `migrate` → prompt 03c applies the canonical
     `canAuthorizeAutonomously` + `serviceInit` pattern; Phase 3b
     enforces the structure and the `GDEnableBackgroundAuthorize: true`
     setting.
   - `deferred` → prompt 03c records the developer's rationale in
     `backgroundAuthorize.decisions[]` only (agent must not edit
     `deferredDomains[]`); Phase 3b always routes deferred candidates
     through `fail_or_defer` (including when other candidates migrated in
     the same run) and downgrades the scoped check to `check_warn`.
   - `not-applicable` → the developer confirms the candidate does not
     touch secure Dynamics APIs at runtime; Phase 3b records an
     audit-pass line. No source edit and no settings change.

`backgroundAuthorize` is therefore a **waivable** domain (it is **not**
in the non-waivable set). Prompt 10's final sweep refuses to write a
report until **every** candidate in `backgroundEntryPoints[]` has a
matching entry in `backgroundAuthorize.decisions[]`
(`backgroundAuthorizeDecisionsCaptured` gate), so the opt-in cannot be
skipped silently.

For each row, set `applicable: true` if the domain is in scope for this
app (based on the inventory) and `false` if it is not, with a
`rationale` string explaining the call. Domains marked `applicable:
true` MUST either be migrated by their owning prompt or be present in
`bootstrap.json`'s `deferredDomains[]` before prompt 10 will run —
otherwise the prompt 10 hard gate aborts. `backgroundAuthorize` is the
exception: it is closed by `bootstrap.backgroundAuthorize.decisions[]`
plus Phase 3b, not by `migration-plan-state.json`.

#### `egressFeatures[]` worklist

`egressFeatures[]` is the feature-level inventory for capabilities whose
purpose is to move protected data outside the Dynamics container. Use it for
business capabilities such as backup/export/share/open-with/printing, not just
for low-level API survivors.

Owner mapping:

| Feature family | `ownerPrompt` |
|---|---|
| backup/export/public storage/download/gallery/media containment | `05a` |
| audio/video capture, playback, retriever, CameraX video (class C/D) | `05c` |
| share/open-with/external viewer/email/ICC replacement | `08` |
| clipboard/drag-drop/printing/screen-export DLP surfaces | `09` |
| report-only/manual follow-up items with no earlier owning prompt | `10` |

Rules:

1. If Prompt 00 detects an egress-capability feature, add an
   `egressFeatures[]` entry with a stable `id`.
2. Use `recommendedOutcome` from the baseline taxonomy in `steering/13`:
   `REMOVE`, `REPLACE_WITH_DYNAMICS`, `MANUAL_INTERVENTION_REQUIRED`, or
   `BLOCKED_UNTIL_APPROVED`.
3. `REMOVE` means the later prompt should strip the feature rather than try
   to preserve it.
4. `REPLACE_WITH_DYNAMICS` means the later prompt must remove the original
   Android path and replace it only with the documented Dynamics-safe
   boundary.
5. `BLOCKED_UNTIL_APPROVED` means the later prompt should disable the
   visible action and make the underlying code path unreachable before
   asking the developer whether the capability should return.
6. `MANUAL_INTERVENTION_REQUIRED` means the later prompt must not auto-migrate
   the original path; it should carry the decision into
   `migration-plan-state.json` and the final report instead.
7. `targetMechanism` must name the concrete Android surface when known
   (`ACTION_SEND`, `ACTION_CREATE_DOCUMENT`, `PrintManager`,
   `android:allowBackup`, `MediaStore`, etc.).

#### `callSites[]` worklist (M2 — schema 1.2.0)

For every `executionPlan` row whose `promptId` is **`04`**, **`05z`**,
**`06`**, **`08`**, or **`09`**:

1. Include a **`callSites` array** on the row (required key).
2. If `applicable: true`, list **every sensitive call site** the inventory
   found for that domain (one object per site). Use stable, unique
   **`id`** strings (see `steering/79-migration-plan-state-and-call-site-closure.md`).
3. If `applicable: false`, set **`callSites` to `[]`**.
4. If `applicable: true` and the inventory genuinely found **zero** call
   sites, `callSites` may be `[]` **only** for data-plane domains (`04` /
   `05z` / `06`) — state that explicitly in `rationale`. For **`icc`**,
   **`secureUiWidgets`**, and **`secureClipboard`** (`08` / `09`), an
   applicable row with empty `callSites[]` is a contract violation unless
   the domain is `not-applicable`.
5. Each `callSites[*]` entry **must** include a `module` field — the
   Gradle module name owning that file, taken from `module-map.json`
   (`primaryAppModule.name` or one of `libraryModulesInScope[*].name`).
   Prompts 04/05z/06 propagate this `module` value into the matching
   `dispositions[*]` row in `migration-plan-state.json`.
6. For `secureFileStorage` call sites that use MediaStore,
   `getExternalFilesDir`, SAF import/export, external primary storage, or
   other public-storage signals, add optional **`redesignPath`**:
   `"in-container" | "saf-boundary" | "feature-removal" | null` per
   `steering/40-secure-file-storage.md` §7 and
   `steering/44-saf-trust-boundary.md`. Non-null values become the
   redesign worklist for prompts `05a`–`05z` and block ICC until storage closes.
   If `redesignPath` is `"saf-boundary"`, the call site must also include
   `direction`, `migrationDecision`, `uiEntryPoint` when user-visible, and
   `targetMechanism`. Outbound SAF export defaults to
   `BLOCKED_PENDING_DEVELOPER_APPROVAL`; prompt `05a` implements the
   safe block first and asks the developer whether the lost feature
   should remain blocked, move to ICC, or be explicitly re-enabled with
   verified runtime DLP. Do not propose "one-shot SAF export" as the
   default migration. Camera/media apps should prefer `in-container` for
   managed gallery / latest-preview redesign and use `saf-boundary` only
   for explicit user-initiated export, never as the app-owned media store
   of record.
7. For `SAF_URI_SHARING` / generic file-open/share call sites, place the
   stable ID on the `icc` execution-plan row (`promptId: "08"`) with
   `direction: "outbound"`, default
   `migrationDecision: "REPLACE_WITH_SECURE_INTERNAL_FLOW"` when ICC is
   feasible or `BLOCKED_PENDING_DEVELOPER_APPROVAL` when the immediate
   safe outcome is removal/blocking pending product decision.
8. Independent-evidence closure is file-based, not just call-based. When the
   validator will later rediscover import-only bridge or inventory surfaces
   (for example DAO/entity files, GDRoom bridge helpers, or read-only widget
   support files), include those files in `callSites[]` with stable IDs and a
   clear `context` instead of assuming prompt 10 can infer them after the fact.
   This keeps prompt 10 from exploding into dozens of audit-only inventory
   misses after the real migration work is already done.
9. **Native (NDK) call sites** identified in step 2b feed the same
   `callSites[]` worklist. Each entry must have:
   - `language: "C"` or `"C++"` (in addition to the existing
     `Java`/`Kotlin` values),
   - `kind` matching the C/POSIX name (e.g. `fopen`, `GD_fopen-target`,
     `socket`, `connect`),
   - `file` pointing at the `.c` / `.cpp` / `.h` / `.hpp` source.
   File-system native calls go on the `secureFileStorage` row
   (`promptId: "05z"`). Socket / name-resolution native calls go on
   the `secureNetworking` row (`promptId: "06"`). Prebuilt `.so`
   libraries do **not** become `callSites[]` entries — they go in
   `manualTodoCandidates[]` and `unsupportedDetections[]`.

Also create **`dynamics-migration-tool/output/migration-plan-state.json`**
immediately after analysis (full-file overwrite):

```json
{
  "schemaVersion": "1.1.0",
  "runId": "copied from bootstrap.json runId",
  "egressFeatureDecisions": [],
  "dispositions": []
}
```

Prompts **04**, **05z**, **06**, **08**, and **09** append dispositions here
as they close each call site. Prompt **10** refuses final completion until
every listed `callSites[].id` has a matching disposition or a valid domain
deferral exists (see steering 79).

Authorization (prompt 03 / 03b), gradle setup (prompt 01),
configuration (prompt 02), and policy management are NOT part of the
execution plan — they are unconditional and always run.

This artifact is mandatory input for Prompt 10 report generation.

---

## Output

- Complete API usage inventory table
- Data sensitivity classification for each usage
- Startup flow analysis (what runs before authorization is possible)
- Ordered migration plan with applicable/not-applicable phases marked
- Risks, edge cases, and items requiring developer input
- `dynamics-migration-tool/output/migration-analysis.json` (required)
- `dynamics-migration-tool/output/migration-plan-state.json` (required — seed `egressFeatureDecisions: []` and `dispositions: []`)

---

## Critical Rules

- Do NOT make any code changes during this step — analysis only
- Do NOT skip reading any source file — every file must be inventoried
- Do NOT assume what the app does — read the code
- Flag any patterns that will require special handling (e.g., database
  access in onCreate, background services, custom ContentProviders)
- If the app has no Application class, note that one must be created
- If the app has multiple Activities, list all of them with process
  classification and any existing Dynamics monitoring mechanism. Main-process
  Activities follow the kit-standard `activityInit()` policy; auxiliary
  Activities must not call it.
- Write `migration-analysis.json` even if some sections are mostly empty
- `executionPlan` is mandatory and binding — every row in the table
  above must be present, with `applicable: true|false` and a non-empty
  `rationale`. Prompt 10's hard gate refuses to write a report if any
  applicable row is missing both an executed prompt and a developer
  deferral
- `schemaVersion` in `migration-analysis.json` must be **`1.2.0`** when
  emitting `callSites` (M2 worklist). Prompt 00 must also write empty
  `migration-plan-state.json` as documented above
- `runId` must be copied from `bootstrap.json` into both
  `migration-analysis.json` and `migration-plan-state.json` and then
  preserved unchanged throughout the run
- Do NOT run an ad-hoc `./gradlew dependencies` probe in this step —
  consult `bootstrap.json` for SDK status. The bootstrap is
  authoritative and has already verified the SDK class index

---

## Record execution

After `migration-analysis.json` is written, append the execution record:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 00 \
    --status completed \
    --files-touched "dynamics-migration-tool/output/migration-analysis.json,dynamics-migration-tool/output/migration-plan-state.json"
```

---

## Next Step

After this analysis is complete, run **01-gradle-integration.md** unless
the developer invoked the toolkit with `--with-diagrams` or explicitly
requests diagrams. In that optional path, run
**00b-generate-architecture-diagrams.md** first to produce data flow
diagrams, storage/network classification maps, lifecycle dependency maps,
a secure API call graph, authorization boundary declarations, and a
migration risk heatmap.


### Enterprise hardening domain

Add `playIntegrity` to `domains[]` and set applicability explicitly. If marked applicable, include a manual todo/release gate until attestation configuration is complete.

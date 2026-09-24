# Migration Checklist

Use this checklist to track BlackBerry Dynamics integration progress.

> **Multi-module note**: every `app/src/main/...` reference and every
> `rg ... app/src/main/java/` example below is a canonical-shape
> illustration. On multi-module projects, expand placeholders from
> `dynamics-migration-tool/output/module-map.json`:
>
> - `app/src/main/assets/settings.json` →
>   every entry in `${primary_assets_dirs}` (main + each declared
>   product flavor / build type).
> - `app/src/main/AndroidManifest.xml` → every entry in
>   `${primary_manifests}`.
> - `app/build.gradle(.kts)` → `${primary_build_file}` (and
>   `${convention_plugin_files}` for Android config blocks routed
>   through Kotlin convention plugins).
> - `rg ... app/src/main/java/` → `rg ... ${in_scope_main_src}`
>   (primary module + every entry in `libraryModulesInScope[]`).
>
> Full placeholder definitions and per-domain scope rules live in
> `04-multi-module-projects.md`.

---

## Evidence Discipline (All Security Domains)
- [ ] For each security-sensitive migration decision, use kit-contained evidence only: steering guidance, prompt rules, templates, and validator outputs
- [ ] Phrase constraints precisely: if an API exists but is prohibited by enterprise policy, document as "disallowed by this kit" (not "unsupported by SDK")
- [ ] Prefer validator checks that hard-fail explicit unsafe behavior; treat broad ambiguous patterns as review warnings or fail-or-defer
- [ ] For ripgrep examples, use `rg -g "<glob>"` (not `rg --include`)

---

## Phase 1: Project Setup
- [ ] Run Prompt 00 (analyze-app) — produce flat API inventory
- [ ] Run Prompt 00b (architecture-diagrams) — produce lifecycle dependency map, data flow diagram, secure API call graph, storage/network classification, risk heatmap
- [ ] Review architecture diagrams — identify all pre-auth secure API chains
- [ ] Identify redundant features (see `15-redundant-feature-removal.md`):
  - [ ] App-level biometric / lock screen (replaced by Dynamics container lock)
  - [ ] App-level database encryption / SQLCipher (replaced by Dynamics secure SQLite)
  - [ ] App-level backup mechanisms (replaced by Dynamics container backup)
  - [ ] App-level screenshot / screen-recording prevention / FLAG_SECURE (replaced by UEM DLP policy)
- [ ] Add BlackBerry Maven repository to build.gradle
- [ ] Add Dynamics SDK dependency (`android_handheld_platform`)
- [ ] Add `android_handheld_resources` dependency
- [ ] Add `android_handheld_backup_support` dependency (recommended)
- [ ] Remove redundant dependencies (SQLCipher, biometric lock libraries, app backup libraries)
- [ ] Sync Gradle and verify no conflicts
- [ ] Verify minSdk is 33+ (required for Dynamics SDK 15.1)
- [ ] Confirm Dynamics SDK pin is `15.1.8766.18` (or a later approved 15.x build)
- [ ] Confirm `android_handheld_blackberry_protect_support` is absent (removed in SDK 15.0)
- [ ] Verify Java 17 compatibility
- [ ] Verify AndroidX is enabled (`android.useAndroidX=true`)
- [ ] Review ProGuard/R8 rules if minification enabled
- [ ] Add `-dontwarn com.good.gd.**` to ProGuard rules

## Phase 2: Configuration
- [ ] Create `app/src/main/assets/settings.json`
- [ ] Obtain GDApplicationID from UEM administrator
- [ ] Configure entitlement in UEM or Developer Portal
- [ ] Set GDApplicationVersion to match app version

## Phase 3: Authorization & Initialization
- [ ] Scan for existing supported non-kit Dynamics authorization patterns (`authorize(...)`, `GDMonitorActivity`, replacement Activity classes, `GDStateAction`, `applicationInit(...)`) and record whether each is converted or intentionally preserved
- [ ] Create or modify Application class
- [ ] Implement GDStateListener in Application class (kit-standard global listener)
- [ ] Call `setGDStateListener(this)` in Application.onCreate()
- [ ] Add `isContainerAuthorized` static boolean flag
- [ ] Add observable `authorized` LiveData field (for reactive deferral)
- [ ] Add `runOnAuthorized()` helper (for one-shot callback deferral)
- [ ] Register Application class in AndroidManifest.xml (`android:name`)
- [ ] Add `GDAndroid.getInstance().activityInit(this)` exactly once to every main-process Activity launch path governed by the kit policy
- [ ] Implement all 7 GDStateListener callbacks
- [ ] Handle onAuthorized, onLocked, onWiped states
- [ ] Handle manifest merger conflicts (`tools:replace`)
- [ ] Restructure app startup: move secure API access from onCreate() to onAuthorized()
- [ ] Test authorization flow with UEM

## Phase 3b: Authorization Deferral Audit (see `21-authorization-deferral-patterns.md`)
- [ ] Audit ViewModel `init {}` blocks — defer database init until `authorized` emits true
- [ ] Add `databaseReady` LiveData signal to ViewModels that defer database init
- [ ] Audit Fragment `onViewCreated()` — defer data observation until `databaseReady` is true
- [ ] Audit BroadcastReceivers — add `isContainerAuthorized` guards before secure API access
- [ ] Audit app widget factories/providers — defer database access until authorized
- [ ] Audit data migration / schema upgrade code — wrap in authorization observer
- [ ] Audit utility functions that create directories or access GD file APIs — add guards
- [ ] Audit `!!` (non-null assertions) on deferred fields — convert to `?.` safe calls
- [ ] Run systematic grep audit (see checklist in `21-authorization-deferral-patterns.md`)

## Phase 4: Secure Databases
- [ ] Inventory all SQLite/Room usage
- [ ] Replace android.database.sqlite.* with com.good.gd.database.sqlite.*
- [ ] Create Room bridge adapter files (if Room is used)
- [ ] Handle SQLiteTransactionListener type mismatch (if Room)
- [ ] Handle query binding conversion (if Room)
- [ ] Verify database initialization happens after authorization
- [ ] Test database operations
- [ ] Verify schema migrations work

## Phase 5: Secure File Storage
- [ ] Inventory all file I/O operations
- [ ] Classify storage flows by API surface (Dynamics container vs Android sandbox vs external/public storage)
- [ ] Replace Context.openFileInput/Output with GDFileSystem
- [ ] Replace **every** `java.io.File` with `com.good.gd.file.File` (do not leave `java.io.File` construction in app data paths)
- [ ] Replace **every** `java.io.FileInputStream`/`FileOutputStream` with `com.good.gd.file.FileInputStream`/`FileOutputStream`
- [ ] Evaluate third-party library compatibility (Glide, ZipFile, CameraX, etc.)
- [ ] **Migrate or remove** external/secondary storage writes (see `40-secure-file-storage.md`):
  - [ ] Replace `getExternalStorageDirectory()`, `getExternalFilesDir()`, `getExternalCacheDir()` with container-relative paths
  - [ ] Remove `MediaStore` writes — store media in the GD container instead
  - [ ] Replace `FileProvider` sharing with non-Dynamics apps with ICC (`GDServiceClient.sendTo`) or remove
  - [ ] Remove "save to device" / "export to SD card" features (replace with in-container storage or one-shot SAF export)
- [ ] **Implement** `SecurePreferencesHelper` for SharedPreferences persistence (see `42-secure-storage-sharedpreferences.md`)
- [ ] **Do not** add a leftover SharedPreferences copy helper (`18-fresh-dynamics-install.md`)
- [ ] Replace native POSIX file I/O (`fopen`, `open`, etc.) with `GD_fopen`, `GD_UNISTD_open` equivalents
- [ ] Test file read/write operations
- [ ] Verify data encryption

## Phase 6: Secure Networking
- [ ] Inventory all networking code
- [ ] Replace HttpURLConnection with GDHttpClient or compatible
- [ ] Replace Socket with GDSocket
- [ ] Update OkHttp/Retrofit if used (add BBCustomInterceptor)
- [ ] Test network requests
- [ ] Verify policy enforcement (try blocked domains)

## Phase 7: Policy Management
- [ ] Remove Android Managed Configurations (if present)
- [ ] Replace RestrictionsManager with GDAndroid policy APIs
- [ ] Implement onUpdatePolicy callback
- [ ] Test policy updates from UEM
- [ ] Verify app behavior under different policies

## Phase 8: Secure UI Widgets
- [ ] Inventory **every** covered standard/AppCompat/Material text/search widget from `tooling/lib/ui-widget-catalog.json` `replaceRows[]` (sensitivity is recorded but does not gate migration — see steering 45)
- [ ] Choose one lane and keep it: Lane A (`GDAppCompatViewInflater`, keep standard XML tags) or Lane B (explicit `GD*` XML). Do not mix.
- [ ] If the app is already Lane B, finish Lane B — do not install the inflater on top of `GDTextView`/`GDEditText` tags
- [ ] Keep `keepNativeRows[]` widgets native (`Button`, `Chip`, `TextInputLayout`, Preferences, Compose text, …)
- [ ] Update Java/Kotlin bindings to the catalog safe bind types (Lane A: Android/AppCompat base types, never `GDTextView`/`GDEditText`)
- [ ] Migrate custom EditText/TextView subclasses: change root parent class from `AppCompatEditText`/`AppCompatTextView` to `GDAppCompatEditText`/`GDAppCompatTextView`
- [ ] Verify no custom subclasses still extend `AppCompatEditText`/`AppCompatTextView` (`rg "AppCompatEditText|AppCompatTextView" -g "*.java" -g "*.kt" -n app/src/main/java/ | rg "class "`)
- [ ] Migrate platform clipboard: replace `android.content.ClipboardManager` with `com.good.gd.content.ClipboardManager`
- [ ] Migrate Compose clipboard: replace `LocalClipboardManager` / `LocalClipboard` usage with kit `GDClipboardAdapter` (see `templates/clipboard/GDClipboardAdapter.kt` and steering 45 § Compose clipboard)
- [ ] Verify no `android.content.ClipboardManager` imports remain (`rg "android.content.ClipboardManager" -g "*.java" -g "*.kt" -n app/src/main/java/`)
- [ ] Verify no unmanaged Compose clipboard APIs remain (`rg "LocalClipboardManager|LocalClipboard\\.current|setClipEntry|getClipEntry" -g "*.kt" -n app/src/main/java/` — expect zero after migration)
- [ ] Test UI functionality
- [ ] Verify DLP copy/paste enforcement (both programmatic clipboard AND system copy/paste action bar)
- [ ] Verify screenshot protection

## Phase 9: Optional Features
- [ ] WebView → BBWebView (if applicable) — see `50-webview-bbwebview.md`
- [ ] ICC for secure sharing (if applicable) — see `60-icc-transferfileservice.md`
- [ ] Compose ICC chooser: replace `MaterialAlertDialogBuilder` / `showShareChooser(Activity, …)` in `@Composable` ICC flows with `GDICCProviderShareDialog` (`templates/icc/GDICCProviderShareDialog.kt`)
- [ ] Verify no unmanaged Compose ICC chooser patterns remain (phase 8b / `compose-icc-chooser-scan.py` — expect pass after migration)
- [ ] AppCompat auto-substitution (`GDAppCompatViewInflater`) (if applicable)
- [ ] Application config cache-and-refresh (if using `getApplicationConfig`) — see `73a-app-config-read-and-refresh.md`
- [ ] Push Channel / FCM hardening (if applicable) — see `78-push-channel.md`, prompt `11`
- [ ] Background Authorize for push/FCM (if applicable) — see `70-background-authorize.md`, prompt `03c`
- [ ] Launcher customization (if needed) — see `71-launcher-branding-nightmode.md`
- [ ] Branding API (custom logo/colors) (if desired)
- [ ] Night Mode support (if applicable)
- [ ] Custom UEM policies (if applicable) — see `72-local-compliance-and-custom-policies.md`
- [ ] DLP watermark (if required by organization)
- [ ] Local compliance (executeBlock/executeUnblock) (if applicable)
- [ ] Certificate management (if applicable) — see `75-certificates-kerberos.md`
- [ ] Play Integrity attestation (if required) — see `73-play-integrity-attestation.md`

## Phase 10: Testing & Validation
- [ ] Test authorization flow (first launch)
- [ ] Test with valid UEM credentials
- [ ] Test with invalid credentials
- [ ] Test policy enforcement
- [ ] Test data persistence across app restarts
- [ ] Test wipe functionality
- [ ] Test lock/unlock scenarios
- [ ] Perform security audit
- [ ] Review logs for Dynamics errors

## Phase 11: Documentation
- [ ] Document entitlement setup process
- [ ] Document testing procedures
- [ ] Document policy configuration
- [ ] Update README with Dynamics requirements
- [ ] Document known limitations
- [ ] Verify all migration points have `[BB_DYNAMICS-MIGRATION]` inline comments (`rg "\[BB_DYNAMICS-MIGRATION\]" -g "*.java" -g "*.kt" -g "*.xml" -g "*.gradle" -n`)
- [ ] Generate `Dynamics_Migration_Readme.md` at project root (produced by Prompt 10)

---

## Verification Commands

```bash
# Check for remaining non-secure APIs
grep -r "java.io.File" app/src/main/java/
grep -r "android.database.sqlite" app/src/main/java/
grep -r "java.net.Socket" app/src/main/java/
grep -r "HttpURLConnection" app/src/main/java/
grep -r "RestrictionsManager" app/src/main/java/

# Verify Dynamics imports
grep -r "com.good.gd" app/src/main/java/

# Verify all migration points are annotated with inline comments
rg "\[BB_DYNAMICS-MIGRATION\]" -g "*.java" -g "*.kt" -g "*.xml" -g "*.gradle" -n

# Clipboard DLP audit (see 45-secure-ui-widgets.md)
# Verify no standard Android ClipboardManager remains
rg "android.content.ClipboardManager" -g "*.java" -g "*.kt" -n app/src/main/java/

# Custom subclass DLP audit (see 45-secure-ui-widgets.md)
# Verify no custom EditText/TextView subclasses still extend AppCompat (bypasses system copy/paste DLP)
rg "AppCompatEditText|AppCompatTextView" -g "*.java" -g "*.kt" -n app/src/main/java/ | rg "class "

# External storage data leakage audit (see 40-secure-file-storage.md)
rg "getExternalStorageDirectory|getExternalFilesDir|getExternalCacheDir|getExternalFilesDirs" \
  -g "*.java" -g "*.kt" -n app/src/main/java/
rg "MediaStore\.|ACTION_SEND|FileProvider" -g "*.java" -g "*.kt" -n app/src/main/java/

# FLAG_SECURE / screenshot prevention audit (see 15-redundant-feature-removal.md)
rg "FLAG_SECURE|setFlags|clearFlags" -g "*.java" -g "*.kt" -n app/src/main/java/

# Authorization deferral audit (see 21-authorization-deferral-patterns.md)
# Verify all database access points are guarded or deferred
rg "getDatabase|getWritableDatabase|getReadableDatabase" -g "*.java" -g "*.kt" -n app/src/main/java/
# Verify all GD file access points are guarded or deferred
rg "GDFileSystem|GDFileHelper|com\.good\.gd\.file" -g "*.java" -g "*.kt" -n app/src/main/java/
# Verify ViewModel init blocks don't access secure APIs without deferral
rg "init \{" -g "*.kt" -n app/src/main/java/ | rg -i "model|viewmodel"
# Verify BroadcastReceivers have authorization guards
rg "onReceive|BroadcastReceiver" -g "*.java" -g "*.kt" -n app/src/main/java/
# Verify widget code defers database access
rg "RemoteViewsFactory|AppWidgetProvider" -g "*.java" -g "*.kt" -n app/src/main/java/
# Verify migration/upgrade code is deferred
rg "migration|upgrade|schema|runMigrations" -g "*.java" -g "*.kt" -n app/src/main/java/
```

---

## Success Criteria

[OK] App authorizes successfully with UEM  
[OK] All steady-state app data uses Dynamics secure storage  
[OK] All network traffic goes through Dynamics  
[OK] Policy updates are received and applied  
[OK] App handles lock/wipe scenarios correctly  
[OK] No data leakage through screenshots or clipboard  
[OK] App passes security audit

## Validator-first closure

Use `dynamics-migration-tool/tooling/validate.sh` as the canonical closure gate for migration hardening. Keep ad-hoc grep checks as exploratory aids only; final readiness is determined by validator phase pass/fail.

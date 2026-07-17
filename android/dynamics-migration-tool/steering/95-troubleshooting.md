# Troubleshooting Guide

Common issues and solutions during Dynamics migration.

> **Multi-module note**: every `app/src/main/...`, `app/build.gradle`,
> and `rg ... app/src/main/java/` reference below is canonical-shape
> illustration. On multi-module projects, expand placeholders from
> `dynamics-migration-tool/output/module-map.json`:
>
> - `app/src/main/assets/` → every entry in `${primary_assets_dirs}`.
> - `app/src/main/AndroidManifest.xml` → every entry in
>   `${primary_manifests}`.
> - `app/build.gradle(.kts)` → `${primary_build_file}` (and any
>   `${convention_plugin_files}` entry for Android config blocks
>   routed through Kotlin convention plugins).
> - `rg ... app/src/main/java/` → `rg ... ${in_scope_main_src}`.
>
> See `04-multi-module-projects.md` for full placeholder rules.

---

## Agent Behavior Issues

### Agent Reports "Blocked by Non-Waivable Findings" Without Fixing Them

**Symptoms**: The agent stops at prompt 05a or 05c and produces a long
list of "remaining findings" — `java.io.File` construction,
SharedPreferences, external storage APIs — and says they "require
product/security decisions" or "manual intervention."

**Cause**: The agent is treating findings as stop-signals instead of
implementing the documented fixes.

**Fix**: Tell the agent:

> Read `steering/03-implementation-first-conduct.md`. Your job is to
> implement the migration, not flag findings. Replace `java.io.File`
> with `com.good.gd.file.File`. Implement `SecurePreferencesHelper` for
> SharedPreferences persistence. Remove or migrate external storage writes
> to container paths. For each finding, apply the direct replacement
> from the API catalog before moving to the next one.

The agent should work through the decision ladder: direct API
replacement → pattern redesign → feature removal → partial migration →
true blocker (last resort only).

### Agent Stops After One Domain Fails

**Symptoms**: The agent resolves authorization and SQL but stops
entirely when file storage has unresolved findings, skipping networking,
UI widgets, ICC, and the report.

**Cause**: The agent treats one unresolved domain as a reason to
abandon the entire migration.

**Fix**: Tell the agent:

> An unresolved finding in file storage does not block networking, UI
> widgets, or other domains. Continue to the next prompt. Record
> unresolved call sites in `manualTodos[]` and proceed.

### Prompt 10 / Final Validation Loop

**Symptoms**: The agent repeatedly runs prompt 10 or `validate.sh --mode final-source`,
failure counts move around between runs, and real blockers are buried under a
large pile of inventory noise.

**Cause**: The agent is treating prompt 10 as a repair loop instead of a final
gate. Earlier gate failures can hide later categories, and import-only evidence
surfaces can look indistinguishable from real data-path regressions unless the
agent triages them first.

**Fix**:
1. Fix **Phase 0 / bootstrap contract** failures first.
2. Fix **security blockers / real data-path failures** next.
3. Then clean up **independent-evidence inventory-only** findings by
   backfilling Prompt-00 `callSites[]` inventory and matching
   `migration-plan-state.json` `dispositions[]`.
4. Use targeted checks before another full sweep:
   - `bash dynamics-migration-tool/tooling/validate.sh --check-prompt 05c`
   - `bash dynamics-migration-tool/tooling/validate.sh --check-prompt 08`
   - `bash dynamics-migration-tool/tooling/validate.sh --check-prompt 09`
5. Only re-run prompt 10 after the owner-prompt checks stop producing new
   categories of failures.

### ESCALATION REQUIRED (Exit Code 3)

**Symptoms**: `validate.sh` or `record-prompt-execution.sh` exits with code `3`
and prints `ESCALATION REQUIRED`.

**Cause**: Bounded retry detected repeated no-progress failures for the same
prompt/stage signature, or prompt-level failure churn exceeded the configured
budget in `tooling/check-prompt-map.json` `retryPolicy`.

**Fix**:
1. Stop rerunning the same broad gate.
2. Inspect:
   - `dynamics-migration-tool/output/migration-loop-state.json`
   - `dynamics-migration-tool/output/.last-source-check.json` or
     `dynamics-migration-tool/output/.last-report-check.json`
3. Route fixes to the owner prompt/domain (`05c`, `08`, `09`, etc.) and run
   `validate.sh --check-prompt <id>` before another prompt-10 attempt.
4. If the escalation is environment/config-related, fix toolchain/network
   issues first, then retry.

### `deferredDomains[]` Looks Present But Still Doesn't Work

**Symptoms**: `bootstrap.json` has a `deferredDomains[]` entry, but prompt 10
or `validate.sh` still hard-fails the domain as if no deferral exists.

**Cause**: The entry is incomplete. Phase 0 ignores deferrals that are missing
required fields.

**Fix**: Ensure every developer-authored entry includes all of:
- `developerSignedOff: true`
- `classification: "plannedInNextRelease"` or `"acceptedResidualRisk"`
- `expiresAt` as a future ISO-8601 UTC timestamp
- non-empty `reason`

Also remember: the **developer** edits `deferredDomains[]`; the agent must not
invent or auto-write those entries.

### Independent Evidence Explodes Into Dozens of Findings

**Symptoms**: Prompt 10 reports a large batch of independent-evidence findings
for DAO/entity files, GDRoom helpers, adapters, or read-only widget imports
after the main migration is already complete.

**Cause**: Prompt 00 inventory was too narrow. The validator rediscovered files
that belong in the audit trail, but they never received `callSites[]` IDs or
matching `dispositions[]`.

**Fix**:
1. Treat uncovered **data-path** findings as real migration work.
2. Treat uncovered **bridge/read-only-ui/inventory** findings as audit gaps.
3. Re-run Prompt 00 inventory logic for those files, add stable `callSites[]`
   entries, then add matching `dispositions[]` rows once the owning domain is
   truly migrated or removed.

### "Scaffolding-Only" Failure In A Kotlin Project

**Symptoms**: Phase 4 says GD imports exist but no real call sites were found,
even though the code uses `FileOutputStream("path")` / `FileInputStream("path")`
in Kotlin.

**Cause**: The migration is only valid when those constructors resolve to
`com.good.gd.file.*`. Older repair attempts often mixed correct Kotlin syntax
with invented `GDFileSystem.mkdirs(...)` helpers or stale `java.io` imports.

**Fix**:
- Keep `import com.good.gd.file.FileOutputStream` /
  `import com.good.gd.file.FileInputStream`
- Use Kotlin constructors directly: `FileOutputStream("logs/app.log")`
- Do **not** invent `GDFileSystem.mkdirs(...)`, `GDFileSystem.exists(...)`,
  or similar static helpers. Use `com.good.gd.file.File(...).mkdirs()` and
  other `File` instance methods for path operations.

---

## Authorization Issues

### App Won't Authorize

**Symptoms**: Stuck on authorization screen, "Not Authorized" error

**Checks**:
1. Verify `settings.json` exists in `app/src/main/assets/`
2. Verify GDApplicationID matches UEM entitlement
3. Verify app is provisioned in UEM
4. Check device has network connectivity
5. Check UEM server is reachable
6. Review Dynamics logs: `adb logcat | grep GD`

**Common Causes**:
- Missing settings.json
- GDApplicationID mismatch
- App not provisioned in UEM
- Network/firewall issues

---

## Build Issues

### Build Fails with JdkImageTransform / androidJdkImage / jlink

**Symptoms**: Gradle build fails near the end with errors mentioning
`JdkImageTransform`, `androidJdkImage`, or `jlink` after migration.

**Cause**: A newly-added `compileOptions`/`kotlinOptions` Java 17 block
can trigger AGP's JDK image transform path. Some AGP/JDK combinations
do not handle that path cleanly for the project.

**Fix**:
1. Open `app/build.gradle` or `app/build.gradle.kts`
2. Remove migration-added language-level blocks such as:
   - `compileOptions { sourceCompatibility JavaVersion.VERSION_17 ... }`
   - `kotlinOptions { jvmTarget = "17" }`
3. Keep the project's prior language level unless the app already
   required a higher level before migration
4. Re-run `./gradlew assembleDebug`

**Important**: Dynamics integration itself does not require forcing app
source compatibility to Java 17. JDK 17+ is primarily an environment/
tooling compatibility requirement.

---

### Gradle Build Fails With Network Errors (IDE Sandbox)

**Symptoms**: `./gradlew assembleDebug` fails with "Could not resolve",
"Connection refused", "timeout", or "Could not GET" errors. The Gradle
wrapper download itself may fail.

**Cause**: AI IDE sandbox (e.g., Cursor) blocks outbound network access
by default. Gradle needs network to download its distribution, resolve
Maven dependencies (including the BlackBerry Maven repository), and
sync the project.

**Fix**: Run all Gradle/build commands with network permissions:
- In Cursor: set `required_permissions: ["full_network"]` (or `["all"]`)
  on the Shell tool call
- This applies to ALL `./gradlew` commands, not just the first one
- Non-build commands (`rg`, `ls`, file reads) do NOT need permissions

**How to distinguish from a real build failure**:
- Sandbox failure: errors mention network, DNS, connection, download, timeout
- Real build failure: errors mention compile errors, missing symbols, type
  mismatches, manifest conflicts, resource errors

See `steering/00-context.md § IDE Sandbox and Build Permissions` for the
full guidance.

---

### Corrupted Output Files ("Extra data" / Invalid JSON)

**Symptoms**: `validate.sh` reports "Extra data", "Unexpected token",
or "JSON parse error" on `migration-report.json` or
`migration-analysis.json`. The file may contain multiple JSON root
objects concatenated together (e.g., `{new report}{old report}`).

**Cause**: A patch-based tool (StrReplace, ApplyPatch, or similar)
was used to write an output file instead of a full-file overwrite.
Patch tools append new content to existing files rather than replacing
them. This also happens when stale output files from a previous
migration run were not cleaned before starting a new migration.

**Fix**:
1. Delete the corrupted file:
   ```bash
   rm -f dynamics-migration-tool/output/migration-report.json
   ```
2. Regenerate it using a **full-file overwrite** (Write/CreateFile tool
   in AI IDEs — NOT StrReplace or ApplyPatch)
3. Run `validate.sh` again to confirm the file is valid

**Prevention**:
- Always run `tooling/clean-stale-outputs.sh` (Prompt 00, Step -1)
  before starting a new migration — on a first run it is a no-op
- Always use full-file overwrite for all output files
- Never use patch-based tools on `.json` output files

---

### Manifest Merger Conflicts

**Symptoms**: Build fails with "Manifest merger failed", attribute conflicts

The Dynamics SDK's AndroidManifest.xml may conflict with your app's manifest
attributes. Common conflicts include:

- `android:supportsRtl` — SDK sets `false`, app may have `true`
- `android:allowBackup` — SDK may set a different value
- `android:theme` — SDK may declare a conflicting theme

**Fix**: Add `tools:replace` to your `<application>` element to override
conflicting attributes:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <application
        android:allowBackup="false"
        android:supportsRtl="true"
        tools:replace="android:supportsRtl,android:allowBackup"
        ...>
```

**Important**: You must declare the `tools` namespace in the `<manifest>` tag.
Only add attributes to `tools:replace` that actually conflict — the build error
message will tell you exactly which attributes need it.

### Gradle Sync Fails

**Symptoms**: Cannot resolve Dynamics SDK dependency

**Checks**:
1. Verify BlackBerry Maven repository is added
2. Check internet connectivity
3. Try Gradle cache clear: `./gradlew clean --refresh-dependencies`
4. Verify SDK version exists

---

## Runtime Issues

### ClassNotFoundException

**Symptoms**: App crashes with ClassNotFoundException for Dynamics classes

**Checks**:
1. Verify ProGuard rules if minification enabled
2. Check Dynamics SDK is in dependencies
3. Verify Gradle sync completed successfully

### Data Not Persisting

**Symptoms**: Saved data disappears after app restart

**Checks**:
1. Verify using Dynamics secure storage APIs (not standard Android)
2. Check authorization state before accessing data
3. Verify data is written before app closes
4. Check for wipe events in logs

---

## Policy Issues

### Policy Not Updating

**Symptoms**: onUpdatePolicy not called, old policy persists

**Checks**:
1. Verify GDStateListener is implemented
2. Check UEM policy is published
3. Verify device has network connectivity
4. Force policy sync from UEM console

---

## Networking Issues

### Network Requests Fail

**Symptoms**: HTTP requests timeout or fail

**Checks**:
1. Verify using Dynamics networking APIs
2. Check UEM policy allows the domain
3. Verify device has network connectivity
4. Check proxy settings in UEM
5. Review Dynamics network logs

---

## Logging

### Enable Verbose Logging

Add to settings.json:
```json
{
  "GDConsoleLogger": [
    "GDFilterNone",
    "GDFilterErrors_",
    "GDFilterWarnings_",
    "GDFilterInfo_",
    "GDFilterDetailed_"
  ]
}
```

### View Dynamics Logs

```bash
# Android
adb logcat | grep GD

# Filter for errors only
adb logcat | grep "GD.*ERROR"
```

---

## Getting Help

1. Check official BlackBerry Dynamics documentation
2. Review BlackBerry Developer Forums
3. Contact BlackBerry Support with:
   - Dynamics SDK version
   - Android OS version
   - Device model
   - Relevant logs
   - Steps to reproduce

---

## Additional Troubleshooting

### GDInitializationError: Activity Must Implement GDStateListener

**Symptoms**: Crash with "Each Activity must implement GDStateListener
interface if a singleton interface has not been provided to GDAndroid"

**Cause**: An Activity calls `activityInit()` but:
- It does not implement `GDStateListener`, AND
- No global listener was set via `setGDStateListener()`

**Fix**: Use the global listener pattern (recommended):
1. Application class implements `GDStateListener`
2. Call `GDAndroid.getInstance().setGDStateListener(this)` in
   `Application.onCreate()`
3. All Activities just call `activityInit()` — no need to implement
   the interface

### GDNotAuthorizedError on Startup

**Symptoms**: Crash immediately after activation or unlock, typically
in `onCreate()` of the main Activity

**Cause**: Secure API called before `onAuthorized()` fires. Common
patterns:
- Database access in `onCreate()`
- File I/O in `onCreate()`
- Network request in `onCreate()`
- Secure-preferences / theme / settings / unlock-material reads after
  SharedPreferences was migrated to a Dynamics-backed helper

**Fix**: Move all secure API access to `onAuthorized()` or a method
called from it. See `20-auth-initialization.md` for the two-phase
initialization pattern. For prefs/theme/settings specifically, see
Pattern 13 in `21-authorization-deferral-patterns.md` (`[AUTH-PREF-001]`).

### GDNotAuthorizedError from Secure Preferences on Launch

**Symptoms**: Cold-start crash with `GDNotAuthorizedError` /
`Not authorized. Call GDAndroid.authorize() first` whose stack shows a
secure-preferences helper (`SecurePreferencesHelper.getString` /
`putString` or equivalent) or `com.good.gd.file.FileInputStream` reached
from a launch or base Activity `onCreate` (often via theme, FLAG_SECURE,
or unlock/settings repository helpers). Static Phase 3/4 may already be
green.

**Cause**: SharedPreferences call sites were swapped to GD-backed storage
but left on the Phase-1 lifecycle path. Helper constructors are often
side-effect free; **get/put methods** perform container file I/O and
require authorization.

**Fix**: Defer those reads/writes with `runOnAuthorized` /
`authorized.observe` / `isContainerAuthorized`. Re-run
`validate.sh --check-prompt 03` (Phase 11) and confirm `[AUTH-PREF-001]`
passes. See Pattern 13 in `21-authorization-deferral-patterns.md` and
prompt `05c` step 1b.

### GDNotAuthorizedError in ViewModel init Block

**Symptoms**: Crash during Activity creation, stack trace shows
ViewModel `init {}` or constructor accessing the database

**Cause**: ViewModels are created during `Activity.onCreate()`. If the
ViewModel's `init {}` block opens a database connection or starts
observing Room LiveData, it hits the locked container.

**Fix**: Defer database initialization in the ViewModel by observing
the Application's `authorized` LiveData. Only initialize the database
when `true` is emitted. See Pattern 2 in
`21-authorization-deferral-patterns.md`.

### GDNotAuthorizedError from RoomTrackingLiveData on `arch_disk_io`

**Symptoms**: First-launch crash with stack traces such as:
`com.good.gd.error.GDNotAuthorizedError` from
`com.good.gd.database.sqlite.SQLiteOpenHelper.getWritableDatabase()`,
often on `arch_disk_io` thread and preceded by `RoomTrackingLiveData`.

**Cause**: A ViewModel or startup component subscribes to Room-backed
`LiveData` before container authorization completes. Room immediately
executes the query on its background executor, which opens secure SQLite
while the container is still locked.

**Fix**:
1. Move Room/DAO observer setup behind the authorization boundary:
   - ViewModel: observe Application `authorized` and run DB wiring only
     after `true`.
   - Fragment/Activity: observe `databaseReady` before attaching DAO-backed
     observers.
2. Ensure no startup path (`init {}`, `onCreate`, `onViewCreated`,
   `onStart`, `onResume`) calls DAO query methods pre-auth.
3. Re-run Prompt 03b Step 5 pre-auth runtime smoke:
   ```bash
   adb logcat -d | rg "GDNotAuthorizedError|RoomTrackingLiveData|getWritableDatabase|arch_disk_io"
   ```

**Prevention**: Validator Phase 11 includes a ViewModel/Room pre-auth
scan and fails when Room observer wiring in `init {}` appears ungated.

### NullPointerException on ViewModel Database Fields

**Symptoms**: NPE in a Fragment's `onViewCreated()` or `getObservable()`
when accessing ViewModel fields like `items`, `entries`, etc.

**Cause**: The ViewModel defers database initialization until after
authorization (correct), but Fragments access those fields in
`onViewCreated()` before the ViewModel has finished initializing them.

**Fix**: Add a `databaseReady` LiveData signal to the ViewModel. Have
Fragments observe it before setting up their data observers. Also audit
all `!!` (non-null assertion) operators on deferred fields and convert
to `?.` (safe call). See Patterns 3 and 8 in
`21-authorization-deferral-patterns.md`.

### GDNotAuthorizedError in BroadcastReceiver or Widget

**Symptoms**: Crash in a BroadcastReceiver (alarm, reminder, boot) or
app widget factory/provider when accessing the database

**Cause**: The system triggers the receiver or widget refresh before
the user has unlocked the Dynamics container. These components have no
lifecycle and cannot observe LiveData.

**Fix**: Add a static `isContainerAuthorized` boolean guard at the top
of `onReceive()` or the widget factory's data access methods. Skip the
work silently if not authorized. See Patterns 4 and 5 in
`21-authorization-deferral-patterns.md`.

### GDNotAuthorizedError in Data Migration Code

**Symptoms**: Crash during app startup in migration or schema upgrade
code that accesses the database or filesystem

**Cause**: Migration routines are typically called in `onCreate()` of
the main Activity or Application class, before the container is
authorized. After migration to Dynamics secure APIs, these routines
now access the encrypted container.

**Fix**: Wrap the migration call in an authorization observer. The
migration progress UI can be set up before authorization, but the
actual migration work must wait. See Pattern 6 in
`21-authorization-deferral-patterns.md`.

### App Wiped on Emulator

**Symptoms**: App data is wiped every time it launches on an emulator

**Cause**: UEM compliance profile detects the emulator as a rooted
device and triggers a wipe.

**Fix**:
- Use enterprise simulation mode (`GDEnterpriseSimulation: true`)
- Use a Google Play system image emulator (API 26+)
- Ask UEM admin to disable root detection for development

### Manifest Merger: tools:replace Not Working

**Symptoms**: Build still fails after adding `tools:replace`

**Cause**: The `tools` namespace is not declared, or the wrong
attributes are listed.

**Fix**: Ensure `xmlns:tools="http://schemas.android.com/tools"` is
in the `<manifest>` tag. Only list attributes that actually conflict
(the error message tells you which ones).

### Enterprise Simulation Mode Not Working

**Symptoms**: App still tries to connect to UEM in simulation mode

**Cause**: `com.blackberry.dynamics.settings.json` is not in the
correct location or has invalid JSON.

**Fix**: Verify the file is at `app/src/main/assets/com.blackberry.dynamics.settings.json`
and contains valid JSON with `"GDEnterpriseSimulation": true`.

### Connectivity Diagnostics

Use `GDDiagnostic` class to test connectivity to application servers.
Official BlackBerry Dynamics sample applications (for example the
AppKinetics samples) demonstrate usage.

### Compile Errors After minSdk Bump (Dead Code)

**Symptoms**: `Unresolved reference` errors for resource IDs or API calls
after bumping minSdk from a low value (e.g., 21) to 31.

**Cause**: The app has `Build.VERSION.SDK_INT >= Build.VERSION_CODES.S`
(or similar) checks. With minSdk 31, these checks are always true, making
the `else` branch dead code. If the `else` branch references resource IDs
that only exist in older layout variants (e.g., `layout/` but not
`layout-v31/`), or calls APIs removed in newer SDK levels, the compiler
reports errors.

**Fix**: Search for `Build.VERSION.SDK_INT` checks against API levels at
or below the new minSdk. Remove the dead `else` branches and keep only
the modern code path.

```kotlin
// [NOT OK] BEFORE — else branch references R.id.CheckBoxText which only exists in layout/ (not layout-v31/)
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
    setListItemTextView(item, R.id.CheckBox, color)
} else {
    setListItemTextView(item, R.id.CheckBoxText, color)  // Unresolved reference
}

// [OK] AFTER — dead branch removed, minSdk 31 guarantees API 31+
setListItemTextView(item, R.id.CheckBox, color)
```

### ClassCastException: `GDTextView` cannot be cast to `MaterialTextView`

**Symptoms**: Crash on the main thread right after opening a screen, often
after Dynamics activation. Stack trace points at `findViewById` or the first
line that uses a text view (example: `SettingsFragment.setupResolutionToggle`).

**Cause**: Prompt 09 replaced `<com.google.android.material.textview.MaterialTextView>`
(or `<TextView>`) with `<com.good.gd.widget.GDTextView>` in XML, but Java or
Kotlin code still declares `MaterialTextView` (or a Material subclass) for the
same `@id`. Inflation returns a `GDTextView` instance; assigning it to a
`MaterialTextView` variable triggers `ClassCastException`.

**Fix**:
1. For every layout id migrated to `GDTextView`, change bindings to
   `com.good.gd.widget.GDTextView` (imports, locals, fields, method parameters).
2. Re-run validation: `validate.sh` Phase 8 fails if layouts contain
   `GDTextView` while sources still reference `MaterialTextView` (waivable via
   `secureUiWidgets` when intentionally mixing migrated and non-migrated
   screens).

See `09-migrate-ui-widgets.md` (Material Components section) and
`45-secure-ui-widgets.md`.

### GD FileOutputStream/FileInputStream Fails on `/data/...` Paths

**Symptoms**: Runtime write/read failures such as:
- `Writer unable to open for path: /data/user/0/<pkg>/...`
- `java.io.FileNotFoundException` from `com.good.gd.file.FileOutputStream`
  or `FileInputStream`

**Cause**: The migration switched to GD streams but still passes Android
absolute filesystem paths (often via `File#getAbsolutePath()` from
`getFilesDir()`/`getCacheDir()`). GD stream constructors expect
**container-relative** paths, not Android sandbox paths.

**Fix**:
1. Replace absolute path usage with container-relative logical paths
   (for example `media/photos/<file>`, `thumbs/<file>`).
2. If a storage adapter resolves paths, normalize to container-relative
   strings before calling GD stream constructors.
3. Re-run `validate.sh` Phase 4; it now fails non-waivably when GD
   stream constructors receive Android absolute/cache/files-dir paths.

### Glide/Picasso/Coil Loads Fail After Writer Migration

**Symptoms**:
- Thumbnail/image loads fail with `ENOENT` on `/data/.../cache/...`
- Glide logs `File unsuitable for memory mapping` / `FileNotFoundException`
  while secure writes appear successful

**Cause**: Writer-side migration moved image bytes into container paths,
but reader-side UI still loads via native `File` / absolute path models.
This is a writer-reader closure defect.

**Fix**:
1. Read media bytes from secure container (`SecureFileStore.openForRead()`
   or `com.good.gd.file.FileInputStream`).
2. Pass `byte[]` or `InputStream` to the image loader.
3. Remove native path-based `.load(...)` patterns for container-backed media.
4. Re-run `validate.sh`; Phase 4 now flags native File/path loader usage
   patterns for secure storage domains.

### DLP Policies Not Enforced on Copy/Paste

**Symptoms**: UEM DLP policies restrict copy/paste between managed and
unmanaged apps, but users can still copy text out of (or into) the app
freely. No policy violations are logged.

**Cause**: The app uses `android.content.ClipboardManager` instead of
`com.good.gd.content.ClipboardManager`. The standard Android clipboard
is completely invisible to the Dynamics DLP engine — policies are only
enforced when clipboard operations go through the Dynamics secure
clipboard.

This is the most commonly missed DLP gap because:
- `GDAppCompatViewInflater` handles widget-level DLP for standard widgets
  (EditText, TextView), but programmatic clipboard access is a separate
  code path
- Utility/extension functions that wrap clipboard operations (e.g.,
  `copyToClipBoard()`, `getLatestText()`) are easy to overlook
- Custom EditText/TextView subclasses may access the clipboard directly

**Fix**:
1. Find all `android.content.ClipboardManager` usage:
   ```bash
   rg "android.content.ClipboardManager" -g "*.java" -g "*.kt" -n app/src/main/java/
   ```
2. Replace the import with `com.good.gd.content.ClipboardManager`
3. Replace instance creation:
   - `ContextCompat.getSystemService(context, ClipboardManager::class.java)` →
     `ClipboardManager.getInstance(context)`
   - `context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager` →
     `ClipboardManager.getInstance(context)`
4. Check utility functions and custom views that wrap clipboard access
5. Verify no standard ClipboardManager imports remain:
   ```bash
   rg "android.content.ClipboardManager" -g "*.java" -g "*.kt" -n app/src/main/java/
   # Should return zero results
   ```

See `45-secure-ui-widgets.md` for full migration patterns and code
examples.

### Jetpack Compose Clipboard Bypasses DLP (LocalClipboardManager / LocalClipboard)

**Symptoms**: `validate.sh` Phase 8 reports
`Unmanaged Jetpack Compose clipboard API(s) remain`, or UEM DLP is bypassed
in a Compose-only screen even though `android.content.ClipboardManager` was
never imported.

**Cause**: Jetpack Compose `LocalClipboardManager` / `LocalClipboard` route
copy/paste through the Android system clipboard. They are external clipboard
surfaces and are **not** safe just because platform `ClipboardManager` was
migrated elsewhere.

**Fix**:
1. Copy the kit interim adapter:
   ```bash
   cp dynamics-migration-tool/templates/clipboard/GDClipboardAdapter.kt \
      app/src/main/java/<your/package>/dynamicsclipboard/
   ```
2. Replace `LocalClipboardManager.current` / `LocalClipboard.current` with
   `remember { GDClipboardAdapter(context) }` and `setPlainText` / `getPlainText`.
3. Verify closure:
   ```bash
   rg "LocalClipboardManager\\.current|LocalClipboard\\.current" -g "*.kt" -n app/src/main/java/
   ```
4. For rich `ClipEntry` payloads that cannot be converted to plain text,
   add a **high**-priority `manualTodos[]` entry — do not mark
   `coverage.secureClipboard` as `migrated` or `not-applicable`.

See `45-secure-ui-widgets.md` § "Jetpack Compose Clipboard".

### Compose ICC Share Still Uses View-System Chooser

**Symptoms**: `validate.sh` Phase 8b reports
`Unmanaged Compose ICC chooser pattern(s) remain`, or a Compose share button
still opens `MaterialAlertDialogBuilder` / legacy `showShareChooser(Activity, …)`.

**Cause**: ICC secure transfer is correct (`GDServiceClient.sendTo` /
`sendFiles`), but provider selection UX in `@Composable` screens still uses
View-system dialogs. That breaks Compose-first migration closure and is easy
to miss when a Java `TransferFileService` helper still owns the chooser.

**Fix**:
1. Copy the kit Compose chooser template:
   ```bash
   cp dynamics-migration-tool/templates/icc/GDICCProviderShareDialog.kt \
      app/src/main/java/<your/package>/dynamicsicc/
   ```
2. Replace `MaterialAlertDialogBuilder` provider lists in `@Composable` code
   with `GDICCProviderShareDialog` and call `sendFiles` / `sendTo` from
   `onProviderSelected` on a background executor.
3. Do not call `showShareChooser(activity, …)` from `@Composable` buttons.
4. If chooser wiring cannot be automated, add **high**-priority `manualTodos[]`
   and set `coverage.icc.status` to `partial`.

See `60-icc-transferfileservice.md` § "Compose-First Provider Chooser".

### DLP Policies Not Enforced on System Copy/Paste Action Bar

**Symptoms**: Programmatic clipboard operations are DLP-enforced (the
app uses `com.good.gd.content.ClipboardManager`), but users can still
long-press text in a custom `EditText` and use the system copy/paste
action bar to copy data out of the app.

**Cause**: The app has custom `EditText` or `TextView` subclasses that
extend `AppCompatEditText` or `AppCompatTextView` instead of the GD
equivalents. `GDAppCompatViewInflater` only auto-substitutes standard
widget class names at XML inflation time — it does NOT substitute custom
subclasses.

When a user long-presses text and uses the system copy/paste action bar,
the copy operation is handled internally by the widget at the Android
framework level. It never goes through the app's programmatic
`ClipboardManager` code. Only GD widget classes intercept the system
copy/paste action bar to enforce DLP policies.

**Fix**:
1. Find all custom subclasses:
   ```bash
   rg "AppCompatEditText|AppCompatTextView" -g "*.java" -g "*.kt" -n app/src/main/java/ | rg "class "
   ```
2. Change the root parent class in the inheritance chain to the GD
   equivalent:
   - `AppCompatEditText` → `GDAppCompatEditText` (`com.good.gd.widget`)
   - `AppCompatTextView` → `GDAppCompatTextView` (`com.good.gd.widget`)
3. Only change the root class — all subclasses inherit DLP protection
   automatically
4. Verify no custom subclasses still extend the standard AppCompat
   widgets:
   ```bash
   rg "AppCompatEditText|AppCompatTextView" -g "*.java" -g "*.kt" -n app/src/main/java/ | rg "class "
   # Should return zero results (excluding GD imports/comments)
   ```

**Example**: If the hierarchy is `StylableEditText` →
`HighlightableEditText` → `EditTextWithWatcher` → `AppCompatEditText`,
change only `EditTextWithWatcher` to extend `GDAppCompatEditText`.

See `45-secure-ui-widgets.md` for the full custom subclass migration
pattern.

### Gradle Sync Fails — Dynamics SDK Version Not Found

**Symptoms**: Gradle sync fails with "Could not find any matches for
com.blackberry.blackberrydynamics:android_handheld_platform:15.0.+"
(or an older `14.0.+` / `14.1.+` range).

**Cause**: The Dynamics SDK does not follow simple semantic versioning.
Maven coordinates include build identifiers (for example
`15.0.8513.64`). Dynamic ranges like `15.0.+` or `14.0.+` often fail to
resolve, and Maven metadata can lag behind a newly published release.

**Fix**: Pin to the toolkit's verified 15.0 release:
```groovy
def dynamics_version = '15.0.8513.64'
```

Check available versions:
```bash
curl -s https://software.download.blackberry.com/repository/maven/com/blackberry/blackberrydynamics/android_handheld_platform/maven-metadata.xml
```

If metadata still lists only 14.x while the public API reference shows
15.0, wait for Maven publication or override with
`BOOTSTRAP_DYNAMICS_SDK_VERSION` once the artifact is reachable.

---

### GDInitializationError: Permissions Not Declared

**Symptoms**: App crashes immediately on startup (before any UI is visible)
with:
```
com.good.gd.error.GDInitializationError: Permissions not declared,
including android.permission.ACCESS_NETWORK_STATE
```
Stack trace shows the crash originates from `GDAndroid.activityInit()`.

**Cause**: The Dynamics SDK performs a runtime check during `activityInit()`
to verify that required permissions are present in the merged manifest. One
or both of the required permissions (`ACCESS_NETWORK_STATE`, `INTERNET`) are
absent.

The most common cause is a `tools:node="remove"` attribute applied to one of
these permissions in `AndroidManifest.xml`, typically added in a misguided
attempt to silence a manifest-merger duplicate-declaration warning:

```xml
<!-- [NOT OK] This strips the permission from the merged manifest → GDInitializationError -->
<uses-permission
    android:name="android.permission.ACCESS_NETWORK_STATE"
    tools:node="remove" />
```

**Fix**:
1. Open `app/src/main/AndroidManifest.xml`
2. Search for `tools:node="remove"` on `ACCESS_NETWORK_STATE` or `INTERNET`
3. Remove the `tools:node="remove"` attribute (keep the `<uses-permission>` tag)
4. If the permission declaration is missing entirely, add both:

```xml
<!-- [BB_DYNAMICS-MIGRATION] Required by BlackBerry Dynamics SDK -->
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.INTERNET" />
```

**Prevention**: Step 7 of Prompt 01 ("Required Manifest Permissions
Audit (MANDATORY)") explicitly scans every primary-module manifest for
`tools:node="remove"` on `INTERNET`, `ACCESS_NETWORK_STATE`, and
`ACCESS_WIFI_STATE` and strips the attribute before any runtime testing.
The validator (`tooling/validate.sh`, Phase 1) enforces the same rule —
`record-prompt-execution.sh --prompt-id 01 --status completed` and the
prompt-10 source gate (`--mode final-source`) both block while the trap remains. See the
"Required Manifest Permissions (MANDATORY — non-negotiable)" section in
`steering/10-gradle-integration.md` for the full rationale, the
permission-by-permission table, and the security-review justification
text for compliance reviewers.

---

### Fatal crash: "Can't marshal non-Parcelable objects across processes" in GDClient

**Symptoms**: App crashes on startup with:
```
java.lang.RuntimeException: Can't marshal non-Parcelable objects across processes.
    at com.good.gd.client.GDClient$shy.onServiceConnected
```
The crash process name contains a custom process suffix (e.g., `:error_activity`,
`:background_service`).

**Cause**: `GDAndroid.activityInit()` was called inside an Activity (or Service)
that runs in a separate OS process (declared with `android:process=":something"`
in the manifest). When `GDAndroid.activityInit()` initialises `GDClient`, the
client attempts to bind to the Dynamics service in the main process and send an
IPC `Message` across the process boundary. That `Message` contains an internal
non-Parcelable object, which Android's `Messenger` rejects.

**Affected component types**:
- Crash-reporter activities (e.g., `CustomActivityOnCrash` error screen)
- Remote `Service` or `BroadcastReceiver` components with `android:process`
- Any component that Android boots in a separate process from the main app

**Fix**: Remove `GDAndroid.getInstance().activityInit()` from any component
that has `android:process` set in the manifest. These components are not part
of the Dynamics secure container lifecycle.

```kotlin
// [NOT OK] WRONG — crashes when android:process=":error_activity" is set
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    GDAndroid.getInstance().activityInit(this)  // fatal IPC marshal failure
}

// [OK] CORRECT — omit activityInit() for out-of-process activities
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    // No activityInit() — this activity runs in a separate process
}
```

**Prevention (Prompt 03)**: Before injecting `activityInit()` into any Activity,
check whether the Activity has `android:process` declared in the manifest:
```bash
rg "android:process" app/src/main/AndroidManifest.xml
```
Skip `activityInit()` for every component that matches.

---

### UninitializedPropertyAccessException in Application Lifecycle Callbacks

**Symptoms**: Crash on startup with:
```
kotlin.UninitializedPropertyAccessException: lateinit property preferences
has not been initialized
    at MyApplication.onActivityCreated(MyApplication.kt:NNN)
```
The crash occurs inside an `Application.ActivityLifecycleCallbacks` method
(e.g., `onActivityCreated`, `onActivityResumed`) before `onAuthorized()`
fires.

**Cause**: The app's `Application` class registers
`ActivityLifecycleCallbacks` and accesses `lateinit` properties (database
handles, preferences, secure storage) in those callbacks. These callbacks
fire for every Activity lifecycle event — including the Dynamics SDK's own
internal Activities during activation/unlock, which happen **before**
`onAuthorized()` initializes the properties.

**Fix**: Guard all property access in lifecycle callbacks with an
`isInitialized` check:

```kotlin
override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
    if (!::preferences.isInitialized) return  // Not yet authorized
    // Safe to access preferences
}
```

**Prevention (Prompt 03)**: When converting an Application class to
implement `GDStateListener`, audit ALL `ActivityLifecycleCallbacks`
methods for secure API access or `lateinit` property access. Add
`isInitialized` guards to each one.

---

### FileProvider Root Not Found for Internal Attachments

**Symptoms**: Crash when sharing a file stored in internal storage:
```
java.lang.IllegalArgumentException: Failed to find configured root
that contains /data/data/com.example.app/files/attachments/Images/photo.jpg
```

**Cause**: The app stores attachments in a subdirectory of `filesDir`
(e.g., `files/attachments/Images/`) but the `FileProvider` configuration
in `res/xml/provider_paths.xml` does not include a `<files-path>` entry
covering that directory.

This commonly happens after migrating from external to internal storage:
the old `<external-files-path>` entries no longer match, and the new
internal paths were not added to the provider configuration.

**Fix**: Add a `<files-path>` entry to `res/xml/provider_paths.xml`:

```xml
<paths>
    <!-- [BB_DYNAMICS-MIGRATION] Internal attachment storage -->
    <files-path name="attachments" path="attachments/" />
</paths>
```

**Prevention (Prompt 05a/05b)**: When migrating file storage from external to
internal directories, always audit `res/xml/provider_paths.xml` and update
it to match the new directory structure. See the "FileProvider Path
Reconfiguration" section in `40-secure-file-storage.md` §9.

---

### ICC Transfer Stuck — Receiving App Shows Waiting Animation

**Symptoms**: When sharing files via AppKinetics `TransferFile`, the
sending app reports success but the receiving app shows a loading/waiting
animation indefinitely. No error is logged by the sender.

**Cause**: The files passed to `GDServiceClient.sendTo()` are **Android
OS filesystem paths** (e.g., `/data/data/com.example.app/files/...`)
instead of **GD secure container paths** (e.g., `/icc_outbox/photo.jpg`).

`GDServiceClient.sendTo()` expects paths within the GD virtual
filesystem — the one accessed by `com.good.gd.file.File` and related
APIs. When you pass an Android OS path, AppKinetics cannot locate the
file in the GD container. The transfer notification reaches the peer
but the actual file data is missing, so the receiver hangs waiting.

This is the most common ICC failure mode because:
- Apps that store attachments using `java.io.File` (standard Android)
  have perfectly valid files on the OS filesystem
- The `absolutePath` of those files looks correct
- `sendTo()` does not throw an exception — it silently sends an empty
  or invalid transfer
- The failure only manifests at the receiving end

**Fix**: Before calling `sendFiles()`, copy each file from the Android
filesystem into the GD secure container using `com.good.gd.file.*` APIs,
then pass the GD container paths:

```kotlin
val gdStagingDir = com.good.gd.file.File("icc_outbox")
if (!gdStagingDir.exists()) gdStagingDir.mkdirs()

val gdPaths = mutableListOf<String>()
for (file in androidFiles) {
    if (!file.exists()) continue
    val gdPath = "icc_outbox/${file.name}"
    java.io.FileInputStream(file).use { fis ->
        com.good.gd.file.FileOutputStream(gdPath).use { fos ->
            val buffer = ByteArray(8192)
            var bytesRead: Int
            while (fis.read(buffer).also { bytesRead = it } != -1) {
                fos.write(buffer, 0, bytesRead)
            }
        }
    }
    gdPaths.add(gdPath)
}
sendFiles(targetAddress, gdPaths)
```

**Key distinction**: If the app already stores files using
`com.good.gd.file.*` APIs, no staging is needed — those paths are already
GD container paths. Staging is only required when files are stored using
standard `java.io.File` APIs.

**Prevention (Prompt 08)**: Step 3 of the ICC prompt now includes a
mandatory "File Path Audit" that determines whether app files are in
the GD container or the Android filesystem, and adds staging if needed.
See the "GD Container Filesystem Staging" section in
`60-icc-transferfileservice.md`.

---

### ICC sendTo() Blocks UI Thread

**Symptoms**: The app freezes briefly when the user taps a share target.
On some devices the ANR dialog appears.

**Cause**: `GDServiceClient.sendTo()` performs I/O and was called on the
main (UI) thread instead of a background thread.

**Fix**: Always dispatch `sendTo()` on a background executor. Attachment paths
must already be in the GD secure container (no sandbox staging at send time):

```kotlin
private val executor = Executors.newSingleThreadExecutor()

executor.execute {
    try {
        sendFiles(targetAddress, gdContainerPaths)
        activity.runOnUiThread {
            Toast.makeText(activity, "Sent", Toast.LENGTH_SHORT).show()
        }
    } catch (e: GDServiceException) {
        activity.runOnUiThread {
            Toast.makeText(activity, "Failed", Toast.LENGTH_SHORT).show()
        }
    }
}
```

**Prevention**: The steering at `60-icc-transferfileservice.md` marks
this as a **CRITICAL** requirement, and the code templates in Prompt 08
always wrap `sendTo()` in an executor.

---

### GDNotAuthorizedError in Activity Lifecycle Methods Beyond onCreate()

**Symptoms**: Crash in an Activity method that is NOT `onCreate()`, such
as `setupMenu()`, `onStart()`, or a method called from `onResume()`,
with:
```
com.good.gd.error.GDNotAuthorizedError: Error GD Not authorized.
    at ...LabelDao_Impl.getAll()
    at ...MainActivity.setupMenu()
```

**Cause**: The main Activity's `onCreate()` was correctly deferred using
`runOnAuthorized()`, but other lifecycle-adjacent methods still access
the database directly.

**Fix**: Gate each method behind the ViewModel's `databaseReady` signal:

```kotlin
private fun setupMenu() {
    baseModel.databaseReady.observe(this) { ready ->
        if (ready) populateMenuFromDatabase()
    }
}
```

**Prevention (Prompt 03b)**: The deferral audit must scan for ALL methods
in the main Activity that access the database — not just `onCreate()`.
See Pattern 9 in `21-authorization-deferral-patterns.md`.

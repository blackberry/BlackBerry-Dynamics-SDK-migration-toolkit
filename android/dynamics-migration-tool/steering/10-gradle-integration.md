# Steering: Gradle Integration for BlackBerry Dynamics

Your task is to integrate the BlackBerry Dynamics SDK into this Android project
using Gradle.

> **Multi-module note**: `app/build.gradle(.kts)` and
> `app/build/...` paths below are canonical-shape illustrations.
> On multi-module projects, read from
> `dynamics-migration-tool/output/module-map.json`:
>
> - `${primary_build_file}` is the Gradle file that owns the
>   primary application module's `android { }` block.
> - `${convention_plugin_files}` is every Kotlin convention plugin
>   source file that composes the primary module's Android
>   configuration. On convention-plugin-heavy multi-module projects,
>   `compileSdk` / `minSdk` / lint config live there, not in the
>   module's own build file.
> - Library modules referencing Dynamics APIs receive the SDK as
>   `compileOnly`, never `implementation`. The `${primary_build_file}`
>   is the sole `implementation` carrier.
>
> See `01-gradle-integration.md` (prompt) and
> `04-multi-module-projects.md` (steering).

---

## Rules

- Detect whether the project uses:
  - Groovy Gradle
  - Kotlin DSL (build.gradle.kts)
- Detect:
  - Single-module vs multi-module setup
- Do NOT hardcode SDK versions unless explicitly present in official samples
- Prefer copying structure from official Dynamics Android samples

---

## BlackBerry Maven Repository Placement

The repository must be present in the Gradle repository scope that
actually resolves the primary app module's dependencies. Check
`settings.gradle(.kts)` for `dependencyResolutionManagement` and
`repositoriesMode` before editing.

Use the canonical URL with a trailing slash:

```text
https://software.download.blackberry.com/repository/maven/
```

If the project uses settings-owned resolution
(`RepositoriesMode.PREFER_SETTINGS` or
`RepositoriesMode.FAIL_ON_PROJECT_REPOS`), add the repository under
`dependencyResolutionManagement.repositories`:

```groovy
dependencyResolutionManagement {
    repositories {
        maven { url 'https://software.download.blackberry.com/repository/maven/' }
    }
}
```

```kotlin
dependencyResolutionManagement {
    repositories {
        maven(url = "https://software.download.blackberry.com/repository/maven/")
    }
}
```

If the project uses project-owned resolution
(`RepositoriesMode.PREFER_PROJECT`) or declares project-level
`repositories {}` blocks for the app module, add the same repository in
the root/project repository block that applies to the primary app module:

```groovy
allprojects {
    repositories {
        maven { url 'https://software.download.blackberry.com/repository/maven/' }
    }
}
```

```kotlin
allprojects {
    repositories {
        maven(url = "https://software.download.blackberry.com/repository/maven/")
    }
}
```

Do not rely on a settings-level repository alone when
`PREFER_PROJECT` is configured. In that mode, project-level repositories
override settings-level repositories, which can make bootstrap and prompt
01 resolution fail even when network access and the BlackBerry Maven
service are healthy.

---

## Minimum SDK Requirements

**IMPORTANT**: BlackBerry Dynamics SDK has minimum Android SDK requirements:

| Dynamics SDK Version | Minimum Android SDK (minSdk) |
|---------------------|------------------------------|
| 13.x and earlier    | 30 (Android 11)              |
| 14.x and later      | 31 (Android 12)              |

### Action Required

1. Check the Dynamics SDK version being used
2. Verify the project's `minSdk` meets the requirement
3. Update `minSdk` in `app/build.gradle` if necessary:

```groovy
android {
    defaultConfig {
        minSdk 31  // Required for Dynamics SDK 15.x (unchanged from 14.x)
    }
}
```

### Build Failure Symptoms

If minSdk is too low, you may see errors like:
- `Manifest merger failed`
- `uses-sdk:minSdkVersion X cannot be smaller than version Y declared in library`

### Dead Code After minSdk Bump (IMPORTANT)

Bumping minSdk from a low value (e.g., 21) to 31 can cause compile errors
in existing code. Common patterns:

- `Build.VERSION.SDK_INT >= Build.VERSION_CODES.S` checks become always-true,
  making the `else` branch dead code. If the `else` branch references resource
  IDs that only exist in older layout variants (e.g., `layout/` but not
  `layout-v31/`), the compiler will report `Unresolved reference` errors.
- Version-gated API calls where the old-API fallback path references classes
  or methods removed in newer SDK levels.

**Fix**: After bumping minSdk, search for `Build.VERSION.SDK_INT` checks
against API levels at or below the new minSdk. Remove the dead `else`
branches and keep only the modern code path. The compiler will flag these
as errors if the dead branch references missing resources.

---

## Software Requirements

Before integrating, verify the project meets these requirements:

| Requirement | Minimum |
|-------------|---------|
| Android OS target | Android 12 (API 31) or later |
| Java | Java 17 or later |
| Gradle | 9.3.1 or later |
| Android Gradle Plugin | 9.1.1 or later |
| AndroidX | Required (must use AndroidX support libraries) |
| Character encoding | UTF-8 (no BOM) for all build/config files |

### Java Compatibility Rule (Critical)

Dynamics migration requires a compatible **runtime JDK**, but does not
require forcing the app module's Java/Kotlin source compatibility to 17.

- Verify environment/runtime JDK is compatible (17+), especially for AGP.
- Do **not** add or modify `compileOptions` / `kotlinOptions` just for
  Dynamics integration.
- Preserve the app's existing language level unless there is an
  independent project requirement to change it.
- If a post-migration build fails with `JdkImageTransform`,
  `androidJdkImage`, or `jlink`, first remove newly-added Java 17
  language-level blocks and re-run the build.

### Required AndroidX Libraries (minimum versions)

- `androidx.appcompat:appcompat:1.0.0`
- `androidx.core:core:1.0.0`
- `androidx.constraintlayout:constraintlayout:1.1.3`
- `androidx.recyclerview:recyclerview:1.0.0` (required for Credential Manager UI)
- `androidx.legacy:legacy-support-v4:1.0.0`
- `androidx.preference:preference:1.1.0`
- `androidx.cardview:cardview:1.0.0`

Use the latest stable version of each library when possible.

---

## Expected Actions

1. Identify where Gradle configuration should live:
   - Root project
   - App module
2. Add required repositories if missing
3. Add Dynamics dependencies following official samples
4. **Verify minSdk meets Dynamics SDK requirements**
5. **Verify Java 17 compatibility**
   - Runtime/JDK compatibility check only; do not force module language
     level via new `compileOptions`/`kotlinOptions` blocks.
6. **Verify AndroidX is enabled** (`android.useAndroidX=true` in gradle.properties)
7. **Add lint configuration to prevent Dynamics SDK lint errors from blocking builds**
8. **Apply manifest merger fix** (see Manifest Merger Conflicts section below)
9. Ensure the project still builds

---

## Lint Configuration (IMPORTANT)

The Dynamics SDK may trigger lint errors (e.g., `NotificationPermission`,
`DataExtractionRules`) that block the build. Add lint configuration to prevent
these from aborting the build:

### Groovy Gradle (build.gradle)

```groovy
android {
    lint {
        abortOnError false
        checkReleaseBuilds false
    }
}
```

### Kotlin DSL (build.gradle.kts)

```kotlin
android {
    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}
```

This is a standard practice when integrating SDKs that introduce their own
manifest entries and permissions. The lint warnings should still be reviewed
but should not block the build.

---

---

## Manifest Merger Conflicts (MANDATORY)

The Dynamics SDK manifest declares `android:supportsRtl` and `android:allowBackup`
values that conflict with most app manifests. This causes a build failure
immediately after adding the Dynamics dependency:

```
Manifest merger failed: Attribute application@supportsRtl value=(true) from
AndroidManifest.xml conflicts with attribute from [com.blackberry.blackberrydynamics:
android_handheld_platform:x.x.x] AndroidManifest.xml
```

**Apply this fix proactively — do not wait for the build to fail.**

### Step 1: Add the `tools` namespace to the manifest root

```xml
<!-- [BB_DYNAMICS-MIGRATION] Added tools namespace for manifest merger conflict resolution -->
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
```

### Step 2: Add `tools:replace` to the `<application>` tag

```xml
<!-- [BB_DYNAMICS-MIGRATION] tools:replace resolves manifest merger conflicts with Dynamics SDK -->
<application
    android:name=".MyApplication"
    android:allowBackup="false"
    android:supportsRtl="true"
    ...
    tools:replace="android:supportsRtl,android:allowBackup">
```

### CRITICAL: Every Attribute in `tools:replace` MUST Be Explicitly Declared

If you list an attribute in `tools:replace` but do NOT explicitly declare
that attribute on the same `<application>` tag, the manifest merger will
fail with a confusing error. For example:

```xml
<!-- [NOT OK] WRONG — supportsRtl is listed in tools:replace but not declared as an attribute -->
<application
    android:allowBackup="false"
    tools:replace="android:supportsRtl,android:allowBackup">
```

This fails because the merger tries to replace the SDK's value with "your"
value — but there is no value to replace with. The fix is to always declare
the attribute explicitly:

```xml
<!-- [OK] CORRECT — both attributes are declared AND listed in tools:replace -->
<application
    android:allowBackup="false"
    android:supportsRtl="true"
    tools:replace="android:supportsRtl,android:allowBackup">
```

### Known Conflicting Attributes by SDK Feature Area

| Attribute | Conflict Source | Recommended Value |
|-----------|----------------|-------------------|
| `android:supportsRtl` | Dynamics platform manifest | Keep your app's value (usually `true`) |
| `android:allowBackup` | Dynamics platform manifest | Set to `false` (Dynamics handles secure backup) |

Both attributes must appear in `tools:replace`. The pattern
`tools:replace="android:supportsRtl,android:allowBackup"` covers all known
conflicts as of Dynamics SDK 15.x.

---

## Required Manifest Permissions (MANDATORY — non-negotiable)

The BlackBerry Dynamics SDK is built around secure enterprise communication.
It does not make standard web requests — it intercepts the app's network
traffic and tunnels it through the BlackBerry Network Operations Center
(NOC) and the organization's internal proxy infrastructure. To manage that
tunnel the runtime requires the following permissions in the **merged**
manifest:

| Permission | Why the SDK requires it |
|---|---|
| `android.permission.INTERNET` | Open the encrypted tunnel to the NOC and the enterprise back-end. |
| `android.permission.ACCESS_NETWORK_STATE` | Detect connectivity changes (Wi-Fi ⇄ cellular, drop / restore) so the tunnel can pause, re-authenticate, and resume seamlessly. Required for `ConnectivityManager` queries the SDK performs internally. |
| `android.permission.ACCESS_WIFI_STATE` | Verify enterprise Wi-Fi posture and roaming state for policy and entitlement decisions. |

These permissions ship inside the Dynamics SDK AAR manifests and are
**merged automatically into the app manifest by the Android Gradle build
system**. Under normal conditions the app does **not** need to declare them
manually — the manifest merger pulls them in from
`com.blackberry.blackberrydynamics:android_handheld_platform`.

### MANDATORY: Never strip these permissions with `tools:node="remove"`

It is a **hard requirement** of any Dynamics migration that none of the
permissions above are stripped from the merged manifest. The
following pattern is **forbidden**:

```xml
<!-- [NOT OK] Strips the permission Dynamics injected → fatal GDInitializationError -->
<uses-permission
    android:name="android.permission.ACCESS_NETWORK_STATE"
    tools:node="remove" />

<!-- [NOT OK] Equally forbidden — Dynamics cannot open the secure tunnel without INTERNET -->
<uses-permission
    android:name="android.permission.INTERNET"
    tools:node="remove" />
```

Common reasons apps shipped with one of these `node="remove"` rules
**before** Dynamics integration:

- The original open-source app was privacy-minded and wanted to strip a
  permission a transitive library added (analytics, ads, Firebase, etc.).
- A previous security review asked for the smallest possible permission
  surface.

Neither rationale survives Dynamics integration. With Dynamics in the
build, `ACCESS_NETWORK_STATE`, `INTERNET`, and `ACCESS_WIFI_STATE`
are no longer optional — they are part of the SDK's runtime contract.

### What happens if they are stripped

The SDK runs a permission audit during `GDAndroid.activityInit()` and
crashes the app **before any UI is visible** with:

```
com.good.gd.error.GDInitializationError:
    Permissions not declared, including android.permission.ACCESS_NETWORK_STATE
    at com.good.gd.utils.GDInit...
    at com.good.gd.GDAndroid.activityInit(...)
```

Even if the audit were bypassed, the runtime would later throw a
`SecurityException` the first time it queries `ConnectivityManager`, and
the container would fail to reach the NOC, locking the user out of the
app.

### Required action during migration

Prompt 01 (`prompts/01-gradle-integration.md`, **Step 7 — Required Manifest
Permissions Audit**) MUST:

1. Scan every primary-module manifest (`module-map.json` →
   `primaryAppModule.manifest` plus any flavor manifests) for any
   `<uses-permission>` element naming `INTERNET`, `ACCESS_NETWORK_STATE`,
   or `ACCESS_WIFI_STATE` that carries `tools:node="remove"`.
2. **Remove the `tools:node="remove"` attribute** — keep the
   `<uses-permission>` line itself (so the explicit declaration acts as
   documentation; the merger will deduplicate against the SDK's injected
   copy). Annotate with the migration marker:

   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Removed tools:node="remove" — Dynamics SDK requires this permission in the merged manifest -->
   <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
   ```

3. If any of the three permissions is **entirely absent** from the
   manifest, do not add it manually — manifest merger will supply it
   from the SDK AAR. The audit only removes hostile `node="remove"`
   rules; it does not add new declarations.

### Security-review justification (for compliance reviewers)

If a corporate security audit flags these permissions, the justification
is fixed and standard:

> `INTERNET`, `ACCESS_NETWORK_STATE`, and `ACCESS_WIFI_STATE` are
> mandatory, standard-level Android permissions required by the
> BlackBerry Dynamics SDK to establish and maintain the encrypted
> NOC tunnel, detect connectivity changes, and enforce enterprise
> authorization policies. They are declared by the SDK library and
> merged automatically; the app cannot opt out without breaking
> Dynamics initialization.

The validator (`tooling/validate.sh`, Phase 1) enforces this rule.
`record-prompt-execution.sh --prompt-id 01 --status completed` will
refuse to record success while any of these permissions still carry
`tools:node="remove"` in a primary-module manifest, and the full
sweep at prompt 10 will block the migration report on the same check.

---

## Constraints

- Do not remove existing dependencies
- Do not break non-Dynamics build variants
- If productFlavors or buildTypes exist, explain where Dynamics should apply

---

## ProGuard/R8 Configuration

### Check for Consumer Rules

The Dynamics SDK typically includes consumer ProGuard rules automatically.

Verify by checking:
```bash
# After Gradle sync, check merged ProGuard rules
cat app/build/intermediates/proguard-rules/*/proguard.txt
```

### If Manual Rules Needed

Consult official BlackBerry Dynamics documentation for required keep rules.

Common patterns:
```proguard
# Keep Dynamics SDK classes
-keep class com.good.gd.** { *; }

# Keep GDStateListener implementations
-keep class * implements com.good.gd.GDStateListener { *; }

# Keep classes used via reflection
-keepclassmembers class * {
    @com.good.gd.* <methods>;
}
```

### Testing

After enabling minification:
1. Build release APK
2. Test authorization flow
3. Test all Dynamics features
4. Check logs for reflection errors

### Important: -dontwarn Rule

The Dynamics SDK uses Platform APIs above the minimum supported API level.
Add this to suppress false warnings:

```proguard
-dontwarn com.good.gd.**
```

---

## Full Dependency Set

The SDK provides multiple artifacts. Add what the app needs:

```groovy
// REQUIRED — Core Dynamics SDK
implementation 'com.blackberry.blackberrydynamics:android_handheld_platform:$DYNAMICS_SDK_VERSION'

// REQUIRED — SDK resources (UI screens, strings, etc.)
implementation 'com.blackberry.blackberrydynamics:android_handheld_resources:$DYNAMICS_SDK_VERSION'

// RECOMMENDED — Backup support
implementation 'com.blackberry.blackberrydynamics:android_handheld_backup_support:$DYNAMICS_SDK_VERSION'

// OPTIONAL — BBWebView (if app uses WebView)
implementation 'com.blackberry.blackberrydynamics:android_webview:$DYNAMICS_SDK_VERSION'

// OPTIONAL — Play Integrity attestation
implementation 'com.blackberry.blackberrydynamics:android_handheld_gd_safetynet:$DYNAMICS_SDK_VERSION'
```

At minimum, add `android_handheld_platform`. The other artifacts are
added based on the app's needs.

**Removed in SDK 15.0:** do **not** add
`android_handheld_blackberry_protect_support`. BlackBerry Protect Mobile
features (malware detection, safe browsing, SMS URL scanning) are no
longer supported. Remove any existing Protect Mobile dependency.

---

## SDK Version Resolution (IMPORTANT)

The Dynamics SDK does NOT follow simple semantic versioning on Maven.
Version numbers include build identifiers (e.g., `15.0.8513.64`).

### Common Mistake

```groovy
// [NOT OK] WRONG — dynamic ranges often fail to resolve against Maven metadata
def dynamics_version = '15.0.+'

// [NOT OK] WRONG — obsolete 14.0.x coordinates
def dynamics_version = '14.0.+'
```

### Correct Approach

```groovy
// [OK] RECOMMENDED — pin to the toolkit-verified Dynamics SDK 15.0 release
def dynamics_version = '15.0.8513.64'

// [WARN] ACCEPTABLE but fragile — dynamic range may fail if repo is unreachable
// def dynamics_version = '15.+'
```

**Always pin to a specific version.** Dynamic version ranges (`15.+`) require
Gradle to resolve against the BlackBerry Maven repository at sync time. If the
repository is unreachable or metadata lags a new release, the build fails.
Pinning ensures reproducible builds and avoids unexpected breakage from new
SDK releases.

### How to Find Available Versions

Check the BlackBerry Maven repository directly:
```bash
# List available versions
curl -s https://software.download.blackberry.com/repository/maven/com/blackberry/blackberrydynamics/android_handheld_platform/maven-metadata.xml
```

Or check your Gradle cache after a successful sync:
```bash
ls ~/.gradle/caches/modules-2/files-2.1/com.blackberry.blackberrydynamics/android_handheld_platform/
```

---

## Output

- Summary of Gradle changes
- Diff-style explanation
- Note whether consumer ProGuard rules are present
- List any manual ProGuard rules added (if applicable)
- Notes on anything that must be verified manually

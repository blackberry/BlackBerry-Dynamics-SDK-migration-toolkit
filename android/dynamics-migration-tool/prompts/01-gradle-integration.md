## Task: Gradle Integration for BlackBerry Dynamics

Goal: Add the BlackBerry Dynamics SDK dependency to the project, bump
minSdk, configure the Maven repository, and ensure the project builds.

**Prerequisite**: Prompt 00 (analyze-app) must be complete. Prompt 00b
(architecture diagrams) is optional and is required only when the
developer invoked the toolkit with `--with-diagrams` or explicitly
requested diagram generation. The analysis tells you what dependencies
the app needs (core SDK, BBWebView, backup support, etc.).

**This prompt makes build configuration changes only — no source code
changes.**

---

## Module map context (read first)

Load `dynamics-migration-tool/output/module-map.json` and resolve:

- `${primary}` — `primaryAppModule.path`.
- `${primary_build_file}` — `primaryAppModule.buildFile`. This is the
  Gradle file that receives the Dynamics SDK `implementation`
  dependencies, the `minSdk` bump, the lint config, and the ProGuard
  rules. For projects that route Android configuration through a
  Kotlin convention plugin (common in large multi-module apps),
  some of these blocks already live inside the convention plugin
  source files listed under `conventionPlugins[]` rather than the
  module's own build file — see step 3 below.
- `${convention_plugin_files}` — every `conventionPlugins[*].sourceFile`
  entry in `module-map.json`. These are Kotlin source files (typically
  under `build-logic/.../src/main/kotlin/...`) that compose the
  primary module's Android configuration. Treat them as part of the
  Gradle layer for this prompt.
- `${library_modules_in_scope}` — `libraryModulesInScope[*]`. Library
  modules that ship code consumed by the primary application module.
  Library modules MUST receive the Dynamics SDK as `compileOnly` (not
  `implementation`) when they reference Dynamics APIs directly.
- `${library_modules_referencing_dynamics}` — subset of
  `${library_modules_in_scope}` that the analysis prompt flagged as
  containing `com.good.gd.*` call sites. This is the subset that
  needs the `compileOnly` Dynamics dependency.

If `module-map.json` is missing, STOP and re-run `00pre-bootstrap.md` —
do NOT fall back to a literal `app/build.gradle` path.

---

## Steps

### 1. Detect Build System

- Groovy Gradle (`build.gradle`) or Kotlin DSL (`build.gradle.kts`)
- Single-module or multi-module — already determined by
  `module-map.json` (`projectShape`); use it instead of re-detecting.
- Read `gradle.properties` for AndroidX, Jetifier, Java version

### 2. Add BlackBerry Maven Repository

Add the repository to the Gradle scope that owns dependency resolution
for this project. Do not assume that adding it to `settings.gradle` is
always sufficient: when `RepositoriesMode.PREFER_PROJECT` is configured,
project-level repositories override settings-level repositories for app
dependency resolution.

If the project uses `dependencyResolutionManagement.repositories` with
`RepositoriesMode.PREFER_SETTINGS` or
`RepositoriesMode.FAIL_ON_PROJECT_REPOS`, add the repository there:

```groovy
dependencyResolutionManagement {
    repositories {
        maven { url 'https://software.download.blackberry.com/repository/maven/' }
    }
}
```

If the project uses project-level repositories (or
`RepositoriesMode.PREFER_PROJECT`), add it to the root/project
`repositories {}` block that applies to `${primary_build_file}`:

```groovy
allprojects {
    repositories {
        maven { url 'https://software.download.blackberry.com/repository/maven/' }
    }
}
```

Kotlin DSL is equivalent:

```kotlin
maven(url = "https://software.download.blackberry.com/repository/maven/")
```

After editing, run the same Gradle dependency resolution command recorded
in `bootstrap.json.sdkProbe.probeCommand` (or re-run
`00pre-bootstrap.md` if bootstrap did not complete) and confirm the
repository issue is gone before adding Dynamics dependencies.

### 3. Add Dynamics SDK Dependencies

Add the dependencies to **`${primary_build_file}`** (resolved from the
module map). Do NOT hardcode `app/build.gradle` — the primary module's
build file may live elsewhere (`app-primary/app-primary/build.gradle.kts`,
`apps/foo/build.gradle`, etc.).

At minimum, in the primary application module's build file:
```groovy
def dynamics_version = '15.1.8766.18'  // Pin to Dynamics SDK 15.1
implementation "com.blackberry.blackberrydynamics:android_handheld_platform:$dynamics_version"
implementation "com.blackberry.blackberrydynamics:android_handheld_resources:$dynamics_version"
implementation "com.blackberry.blackberrydynamics:android_handheld_backup_support:$dynamics_version"
```

Add optional dependencies based on the Prompt 00 analysis:
- `android_webview` — if the app uses WebView
- `android_handheld_gd_safetynet` — if Play Integrity is needed

Do **not** add `android_handheld_blackberry_protect_support`. BlackBerry
Protect Mobile features (malware detection, safe browsing, SMS URL
scanning) were removed from the Dynamics SDK as of November 2025 / SDK
15.0. Remove any existing Protect Mobile dependency during migration.

**Library modules that reference Dynamics APIs.** For each module in
`${library_modules_referencing_dynamics}`, add the Dynamics SDK as
`compileOnly` to that module's own build file:

```groovy
compileOnly "com.blackberry.blackberrydynamics:android_handheld_platform:$dynamics_version"
```

`compileOnly` keeps the runtime classpath singular (the primary
application module is the sole carrier of the AAR contents) while
allowing the library to compile against `com.good.gd.*` types. Do NOT
duplicate `implementation` of Dynamics in library modules — that
produces duplicate-class errors at packaging time.

### 4. Bump minSdk to 33

Required for Dynamics SDK 15.1 (Android 13+). Android 12 (API 31–32)
is not supported. Never lower a higher existing `minSdk`.

- For projects whose Android `defaultConfig` lives in
  `${primary_build_file}`, edit `minSdk` there.
- For projects that route Android configuration through a convention
  plugin (entries listed under `${convention_plugin_files}`), edit
  `minSdk`/`minSdkVersion` in the convention plugin source instead —
  the module's own build file does not declare it. Search the
  `${convention_plugin_files}` set for the existing `minSdk` value
  and bump it there.

After bumping:
- Search for `Build.VERSION.SDK_INT` checks against API levels ≤ 33
  across `${in_scope_modules}` (primary + libraries).
- Remove dead `else` branches that reference missing resources or APIs
- The compiler will flag these as errors

### 5. Verify Java Runtime Compatibility (Do NOT force compileOptions)

Verify the build environment can run Dynamics tooling with JDK 17+, but
**do not add or modify** `compileOptions`/`kotlinOptions` language-level
blocks unless the project already has a proven, working requirement.

- Keep existing app language level as-is unless the app already requires
  a higher level.
- Do not inject:
  - `compileOptions { sourceCompatibility JavaVersion.VERSION_17 ... }`
  - `kotlinOptions { jvmTarget = "17" }`
  merely because Dynamics is being integrated.
- If build fails with `JdkImageTransform`, `androidJdkImage`, or `jlink`,
  remove newly-added Java 17 language-level blocks and retry.

### 6. Remove Conflicting Dependencies

Based on the Prompt 00 analysis, remove dependencies that Dynamics
replaces:
- SQLCipher (`net.zetetic:sqlcipher-android`) — Dynamics provides
  encrypted SQLite
- Biometric lock libraries — Dynamics SDK handles lock/unlock
- App-level backup libraries — Dynamics container manages backup

### 7. Required Manifest Permissions Audit (MANDATORY)

The Dynamics SDK requires `INTERNET`, `ACCESS_NETWORK_STATE`, and
`ACCESS_WIFI_STATE` in the **merged** manifest to open and maintain
the encrypted BlackBerry NOC tunnel. The SDK AARs declare these
permissions and the Android Gradle manifest merger injects them
automatically — but **only if the app manifest does not strip them**.

Apps that originated outside an enterprise context frequently ship with
a `tools:node="remove"` rule on one of these permissions (typically to
suppress a permission a transitive analytics / ads / Firebase library
contributed). Once Dynamics is in the build, that rule will neuter the
SDK's injected permission and the app will crash on first launch with:

```
com.good.gd.error.GDInitializationError:
    Permissions not declared, including android.permission.ACCESS_NETWORK_STATE
    at com.good.gd.GDAndroid.activityInit(...)
```

**Action — execute before running the build in Step 9:**

1. Resolve `${primary_manifests}` from `module-map.json`:
   `primaryAppModule.manifest` plus every entry under
   `primaryAppModule.flavorManifests[]` (if present). For single-module
   projects this is exactly `app/src/main/AndroidManifest.xml`.

2. In each manifest, search for any `<uses-permission>` element naming
   `android.permission.INTERNET`,
   `android.permission.ACCESS_NETWORK_STATE`, or
   `android.permission.ACCESS_WIFI_STATE` that carries
   `tools:node="remove"`.

3. For every match: **remove the `tools:node="remove"` attribute** and
   keep the `<uses-permission>` declaration. Annotate with the
   migration marker, for example:

   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Removed tools:node="remove" — Dynamics SDK requires ACCESS_NETWORK_STATE in the merged manifest -->
   <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
   ```

4. Do **not** add any of the three permissions if they are absent —
   the manifest merger pulls them in from the SDK AAR. This step only
   removes hostile `node="remove"` rules.

5. If the manifest root does not yet declare
   `xmlns:tools="http://schemas.android.com/tools"`, add it (also a
   prerequisite for the `tools:replace` work in
   `steering/10-gradle-integration.md`).

This audit is non-negotiable. The validator (`tooling/validate.sh`,
Phase 1) enforces it: `record-prompt-execution.sh --prompt-id 01
--status completed` will refuse while any `tools:node="remove"` on
these three permissions remains in a primary-module manifest. See
`steering/10-gradle-integration.md` → "Required Manifest Permissions
(MANDATORY — non-negotiable)" for the full rationale and the
security-review justification text.

### 8. Add Lint Configuration

Add to `${primary_build_file}` (or the convention plugin that owns
the `android { }` block, if `module-map.json` lists one):

```kotlin
android {
    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}
```

### 9. Add ProGuard Rules

```proguard
-keep class com.good.gd.** { *; }
-keep class * implements com.good.gd.GDStateListener { *; }
-dontwarn com.good.gd.**
```

### 10. Build and Verify

**IMPORTANT — Sandbox Permissions**: This build will download new
dependencies (Dynamics SDK from BlackBerry Maven). The command MUST be
run with `full_network` or `all` permissions in sandboxed IDEs. See
`steering/00-context.md § IDE Sandbox and Build Permissions`.

Run `./gradlew assembleDebug` to verify the project compiles with the
new dependencies and minSdk.

---

## Output

- List of Gradle files modified
- Dependencies added and removed
- minSdk change documented
- Dead code branches removed (if any)
- Build verification result

See `10-gradle-integration.md` for the full steering reference.

---

## Record execution

After Gradle integration is complete and the build verification passes,
append the execution record:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 01 \
    --status completed \
    --files-touched <comma-separated relative paths to gradle files modified>
```

This records prompt progress only. For an immediate diagnostic, run
`validate.sh --check-prompt 01`; prompt `10` remains the mandatory final
source/report gate.

# Steering: Multi-Module Projects

This file is the **agent-facing** guide for working on Gradle projects
that have more than one module — feature-based architectures, multi-app
repositories, projects using Gradle convention plugins, projects using
the version catalog, and projects with product flavors / build types
that have their own source sets.

The canonical specification of the artifact this guide describes lives
at `documentation/report-contract/module-map-schema-v1.0.0.md`. When
the two disagree, the canonical doc wins.

The kit produces `output/module-map.json` during prompt
`00pre-bootstrap.md` and refines it in prompt `00-analyze-app.md`.
Every other script and prompt in the pipeline reads from that file
rather than assuming the project lives under `app/`. The module map is
the single source of truth for *where* the migration applies.

---

## Migration target — one app per run

The kit migrates **exactly one Android Application module per run**.
Projects that ship multiple Android applications from the same repo
(`app-primary` and `app-secondary`)
require one migration run per application.

If multiple application modules are detected, the bootstrap exits with
an explicit list of candidates and the developer re-runs with
`--app-module <name>`. There is no implicit "migrate them all" mode;
the kit refuses to guess.

For single-application projects (which includes every project today
that has a single `app/` directory), no developer choice is needed and
the bootstrap auto-selects.

---

## What lands "in scope"

Once a primary application module is selected, the kit walks Gradle
project dependencies (`implementation(project(...))`,
`implementation(projects.foo.bar)`, `api(...)`, `compileOnly(...)`,
`runtimeOnly(...)`) and includes every reachable library module in the
migration. Reachability is **transitive without depth limit** — a
library that the primary depends on through three intermediate libraries
is just as in-scope as a library it depends on directly.

This means source-edit prompts (04, 05a–c, 06, 07, 08, 09) scan call
sites in **every** in-scope module, not just the application module.
Library / feature modules with `SQLiteOpenHelper`, `HttpURLConnection`,
`EditText`, `WebView`, etc. are migrated in place. The
`[BB_DYNAMICS-MIGRATION]` audit comment is added at every modification
point regardless of which module owns the file.

### What is excluded

- **Test-only edges.** Modules reachable only through
  `testImplementation`, `androidTestImplementation`,
  `testApi`, `androidTestApi`, `testCompileOnly`,
  `androidTestCompileOnly`, `testRuntimeOnly`, or
  `androidTestRuntimeOnly` are excluded. Test code does not ship in
  production builds and Dynamics authorization is not active during
  unit / instrumentation tests, so migrating those call sites would
  add noise without value. Excluded modules are recorded in
  `module-map.json.excludedTestOnlyModules[]` and surfaced in the
  migration report.
- **Kotlin Multiplatform modules.** Modules applying
  `org.jetbrains.kotlin.multiplatform` are excluded in v1.0.0 of the
  kit. Recorded with `reason: "kmp-module-ignored"`.
- **Convention plugin host modules.** A module whose only purpose is
  to host Gradle convention plugins (typically `build-plugin/`,
  `build-logic/`, or `buildSrc/`) is itself out of scope for source
  migration. Individual convention plugin files within it MAY be
  edited if `editStrategy: "edit-convention-plugin"` (see below).
- **Modules in composite builds.** Modules included via
  `pluginManagement { includeBuild(...) }` or top-level
  `includeBuild(...)` are walked only to resolve convention plugin
  source; their Android modules are not auto-discovered. If the
  developer's primary app module lives inside a composite build, they
  re-run with `--app-module`.
- **Other application modules in the same repo.** If the project has
  more than one `com.android.application` module, only the
  developer-selected one is migrated this run. The others are
  recorded in `otherAppModules[]` for transparency but are otherwise
  untouched.

---

## All source sets are read and written

A Gradle Android module can have many source sets:

- The `main` source set (always).
- Build-type source sets (`debug`, `release`, plus any custom build
  type the project declares — e.g. `beta` and `daily`).
- Product flavor source sets (`foss`, `full`, …) when the project
  uses `flavorDimensions`.
- Combinations (`fossDebug`, `fullRelease`, `dailyDebug`, …).

The kit reads and writes against **every source set that physically
exists on disk** under `<module>/src/`. `src/main/` is not privileged.
This matters because:

1. Real apps often place `Application` subclasses, OAuth
   configuration files, build-config-dependent code, and per-flavor
   `assets/` directories outside `main/`. Skipping those source sets
   would silently leave call sites unmigrated.
2. `settings.json` placement honors per-flavor `assets/` directories.
   When `module-map.json.primaryAppModule.settingsJsonPlacement.strategy`
   is `"per-flavor"`, prompt 02 writes `settings.json` to every
   `assets/` directory listed in `targets[]`, including a fallback
   copy in `src/main/assets/`.

Build types and product flavors that are declared in the build file
but have no physical `src/<name>/` directory are NOT recorded. There
is nothing on disk to scan or write into, so the kit ignores them.

---

## Convention plugins

Real-world projects with non-trivial Gradle setups (the
`com.android.application` plugin in particular) often apply that plugin
through a convention plugin rather than directly. A representative
multi-module app might look like this:

```kotlin
plugins {
    id(AppPlugins.Android.compose)
    alias(libs.plugins.dependency.guard)
    // ...
}
```

`AppPlugins.Android.compose` resolves through a constants
holder in `build-plugin/src/main/kotlin/AppPlugins.kt` to the
plugin id `"com.example.app.android.compose"`, which is implemented as
a Gradle precompiled script plugin at
`build-plugin/src/main/kotlin/com.example.app.android.compose.gradle.kts`.
That precompiled script applies `com.android.application` and
configures `android { ... }` and `dependencies { ... }` for every app
module that uses it.

The kit handles this with two strategies, recorded per convention
plugin in `module-map.json.conventionPlugins[].editStrategy`:

### `edit-convention-plugin`

The kit edits the convention plugin source file directly to add the
Dynamics SDK dependency, bump `minSdk`, configure ProGuard rules, and
add the BlackBerry Maven repository. This strategy is chosen when:

- The convention plugin source is a first-party file under
  `build-plugin/`, `build-logic/`, or `buildSrc/` in the same repo
  (not a binary plugin from an external Maven repository).
- The plugin's DSL is statically parseable (`dependencies { ... }`,
  `android { defaultConfig { ... } }` blocks recognizable by the
  kit's edit logic).
- The convention plugin is consumed by **only one** in-scope module
  (the primary app module). Editing a convention plugin shared
  between `app-primary` and `app-secondary` would change `app-secondary`
  too, which is undesired when the developer chose `app-primary`.

When this strategy is in effect, the `[BB_DYNAMICS-MIGRATION]` audit
comment is added in the convention plugin source file itself, not in
the consuming app module. Reviewers grepping the repo for the audit
tag still find every change.

### `override-in-app-module`

The kit leaves the convention plugin source untouched and adds new
`dependencies { ... }`, `android { defaultConfig { minSdk = 33 } }`,
and `android { lint { ... } }` blocks directly inside the consuming
app module's `build.gradle.kts`, after the convention plugin is
applied. Gradle's last-write-wins semantics make these overrides take
effect. This strategy is chosen when:

- The convention plugin source cannot be located (third-party plugin,
  binary plugin, or unresolvable plugin id), OR
- The convention plugin's DSL cannot be statically parsed (dynamic
  extension functions, version-catalog plumbing the kit can't
  evaluate without invoking Gradle), OR
- The convention plugin is shared by multiple app modules and editing
  it would touch out-of-scope apps.

This shared-plugin case falls here. `com.example.app.android.compose` is
applied by both `app-primary` and `app-secondary`; editing it would
add Dynamics dependencies to both apps. Instead, the kit adds the
override block to `app-primary/build.gradle.kts` only.

When this strategy is in effect, the audit comment is added in the
consuming app module's build file at the top of the inserted override
block.

### Choice is made by the bootstrap

The bootstrap classifies every convention plugin during discovery and
records the chosen strategy in `module-map.json` before any prompt
runs. Prompt 01 (Gradle integration) follows the recorded strategy
without re-evaluating the heuristic. If neither strategy is feasible
(e.g. the build file's structure defeats both edit paths), the
bootstrap records a warning and the prompt emits a `manualFollowUp`
finding listing the exact lines for the developer to add by hand.

---

## Library module SDK visibility

When a source-edit prompt modifies a file inside an in-scope library
module — for example, replacing `android.database.sqlite.SQLiteOpenHelper`
with `com.good.gd.database.sqlite.SQLiteOpenHelper` inside
`core/src/main/kotlin/.../MessageStore.kt` — the library module needs
the Dynamics SDK types visible at compile time.

The kit handles this through a dedicated post-source-edit prompt,
`01b-library-module-sdk-propagation.md`, which runs after prompts 04
through 09 but before prompt 10. For every library module that
received a source edit during this run (cross-referenced against
`migration-plan-state.json.callSites[].module`), the prompt ensures
the library's build file declares:

```kotlin
dependencies {
    compileOnly("com.blackberry.blackberrydynamics:android_handheld_platform:${dynamicsVersion}")
}
```

`compileOnly` is used (not `implementation`) because:

- The Dynamics SDK runtime classes are loaded once via the application
  module's `implementation` dependency and are visible to every
  library at runtime through Gradle's classpath assembly.
- Using `compileOnly` in libraries avoids duplicating the SDK in
  multiple `dependencies` graphs and prevents Gradle from emitting
  duplicate-class warnings.

`dynamicsVersion` is taken from
`bootstrap.json.sdkProbe.dynamicsSdkResolvedVersion`. If the project
has a version catalog (`gradle/libs.versions.toml`), the kit adds an
entry there and references it through `alias(libs.dynamics.platform)`
rather than hardcoding the coordinate string.

The library is never edited unless it actually received a source edit
during this run. Libraries that are reachable but contain no
Dynamics-relevant call sites (`containsRelevantApis: []`) are not
touched.

For single-application single-module projects, prompt 01b is a no-op
and records itself as `completed` with zero files touched.

---

## Reading the module map

When you (the agent) need to know where to scan or write, read
`output/module-map.json`. The shapes are documented in the canonical
spec, but the most common lookups are:

| You need…                                           | Read…                                                                |
|-----------------------------------------------------|----------------------------------------------------------------------|
| The primary app module's path                       | `primaryAppModule.path`                                              |
| Every directory containing Java/Kotlin source       | `primaryAppModule.sourceSets[].javaRoots[]` + `kotlinRoots[]` for the app, plus same for every entry of `libraryModulesInScope[]` |
| The manifest(s) to edit                             | `primaryAppModule.sourceSets[].manifest` for every non-null entry    |
| Where to write `settings.json`                      | `primaryAppModule.settingsJsonPlacement.targets[]`                   |
| The APK output glob for emulator install            | `primaryAppModule.apkOutputGlob`                                     |
| The convention plugin source to edit (if any)       | `primaryAppModule.conventionPluginRef.sourceFile` when `editStrategy == "edit-convention-plugin"` |
| The build file to override (if any)                 | `primaryAppModule.buildFile` when `editStrategy == "override-in-app-module"` |
| Which library modules contain relevant call sites   | `libraryModulesInScope[]` filtered by non-empty `containsRelevantApis` |

Shell scripts MUST NOT parse the JSON directly; they go through the
accessor library at `tooling/lib/module-map.sh`
(`mm_primary_path`, `mm_in_scope_source_roots`, `mm_settings_json_targets`,
etc.). This keeps the JSON shape changeable without touching every
script.

---

## Behavior on simple `app/`-shaped projects

Projects with a canonical `app/` directory and a single application
module — the shape every previously-migrated project has had — are
handled identically to before, with the kit producing a module map
populated as:

- `discoveryMethod: "fallback-app-dir"`
- `projectShape: "single-module"`
- `primaryAppModule.name: "app"`, `path: "app"`,
  `buildFile: "app/build.gradle"` or `"app/build.gradle.kts"`,
  `buildFileType: "direct"`, `conventionPluginRef: null`
- `libraryModulesInScope: []`
- `otherAppModules: []`
- `outOfScopeModules: []`
- `excludedTestOnlyModules: []`
- `conventionPlugins: []`
- `warnings: []`

No new developer questions are asked, no new flags are required, and
prompt 01b runs as a no-op. The downstream migration is functionally
identical to the pre-multi-module behavior.

---

## Cross-references

- Canonical schema: `documentation/report-contract/module-map-schema-v1.0.0.md`
- JSON Schema: `documentation/report-contract/module-map.schema.v1.0.0.json` (mirrored at `dynamics-migration-tool/schemas/`)
- Producer prompt: `prompts/00pre-bootstrap.md`
- Producer script: `tooling/bootstrap.sh`
- Refiner prompt: `prompts/00-analyze-app.md`
- Library SDK propagation: `prompts/01b-library-module-sdk-propagation.md`
- Shell accessors: `tooling/lib/module-map.sh`
- Bootstrap consumer: `steering/02-bootstrap-schema.md` (`projectModel` block)
- Migration report consumer: `steering/80-migration-report-schema.md` (`targetModule`, `findings[].module`)

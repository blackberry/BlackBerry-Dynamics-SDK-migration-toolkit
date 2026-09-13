# Changelog — BlackBerry Dynamics Migration Tool (Android)

All notable changes that are part of public Android toolkit releases are
documented in this file. Versioning follows
[Semantic Versioning](https://semver.org/). CI and Nexus publish build
stamps as `MAJOR.MINOR.PATCH.<N>`, while the component line remains
`MAJOR.MINOR.PATCH`.

Run each toolkit version end-to-end against a
fresh project and avoid mid-run upgrades.

---

## [Unreleased]

### Changed

- Dynamics conversions are **always a fresh install** (mandate, not an
  option): do not create or offer leftover SharedPreferences / SQLCipher /
  sandbox copy helpers (`steering/18-fresh-dynamics-install.md`).
  Steady-state replacements (`SecurePreferencesHelper`, GD File,
  Dynamics SQLite) remain required. No bootstrap schema change. Phase 4
  no longer skips leftover SharedPreferences inside a named copy helper.

### Fixed

- `migration-report-viewer.html` now renders **Run ID** and **Bootstrap Timestamp**
  from Android report fields (`runId`, `provenance.bootstrapGeneratedAt`) instead
  of looking only for the iOS `runProvenance` block (GD-69851).
- AUTH-PREF-001 (`auth-startup-scan.py`) now treats Kotlin `object`
  helpers (`SecurePreferencesHelper.getString(`) and preference property
  getters (`preferences.theme.value`, `isLockEnabled`) as prefs I/O, masks
  `if (!isContainerAuthorized) return` remainder-of-method, and ships
  fail/pass fixtures `fail-pre-auth-secure-prefs-property-chain` /
  `pass-deferred-secure-prefs-property-chain`. Copy
  `templates/file/SecurePreferencesHelper.kt` for fail-closed GD File I/O
  (do not gate the helper on idle-lock `isContainerAuthorized`).
- AUTH-PREF-001 named `*Preferences.getInstance().theme.value` chains
  now flag only when that class actually performs GD file / secure-prefs
  helper I/O (plain `UserPreferences` data classes are not prefs I/O).
  Extra top-level Kotlin `object` declarations are indexed for
  reachability. AUTH-UI-004 ignores `field?.` safe-calls as null guards.
  Fixtures: `pass-named-preferences-no-gd`,
  `fail-pre-auth-prefs-toplevel-object`, `pass-ui004-safe-call-nullable`.
- Phase 4 smoke now includes a leftover SharedPreferences copy helper
  (`onAuthorized` + `remove()`) that must fail — the
  `explicit_migration_context` exception is gone.
- AUTH-FILE-001 now treats `import com.good.gd.file.File` then `File(` as
  a GD constructor (not only `GDFile(` / FQCN) and indexes Kotlin
  extension functions (`fun ContextWrapper.getPrivateAttachmentsRoot()`).
  Fail fixture: `fail-fragment-gd-file-imported-ctor`. Pattern 7: the GD
  `File` constructor itself throws before `onAuthorized()`.
- AUTH-UI-004 now fails Phase-2 **observe-before-navigation** order:
  `initializeAuthorizedUi` / `onDynamicsAuthorized` calling a
  LiveData/prefs `observe` helper that uses deferred fields (including
  bare `navController` arguments and one-hop `setupLabelsMenuItems`)
  before `setupNavigation()` assigns them. After activation this runs
  from `onPostResume`, so `observe()` dispatches immediately
  (`UninitializedPropertyAccessException` / `Unable to resume`).
  Kotlin `LockedActivity<Binding>()` subclasses are now classified as
  Activities (generic parent was previously invisible). Combined
  ready/`isInitialized` guards (`if (!ready || !::nav.isInitialized)`)
  are recognized. Fixtures: `fail-ui004-observe-before-navigation` /
  `pass-ui004-navigation-before-observe`.
- Phase 8 **UI-CAST-001**: fail when a layout mixes a custom
  `TextView`/`EditText` subclass with `GDTextView`/`GDEditText` siblings
  and Kotlin/Java still does `view as CustomView` / `(CustomView) getChildAt`
  over ViewGroup children (`ClassCastException` on first Recycler bind).
  Prompt 09 must not rewrite custom XML tags. Fixtures:
  `fail-mixed-children-unsafe-cast` / `pass-mixed-children-filter-isinstance`.
- Prompt 09 / steering 45 / Phase 8 now run a catalog-driven two-lane UI migration
  (`GDAppCompatViewInflater` lane vs explicit `GD*` lane) backed by
  `tooling/lib/ui-widget-catalog.json` and `tooling/lib/ui-surface-scan.py`.
  Added checks: `UI_LANE`, `UI_BIND_001`, `UI_CHILD_001`, `UI_CUSTOM_001`,
  `UI_PROG_001`, `UI_SEARCH_001`, `UI_TIN_001`, `UI_REMOTE_001`, `UI_DRAG_001`.
  `TextInputEditText` is now a first-class migration target via
  `GDTextInputEditText`; unsupported widgets are explicitly keep-native
  (`keepNativeRows[]`) with residual-risk documentation.
- UI surface scanner now classifies mixed-lane tags from the catalog (inflater
  plus `GDTextView`/`GDEditText` dual hierarchy only — not `GDTextInputEditText`
  or `GDAppCompat*`), matches `TextInputEditText` by exact tag (not as a
  substring of `GDTextInputEditText`), treats `return EditText(context)` as a
  programmatic constructor, ignores `ItemTouchHelper.startDrag`, and emits
  `UI_EFFECTIVE_LANE` so Phase 8 remnant checks stay in inflater mode after a
  mixed-lane fail.
- Prompt 00 widget inventory classification now loads
  `tooling/lib/ui-widget-catalog.json` at runtime (`replaceRows[]` +
  `inventoryKinds[]`, minus `keepNativeRows[]`) instead of a second
  hardcoded kind list.
- Prompt 09 / steering 45 / steering 05 now tell re-runs on an already
  rewritten explicit-GD app to finish Lane B instead of installing the
  inflater on top of `GDTextView`/`GDEditText`. The superseded
  `ui-widget-cast-scan.py` helper was removed; Phase 8 uses `ui-surface-scan.py`.

---

## [1.0.0] — 2026-08-10

General-availability release for the Android toolkit. Lockstep component
version with iOS (`1.0.0`) targeting Dynamics SDK **15.0**
(`15.0.8513.64`).

### Changed

- Promoted toolkit component versioning to the `1.0.0` line for production
  release tracking (`1.0.0.<N>` in Jenkins/Nexus builds).
- Removed legacy release framing from public migration guidance and
  maintainer release documentation.

---

## [0.1.0] — 2026-07-14

Initial public Android toolkit release. Targets Dynamics SDK **15.0**
(`15.0.8513.64`).

### Added

- Pre-auth SecurePreferences / GD-file lifecycle gate **AUTH-PREF-001**
  (Phase 11 + `auth-startup-scan.py`) with fail/pass fixtures for Activity
  helper chains and chained `SecurePreferencesHelper` I/O before
  `onAuthorized()`.
- Deferred Activity UI lifecycle gate **AUTH-UI-004** (Pattern 14): fail
  when fields assigned in `initializeAuthorizedUi` / `setupNavigation` /
  `onDynamicsAuthorized` are used from lifecycle **or menu** callbacks
  (`onResume`/`onCreateOptionsMenu`/…) without a ready/null/`isInitialized`
  guard (two-phase auth + Toolbar/NavController cold-start crash class).
  Steering + prompts `03`/`03b`/`10` updated; fail/pass fixtures in
  `tooling/fixtures/auth-startup/`.
- **PROC-AUX-001** elevated from Phase-3 warning to **failure**, with 2-hop
  helper reachability (aux crash-handler → shared log helper → file/dir
  helper → GD File) so auxiliary processes cannot silently keep GD I/O.
- Report normalizer aliases `manualTodos[].priority` → `severity` when the
  value is already `P0|P1|P2|P3` (drops `priority` for
  `additionalProperties: false`); report-contract emits an explicit hint
  for analysis-vocab `priority` values.
- Kickoff / recovery guidance: `progress.sh` when stuck, fix owning prompt
  (do not thrash prompt `10`), stop on `ESCALATION REQUIRED`, optional
  `repair-orchestrator.sh` for controlled prompts, and
  `96-repair-loop-conduct.md` in the kickoff “especially read” list.
- Human-facing **When stuck** section in `MIGRATION_INSTRUCTIONS.md`.

### Included capability snapshot

- Prompt pipeline `00pre` → `10` (optional `00b`, `12`) with recorder
  `requires[]` gating, module/process model, Background Authorize (`03c`),
  and report schema **v2.1.0**.
- Bounded loop-state telemetry, optional repair orchestrator, reviewer
  lane, runtime-evidence contract, improvement backlog, and release
  assessment (maturing / optional; validators remain authoritative).

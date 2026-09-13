# Getting Started: Dynamics Migration Overview

This guide provides a high-level overview of the BlackBerry Dynamics migration process.

---

## Migration Phases

The migration follows a structured approach:

0. **Bootstrap** - Single human stop: confirm IDE permissions, capture UEM credentials and attestations, create backup branch, probe environment + network + Dynamics SDK classes, write `output/bootstrap.json` (prompt `00pre-bootstrap.md`)
1. **Analysis** - Inventory APIs, classify data, map lifecycle dependencies
2. **Project Setup** - Gradle integration, minSdk bump, dependency cleanup
3. **Configuration** - settings.json and entitlement setup (uses UEM values captured during bootstrap)
4. **Authorization** - Dynamics initialization, GDStateListener, two-phase startup
5. **Authorization Deferral Audit** - Systematic audit of ViewModels, Fragments, widgets, receivers, migrations
6. **Secure Databases** - Migrate SQLite/Room usage (most complex — do first)
7. **Secure File Storage** - Migrate file I/O operations
8. **Secure Networking** - Migrate HTTP, Socket, OkHttp/Retrofit
9. **Secure UI Widgets** - Apply the catalog-driven lane model: migrate every `replaceRows[]` widget to its Dynamics equivalent (inflater lane or explicit lane), keep `keepNativeRows[]` widgets native with residual-risk documentation
10. **Optional Features** - WebView, ICC, policy, etc.
11. **Testing & Validation** - Comprehensive testing with UEM
12. **Migration Report** - Generate machine-readable report and human-readable readme

---

## Steering Files Reference

The steering files are numbered to indicate the typical migration sequence:

- **00-context.md** - Core principles and expectations (includes **Implementation-First Principle**)
- **01-getting-started.md** - This overview file
- **02-bootstrap-schema.md** - `output/bootstrap.json` contract (produced by prompt 00pre)
- **03-implementation-first-conduct.md** - Implementation-first agent conduct: decision ladder, what to implement vs. when to ask
- **05-migration-checklist.md** - Track progress across all phases
- **06-inline-migration-comments.md** - `[BB_DYNAMICS-MIGRATION]` inline comment requirements
- **10-gradle-integration.md** - Add Dynamics SDK dependency
- **11-settings-json-reference.md** - settings.json and com.blackberry.dynamics.settings.json reference
- **12-capability-and-support-model.md** - Canonical tier/support reference: app complexity tiers (A/B/C), domain support levels (1/2/3), capability matrix, and glossary
- **13-unsupported-feature-detection-matrix.md** - Required unsupported/partial detection rules
- **14-api-provenance-and-replacement-catalog.md** - Deterministic native-to-Dynamics API mapping
- **15-redundant-feature-removal.md** - Features superseded by Dynamics (biometric lock, SQLCipher, app backup)
- **16-supported-app-tiers.md** - *(redirect stub — merged into 12-capability-and-support-model.md)*
- **18-fresh-dynamics-install.md** - Mandate: a Dynamics conversion is always a fresh install; leftover-data transfer is out of scope
- **20-auth-initialization.md** - Initialize Dynamics and handle authorization
- **21-authorization-deferral-patterns.md** - Patterns for deferring secure API access across ViewModels, Fragments, widgets, receivers, migrations
- **30-secure-networking.md** - Migrate networking code (HTTP, Socket, OkHttp)
- **40-secure-file-storage.md** - Canonical secure file storage guide (filesystem, stream-layer closure, storage layout redesign, native NDK file I/O)
- **41-secure-storage-sql.md** - Migrate SQL databases
- **42-secure-storage-sharedpreferences.md** - Replace runtime SharedPreferences with GD-backed `SecurePreferencesHelper` (no leftover-data copy helper; see 18)
- **45-secure-ui-widgets.md** - Migrate every covered UI widget in the secure family (including AppCompat auto-substitution)
- **50-webview-bbwebview.md** - Migrate WebView to BBWebView
- **60-icc-transferfileservice.md** - Add ICC support (if applicable)
- **70-background-authorize.md** - Background Authorize for push/FCM handling
- **78-push-channel.md** - FCM hardening and Dynamics Push Channel (`com.good.gd.push`)
- **71-launcher-branding-nightmode.md** - Launcher, branding API, Night Mode
- **72-local-compliance-and-custom-policies.md** - executeBlock/executeUnblock, custom UEM policies, DLP watermark
- **73a-app-config-read-and-refresh.md** - `getApplicationConfig()` cache-and-refresh on `onUpdateConfig`
- **73-play-integrity-attestation.md** - Play Integrity (GDSafetyNet) setup
- **74-fips-obfuscation-backup.md** - FIPS compliance, ProGuard, backup compatibility
- **75-certificates-kerberos.md** - Certificate deployment and Kerberos authentication
- **76-enterprise-simulation-testing.md** - Enterprise simulation mode and automated testing (ATSL)
- **77-activation-and-easy-activation.md** - Activation methods (standard, Easy, programmatic)
- **80-migration-report-schema.md** - Migration report schema (machine-readable contract)
- **81-migration-report-contract.md** - Mandatory report quality contract (confidence + release readiness)
- Maintainer-only diagnostics and release-runbook files now live under
  `_maintainer/` and are not part of the public migration prompt flow
- **90-test-against-uem.md** - Testing guidance
- **95-troubleshooting.md** - Common issues and solutions
- **99-docs-and-references.md** - Official documentation links

---

## Prompt Files Reference

The prompt files provide specific task instructions, run in order:

- **00pre-bootstrap.md** - Bootstrap the migration: permissions, UEM values, attestations, backup branch, SDK probe; writes `output/bootstrap.json` (**MUST run before `00-analyze-app.md`**)
- **00-analyze-app.md** - Analyze the app's architecture, APIs, and data flows (after `00pre`; before `01` — no code changes)
- **00b-generate-architecture-diagrams.md** - OPTIONAL diagnostics: generate data flow diagrams, storage/network classification, lifecycle dependency map, secure API call graph, authorization boundary, risk heatmap (after `00`; no code changes)
- **01-gradle-integration.md** - Add SDK dependency, bump minSdk, configure Maven repo, remove conflicting deps
- **02-create-settings-json.md** - Create `settings.json` from `output/bootstrap.json` (no UEM prompts here; UEM captured in `00pre-bootstrap.md`)
- **03-add-dynamics-auth.md** - Application class, GDStateListener, activityInit, manifest, two-phase startup
- **03b-authorization-deferral-audit.md** - Systematic audit of ViewModels, Fragments, widgets, receivers, migrations
- **04-sqlite-migrate-to-secure-sql.md** - Migrate SQL databases (Room bridge if needed)
- **05a-filesystem-core-io-migration.md** - Core file I/O migration
- **05b-filesystem-ui-reader-closure.md** - UI/consumer reader closure
- **05c-filesystem-sharedprefs-and-closure.md** - SharedPreferences + final closure
- **06-secure-networking-audit-and-migrate.md** - Audit and migrate networking
- **07-webview-migrate-to-bbwebview.md** - Migrate WebView to BBWebView
- **08-icc-add-transferfileservice.md** - Add ICC support (if applicable)
- **09-migrate-ui-widgets.md** - Catalog-driven UI migration: lane detection, type-safe widget replacement, and keep-native handling for unsupported widgets
- **11-push-channel.md** - FCM metadata-only hardening and Dynamics Push Channel migration (before `03c`)
- **03c-background-authorize.md** - Capture Background Authorize intent per push/job entry point (after `11`)
- **10-generate-migration-report.md** - Generate machine-readable migration report and human-readable `Dynamics_Migration_Readme.md`
- **12-generate-migration-retrospective.md** - OPTIONAL: after prompt 10, ask the developer whether to generate `output/migration-retrospective.md` (evidence-based run retrospective; no source changes)

---

## Quick Start

For a typical migration:

1. Run **00pre-bootstrap.md** — permissions, UEM credentials, attestations, backup branch, environment/SDK probe; writes `output/bootstrap.json`
2. Run **00-analyze-app.md** — flat API inventory, no code changes
3. (Optional) Run **00b-generate-architecture-diagrams.md** — diagnostics only, no code changes
4. Run **01-gradle-integration.md** — add SDK, bump minSdk, build verification
5. Run **02-create-settings-json.md** — writes `settings.json` from `bootstrap.json` (re-run `00pre-bootstrap.md` if UEM values are missing)
6. Run **03-add-dynamics-auth.md** — Application class, activityInit, manifest, main Activity startup
7. Run **03b-authorization-deferral-audit.md** — systematic audit of all pre-auth secure API access
8. Run **04-sqlite-migrate-to-secure-sql.md** — database migration (most complex piece)
9. Run **05a-filesystem-core-io-migration.md** — core file storage migration
10. Run **05b-filesystem-ui-reader-closure.md** — reader closure pass
11. Run **05c-filesystem-sharedprefs-and-closure.md** — sensitive prefs + final closure
12. Run **06-secure-networking-audit-and-migrate.md** — networking migration
13. Run remaining prompts (07-09) based on the migration plan
14. Run **11-push-channel.md** when FCM / push is in scope (before `03c`)
15. Run **03c-background-authorize.md** when `processModel.backgroundEntryPoints[]` is non-empty
16. Run **10-generate-migration-report.md** — final report + `Dynamics_Migration_Readme.md`
17. (Optional) Run **12-generate-migration-retrospective.md** — only if the developer wants `migration-retrospective.md`
18. Use **95-troubleshooting.md** when issues arise

---

## Key Success Factors

[OK] **Implement, Don't Report** - When you find a non-secure API, replace it with the Dynamics equivalent; do not just flag it  
[OK] **Exhaust All Options** - Direct replacement → pattern redesign → feature removal → partial migration → true blocker (last resort)  
[OK] **Continue Past Blockers** - A single unresolved call site does not block progress in other domains  
[OK] **Ask Only for Ambiguity** - Ask the developer only when two viable options exist with different UX trade-offs, or when UEM values are needed  
[OK] **Official Patterns** - Follow official BlackBerry Dynamics samples and the API catalog  
[OK] **Test Frequently** - Verify each phase before moving forward  
[OK] **Document Decisions** - Explain why changes are made

---

## Critical Configuration Files

These files are essential for Dynamics to work:

1. **settings.json** - Required configuration (GDApplicationID, etc.)
2. **AndroidManifest.xml** - Application class registration
3. **build.gradle** - Dynamics SDK dependency

Missing any of these will prevent the app from authorizing.

---

## Common Pitfalls to Avoid

[NOT OK] **Flagging findings instead of fixing them** — when the validator reports `java.io.File` construction, SharedPreferences, or external storage, IMPLEMENT the replacement, do not report "requires product/security decisions"  
[NOT OK] **Stopping the migration because one domain has unresolved findings** — continue to other domains; record unresolved sites in `manualTodos[]`  
[NOT OK] **Treating every non-waivable finding as a blocker** — most non-waivable findings have direct API replacements; use them  
[NOT OK] Running Gradle builds inside IDE sandbox without network permissions (see `00-context.md § IDE Sandbox and Build Permissions`)  
[NOT OK] Inventing or hardcoding UEM entitlement IDs outside `bootstrap.json` / `00pre-bootstrap.md`  
[NOT OK] Skipping settings.json creation  
[NOT OK] Calling Dynamics APIs before onAuthorized()  
[NOT OK] Mixing standard and Dynamics APIs for same data  
[NOT OK] Skipping covered UI widgets because they "look non-sensitive" (the covered family migrates in full; the only escape is a `secureUiWidgets` deferral)  
[NOT OK] Inventing API patterns not in official documentation

---

## Getting Help

- Review **95-troubleshooting.md** for common issues
- Check **99-docs-and-references.md** for official documentation
- Consult BlackBerry Developer Forums
- Contact BlackBerry Support with detailed logs

---

## Next Steps

1. Review **00-context.md** for core principles
2. Open **05-migration-checklist.md** to track progress
3. Begin with **00pre-bootstrap.md**, then `00`; run `00b` only if you want architecture diagnostics, then continue to project setup (`01`) onward
4. Work through phases sequentially
5. Test thoroughly at each phase
6. Document all changes and decisions

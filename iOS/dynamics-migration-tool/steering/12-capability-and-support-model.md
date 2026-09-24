# Steering: iOS Migration Capability & Support Model

This is the **canonical** tier and support reference for the iOS migration
tool. It replaces the former `12-capability-matrix.md` and
`16-supported-app-tiers.md`.

Use this file during Prompt 00 analysis and Prompt 10 reporting.

---

## Glossary

| Term | Definition |
|------|-----------|
| **App Complexity Tier** (A / B / C) | Classifies the *application* by how amenable its architecture is to migration. Determined during Prompt 00 analysis. |
| **Migration Domain** | A functional area of the SDK surface (e.g. authorization, secure storage, networking). Each domain has its own prompt phase. |
| **Domain Support Level** (1 / 2 / 3) | Indicates the *automation depth* the tool provides for a given migration domain: fully automatable, assisted, or advisory-only. |
| **Support Status** | Per-domain outcome for a specific app: `migrated`, `partial`, `unsupported`, or `deferred`. Recorded in the migration report. |
| **Unsupported Construct** | A specific API, pattern, or architecture element that cannot be safely migrated and must be flagged. Detection rules live in `13-unsupported-feature-detection-matrix.md`. |

---

## App Complexity Tiers

Determine the app's complexity tier during Prompt 00 to set expectations for
automation coverage and report outcomes.

### Tier A — Best Fit

- UIKit/SwiftUI apps with native storage/networking patterns.
- No App Extensions needing secure container access.
- Sensitive data mostly in file/Core Data/SQLite and URLSession.
- **Expected outcome:** high automation coverage, low manual TODO volume.

### Tier B — Assisted Fit

- Mixed legacy architecture, third-party libraries around storage/networking.
- Partial dependency on unsupported patterns with available workarounds.
- Multiple targets or complex startup graphs requiring auth deferral refactors.
- **Expected outcome:** moderate automation with explicit manual TODOs.

### Tier C — Advisory / Limited Fit

- Heavy dependence on unsupported patterns (SwiftData persistent history,
  same-store Core Data/SwiftData mixing, extension-centric secure workflows,
  App Clip secure data path assumptions).
- Opaque proprietary wrappers that hide data-at-rest and in-transit behavior.
- **Flutter / cross-platform hybrid hosts** (Flutter Runner, React Native without
  the official BlackBerry Dynamics React Native SDK, similar embeddings).
- **Expected outcome:** migration report first, with architecture redesign required.

### Flutter apps (this toolkit release)

BlackBerry Dynamics has **no official Flutter SDK**. This iOS migration toolkit
version therefore treats Flutter hybrids as **out of scope**:

- Detect Flutter early (Prompt `00pre` / `00`) using the signals in
  `13-unsupported-feature-detection-matrix.md`.
- Classify **Tier C** and record Flutter under `unsupportedDetections` /
  `unsupportedFeatures`.
- **Do not** attempt Dynamics authorization, window, or plugin-registrant
  migration of the Flutter Runner in this release.
- Default release readiness: **`no-go`**. Point the developer at native
  UIKit/SwiftUI Dynamics integration, or an officially supported cross-platform
  path (e.g. BlackBerry Dynamics React Native SDK) — not an ad-hoc Flutter
  Dynamics playbook from this kit.

### Mandatory Report Behavior by App Complexity Tier

| Tier | Default Release Readiness |
|------|--------------------------|
| A | `go` or `go-with-risks` |
| B | `go-with-risks`, with blocking items possible |
| C | `no-go` unless all critical blockers are resolved |
| C + Flutter detected | **`no-go`** (Flutter out of scope for this toolkit release) |

---

## Domain Support Levels

Each migration domain is classified by what the tool can automate:

- **Level 1 (automatable):** deterministic API replacement and configuration.
- **Level 2 (assisted):** partial automation with required manual developer steps.
- **Level 3 (advisory):** unsupported or redesign-required patterns.

---

## Capability Matrix

| Domain | Typical Source APIs/Patterns | Dynamics Target | Level | Required Evidence |
|---|---|---|---|---|
| Authorization lifecycle | App startup logic in `AppDelegate`/`SceneDelegate` | `GDiOS`, `GDiOSDelegate`, state notifications | 1 | `authorize()` invoked, authorized-state gate present |
| Info.plist entitlement config | `Info.plist` app config | `GDApplicationID`, `GDApplicationVersion`, URL schemes | 1 | keys and schemes present, no placeholder values |
| Secure file storage | `FileManager`, `FileHandle`, `InputStream`, `OutputStream` | `GDFileManager`, `GDFileHandle`, `GDCReadStream`, `GDCWriteStream` | 1 | sensitive file paths use GD APIs |
| Secure SQL | `sqlite3_open`, `sqlite3.h`, wrappers (FMDB/GRDB) | `sqlite3enc_open`, `GD_C.SecureStore.SQLite` | 2 | secure open path + migration/compat notes |
| Secure Core Data | `NSPersistentContainer`, standard store coordinator | `GDPersistentStoreCoordinator`, encrypted store types | 2 | post-auth init + encrypted store config |
| Secure SwiftData | `ModelConfiguration`, `ModelContainer`, `@Model` | `GDSecureModelConfiguration`, `GDSecureModelContainer.create` | 2 | post-auth factory; iOS 18+; no App-scene `.modelContainer(for:)` |
| Secure networking | `URLSession`, socket APIs | `GDURLLoadingSystem` (routed `URLSession`), `GDSocket` | 2 | transit paths documented as Dynamics-routed |
| Secure WebView | `WKWebView` | `WKWebView+GDNET` | 2 | secure web loading path and unsupported WK APIs listed |
| ICC / AppKinetics | `UIActivityViewController`, custom sharing | `GDService`, `GDServiceClient` | 2 | service definitions + provider/consumer handling |
| DLP / pasteboard | `UIPasteboard` use | `GDNativePasteboardAccess` + policy-aware behavior | 2 | pasteboard use audited and policy outcome documented |
| UEM policy interactions | local app config assumptions | Dynamics/UEM policy-driven behavior | 2 | policy dependencies documented |
| SwiftData persistent history, App Extensions, App Clips | history APIs / extension targets | N/A (workaround or redesign) | 3 | explicit unsupported feature entry + next steps |
| **Share Extension** | `com.apple.share-services` / Share Extension targets | **Unsupported** — isolate / non-shipping; never Dynamics-authorize the extension (`17-app-extensions-and-share-extensions.md`) | 3 | `unsupportedFeatures` + high manual TODO; Dynamics IPA excludes extension or approved URL handoff redesign |

### Share Extensions (this toolkit)

BlackBerry Dynamics **does not support** Share Extensions. When detected:

1. Continue migrating the **main app** (unlike Flutter whole-app stop).
2. Record Share Extension under `unsupportedDetections` / `unsupportedFeatures`.
3. **Do not** link Dynamics or call `authorize()` inside the extension.
4. Exclude the extension from Dynamics shipping (scheme / Archive / Embed App
   Extensions) and remove App Group sensitive bridges.
5. If product requires share-in: redesign to open the main Dynamics app and
   copy inbound content into `GDFileManager` only after authorize.
6. Release readiness: `go-with-risks` only when non-shipping + documented;
   `no-go` if still embedded or core workflow depends on the extension.

See `steering/17-app-extensions-and-share-extensions.md`.

---

## Required Outcome for Prompt 10

Prompt 10 report MUST include:

1. The app's complexity tier (A/B/C) with justification.
2. Which domains were Level 1/2/3 for this app.
3. Evidence for every migrated Level 1/2 domain.
4. Explicit unsupported entries for all Level 3 detections.
5. Manual TODOs for every Level 2/3 unresolved item.

---

## Cross-Reference

- **Unsupported construct detection:** `steering/13-unsupported-feature-detection-matrix.md`
- **API replacement catalog:** `steering/14-api-provenance-and-replacement-catalog.md`
- **Redundant feature removal:** `steering/15-redundant-feature-removal.md`

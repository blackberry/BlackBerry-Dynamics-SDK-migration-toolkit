# Steering: Android Migration Capability & Support Model

This is the **canonical** tier and support reference for the Android migration
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

- Native Android app (Java/Kotlin) with clear module ownership.
- Sensitive data paths are visible and can be mapped to Dynamics APIs.
- Startup/auth flow can be refactored to full authorization deferral.
- **Expected outcome:** high automation coverage, low manual TODO volume.

### Tier B — Assisted Fit

- Multi-module app with mixed dependency patterns and custom wrappers.
- Third-party libraries for files/networking/UI that need adapter patterns.
- Some external storage or sharing flows that can be bounded with policy.
- **Expected outcome:** moderate automation with explicit manual TODOs.

### Tier C — Advisory / Limited Fit

- Non-native or heavily abstracted stacks where data flow cannot be proven.
- Core product flows require external storage export or unrestricted sharing.
- Startup architecture fundamentally conflicts with authorization requirements.
- **Expected outcome:** migration report first, with architecture redesign required.

### Mandatory Report Behavior by App Complexity Tier

| Tier | Default Release Readiness |
|------|--------------------------|
| A | `go` or `go-with-risks` |
| B | `go-with-risks`, with blocking items possible |
| C | `no-go` unless all critical blockers are resolved |

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
| Authorization lifecycle | Activity startup and app initialization | `GDAndroid`, `GDStateListener`, `activityInit`/`authorize` | 1 | authorized-state gate and per-activity init evidence |
| Entitlement config | `assets/settings.json` or equivalent | `GDApplicationID`, `GDApplicationVersion`, `GDLibraryMode` | 1 | settings values present and non-placeholder |
| Secure file storage | `java.io.File*`, context file APIs | `com.good.gd.file.*` | 1 | sensitive writes no longer use standard file APIs |
| Secure SQL | `android.database.sqlite`, Room defaults | `com.good.gd.database.sqlite.*` | 2 | secure DB path + bridge handling documented |
| Secure networking | `HttpURLConnection`, sockets, OkHttp | `GDHttpClient`, `GDSocket`, `BBCustomInterceptor` | 2 | sensitive transit paths routed through Dynamics |
| Secure WebView | `android.webkit.WebView` | `com.blackberry.bbwebview.BBWebView` | 2 | web routes and caveats documented |
| ICC / sharing | standard sharing/FileProvider patterns | AppKinetics/TransferFileService patterns | 2 | secure sharing path and exceptions documented |
| DLP widgets and clipboard | Standard / AppCompat / Material text widgets (`EditText`, `TextView`, `AutoCompleteTextView`, `MultiAutoCompleteTextView`, `SearchView`, `CheckedTextView`, `AppCompat*` variants, `MaterialTextView`), `android.content.ClipboardManager`, and Jetpack Compose clipboard (`LocalClipboardManager`, `LocalClipboard`, `androidx.compose.ui.platform.ClipboardManager` / `Clipboard` / `ClipEntry`) | `com.good.gd.widget.GD*` equivalents, `com.good.gd.content.ClipboardManager` for platform clipboard, and interim `GDClipboardAdapter` (kit template) for Compose plain-text clipboard until official Compose-native Dynamics APIs exist. **Note**: `com.good.gd.widget.GDWebView` is not part of this family — secure WebView is owned by `com.blackberry.bbwebview.BBWebView` only (see WebView row above). | 2 | **every** covered widget in app-controlled UI migrated to its GD equivalent (no per-call-site sensitivity escape); platform and Compose clipboard surfaces migrated or documented with high-priority manual remediation; `secureClipboard` is non-waivable |
| Policy integration | `RestrictionsManager` and local policy assumptions | `GDAndroid.getApplicationPolicy*` | 2 | policy retrieval and callback handling evidenced |
| External storage exports | `MediaStore`, SD card, broad file sharing | secure-container patterns or controlled exception | 3 | explicit risk + mitigation decision |
| Complex non-native stacks | unsupported third-party abstractions | case-by-case workaround/redesign | 3 | unsupported/partial entry + manual plan |

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

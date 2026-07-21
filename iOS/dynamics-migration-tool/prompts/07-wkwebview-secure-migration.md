## Task: WKWebView Secure Migration

Goal: Ensure `WKWebView` uses secure content loading through the
Dynamics SDK's auto-swizzling and `WKWebView+GDNET` category.

**Prerequisites**:
- Prompts 00-03b must be complete
- The analysis (Prompt 00) identified WKWebView usage

**Skip this prompt if the app does not use WKWebView.**

**Background**: The Dynamics SDK auto-swizzles `WKWebsiteDataStore` and
`WKHTTPCookieStore` methods when secure communication is enabled on
authorization. This means WKWebView secure networking is largely
automatic — the `WKWebView+GDNET` import ensures the SDK's extensions
are linked.

---

## Steps

### 1. Process Every Owned WebView Call Site (Mandatory)

Read `output/migration-analysis.json` and isolate
`executionPlan[].domainId == "webview"` call sites.

For each call site, classify and record:
- support initialization state (`WKWebView+GDNET`, `supportWKWebView`)
- creation/init lifecycle point (`pre-auth` vs `post-auth`)
- content source (`remote`, `local file`, `html string`, `custom scheme`)
- local/remote/custom-scheme risk classification
- process pool / website data store / cookie behavior decision
- download/upload handling decision
- unsupported-feature decision
- cross-domain local-file producer evidence from Tranche 3 when applicable
- replacement API and API catalog row ID

Every applicable call site must receive a disposition in the closure ledger.

### 2. Verify Dynamics WKWebView Support Initialization

```swift
// [BB_DYNAMICS-MIGRATION] Import for secure WKWebView
import BlackBerryDynamics.GDNET
import WebKit
```

Or in Objective-C (CocoaPods):
```objc
// [BB_DYNAMICS-MIGRATION] Import for secure WKWebView
@import BlackBerryDynamics.GDNET;
```

Or in Objective-C (manual framework):
```objc
#import <BlackBerryDynamics/GD/WKWebView+GDNET.h>
```

After SDK authorization, WKWebView automatically uses secure communication.

### 3. Audit Unsupported or High-Risk Features

Check if the app uses any unsupported WKWebView features:

| Feature | Check For | Action |
|---------|-----------|--------|
| `WKDownload` | Download delegates | Replace with `GDFileManager` download |
| `WKFindConfiguration` | In-page search | Document as unsupported |
| Non-pageWorld | `WKContentWorld` other than `.pageWorld` | Use `.pageWorld` only |
| `removeAllUserScripts()` | Script removal calls | Remove — SDK needs its scripts |
| `loadFileURL` from container | Loading secure files | Use `loadHTMLString` instead |

### 4. Fix Content Loading from Secure Container

```swift
// Before (won't work with secure container)
webView.loadFileURL(secureURL, allowingReadAccessTo: directory)

// After
// [BB_DYNAMICS-MIGRATION] Load HTML content from secure container via data
let fm = GDFileManager.default
if let data = fm.contents(atPath: "/page.html"),
   let html = String(data: data, encoding: .utf8) {
    // Use a base URL so relative resources (images, scripts, stylesheets)
    // resolve correctly. Use the containing directory's path as the base.
    // If the HTML has no relative resource references, nil is acceptable.
    let baseURL = URL(fileURLWithPath: "/", isDirectory: true)
    webView.loadHTMLString(html, baseURL: baseURL)
}
```

**Important**: `baseURL: nil` breaks all relative resource references
(`<img src="...">`, `<link href="...">`, `<script src="...">`) inside
the HTML. If the loaded HTML document links to any relative resources
that are also stored in the secure container, set `baseURL` to the
directory URL containing those resources (e.g., the documents directory
in the secure container). Only use `nil` for fully self-contained HTML
strings with no external resource references.

### 5. Handle Custom Schemes, Process Pools, and Data Stores

For custom schemes/process-pool/data-store paths:
- classify if the configuration is safe and supported
- if safety cannot be proven, block and record rationale
- do not leave unreviewed custom scheme handlers active

### 6. Handle SFSafariViewController (if detected)

`SFSafariViewController` runs in a separate process and **cannot** be
controlled by Dynamics SDK swizzling. It will use the system network
stack, bypassing Dynamics secure networking entirely.

If the app uses `SFSafariViewController` for enterprise-sensitive content
(authenticated sessions, internal URLs):
- Flag as **unsupported** for enterprise use
- Add to migration report `manualTodos` with recommendation to replace
  with a `WKWebView`-based in-app browser or a Dynamics-compatible URL
  loading approach

If `SFSafariViewController` is used only for external/public URLs (e.g.,
opening a support webpage, OAuth redirect with no sensitive session data),
it may remain in place — document the decision.

### 7. Handle `removeAllUserScripts()` (if present)

Before removing any `removeAllUserScripts()` call, **ask the developer**:

> "The app calls `removeAllUserScripts()`. The Dynamics SDK injects its
> own scripts into WKWebView, so removing all scripts unconditionally may
> break SDK functionality. Was this call intentional for security
> isolation between WebView sessions? If so, we need to selectively
> remove only app-defined scripts, not SDK-injected ones."

Do NOT auto-remove this call. If it must be kept, replace with selective
removal of app-defined scripts by name rather than removing all scripts.

### 8. Verify WebView Creation Timing

WebViews that load enterprise content must be created post-authorization.

### 9. Document Unsupported Features

Add any detected unsupported WKWebView features to the migration report
as manual TODOs.

### 10. Build and Verify

Run `xcodebuild` to verify compilation. Classify any failures as
pre-existing (per developer clean-build attestation/history), step-introduced, or unrelated.

### 11. Run Scoped Validation (Required)

```bash
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt 07
```

Resolve all failures before recording prompt completion. Hard failures include:
- protected content loaded from unmanaged local files
- missing Dynamics WebView support where required
- unreviewed custom-scheme/process-pool/data-store bypass risks
- active unsupported WK feature without blocker
- unmanaged download/upload path without blocker
- pre-auth WebView initialization for enterprise content
- missing/wrong-owner ledger disposition

---

## Closure Ledger Update (Required)

Before recording Prompt 07 as `completed`, write call-site dispositions for
the `webview` domain using the atomic updater:

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "07" \
  --domain-id "webview" \
  --updates-file /tmp/webview-updates.json
```

Do not edit `output/migration-plan-state.json` directly.
Missing dispositions block recorder completion.

---

## Output

- `WKWebView+GDNET` imported for secure web content
- `GDURLLoadingSystem.supportWKWebView` / support initialization status verified
- `SFSafariViewController` usage assessed and documented
- `removeAllUserScripts()` reviewed with developer (not auto-removed)
- Content loading from secure container fixed with correct `baseURL`
- Custom scheme/process pool/data store decisions documented
- WebView creation deferred to post-authorization
- Build verification result
- Scoped validation (`--check-prompt 07`) passed

See `steering/50-wkwebview-secure.md` for the full steering reference.

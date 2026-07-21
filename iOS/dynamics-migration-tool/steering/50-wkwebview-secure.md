# Steering: Secure WKWebView (iOS)

The Dynamics SDK secures `WKWebView` content loading through a combination
of auto-swizzling and the `WKWebView+GDNET` category. This routes web
content through the Dynamics infrastructure, enabling access to enterprise
web resources.

Unlike Android (which replaces `WebView` with `BBWebView`), iOS keeps the
standard `WKWebView` class — the SDK hooks into it transparently.

---

## How WKWebView Secure Networking Works (Auto-Swizzling)

When the SDK enables secure communication on authorization, it
automatically swizzles several `WKWebView`-related classes:

- `WKWebsiteDataStore.defaultDataStore` / `nonPersistentDataStore` —
  intercepted to manage cookies in the secure container
- `WKHTTPCookieStore` methods (`getAllCookies:`, `setCookie:`,
  `deleteCookie:`, `getCookiePolicy:`, `setCookiePolicy:`) — intercepted
  for secure cookie management
- `WKWebsiteDataStore.removeDataOfTypes:` — intercepted for secure data
  store management

This swizzling happens as part of `GDURLLoadingSystem.enableSecureCommunication()`
which the SDK calls automatically on authorization.

**In practice, WKWebView secure networking is largely automatic** after
the SDK is authorized. The `WKWebView+GDNET` category import ensures
the SDK's WKWebView extensions are linked.

---

## Enabling Secure WKWebView

### Swift

```swift
import BlackBerryDynamics
import WebKit

let webView = WKWebView(frame: view.bounds)
// WKWebView automatically uses secure communication for enterprise
// resources after SDK authorization — no explicit enablement needed
```

### Objective-C

```objc
@import BlackBerryDynamics.GDNET;
// For manual framework integration use: #import <BlackBerryDynamics/GD/WKWebView+GDNET.h>
#import <WebKit/WebKit.h>

WKWebView *webView = [[WKWebView alloc] initWithFrame:self.view.bounds];
// Secure communication is auto-enabled after authorization
```

Use explicit evidence in Prompt 07 call-site records:
- `webviewSupportState` (`gdnet-imported`, `supportWKWebView-enabled`, or both)
- `webviewInitPoint` (`post-auth` expected for enterprise content)
- `catalogRowId` (`ios-webview-*`)

---

## Unsupported WKWebView Features

The following WKWebView features are NOT supported under Dynamics:

| Feature | Status | Notes |
|---------|--------|-------|
| `WKDownload` | Not supported | Use `GDFileManager` for downloads |
| `WKFindConfiguration` | Not supported | In-page search not available |
| `WKContentWorld` (non-pageWorld) | Not supported | Only `.pageWorld` works |
| `removeAllUserScripts()` | Not supported | SDK injects its own scripts |
| `WKWebView.loadFileURL(_:allowingReadAccessTo:)` | Limited | Cannot load from secure container directly |
| `callAsyncJavaScript` with non-pageWorld | Not supported | Use `.pageWorld` only |
| `WKWebpagePreferences` | Partial | Some properties may not work |

---

## Loading Content

### Loading from URL (Enterprise Resources)

```swift
// Works with GDURLLoadingSystem — enterprise resources accessible
let url = URL(string: "https://intranet.company.com/app")!
webView.load(URLRequest(url: url))
```

### Loading from Secure Container

Files in the Dynamics secure container cannot be loaded directly via file
URL. Instead, read the file content and load as HTML string or data:

```swift
// [BB_DYNAMICS-MIGRATION] Loading HTML from secure container
let fm = GDFileManager.default
if let data = fm.contents(atPath: "/cached-page.html"),
   let html = String(data: data, encoding: .utf8) {
    let baseURL = URL(fileURLWithPath: "/", isDirectory: true)
    webView.loadHTMLString(html, baseURL: baseURL)
}
```

If sensitive/protected content is loaded from unmanaged local files, Prompt 07
must block that path (or migrate it) rather than leaving a warning-only state.

### Loading Local Bundle Resources

Standard bundle resources (non-sensitive) can still be loaded normally:

```swift
if let url = Bundle.main.url(forResource: "help", withExtension: "html") {
    webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
}
```

---

## WKNavigationDelegate

The standard `WKNavigationDelegate` works with secure WKWebView:

```swift
extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Standard navigation policy — DLP may restrict external links
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                              URLCredential?) -> Void) {
        // Dynamics handles enterprise certificate challenges
        completionHandler(.performDefaultHandling, nil)
    }
}
```

---

## JavaScript Bridges

If the app uses `WKScriptMessageHandler` for JavaScript-to-native
communication:

```swift
// [BB_DYNAMICS-MIGRATION] JavaScript bridge works with secure WKWebView
// but only in WKContentWorld.pageWorld
let controller = webView.configuration.userContentController
controller.add(self, name: "nativeBridge")
```

**Important**: Only `WKContentWorld.pageWorld` is supported. Do not use
custom content worlds.

## Prompt 07 Closure Expectations (G20)

For each `webview` call site capture and decide:
- content source/classification (`remote`, `local-managed`, `local-unmanaged`, `custom-scheme`)
- custom scheme safety decision
- process pool decision
- website data store/cookie decision
- download/upload storage decision
- unsupported feature decision (`blocked` when active and unsupported)
- Tranche 3 local-file producer linkage when local sensitive content is rendered

No applicable WebView call site can be left without a ledger disposition.

---

## Common Issues

1. **WebView created before authorization** — the web view may fail to
   load enterprise content if created pre-auth
2. **Loading secure container files via file URL** — not supported; use
   `loadHTMLString` or `load(data:)` instead
3. **Removing user scripts** — `removeAllUserScripts()` removes SDK-injected
   scripts; do not call it
4. **Custom WKProcessPool** — may conflict with SDK web process handling; require explicit reviewed decision
5. **Custom URL scheme handlers** — can bypass reviewed network routing; require explicit reviewed decision or blocker
6. **Persistent/non-persistent data stores** — require explicit reviewed decision for protected content
7. **SFSafariViewController** — opens outside the Dynamics container; do not
   use for enterprise content

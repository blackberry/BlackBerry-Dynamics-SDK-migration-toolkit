# Steering: WebView to BBWebView Migration

If the app uses Android WebView, it must be replaced with BBWebView
to comply with Dynamics security policies. BBWebView provides secure
HTTP request interception, DLP-protected cut/copy/paste, page history
navigation, a secure cookies store, and file downloading into the
secure container.

---

## Discovery

Locate:
- `android.webkit.WebView` usage (Java/Kotlin and XML layouts)
- `WebViewClient` / `WebChromeClient` subclasses
- JavaScript bridges (`addJavascriptInterface`)
- File upload/download handling
- Local asset loading (`file:///android_asset/`)

---

## Gradle Dependency

Add the BBWebView library alongside the main Dynamics SDK:

```groovy
// [BB_DYNAMICS-MIGRATION] BBWebView library for secure WebView
implementation 'com.blackberry.blackberrydynamics:android_webview:$DYNAMICS_SDK_VERSION'
```

Or if using a local SDK distribution:

```groovy
implementation project(':BBWebView')
```

With `settings.gradle`:
```groovy
include(':BBWebView')
project(':BBWebView').projectDir = new File('${SDK_DISTRIBUTION_FOLDER}/sdk/libs/handheld/bb_webview')
```

---

## Migration: Import Changes

```java
// REMOVE these imports
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebChromeClient;

// ADD these imports
import com.blackberry.bbwebview.BBWebView;
import com.blackberry.bbwebview.BBWebViewClient;
import com.blackberry.bbwebview.BBWebChromeClient;
```

---

## Migration: XML Layout Changes

```xml
<!-- OLD -->
<WebView
    android:id="@+id/webView"
    android:layout_width="match_parent"
    android:layout_height="match_parent" />

<!-- NEW -->
<!-- [BB_DYNAMICS-MIGRATION] Replaced WebView with BBWebView for secure browsing -->
<com.blackberry.bbwebview.BBWebView
    android:id="@+id/webView"
    android:layout_width="match_parent"
    android:layout_height="match_parent" />
```

---

## Migration: Java Code Changes

```java
// OLD
WebView webView = findViewById(R.id.webView);
webView.setWebViewClient(new WebViewClient() { ... });
webView.setWebChromeClient(new WebChromeClient() { ... });

// NEW
// [BB_DYNAMICS-MIGRATION] Replaced WebView with BBWebView
BBWebView webView = findViewById(R.id.webView);
webView.setWebViewClient(new BBWebViewClient() {
    @Override
    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
        // Custom URL handling
        return false;
    }
    @Override
    public void onPageFinished(WebView view, String url) {
        // Page loaded
    }
});
webView.setWebChromeClient(new BBWebChromeClient() {
    @Override
    public void onProgressChanged(WebView view, int newProgress) {
        // Progress update
    }
});
```

Custom `WebViewClient` and `WebChromeClient` subclasses MUST extend
`BBWebViewClient` and `BBWebChromeClient` respectively — not the
standard Android classes.

---

## Loading Local Assets

BBWebView requires the web-like URL format for local assets instead of
`file:///android_asset/`:

```java
// OLD — will NOT work with BBWebView
webView.loadUrl("file:///android_asset/index.html");

// NEW — required format for BBWebView
// [BB_DYNAMICS-MIGRATION] Changed asset URL format for BBWebView compatibility
webView.loadUrl("https://appassets.androidplatform.net/assets/index.html");
```

This is compatible with the Same-Origin policy and recommended by Google
(see `WebViewAssetLoader`).

---

## Supported Features

BBWebView supports:
- Loading HTTP and HTTPS data
- Redirection
- Basic, Digest, NTLM, and Kerberos authentication
- Cookies (stored in secure container)
- Video and audio playback
- Asynchronous XHR requests
- WebSockets (with limitations: ServerTrust challenge, bufferedAmount,
  Basic/Digest/NTLM/Kerberos auth)
- File downloading into the secure container
- Viewing downloaded text, image (jpeg/jpg/png), audio (mp3), and
  video (mp4) files

## NOT Supported

BBWebView does NOT currently support:
- URL schemes (mailto:, geo:, etc.)
- Web Workers / Service Workers
- Drag-and-drop paste from Dynamics apps to WebView
- Resource caches
- Secure database (HTML5)
- Local storage (HTML5)
- Session storage
- AutoZSO (automatic zero sign-on)
- Dynamically created HTML iframes

---

## Accessing Downloaded Files

BBWebView downloads files into the secure container. Access them using
the Dynamics Secure Storage APIs (`com.good.gd.file`):

```java
// Get path to BBWebView download directory
// Access files using com.good.gd.file APIs
```

---

## CRITICAL: BBWebView Requires an Unlocked Container

Like all Dynamics secure APIs, BBWebView routes traffic through the
Dynamics infrastructure. The container must be unlocked before loading
any URLs. Initialize BBWebView in `onAuthorized()` or after the
container is confirmed authorized.

---

## Migration Rules

- Replace ALL WebView instances with BBWebView
- Extend `BBWebViewClient` / `BBWebChromeClient` (not standard Android)
- Update local asset URLs to `https://appassets.androidplatform.net/assets/`
- Document any features that rely on unsupported BBWebView capabilities
- Test thoroughly — some JavaScript-heavy pages may behave differently

---

## Output

- WebView feature matrix (supported vs unsupported in BBWebView)
- Code changes with explanation
- List of unsupported features that affect the app
- Testing notes for web content functionality

## Enterprise Hardening Addendum (JS bridge and settings)

- `addJavascriptInterface(...)` is API-supported, but this toolkit
  treats any call as a hard validation failure. If a JS bridge is
  unavoidable, the developer must defer the entire `webview` domain
  in `bootstrap.json deferredDomains[]` and the release readiness
  will reflect the gap.
- Unsafe WebView settings are disallowed: universal/file URL access toggles, mixed-content always-allow, permissive file/content access toggles.
- URL handling must use explicit allowlists.

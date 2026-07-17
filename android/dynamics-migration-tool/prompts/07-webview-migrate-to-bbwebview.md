## Task: WebView to BBWebView Migration

**Prerequisite**: Prompts 03 and 03b must be complete. WebView initialization
requires onAuthorized() — the authorization lifecycle must be in place first.

Goal: Replace Android WebView with BBWebView for secure browsing within
the Dynamics container.

**Module map context**: Load
`dynamics-migration-tool/output/module-map.json` and resolve:

- `${primary_build_file}` — the Gradle file that receives
  `android_webview`. (For projects routing Android config through a
  convention plugin, this dependency may already be added once and
  applied to multiple modules; the convention plugin source files
  listed in `module-map.json` `conventionPlugins[]` are the
  authoritative target.)
- `${in_scope_main_src}` and `${in_scope_res_dirs}` — `WebView` usage
  often lives in feature/UI library modules; both Java/Kotlin and
  XML layout searches scan the full in-scope set.

Library modules that reference `WebView` directly need the
`android_webview` Dynamics dependency as `compileOnly` (same
pattern as prompt 01 for the core SDK).

If `module-map.json` is missing, STOP and re-run `00pre-bootstrap.md`.

---

## Steps

1. Add BBWebView Gradle dependency:
   `implementation 'com.blackberry.blackberrydynamics:android_webview:$DYNAMICS_SDK_VERSION'`
2. Find all WebView usage (Java/Kotlin code and XML layouts)
3. Replace `android.webkit.WebView` with `com.blackberry.bbwebview.BBWebView`
4. Replace `WebViewClient` subclasses with `BBWebViewClient` extensions
5. Replace `WebChromeClient` subclasses with `BBWebChromeClient` extensions
6. Update local asset URLs from `file:///android_asset/` to
   `https://appassets.androidplatform.net/assets/`
7. Document any features that rely on unsupported BBWebView capabilities
   (Web Workers, local storage, session storage, URL schemes, etc.)
8. Ensure WebView initialization happens after `onAuthorized()`

See `50-webview-bbwebview.md` for the full migration guide including
supported/unsupported features, code examples, and limitations.

---

## Output

- WebView feature matrix (what works, what doesn't in BBWebView)
- Code changes with explanation
- List of unsupported features that affect the app
- Testing notes

---

## Record execution

After this prompt completes — whether it migrated WebView or skipped
because `webview` is `not-applicable` — append the execution record so
prompt 10's hard gate sees that the plan was honored:

```bash
# Migrated case
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 07 \
    --status completed \
    --files-touched <comma-separated relative paths>

# Skipped case (domain marked not-applicable in migration-analysis.json)
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 07 \
    --status skipped \
    --note "webview not-applicable per executionPlan"
```

## Enterprise Hardening Addendum (WebView)

Mandatory checks for enterprise posture:

1. Remove unsafe settings: `setAllowFileAccess(true)`, `setAllowContentAccess(true)`, `setAllowFileAccessFromFileURLs(true)`, `setAllowUniversalAccessFromFileURLs(true)`, and `MIXED_CONTENT_ALWAYS_ALLOW`.
2. `addJavascriptInterface(...)` is available in BBWebView/WebView APIs but is a hard validation failure in this kit. Remove the call entirely. If the JS bridge is unavoidable, the developer must defer the entire `webview` domain in `bootstrap.json deferredDomains[]`.
3. Implement strict URL allowlisting in `BBWebViewClient.shouldOverrideUrlLoading(...)`.
4. Document all allowed deviations in `manualTodos` with `severity: "P1"` and the appropriate `blocking` value.

Evidence discipline for this prompt:
- Use only kit-contained guidance from this prompt and `steering/50-webview-bbwebview.md`.
- Follow validator semantics in `tooling/validate.sh`. All findings are hard-fail unless the entire `webview` domain is deferred via `bootstrap.json deferredDomains[]`.

### Developer Deferral Stop (MANDATORY when WebView cannot fully close)

If a required WebView feature cannot be migrated safely this release, STOP and hand the developer this exact `deferredDomains[]` entry. The agent must not write it:

```json
{
  "deferredAt": "2026-06-25T12:00:00Z",
  "deferredBy": "developer",
  "developerSignedOff": true,
  "classification": "acceptedResidualRisk",
  "domain": "webview",
  "expiresAt": "2026-09-25T12:00:00Z",
  "reason": "Unsupported BBWebView capability remains and requires product review before release."
}
```

Do not create a partial placeholder. Missing `developerSignedOff`, `classification`, or `expiresAt` means the validator ignores the deferral and prompt 10 still hard-fails.

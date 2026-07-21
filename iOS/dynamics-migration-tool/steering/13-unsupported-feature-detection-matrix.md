# Steering: iOS Unsupported Feature Detection Matrix

Use this matrix in Prompt 00 and Prompt 10.

If a feature is detected and no implemented workaround exists, it MUST appear in
`unsupportedFeatures` and in `manualTodos`.

---

## Detection Matrix

| Feature | Detection Signals | Why Risky for Dynamics Migration | Expected Report Action |
|---|---|---|---|
| **Flutter hybrid (out of scope)** | `pubspec.yaml`, `Flutter/` engine dir, `GeneratedPluginRegistrant`, `FlutterEngine` / `FlutterViewController`, `Flutter.framework` / CocoaPods `Flutter` | No official BlackBerry Dynamics Flutter SDK. Flutter plugins (`path_provider`, `shared_preferences`, `file_picker`, etc.) are unmanaged; Dynamics single-window rules conflict with Flutter UIScene bring-up. Attempting Runner-only Dynamics wiring produces blank UI / crashes and false “migrated” reports. | **This toolkit release does not migrate Flutter apps.** Classify Tier C, add `unsupportedDetections` + `unsupportedFeatures`, set release readiness `no-go`, and **STOP** Dynamics code migration (do not invent FlutterEngine / plugin-registrant Dynamics playbooks). |
| **Share Extension (unsupported)** | `NSExtensionPointIdentifier` = `com.apple.share-services`; Share Extension target; `SLComposeServiceViewController` | Dynamics **does not support** Share Extensions — no secure-container access; App Group bridges leak trust boundary; do not `authorize()` inside the extension | **Call out + isolate.** Continue main-app migration. Exclude Share Extension from Dynamics shipping (scheme/Archive/Embed), remove App Group sensitive bridges, do not link Dynamics into the extension. Redesign inbound handoff via main-app URL open + post-auth `GDFileManager` if product requires share-in. See `17-app-extensions-and-share-extensions.md`. `go-with-risks` only when non-shipping; `no-go` if still embedded or required without redesign. |
| SwiftData | `@Model`, `ModelContainer`, `ModelContext` | Cannot be redirected directly to Dynamics secure container | Add unsupported feature with redesign recommendation |
| Other App Extensions (WidgetKit, Intents, Safari, Notification Service, Action) | extension targets / `NSExtensionPointIdentifier` for widget/intents/safari/etc. | Same container/lifecycle gap as Share Extensions | Same isolate / non-shipping doctrine as Share Extensions (`17-app-extensions-and-share-extensions.md`); list each target in `unsupportedFeatures` |
| App Clips | App Clip targets/capabilities | Not supported in standard Dynamics app model | Mark unsupported and propose full-app alternative |
| CloudKit/iCloud for sensitive data | CloudKit APIs or iCloud container usage for sensitive data | Sensitive data may leave secure container boundary | Mark unsupported or partial with risk + mitigation |
| Unsupported WKWebView capabilities | `WKDownload`, unsupported content worlds/features | Some WK features are not compatible with secure web path | Mark partial support with explicit feature list |
| Pre-auth secure access via actors/tasks | actors/tasks invoking secure APIs before authorized state | Runtime failures and undefined secure access behavior | Add high-priority TODO and risk entry |
| Third-party libs requiring raw filesystem/network | hard dependency on non-GD file/network APIs | Breaks secure container/transit guarantees | Mark partial/unsupported unless workaround exists |
| BlackBerry Protect Mobile / SafeBrowsing | Protect Mobile APIs, safe-browsing / SMS URL-scan integration | **Removed in SDK 15.0** — no longer supported | Mark unsupported; plan removal (do not migrate onto these APIs) |
| App-owned PKCS#7 / S/MIME (`GDPKCS7_*`) | `GDPKCS7_`, `GDCryptoPKCS7`, PKCS7_sign wrappers | OpenSSL 3.x in SDK 15.0 requires explicit flags; FIPS may reject Triple-DES | Add high-priority `manualTodo` for flag/cipher audit |

---

## Workaround Rule

- If workaround code exists and is validated, do NOT list as unsupported.
- Still record residual risk in:
  - `apisReplaced[*].riskReason`
  - `manualTodos` if further verification is required.

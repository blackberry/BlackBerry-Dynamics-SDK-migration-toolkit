# Steering: Authoritative References

Use ONLY these sources as authoritative:

---

## Official Documentation

- **BlackBerry Dynamics SDK for Android Development Guide** (v15.1)
  — The primary reference for this migration tool
- **BlackBerry Dynamics SDK API Reference (Android)** (15.1.8766.18)
  — https://developer.blackberry.com/files/blackberry-dynamics/android/
- **BlackBerry Dynamics SDK for Android 15.1 Release Notes**
  — https://docs.blackberry.com/en/blackberry-dynamics-sdk/15.x/blackberry-dynamics-sdk-for-android/blackberry-dynamics-sdk-for-android-release-notes/blackberry-dynamics-sdk-for-android-version-15.1
- **BlackBerry UEM Administration Guide**
  — For entitlement setup, policy configuration, compliance profiles
- **BlackBerry Dynamics Security White Paper**
  — For security architecture and Easy Activation details

## Key API References

- `GDAndroid` class — Initialization, authorization, policy, services
- `GDStateListener` interface — Authorization lifecycle callbacks
- `GDHttpClient` — Secure HTTP client (Apache HTTP style)
- `GDSocket` — Secure TCP socket
- `BBCustomInterceptor` — OkHttp interceptor for Dynamics
- `BBCookieJar` — Secure cookie support for OkHttp
- `BBWebView` / `BBWebViewClient` / `BBWebChromeClient` — Secure WebView
- `com.good.gd.database.sqlite.*` — Secure SQLite
- `com.good.gd.file.*` — Secure filesystem
- `com.good.gd.widget.*` — Secure UI widgets (DLP)
- `com.good.gd.content.ClipboardManager` — Secure clipboard
- `GDLogManager` — Log upload monitoring
- `GDDiagnostic` — Connectivity diagnostics
- `GDServiceClient` / `GDService` — Inter-Container Communication (ICC)

## Sample Apps

The SDK includes sample apps demonstrating key features:
- **Skeleton** — Starting point for new apps
- **Apache HTTP client** — Secure networking
- **Secure SQL** — Secure database
- **Secure copy-cut-paste** — DLP widgets
- **AppKinetics** — Shared Services Framework / ICC
- **App policy** — Custom policies and Night Mode
- **Greetings client/server** — ICC and Play Integrity
- **Push channel** — Push notifications
- **Interaction** — GDStateListener events, executeBlock/executeUnblock
- **Bypass Unlock** — Password bypass feature
- **AppBasedCertImport** — Certificate import API

Source code: https://github.com/blackberry/BlackBerry-Dynamics-Android-Samples

## Additional Resources

- **Application Policies Definition** appendix in API Reference
  — For custom UEM policy XML schema
- **Android Auto Backup** appendix in API Reference
  — For backup compatibility with Dynamics
- **Build-Time Configuration** appendix in API Reference
  — For ProGuard/obfuscation configuration
- **Crypto C Programming Interface** appendix in API Reference
  — For certificate signing/verification (`GDCryptoPKCS7`, OpenSSL 3.5.4
    flag rules in SDK 15.0)
- **BlackBerry Analytics documentation**
  — For analytics portal and REST API
- **Bypass Unlock Developer Guide**
  — For password bypass implementation

> **Removed in SDK 15.0:** BlackBerry Protect Mobile features (malware
> detection, safe browsing, SMS URL scanning) are no longer supported.
> Do not steer migrations toward Protect Mobile APIs or the
> `android_handheld_blackberry_protect_support` artifact.

---

## Rules

- If information is missing or unclear, request clarification
- Do not rely on third-party blogs or StackOverflow
- Cross-reference with the official API reference when in doubt
- The Dynamics SDK 15.1 Development Guide / release notes are the
  canonical source for integration guidance in this toolkit revision

## Standalone migration kit (no internal SDK sources)

This tool is packaged for **third-party developers** migrating their own
apps. Agents and validators must **not** depend on, link to, or search
BlackBerry-internal SDK repositories (for example company-internal `msdk/`
or `endpoint/` source trees).

Authoritative sources for API mapping and verification:

1. Official BlackBerry Dynamics documentation and API reference (above).
2. The Dynamics SDK **installed** on the developer machine (Maven
   artifacts + `sdk/libs/handheld/libs/gd/inc/` C headers).
3. Public sample code at
   https://github.com/blackberry/BlackBerry-Dynamics-Android-Samples

The canonical replacement tables live in this kit under
`steering/14-api-provenance-and-replacement-catalog.md`.

## Additional hardening references

- `74a-third-party-telemetry.md`

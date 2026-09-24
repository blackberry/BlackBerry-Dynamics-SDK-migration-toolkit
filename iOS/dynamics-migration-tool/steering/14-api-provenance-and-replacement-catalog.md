# Steering: iOS API Provenance and Replacement Catalog

This file is the canonical mapping from native iOS APIs to Dynamics APIs,
with provenance to public documentation and the installed SDK.

## Source Provenance

- Public API reference: `https://developer.blackberry.com/files/blackberry-dynamics/ios/`
  (generated from the installed SDK headers; version 15.1.8766.18 at time of last review).
- Public development guide: BlackBerry Dynamics SDK for iOS documentation at
  `https://docs.blackberry.com/en/development-tools/blackberry-dynamics-sdk-ios/`.
- Public samples: `https://github.com/blackberry/BlackBerry-Dynamics-iOS-Samples`.
- Official SPM package: `https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK`
  (tag `v15.1.18` ships SDK build `15.1.8766.18`; products `BlackBerryDynamics`
  + `GSEProvider`).
- Installed SDK headers: headers present in `Pods/BlackBerryDynamics/` after
  `pod install`, in the SPM checkout after package resolution, or in the
  manually linked `.xcframework` — use these to verify exact method
  signatures when integrating.

**Third-party guidance rule:** API names in this catalog must be verifiable against
the installed SDK headers or the official API reference. Do not invent or guess
replacement APIs; if a mapping is uncertain, record it as `confidence: "docs-only"`
and add a `manualTodo`.

## Target SDK release

This toolkit revision targets **BlackBerry Dynamics SDK for iOS 15.1**
(public API reference / CocoaPods build **15.1.8766.18**).

Release-note deltas that affect migration steering (not every app needs
code changes):

| Area | SDK 15.1 change | Migration action |
|------|-----------------|------------------|
| Minimum iOS | iOS 17 removed; **iOS 18+** required (iOS 27 supported) | Raise `IPHONEOS_DEPLOYMENT_TARGET` / `platform :ios` only if below 18.0; never lower a higher target |
| Packaging | CocoaPods + official SPM tag `v15.1.18`; crypto via `GSEProvider.xcframework` | Use `pod 'BlackBerryDynamics', '~> 15.1'` **or** SPM URL `https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK` (`15.1.18`) linking products `BlackBerryDynamics` + `GSEProvider` |
| SwiftData | `GDSecureModelConfiguration` + `GDSecureModelContainer.create(...)` | Migrate `@Model` stores in Prompt 04c; do not rewrite to Core Data |
| Siri / Apple Intelligence DLP | Screenshot restriction also blocks Siri AI from on-screen and selected text | Policy-driven; remove app-level screenshot hacks; verify UEM "Do not allow screenshots" |
| TLS | TLS 1.3 with AES-GCM cipher suites (AES-CCM not supported) | No API swap; regress `GDURLLoadingSystem` / `URLSession` / `GDSocket` against TLS 1.3 endpoints |
| Third-party libraries | SQLite, cURL, and OpenSSL updated | Regression for secure SQL and networking; no app API rename |

SDK 15.0 deltas that remain in force (do not re-attribute them to 15.1):

| Area | SDK 15.0 change | Migration action |
|------|-----------------|------------------|
| Packaging | CocoaPods + official SPM; crypto via `GSEProvider.xcframework` | Remove Certicom pair; keep GSEProvider |
| OpenSSL | Upgraded to OpenSSL 3.5.4 (15.1 refreshes the library again) | Review any `GDCryptoPKCS7` / PKCS#7 call sites for stricter flag handling (`GDPKCS7_BINARY`, `GDPKCS7_DETACHED`) |
| FIPS | Provider upgraded to FIPS 140-3 | Prefer AES-128/256-CBC over Triple-DES for S/MIME when FIPS is enabled; see `74-fips-compliance.md` |
| SecureStorage | New activations use AES-GCM; existing stay AES-CBC | No app API swap; note in report if storage crypto posture matters |
| Protect Mobile | Safe browsing / SMS URL scan removed | Remove Protect Mobile / SafeBrowsing API usage; do not migrate onto those APIs |
| Networking | `GDHttpRequest` / `GDHttpRequestDelegate` deprecated in the 15.x API reference; removal is scheduled for SDK **16.0** | Never target these classes and never require them to be present; route HTTP through `GDURLLoadingSystem` by using `URLSession` / `NSURLConnection`, and rewrite any legacy `GDHttpRequest` call sites |
| UEM profile | "Open files unencrypted in other selected non-Dynamics apps" | Policy-driven; keep outbound file transfer on Dynamics-controlled paths (AppKinetics / secured share) |
| UEM profile | "Do not require authentication when securely receiving a file from an authenticated Dynamics app" | Policy-driven receive UX; do not invent app-level auth bypass — keep ICC receive on Dynamics service APIs |
| Native share | Text share via native iOS share menu to BlackBerry Work | Optional product capability; still classify protected file/share flows per ICC/DLP rules |

Official notes:
https://docs.blackberry.com/en/blackberry-dynamics-sdk/15.x/blackberry-dynamics-sdk-for-ios/blackberry-dynamics-sdk-for-ios-release-notes/blackberry-dynamics-sdk-for-ios-version-15.x

## Deterministic Replacement Rules

| Domain | Native API / Pattern | Dynamics Replacement | Tier | Notes |
|---|---|---|---|---|
| Authorization | App launches and accesses secure data immediately | `GDiOS.authorize()` + defer to authorized callback | tier1 | Mandatory for all Dynamics apps |
| Secure files | `FileManager`, `FileHandle`, stream file I/O for sensitive data | `GDFileManager`, `GDFileHandle`, `GDCReadStream`, `GDCWriteStream` | tier1 | Keep non-sensitive cache native if justified |
| Secure SQLite | `sqlite3_open*` for sensitive DB | `sqlite3enc_open*` via Dynamics `sqlite3.h` + `sqlite3enc.h` (all `sqlite3_*` from Dynamics on iOS) | tier1 | Paths in secure container; never mix with system libsqlite3 |
| FMDB | FMDB over `sqlite3_open` | Direct `sqlite3enc_*` **or** retain FMDB with full iOS Dynamics SQLite linkage | tier2 | Open-only bridges → SIGSEGV; see `41-secure-storage-sql.md` |
| Secure Core Data | `NSPersistentStoreCoordinator` standard stack | `GDPersistentStoreCoordinator` | tier2 | Requires stack refactor, not pure import swap |
| Secure SwiftData | `ModelConfiguration` / `ModelContainer` for sensitive `@Model` stores | `GDSecureModelConfiguration` + `GDSecureModelContainer.create(_:migrationPlan:)` | tier2 | iOS 18+; factory only; post-auth; keep `@Model`/`@Query`/`ModelContext` |
| Secure networking (Foundation) | `URLSession`, `NSURLConnection` | Keep standard APIs; routed post-auth by `GDURLLoadingSystem` | tier1 | Do not replace with invented APIs; verify post-auth initiation |
| Secure networking (direct sockets) | `NWConnection`, `CFSocket`, `NSStream`, `GCDAsyncSocket`, socket wrappers | `GDSocket` (or explicit blocker if safe migration cannot be proven) | tier1 | Host/port/TLS set in `GDSocket` init; `connect()` takes no args |
| Secure networking (background sessions) | `URLSessionConfiguration.background(...)`, background callbacks | Classification only in this tranche (foreground defer vs G12 blocker) | tier1 | Do not implement Background Authorize in Tranche 4 |
| Secure networking (withdrawn HTTP class) | legacy `GDHttpRequest` / `GDHttpRequestDelegate` call sites | `URLSession` / `NSURLConnection` routed post-auth by `GDURLLoadingSystem` | tier2 | Deprecated in 15.x and dropped from SDK headers in 16.0 — never a replacement target; rewrite request, response, and delegate handling |
| Web content | `WKWebView` enterprise flows | `WKWebView+GDNET` / `GDURLLoadingSystem.supportWKWebView` with lifecycle-safe init | tier2 | Local/custom/unsupported paths require explicit decision or blocker |
| ICC / sharing | open share sheet for enterprise flows | `GDService` / `GDServiceClient` (`GDServices.h`) | tier2 | AppKinetics pairing + Info.plist service registration required |
| External data movement / DLP | unmanaged document/share/export/import surfaces | classify direction + migrate/secure-copy/block | tier2 | Protected unmanaged outbound defaults to blocked unless approved |
| Clipboard / DLP | uncontrolled `UIPasteboard` flows | `GDNativePasteboardAccess.performActionOnNativePasteboard:` + policy-aware handling | tier2 | Manual UI flow verification required |
| Policy access | custom config channels | `getApplicationConfig`, `getApplicationPolicy`, `getApplicationPolicyString`, policy update events | tier2 | Reads must be post-auth; update/cache handling required |

## SDK 15.0 crypto notes (`GDCryptoPKCS7` / OpenSSL 3.x)

SDK 15.0 upgrades OpenSSL to **3.5.4**. Every flag that is semantically
relevant to a PKCS#7 operation must be supplied at every call site
(`GDPKCS7_add_signer`, `GDPKCS7_final`, `GDPKCS7_write`,
`GDPKCS7_verify`, …). Missing flags can cause silent data corruption or
verification failures.

| Scenario | Required flags / inputs |
|---|---|
| Binary (non-MIME) signature | Pass `GDPKCS7_BINARY` to `GDPKCS7_add_signer`, `GDPKCS7_final`, and `GDPKCS7_write` |
| Detached signature | Pass `GDPKCS7_DETACHED \| GDPKCS7_BINARY`; on verify, supply original content via the `indata` parameter of `GDPKCS7_verify` |

Public reference:
https://developer.blackberry.com/files/blackberry-dynamics/ios/group__cryptolist.html

Most Swift/ObjC migrations never call these C APIs. When Prompt 00 finds
native PKCS#7 / S/MIME usage, treat flag review as a blocking crypto
follow-up and record it in `manualTodos`.

## Unsupported or Advisory Patterns

| Pattern | Tier | Required Action |
|---|---|---|
| Persistent history tracking on a secure SwiftData/Core Data store | tier3 | Unsupported on the Dynamics store; redesign change detection. Do not mark as migrated |
| Core Data and SwiftData sharing one store URL | tier3 | Use separate stores; Prompt 04b and 04c are complementary |
| App Extensions (WidgetKit, Share Extension, etc.) needing secure container | tier3 | Split architecture, keep secure flows in main app |
| App Clip requiring Dynamics secure container | tier3 | Redesign feature boundary |
| CloudKit/iCloud for sensitive container data | tier3 | Keep sensitive data in secure container |
| Broad file sharing to non-Dynamics apps | tier3 | Restrict or replace with secure transfer patterns; honor UEM "Open files unencrypted in other selected non-Dynamics apps" when present |
| BlackBerry Protect Mobile (safe browsing / SMS URL scan) | tier3 | **Removed in SDK 15.0** — delete Protect / SafeBrowsing API usage |
| App-owned `GDPKCS7_*` without OpenSSL 3.x flags | tier2 | Audit call sites for `GDPKCS7_BINARY` / `GDPKCS7_DETACHED` (+ `indata` on detached verify) |
| S/MIME Triple-DES under FIPS-enabled profile | tier2 | Prefer AES-128-CBC or AES-256-CBC; Triple-DES encryption returns an error when FIPS is enabled |

## Catalog Usage Rules

- Use this catalog when generating `apisReplaced` in `migration-report.json`.
- Every replacement entry should map to exactly one row above.
- If no row applies, add a `manualTodo` and mark domain as `partial`.
- Do not invent replacement APIs that are absent from public docs or the
  installed SDK headers.

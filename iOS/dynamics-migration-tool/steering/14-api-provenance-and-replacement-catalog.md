# Steering: iOS API Provenance and Replacement Catalog

This file is the canonical mapping from native iOS APIs to Dynamics APIs,
with provenance to public documentation and the installed SDK.

## Source Provenance

- Public API reference: `https://developer.blackberry.com/files/blackberry-dynamics/ios/`
  (generated from the installed SDK headers; version 15.0.8513.67 at time of last review).
- Public development guide: BlackBerry Dynamics SDK for iOS documentation at
  `https://docs.blackberry.com/en/development-tools/blackberry-dynamics-sdk-ios/`.
- Public samples: `https://github.com/blackberry/BlackBerry-Dynamics-iOS-Samples`.
- Official SPM package: `https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK`
  (tag `15.0.0` ships SDK build `15.0.8513.67`; products `BlackBerryDynamics`
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

This toolkit revision targets **BlackBerry Dynamics SDK for iOS 15.0**
(public API reference / CocoaPods build **15.0.8513.67**).

Release-note deltas that affect migration steering (not every app needs
code changes):

| Area | SDK 15.0 change | Migration action |
|------|-----------------|------------------|
| Packaging | CocoaPods + official SPM; crypto via `GSEProvider.xcframework` | Use `pod 'BlackBerryDynamics', '~> 15.0'` **or** SPM URL `https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK` (`15.0.0`) linking products `BlackBerryDynamics` + `GSEProvider`; remove Certicom pair |
| OpenSSL | Upgraded to OpenSSL 3.5.4 | Review any `GDCryptoPKCS7` / PKCS#7 call sites for stricter flag handling (`GDPKCS7_BINARY`, `GDPKCS7_DETACHED`) |
| FIPS | Provider upgraded to FIPS 140-3 | Prefer AES-128/256-CBC over Triple-DES for S/MIME when FIPS is enabled; see `74-fips-compliance.md` |
| SecureStorage | New activations use AES-GCM; existing stay AES-CBC | No app API swap; note in report if storage crypto posture matters |
| Protect Mobile | Safe browsing / SMS URL scan removed | Remove Protect Mobile / SafeBrowsing API usage; do not migrate onto those APIs |
| UEM profile | "Open files unencrypted in other selected non-Dynamics apps" | Policy-driven; keep outbound file transfer on Dynamics-controlled paths (AppKinetics / secured share) |
| UEM profile | "Do not require authentication when securely receiving a file from an authenticated Dynamics app" | Policy-driven receive UX; do not invent app-level auth bypass — keep ICC receive on Dynamics service APIs |
| Native share | Text share via native iOS share menu to BlackBerry Work | Optional product capability; still classify protected file/share flows per ICC/DLP rules |

Official notes:
https://docs.blackberry.com/en/blackberry-dynamics-sdk/15.x/blackberry-dynamics-sdk-for-ios/blackberry-dynamics-sdk-for-ios-release-notes/blackberry-dynamics-sdk-for-ios-version-15.0

## Deterministic Replacement Rules

| Domain | Native API / Pattern | Dynamics Replacement | Tier | Notes |
|---|---|---|---|---|
| Authorization | App launches and accesses secure data immediately | `GDiOS.authorize()` + defer to authorized callback | tier1 | Mandatory for all Dynamics apps |
| Secure files | `FileManager`, `FileHandle`, stream file I/O for sensitive data | `GDFileManager`, `GDFileHandle`, `GDCReadStream`, `GDCWriteStream` | tier1 | Keep non-sensitive cache native if justified |
| Secure SQLite | `sqlite3_open*` for sensitive DB | `sqlite3enc_open*` via Dynamics `sqlite3.h` + `sqlite3enc.h` (all `sqlite3_*` from Dynamics on iOS) | tier1 | Paths in secure container; never mix with system libsqlite3 |
| FMDB | FMDB over `sqlite3_open` | Direct `sqlite3enc_*` **or** retain FMDB with full iOS Dynamics SQLite linkage | tier2 | Open-only bridges → SIGSEGV; see `41-secure-storage-sql.md` |
| Secure Core Data | `NSPersistentStoreCoordinator` standard stack | `GDPersistentStoreCoordinator` | tier2 | Requires stack refactor, not pure import swap |
| Secure networking (Foundation) | `URLSession`, `NSURLConnection` | Keep standard APIs; routed post-auth by `GDURLLoadingSystem` | tier1 | Do not replace with invented APIs; verify post-auth initiation |
| Secure networking (direct sockets) | `NWConnection`, `CFSocket`, `NSStream`, `GCDAsyncSocket`, socket wrappers | `GDSocket` (or explicit blocker if safe migration cannot be proven) | tier1 | Host/port/TLS set in `GDSocket` init; `connect()` takes no args |
| Secure networking (background sessions) | `URLSessionConfiguration.background(...)`, background callbacks | Classification only in this tranche (foreground defer vs G12 blocker) | tier1 | Do not implement Background Authorize in Tranche 4 |
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
| SwiftData for sensitive persistence | tier3 | Rewrite to Core Data + Dynamics secure store |
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
- Do not invent replacement APIs that are absent from public docs/internal headers.

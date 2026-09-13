# Steering: Getting Started with iOS Dynamics Migration

## Overview

Migrating an iOS app to BlackBerry Dynamics means wrapping the app's data
and communications in an encrypted secure container managed by the Dynamics
SDK and controlled by UEM policy. The app continues to use familiar iOS
patterns (UIKit, SwiftUI, Core Data, URLSession) but routes sensitive
operations through Dynamics secure APIs.

**This toolkit targets native UIKit/SwiftUI apps.** Flutter hybrids are
detected and treated as out of scope for this release (no official Dynamics
Flutter SDK) — see `12-capability-and-support-model.md` and
`13-unsupported-feature-detection-matrix.md`.

---

## What Changes

### Authorization Lifecycle

Every Dynamics app must authorize with the runtime before accessing secure
APIs. This means:
- `GDiOS.sharedInstance().authorize()` is called in
  `application(_:didFinishLaunchingWithOptions:)`
- The app waits for `GDAppEventAuthorized` (delegate) or
  `GDState.isAuthorized == true` (notification) before accessing data
- All database, file, network, and policy operations are deferred to
  post-authorization

### Secure Storage

- `FileManager.default` → `GDFileManager.default` for encrypted file operations
- `FileHandle` → `GDFileHandle` for encrypted file handle access
- `NSPersistentStoreCoordinator` → `GDPersistentStoreCoordinator` for Core Data
- `sqlite3_open()` → `sqlite3enc_open()` for raw SQLite
- `UserDefaults` for sensitive data → secure file storage (no leftover
  UserDefaults copy; `18-fresh-dynamics-install.md`)

### Secure Networking

- `GDURLLoadingSystem` intercepts `NSURLSession` traffic and routes it
  through the Dynamics infrastructure
- `GDSocket` replaces direct socket connections
- `GDHttpRequest` provides HTTP request capability

### Secure WebView

- `WKWebView+GDNET` category enables secure content loading in WKWebView

### Inter-App Communication

- `GDService`/`GDServiceClient` replace standard `UIActivity` and URL
  scheme sharing for secure inter-container communication

### Data Leakage Prevention

- `UIPasteboard` access is restricted by DLP policy
- `GDNativePasteboardAccess` provides controlled access when needed
- Copy/paste between Dynamics and non-Dynamics apps is policy-controlled

---

## Integration Methods

Choose the method from the dependency topology matrix in
`10-xcode-integration.md` (CocoaPods-only → CocoaPods; SPM-only or mixed
→ SPM; neither → manual).

### Method 1: CocoaPods

Add to your `Podfile`:
```ruby
pod 'BlackBerryDynamics', '~> 15.0'
```

Run `pod install` and open the `.xcworkspace` file.

### Method 2: SPM (Official Package)

When the matrix selects SPM, add the official package:

- URL: https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK
- Version: `15.0.0` (SDK build `15.0.8513.67`) or a later published `15.*` tag
- Products (app target): `BlackBerryDynamics` + `GSEProvider`

In Xcode: File → Add Package Dependencies… → paste the URL above → link
both required products. See `10-xcode-integration.md` for full steps.

### Method 3: Manual Framework Embedding

Add these frameworks to your Xcode project:
- `BlackBerryDynamics.xcframework` — Embed and Sign
- `GSEProvider.xcframework` — Embed and Sign

(SDK 15.0+; do not use the pre-15.0 `BlackBerryCerticom` /
`BlackBerryCerticomSBGSE` pair.)

Configure Header Search Paths and Framework Search Paths accordingly.

---

## Import Syntax Rule

The import syntax depends on the project integration method. **Detect
this early and use the correct style throughout the migration.**

| Integration | ObjC Import Style | Swift Import Style |
|---|---|---|
| CocoaPods (`Podfile` exists) | `@import Module.Submodule;` | `import Module.Submodule` |
| SPM (official package linked) | `@import Module.Submodule;` | `import Module.Submodule` |
| Manual framework (no Podfile/SPM) | `#import <BlackBerryDynamics/GD/Header.h>` | Bridging header with `#import` |

For CocoaPods and SPM projects, **always** use `@import` (ObjC) or `import`
(Swift) module syntax. The `#import <...>` header paths do NOT resolve
when the SDK is linked as a dynamic framework via CocoaPods/SPM.

**NEVER use bare `@import BlackBerryDynamics;` in Objective-C** — always
use the specific submodule. The SDK's modulemap declares all functional
submodules as `explicit`, so the ObjC umbrella import does NOT include
`GDiOS`, `GDiOSDelegate`, `GDAppEvent`, `GDFileManager`, etc.

**Swift**: `import BlackBerryDynamics` (bare) does compile because Swift
transitively resolves all submodules. It is acceptable as a shorthand
when the file uses types from multiple submodules, but **prefer specific
submodule imports** (`import BlackBerryDynamics.Runtime`, etc.) for
consistency with ObjC and to make dependencies explicit.

Common submodule imports:

| Purpose | Swift | ObjC |
|---------|-------|------|
| Authorization | `import BlackBerryDynamics.Runtime` | `@import BlackBerryDynamics.Runtime;` |
| Secure files | `import BlackBerryDynamics.SecureStore.File` | `@import BlackBerryDynamics.SecureStore.File;` |
| Secure Core Data | `import BlackBerryDynamics.SecureStore.CoreData` | `@import BlackBerryDynamics.SecureStore.CoreData;` |
| Secure sockets | `import BlackBerryDynamics.SecureCommunication` | `@import BlackBerryDynamics.SecureCommunication;` |
| Auth tokens | `import BlackBerryDynamics.AuthenticationToken` | `@import BlackBerryDynamics.AuthenticationToken;` |

**ObjC import placement rule**: If a header file (`.h`) declares
conformance to a Dynamics protocol (e.g., `<GDiOSDelegate>`) or
references a Dynamics type in its `@interface`, the `@import` for that
module MUST be in the **header file**, not just the `.m`. The compiler
must see the type/protocol declaration before the `@interface` that uses
it. Placing the import only in `.m` causes: "Declaration of 'X' must be
imported from module 'Y' before it is required".

**Special case — `GD_C` module**: The encrypted SQLite C API (`GD_C.SecureStore.SQLite`)
is defined inside `BlackBerryDynamics.framework`'s modulemap. The compiler
only discovers `GD_C` after loading that modulemap. Any file importing
`GD_C.*` MUST also import a `BlackBerryDynamics.*` module first (e.g.,
`@import BlackBerryDynamics.SecureStore.File;`).

See `10-xcode-integration.md` for the full module import reference table.

---

## Requirements

- **iOS Deployment Target**: >= 17.0 (minimum). If the project already targets
  a higher version, keep the existing target — do NOT lower it.
- **Xcode**: 15 or 16
- **Languages**: Swift 4/4.2/5/6, Objective-C
- **Swift Version Awareness**: Detect the project's `SWIFT_VERSION` build
  setting. Swift 6 projects with strict concurrency may require `@Sendable`
  annotations on SDK callbacks. ObjC-bridged API signatures may differ between
  Swift 5 and 6 — always verify against installed SDK headers.
- **Keychain Sharing**: Must be enabled with group `com.good.gd.data`
- **URL Schemes**: Required for enterprise discovery and authentication delegation

---

## Migration Sequence

The migration follows a strict order:

1. **Analysis** (Prompts 00, 00b) — Understand the app, generate diagrams
2. **Project Setup** (Prompt 01) — Add framework, configure Xcode
3. **Configuration** (Prompt 02) — Info.plist with entitlement info
4. **Authorization** (Prompts 03, 03b) — GDiOS authorization, deferral audit
5. **Secure Storage** (Prompts 04, 04b, 05) — SQLite, Core Data, filesystem
6. **Secure Networking** (Prompt 06) — GDURLLoadingSystem, GDSocket
7. **WebView** (Prompt 07) — WKWebView+GDNET (if applicable)
8. **ICC** (Prompt 08) — AppKinetics (if applicable)
9. **DLP** (Prompt 09) — Pasteboard migration
10. **Report** (Prompt 10) — Generate migration report

Each prompt has prerequisites. Do NOT skip ahead.

Before Prompt 10, review:

- `12-capability-and-support-model.md` — canonical tier/support reference: app complexity tiers (A/B/C), domain support levels (1/2/3), capability matrix, and glossary
- `13-unsupported-feature-detection-matrix.md` — what to flag as unsupported/partial
- `14-api-provenance-and-replacement-catalog.md` — deterministic native-to-Dynamics mapping
- `15-redundant-feature-removal.md` — features superseded by Dynamics
- `18-fresh-dynamics-install.md` — mandate: a Dynamics conversion is always a fresh install; leftover-data transfer is out of scope
- `16-supported-app-tiers.md` — *(redirect stub — merged into 12-capability-and-support-model.md)*
- `81-migration-report-contract.md` — mandatory report quality gates
- `82-tool-analysis-report-schema.md` — optional tool analysis report schema (internal feedback)
- `83-effectiveness-kpis-and-release-gates.md` — ship-readiness KPIs and release gates
- `84-parity-and-runtime-validation-runbook.md` — agent parity + runtime/UEM execution

---

## Key Differences from Android Migration

| Aspect | Android | iOS |
|--------|---------|-----|
| Build system | Gradle + Maven | CocoaPods, SPM, or manual xcframework |
| Configuration | `settings.json` in `assets/` | `Info.plist` keys |
| Authorization | `GDStateListener` on `Application` class | `GDiOSDelegate` on `AppDelegate` or `GDStateChangeNotification` |
| Activity init | `activityInit()` per Activity | Not needed (single AppDelegate) |
| File storage | `GDFileSystem` | `GDFileManager` (subclass of `NSFileManager`) |
| Core Data | N/A | `GDPersistentStoreCoordinator` |
| SQLite | `com.good.gd.database.sqlite` | `sqlite3enc.h` (C API) |
| Networking | `GDHttpClient`, `GDSocket` | `GDURLLoadingSystem`, `GDSocket`, `GDHttpRequest` |
| WebView | `BBWebView` | `WKWebView+GDNET` |
| UI DLP | `GDEditText`, `GDTextView` | `UIPasteboard` policy, `GDNativePasteboardAccess` |
| ICC | `TransferFileService` | `GDService`/`GDServiceClient` (AppKinetics) |
| Clipboard | `com.good.gd.content.ClipboardManager` | `GDNativePasteboardAccess` |

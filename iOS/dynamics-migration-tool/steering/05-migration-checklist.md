# Steering: iOS Migration Checklist

Use this checklist to track migration progress. Each phase maps to a prompt.

---

## Phase 0: Analysis (Prompts 00, 00b)

- [ ] **Pre-flight baseline PASSES** — unsigned simulator build (`CODE_SIGNING_ALLOWED=NO`)
- [ ] Swift version detected (`SWIFT_VERSION` build setting)
- [ ] Deployment target recorded and compatibility assessed (>= 17.0 required)
- [ ] All Swift/ObjC source files read and inventoried
- [ ] All storyboards and xibs scanned for UI components
- [ ] Info.plist strategy detected (physical file vs GENERATE_INFOPLIST_FILE)
- [ ] Info.plist analyzed for existing URL schemes and capabilities
- [ ] Entitlements file analyzed for Keychain groups, App Groups
- [ ] API usage inventory table produced
- [ ] Data sensitivity classification complete
- [ ] Startup flow analysis complete (what runs in `didFinishLaunchingWithOptions`, `viewDidLoad`)
- [ ] Unsupported features flagged (Flutter hybrid, Share Extension / App Extensions, SwiftData, BitCode, CloudKit, App Clips)
- [ ] If Flutter hybrid detected: Tier C + out-of-scope stop — do **not** run Dynamics code-migration prompts with this toolkit version
- [ ] If Share Extension detected: call out + isolate / non-shipping (never Dynamics-authorize the extension); see `17-app-extensions-and-share-extensions.md`
- [ ] Third-party library compatibility assessed
- [ ] Redundant features identified (app-level biometric, encryption, etc.)
- [ ] Mixed dependency boundaries assessed (`Package.swift` + CocoaPods, if present)
- [ ] Secure file I/O call sites mapped to owning targets/modules
- [ ] Prompt 05 execution mode declared (`auto-apply-injection` or `suggest-manual`)
- [ ] Dynamics integration method selected by matrix (CocoaPods-only -> CocoaPods, SPM-only -> SPM, mixed -> SPM)
- [ ] Canonical build entrypoint selected (`.xcworkspace` when Podfile/workspace exists)
- [ ] Entrypoint ambiguity resolved when both `.xcodeproj` and `.xcworkspace` are present
- [ ] No `xcodebuild -project` commands used when workspace exists
- [ ] Architecture diagrams generated (lifecycle, data flow, API call graph)
- [ ] Migration plan produced with applicable/not-applicable phases marked

## Phase 1: Project Setup (Prompt 01)

- [ ] Deployment target >= 17.0 ensured (raised only if below; higher targets preserved)
- [ ] BlackBerryDynamics integrated via selected method (CocoaPods, SPM, or manual)
- [ ] If SPM: official URL `https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK` pinned at `15.0.0` (or later published `15.*`); products `BlackBerryDynamics` + `GSEProvider` linked
- [ ] GSEProvider.xcframework / `GSEProvider` product added (manual embed or SPM product link)
- [ ] Pre-15.0 Certicom frameworks removed (if upgrading an existing Dynamics app)
- [ ] Protect Mobile / SafeBrowsing usage flagged for removal (if present)
- [ ] `GDPKCS7_*` / S/MIME call sites inventoried for OpenSSL 3.x flag + FIPS cipher review (if present)
- [ ] Keychain Sharing enabled with `com.good.gd.data` group
- [ ] Header Search Paths configured (if manual)
- [ ] Framework Search Paths configured (if manual)
- [ ] Redundant dependencies removed
- [ ] CocoaPods/xcodeproj compatibility preflight passed before `pod install`
- [ ] ObjectVersion incompatibility (if detected) auto-remediated and recorded as pre-existing/tooling
- [ ] Build checks executed with unsigned simulator mode only (`CODE_SIGNING_ALLOWED=NO`)
- [ ] Project builds with `xcodebuild`

## Phase 2: Configuration (Prompt 02)

- [ ] Developer provided GDApplicationID (NOT guessed)
- [ ] Developer provided GDApplicationVersion (NOT guessed)
- [ ] `GDApplicationID` added to Info.plist
- [ ] `GDApplicationVersion` added to Info.plist
- [ ] Application setup type recorded (`in-house`, `partner-third-party`, or `blackberry-developed`)
- [ ] URL scheme `com.good.gd.discovery` registered (CRITICAL — always required; `.enterprise` is NOT a substitute)
- [ ] Setup-specific second discovery scheme policy satisfied (`com.good.gd.discovery.enterprise` for in-house/UEM-managed apps; none for partner/third-party apps; `com.good.gd.discovery.good` only for BlackBerry-developed apps)
- [ ] URL scheme `<native-bundle-id>.sc2` registered
- [ ] URL scheme `<native-bundle-id>.sc2.<GDApplicationVersion>` registered
- [ ] URL scheme `<native-bundle-id>.sc3` registered
- [ ] No bare `<native-bundle-id>.sc` scheme registered
- [ ] `NSFaceIDUsageDescription` added with a non-empty Dynamics biometric unlock purpose string
- [ ] `NSCameraUsageDescription` added with a non-empty QR activation purpose string

## Phase 3: Authorization (Prompts 03, 03b)

- [ ] `GDiOS.sharedInstance().authorize()` called in AppDelegate
- [ ] GDiOSDelegate implemented OR GDStateChangeNotification registered
- [ ] If using GDStateChangeNotification without GDiOSDelegate, Info.plist has `BlackBerryDynamics.CheckEventReceiver = false`
- [ ] `handleEvent:` or notification observer handles all event types
- [ ] Two-phase startup: UI shell in `didFinishLaunchingWithOptions`, business logic in onAuthorized
- [ ] SceneDelegate support handled (if app uses scenes)
- [ ] Authorization deferral audit complete for all ViewControllers
- [ ] Authorization deferral audit complete for SwiftUI views
- [ ] Authorization deferral audit complete for Combine pipelines
- [ ] Authorization deferral audit complete for async/await tasks
- [ ] Authorization deferral audit complete for lazy properties
- [ ] Two-phase startup contract enforced (pre-auth UI shell only; no business/data init)
- [ ] Scene event queue implemented and drained post-auth (if app uses scenes)
- [ ] Swift `GDiOSDelegate` callback bridge to MainActor applied (if strict concurrency)
- [ ] Post-auth root install wires coordinator **before** `rootViewController` attach
- [ ] Storyboard/split root coordinators are optional (no IUO force-unwrap in status-bar paths)
- [ ] No secure API access before authorization confirmed

## Phase 4: Secure SQL (Prompt 04, if applicable)

- [ ] All `sqlite3_open()` calls replaced with `sqlite3enc_open()`
- [ ] `#include <sqlite3.h>` replaced with `@import GD_C.SecureStore.SQLite;` (CocoaPods) or `#import <BlackBerryDynamics/GD_C/sqlite3.h>` + `sqlite3enc.h` (manual/SPM)
- [ ] **ABI invariant:** iOS SQL/FMDB module links BlackBerryDynamics and does **not** link system `libsqlite3` for exec/prepare/step
- [ ] FMDB open-only bridges rejected; full-linkage or direct `sqlite3enc` rewrite applied
- [ ] SPM SQL shims are private headers (or umbrella updated in the same change)
- [ ] GRDB wrapper blocked/replaced (if applicable)
- [ ] Database access deferred to post-authorization
- [ ] Phase 7 `check-sql-linkage.py` passes

## Phase 5: Secure Core Data (Prompt 04b, if applicable)

- [ ] `NSPersistentStoreCoordinator` replaced with `GDPersistentStoreCoordinator`
- [ ] Store type changed to `GDEncryptedBinaryStoreType` or `GDEncryptedIncrementalStoreType`
- [ ] `NSPersistentContainer` setup migrated to custom container
- [ ] Lightweight migration verified with encrypted store
- [ ] Core Data stack initialization deferred to post-authorization

## Phase 6: Secure File Storage (Prompt 05, if applicable)

- [ ] Execution strategy selected before edits (direct replacement vs app-level injection)
- [ ] App-level adapter injection auto-applied when mixed-boundary conditions were met
- [ ] Uncertain mixed-boundary cases converted to high-priority manual TODOs
- [ ] `FileManager.default` replaced with `GDFileManager.default` for sensitive ops
- [ ] `FileHandle` replaced with `GDFileHandle`
- [ ] `InputStream` replaced with `GDCReadStream`
- [ ] `OutputStream` replaced with `GDCWriteStream`
- [ ] `UserDefaults` for sensitive data migrated to secure file storage
- [ ] Temp file patterns identified and replaced with in-memory processing
- [ ] No generated use of `GDFileManager.default.temporaryDirectory`
- [ ] Secure temp strategy uses container-backed path (`.cachesDirectory` or `.documentDirectory` + app temp subdirectory)
- [ ] Secure temp runtime probe passed (create/read/delete post-authorization)
- [ ] File operations deferred to post-authorization

## Phase 7: Secure Networking (Prompt 06, if applicable)

- [ ] `GDURLLoadingSystem` enabled for secure NSURLSession
- [ ] Direct socket connections replaced with `GDSocket`
- [ ] Custom HTTP replaced with `GDHttpRequest` (if applicable)
- [ ] Alamofire/other HTTP libraries assessed for compatibility
- [ ] Network operations deferred to post-authorization

## Phase 8: Secure WebView (Prompt 07, if applicable)

- [ ] `WKWebView+GDNET` imported for secure web content
- [ ] Unsupported WKWebView features documented
- [ ] WebView creation deferred to post-authorization

## Phase 9: AppKinetics ICC (Prompt 08, if applicable)

- [ ] `GDService` implemented for service provider role
- [ ] `GDServiceClient` implemented for service consumer role
- [ ] Service definitions registered in Info.plist
- [ ] Standard sharing (`UIActivityViewController`) replaced or wrapped

## Phase 10: DLP / Pasteboard (Prompt 09, if applicable)

- [ ] `UIPasteboard.general` usage reviewed for DLP compliance
- [ ] `GDNativePasteboardAccess` used where native pasteboard needed
- [ ] Canonical ObjC bridge shim used for Swift interop friction (if needed)
- [ ] Screen capture policy documented (UEM-controlled)
- [ ] Copy/paste between Dynamics and non-Dynamics apps policy-aware

## Phase 11: Migration Report (Prompt 10)

- [ ] `migration-report.json` generated in `dynamics-migration-tool/output/`
- [ ] Schema version is `2.0.0`
- [ ] All coverage areas assessed
- [ ] Unsupported features listed (SwiftData, App Extensions, etc.)
- [ ] Manual TODOs documented
- [ ] Runtime test plan generated
- [ ] UEM admin handoff section complete
- [ ] `Dynamics_Migration_Readme.md` generated at project root

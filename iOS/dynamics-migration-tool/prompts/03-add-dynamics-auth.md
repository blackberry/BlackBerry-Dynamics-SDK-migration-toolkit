## Task: Add BlackBerry Dynamics Authorization

Goal: Set up the Dynamics authorization infrastructure — `GDiOS`
initialization, delegate or notification pattern, and two-phase startup
restructuring.

**Prerequisites**:
- Prompt 01 (xcode-integration) must be complete — SDK framework is added
- Prompt 02 (configure-info-plist) must be complete — Info.plist has
  developer-provided GDApplicationID and GDApplicationVersion

**Key concept**: Dynamics wraps the app's data in an encrypted secure
container. On first launch the SDK handles activation (provisioning with
UEM) — the app has no control over this flow. On subsequent launches the
SDK prompts the user to unlock the container (password/biometric). The
app's own business logic (database access, file I/O, networking, policy
reads) cannot run until the container is unlocked and authorization fires.
This means the app must split its startup into two phases:
Phase 1 (didFinishLaunchingWithOptions) = UI shell only,
Phase 2 (onAuthorized) = real app logic.

**Flutter gate (this toolkit release):** If `migration-analysis.json`
`unsupportedDetections` includes Flutter (or bootstrap
`lifecycleCandidates` has `type: Flutter-hybrid`), **STOP**. Do not add
Dynamics authorization, FlutterEngine wiring, SceneDelegate changes, or
plugin registrant gating for Flutter apps. There is no official Dynamics
Flutter SDK; this kit version documents Flutter as out of scope only.
Escalate to the developer with Tier C / `no-go` guidance from
`steering/12-capability-and-support-model.md`.

---

## Steps

### 1. Choose Authorization Pattern

Determine which pattern suits the app:

- **Delegate pattern** (`GDiOSDelegate`): Traditional approach. Best for
  UIKit apps with a standard `AppDelegate`.
- **Notification pattern** (`GDStateChangeNotification`): Best for SwiftUI
  apps using `@main App` protocol, or when multiple components need to
  observe auth state.

If using notification pattern, add a `BlackBerryDynamics` dictionary to
Info.plist at the **top level** (not nested inside another key) with
`CheckEventReceiver` set to `false`:
```xml
<!-- [BB_DYNAMICS-MIGRATION] Disable GDiOSDelegate receiver check for notification pattern -->
<key>BlackBerryDynamics</key>
<dict>
    <key>CheckEventReceiver</key>
    <false/>
</dict>
```

### 2. Set Up Authorization in AppDelegate

#### Delegate Pattern (Swift)

```swift
// [BB_DYNAMICS-MIGRATION] Added GDiOS authorization with delegate pattern
import BlackBerryDynamics.Runtime

@main
class AppDelegate: UIResponder, UIApplicationDelegate, GDiOSDelegate {
    var window: UIWindow?
    static var isAuthorized = false
    private var didStartPostAuthorizationServices = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        GDiOS.sharedInstance().delegate = self
        GDiOS.sharedInstance().authorize()
        return true
    }

    func handle(_ anEvent: GDAppEvent) {
        switch anEvent.type {
        case .authorized:
            onAuthorized(event: anEvent)
        case .notAuthorized:
            onNotAuthorized(event: anEvent)
        case .remoteSettingsUpdate, .policyUpdate,
             .servicesUpdate, .entitlementsUpdate:
            break
        @unknown default:
            break
        }
    }

    private func onAuthorized(event: GDAppEvent) {
        // Idle unlock re-sends authorized — do not re-run Phase 2.
        AppDelegate.isAuthorized = true
        if didStartPostAuthorizationServices {
            return // resume-only path if needed
        }
        didStartPostAuthorizationServices = true
        // Phase 2 one-shot: install real UI, start AccountManager/DB/etc.
    }

    private func onNotAuthorized(event: GDAppEvent) {
        AppDelegate.isAuthorized = false
        // Never clear didStartPostAuthorizationServices on idle lock.
    }
}
```

#### Notification Pattern (Swift)

```swift
// [BB_DYNAMICS-MIGRATION] Added GDiOS authorization with notification pattern
import BlackBerryDynamics.Runtime

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    static var isAuthorized = false
    private var didStartPostAuthorizationServices = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stateChanged(_:)),
            name: .GDStateChange,
            object: nil
        )
        GDiOS.sharedInstance().authorize()
        return true
    }

    @objc private func stateChanged(_ notification: Notification) {
        guard let state = notification.userInfo?[GDStateChangeKeyCopy] as? GDState else { return }
        if state.isAuthorized {
            AppDelegate.isAuthorized = true
            if didStartPostAuthorizationServices { return }
            didStartPostAuthorizationServices = true
            // Phase 2 one-shot: safe to access secure APIs
        } else {
            AppDelegate.isAuthorized = false
        }
    }
}
```

### 3. Handle SwiftUI @main App (if applicable)

If the app uses a SwiftUI `@main App` entrypoint, do **not** gate the app
body on a static flag (for example `if AppDelegate.isAuthorized { ... }`).
That pattern can render a permanent blank screen because SwiftUI does not
observe static vars.

Use a scene-driven bridge and install the real SwiftUI root **after**
`GDAppEventAuthorized`:

```swift
// [BB_DYNAMICS-MIGRATION] SwiftUI app — SceneDelegate installs root post-auth
import BlackBerryDynamics.Runtime
import SwiftUI

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Placeholder scene shell only. Real root is installed in SceneDelegate.onAuthorized.
        WindowGroup { EmptyView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    // REQUIRED: SDK-managed window handoff uses this setter.
    var window: UIWindow?
    static var isAuthorized = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate, GDiOSDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // Reuse SDK-managed window when available; do not construct a second UIWindow.
        self.window = windowScene.keyWindow
        GDiOS.sharedInstance().delegate = self
        GDiOS.sharedInstance().authorize()
    }

    // Swift 6 strict-concurrency safe pattern.
    nonisolated func handle(_ anEvent: GDAppEvent) {
        switch anEvent.type {
        case .authorized:
            Task { @MainActor in self.onAuthorized() }
        default:
            break
        }
    }

    @MainActor
    private func onAuthorized() {
        guard !AppDelegate.isAuthorized else { return }
        AppDelegate.isAuthorized = true
        let root = UIHostingController(rootView: ContentView())
        window?.rootViewController = root
        window?.makeKeyAndVisible()
    }
}
```

**Key requirements**:
- Keep `var window: UIWindow?` on delegate types that receive SDK window handoff.
- Do not create a second `UIWindow(windowScene:)` in `scene(_:willConnectTo:)`.
- Do not use static auth flags directly inside the SwiftUI `App` body.

### 3a. Handle SceneDelegate (if applicable)

If the app already uses `UISceneDelegate`:
- Keep authorization setup in the scene lifecycle path.
- Reuse `windowScene.keyWindow` (SDK-managed window) when possible.
- Queue external scene actions (`openURLContexts`, `continue userActivity`) and
  process them only after authorization.
- Install the business root controller in `onAuthorized()` only.

### 4. Handle UIMainStoryboardFile Removal

If the app uses a main storyboard (`UIMainStoryboardFile` in Info.plist),
it loads the root ViewController before authorization completes, breaking
two-phase startup. Remove or nullify `UIMainStoryboardFile` and set up
the UI programmatically in `onAuthorized`:

- Remove `<key>UIMainStoryboardFile</key>` and its `<string>` from Info.plist
- In `onAuthorized`, set the rootViewController on the **existing**
  `self.window?` — do NOT create a new `UIWindow`. The Dynamics SDK
  manages the window during activation/unlock. Creating a new window
  replaces the SDK-managed window and causes `EXC_BAD_ACCESS` crashes
  (especially on iOS 16+ where `UIScreen.main` is deprecated).

  **Note**: Removing `UIMainStoryboardFile` does NOT delete the `.storyboard`
  file — the storyboard resource stays in the bundle. You can still
  load it programmatically. The key only controls automatic pre-launch
  loading by UIKit:
  ```swift
  // CORRECT — reuse SDK-managed window; load storyboard manually post-auth
  self.window?.rootViewController = UIStoryboard(name: "Main", bundle: nil)
      .instantiateInitialViewController()

  // WRONG — never do this in onAuthorized
  // window = UIWindow(frame: UIScreen.main.bounds)
  ```
  If `UIStoryboard(name:bundle:).instantiateInitialViewController()` returns
  nil, the storyboard has no "Is Initial View Controller" set — fall back
  to instantiating a specific VC by storyboard identifier.

- For ObjC, use `[[GDiOS sharedInstance] getWindow]` to obtain the
  SDK-managed window explicitly; `self.window` on UIApplicationDelegate
  is equivalent in Swift

### 5. Restructure Main Startup (Two-Phase Initialization)

**HARD GATE**: Pre-auth lifecycle must run UI shell only.

- Before `GDAppEventAuthorized` / `GDState.isAuthorized`, app code must NOT
  initialize account/session managers, database stacks, secure repositories,
  network clients, or business coordinators.
- Any pre-auth path that touches those components is a migration defect and
  must be deferred before continuing.

- Find ALL code in `didFinishLaunchingWithOptions` or the root
  ViewController's `viewDidLoad` that accesses: databases, files,
  network, or policy
- Move that code into first-time Phase 2 `onAuthorized()` (one-shot)
- Set up a placeholder/splash UI for Phase 1 — **do not** load the full
  storyboard graph (split view / feeds / timeline) until authorize
- Keep `isAuthorized` for runtime gates, and a separate
  `didStartPostAuthorizationServices` one-shot flag that is **never**
  cleared on idle lock (only wipe/full reset). On re-auth: set
  `isAuthorized = true` and resume; do not call `AccountManager.start()`
  again unless it is idempotent
- Storyboard root VCs: make coordinator IUOs optional — Dynamics Launcher
  may probe the RVC (`prefersStatusBarHidden`) before your coordinator exists

**Also dismantle type-load-time persistence singletons**:
- Look for `static let` persistence containers/databases initialized at declaration time
  (`ModelContainer`, `NSPersistentContainer`, sqlite handles, `AccountManager.shared`
  reached from storyboard property initializers, etc.).
- These often execute before authorization (type load / first access), which is a
  migration defect even when `didFinishLaunching` is clean.
- Rewrite to a set-once optional initialized from `onAuthorized()`, with a fail-loud
  getter if accessed pre-auth.
- Do not hide this with lazy globals that are first touched from pre-auth scene callbacks.
- Replace `try!` on `GDFileManager` / container paths with soft create + error logging.

### 5a. Scene Event Queue + Authorization Gate (if SceneDelegate exists)

If the app uses scenes, treat scene callbacks as pre-auth by default.
Queue scene-driven actions until authorization completes, then drain queue
from `onAuthorized`:

```swift
// [BB_DYNAMICS-MIGRATION] Scene actions queued until Dynamics authorization
enum PendingSceneAction {
    case openURL(URL)
    case continueActivity(NSUserActivity)
}

final class SceneActionGate {
    static var pending: [PendingSceneAction] = []

    static func enqueue(_ action: PendingSceneAction) {
        pending.append(action)
    }

    static func drainIfAuthorized(_ handler: (PendingSceneAction) -> Void) {
        guard AppDelegate.isAuthorized else { return }
        let actions = pending
        pending.removeAll()
        actions.forEach(handler)
    }
}
```

Use this in `SceneDelegate` callbacks (`willConnectTo`, `openURLContexts`,
state restoration/external actions) so no controller/data path initializes
before auth.

### 6. Handle Objective-C AppDelegate (if applicable)

For Objective-C apps, two patterns are available:

**Pattern A (Inline)**: AppDelegate directly implements `GDiOSDelegate`
and `handleEvent:`.

**Pattern B (Separate Singleton — recommended for larger apps)**:
Create a separate `AppGDiOSDelegate` singleton class that implements
`GDiOSDelegate`. This decouples authorization handling from the app
delegate and allows other components (e.g., root ViewController) to
observe authorization state.

**CRITICAL — ObjC Import Placement**: The `@import BlackBerryDynamics.Runtime;`
(CocoaPods) or `#import <BlackBerryDynamics/GD/GDiOS.h>` (manual) MUST
be in the **header** (`.h`) file where `<GDiOSDelegate>` conformance is
declared — NOT only in the `.m` file. The compiler must see the protocol
declaration before the `@interface` that references it. Placing the import
only in the `.m` causes: "Declaration of 'GDiOSDelegate' must be imported
from module 'BlackBerryDynamics.Runtime' before it is required".

See `10-xcode-integration.md` for the full import reference table.

Use `[[GDiOS sharedInstance] getWindow]` instead of manually creating
`UIWindow` — this returns the SDK-managed window that integrates with
the Dynamics lock/activation UI.

See `20-auth-initialization.md` for both ObjC patterns and `getWindow`
examples.

### 7. Build and Verify

Run `xcodebuild` to verify the project compiles with authorization added.

If the build fails, classify each error against the developer's pre-migration clean-build attestation:
- **Pre-existing**: already present before migration
- **Step-introduced**: caused by changes in this prompt — fix before proceeding
- **Unrelated**: environment or transient issue

### 8. Post-Change Startup Safety Checks (Mandatory)

Before marking this prompt complete, verify each of the following. If any
check fails, fix it before proceeding to Prompt 03b.

**Check 1 — Window exists before rootViewController is set**
```swift
// PASS: safe
self.window?.rootViewController = mainVC

// FAIL: window may be nil — SDK creates it, not the app
guard let w = self.window else {
    // SDK window not ready — symptom: blank screen or EXC_BAD_ACCESS
    return
}
w.rootViewController = mainVC
```

**Check 2 — Placeholder/loading UI shown in Phase 1**
Confirm `didFinishLaunchingWithOptions` / scene connect sets only a
non-sensitive placeholder (plain `UIViewController()` or splash). Without
it the app shows a black screen during SDK activation/unlock. Do **not**
instantiate the full storyboard root graph (split/timeline/feeds) pre-auth —
Dynamics Launcher may attach early and crash on nil IUO coordinators.

**Check 3 — No secure API access in Phase 1**
After refactoring, run a quick scan for any remaining secure API usage
outside of `onAuthorized` / `stateChanged`:
```
rg "GDFileManager|sqlite3enc|GDURLLoadingSystem|GDPersistentStoreCoordinator" \
  --include="*.swift" --include="*.m" \
  -l
```
For each file found, confirm those usages are inside a post-auth guard.

**Check 4 — SceneDelegate scene setup deferred (if applicable)**
If the app uses `UISceneDelegate`, confirm `scene(_:willConnectTo:options:)`
does NOT set the rootViewController from storyboard or data. It should only
install placeholder UI; real UI is set in the auth callback.

**Check 5 — Swift 6 strict-concurrency bridge is correct (mandatory when applicable)**
If the target uses `SWIFT_VERSION = 6.0` (or strict concurrency mode), the
`GDiOSDelegate` callback must use:
- `nonisolated func handle(_ anEvent: GDAppEvent)`
- `Task { @MainActor in ... }` trampoline for app-side state/UI work

Do **not** use `@preconcurrency` on the conformance as a workaround; it
silences compile-time diagnostics but does not guarantee callback isolation.
The migration-safe pattern is `nonisolated` + explicit MainActor hop.

**Check 6 — Idle unlock is one-shot / idempotent**
Confirm Phase 2 bootstrap uses a flag separate from `isAuthorized` (e.g.
`didStartPostAuthorizationServices`) that is **not** cleared on idle
`notAuthorized`. Re-auth must set `isAuthorized = true` and resume only.
Service `start()` methods must not assert when already active.

**Check 7 — Wire coordinator / dependencies BEFORE attaching root (mandatory)**
When post-auth UI install creates a storyboard/split root that owns a
coordinator (or similar dependency), **wire it before** assigning
`window.rootViewController` / scene window root. Dynamics Launcher and
UIKit may immediately probe `prefersStatusBarHidden` /
`preferredStatusBarStyle` on attach; an IUO coordinator still nil will abort
(`_swift_runtime_on_report`) right after activation unlock.

```swift
// PASS: wire, then attach
let root = storyboard.instantiateInitialViewController() as! RootSplitViewController
let coordinator = SceneCoordinator(splitViewController: root)
root.coordinator = coordinator          // wire first
root.loadViewIfNeeded()                 // optional: resolve columns safely
window?.rootViewController = root       // attach only after wire

// FAIL: attach before wire — Launcher probes status bar → nil IUO crash
// window?.rootViewController = root
// root.coordinator = SceneCoordinator(...)
```

Also make root VC coordinator properties **optional** (not `Type!`) with
no-op status-bar paths when nil until post-auth install completes.

**Check 8 — Status-bar / RVC IUOs are optional**
Scan storyboard roots / split roots:

```
rg "prefersStatusBarHidden|preferredStatusBarStyle|coordinator!" \
  --include="*.swift" -n
```

Any `coordinator!` (or equivalent) inside those overrides is a fail — use
`coordinator?` / optional chaining.

**Rollback instruction**: If the app crashes immediately after authorization
changes (blank screen, `EXC_BAD_ACCESS`, Swift runtime abort on status bar,
or SDK lock screen stuck):
1. Revert only the window/rootViewController assignment in `onAuthorized`
2. Verify `self.window?` is not nil at the point of assignment (use `guard`)
3. Check that `UIMainStoryboardFile` was removed from Info.plist if present
4. If using SceneDelegate, ensure `window` is bridged from scene to appDelegate
5. If crash is on idle unlock, check whether Phase 2 re-ran `start()` on an
   already-active manager
6. If crash is immediately after first activate during post-auth root install,
   verify wire-before-attach and optional coordinators (Check 7 / 8)

---

## What This Prompt Does NOT Cover

The full authorization deferral audit (ViewControllers, SwiftUI views,
Combine pipelines, async/await tasks, lazy properties, singletons) is
handled by **Prompt 03b (authorization-deferral-audit)**. This prompt
focuses on the AppDelegate/SceneDelegate authorization setup and the
main startup restructuring only.

---

## Closure Ledger Update (Required)

Before recording Prompt 03 as `completed`, write call-site dispositions for
the `authorization` domain using the atomic updater (never edit
`output/migration-plan-state.json` directly):

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "03" \
  --domain-id "authorization" \
  --updates-file /tmp/auth-updates.json
```

`/tmp/auth-updates.json` must be a JSON array of objects:
- `callSiteId` (from `migration-analysis.json`)
- `status` in: `migrated`, `removed`, `blocked`, `deferred`, `notApplicable`
- `evidence` object with executable verification evidence
- `rationale` required for `blocked`, `deferred`, `notApplicable`

Missing dispositions block recorder completion.

## Scoped Validation and Recorder Gate (Required)

After code changes and ledger updates, run prompt-scoped validation for prompt
`03` and confirm the authorization integration + lifecycle phases pass:

```bash
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt 03
```

The run must include:
- `4-authorization-integration`
- `4-lifecycle-window-root-ui`

Only after validation passes, record completion:

```bash
bash ./dynamics-migration-tool/tooling/record-prompt-execution.sh \
  --prompt-id 03 \
  --status completed
```

Recorder completion will fail if scoped proof is stale, lifecycle gates fail,
or authorization call-site ownership/dispositions are incomplete.

---

## Common Pitfalls (Prompt 03)

- SwiftUI `@main` body gated by static flag (`if AppDelegate.isAuthorized`) — can
  freeze on blank screen forever.
- New `UIWindow(windowScene:)` created after SDK startup — can conflict with the
  SDK-managed window and break launcher/activation interactions.
- `GDiOSDelegate` callback copied from Swift 5 samples into Swift 6 targets without
  `nonisolated` + MainActor trampoline.
- Persistence singleton initialized at type load (`static let`) before authorization.

---

## Output

- AppDelegate with GDiOS authorization (delegate or notification pattern)
- SceneDelegate updated (if applicable)
- Main startup restructured (two-phase)
- Scene event queue + post-auth drain pattern applied (if scenes exist)
- Swift delegate MainActor bridge applied (if strict concurrency app)
- Build verification result
- How to test authorization (first activation + subsequent unlock)

See `20-auth-initialization.md` and `21-authorization-deferral-patterns.md`
for the full steering references.

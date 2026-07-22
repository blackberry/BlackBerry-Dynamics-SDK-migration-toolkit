# Steering: Authorization and Initialization (iOS)

Authorization is the most critical part of the migration. Every Dynamics
app must authorize with the runtime before accessing any secure API.
Getting this wrong causes crashes, data loss, or silent failures.

---

## The Container Lifecycle

1. **First launch**: SDK handles activation (provisioning with UEM).
   The app has no control over this flow — the SDK presents its own UI.
2. **Subsequent launches**: SDK prompts the user to unlock the container
   (password or biometric, controlled by UEM policy).
3. **Authorization event**: Once unlocked, the SDK fires
   `GDAppEventAuthorized` (delegate) or sets `GDState.isAuthorized = true`
   (notification). Only AFTER this event can the app access secure APIs.
4. **Lock/Wipe events**: The SDK may lock or wipe the container based on
   policy. The app must handle these events gracefully.

---

## How the SDK Bootstraps Itself (Auto-Swizzling)

The Dynamics SDK uses Objective-C runtime method swizzling to bootstrap
itself **before any app code runs**:

1. In `+[GDiOS load]` (before `main()`), the SDK swizzles
   `UIApplication.setDelegate:` to intercept the app delegate assignment.
2. When the OS calls `setDelegate:`, the SDK captures the delegate,
   initializes its runtime, and swizzles ~20 `UIApplicationDelegate`
   lifecycle methods (`applicationDidBecomeActive:`,
   `applicationDidEnterBackground:`, `application:didFinishLaunchingWithOptions:`,
   etc.) onto the app's delegate class.
3. For methods the app implements: the SDK swaps its own version in and
   calls the app's version from within. For methods the app does NOT
   implement: the SDK injects its implementation directly.
4. On authorization, the SDK auto-enables secure networking (see
   `30-secure-networking.md`).

This means the SDK integrates into the app lifecycle **purely by linking
the framework** — no manual lifecycle hook-up is needed beyond calling
`authorize()`.

---

## Pattern 1: Delegate-Based Authorization (GDiOSDelegate)

This is the traditional pattern. The AppDelegate implements `GDiOSDelegate`
and receives events via `handleEvent:`.

### Swift

```swift
import UIKit
import BlackBerryDynamics.Runtime

@main
class AppDelegate: UIResponder, UIApplicationDelegate, GDiOSDelegate {

    var window: UIWindow?
    private var didStartPostAuthorizationServices = false
    static var isAuthorized = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // [BB_DYNAMICS-MIGRATION] Initialize Dynamics authorization
        GDiOS.sharedInstance().delegate = self
        GDiOS.sharedInstance().authorize()
        return true
    }

    // MARK: - GDiOSDelegate

    func handle(_ anEvent: GDAppEvent) {
        switch anEvent.type {
        case .authorized:
            onAuthorized(event: anEvent)
        case .notAuthorized:
            onNotAuthorized(event: anEvent)
        case .remoteSettingsUpdate:
            break // handle remote settings update
        case .policyUpdate:
            break // handle policy update
        case .servicesUpdate:
            break // handle services update
        case .entitlementsUpdate:
            break // handle entitlements update
        @unknown default:
            break
        }
    }

    private func onAuthorized(event: GDAppEvent) {
        // Idle lock/unlock re-sends authorized without destroying services.
        AppDelegate.isAuthorized = true
        if didStartPostAuthorizationServices {
            // [BB_DYNAMICS-MIGRATION] Re-auth after idle lock — resume only
            resumeAfterUnlock()
            return
        }
        didStartPostAuthorizationServices = true

        // [BB_DYNAMICS-MIGRATION] Phase 2 one-shot bootstrap — safe to
        // access secure APIs (database, files, network, policy). Never clear
        // didStartPostAuthorizationServices on idle lock.
        setupMainUI()
        loadData()
    }

    private func onNotAuthorized(event: GDAppEvent) {
        AppDelegate.isAuthorized = false
        // Do NOT clear didStartPostAuthorizationServices here — idle lock
        // must not re-run Phase 2 on the next authorized event.
        switch event.code {
        case .errorActivationFailed:
            print("Activation failed")
        case .errorProvisioningFailed:
            print("Provisioning failed")
        case .errorPushConnectionTimeout:
            print("Push connection timeout")
        case .errorIdleLockout:
            // Container locked — secure APIs unavailable until re-auth
            break
        case .errorRemoteLockout:
            break
        case .errorWiped:
            // Container wiped — all data gone; may need full restart
            didStartPostAuthorizationServices = false
            break
        case .errorBlocked:
            break
        @unknown default:
            break
        }
    }

    private func resumeAfterUnlock() {
        // Re-enable UI / observers that pause on lock. Do not call start()
        // again on singletons that assert when already active.
    }

    private func setupMainUI() {
        // Set up the main window and root view controller
    }

    private func loadData() {
        // Load data from secure storage, network, etc.
    }
}
```

### Objective-C Import Placement Rule

**CRITICAL**: In Objective-C, if a header file (`.h`) declares conformance
to a protocol (e.g., `<GDiOSDelegate>`), the module that defines that
protocol MUST be imported **in the header file**, not just the `.m` file.
Placing `@import BlackBerryDynamics.Runtime;` only in the `.m` produces:
"Declaration of 'GDiOSDelegate' must be imported from module
'BlackBerryDynamics.Runtime' before it is required".

Rule: **Any `.h` file that references a Dynamics type or protocol in its
`@interface` declaration must import the corresponding module.**

### Objective-C (Inline Delegate)

```objc
// AppDelegate.h
#import <UIKit/UIKit.h>
@import BlackBerryDynamics.Runtime; // MUST be in .h — protocol GDiOSDelegate is referenced below
// For manual framework integration use: #import <BlackBerryDynamics/GD/GDiOS.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate, GDiOSDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

// AppDelegate.m
#import "AppDelegate.h"

@implementation AppDelegate {
    BOOL _started;
}

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [GDiOS sharedInstance].delegate = self;
    [[GDiOS sharedInstance] authorize];
    return YES;
}

- (void)handleEvent:(GDAppEvent *)anEvent {
    switch (anEvent.type) {
        case GDAppEventAuthorized:
            [self onAuthorized:anEvent];
            break;
        case GDAppEventNotAuthorized:
            [self onNotAuthorized:anEvent];
            break;
        case GDAppEventRemoteSettingsUpdate:
        case GDAppEventPolicyUpdate:
        case GDAppEventServicesUpdate:
        case GDAppEventEntitlementsUpdate:
            break;
    }
}

- (void)onAuthorized:(GDAppEvent *)event {
    if (_started) return;
    _started = YES;
    [self setupMainUI];
    [self loadData];
}

- (void)onNotAuthorized:(GDAppEvent *)event {
    switch (event.code) {
        case GDErrorActivationFailed:
        case GDErrorProvisioningFailed:
        case GDErrorPushConnectionTimeout:
        case GDErrorIdleLockout:
        case GDErrorRemoteLockout:
        case GDErrorWiped:
        case GDErrorBlocked:
            break;
    }
}

@end
```

### Objective-C (Separate Delegate Singleton — Recommended for Larger Apps)

For larger ObjC apps, a best practice is to implement `GDiOSDelegate` as
a separate singleton class rather than on AppDelegate. This keeps the
authorization logic decoupled from the app delegate and allows multiple
components (e.g., AppDelegate, root ViewController) to be notified of
authorization state:

```objc
// [BB_DYNAMICS-MIGRATION] Separate GDiOSDelegate singleton for authorization handling
// AppGDiOSDelegate.h
#import <Foundation/Foundation.h>
@import BlackBerryDynamics.Runtime; // MUST be in .h — protocol GDiOSDelegate is referenced below
// For manual framework integration use: #import <BlackBerryDynamics/GD/GDiOS.h>

@interface AppGDiOSDelegate : NSObject <GDiOSDelegate>
@property (assign, nonatomic, readonly) BOOL hasAuthorized;
+ (instancetype)sharedInstance;
@end

// AppGDiOSDelegate.m
#import "AppGDiOSDelegate.h"

@implementation AppGDiOSDelegate

+ (instancetype)sharedInstance {
    static AppGDiOSDelegate *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AppGDiOSDelegate alloc] init];
    });
    return instance;
}

- (void)handleEvent:(GDAppEvent *)anEvent {
    switch (anEvent.type) {
        case GDAppEventAuthorized:
            _hasAuthorized = YES;
            // Post a custom notification or call back into AppDelegate
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"GDAppAuthorized" object:nil];
            break;
        case GDAppEventNotAuthorized:
            // Handle error codes
            break;
        default:
            break;
    }
}

@end
```

Then in AppDelegate:

```objc
// AppDelegate.m
#import "AppGDiOSDelegate.h"

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // [BB_DYNAMICS-MIGRATION] Delegate authorization to singleton handler
    [GDiOS sharedInstance].delegate = [AppGDiOSDelegate sharedInstance];
    [[GDiOS sharedInstance] authorize];
    return YES;
}
```

---

## Window Setup with GDiOS.getWindow (Objective-C)

In Objective-C Dynamics apps, use `[[GDiOS sharedInstance] getWindow]`
to obtain the app window instead of creating one manually. This returns
the SDK-managed window that properly integrates with the Dynamics UI
(lock screen, activation screen, etc.):

```objc
- (void)onAuthorized {
    // [BB_DYNAMICS-MIGRATION] Use GDiOS.getWindow for the SDK-managed window
    self.window = [[GDiOS sharedInstance] getWindow];
    self.window.rootViewController = [[RootViewController alloc] init];
    [self.window makeKeyAndVisible];
}
```

In Swift, the SDK intercepts `self.window` through its UIApplicationDelegate
swizzling — **do not create a new UIWindow**. After authorization, simply
set the `rootViewController` on the existing `self.window?`:

```swift
// Swift — post-authorization window setup
self.window?.rootViewController = UIStoryboard(name: "Main", bundle: nil)
    .instantiateInitialViewController()
```

---

## Pattern 2: Notification-Based Authorization (GDState)

This pattern uses `NotificationCenter` and KVO on `GDState`. It is useful
when you don't want the AppDelegate to be the sole handler, or when using
SwiftUI's `App` protocol.

**Prerequisite**: Add `BlackBerryDynamics` dictionary to Info.plist with
`CheckEventReceiver = false` (see `11-info-plist-reference.md`).

### Swift

```swift
import UIKit
import BlackBerryDynamics.Runtime

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var started = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // [BB_DYNAMICS-MIGRATION] Register for Dynamics state notifications
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
        guard let state = notification.userInfo?[GDStateChangeKeyCopy] as? GDState else {
            return
        }
        if state.isAuthorized {
            onAuthorized()
        } else {
            onNotAuthorized(state: state)
        }
    }

    private func onAuthorized() {
        guard !started else { return }
        started = true
        // [BB_DYNAMICS-MIGRATION] Phase 2: safe to access secure APIs
        setupMainUI()
        loadData()
    }

    private func onNotAuthorized(state: GDState) {
        // Handle state.reasonNotAuthorized
    }
}
```

---

## SceneDelegate Support

If the app uses `UISceneDelegate` (iOS 13+ scene lifecycle), the
authorization is still initiated in `AppDelegate`. However, scene setup
must be deferred:

```swift
final class SceneDelegate: UIResponder, UIWindowSceneDelegate, GDiOSDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // Reuse SDK-managed window when available; do not construct a second UIWindow.
        window = windowScene.keyWindow
        GDiOS.sharedInstance().delegate = self
        GDiOS.sharedInstance().authorize()
    }

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
        window?.rootViewController = MainViewController()
        window?.makeKeyAndVisible()
    }
}
```

If scene callbacks carry external actions (`openURLContexts`,
`continue userActivity`), queue them pre-auth and replay once in
`onAuthorized()`.

---

## Two-Phase Startup

Every app must split its startup into two phases:

### Canonical Authorization Boundary Contract

Use this single contract across prompt 00, prompt 03, prompt 03b, validator,
and recorder gates:

- **Pre-auth allowed**: placeholder UI shell, observer registration, queueing
  callback metadata without processing sensitive payloads.
- **Pre-auth prohibited**: secure storage/SQL/Core Data initialization, secure
  networking/webview load, policy reads, ICC/DLP sensitive payload handling.
- **Post-auth entry**: first verified authorized event (`GDAppEventAuthorized`
  or `GDState.isAuthorized == true`) triggers business startup.
- **Window strategy**: preserve SDK-managed window (`self.window?` in Swift,
  `[[GDiOS sharedInstance] getWindow]` in ObjC), then install business root UI.
- **Scene strategy**: queue URL/user-activity callbacks until authorization and
  replay exactly once.
- **Failure/lock behavior**: authorization failures and re-lock events must not
  run sensitive startup work.

### Authorization Contract (Hard Rule)

Before authorization completes, allow only:
- placeholder UI shell
- observer registration
- non-secure visual setup

Before authorization completes, do NOT run:
- account/session/domain coordinator init
- database stack init
- secure repository/service bootstrap
- secure networking bootstrap

Treat this as lifecycle architecture migration, not simple API replacement.

### Phase 1: Pre-Authorization (in `didFinishLaunchingWithOptions`)

Safe to do:
- Set up `GDiOS` authorization
- Set up a placeholder/splash UI
- Register notification observers
- Configure non-secure settings

NOT safe to do:
- Access `GDFileManager`, `GDFileHandle`, `GDCReadStream`, `GDCWriteStream`
- Open databases (`sqlite3enc`, `GDPersistentStoreCoordinator`)
- Make network requests (the SDK auto-swizzles networking post-auth, so
  pre-auth requests go through Apple's stack, not Dynamics)
- Read policy or application config
- Access any data in the secure container

### Phase 2: Post-Authorization (in `onAuthorized`)

Safe to do everything — the container is unlocked.

### Removing UIMainStoryboardFile for Programmatic UI Setup

If the original app uses a main storyboard (`UIMainStoryboardFile` in
Info.plist), the storyboard loads the root ViewController **before**
authorization completes. This causes the root ViewController's
`viewDidLoad` to fire pre-auth, which breaks two-phase startup if
that method accesses secure APIs.

**Solution**: Remove or nullify `UIMainStoryboardFile` from Info.plist
and set up the root ViewController programmatically in `onAuthorized`
(first authorize only). Until then, keep only a non-sensitive placeholder
root (empty `UIViewController` / splash). Do **not** instantiate the full
storyboard graph (feeds, timeline, split view, etc.) pre-auth — Dynamics
Launcher may attach to the current RVC and probe `prefersStatusBarHidden`
before your coordinator exists.

```xml
<!-- Remove this from Info.plist -->
<!-- <key>UIMainStoryboardFile</key> -->
<!-- <string>Main</string> -->
```

Then in first-time `onAuthorized` Phase 2:

```swift
private func setupMainUI() {
    // [BB_DYNAMICS-MIGRATION] Removed UIMainStoryboardFile — loading UI
    // programmatically post-authorization for two-phase startup.
    // IMPORTANT: Do NOT create a new UIWindow here. The Dynamics SDK
    // manages the window during activation/unlock. Set the rootViewController
    // on the existing self.window that the SDK already controls.
    self.window?.rootViewController = UIStoryboard(name: "Main", bundle: nil)
        .instantiateInitialViewController()
}
```

**Scene storyboards:** If `UISceneStoryboardFile` loads a complex root
(split view / timeline) pre-auth, replace the scene window's root with a
placeholder in `scene(_:willConnectTo:)` and only instantiate the real
root + coordinator after `GDAppEventAuthorized`. Soft-gating individual
asserts inside timeline VCs is not enough when the whole graph loads early.

**Root VC IUOs:** Any `coordinator!` / implicitly unwrapped outlet on the
storyboard root that Dynamics may touch (`prefersStatusBarHidden`,
`viewDidLoad`) must be optional and no-op when nil until post-auth install.

**Wire before attach:** When installing the real root after
`GDAppEventAuthorized`, assign coordinator / scene dependencies **before**
setting `window.rootViewController`. Attaching first lets Dynamics Launcher
or UIKit probe status-bar properties while the IUO is still nil → Swift
runtime abort on first activate.

Or for ObjC using `GDiOS.getWindow`:

```objc
- (void)onAuthorized:(GDAppEvent *)event {
    if (_started) return;
    _started = YES;

    // [BB_DYNAMICS-MIGRATION] Removed UIMainStoryboardFile — loading UI
    // programmatically post-authorization using GDiOS.getWindow
    self.window = [[GDiOS sharedInstance] getWindow];
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
    self.window.rootViewController = [storyboard instantiateInitialViewController];
    [self.window makeKeyAndVisible];

    [self loadData];
}
```

If the app uses `UISceneDelegate`, the scene configuration in Info.plist
may also reference a storyboard via `UISceneStoryboardFile` — evaluate
whether that also needs deferral.

---

## Common Mistakes

1. **Creating a new UIWindow in `onAuthorized` (Swift)** — **NEVER** call
   `UIWindow(frame: UIScreen.main.bounds)` or `UIWindow(windowScene:)` in
   the post-authorization handler. The Dynamics SDK takes over `self.window`
   during the activation/unlock flow. Creating a new window replaces the
   SDK-managed window and breaks the container lifecycle. On iOS 16+,
   `UIScreen.main` is deprecated and may return a zero rect, causing
   `EXC_BAD_ACCESS`. Instead, set the `rootViewController` on the
   **existing** `self.window?`:
   ```swift
   // CORRECT — reuse the SDK-managed window
   self.window?.rootViewController = UIStoryboard(name: "Main", bundle: nil)
       .instantiateInitialViewController()

   // WRONG — creates new window, crashes on iOS 16+
   // window = UIWindow(frame: UIScreen.main.bounds)
   // window?.rootViewController = ...
   // window?.makeKeyAndVisible()
   ```
   In Objective-C, use `[[GDiOS sharedInstance] getWindow]` which returns
   the SDK-managed window explicitly.
2. **Accessing Core Data in `didFinishLaunchingWithOptions`** — the
   persistent store coordinator must be initialized post-authorization
3. **Loading data in `viewDidLoad` of the root ViewController** — if the
   root VC is set before authorization, `viewDidLoad` fires pre-auth
4. **Initializing network managers as lazy properties** — if the first
   access happens before authorization, the request will fail
5. **Using `@StateObject` or `@ObservedObject` that fetch data on init** —
   SwiftUI view initialization may happen before authorization
6. **Calling `authorize()` more than once** — this is safe but unnecessary;
   the SDK handles re-authorization automatically
7. **Re-running Phase 2 on idle unlock** — Dynamics sends
   `notAuthorized` then `authorized` on idle lock/unlock. Phase 2
   (`AccountManager.start()`, DB open, observer registration, full UI
   install) must be **one-shot**. Keep a `didStartPostAuthorizationServices`
   flag that is **never cleared** on idle lock. On re-auth: set
   `isAuthorized = true` and resume only. Make service `start()` methods
   idempotent (no assert when already active). Only wipe/reset may clear
   the one-shot flag.
8. **`guard !started else { return }` without restoring `isAuthorized`** —
   early-return on re-auth must still mark authorized / resume UI; otherwise
   the app stays logically locked after idle unlock.
9. **Storyboard root with IUO coordinators** — Dynamics Launcher can query
   the current RVC (`prefersStatusBarHidden`, etc.) before your
   `SceneCoordinator` exists. Use optional coordinators + placeholder root
   until first authorize.
10. **Attach root before wiring coordinator** — setting
    `window.rootViewController` and then assigning `root.coordinator`
    races with Launcher/UIKit status-bar probes. Wire first, then attach.

---

## Authorization State Tracking

For reactive patterns, use `GDState` with KVO:

```swift
class AuthManager: ObservableObject {
    @Published var isAuthorized = false

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stateChanged),
            name: .GDStateChange,
            object: nil
        )
    }

    @objc private func stateChanged(_ notification: Notification) {
        guard let state = notification.userInfo?[GDStateChangeKeyCopy] as? GDState else {
            return
        }
        DispatchQueue.main.async {
            self.isAuthorized = state.isAuthorized
        }
    }
}
```

This can be used with SwiftUI:

```swift
@main
struct MyApp: App {
    @StateObject private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            if authManager.isAuthorized {
                ContentView()
            } else {
                SplashView()
            }
        }
    }
}
```

---

## Swift Concurrency Bridge for GDiOSDelegate

In strict concurrency projects, keep delegate callback nonisolated and bridge
to MainActor for app logic:

```swift
@MainActor
final class DynamicsAuthHandler {
    static let shared = DynamicsAuthHandler()
    private var started = false

    func handleAuthorized(_ event: GDAppEvent) {
        guard !started else { return }
        started = true
        // Safe MainActor app startup here
    }
}

final class DynamicsDelegateBridge: NSObject, GDiOSDelegate {
    nonisolated func handle(_ anEvent: GDAppEvent) {
        switch anEvent.type {
        case .authorized:
            Task { @MainActor in
                DynamicsAuthHandler.shared.handleAuthorized(anEvent)
            }
        default:
            break
        }
    }
}
```

This avoids actor-isolation/sendability friction while keeping authorization
event handling deterministic.

Do **not** use `@preconcurrency` on `GDiOSDelegate` conformance as a migration
shortcut. It suppresses diagnostics but does not guarantee callback isolation.
Use explicit `nonisolated` + `Task { @MainActor in ... }`.

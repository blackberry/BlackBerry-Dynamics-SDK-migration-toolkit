# Steering: Authorization Deferral Patterns (iOS)

This steering file covers patterns for deferring secure API access until
after authorization. Every location in the codebase that accesses a
Dynamics secure API must be audited to ensure it only runs after
`GDAppEventAuthorized` or `GDState.isAuthorized == true`.

The scoped validator for prompt `03b` consumes
`output/auth-reachability.json` and classifies each sensitive call site as:
- `definitely-pre-auth` (hard fail)
- `definitely-post-auth`
- `conditionally-gated`
- `unresolved-opaque`

`unresolved-opaque` sensitive startup paths are not silent warnings; they must
be closed with explicit blocker/manual-intervention disposition evidence.

---

## Pattern 1: UIViewController Lifecycle

### Problem

`viewDidLoad()`, `viewWillAppear(_:)`, and `viewDidAppear(_:)` may fire
before authorization if the ViewController is set as the root before auth.

### Solution

Defer data loading to a method that checks authorization state:

```swift
class DataViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Safe: UI setup only (no secure API access)
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // [BB_DYNAMICS-MIGRATION] Deferred data load to post-authorization
        if AppDelegate.isAuthorized {
            loadSecureData()
        }
    }

    func loadSecureData() {
        // Access GDFileManager, Core Data, network, etc.
    }
}
```

Or use the notification pattern:

```swift
override func viewDidLoad() {
    super.viewDidLoad()
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(onAuthorized),
        name: .GDStateChange,
        object: nil
    )
}

@objc private func onAuthorized(_ notification: Notification) {
    guard let state = notification.userInfo?[GDStateChangeKeyCopy] as? GDState,
          state.isAuthorized else { return }
    loadSecureData()
}
```

---

## Pattern 2: Storyboard Segues

### Problem

`prepare(for:sender:)` may pass data from secure storage to the
destination ViewController before auth.

### Solution

If the segue fires from a post-auth context, it is safe. If the root
ViewController's initial segues fire during launch, defer them:

```swift
// [BB_DYNAMICS-MIGRATION] Deferred segue preparation to post-authorization
override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
    guard AppDelegate.isAuthorized else { return }
    if let destVC = segue.destination as? DetailViewController {
        destVC.data = loadFromSecureStorage()
    }
}
```

---

## Pattern 3: Lazy Properties

### Problem

Lazy properties that initialize secure resources are evaluated on first
access. If that access happens before auth, it fails.

```swift
// DANGEROUS: if accessed before authorization
lazy var database: GDPersistentStoreCoordinator = {
    let coordinator = GDPersistentStoreCoordinator(managedObjectModel: model)
    // ... setup
    return coordinator
}()
```

### Solution

Convert to optional properties initialized in the post-auth handler:

```swift
// [BB_DYNAMICS-MIGRATION] Changed from lazy to optional, initialized post-auth
var database: GDPersistentStoreCoordinator?

func onAuthorized() {
    database = GDPersistentStoreCoordinator(managedObjectModel: model)
    // ... setup
}
```

---

## Pattern 4: SwiftUI View Initialization

### Problem

`@StateObject` and `@ObservedObject` initializers run when the view is
first created. If the view is in the hierarchy before authorization, the
init accesses secure APIs too early.

```swift
// DANGEROUS: ViewModel init may access secure storage
struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    var body: some View { ... }
}
```

### Solution A: Conditional View Hierarchy

Only add views that need secure data after authorization:

```swift
@main
struct MyApp: App {
    @StateObject private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            // [BB_DYNAMICS-MIGRATION] ContentView only appears after auth
            if authManager.isAuthorized {
                ContentView()
            } else {
                SplashView()
            }
        }
    }
}
```

### Solution B: Deferred Loading in ViewModel

```swift
class ContentViewModel: ObservableObject {
    @Published var items: [Item] = []

    // [BB_DYNAMICS-MIGRATION] Don't load in init — wait for auth
    func loadIfAuthorized() {
        guard AppDelegate.isAuthorized else { return }
        items = loadFromSecureStorage()
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()

    var body: some View {
        List(viewModel.items) { item in
            Text(item.name)
        }
        .onAppear {
            viewModel.loadIfAuthorized()
        }
    }
}
```

---

## Pattern 5: Combine Pipelines

### Problem

Publishers that trigger on subscription may access secure APIs before auth.

```swift
// DANGEROUS: fires immediately on subscription
let dataPublisher = NotificationCenter.default
    .publisher(for: .dataDidChange)
    .flatMap { _ in loadFromSecureDB() }
```

### Solution

Gate the pipeline on authorization state:

```swift
// [BB_DYNAMICS-MIGRATION] Gated pipeline on authorization state
let dataPublisher = authManager.$isAuthorized
    .filter { $0 }
    .flatMap { _ in loadFromSecureDB() }
```

---

## Pattern 6: Swift Concurrency (async/await)

### Problem

`Task {}` blocks in `viewDidLoad` or view `body` may start before auth:

```swift
// DANGEROUS: Task starts immediately
override func viewDidLoad() {
    super.viewDidLoad()
    Task {
        let data = try await fetchFromSecureNetwork()
        updateUI(with: data)
    }
}
```

### Solution

Guard on authorization state (do not invent suspendable auth-await helpers):

```swift
override func viewDidLoad() {
    super.viewDidLoad()
    // [BB_DYNAMICS-MIGRATION] Deferred async task to post-authorization
    Task {
        guard AppDelegate.isAuthorized else { return }
        let data = try await fetchFromSecureNetwork()
        await MainActor.run { updateUI(with: data) }
    }
}
```

Or only start the task from the post-auth handler:

```swift
func onAuthorized() {
    Task {
        let data = try await fetchFromSecureNetwork()
        await MainActor.run { updateUI(with: data) }
    }
}
```

---

## Pattern 7: Singleton / Shared Instances

### Problem

Singletons that initialize secure resources on first access:

```swift
// DANGEROUS: shared instance initializes database on first access
class DataManager {
    static let shared = DataManager()
    private let db: GDPersistentStoreCoordinator

    private init() {
        db = GDPersistentStoreCoordinator(managedObjectModel: model)
    }
}
```

### Solution

Separate initialization from construction:

```swift
// [BB_DYNAMICS-MIGRATION] Split singleton init from secure resource setup
class DataManager {
    static let shared = DataManager()

    private var db: GDPersistentStoreCoordinator?

    private init() {}

    func initialize() {
        // Call this from onAuthorized()
        db = GDPersistentStoreCoordinator(managedObjectModel: model)
    }
}
```

---

## Pattern 8: UIApplicationDelegate Callbacks

### Problem

Other AppDelegate callbacks may access secure APIs:

- `applicationDidBecomeActive(_:)` — may reload data
- `application(_:performFetchWithCompletionHandler:)` — background fetch
- `application(_:didReceiveRemoteNotification:)` — push handling

### Solution

Guard all data-accessing callbacks:

```swift
func applicationDidBecomeActive(_ application: UIApplication) {
    // [BB_DYNAMICS-MIGRATION] Guard secure API access on authorization
    guard AppDelegate.isAuthorized else { return }
    refreshData()
}
```

---

## Pattern 9: SceneDelegate Event Queue

### Problem

Scene callbacks (`willConnectTo`, `openURLContexts`, restoration callbacks)
may fire before authorization and trigger controller/data paths too early.

### Solution

Queue scene-driven actions pre-auth and drain once authorized:

```swift
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

Use this template when scenes are present to avoid pre-auth controller init
and race-like lifecycle behavior.

---

## Audit Checklist

When running Prompt 03b, systematically check:

- [ ] Every `viewDidLoad` in every UIViewController
- [ ] Every `viewWillAppear` / `viewDidAppear`
- [ ] Every `prepare(for:sender:)`
- [ ] Every `lazy var` that accesses secure APIs
- [ ] Every `@StateObject` / `@ObservedObject` init
- [ ] Every `.onAppear` modifier in SwiftUI
- [ ] Every `Task {}` block
- [ ] Every Combine pipeline subscription
- [ ] Every singleton `shared` instance (including storyboard property-initializer reachability)
- [ ] Every AppDelegate callback beyond `didFinishLaunchingWithOptions`
- [ ] Every `SceneDelegate` callback
- [ ] Scene event queue + post-auth drain pattern (if scenes are present)
- [ ] Placeholder root until authorize (no full storyboard split/timeline graph pre-auth)
- [ ] Root VC coordinator IUOs are optional (Dynamics Launcher may probe RVC early)
- [ ] Idle unlock: Phase 2 one-shot flag never cleared on `notAuthorized`; `start()` idempotent
- [ ] Every background task / fetch handler

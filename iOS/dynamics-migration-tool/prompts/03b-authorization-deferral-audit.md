## Task: Authorization Deferral Audit

Goal: Systematically audit the entire codebase for pre-authorization
secure API access and defer all such access to post-authorization.

**Prerequisites**:
- Prompt 03 (add-dynamics-auth) must be complete — GDiOS authorization
  is set up in AppDelegate

**Key concept**: Any code that accesses `GDFileManager`, `GDFileHandle`,
`GDCReadStream`, `GDCWriteStream`, `GDPersistentStoreCoordinator`,
`sqlite3enc_open`, `GDURLLoadingSystem`, `GDSocket`, `GDHttpRequest`,
or any other secure API MUST run after authorization. This audit traces
every call chain to find violations.

---

## Steps

### 1. Audit UIViewController Lifecycle Methods

For EVERY UIViewController in the project:

- Check `viewDidLoad()` — does it access secure APIs or trigger data loading?
- Check `viewWillAppear(_:)` / `viewDidAppear(_:)` — data refresh calls?
- Check `prepare(for:sender:)` — passing secure data to destination VC?
- Check `init(coder:)` / `init(nibName:bundle:)` — early initialization?

**Fix**: Guard with `AppDelegate.isAuthorized` or defer to notification.

### 2. Audit SwiftUI Views

For EVERY SwiftUI view:

- Check `@StateObject` and `@ObservedObject` initializers — do they
  access secure storage?
- Check `.onAppear` modifiers — do they trigger secure API calls?
- Check `.task` modifiers — do they start async secure operations?
- Check `@Query` (SwiftData — flag as unsupported)

**Fix**: Conditionally show views based on auth state, or defer loading.

### 3. Audit Combine Pipelines

For every Combine publisher chain:

- Check publishers that fire on subscription — do they access secure APIs?
- Check `sink`, `assign`, or `receive(on:)` that trigger secure operations

**Fix**: Gate pipelines on `AppDelegate.isAuthorized` or subscribe to
`Notification.Name("GDStateChangeNotification")` to trigger secure
operations only after the notification fires with authorized state.

### 4. Audit Swift Concurrency (async/await)

For every `Task {}` block:

- Check if it starts in a lifecycle method that runs before auth
- Check if it accesses secure APIs

**Fix**: Start async tasks from `onAuthorized()` / the
`GDStateChangeNotification` handler, or guard the task body with
`guard AppDelegate.isAuthorized else { return }` at the start. Do not
invent a `waitForAuthorization()` function — the SDK uses callbacks, not
a suspendable awaitable.

### 5. Audit Lazy Properties

For every `lazy var`:

- Does it initialize secure resources (Core Data stack, database, etc.)?
- When is it first accessed — before or after authorization?

**Fix**: Convert to optional properties initialized in `onAuthorized()`.

### 6. Audit Singletons

For every `static let shared` / singleton:

- Does `init()` access secure APIs?
- When is `shared` first accessed?

**Fix**: Separate construction from secure initialization.

### 7. Audit AppDelegate Callbacks

Beyond `didFinishLaunchingWithOptions`:

- `applicationDidBecomeActive(_:)` — data refresh?
- `application(_:performFetchWithCompletionHandler:)` — background fetch?
- `application(_:didReceiveRemoteNotification:)` — push handling?
- `application(_:open:options:)` — URL handling with secure data?

**Fix**: Guard all with authorization state check.

### 8. Audit SceneDelegate Callbacks

- `scene(_:willConnectTo:options:)` — scene setup with data?
- `sceneDidBecomeActive(_:)` — data refresh?
- `scene(_:openURLContexts:)` — URL handling?

**Fix**: Guard all with authorization state check, and when actions can
arrive pre-auth, queue them for post-auth drain.

### 8a. Enforce Scene Event Queue Template (Required if scenes exist)

If `SceneDelegate` exists, verify a formal queue + drain pattern:

- pre-auth scene/external actions are enqueued (not executed immediately)
- queue drains only from post-auth path (`onAuthorized` / authorized state callback)
- queue drain is idempotent and clears pending actions

If no queue/gate exists for scene-driven actions, classify as
step-introduced risk and fix before completing this prompt.

---

### 9. Post-Audit Build and Smoke Check (Mandatory)

Run `xcodebuild` to confirm no compile errors from deferral changes, then
verify the following before marking this prompt complete:

**Pre-authorization scan** — confirm no secure API remains in Phase 1:
```
rg "GDFileManager|GDFileHandle|GDCReadStream|GDCWriteStream|sqlite3enc|GDURLLoadingSystem|GDPersistentStoreCoordinator|GDSocket|GDHttpRequest" \
  --include="*.swift" --include="*.m" \
  -n
```
For each match, confirm it is inside a function that is only ever called
from first-time Phase 2 `onAuthorized`, `stateChanged`, or another post-auth
path — not from storyboard property initializers or root `viewDidLoad`.

**Also confirm**:
- Placeholder root until authorize (full storyboard graph deferred)
- Root VC coordinators are optional (Launcher may probe RVC pre-auth)
- Idle unlock: `didStartPostAuthorizationServices` not cleared on lock;
  service `start()` methods are idempotent
- `auth-reachability.json` has `definitelyPreAuthCount == 0` including
  structural hazards (`storyboard-shared-init`, `status-bar-iuo`,
  `try-bang-secure`) — Prompt 03b scoped validate fails otherwise

**Rollback instruction**: If deferral changes cause a build error or crash:
- Check that all `lazy var` conversions to optional properties have their
  call sites updated to use optional chaining (`?.`) or `guard let` unwraps
- Check that any `@StateObject` or `@ObservedObject` whose init was deferred
  has a corresponding conditional `if isAuthorized { ... }` guard at the view
- If a singleton `init()` was changed to lazy — confirm every call site
  handles the case where `shared` is called before authorization (return early
  or assert in debug)

---

## Closure Ledger Update (Required)

Before recording Prompt 03b as `completed`, write call-site dispositions for
the `authorization` domain using the atomic updater (never edit
`output/migration-plan-state.json` directly):

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "03b" \
  --domain-id "authorization" \
  --updates-file /tmp/auth-deferral-updates.json
```

`/tmp/auth-deferral-updates.json` must contain one disposition per analyzed
authorization call site (`callSiteId`, `status`, `evidence`, and required
`rationale` for `blocked|deferred|notApplicable`).

Missing dispositions block recorder completion.

## Scoped Validation and Recorder Gate (Required)

Prompt `03b` must run deterministic pre-auth reachability analysis and residual
closure checks before it can be recorded complete.

Run:

```bash
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt 03b
```

The run must include:
- `4-preauth-reachability`
- `4-residual-authorization-closure`

This generates/refreshes `output/auth-reachability.json` and enforces:
- no definite pre-auth sensitive reachability,
- no unresolved opaque sensitive startup path without blocker/manual rationale,
- current-source fingerprint match (stale proof is rejected).

Then record completion:

```bash
bash ./dynamics-migration-tool/tooling/record-prompt-execution.sh \
  --prompt-id 03b \
  --status completed
```

---

## Output

- Complete list of pre-auth secure API access points found
- Fix applied for each violation
- Verification that no secure API is called before authorization
- List of any patterns that require developer review
- Build verified after changes (xcodebuild passes)

See `21-authorization-deferral-patterns.md` for the full steering reference
with code examples for each pattern.

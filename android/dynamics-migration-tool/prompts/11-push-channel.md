# Task: Migrate FCM and Dynamics Push Channel usage

**Prerequisite:** Prompts `03` and `03b` must be complete. The Application
class exposes `GDStateListener`, `isContainerAuthorized`, and
`runOnAuthorized(Runnable)`.

**Runs before:** `03c-background-authorize.md` (Background Authorize uses
the candidate list already captured by `00pre` in
`bootstrap.json.processModel.backgroundEntryPoints[]`).

## Goal

1. Harden every `FirebaseMessagingService` handler so enterprise work runs
   only when the container is authorized (or after the Background Authorize
   handshake applied in prompt `03c`).
2. Replace ad-hoc UEM/server push integrations with the verified Dynamics
   Push Channel API (`com.good.gd.push.*` — **not** `GDPushChannel*`).

## Module map context (read first)

Load `dynamics-migration-tool/output/module-map.json` and scan every entry
in `${in_scope_main_src}`. If `module-map.json` is missing, STOP and re-run
`00pre-bootstrap.md`.

---

## Steps

### 1. Consume the existing securePush plan row

Read `dynamics-migration-tool/output/migration-analysis.json` and find
the binding `executionPlan[]` row where `domain == "securePush"` and
`promptId == "11"`. Do not modify or extend `migration-analysis.json`
in this prompt; prompt `00` owns that artifact.

Expected prompt-00 classification:

| Kind | Detection | `securePush` applicable |
|------|-----------|-------------------------|
| FCM service | extends `FirebaseMessagingService` | yes |
| `PushChannel` / push-channel broadcasts | `com.good.gd.push` imports or `PushChannel.prepareIntentFilter()` | yes |
| None | — | set domain `not-applicable`; skip remaining steps |

Also read `bootstrap.json` → `processModel.backgroundEntryPoints[]` for
FCM candidates. If source scanning in this prompt finds a
`FirebaseMessagingService` that is missing from
`backgroundEntryPoints[]`, STOP and instruct the developer to re-run
`00pre-bootstrap.md` and then prompt `00`; a newly discovered service here
will not automatically be seen by prompt `03c`.

### 2. FCM payload hardening (every FCM service)

For each `FirebaseMessagingService` subclass:

- Remove sensitive fields from FCM `notification` title/body and from
  cleartext `data` keys visible to the OS push layer.
- Restrict `onMessageReceived` to a **metadata-only wake** (opaque sync
  token / correlation ID).
- Add an early guard:

```kotlin
if (!MyDynamicsApplication.isContainerAuthorized) {
    return
}
```

(or the Java equivalent from `DynamicsApplicationBase`).

Do **not** access `GDFileSystem`, secure SQLite, `GDHttpClient`, or
`getApplicationPolicy()` inside the handler until authorized.

Steering: `steering/70-background-authorize.md`, `steering/78-push-channel.md`.

### 3. Dynamics Push Channel migration (when `com.good.gd.push` is required)

When the app uses UEM Push Channel (server push over Dynamics transport):

1. Use `new PushChannel(pushChannelId)` with the UEM-supplied channel ID.
2. Register `prepareIntentFilter()` with
   `GDAndroid.getInstance().registerReceiver(receiver, intentFilter)`.
3. Implement a standard Android `BroadcastReceiver` and switch on
   `PushChannel.getEventType(intent)` in `onReceive(...)`. Use the
   `PushChannel` intent helpers (`getToken`, `getMessage`,
   `getErrorCode`, `getPingFailCode`) to extract event data.
4. Call `connect()` from `runOnAuthorized` / `onAuthorized()` — not from
   pre-auth `Activity.onCreate`.
5. Tear down on `onLocked()` / `onWiped()` (`disconnect()`,
   `GDAndroid.getInstance().unregisterReceiver(receiver)`).

Verified types only:

- `com.good.gd.GDAndroid`
- `com.good.gd.push.PushChannel`
- `com.good.gd.push.PushChannelState`
- `com.good.gd.push.PushChannelEventType`

Do **not** use `PushChannelListener` as a migration target. It is present in
the public API reference only as a deprecated listener interface. Do **not**
invent or import `GDLocalBroadcastManager`; Push Channel local broadcasts are
registered through `GDAndroid.getInstance().registerReceiver(...)`.

Doc URLs are in `steering/14-api-provenance-and-replacement-catalog.md` and
`steering/78-push-channel.md`.

### 4. Record catalog-backed replacements

For each migrated surface, add `apisReplaced[]` rows in the migration report
( prompt `10` ) referencing catalog IDs:

| Catalog ID | When |
|------------|------|
| `push-java-001` | FCM handler gated + metadata-only payload |
| `push-java-002` | `PushChannel` construction + `connect()` |
| `push-java-003` | Deprecated Push Channel listener removed/replaced |
| `push-java-004` | `GDAndroid.registerReceiver` receiver for channel events |

### 5. Inline comments

Tag non-obvious push changes with `[BB_DYNAMICS-MIGRATION]` per
`steering/06-inline-migration-comments.md`.

---

## Record execution

When complete, run:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
  --prompt-id 11 --status completed
```

When `securePush` is not applicable per the execution plan, record skipped:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
  --prompt-id 11 \
  --status skipped \
  --note "securePush not-applicable per executionPlan"
```

This records progress only. For an immediate diagnostic, run
`validate.sh --check-prompt 11`; prompt `10` remains the mandatory final
source/report gate. Fix any Phase `12` failures before prompt `03c`.

---

## Acceptance criteria

- No invented `GDPush*` or other unverified `com.good.gd.*` symbols.
- No `PushChannelListener` or `GDLocalBroadcastManager` remnants.
- FCM services: `onMessageReceived` / `onNewToken` include
  `isContainerAuthorized` or Background Authorize handshake markers when
  they perform work beyond logging.
- `PushChannel` usage registers with `GDAndroid.registerReceiver`, unregisters
  on teardown, and connects post-authorization.
- `validate.sh --check-prompt 11` exits 0 on a clean project.

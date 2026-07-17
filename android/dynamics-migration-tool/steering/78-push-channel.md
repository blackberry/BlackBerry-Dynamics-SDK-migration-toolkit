# Steering: Push Channel and FCM migration

**Ownership:** platform migration kit (`prompts/11-push-channel.md`, Phase `12`,
`contracts/api-catalog.v1.0.0.json` `securePush` rows).

Enterprise Android apps commonly use **two distinct push mechanisms**:

1. **FCM (Firebase Cloud Messaging)** — OS-delivered wake signals. In a
   Dynamics app, FCM must **not** carry sensitive enterprise payloads and
   handlers must **not** touch secure APIs until the container is authorized.
2. **Dynamics Push Channel** (`com.good.gd.push`) — UEM/server-initiated
   messaging inside the secured container. This is **not** FCM; it uses
   `PushChannel`, `PushChannel.prepareIntentFilter()`, a standard Android
   `BroadcastReceiver`, `GDAndroid.getInstance().registerReceiver(...)`, and
   `PushChannel.getEventType(Intent)` for channel events.

> **Verified public API (WI-00, SDK 15.0 / originally verified on 14.1):** `PushChannel`,
> `PushChannelState`, `PushChannelEventType`, and
> `GDAndroid.getInstance().registerReceiver(BroadcastReceiver, IntentFilter)`.
> `PushChannelListener` is present in the API reference but deprecated; do not
> use it as a migration target. There are **no** `GDPushChannel*` types in the
> installed AAR. Maintainer transcript:
> `_maintainer/notes/sdk-verification-2026Q2.md`.

---

## When this domain applies

| Signal | Domain | Follow-on |
|--------|--------|-----------|
| `FirebaseMessagingService` subclass in manifest or source | FCM + Background Authorize | `70-background-authorize.md`, prompt `03c` |
| App registers for FCM and reads `RemoteMessage` data in `onMessageReceived` | FCM hardening | metadata-only payloads; auth gate in handler |
| App uses UEM Push Channel IDs / server push over Dynamics transport | `securePush` | `PushChannel` wiring (this doc) |
| No push usage | N/A | Skip prompt `11` |

Prompt `00-analyze-app.md` should record `securePush` as `applicable: true`
when either FCM enterprise handlers or `com.good.gd.push` usage is present.

---

## FCM rules (pair with Background Authorize)

FCM is an **untrusted wake channel**. Treat notification title/body and
top-level `data` map entries as visible outside the container.

| Rule | Rationale |
|------|-----------|
| Use FCM only as a **wake signal** (opaque ID / “sync now”) | Sensitive strings in FCM payloads leak via the OS push pipeline |
| Gate `onMessageReceived` / secure work on `isContainerAuthorized()` **or** the canonical Background Authorize handshake | Prevents `GDNotAuthorizedError` and data access before unlock |
| Run prompt `03c` when `bootstrap.processModel.backgroundEntryPoints[]` lists the FCM service | Per-candidate opt-in for `canAuthorizeAutonomously` + `serviceInit` |
| Set `GDEnableBackgroundAuthorize: true` only when a `migrate` decision exists for that service | See `11-settings-json-reference.md` |

Canonical FCM handler shape (from `70-background-authorize.md`):

```java
@Override
public void onMessageReceived(RemoteMessage message) {
    if (!MyDynamicsApplication.isContainerAuthorized()) {
        // Queue or drop — container not ready
        return;
    }
    // Metadata-only wake: fetch enterprise data with secure APIs post-auth
}
```

Phase **12** hard-fails when a `FirebaseMessagingService` subclass defines
`onMessageReceived` or `onNewToken` without an authorization guard in that
class.

---

## Dynamics Push Channel API mapping

Authoritative reference:
[PushChannel](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1push_1_1_push_channel.html).

| Legacy / ad-hoc pattern | Dynamics replacement |
|-------------------------|----------------------|
| Custom socket/long-poll to UEM for server push | `new PushChannel(pushChannelId)` + `connect()` |
| Ad-hoc broadcast actions for push events | `PushChannel.prepareIntentFilter()` + `GDAndroid.getInstance().registerReceiver(BroadcastReceiver, intentFilter)`; dispatch with `PushChannel.getEventType(intent)` |
| Hand-rolled token registration | `PushChannel.getToken(intent)` on `Open` events |
| Message delivery callback | `BroadcastReceiver.onReceive(...)` + `PushChannel.getMessage(intent)` on `PushChannelEventType.Message` |
| Channel lifecycle | `PushChannelState` (`None`, `Open`, `Error`, `Closed`) |

### Wiring checklist

1. Obtain the **push channel ID** from UEM / server documentation (not the
   FCM sender ID).
2. Construct `PushChannel` with that ID after `onAuthorized()` (or from
   `Application.runOnAuthorized`).
3. Register a `BroadcastReceiver` with `mPushChannel.prepareIntentFilter()`
   via `GDAndroid.getInstance().registerReceiver(receiver, intentFilter)`.
4. In `BroadcastReceiver.onReceive(...)`, switch on
   `PushChannel.getEventType(intent)` for open/message/error/close/ping-fail.
5. Call `connect()` when `GDConnectivityManager.getActiveNetworkInfo()
   .isPushChannelAvailable()` (see platform samples).
6. Call `disconnect()` on `onLocked()` / `onWiped()` and unregister the
   receiver with `GDAndroid.getInstance().unregisterReceiver(receiver)`.

### Intent helper methods (verified)

| Method | Use |
|--------|-----|
| `PushChannel.getEventType(Intent)` | Switch on `PushChannelEventType` |
| `PushChannel.getToken(Intent)` | Token after channel open |
| `PushChannel.getMessage(Intent)` | Payload on `Message` events |
| `PushChannel.getErrorCode(Intent, default)` | Error events |
| `PushChannel.getPingFailCode(Intent, default)` | Ping failure events |

---

## Detection hints (for agents)

```bash
# FCM entry points
rg -n 'FirebaseMessagingService|onMessageReceived' --glob '*.{java,kt}'

# Dynamics Push Channel (do not invent GDPush*)
rg -n 'com\.good\.gd\.push\.|PushChannel\b|GDAndroid\.getInstance\(\)\.registerReceiver' --glob '*.{java,kt}'
```

---

## Anti-patterns

| Anti-pattern | Fix |
|--------------|-----|
| `GDFileSystem` / secure SQL / `GDHttpClient` in `onMessageReceived` without Background Authorize | Wire `03c` + guard; defer work to `runOnAuthorized` |
| Sensitive text in FCM `notification` payload | Metadata-only wake; fetch inside container |
| Invented `GDPushChannel` types | Use `com.good.gd.push.PushChannel` only |
| `PushChannelListener` | Deprecated in current public docs; use `PushChannel.prepareIntentFilter()` + `GDAndroid.getInstance().registerReceiver(...)` |
| `GDLocalBroadcastManager` | Not a public Dynamics Android API; register a standard `BroadcastReceiver` through `GDAndroid` |
| `PushChannel.connect()` from `Activity.onCreate` before auth | Connect from `onAuthorized()` / `runOnAuthorized` |
| Duplicate push stacks (FCM + Push Channel) without documented roles | Document: FCM = wake, Push Channel = UEM server channel |

---

## Cross-references

- `steering/70-background-authorize.md` — FCM service handshake
- `steering/14-api-provenance-and-replacement-catalog.md` — catalog rows `push-java-*`
- `prompts/11-push-channel.md` — migration steps
- `prompts/03c-background-authorize.md` — runs **after** prompt `11`

---

## Verification

- `bash dynamics-migration-tool/tooling/validate.sh --check-prompt 11` — Phase `12`
- Maintainer: `internal/fixtures/10-notifications/` pass/fail pair
- `bash dynamics-migration-tool/_maintainer/tooling/hardening-smoke.sh` — WI-02 scan

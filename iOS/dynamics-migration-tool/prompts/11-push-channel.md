## Task: Push Channel Audit and Migration Decisions (iOS)

Goal: classify push-notification surfaces and apply Dynamics Push Channel where
appropriate for SDK 15.x.

This prompt is **applicability-driven** and may be `not-applicable`.

---

## Prerequisites

- Prompt 03b completed (authorization closure in place)
- Prompt 06 completed for networking classification context

---

## Steps

1. Inventory push-related code paths:
   - APNs registration and callbacks (`registerForRemoteNotifications`,
     `didRegisterForRemoteNotificationsWithDeviceToken`,
     `didReceiveRemoteNotification`, notification-center delegates)
   - Existing Dynamics push usage (`GDPushChannel`, push notifications from
     Dynamics SDK)

2. For each push path, classify migration treatment:
   - Keep APNs metadata-only path (with post-auth secure guard)
   - Migrate to `GDPushChannel`
   - Manual intervention required (app-server contract/backend dependency)

3. If migrating a path to `GDPushChannel`:
   - Use only documented APIs from `GDPush.h`
   - Capture channel lifecycle and token handoff behavior clearly
   - Add `[BB_DYNAMICS-MIGRATION]` comments on changed code

4. If keeping APNs path:
   - Ensure secure container access is gated by authorization state
   - Do not process protected payloads pre-auth

5. Add outcomes to migration notes/report inputs:
   - migrated paths
   - retained APNs paths with rationale
   - manual intervention items

---

## Common Pitfalls (Prompt 11)

- Treating APNs and Dynamics Push Channel as drop-in equivalents without server
  contract review.
- Using non-public/invented push API names.
- Processing secure payload in background callbacks without auth guard.

---

## Output

- Push path inventory and per-path disposition
- Any code changes needed for `GDPushChannel` usage
- Manual intervention items for server-side dependencies

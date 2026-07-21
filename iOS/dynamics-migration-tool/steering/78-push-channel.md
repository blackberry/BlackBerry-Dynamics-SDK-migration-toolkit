# Steering: Push Channel (iOS, SDK 15.x)

Use this guidance when the app has server-to-app signaling requirements.

## Public API (15.x)

- Class: `GDPushChannel`
- Header: `GDPush.h`
- Related availability signal: `GDReachability.isPushChannelAvailable`

Do not invent push APIs. In particular, there is no `GDPushConnection` class.

## What Push Channel Covers

`GDPushChannel` is the Dynamics push front-end channel used for enterprise
signaling via Dynamics NOC.

- App opens channel with `connect`
- Receives notifications (`GDPushChannelOpenedNotification`, error/close)
- Sends channel token to app server (`GDPushChannelTokenKey`)

## Migration Expectations

- If app currently uses APNs direct flows only, do not auto-rewrite business
  push logic blindly.
- Classify each push path:
  - metadata-only APNs path retained
  - Dynamics Push Channel migration candidate
  - manual intervention required (server contract changes needed)
- Capture explicit rationale in report/manual todos.

## Authorization / Lifecycle Guard

Push-triggered background callbacks must not touch secure APIs before
authorization is complete.

- Guard with `GDAppEventAuthorized`/`GDState.isAuthorized`
- If autonomous background auth is required, use documented
  `canAuthorizeAutonomously`/`authorizeAutonomously` patterns only.

## Out of Scope for this Prompt

- Full server-side NOC push backend implementation
- App-specific business payload redesign

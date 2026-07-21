# Steering: Background Authorization (iOS)

Background Authorization allows a Dynamics app to access the secure
container while in the background, without requiring user interaction.

---

## When to Use

- Background fetch tasks that access secure data
- Push notification handling that reads/writes secure storage
- Background URLSession transfers through Dynamics
- Location updates that need to store data securely

---

## Configuration

### Info.plist

```xml
<!-- [BB_DYNAMICS-MIGRATION] Enable Background Authorize -->
<key>GDEnableBackgroundAuthorize</key>
<true/>
```

### AppDelegate

```swift
// Check if autonomous authorization is possible
if GDiOS.sharedInstance().canAuthorizeAutonomously {
    GDiOS.sharedInstance().authorizeAutonomously()
}
```

---

## Events

When background authorization succeeds, the app receives
`GDAppEventBackgroundAuthorized`. When it fails,
`GDAppEventBackgroundNotAuthorized`.

```swift
func handle(_ anEvent: GDAppEvent) {
    switch anEvent.type {
    case .authorized:
        onAuthorized(event: anEvent)
    case .backgroundAuthorized:
        onBackgroundAuthorized(event: anEvent)
    case .backgroundNotAuthorized:
        onBackgroundNotAuthorized(event: anEvent)
    // ... other cases
    }
}
```

---

## Limitations

- Background authorization is only available after the user has
  successfully authorized at least once
- UEM policy must allow autonomous authorization
- The container must not be locked or wiped

# Steering: Inline Migration Comments

Every code change made during migration MUST be tagged with an inline
`[BB_DYNAMICS-MIGRATION]` comment. This allows developers to:
- Find every migration change with a single search
- Understand why each change was made
- Review migration completeness
- Revert or adjust individual changes

---

## Syntax by File Type

### Swift

```swift
// [BB_DYNAMICS-MIGRATION] Replaced FileManager.default with GDFileManager.default
// for encrypted file storage in the Dynamics secure container
let fileManager = GDFileManager.default
```

### Objective-C

```objc
// [BB_DYNAMICS-MIGRATION] Added GDiOS authorization in AppDelegate
// The app must authorize before accessing any secure APIs
[[GDiOS sharedInstance] authorize];
```

### Info.plist (XML)

```xml
<!-- [BB_DYNAMICS-MIGRATION] Added GDApplicationID for Dynamics entitlement -->
<key>GDApplicationID</key>
<string>com.company.appname</string>
```

### Podfile

```ruby
# [BB_DYNAMICS-MIGRATION] Added BlackBerryDynamics SDK dependency
  pod 'BlackBerryDynamics', '~> 15.1'
```

### Storyboard / XIB (XML)

```xml
<!-- [BB_DYNAMICS-MIGRATION] Note: this view loads secure data; ensure
     the owning ViewController defers data loading to post-authorization -->
```

### Entitlements (XML)

```xml
<!-- [BB_DYNAMICS-MIGRATION] Added Keychain Sharing for Dynamics secure container -->
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.good.gd.data</string>
</array>
```

### Xcode Project (pbxproj)

Changes to `.pbxproj` are typically made through Xcode or CocoaPods. Do not
add comments directly to `.pbxproj` files. Instead, document the change in
the corresponding source file or in the migration report.

---

## Comment Format Rules

1. **Always start with** `[BB_DYNAMICS-MIGRATION]`
2. **Follow with a one-line summary** of what changed
3. **Optionally add a second line** explaining why
4. **Keep it concise** — 1-2 lines maximum
5. **Place the comment immediately above** the changed line(s)
6. **Do NOT add comments in JSON files** (migration-report.json)

---

## Finding All Changes

After migration, all changes can be found with:

```bash
rg "\[BB_DYNAMICS-MIGRATION\]" --include="*.swift" --include="*.m" --include="*.h" \
  --include="*.plist" --include="*.entitlements" --include="Podfile" -n
```

Or in Xcode: Find > Find in Project > `[BB_DYNAMICS-MIGRATION]`

---

## Examples by Migration Phase

### Authorization
```swift
// [BB_DYNAMICS-MIGRATION] Initialize Dynamics authorization — must be called
// before any secure API access; UI deferred to onAuthorized handler
GDiOS.sharedInstance().authorize()
```

### File Storage
```swift
// [BB_DYNAMICS-MIGRATION] Replaced FileManager with GDFileManager for
// encrypted file operations inside the Dynamics secure container
let fm = GDFileManager.default
```

### Core Data
```swift
// [BB_DYNAMICS-MIGRATION] Replaced NSPersistentStoreCoordinator with
// GDPersistentStoreCoordinator for encrypted Core Data store
let coordinator = GDPersistentStoreCoordinator(managedObjectModel: model)
```

### SwiftData
```swift
// [BB_DYNAMICS-MIGRATION] Encrypted SwiftData store via GDSecureModelContainer
// Created only after Dynamics authorization; keep @Model / @Query / ModelContext
let container = try GDSecureModelContainer.create(config)
```

### Networking (auto-swizzled — comment where NO change needed)
```swift
// [BB_DYNAMICS-MIGRATION] No change needed — the SDK auto-swizzles
// NSURLSession after authorization for secure communication
let session = URLSession.shared
```

### Networking (socket migration — comment where change IS needed)
```swift
// [BB_DYNAMICS-MIGRATION] Replaced raw socket with GDSocket for
// secure communication through the Dynamics infrastructure
let gdSocket = GDSocket("server.example.com", onPort: 443, andUseSSL: true)
```

### Pasteboard / DLP
```swift
// [BB_DYNAMICS-MIGRATION] Using GDNativePasteboardAccess to allow native
// pasteboard access while DLP policy restricts cross-app copy/paste
var content: String?
GDNativePasteboardAccess.performAction(onNativePasteboard: {
    content = UIPasteboard.general.string
})
```

### Redundant Feature Removal
```swift
// [BB_DYNAMICS-MIGRATION] Removed app-level biometric lock — Dynamics SDK
// provides container lock/unlock with biometric support via UEM policy
```

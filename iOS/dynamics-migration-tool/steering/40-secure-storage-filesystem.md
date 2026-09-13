# Steering: Secure File Storage (iOS)

The Dynamics SDK provides encrypted file storage through `GDFileManager`,
`GDFileHandle`, `GDCReadStream`, and `GDCWriteStream`. All files stored
through these APIs are encrypted at rest in the Dynamics secure container.

---

## File I/O Is NOT Auto-Swizzled

Unlike networking APIs (where the SDK auto-swizzles `NSURLSession` and
`NSURLConnection` transparently), **file I/O is NOT automatically
intercepted** in production builds. The SDK contains a
`GDFileManagerProxyLayer` that can swizzle `NSFileManager` methods, but
this proxy layer is not activated in the production startup path.

This means apps **must explicitly use** `GDFileManager`, `GDFileHandle`,
`GDCReadStream`, and `GDCWriteStream` instead of their standard iOS
counterparts. Standard `FileManager.default` calls will continue to
operate on the unencrypted app sandbox, not the secure container.

---

## API Replacements

| Standard iOS API | Dynamics Equivalent | Notes |
|-----------------|-------------------|-------|
| `FileManager.default` | `GDFileManager.default` | Subclass of `NSFileManager` |
| `FileHandle(forReadingFrom:)` | `GDFileHandle(forReadingFrom:)` | Subclass of `NSFileHandle` |
| `FileHandle(forWritingTo:)` | `GDFileHandle(forWritingTo:)` | Subclass of `NSFileHandle` |
| `InputStream(url:)` | `GDCReadStream(url:)` | Subclass of `NSInputStream` |
| `OutputStream(url:)` | `GDCWriteStream(url:)` | Subclass of `NSOutputStream` |
| `Data.write(to:)` | Write via `GDFileManager` or `GDCWriteStream` | |
| `String.write(to:)` | Write via `GDFileManager` or `GDCWriteStream` | |

---

## GDFileManager

`GDFileManager` is a subclass of `NSFileManager` (Swift: `FileManager`).
It provides the same interface but all operations target the encrypted
secure container.

### Before

```swift
let fm = FileManager.default
let documentsPath = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
let filePath = documentsPath.appendingPathComponent("data.json")
try data.write(to: filePath)
```

### After

Import the module first:
- Swift: `import BlackBerryDynamics.SecureStore.File`
- ObjC (CocoaPods): `@import BlackBerryDynamics.SecureStore.File;`
- ObjC (manual): `#import <BlackBerryDynamics/GD/GDFileManager.h>`

**Swift:**
```swift
import BlackBerryDynamics.SecureStore.File

// [BB_DYNAMICS-MIGRATION] Replaced FileManager with GDFileManager for
// encrypted file storage in the Dynamics secure container
let fm = GDFileManager.default
let documentsPath = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
let filePath = documentsPath.appendingPathComponent("data.json")
fm.createFile(atPath: filePath.path, contents: data, attributes: nil)
```

**Objective-C (CocoaPods):**
```objc
@import BlackBerryDynamics.SecureStore.File;

// [BB_DYNAMICS-MIGRATION] Replaced NSFileManager with GDFileManager
NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
NSString *documentsDir = [paths objectAtIndex:0];
NSString *filePath = [documentsDir stringByAppendingPathComponent:@"data.json"];
[[GDFileManager defaultManager] createFileAtPath:filePath contents:data attributes:nil];
```

### Path Handling

**CRITICAL**: `GDFileManager` is a subclass of `NSFileManager` and uses the
**same full filesystem paths** as standard iOS file operations. It intercepts
those paths transparently and redirects reads/writes to the encrypted secure
container.

- **Use the same path-building logic** as you would with `NSFileManager` —
  `NSSearchPathForDirectoriesInDomains`, `urls(for:in:)`, etc.
- Do NOT use bare relative filenames (e.g., `@"data.json"`) — these will
  fail because `GDFileManager` expects full paths.
- Do NOT invent a new path scheme — the original app's path logic should
  remain unchanged; only the `NSFileManager`/`FileManager` class reference
  changes to `GDFileManager`.

**Migration rule**: when replacing `NSFileManager` with `GDFileManager`,
change ONLY the class name. Keep all path-building code exactly as-is.

---

## GDFileHandle

`GDFileHandle` is a subclass of `NSFileHandle`. Use it for reading and
writing files in the secure container:

```swift
// [BB_DYNAMICS-MIGRATION] Replaced FileHandle with GDFileHandle
// Use the same full path as you would with standard FileHandle
let handle = GDFileHandle(forWritingAtPath: filePath)
handle?.write(data)
handle?.closeFile()
```

---

## GDCReadStream / GDCWriteStream

For streaming I/O:

```swift
// [BB_DYNAMICS-MIGRATION] Replaced InputStream with GDCReadStream
// Use the same full path as you would with standard InputStream
let readStream = GDCReadStream(file: filePath)
readStream.open()
var buffer = [UInt8](repeating: 0, count: 1024)
let bytesRead = readStream.read(&buffer, maxLength: buffer.count)
readStream.close()
```

```swift
// [BB_DYNAMICS-MIGRATION] Replaced OutputStream with GDCWriteStream
// Use the same full path as you would with standard OutputStream
let writeStream = GDCWriteStream(file: outputPath)
writeStream.open()
data.withUnsafeBytes { rawBuffer in
    let bytes = rawBuffer.bindMemory(to: UInt8.self)
    writeStream.write(bytes.baseAddress!, maxLength: data.count)
}
writeStream.close()
```

---

## UserDefaults for Sensitive Data

`UserDefaults` stores data in an unencrypted plist file in the app sandbox.
For sensitive data, migrate to `GDFileManager`:

### Before

```swift
UserDefaults.standard.set(token, forKey: "authToken")
UserDefaults.standard.set(userId, forKey: "userId")
```

### After

```swift
// [BB_DYNAMICS-MIGRATION] Moved sensitive data from UserDefaults to
// secure container — UserDefaults is not encrypted
let sensitiveData = ["authToken": token, "userId": userId]
let jsonData = try JSONEncoder().encode(sensitiveData)
let docsURL = GDFileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let prefsPath = docsURL.appendingPathComponent("prefs.json").path
GDFileManager.default.createFile(atPath: prefsPath, contents: jsonData, attributes: nil)
```

Do **not** add a one-time `UserDefaults` → container copy
(`18-fresh-dynamics-install.md`). A Dynamics conversion is always a
fresh install.

**Keep in UserDefaults**: Non-sensitive UI preferences, feature flags,
onboarding state, theme preferences — anything that doesn't contain
PII, credentials, or business data.

---

## Downstream Readers and Follow-On Consumers

Writer closure is insufficient by itself. Any reader/viewer/archive/cache
path that still consumes unmanaged local files must be migrated or blocked
with explicit rationale. Review and close:

- `Data(contentsOf:)` / `String(contentsOf:)` reads from local file URLs
- Reader wrappers that open local paths after a secure write
- Viewer/export/archive flows that stage plaintext outside secure storage

Sensitive storage must not round-trip through unmanaged temporary files.

---

## Keychain and Local Crypto Policy (Context-Based)

Do not treat all Keychain usage as automatically safe or automatically
forbidden.

- Keep device-bound secrets in Keychain when justified by policy and threat
  model.
- Migrate app-data payloads that should be container-managed to secure file
  storage.
- For local cryptography (`CryptoKit`, `CommonCrypto`, SQLCipher helpers),
  retain or remove only with explicit evidence/rationale. Do not remove by
  assumption.

Recorder/validator closure requires explicit disposition + evidence for
Keychain and local-crypto call sites.

---

## Temp File / Plaintext Leakage

Flag any code that writes sensitive data outside the secure container, even
temporarily:

- `FileManager.default.temporaryDirectory` for sensitive data
- Image capture to the standard filesystem before moving to container
- Document processing via temp files
- Any "write to standard FS → process → copy to container → delete" pattern

Replace with in-memory processing or direct writes to the secure container.

---

## Temporary Directory Compatibility

`GDFileManager.default.temporaryDirectory` is not consistently reliable across
all SDK/runtime combinations. Some apps encounter runtime warnings/errors
reporting this API as unsupported with an empty NSURL.

Migration policy:

- Keep existing app temp path-building logic where possible (for example,
  `NSTemporaryDirectory()` and existing filename conventions), and change only
  the file I/O API to `GDFileManager`/`GDFileHandle`.
- Do NOT rely on `GDFileManager.default.temporaryDirectory` in generated code.
- Prefer in-memory processing for small payloads.
- If preserved temp path is unreliable at runtime, create temp files under a
  known secure container location from `GDFileManager.default.urls(for:in:)`:
  - first choice: `.cachesDirectory`
  - fallback: `.documentDirectory`
  - append an app-owned temp subdirectory (for example `tmp_secure`) and a
    UUID filename.
- Always run a post-authorization runtime probe (create/read/delete) for the
  selected temp-path strategy.

---

## Third-Party Library Compatibility

Libraries that expect `FileManager` or `URL` file paths may not work
directly with the Dynamics container:

- **Image libraries** (Kingfisher, SDWebImage): May cache to standard
  filesystem. Evaluate whether cache data is sensitive.
- **Zip libraries**: May need `Data`-based APIs instead of file paths
- **Document viewers**: May need content loaded via `Data` rather than file URL

For each incompatible library, options are:
1. Use `Data`/`byte[]` based APIs if available
2. Copy to a temp location in the standard filesystem for processing
   (non-sensitive data only)
3. Document as a manual TODO if no workaround exists

---

## Modular Architecture: SPM + CocoaPods Boundary

Some apps keep core logic in an SPM module while integrating Dynamics via
CocoaPods in the app target. In that topology, package code may be unable to
import Dynamics modules directly.

### Execution Policy

- **Auto-apply app-level adapter injection** when all are true:
  - Sensitive file I/O call sites are in a module that cannot import Dynamics
  - App target has Dynamics linkage
  - There is a stable composition root (`AppDelegate`, bootstrap, DI container)
- **Fallback to suggest/manual** only when uncertain:
  - No clear composition root exists
  - Refactor requires broad constructor or singleton redesign
  - Ownership/lifecycle wiring is ambiguous

### Reference Pattern

1. Define protocol in the non-Dynamics module (for example,
   `SecureFileWriting`) with methods the module needs.
2. Implement the protocol in app target using `GDFileManager`/`GDFileHandle`.
3. Inject the implementation from app composition root during startup.
4. Keep module-level business logic independent of Dynamics imports.

This pattern is preferred over forcing direct Dynamics imports into package
targets that cannot link those modules.

---

## Common Issues

1. **Using bare relative filenames** — `GDFileManager` expects the same
   full filesystem paths as `NSFileManager` (e.g., Documents directory
   path from `NSSearchPathForDirectoriesInDomains`). Do NOT strip the
   path and use just a filename like `@"data.json"` — this will fail
   with `Error: 2` (ENOENT).
2. **Mixing `FileManager` and `GDFileManager`** — standard `FileManager`
   cannot see files in the secure container and vice versa
3. **Accessing files before authorization** — `GDFileManager` operations
   fail before the container is unlocked
4. **Changing path-building logic during migration** — keep all
   `NSSearchPathForDirectoriesInDomains`, `urls(for:in:)`, and
   `stringByAppendingPathComponent:` calls exactly as-is. Only change
   the class name from `NSFileManager`/`FileManager` to `GDFileManager`.
5. **Closing writers but not readers** — unresolved downstream readers leave
   sensitive data paths open and fail final storage closure validation.
6. **Unresolved sensitive dispositions** — sensitive storage call sites that
   remain `deferred`/`blocked` are non-waivable for Prompt 05 completion.

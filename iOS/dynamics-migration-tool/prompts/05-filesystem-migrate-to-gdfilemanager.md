## Task: Migrate File Storage to GDFileManager

Goal: Replace standard file I/O APIs with Dynamics secure equivalents
for encrypted file storage in the secure container.

**Prerequisites**:
- Prompts 00-03b must be complete
- The analysis (Prompt 00) identified file I/O usage

**Skip this prompt if the app does not use file storage for sensitive data.**

---

## Steps

### 0. Select Execution Strategy (Hard Gate)

Before making any file-storage code change, determine strategy from Prompt 00
architecture findings:

- **Direct replacement strategy** (`FileManager` -> `GDFileManager`) when the
  owning target can import Dynamics modules.
- **App-level adapter injection strategy** when file I/O lives in an SPM/module
  target that cannot import Dynamics but app target can.

For mixed SPM + CocoaPods boundaries, use this policy:
- **Auto-apply injection** when all are true:
  - file I/O call site is in non-Dynamics-importable module
  - Dynamics linkage exists in app target
  - a stable composition root exists (`AppDelegate`, bootstrap, DI container)
- **Suggest/manual only** when uncertain:
  - no clear composition root
  - wide constructor/singleton redesign required
  - ownership/lifecycle wiring is ambiguous

When execution mode is uncertain, stop automation for that path and emit a
high-priority manual TODO with exact files and required injection boundaries.

### 1. Replace FileManager Usage

**CRITICAL**: `GDFileManager` uses the **same full filesystem paths** as
`NSFileManager`/`FileManager`. It intercepts those paths transparently and
redirects to the secure container. Do NOT change the path-building logic —
only change the class name.

**Swift:**
```swift
// Before
let fm = FileManager.default
let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
let filePath = docsURL.appendingPathComponent("data.json").path
fm.createFile(atPath: filePath, contents: data, attributes: nil)

// After — ONLY the class name changes, paths stay the same
// [BB_DYNAMICS-MIGRATION] Encrypted file storage in Dynamics container
let fm = GDFileManager.default
let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
let filePath = docsURL.appendingPathComponent("data.json").path
fm.createFile(atPath: filePath, contents: data, attributes: nil)
```

**Objective-C (CocoaPods):**
```objc
// Before
NSFileManager *fm = [NSFileManager defaultManager];
[fm createFileAtPath:filePath contents:data attributes:nil];

// After — ONLY the class name changes, paths stay the same
// [BB_DYNAMICS-MIGRATION] Encrypted file storage in Dynamics container
GDFileManager *fm = [GDFileManager defaultManager];
[fm createFileAtPath:filePath contents:data attributes:nil];
```

### 2. Replace FileHandle Usage

```swift
// Before
let handle = FileHandle(forWritingAtPath: path)

// After — same path, only class name changes
// [BB_DYNAMICS-MIGRATION] Encrypted file handle
let handle = GDFileHandle(forWritingAtPath: path)
```

### 3. Replace Stream I/O

```swift
// Before
let input = InputStream(url: fileURL)
let output = OutputStream(url: fileURL, append: false)

// After — same paths, only class names change
// [BB_DYNAMICS-MIGRATION] Encrypted streams for Dynamics container
let input = GDCReadStream(file: filePath)
let output = GDCWriteStream(file: outputPath)
```

### 4. Migrate UserDefaults Sensitive Data

Move sensitive data from `UserDefaults` to secure file storage. For each
key migrated, provide both **write** and **read** implementations.

A Dynamics conversion is always a **fresh install**
(`steering/18-fresh-dynamics-install.md`). Do **not** add
`migrateFromUserDefaults` or any leftover UserDefaults copy helper.

```swift
// [BB_DYNAMICS-MIGRATION] Moved sensitive data from UserDefaults to secure storage

struct SecurePrefs {
    private static var docsURL: URL? {
        GDFileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static func set(_ value: String, forKey key: String) {
        guard let docsURL else { return }
        let data = value.data(using: .utf8)
        GDFileManager.default.createFile(
            atPath: docsURL.appendingPathComponent(key).path,
            contents: data,
            attributes: nil
        )
    }

    static func string(forKey key: String) -> String? {
        guard let docsURL else { return nil }
        let path = docsURL.appendingPathComponent(key).path
        guard let data = GDFileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// SecurePrefs.set(token, forKey: "authToken")
// let token = SecurePrefs.string(forKey: "authToken")
```

Keep non-sensitive preferences in `UserDefaults` (theme, UI state, etc.).

### 5. Path Handling Rules

**CRITICAL**: Do NOT change the app's path-building logic during migration.

- Keep all `NSSearchPathForDirectoriesInDomains`, `urls(for:in:)`, and
  `stringByAppendingPathComponent:` calls exactly as-is.
- Do NOT use bare filenames (e.g., `@"data.json"`) — `GDFileManager`
  expects full paths and will fail with Error 2 (ENOENT) on bare names.
- Do NOT invent a new relative-path scheme — the original paths work.

### 6. Handle Temp File Patterns

Replace temp file patterns that leak data outside the container:

```swift
// Before (data leakage — writes to unencrypted system temp directory)
let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("export.tmp")
data.write(to: tempURL)

// After — Option A: keep the app's temp path-building pattern, change writer API
// [BB_DYNAMICS-MIGRATION] Temp file path preserved, write routed via GDFileManager
let fm = GDFileManager.default
let filename = UUID().uuidString + ".tmp"
let secureTempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent(filename)
let secureTempPath = secureTempURL.path
fm.createFile(atPath: secureTempPath, contents: data, attributes: nil)
// ... process ...
try? fm.removeItem(atPath: secureTempPath)

// After — Option B: process entirely in memory (preferred for small payloads)
// [BB_DYNAMICS-MIGRATION] Processing data in memory — no temp file needed
// processInMemory(data)
```

Use Option A when the data is too large for in-memory processing (e.g.,
large documents, media files). Use Option B when the payload is small
enough that an in-memory approach is feasible (< ~10 MB). Always clean up
secure temp files after use — they are not automatically cleared.

**Universal temp-path rule**:
- Keep the app's existing temp path-building logic where possible
  (`NSTemporaryDirectory()`, existing `URL(fileURLWithPath:)`, existing filename conventions).
- Change the file I/O API to `GDFileManager`/`GDFileHandle` only.
- Do NOT rely on `GDFileManager.default.temporaryDirectory` in generated migration code.
  Some SDK/runtime combinations report this API as unsupported (empty NSURL warning at runtime).
- If preserved temp path fails runtime probe, fallback to container-backed temp path:
  `.cachesDirectory` first, then `.documentDirectory`, plus app temp subdirectory.

Known runtime log signals when `GDFileManager.default.temporaryDirectory` is used:
- `ERR 'temporaryDirectory' is unsupported`
- `-[NSURL init] called; this results in an NSURL instance with an empty URL string.`

### 6a. Secure Temp Runtime Probe (Required)

After implementing temp-file handling, run a runtime probe in post-authorization
flow for the selected path strategy:

- create temp file
- read back bytes
- delete temp file

If the probe fails, classify as step-introduced risk and emit a high-priority
manual TODO with:
- failing API/path pattern
- affected files
- recommended fallback path (`.cachesDirectory` or `.documentDirectory` + app temp subdirectory)

### 7. Build and Verify

Run `xcodebuild` to verify compilation. Classify any failures as
pre-existing (per developer clean-build attestation/history), step-introduced, or unrelated.

---

## Closure Ledger Update (Required)

Before recording Prompt 05 as `completed`, write call-site dispositions for
the `secureFileStorage` domain using the atomic updater:

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "05" \
  --domain-id "secureFileStorage" \
  --updates-file /tmp/secure-file-updates.json
```

Do not edit `output/migration-plan-state.json` directly.
Missing dispositions block recorder completion.

Disposition rules for this prompt:
- Every applicable `secureFileStorage` call site must be updated (writers and
  downstream readers/follow-on consumers).
- Sensitive storage call sites cannot remain open; unresolved sensitive paths
  must end as `migrated` or `removed`.
- Keychain call sites require explicit policy decision + evidence
  (context-based, not globally safe/forbidden).
- Local-crypto call sites require explicit rationale/evidence before removal
  or retention (do not remove by assumption).
- `blocked` and `deferred` are non-waivable for Prompt 05 completion.

Prompt-scoped validation phases for this prompt are:
`0-artifact-provenance, 5-secure-file-writers, 5b-secure-file-readers-follow-on, 5c-preferences-keychain-crypto, 5d-storage-final-closure`.

---

## Output

- Execution strategy documented (`direct-replacement` or `app-level-injection`)
- For mixed boundaries, injection **auto-applied** when conditions were met
- For uncertain boundaries, manual TODOs emitted with concrete wiring guidance
- `FileManager.default` replaced with `GDFileManager.default` for sensitive operations
- `FileHandle` replaced with `GDFileHandle`
- Streams replaced with `GDCReadStream`/`GDCWriteStream`
- Sensitive `UserDefaults` migrated to secure storage
- No leftover `UserDefaults` copy helper (`18-fresh-dynamics-install.md`)
- Temp file patterns addressed
- No generated dependency on `GDFileManager.default.temporaryDirectory`
- Secure temp runtime probe result recorded (pass/fail with fallback TODOs if needed)
- Build verification result

See `40-secure-storage-filesystem.md` for the full steering reference.

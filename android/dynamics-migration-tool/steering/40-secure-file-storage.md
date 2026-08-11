# Steering: Secure File Storage (Canonical Guide)

> **Canonical source** for all filesystem migration steering in this kit.
> Consolidates content from the former `40-secure-storage-filesystem.md`,
> `40a-stream-layer-closure.md`, `43-storage-layout-redesign.md`, and
> file-storage sections of `46-native-ndk-direct-replacement.md`.
>
> **Related but separate domains (not covered here):**
> - SQL / Room → `41-secure-storage-sql.md`
> - SharedPreferences → `42-secure-storage-sharedpreferences.md`
> - API replacement catalog → `14-api-provenance-and-replacement-catalog.md`

> **Multi-module note**: `app/build.gradle` and `app/src/main/...`
> references below are canonical-shape illustrations. Operationally:
> filesystem writers/readers commonly live in `core/data` or
> `feature/<x>/data` library modules — scan `${in_scope_main_src}`
> from `dynamics-migration-tool/output/module-map.json`. CameraX and
> similar library dependencies live in `${primary_build_file}`. See
> `04-multi-module-projects.md`.

---

## 1. Discovery Phase (MANDATORY)

### 1a. Java / Kotlin file I/O

Find all usages of:
- `java.io.File`, `java.io.FileInputStream`, `java.io.FileOutputStream`
- `Context.openFileOutput()` / `Context.openFileInput()`
- `getFilesDir` / `getCacheDir`
- External storage directories (`getExternalStorageDirectory`,
  `getExternalFilesDir`, `getExternalCacheDir`, `getExternalFilesDirs`)
- `File.createTempFile()`
- MediaStore writes, FileProvider sharing

Extend the inventory with the full **stream-layer anti-pattern list** (§5).
These compile cleanly against either `java.io.File` or
`com.good.gd.file.File` and silently bypass the secure container:

- Kotlin `kotlin.io.*` extensions: `writeText`, `readText`, `appendText`,
  `writeBytes`, `readBytes`, `appendBytes`, `forEachLine`, `readLines`,
  `useLines`, `bufferedReader()`, `bufferedWriter()`, `printWriter()`,
  `inputStream()`, `outputStream()`, `copyTo`, `copyRecursively`.
- JDK helpers: `java.nio.file.Files.*`, `FileReader`, `FileWriter`,
  `PrintWriter(File)`, `Scanner(File)`, `RandomAccessFile`.
- Image / serialization sinks bound to a path: `BitmapFactory.decodeFile`,
  `Bitmap.compress(…, FileOutputStream)`, `ObjectInputStream` /
  `ObjectOutputStream` over `java.io.File*Stream`, `Properties.load`,
  `ZipFile(File|String)`.

### 1b. Native (NDK / C / C++) file I/O

For every in-scope module from `module-map.json`, scan for:

1. Native source files (`*.c`, `*.cc`, `*.cpp`, `*.cxx`, `*.h`, `*.hpp`)
   under `src/main/` (excluding `src/test/` and `src/androidTest/`).
2. Build configuration: `CMakeLists.txt`, `Android.mk`, `Application.mk`,
   and `externalNativeBuild` blocks in `build.gradle(.kts)`.
3. JNI loading: `System.loadLibrary("…")` and `System.load("…")`.
4. Prebuilt artifacts: `src/main/jniLibs/<abi>/lib*.so` and any `*.so`
   referenced from `CMakeLists.txt` via `add_library(... IMPORTED)`.

Record discoveries in `migration-analysis.json` so prompts `05a`, `05b`,
`05c`, and `06` can act on them.

---

## 2. Classification Rules

### 2a. Storage-surface rule

Classify file-storage behavior by the **API surface**, not by filenames,
paths, or identifier text:
- **Dynamics container APIs** (`com.good.gd.file.*`, `GDFileSystem`) are the
  target steady-state storage surface.
- **Android filesystem APIs** (`java.io.File*`, `getFilesDir()`,
  `getCacheDir()`, `openFileOutput()`, etc.) are migration debt until
  removed, redesigned, or explicitly domain-deferred.
- **External/public storage APIs** remain non-waivable security blockers.

The validator does not infer "this path looks sensitive" from words such as
`auth`, `media`, `export`, or `cache`. A storage flow is in-scope because of
the API used to persist it.

### 2b. Native artifact classification

Each native artifact falls into exactly one bucket:

1. **App-controlled native source** — `.c`/`.cpp` committed to the repo
   that the developer can edit. Direct replacement applies using the
   Dynamics C API mapping in
   `14-api-provenance-and-replacement-catalog.md`.

2. **Prebuilt native libraries** — `*.so` under `src/main/jniLibs/` or
   `IMPORTED` CMake targets with no in-repo source. Must become a
   high-priority `manualTodo` in `migration-analysis.json` and
   `migration-report.json`, and listed in `unsupportedFeatures`.

3. **Vendored third-party source** — native source copied from an
   upstream project. Treat like prebuilt unless the developer attests
   they will patch and maintain it.

---

## 3. Canonical Migration Pattern (Java / Kotlin)

### Import changes

```java
// REMOVE
import java.io.FileInputStream;
import java.io.FileOutputStream;

// ADD — [BB_DYNAMICS-MIGRATION]
import com.good.gd.file.FileInputStream;
import com.good.gd.file.FileOutputStream;
import com.good.gd.file.GDFileSystem;
```

**Unchanged imports (no Dynamics equivalents needed):**
```java
import android.content.Context;
import java.io.BufferedReader;
import java.io.InputStreamReader;
```

### Call-site substitution (source: SDK sample)

```java
// BEFORE (native Android)
FileOutputStream out = getContext().openFileOutput(FILENAME, Context.MODE_PRIVATE);
FileInputStream  in  = getContext().openFileInput(FILENAME);

// AFTER (Dynamics secure container) — [BB_DYNAMICS-MIGRATION]
FileOutputStream out = GDFileSystem.openFileOutput(FILENAME, Context.MODE_PRIVATE);
FileInputStream  in  = GDFileSystem.openFileInput(FILENAME);
```

The migration creates **zero net new lines** for the typical named-file
case. Any "migration" that adds an anchor line and leaves `java.io.*` at
the call sites is a scaffolding pattern and must be reworked.

### Forbidden scaffold patterns — do NOT produce these

```java
// FORBIDDEN: class-literal anchor — imports GDFileSystem but never calls it
Class<?> gdFsAnchor = GDFileSystem.class;

// FORBIDDEN: writing to standard sandbox after "migrating"
import com.good.gd.file.GDFileSystem;
...
return new java.io.FileOutputStream(target);   // still outside the container
```

### Path semantics (container-relative)

GD stream constructors must use **container-relative paths** — never
seeded from `getFilesDir()`, `getCacheDir()`,
`Environment.getExternalStorageDirectory()`, or any string derived from
`File#getAbsolutePath()` on a non-GD root.

```kotlin
// [NOT OK] WRONG — GD File typed, sandbox path seeded
val root = com.good.gd.file.File(context.filesDir.absolutePath)
val f    = com.good.gd.file.File(root, "documents/document.json")
f.writeText(json)                                                 // double anti-pattern

// [OK] CORRECT — container-relative, GD stream
val out = com.good.gd.file.FileOutputStream("documents/document.json")
out.use { it.write(json.toByteArray(Charsets.UTF_8)) }
```

---

## 4. `GDFileSystem` vs `com.good.gd.file.File` (API Surface)

`GDFileSystem` exposes **named container file** helpers that mirror Android
`Context` patterns (e.g. `openFileInput`, `openFileOutput`).

Do **not** invent static helpers such as `GDFileSystem.mkdirs(path)`,
`GDFileSystem.exists(path)`, `GDFileSystem.delete(path)`,
`GDFileSystem.listDir(path)` — they are a common agent hallucination and
**will not compile**.

For path-style operations (ensure parent directories, test existence,
delete, list children), use **`com.good.gd.file.File`**:

```java
// [BB_DYNAMICS-MIGRATION] — path operations on the secure container
com.good.gd.file.File dir = new com.good.gd.file.File(path);
if (!dir.exists()) {
    dir.mkdirs();
}
com.good.gd.file.File target = new com.good.gd.file.File(dir, "capture.jpg");
```

Use `new com.good.gd.file.FileInputStream(com.good.gd.file.File)` /
`new com.good.gd.file.FileOutputStream(...)` for stream constructors on
GD `File` instances. The validator treats `new java.io.FileInputStream` /
`new java.io.FileOutputStream` against secured data paths as failures.

Kotlin constructor calls are equally valid when they resolve to the Dynamics
imports:

```kotlin
import com.good.gd.file.FileInputStream
import com.good.gd.file.FileOutputStream

FileOutputStream("logs/app.log").use { out ->
    out.write("hello".toByteArray())
}
```

The validator treats `FileOutputStream("...")` / `FileInputStream("...")` as
real Dynamics call-sites only when the imports or FQCN prove they resolve to
`com.good.gd.file.*`. Do not mix valid Kotlin constructors with hallucinated
`GDFileSystem.mkdirs(...)` helpers.

---

## 5. Stream-Layer Closure (Non-Negotiable)

> **Invariant**: A GD-typed `File` handle (`com.good.gd.file.File`) does
> **not** make I/O secure. Whether bytes flow through the Dynamics container
> is decided by the **stream constructor / helper actually used**, not by
> the `File` type that names them.

### Kotlin `File` extensions are compile-time traps

`com.good.gd.file.File` extends `java.io.File`, so Kotlin extensions on
`java.io.File` can resolve and compile on GD `File` receivers. Compile success
or a green type check is not proof of secure-container I/O.

For any `secureFileStorage` call site, migration is complete only when the
actual stream/helper is GD-backed (`com.good.gd.file.FileInputStream`,
`com.good.gd.file.FileOutputStream`, `GDFileSystem.openFileInput`,
`GDFileSystem.openFileOutput`, or `SecureFileIO.*` wrapping those APIs).

Bad (compiles, not migrated):

```kotlin
val f = com.good.gd.file.File("documents/document.json")
val text = f.readText()
f.writeBytes(payload)
f.deleteRecursively()
```

Good (migrated):

```kotlin
val f = com.good.gd.file.File("documents/document.json")
val text = SecureFileIO.readText(f)
SecureFileIO.writeBytes(f, payload)
SecureFileIO.deleteRecursively(f)
```

### 5a. Mandatory rule

Every read or write of a file under the `secureFileStorage`
execution-plan entry MUST go
through one of:

- `com.good.gd.file.FileInputStream` / `com.good.gd.file.FileOutputStream`
  constructors directly,
- `com.good.gd.file.GDFileSystem.openFileInput` /
  `GDFileSystem.openFileOutput`, or
- a repo-level helper (e.g. `SecureFileIO` from
  `templates/file/SecureFileIO.{kt,java}`) wrapping one of the above
  exclusively.

The receiver's *static type* (`com.good.gd.file.File` vs `java.io.File`)
is irrelevant. What matters is the constructor name resolved at the call
site.

### 5b. Forbidden on container paths (even when the receiver is GD-typed)

These compile (often with no warnings), but route I/O outside the secure
container or otherwise bypass the intended GD stream layer.

**Kotlin `kotlin.io.*` extensions on `File`:**
- `writeText`, `readText`, `appendText`
- `writeBytes`, `readBytes`, `appendBytes`
- `forEachLine`, `readLines`, `useLines`
- `bufferedReader()`, `bufferedWriter()`, `printWriter()`
- `inputStream()`, `outputStream()`
- `copyTo`, `copyRecursively`
- `deleteRecursively` (unless replaced by an explicit GD-aware recursive
  delete helper)

**JDK helpers:**
- `java.nio.file.Files.newInputStream`, `Files.newOutputStream`
- `Files.readAllBytes`, `Files.write`
- `Files.newBufferedReader`, `Files.newBufferedWriter`
- `Files.readString`, `Files.writeString`, `Files.lines`
- `new java.io.FileReader(File|String)`
- `new java.io.FileWriter(File|String)`
- `new java.io.PrintWriter(File|String)`
- `new java.util.Scanner(File)`
- `new java.io.RandomAccessFile(File|String, String)` against container paths

**Image / serialization sinks bound to a path:**
- `BitmapFactory.decodeFile(path)`
- `Bitmap.compress(format, quality, new java.io.FileOutputStream(path))`
- `new ObjectInputStream(new FileInputStream(path))` /
  `new ObjectOutputStream(new FileOutputStream(path))` against container paths
- `Properties.load(new FileInputStream(...))`
- `new ZipFile(File|String)` over a container path
- `FileChannel` / `transferTo` / `transferFrom` on GD streams

### 5c. Library-consumed `File` arguments are hidden `java.io` sites

When application code hands a `java.io.File` (or a string path) to a
third-party or platform library API, the library typically constructs a
`java.io.FileInputStream` or `java.io.FileOutputStream` against that path
*inside its own classes*. The Dynamics container is bypassed even when the
argument is statically `com.good.gd.file.File`.

Changing the static type of the argument from `java.io.File` to
`com.good.gd.file.File` is **not** a migration.

**Three closure paths** for every such library API:

1. **Stream/InputStream/OutputStream overload.** Replace the
   `File`-accepting API with an overload that accepts a stream backed by
   `com.good.gd.file.*`.
2. **Non-file API.** Replace with a library API that avoids files entirely.
3. **Domain deferral.** Defer `secureFileStorage` in
   `bootstrap.json.deferredDomains[]` via `fail_or_defer`.

`validate.sh` Phase 4 rule 4H enforces detection:

| Library API | Sub-rule | Closure path |
|---|---|---|
| `ImageCapture.OutputFileOptions.Builder(File)` | 4H.camerax | (1) or (2) |
| `new MediaMuxer(String\|File, format)` | 4H.mediamuxer | (1) via `FileDescriptor`; manual intervention / `no-go` otherwise |
| `MediaRecorder.setOutputFile(path\|file)` / `setNextOutputFile(path\|file)` | 4H.mediarecorder | redesign to memory / stream / descriptor import; manual intervention if unmanaged path is unavoidable |
| `new ZipFile(File\|String)` | 4H.zipfile | (1) via `ZipInputStream` / `ZipOutputStream` |
| `new ExifInterface(File\|String)` | 4H.exifinterface | (1) for read; (3) for write (`saveAttributes()`) |
| `ParcelFileDescriptor.open(File, mode)` for `PdfRenderer` | 4H.pdfrenderer | (1) via pipe/`MemoryFile`; (3) otherwise |

**Already covered by existing rules (not duplicated under 4H):**

| API shape | Existing rule |
|---|---|
| `new ObjectInputStream(new FileInputStream(path))` / `ObjectOutputStream` | 4A (raw `java.io.FileInputStream`) |
| `Properties.load(new FileInputStream(...))` | 4A |
| `new RandomAccessFile(File\|String, String)` | 4D (`jdkReaderWriter`) |
| Glide/Picasso/Coil `.load(File)` / `.load(path)` | Phase 4 image-loader rule |

### 5d. Canonical replacement table

| Anti-pattern | Canonical Dynamics replacement |
|---|---|
| `f.writeText(s)` / `f.writeText(s, charset)` | `com.good.gd.file.FileOutputStream(f.absolutePath).use { it.write(s.toByteArray(charset)) }` |
| `f.appendText(s)` | GD stream in append mode (`FileOutputStream(path, true)`) |
| `f.readText()` | `com.good.gd.file.FileInputStream(f.absolutePath).use { it.readBytes().toString(charset) }` |
| `f.writeBytes(b)` | `com.good.gd.file.FileOutputStream(f.absolutePath).use { it.write(b) }` |
| `f.readBytes()` | `com.good.gd.file.FileInputStream(f.absolutePath).use { it.readBytes() }` |
| `f.forEachLine { … }` / `f.readLines()` / `f.useLines { … }` | `BufferedReader(InputStreamReader(GD FileInputStream))` |
| `f.bufferedReader()` / `f.bufferedWriter()` / `f.printWriter()` | Wrap a GD stream with `InputStreamReader` / `OutputStreamWriter` |
| `f.inputStream()` / `f.outputStream()` | `com.good.gd.file.FileInputStream(…)` / `FileOutputStream(…)` |
| `f.copyTo(dst)` / `f.copyRecursively(dst)` | `SecureFileIO.copy(src, dst)` or a buffer loop over GD streams |
| `f.deleteRecursively()` | `SecureFileIO.deleteRecursively(f)` (GD-aware traversal: guard `exists()`, handle `listFiles()`, recurse children-first) |
| `BitmapFactory.decodeFile(p)` | `com.good.gd.file.FileInputStream(p).use { BitmapFactory.decodeStream(it) }` |
| `bmp.compress(fmt, q, java.io.FileOutputStream(p))` | `com.good.gd.file.FileOutputStream(p).use { bmp.compress(fmt, q, it) }` |
| `new FileReader(f)` | `InputStreamReader(com.good.gd.file.FileInputStream(f.absolutePath))` |
| `new FileWriter(f)` | `OutputStreamWriter(com.good.gd.file.FileOutputStream(f.absolutePath))` |
| `Files.readAllBytes(p)` | `com.good.gd.file.FileInputStream(p.toString()).use { it.readBytes() }` |
| `Files.write(p, b)` | `com.good.gd.file.FileOutputStream(p.toString()).use { it.write(b) }` |
| `Files.readString(p)` / `Files.writeString(p, s)` | GD stream + `toString(UTF_8)` / `toByteArray(UTF_8)` |
| `Properties.load(new FileInputStream(p))` | `com.good.gd.file.FileInputStream(p).use { props.load(it) }` |
| `new ObjectInputStream(new FileInputStream(p))` | `ObjectInputStream(com.good.gd.file.FileInputStream(p))` |
| `new ObjectOutputStream(new FileOutputStream(p))` | `ObjectOutputStream(com.good.gd.file.FileOutputStream(p))` |
| `ImageCapture.OutputFileOptions.Builder(file)` | `Builder(outputStream)` with `outputStream = new com.good.gd.file.FileOutputStream(…)`, or `OnImageCapturedCallback` for EXIF |
| `new ZipFile(file or path)` (read) | `new ZipInputStream(new com.good.gd.file.FileInputStream(path))` |
| `new ZipOutputStream(new java.io.FileOutputStream(path))` (write) | `new ZipOutputStream(new com.good.gd.file.FileOutputStream(path))` |
| `new ExifInterface(file or path)` (read) | `new ExifInterface(new com.good.gd.file.FileInputStream(…))` |
| `new ExifInterface(file or path)` + `saveAttributes()` (write) | Decode through GD `FileInputStream`, modify, re-encode through GD `FileOutputStream`. **No in-place EXIF write.** |
| `new MediaMuxer(file or path, format)` | `new MediaMuxer(fd, format)` where `fd` is GD-backed. If unavailable, defer via `fail_or_defer "secureFileStorage"` |
| `ParcelFileDescriptor.open(file, mode)` for `PdfRenderer` | `ParcelFileDescriptor.createPipe()` or `MemoryFile` fed from GD `FileInputStream` |
| `gdStream.getChannel()` / `transferFrom` / `transferTo` | Read/write `byte[]` or copy with a buffer loop on the GD stream |
| `Glide.load(File)` / `.load(path)` for container-backed files | `Glide.load(byte[])` or custom `ModelLoader` over `InputStream` from GD APIs |

Prefer `SecureFileIO` helpers (template at
`templates/file/SecureFileIO.{kt,java}`) — they collapse many rows above
into a single auditable call.

### 5e. Worked example — `saveMetadata` / `loadMetadata`

**Anti-pattern (compiles, validates green on type-only checks, crashes at runtime):**

```kotlin
class Repository(private val container: com.good.gd.file.File) {
    fun saveMetadata(meta: Metadata) {
        val f = com.good.gd.file.File(container, "documents/document.json")
        f.parentFile?.mkdirs()
        f.writeText(Json.encodeToString(meta))   // [NOT OK] kotlin.io on GD File
    }
    fun loadMetadata(): Metadata? {
        val f = com.good.gd.file.File(container, "documents/document.json")
        if (!f.exists()) return null
        return Json.decodeFromString(f.readText())   // [NOT OK] kotlin.io on GD File
    }
}
```

**Canonical (GD stream layer):**

```kotlin
import com.good.gd.file.FileInputStream
import com.good.gd.file.FileOutputStream

class Repository {
    fun saveMetadata(meta: Metadata) {
        com.good.gd.file.File("documents").apply { if (!exists()) mkdirs() }
        FileOutputStream("documents/document.json").use { out ->
            out.write(Json.encodeToString(meta).toByteArray(Charsets.UTF_8))
        }
    }
    fun loadMetadata(): Metadata? {
        val gdFile = com.good.gd.file.File("documents/document.json")
        if (!gdFile.exists()) return null
        return FileInputStream("documents/document.json").use { input ->
            Json.decodeFromString(input.readBytes().toString(Charsets.UTF_8))
        }
    }
}
```

Or, using `SecureFileIO`:

```kotlin
SecureFileIO.writeText("documents/document.json", Json.encodeToString(meta))
val raw = SecureFileIO.readText("documents/document.json") ?: return null
return Json.decodeFromString(raw)
```

### 5f. Tree operations (`deleteRecursively`) on GD paths

`deleteRecursively()` is a directory-tree operation, not a byte-stream helper,
but for secure-file-storage closure it is treated as migration debt unless
replaced with a GD-aware helper.

Why this still matters:

- The Kotlin call resolves through `java.io.File` interop, so the call can
  look migrated while hiding type/runtime mismatches.
- `com.good.gd.file.File.listFiles()` is exposed as `java.io.File[]`, and
  callers may need safe normalization back to `com.good.gd.file.File`.
- GD directory listing behavior differs from plain `java.io.File` in some
  failure cases (`listFiles()` may throw on non-existent paths).

Canonical replacement:

- Use `SecureFileIO.deleteRecursively(file)` (or equivalent helper) that:
  1. guards `exists()`,
  2. wraps `listFiles()` in defensive handling,
  3. normalizes child entries to `com.good.gd.file.File`,
  4. deletes children first, then parent.

---

## 6. Secure Container Prerequisites

Dynamics secure file APIs (`GDFileSystem`, `com.good.gd.file.*`) store
data inside the encrypted Dynamics container. The container is locked when
the app starts and only becomes accessible after `onAuthorized()`.

- On **first launch**, the container does not exist yet — the SDK must
  complete activation before any file can be read or written.
- On **subsequent launches**, the container is locked until the user
  authenticates. No file access is possible until then.
- Any call to `GDFileSystem.openFileInput()`, `GDFileSystem.openFileOutput()`,
  or Dynamics `FileInputStream`/`FileOutputStream` before the container is
  unlocked will throw `GDNotAuthorizedError` and crash the app.

**Fix**: Move all file I/O into `onAuthorized()` or a method called from
it. See `20-auth-initialization.md` for the full two-phase initialization
pattern.

### Utility functions that create directories

Apps commonly have utility functions like `getPrivateStorageDirectory()`
that create directories on first access. After migration, these use
`com.good.gd.file.File.mkdirs()`. If called during early initialization
(e.g. from a ViewModel `init {}` or an adapter constructor), they crash.

**Fix**: Add a static `isContainerAuthorized` guard inside the utility
function. Return the path reference regardless but only perform actual I/O
when authorized. See Pattern 7 in `21-authorization-deferral-patterns.md`.

---

## 7. Storage Layout Redesign

Some apps cannot reach Dynamics closure with import swaps alone. When
app data still flows through **public storage**, **MediaStore**,
**FileProvider** paths, or **`getExternalFilesDir`** as the system of
record, the migration outcome is a **layout redesign**, not a line-by-line
API rename.

### When redesign is required

Tag call sites with `redesignPath` during prompt `00-analyze-app.md` when
any of these apply to business-critical data:

- `MediaStore` / `ContentResolver` for app-owned notes, attachments, exports
- `FileProvider` + `content://` URIs used as durable storage
- `getExternalFilesDir` / `Environment.getExternalStorage*` as canonical write root
- Backup/restore flows that rehydrate files outside the GD container

**ICC rule (strict):** AppKinetics file transfer must use paths **already
inside** the Dynamics secure container. If files still live in
the normal sandbox or public storage, **storage migration has failed** —
do not proceed with ICC file transfer until `secureFileStorage` is fully
closed.

### Canonical redesign outcomes

1. **In-container persistence (default)** — writers use
   `com.good.gd.file.FileOutputStream`, `GDFileSystem.openFileOutput`,
   etc.; readers use matching GD streams; paths are container-relative.
   For camera and media apps, this means a **managed in-container
   gallery**: secure media bytes, secure metadata/index rows, secure
   thumbnails, latest-preview state, and in-app gallery/grid/list views
   all backed by the Dynamics container rather than MediaStore or the
   public Gallery.

2. **SAF-boundary import/export** — Storage Access Framework at explicit
   user gestures only. Stream bytes in/out of the container in memory or
   via GD streams; do not persist public `content://` or filesystem paths
   as the source of truth.

3. **ICC egress (after data is in-container)** — `GDServiceClient.sendTo`
   attachment paths must be GD container paths. See
   `60-icc-transferfileservice.md`.

4. **Feature removal** — flow removed for DLP compatibility; record
   rationale in `migration-analysis.json` and disposition `removed`.

### Prompt 05a interaction model (implement first, ask only when stuck)

`externalStorage` remains a non-waivable security blocker and Phase 4
must stay strict. That hardening is the **acceptance gate**, not a
reason for the agent to give up without trying a viable redesign.

**Implementation-first rule**: The agent's default posture is to
**implement** the migration, not to flag findings and wait. A manual
developer confronted with `getExternalFilesDir()` or `MediaStore` writes
would not pause the project — they would replace the storage path with a
container-relative path, remove the public-export toggle, or restructure
the feature. The agent must do the same.

When prompt `05a-filesystem-core-io-migration.md` encounters
external-storage, `java.io.File`, `SharedPreferences`, or other
non-waivable findings, the agent **MUST**:

1. **Implement the fix immediately** using the cataloged replacement
   (see §5d canonical replacement table and
   `14-api-provenance-and-replacement-catalog.md`). For `java.io.File`
   construction, replace with `com.good.gd.file.File`. For
   `FileInputStream`/`FileOutputStream`, replace with the
   `com.good.gd.file` equivalents. For `getExternalFilesDir()` /
   `getExternalCacheDir()`, migrate to container-relative paths. For
   `SharedPreferences` persistence, implement
   `SecurePreferencesHelper` (see `42-secure-storage-sharedpreferences.md`).
2. **For features that cannot use a drop-in replacement** (e.g.,
   "Save to SD card," public Gallery export, `MediaStore` writes),
   implement the best redesign from §7:
   - `in-container` — move storage into the GD container,
   - `feature-removal` — delete the public-storage toggle and UI,
   - `saf-boundary` — blocked outbound SAF export by default, re-enabled
     only after explicit developer approval and verified runtime DLP.
   Briefly inform the developer which redesign was applied and why.
3. **Re-run scoped validation** after each batch of changes to confirm
   findings are resolved.
4. **Only ask the developer** when a genuine ambiguity exists: e.g.,
   the feature serves a core user-visible purpose and both
   `in-container` and `feature-removal` are viable but have different
   UX trade-offs. In that case, present the two options and ask which
   to implement — then implement immediately.
5. **Continue to the next domain** even if one call site remains
   unresolved. A single FD-only media writer that cannot be
   container-safe is a `manualTodos[]` entry, not a reason to abandon
   the entire file-storage migration or halt all subsequent prompts.

For SAF redesigns, persist developer decisions in
`migration-plan-state.json` `dispositions[].safDecision`. Do **not**
invent a new `bootstrap.json` field for redesign approval.

If a specific call site truly cannot be resolved after exhausting all
five steps in `steering/00-context.md` §Implementation-first, record it
in `manualTodos[]` with `severity: "P1"` and `blocking: true`, and **do not add a final
disposition** for that call site. `manual-intervention` is not a valid
`migration-plan-state.json` status. The call site must later be
resolved, removed, or covered by a developer-signed domain deferral
before 05c closure can pass. Continue to the next call site and the next
prompt; the validator severity does **not** change.

### Media-safe redesign patterns

When the app captures, previews, indexes, or exports media, apply these
patterns in order:

1. **Keep app-owned media in the container.** Secure storage is the
   system of record. Do not restore MediaStore or the Android Gallery as
   the canonical index for app-owned content.
2. **Prefer direct stream or bounded-memory copy.** Use `InputStream`,
   `OutputStream`, or bounded byte-array buffers to move bytes directly
   into `com.good.gd.file.*`. Generate thumbnails in memory and persist
   them into secure storage.
3. **Use controlled export only.** Public save/share behavior must be an
   explicit user action, documented as an export boundary, and reviewed
   under DLP policy. It is not evidence that secure storage migration is
   complete.
4. **Disable unmanaged capture-provider behavior when necessary.**
   `ACTION_IMAGE_CAPTURE`, `ACTION_VIDEO_CAPTURE`, `IMAGE_CAPTURE_SECURE`,
   and caller `MediaStore.EXTRA_OUTPUT` flows must be removed, narrowed,
   or escalated to manual intervention when they let unmanaged callers
   dictate output locations outside the container.

### Rejected media fallbacks

The migration agent must explicitly reject these patterns for app-owned
media and container-bound file flows:

- write to the container, then auto-copy to public MediaStore;
- accept caller `MediaStore.EXTRA_OUTPUT` and write capture bytes there;
- use `MediaScannerConnection` to restore public Gallery visibility;
- stage app-owned media in `getCacheDir()`, `getFilesDir()`, or
  `File.createTempFile(...)` as the default workaround;
- use normal Android filesystem paths for `MediaRecorder` output unless a
  product/security decision explicitly accepts manual intervention and
  the report remains `no-go`;
- mark `coverage.secureFileStorage.status` as `"migrated"` while any
  `filesDir`/`cacheDir`/`openFileOutput` staging remains for media
  capture, playback, or export (see "FD-only media writer outcomes"
  above);
- treat public Gallery compatibility as proof of migration success.

### FD-only media writer outcomes (MediaRecorder / MediaMuxer)

Some platform media APIs (`MediaRecorder.setOutputFile`,
`MediaMuxer(FileDescriptor, format)`, `ParcelFileDescriptor`-backed
capture writers) require a native file descriptor or seekable path that
the Dynamics container cannot directly supply. When the migration
replaces public storage with a `FileDescriptor` obtained from **app-private
storage** (`getFilesDir()`, `getCacheDir()`, `openFileOutput()`, or
`File.createTempFile()`), the media bytes still leave the secure container
during capture and reside in unencrypted sandbox storage until an
explicit import-then-delete step copies them into the GD container.

This **private staging** pattern is functionally necessary for some apps
but is **not** equivalent to a clean `secureFileStorage` migration:

- Data is unencrypted at rest during the staging window.
- The staging file survives process death, ANR kills, and crash loops.
- A remote container wipe does **not** clear the staging directory.
- `validate.sh` Phase 4 `PRIVATE_SANDBOX_STAGING_HITS` fails on this
  pattern and it cannot be silenced by deferral alone.

#### Decision tree for FD-only media writers

1. **Container-safe stream/descriptor path exists?**
   If the platform API accepts an `OutputStream`, a pipe-backed
   `FileDescriptor`, or a `ParcelFileDescriptor.createPipe()` whose
   write end is fed from a GD stream, use that path. Mark the call
   site `migrated`.

2. **No container-safe path exists — redesign feasible?**
   Replace the platform writer with an in-memory or bounded-buffer
   architecture (e.g., `OnImageCapturedCallback` for photo capture,
   chunked `OutputStream` for video where the codec supports it).
   Mark the call site `migrated`.

3. **No container-safe path, no feasible redesign?**
   The call site must remain without a final disposition (not
   `migrated` or `removed`) until resolved or domain-deferred. The
   migration report must:
   - set `coverage.secureFileStorage.status` to `"partial"`,
   - add the call site to `manualTodos[]` with `severity: "P1"`,
     `blocking: true`, and a title naming the blocked API and affected feature,
   - explain in `securityPosture.dataAtRest.summary` that media
     staging leaves the container during capture,
   - keep `releaseReadiness.recommendation` at `"no-go"` while the
     product/security decision is pending.

   `filesDir`/`cacheDir` staging is **not** an accepted default
   migration outcome. It is a runtime workaround that must be surfaced
   as residual risk, not hidden behind a clean closure status.

#### FD provenance: sandbox-sourced descriptors are not GD-backed

When the 4H scanners pass a `FileDescriptor`-based call, they assume
the descriptor comes from a GD-backed source. Phase 4 rule 4I
(`fd-media-sandbox-provenance`) adds a second-pass check: if the same
file contains both a `FileDescriptor`-accepting media writer **and** a
sandbox path derivation (`getFilesDir`, `getCacheDir`, `openFileOutput`,
`createTempFile`, `ParcelFileDescriptor.open`), the call site is flagged
as `fail_or_defer "secureFileStorage"`. The developer must either
eliminate the sandbox staging or defer the whole `secureFileStorage`
domain with a valid developer-signed entry.

### Layout redesign closure (prompts 05a / 05c)

Before recording prompt `05c` as `completed`:

1. Storage layout redesign decision documented in
   `migration-plan-state.json` notes or `migration-analysis.json`
   rationale when `redesignPath` applied.
2. Every applicable `secureFileStorage` call site is `migrated` | `removed`,
   domain is `not-applicable`, or developer signed a valid
   `deferredDomains[]` entry.
3. No new `java.io.File` staging helpers for ICC (prompt 08 blocked until
   storage closed).

---

## 7a. Secure Container Save Pattern (Write-Read Round-Trip Continuity)

When migrating a user-facing **Save**, **Download**, or **Export** feature
that previously wrote to external storage (MediaStore, SAF, Downloads,
`getExternalStoragePublicDirectory`), simply removing the external write
path is **not** sufficient. The feature must be replaced end-to-end so the
user can still find and open saved files.

Failure to maintain the write-read round trip produces a **silent data
loss** scenario: the app reports success ("Saved to Downloads") but the
file is unreachable — it either lives in a cache path subject to cleanup,
or the stored file reference is `Uri.EMPTY` / an invalid path that no
reader can resolve.

### 1. Identify the write-read round-trip

For each external write path being removed, trace the complete data flow:

- **WHERE** was the file written? (MediaStore, SAF directory, Downloads,
  `getExternalStoragePublicDirectory`)
- **WHAT reference** was stored? (`content://` URI, file path, filename)
- **WHERE** was the reference stored? (DataStore, Room, SharedPreferences,
  in-memory list, protobuf)
- **HOW** was the file later retrieved? (`ContentResolver.openInputStream`,
  `DocumentFile`, `java.io.File`, URI resolution)
- **WHAT UI** showed the saved state? (success message, recent documents
  list, file browser, share sheet)

### 2. Design the container-side equivalent

- Use a **permanent** container path (e.g., `/data/saved-documents/`),
  **NOT** a cache path
- Cache paths (`/cache/*`) may be cleaned up by the app's own cleanup logic
  or evicted under storage pressure — saved user documents must survive
- Generate a `file://` URI from the container path for storage in data
  stores:
  ```java
  com.good.gd.file.File saved = new com.good.gd.file.File("data/saved-documents/report.pdf");
  // Store this URI in DataStore / Room
  Uri savedUri = Uri.parse("file://" + saved.getAbsolutePath());
  ```
- **Never** store `Uri.EMPTY` or `Uri.parse("")` as a file reference — this
  is a data loss indicator that the write path was removed without
  implementing the container-side equivalent

### 3. Update all reference consumers

- **DataStore / Room / SharedPreferences**: store the new `file://`
  container URI instead of the old `content://media/…` URI
- **Retrieval logic**: resolve `file://` URIs via
  `com.good.gd.file.File(path).exists()` — do not use
  `ContentResolver.openInputStream` for container paths
- **Recent documents / file lists**: verify existence with GD File API
  before displaying entries — stale references from pre-migration data
  may point to paths that no longer exist
- **UI text**: replace "Downloads", "Save to Downloads", "Saved to SD Card"
  with "Secure Documents" or equivalent phrasing that reflects container
  storage
- **"Open" action**: use an in-app viewer or ICC (`GDServiceClient.sendTo`)
  to deliver the file to another Dynamics app — do **not** use
  `ACTION_VIEW` with a `file://` container URI (external apps cannot read
  from the Dynamics container)

### 4. Protect permanent saves from cleanup

If the app has cleanup / cache-eviction logic (e.g., `cleanUpOldFiles`,
`clearTemporaryData`, session-end cleanup), ensure it targets **ONLY** the
cache / preparation directory, **NOT** the permanent save directory.

A cache cleanup sweep that accidentally deletes `/data/saved-documents/`
has the same effect as the original bug: user data silently disappears.

### 5. Validator enforcement

`validate.sh` Phase 4 detects a broken save round-trip via an
API-anchored indicator:

- **`Uri.EMPTY` / `Uri.parse("")` in persistent data stores** (rule 4K):
  These are placeholder URIs that will never resolve to a file. Their
  presence indicates a save path was removed without implementing the
  container-side equivalent.

Updating stale UI copy ("Downloads", "SD Card", "Save to …") after an
`externalStorage` migration is a **manual review** item, not a validator
rule. UI string text carries no API signal, so the validator does not
keyword-scan resources for it — confirm and reword such strings as part of
the storage migration walkthrough above.

---

## 8. Native (NDK) File Access

Native file calls go through the same Dynamics secure container as
Java/Kotlin. Use the canonical tables in
`14-api-provenance-and-replacement-catalog.md`.

### Direct-replacement rules

| Standard C / POSIX | Dynamics C API |
|---|---|
| `fopen` / `fclose` / `fread` / `fwrite` / `fseek` / `ftell` / `fflush` | `GD_fopen` / `GD_fclose` / `GD_fread` / `GD_fwrite` / `GD_fseek` / `GD_ftell` / `GD_fflush` |
| `remove` / `rename` | `GD_remove` / `GD_rename` |
| `open` / `close` / `read` / `write` / `lseek` | `GD_UNISTD_open` / `GD_UNISTD_close` / `GD_UNISTD_read` / `GD_UNISTD_write` / `GD_UNISTD_lseek` |
| `unlink` / `rmdir` | `GD_UNISTD_unlink` / `GD_UNISTD_rmdir` |
| `mkdir` | `GD_mkdir` |
| `opendir` / `readdir` / `closedir` | `GD_opendir` / `GD_readdir` / `GD_closedir` |
| `stat` / `fstat` | `GD_stat` / `GD_UNISTD_fstat` |

**Do not** prefix directory or stdio APIs with `GD_UNISTD_` — there is no
`GD_UNISTD_mkdir` / `GD_UNISTD_opendir` in the shipped headers. If a
POSIX call has no documented equivalent, **do not invent one** — record a
manual TODO and mark the call site unsupported.

### Include path

Add the Dynamics C headers to the native build's include path. The install
path is `sdk/libs/handheld/libs/gd/inc/`. In a CMake module, add the
resolved path to `target_include_directories` and link the Dynamics native
library.

| Header (installed) | POSIX / C family |
|---|---|
| `GD_C_FileSystem.h` | stdio, `mkdir`, `opendir`, `stat` — plain `GD_*` names |
| `GD_C_unistd.h`, `GD_C_sys_stat.h` | fd I/O — `GD_UNISTD_*` names |

Verify each replacement in the **installed** headers or the public
[C API documentation](https://developer.blackberry.com/files/blackberry-dynamics/android/capi.html).

### Native path semantics

Pass **container-relative paths** to `GD_fopen` / `GD_UNISTD_open` — the
same rule as Java GD streams. Never pass `/data/data/<pkg>/files`-rooted
or external-storage absolute paths.

### Native validator routing

`validate.sh` flags native file/POSIX storage calls as
`fail_or_defer "secureFileStorage"` violations. Prebuilt `.so` files and
`System.loadLibrary` calls without in-repo source produce `check_warn`
(manual TODO candidate) — they do not auto-close any domain.

---

## 9. External Storage — SECURITY BLOCKER (non-waivable)

> **Doctrine:** External-storage usage in a Dynamics-migrated app is
> **security-critical** and **non-waivable**. The migration agent must
> either migrate every external-storage call-site into the Dynamics
> secure container or remove the feature. Silently deferring external
> storage is forbidden and is rejected by the validator (`externalStorage`
> is on the non-waivable domain list in `tooling/validate.sh` and Phase 0
> rejects deferral entries naming `externalStorage`). Phase 4 emits a
> `[SECURITY-BLOCKER][externalStorage/api-surface]` `check_fail` for any
> remaining hit; Phase 10 re-emits these blockers and forces prompt 10's
> `releaseReadiness.recommendation` to `no-go`.

### Why external storage is non-waivable

Application data written to any of the surfaces below leaves the
Dynamics secure container. The data is then:

- **unencrypted at rest** — the on-disk Dynamics encryption only
  applies to container paths;
- **included in device backups** (cloud / local) regardless of
  `android:allowBackup=false` on the Dynamics app, because other apps
  and the platform itself back up shared storage;
- **readable by any app** holding `READ_EXTERNAL_STORAGE`,
  `MANAGE_EXTERNAL_STORAGE`, or the appropriate scoped-storage
  permission;
- **accessible over USB / MTP / file manager UI**;
- **NOT cleared by remote container wipe** — a UEM admin who wipes
  the Dynamics container leaves this data on the device;
- **NOT covered by Dynamics DLP** (copy/paste, screenshot, take-photo
  policies do not apply to data the OS treats as user-shared).

That set of properties directly contradicts the BlackBerry Dynamics
data-at-rest contract that enterprise customers rely on. Allowing the
migration agent to mark this as "deferred for follow-up" would let an
app ship with a silent data-exfiltration path that looks green in the
report.

### Surfaces that always fail (Phase 4)

| Surface ID                                   | Examples                                                                                                                                 |
|----------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| `externalStorage/high-level-apis`            | `Environment.getExternalStorageDirectory`, `Environment.getExternalStoragePublicDirectory`, `Environment.DIRECTORY_DOWNLOADS / PICTURES / DOCUMENTS / MOVIES / MUSIC / DCIM / ...`, `Context.getExternalFilesDir`, `Context.getExternalFilesDirs`, `Context.getExternalCacheDir`, `Context.getExternalMediaDirs` |
| `externalStorage/mediastore-writes`          | Any `ContentResolver.insert / update / delete` targeting `MediaStore.{Images,Video,Audio,Downloads,Files,Documents}.EXTERNAL_CONTENT_URI`, plus `MediaStore.createWriteRequest / createDeleteRequest / createTrashRequest`                                                                              |
| `externalStorage/raw-paths`                  | String literals beginning `"/sdcard/"`, `"/storage/emulated/"`, `"/storage/self/"`, `"/mnt/sdcard/"`, `"/storage/<volume>/Downloads"`, `".../Pictures"`, `".../Documents"`, `".../DCIM"`, `".../Movies"`, `".../Music"`                                                                                                       |
| `externalStorage/saf-doc-tree`               | `ACTION_OPEN_DOCUMENT_TREE`, `DocumentFile.fromTreeUri`, `DocumentsContract.buildChildDocumentsUriUsingTree / createDocument`, `takePersistableUriPermission` (persisted tree URIs imply repeated writes outside the container)                                                                                |

A single hit in any of these surfaces produces a hard fail tagged
`[SECURITY-BLOCKER]`. Surface counts are recorded individually in
`output/.security-blockers.log` so prompt 10 can transcribe them into
the migration report verbatim.

### Manifest follow-up (warn-only)

`WRITE_EXTERNAL_STORAGE`, `MANAGE_EXTERNAL_STORAGE`, and
`ACCESS_MEDIA_LOCATION` in `AndroidManifest.xml` are reported as a
warning so a fully-migrated app remembers to drop the now-unused
permission before UEM hardening review.

### What the migration agent MUST do

For every hit the agent must apply, in order of preference:

1. **Migrate to a container path.** Replace the external-storage write
   with `com.good.gd.file.File` / `com.good.gd.file.FileOutputStream`
   / `GDFileSystem` rooted at the GD container. See the catalog rows
   `fs-java-ext-001 .. fs-java-ext-005` in
   `14-api-provenance-and-replacement-catalog.md` for the canonical
   replacements.

2. **Remove the feature.** "Save to SD card", "Export to public
   Downloads", "Cache thumbnails to /sdcard/.../thumbs", and similar
   pre-Dynamics affordances are typically obsolete after migration —
   the secure container is the storage. Delete the toggle, the UI
   setting, and the writer; replace any external getter with the
   container getter (`getCurrentImagesDirectory(): File =
   getPrivateImagesDirectory()`).

3. **Replace with a secure export pattern.** If the feature is an
   intentional user-initiated *export* (e.g. user explicitly saves a
   PDF), it must still be migrated to one of:
   - **AppKinetics TransferFile** (`GDServiceClient.sendTo`) to deliver
     the payload to another Dynamics-managed app (BlackBerry Work,
     Docs, etc.) — see `60-icc-transferfileservice.md`.
   - **SAF-mediated user save with redaction**: the user picks a target
     via `ACTION_CREATE_DOCUMENT` (one-shot, no persisted tree URI)
     and the writer streams an explicitly user-acknowledged, redacted
     payload from the container through `ContentResolver.openOutputStream`.
     The agent must wrap the call-site with a `[BB_DYNAMICS-MIGRATION]`
     audit comment that justifies the export, AND the migration report
     must list the call-site under `manualTodos[]` with `blocking: true`
     so the developer signs off on the export boundary
     before shipping.

Whichever path is chosen, the **Phase 4 hit must be eliminated** — an
audit comment alone does not silence `security_blocker`. If the agent
cannot eliminate the hit, the migration is incomplete; prompt 10 must
record the residual call-sites under `releaseReadiness.blockingItems[]`
and the `releaseReadiness.recommendation` must be `"no-go"`.

### What the migration agent MUST NOT do

- **Do NOT** add `externalStorage` to `bootstrap.json.deferredDomains[]`
  (Phase 0 rejects it).
- **Do NOT** defer `secureFileStorage` and assume external storage
  follows — Phase 10 deliberately does not subtract the external
  storage count when `secureFileStorage` is deferred.
- **Do NOT** describe a remaining external-storage write as
  "intentional export boundary, deferred" in `manualTodos[]`. That
  phrasing was permitted by the 0.3.0 tool and is the exact
  failure mode that allowed public MediaStore / external-storage writes
  to ship under a "deferred export boundary" label. The
  current tool requires either elimination of the call-site or an
  explicit secure export pattern as above.
- **Do NOT** add `[BB_DYNAMICS-MIGRATION]` audit markers solely to
  filter the line out of `strip_audit_noise`; the marker is audit-only
  and Phase 4 still counts the line.

### How prompt 10 must report unresolved hits

When `output/.security-blockers.log` contains any
`externalStorage/*` row, the migration report MUST:

- set `releaseReadiness.recommendation` to `"no-go"`;
- copy each row into `releaseReadiness.blockingItems[]` with wording
  that names the surface and the count;
- emit one `manualTodos[]` entry per surface with `blocking: true`
  and a title that explicitly says "Manual intervention required
  before production use — external-storage usage breaks the Dynamics
  secure-container contract";
- set `securityPosture.dataAtRest.status` to `"partial"` (or
  `"unverified"` if the writer count is large), and explain in
  `securityPosture.dataAtRest.summary` that residual external-storage
  call-sites mean enterprise data can leave the container;
- if the report schema is at v2.1.0 or later, populate the optional
  `securityBlockers[]` top-level array (see
  `documentation/report-contract/schema-v2.1.0.md`).

### Private-only storage enforcement (recommended)

When UEM DLP policy prohibits storing enterprise data outside the container,
hardwire the app to internal-only storage. Remove external/internal toggle
logic and external storage UI settings:

```kotlin
// [NOT OK] BEFORE — toggle between external and internal
fun getCurrentImagesDirectory(): File {
    return if (useExternalStorage)
        getExternalImagesDirectory()
    else
        getPrivateImagesDirectory()
}

// [OK] AFTER — always internal
fun getCurrentImagesDirectory(): File = getPrivateImagesDirectory()
```

Make migration code (e.g. `moveAttachments(toPublic)`) a no-op rather than
deleting it, to avoid breaking callers.

### FileProvider path reconfiguration (MANDATORY after storage migration)

When migrating from external to internal storage, update
`res/xml/provider_paths.xml` to match the new directory structure:

```xml
<paths>
    <!-- [BB_DYNAMICS-MIGRATION] Internal attachment storage -->
    <files-path name="attachments" path="attachments/" />
</paths>
```

Replace `<external-files-path>` entries with `<files-path>` entries.
Otherwise `FileProvider` crashes with `IllegalArgumentException: Failed
to find configured root`.

---

## 10. Known Pitfalls

### `com.good.gd.file.File.listFiles()` can throw on non-existent directory

Unlike `java.io.File.listFiles()` (which returns `null`), GD may throw.
Always guard:

```kotlin
val gdDir = com.good.gd.file.File("exports")
if (!gdDir.exists()) return
gdDir.listFiles()?.forEach { it.delete() }
```

### `DocumentFile.fromFile()` with GD Container Paths

`DocumentFile.fromFile(gdFile)` produces a `file://` URI from the
GDFile's `absolutePath`. GD container-relative paths (e.g. `"/logs"`,
`"/attachments"`, `"/data"`) are virtual — they do not exist on the real
Android filesystem. The resulting URI (e.g. `file:///logs`) is invalid
for `ContentResolver` operations.

**Symptom:** `DocumentFile.createFile()` returns `null` or throws
`IllegalArgumentException`; `ContentResolver.openOutputStream()` throws
`FileNotFoundException`. This compiles cleanly, passes type checks, and
crashes deterministically at runtime.

**Fix:** Replace `DocumentFile`-based I/O with direct GD stream access
(`com.good.gd.file.FileInputStream` / `FileOutputStream`). Do not wrap
GD files with `DocumentFile.fromFile()`.

| Pattern | Status |
|---------|--------|
| `DocumentFile.fromFile(gdFile)` | **FORBIDDEN** on GD container paths |
| `DocumentFile.fromTreeUri(uri)` | SAF-only, unrelated to GD container |
| `DocumentFile.fromSingleUri(uri)` | SAF-only, unrelated to GD container |
| Direct GD `FileOutputStream` / `FileInputStream` | **REQUIRED** for container I/O |

**Anti-pattern (compiles, crashes at runtime):**

```kotlin
val logsDir = com.good.gd.file.File("logs")
val docFile = DocumentFile.fromFile(logsDir)
val logFile = docFile.createFile("text/plain", "app.log")
// CRASH: IllegalArgumentException — "file:///logs" is not a real path
```

**Canonical (GD stream layer):**

```kotlin
val logsDir = com.good.gd.file.File("logs")
if (!logsDir.exists()) logsDir.mkdirs()
com.good.gd.file.FileOutputStream("logs/app.log").use { out ->
    out.write(logMessage.toByteArray(Charsets.UTF_8))
}
```

### Nested GD directories: create ancestors root-first

For nested secure paths (for example `media/logs/app.log`), create each
ancestor directory explicitly in root-first order before opening the file.
Do not assume a single `mkdirs()` call on a deep path always succeeds.

```kotlin
val mediaDir = com.good.gd.file.File("media")
if (!mediaDir.exists()) mediaDir.mkdirs()
val logsDir = com.good.gd.file.File("media/logs")
if (!logsDir.exists()) logsDir.mkdirs()
```

### Secure logging must be best-effort

Logging failures must never abort schema/data migration paths. Wrap secure
log writes in `try/catch` and keep a fallback (`android.util.Log`) so
diagnostic code cannot turn into a launch blocker.

```kotlin
try {
    val out = com.good.gd.file.FileOutputStream("media/logs/migration.log", true)
    out.use { it.write((line + "\n").toByteArray(Charsets.UTF_8)) }
} catch (_: Exception) {
    android.util.Log.w("Migration", line)
}
```

`validate.sh` Phase 4 rule 4M emits `[FS-DOCFILE-001] FAILURE` when any
file importing `com.good.gd.file.*` also contains
`DocumentFile.fromFile`. This is non-waivable — the pattern always
produces invalid URIs on container paths.

### `com.good.gd.file.File.getParentFile()` returns `java.io.File`

```java
// [NOT OK] WRONG — getParentFile() returns java.io.File
File parent = target.getParentFile();  // Compile error

// [OK] CORRECT — use getParent() and construct new GD File
String parentPath = target.getParent();
if (parentPath != null) {
    File parent = new File(parentPath);
    if (!parent.exists()) parent.mkdirs();
}
```

### Third-party libraries cannot read from Dynamics secure container

**Affected**: Glide, Picasso, Coil, Fresco, and any library that accepts
`java.io.File` or constructs its own `InputStream`. Read file bytes into
memory first:

```java
InputStream in = fileStore.openForRead("thumbs/photo.jpg");
byte[] bytes = readAllBytes(in);
in.close();
Glide.with(context).load(bytes).into(imageView);
```

**Cascading scope warning:** this is required at every call site loading
images from the secure container (gallery adapters, fragments, detail
views, custom adapters). Audit all affected files before starting.

**Recommended:** create a shared `GDFileUtils.readToByteArray()` utility
before migrating individual adapters:

```java
public final class GDFileUtils {
    private GDFileUtils() {}

    @Nullable
    public static byte[] readToByteArray(SecureFileStore fileStore, String path) {
        try (InputStream in = fileStore.openForRead(path)) {
            if (in == null) return null;
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) {
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        } catch (Exception e) {
            return null;
        }
    }
}
```

### Memory implications for large images

Reading full-resolution photos into `byte[]` then passing to Glide holds
raw bytes AND decoded `Bitmap` simultaneously. Mitigations:

1. `BitmapFactory.Options.inSampleSize` to downsample thumbnails
2. Store pre-sized thumbnails separately from full-resolution files
3. Glide `override(width, height)` to cap decoded size

Once workarounds are implemented, do NOT list the library in
`unsupportedFeatures`. Document in `apisReplaced` instead.

### Partial store migration: writers in container, readers on platform paths

If only the persistence layer is migrated but reader code still targets
platform directories, the app writes into the container but reads from the
sandbox. The symptom is `ENOENT` / `FileNotFoundException`.

Treat writer and reader migration as a **single closure unit** for each
path domain (`thumbs`, `photos`, `exports`, etc.).

`validate.sh` Phase 4 must fail for domain-mismatch patterns where
Dynamics writes, cache/files-dir path builders, and file/loader readers
all reference the same domain but in different storage layers.

### CameraX and Dynamics secure container

Always use the **`OutputStream` builder** to write captured images
directly into the secure container:

```java
// [NOT OK] WRONG — writes unencrypted image to standard storage
java.io.File tempFile = java.io.File.createTempFile("capture_", ".jpg", context.getCacheDir());
ImageCapture.OutputFileOptions options =
    new ImageCapture.OutputFileOptions.Builder(tempFile).build();

// [OK] CORRECT — write directly to secure container
OutputStream secureOut = secureFileStore.openForWrite("media/photos/" + fileName);
ImageCapture.OutputFileOptions options =
    new ImageCapture.OutputFileOptions.Builder(secureOut).build();
```

`OutputFileOptions.Builder(OutputStream)` is available since CameraX
1.0.0-beta01. When using the `OutputStream` builder, CameraX does not
write EXIF metadata — use `OnImageCapturedCallback` for EXIF if needed.

**No file-based fallback** for capture paths that belong in the Dynamics container.
`File.createTempFile(...)` and temp-then-copy are not acceptable.
`validate.sh` treats `File.createTempFile(...)` as non-waivable.

### MediaRecorder and native media writers

`MediaRecorder.setOutputFile(...)` and `setNextOutputFile(...)` must not
default to Android sandbox, cache, files-dir, MediaStore, or public
filesystem staging for app-owned media.

Required decision order:

1. Look for a redesign that keeps bytes in memory, stream form, pipe
   form, or a descriptor path that can be imported into the secure
   container without unmanaged staging.
2. If the platform writer truly requires a normal filesystem path or a
   seekable native descriptor and no approved direct-secure pattern
   exists, mark the flow **manual intervention** and keep the migration
   report `no-go`.
3. Do **not** mark `coverage.secureFileStorage` as migrated while such a
   writer remains unresolved.

### Lambda capture of try-with-resources variables

Variables assigned inside `try-with-resources` are not effectively final.
When the decoded result is used in a lambda (`runOnUiThread`, `post()`,
observer callback), reassign to a final variable first:

```java
try (InputStream in = fileStore.openForRead("thumbs/" + photoId + ".jpg")) {
    Bitmap decoded = BitmapFactory.decodeStream(in);
    final Bitmap thumb = decoded;   // effectively final
    requireActivity().runOnUiThread(() -> imageView.setImageBitmap(thumb));
}
```

---

## 11. Validator Coverage

`validate.sh` Phase 4 fails when any pattern in §5b is found in
`${in_scope_main_src}` files that also import `com.good.gd.file.*`, or in
modules hosting a `secureFileStorage` call site. Prompts `05a` and `05b`
map to Phase 4 for optional `validate.sh --check-prompt` diagnostics; the
mandatory enforcement point is prompt `10` final source validation.

### Detection summary

| Rule | Label token | What it catches |
|---|---|---|
| 4A | `kotlinIoTextBytes` | `writeText`, `readText`, `appendText`, `writeBytes`, `readBytes`, `appendBytes`, `forEachLine`, `readLines`, `useLines` |
| 4B | `kotlinIoAccessor` | `bufferedReader()`, `bufferedWriter()`, `printWriter()`, `inputStream()`, `outputStream()` |
| 4C | `javaNioFiles` | `java.nio.file.Files.*` convenience methods |
| 4D | `jdkReaderWriter` | `FileReader`, `FileWriter`, `PrintWriter`, `Scanner`, `RandomAccessFile` |
| 4E | `bitmapDecodeFile` | `BitmapFactory.decodeFile(path)` |
| 4F | `bitmapCompressJavaIo` | `Bitmap.compress(…, new java.io.FileOutputStream)` |
| 4G | `gdFileFromSandbox` | `com.good.gd.file.File` seeded from `getFilesDir()` / `getCacheDir()` |
| 4H.camerax | `camerax-output-file-builder` | `ImageCapture.OutputFileOptions.Builder(File)` |
| 4H.mediamuxer | `mediamuxer-file-constructor` | `new MediaMuxer(path\|file, format)` |
| 4H.mediarecorder | `mediarecorder-file-output` | `MediaRecorder.setOutputFile(path\|file)` / `setNextOutputFile(path\|file)` |
| 4H.zipfile | `zipfile-file-constructor` | `new ZipFile(File\|String)` |
| 4H.exifinterface | `exifinterface-file-constructor` | `new ExifInterface(File\|String)` |
| 4H.pdfrenderer | `pdfrenderer-file-backed-pfd` | `ParcelFileDescriptor.open(File, mode)` for `PdfRenderer` |
| 4I | `fd-media-sandbox-provenance` | `MediaMuxer(fd, …)` or `MediaRecorder.setOutputFile(fd)` where the same file derives the FD from sandbox paths (`getFilesDir`, `getCacheDir`, `openFileOutput`, `createTempFile`, `ParcelFileDescriptor.open`) |
| 4K | `uri-empty-persistent` | `Uri.EMPTY` or `Uri.parse("")` stored in persistent data stores (DataStore, Room, SharedPreferences). Indicates a broken save round-trip — see §7a. |
| 4M | `docfile-from-file-gd` | `DocumentFile.fromFile()` in files importing `com.good.gd.file.*` — produces invalid `file://` URIs from container-relative paths. FAILURE — see §10. |

`steering/79-migration-plan-state-and-call-site-closure.md` adds the
matching closure clause: a `secureFileStorage` call site may only be
marked `migrated` when **both** its `File` type AND its stream layer are
GD-backed.

### How to add a new library entry

1. Add regex to `validate.sh` rule 4H as new sub-entry
   (e.g. `4H.newlib`) using `__stream_layer_scan` with import-gate.
2. Add `__stream_layer_accumulate` call with label token.
3. Append sub-entry output to `STREAM_LAYER_DETAILS_BUFFER`.
4. Add fixture pair under `tooling/fixtures/stream-layer/` and wire into
   `hardening-smoke.sh`.
5. Add row to the canonical replacement table in §5d above.
6. Add row to `13-unsupported-feature-detection-matrix.md`.
7. Add the `kind` / `library` / `replacementHint` values to
   `prompts/00-analyze-app.md` step 2 and
   `prompts/05a-filesystem-core-io-migration.md`.

---

## 12. Enterprise Hardening Addendum

- External storage and MediaStore writes are enterprise-risk findings and
  remain non-waivable security blockers.
- `File.createTempFile(...)` remains non-waivable for container-bound flows.
- Canonical CameraX guidance for container-bound capture: prefer in-memory
  `OnImageCapturedCallback` processing and write directly to secure
  container paths.
- `MediaScannerConnection`, capture intent output-URI flows, and public
  Gallery restoration are not accepted as successful secure-storage
  migration outcomes.

---

## 13. Migration Rules Summary

- Steady-state app data persisted through filesystem APIs → migrate to Dynamics secure filesystem APIs
- SharedPreferences persistence → see `42-secure-storage-sharedpreferences.md`
- `cacheDir` / `filesDir` staging is migration debt unless eliminated, redesigned, or domain-deferred
- All secure file access MUST happen after `onAuthorized()` fires
- Secondary activities launched after authorization can access files
  normally (container already unlocked)
- Writer and reader migration is a **single closure unit** per domain
- Stream-layer closure is mandatory — GD `File` type alone is insufficient

---

## Output

- File usage inventory table
- Migration recommendations
- Code changes with explanation

## Task: Secure Filesystem Migration 05b (UI Reader Closure)

Goal: Close reader-side gaps so UI/consumer paths do not read sensitive data
from native Android filesystem after writer-side migration.

**Prerequisite**: Run `05a-filesystem-core-io-migration.md` first.

**Module map context**: Load
`dynamics-migration-tool/output/module-map.json` and resolve
`${in_scope_main_src}`. Reader-side gaps frequently live in
feature/UI library modules. Iterate the full set in every audit
below. If `module-map.json` is missing, STOP and re-run
`00pre-bootstrap.md`.

---

## Steps

### 1. Inventory UI/Consumer Read Paths

Audit adapters, fragments, viewmodels, workers, and utility classes that read
file-backed data for domains migrated in 05a (for example `thumbs/`,
`media/photos/`, `exports/`).

Include third-party readers:

- Glide / Picasso / Coil
- `BitmapFactory.decodeFile(...)`
- direct `java.io.File` / absolute path loads

**Native media playback and metadata are prompt 05c**, not this
prompt: `MediaPlayer.setDataSource(path)`, `VideoView.setVideoPath`,
`MediaMetadataRetriever.setDataSource(path|File)`,
`ThumbnailUtils.createVideoThumbnail`. Do not mark those `migrated`
here. See `steering/41-secure-media.md`.

**Enumerate text-format files, not just media.** Reader closure must
cover **every** sensitive file format the app reads back, including:

- JSON metadata (settings, manifests, conversation/state files)
- XML (preferences, config, sync state)
- `.properties` files
- log files and any plaintext journal/audit files
- text caches written next to media (e.g. `documents/document.json`
  alongside `documents/document.pdf`)

Text-format reader sites are the most common false-positive "migrated"
sites: writer-side migration to `SecureFileIO`/GD streams looks correct,
but a downstream `readText()` / `forEachLine` / `Files.readAllBytes` /
`FileReader` against the same path still goes through `java.io` and
fails with `FileNotFoundException` after activation.

### 1a. Stream-Layer Audit (mandatory)

Apply the same stream-layer audit defined in
`prompts/05a-filesystem-core-io-migration.md` step 1a and
`steering/40-secure-file-storage.md` §5: for every reader call site under a
sensitive (`secureFileStorage`) domain, record both the `File` type
(GD vs `java.io`) and the actual reader/stream helper used. The site is
closed only when **both** are GD-backed.

Disallowed on sensitive domains (even when the `File` argument is
`com.good.gd.file.File`):

- `readText`, `readBytes`, `forEachLine`, `readLines`, `useLines`,
  `bufferedReader()`, `inputStream()`, `printWriter()`/`bufferedWriter()`,
  `copyTo`, `copyRecursively`, `deleteRecursively` on read+write paths
- `BitmapFactory.decodeFile(path)`
- `java.nio.file.Files.readAllBytes`, `Files.readString`,
  `Files.newInputStream`, `Files.newBufferedReader`, `Files.lines`
- `new java.io.FileReader(...)`, `new java.util.Scanner(File)`,
  `new java.io.RandomAccessFile(File, "r"|"rw")` over container paths
- `new ObjectInputStream(new FileInputStream(...))`,
  `Properties.load(new FileInputStream(...))`,
  `new ZipFile(File|String)` over container paths

Required closure checklist for each Kotlin extension call site:

- receiver type (`java.io.File` or `com.good.gd.file.File`)
- extension/API still in use (`readText`, `readBytes`, `copyRecursively`, etc.)
- replacement (`com.good.gd.file.*` stream, `GDFileSystem`, or `SecureFileIO`)
- final status (`migrated` only after extension removal on secure paths)

Do not mark a call site `migrated` solely because the receiver type changed to
`com.good.gd.file.File`; unresolved Kotlin extension calls remain migration
debt for `secureFileStorage`.

### 2. Enforce Writer->Reader Domain Closure — IMPLEMENT THE FIXES

For every domain migrated to secure container writers, **migrate** readers
to secure-container access patterns. Do not just flag mismatches — fix them.

Required pattern (implement this for every reader):

- read from secure container (`com.good.gd.file.*` or repo abstraction)
- pass `byte[]` / `InputStream` to consumer APIs

For each disallowed reader pattern, **replace it now**:

| Disallowed pattern | Replacement |
|---|---|
| `Glide.load(new File(...))` | `Glide.load(byte[])` from GD `FileInputStream`, or `Glide.load(inputStream)` |
| `Glide.load(file.getAbsolutePath())` | `Glide.load(byte[])` from GD `FileInputStream` |
| `BitmapFactory.decodeFile(path)` | `BitmapFactory.decodeStream(new com.good.gd.file.FileInputStream(path))` |
| Reads from `getCacheDir()/getFilesDir()` paths | Read from container-relative path via GD streams |
| `readText()` / `readBytes()` on GD `File` | `com.good.gd.file.FileInputStream` + manual read |
| `Files.readAllBytes(path)` | `com.good.gd.file.FileInputStream` + manual read |

### 2b. Native reader paths

If the app has app-controlled NDK code, audit any native readers (in
addition to Java/Kotlin readers above) that read from filesystem
domains migrated in 05a. Reader-side closure for native code is the
same rule: secure-container reads only.

- Replace `fopen(...)/fread(...)/fclose(...)` and `open(...)/read(...)/close(...)`
  on sensitive paths with the matching `GD_*` / `GD_UNISTD_*` calls per
  `steering/14-api-provenance-and-replacement-catalog.md` and
  `steering/40-secure-file-storage.md` §8.
- Disallow native readers that consume Android filesystem paths
  derived from `getCacheDir()` / `getFilesDir()` / `/data/...` strings
  (typically passed across the JNI boundary).
- For prebuilt `.so` files where source is not available, keep the
  non-blocking manual intervention from prompt 00 step 2b unless
  evidence shows a non-waivable storage/networking violation. Do not
  silently treat them as closed readers.

### 3. Third-Party Compatibility Decisions

If a library cannot consume secure streams and has no byte-stream API:

- create explicit `manualTodo` candidate with `severity: P1`
- include reason and workaround path

Do not silently keep native sensitive-file reads.

### 4. Update Call-Site Dispositions (Partial Closure)

Update `migration-plan-state.json` for secure file-storage call sites closed in
this pass.
Preserve the file's existing top-level `runId` unchanged (copy from
`bootstrap.json` if creating the file from scratch).

---

## Output

- Reader-side closure table by domain (`writer`, `reader`, `status`)
- Third-party compatibility notes and unresolved blockers
- Files changed in this pass
- `migration-plan-state.json` updated

See `steering/40-secure-file-storage.md` (canonical guide). `validate.sh` Phase 4 fails
writer→reader domain mismatches, Glide native path loads, GD stream
follow-on APIs (`.getChannel()`, `decodeFile`), and the stream-layer
anti-patterns from step 1a (`readText`/`Files.readAllBytes`/`FileReader`/
etc.). Re-run until scoped checks pass.

---

## Record execution

After 05b completes, append execution record:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05b \
    --status completed \
    --files-touched <comma-separated relative paths including migration-plan-state.json>
```

If secure file storage is `not-applicable` per execution plan, record skipped:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05b \
    --status skipped \
    --note "secureFileStorage not-applicable per executionPlan"
```

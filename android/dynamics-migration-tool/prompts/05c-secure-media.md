## Task: Secure Media Migration (prompt 05c)

Goal: migrate Android **native media** capture, playback, and metadata
onto Dynamics-safe patterns from `steering/41-secure-media.md`. Do not
treat `com.good.gd.file.File.path` / `absolutePath` or
`ParcelFileDescriptor.createPipe()` + MPEG-4 as a migration.

**Domain:** `secureFileStorage` (no `secureMedia` domain). Prompt `05z`
still closes the domain after this prompt.

**Prerequisites:** prompts `05a` and `05b` recorded; Application exposes
`isContainerAuthorized` / `runOnAuthorized` from prompt 03.

**Steering:** `steering/41-secure-media.md` (canonical). Catalog rows
`fs-java-media-record-001`, `fs-java-media-play-001`,
`fs-java-media-muxer-001`, `fs-java-media-video-capture-001`,
`fs-java-media-retriever-001`.

**Templates:** copy `templates/file/SeekableGdMediaCapture.{kt,java}`
and `templates/file/SeekableGdMediaPlayback.{kt,java}`. Substitute
`__APP_PACKAGE__`.

---

## Module map context (read first)

Load `dynamics-migration-tool/output/module-map.json` and resolve
`${in_scope_main_src}`. Media helpers often live in feature modules.
If `module-map.json` is missing, STOP and re-run `00pre-bootstrap.md`.

---

## Steps

### 0. Skip when not applicable

Read `dynamics-migration-tool/output/migration-analysis.json` →
`mediaCapabilities[]`.

If the array is **missing or empty**, AND a scan of `${in_scope_main_src}`
finds none of:

- `android.media.MediaRecorder`
- `android.media.MediaPlayer` / `android.widget.VideoView`
- `android.media.MediaMuxer`
- `android.media.MediaMetadataRetriever`
- `android.media.ThumbnailUtils`
- `androidx.camera.video`
- `androidx.media3.datasource.FileDataSource` / `exoplayer2` `FileDataSource`
- `ACTION_IMAGE_CAPTURE` / `ACTION_VIDEO_CAPTURE`

then record this prompt as **skipped** (see Record execution) and stop.
Do not invent media code.

If `mediaCapabilities[]` is empty but the scan finds APIs, **fix the
analysis** (add capabilities + `secureFileStorage` call sites with
`ownerPrompt: "05c"`) before migrating.

### 1. Classify each capability

For every `mediaCapabilities[]` entry, assign a class from
`steering/41-secure-media.md`:

| Class | Action in this prompt |
|---|---|
| A. No file (preview) | No source edit. Disposition not required. |
| B. Java stream (still `OutputStream`) | Usually already 05a. Verify GD `FileOutputStream`. |
| C. Seekable native FD | Apply the bridge below. |
| D. Leave container | REMOVE or ICC/SAF product path (already 05a/MediaStore blockers). |

Do **not** call `GD_fopen`, `GD_UNISTD_open`, or
`GDFileSystem.getAbsoluteEncryptedPath()` as a MediaRecorder/MediaPlayer
FD. Public GD `FileOutputStream` has no `getFD()`.

### 2. Capture (MediaRecorder / MediaMuxer / CameraX video)

For MPEG-4 / 3GP / WEBM, or when `setOutputFormat` is omitted:

1. Copy the capture template.
2. Give the native writer a **seekable** FD (`MemoryFile` /
   `SharedMemory` for audio/short clips; `openProxyFileDescriptor` +
   `com.good.gd.file.RandomAccessFile` for video when feasible).
3. On stop, copy bytes into a GD `FileOutputStream` from an
   **authorized Activity** (`runOnAuthorized` / `isContainerAuthorized`).
4. Do **not** construct `com.good.gd.file.File` in `Service.onCreate`.
5. Do **not** use `createPipe()` for these formats. Phase 4 `4L` fails it.
6. Sequential exception: `OutputFormat.AAC_ADTS` / `AMR_NB` / `AMR_WB`
   may pipe into a GD `FileOutputStream`.

CameraX video `FileOutputOptions(File)` and `MediaStoreOutputOptions`
are not migrated. Use `FileDescriptorOutputOptions` on the seekable
bridge, or leave P1 blocking `manualTodos[]`.

Mark call sites `migrated` only when the validator tokens
`mediarecorder-file-output`, `mpeg4-nonseekable-fd`,
`camerax-video-file-output`, and `fd-media-sandbox-provenance` are
clean for those files.

### 3. Playback and metadata

Replace:

- `MediaPlayer.setDataSource(path)` / `gdFile.absolutePath`
- `VideoView.setVideoPath`
- `Uri.fromFile(...)` media playback
- ExoPlayer `FileDataSource` on a java.io / GD path
- `MediaMetadataRetriever.setDataSource(path|File)`
- `ThumbnailUtils.createVideoThumbnail(File|path)`

with `setDataSource(FileDescriptor)` (or equivalent) from the playback
template: GD `FileInputStream` → MemoryFile (small) or proxy FD (large).

Load GD bytes only after authorization.

### 4. Dispositions

Write `dispositions[]` for every `secureFileStorage` call site whose
`ownerPrompt` is `05c` (or whose file is a media writer/player you
touched). Status `migrated` only if both the File type and the native
FD layer match `41-secure-media.md`. Unresolved class C sites stay
without `migrated`/`removed` and get `manualTodos[]` P1 blocking.

Full-file overwrite `migration-plan-state.json`. Keep existing SQL/file
dispositions from 04/05a/05b.

Every media source change needs a `[BB_DYNAMICS-MIGRATION]` comment.

---

## Record execution

```bash
# Migrated case
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05c \
    --status completed \
    --files-touched <comma-separated relative paths including migration-plan-state.json>

# No media capabilities and no media APIs in source
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05c \
    --status skipped \
    --note "no mediaCapabilities[] and no MediaRecorder/MediaPlayer/CameraX video APIs"
```

`validate.sh --check-prompt 05c` runs Phase 4 (including 4L / player /
retriever / camerax-video) and Phase 10. Prompt 10 remains the final gate.

Before recording **completed**, Phase 4 media tokens for in-scope sources
must be clean, or remaining hits must be documented as blocking
`manualTodos[]` (do not mark those call sites `migrated`).

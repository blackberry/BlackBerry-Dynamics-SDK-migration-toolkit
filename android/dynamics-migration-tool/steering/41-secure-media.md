# Steering: Secure Media (capture, playback, metadata)

**Ownership:** platform migration kit (prompt `05c` + Phase 4 stream-layer
rules `4L` / `4H.mediaplayer-path` / `4H.retriever-path` / `4H.camerax-video`
+ catalog rows `fs-java-media-*`).

**Domain:** `secureFileStorage`. There is no separate `secureMedia` domain.
Prompt `05z` still closes the domain after this prompt migrates the media
subset.

This document is the source of truth for Android media APIs that **do not
speak `com.good.gd.file.*`**. Generic file I/O stays in
`40-secure-file-storage.md`. Prompt `05c-secure-media.md` applies this
document; Phase 4 enforces it.

---

## Why media is not “just another File”

BlackBerry Dynamics secure storage is a Java/SDK layer. Public Android
docs for `com.good.gd.file.FileOutputStream` / `FileInputStream` state
that **`FileDescriptor` is not supported** — there is no `getFD()` and
no constructor from a descriptor.

Platform media APIs (`MediaRecorder`, `MediaMuxer`, `MediaPlayer`,
`VideoView`, `MediaMetadataRetriever`, CameraX `VideoCapture`) are
native. They `open` / `write` / `lseek` a Linux path or kernel FD.
They never call GD streams.

Therefore:

- `setOutputFile(gdFile.path)` and `setDataSource(gdFile.absolutePath)`
  are **not** migrations. GD `getAbsolutePath()` is a virtual container
  path (`/`-rooted inside the store), not an inode.
- `GD_fopen` / `GD_UNISTD_open` / `GD_UNISTD_lseek` are NDK replacements
  for **app** C/C++ I/O. They are not kernel FDs. MediaRecorder will not
  call them. iOS `GDFileHandle` documents the same constraint: extracted
  FDs may be used only with Dynamics interfaces, not native POSIX.
- `GDFileSystem.getAbsoluteEncryptedPath()` returns the native path of
  the **ciphertext** blob. Documented use is SQL `ATTACH`. Pointing a
  muxer at it writes plaintext onto encrypted storage.

A `ParcelFileDescriptor.createPipe()` satisfies “we passed an FD” and
fails at `MediaRecorder.start()` for MPEG-4 (`start failed: -2147483648`)
because Stagefright requires a **seekable** FD to finish the `moov` atom.
Prompt 05a must not mark pipe + MPEG-4 as `migrated`.

---

## Capability classes

Inventory in prompt 00 as `mediaCapabilities[]`. Classify each feature
before editing source.

| Class | Meaning | Dynamics pattern | Typical APIs |
|---|---|---|---|
| **A. No file** | Preview / live surface | Leave it | CameraX Preview, `TextureView`, `SurfaceView` |
| **B. Java stream** | App or CameraX writes/reads bytes | GD `FileOutputStream` / `FileInputStream` | JPEG stills, `ImageCapture.OutputFileOptions.Builder(OutputStream)`, Glide stream, `ExifInterface(InputStream)` |
| **C. Seekable native FD** | Platform muxer/player `lseek`s | Seekable FD bridge, then GD Java I/O | MPEG-4 `MediaRecorder`, `MediaMuxer` MP4, CameraX video `FileOutputOptions`, `MediaPlayer` / `VideoView` / ExoPlayer file, `MediaMetadataRetriever` |
| **D. Leave the container** | Public or other-app file | Remove, or ICC / one-shot SAF with product sign-off | `MediaStore` insert, `ACTION_IMAGE_CAPTURE` / `ACTION_VIDEO_CAPTURE` + `EXTRA_OUTPUT` |

Pipes are allowed **only** for class B, or for class C when the encoder
is sequential (`OutputFormat.AAC_ADTS`, `AMR_NB`, `AMR_WB`). MPEG-4,
3GP, and WEBM are never a pipe.

---

## Class C canonical bridge

### Small media (audio, still JPEG, short clip)

1. Allocate a seekable in-memory FD: `android.os.MemoryFile` or
   `android.os.SharedMemory` (document a cap; default **32–64 MB**).
2. Hand that FD to `MediaRecorder.setOutputFile(fd)` /
   `MediaPlayer.setDataSource(fd)` /
   `MediaMetadataRetriever.setDataSource(fd)`.
3. On stop (capture) or before play (playback), copy bytes through
   `com.good.gd.file.FileOutputStream` / `FileInputStream`.
4. Copy GD I/O from an **authorized Activity** (or `runOnAuthorized`),
   not from `Service.onCreate`.

Copy `templates/file/SeekableGdMediaCapture.{kt,java}` and
`templates/file/SeekableGdMediaPlayback.{kt,java}`.

`MemoryFile` is RAM, not `getCacheDir()` / `createTempFile()`. Phase 4
rule 4I must not fire on MemoryFile-only files.

### Large media (video)

Prefer `StorageManager.openProxyFileDescriptor` backed by
`com.good.gd.file.RandomAccessFile` so bytes enter the container during
capture and playback can seek without holding the whole clip in RAM.

If proxy + GD `RandomAccessFile` is not feasible: leave the call site
unresolved, add `manualTodos[]` with `severity: "P1"`, `blocking: true`,
keep `coverage.secureFileStorage` `partial`. Do **not** stage in
`filesDir` / `cacheDir`.

### Sequential-only formats

`OutputFormat.AAC_ADTS` / `AMR_NB` / `AMR_WB` may use
`ParcelFileDescriptor.createPipe()` whose read end is drained into a GD
`FileOutputStream`. MPEG-4 default (`setOutputFormat` omitted) is
**not** sequential — treat as seekable.

---

## Lifecycle (Service vs Activity)

`GDNotAuthorizedError` from `com.good.gd.file.File` inside
`Service.onCreate` is expected without Background Authorize, even when
a foreground Activity is already authorized.

Pattern:

- Service: native recorder/player + MemoryFile / proxy FD only.
- Activity (post-`onAuthorized`): GD stream copy / load.
- Do not enable `GDEnableBackgroundAuthorize` just to open a GD `File`
  from a bound recording service.

---

## Camera and video (same crash class as audio)

- **Preview:** class A. No change.
- **Still capture:** class B when using CameraX `Builder(OutputStream)`
  or `OnImageCapturedCallback` + GD write (already 05a / 4H.camerax).
- **Video recording:** class C. CameraX `FileOutputOptions(File)` and
  `MediaRecorder` video are MPEG-4 muxers. `MediaStoreOutputOptions` is
  an external-storage blocker. `FileDescriptorOutputOptions` still needs
  a **seekable** FD (not a pipe).
- **Playback:** class C. `VideoView.setVideoPath`,
  `MediaPlayer.setDataSource(path)`, ExoPlayer `FileDataSource` open a
  Linux path. Use the FD bridge or an ExoPlayer `DataSource` that reads
  GD streams **and** supports seek.
- **Metadata / thumbs:** class C.
  `MediaMetadataRetriever.setDataSource(path)` and
  `ThumbnailUtils.createVideoThumbnail(File)` are path APIs.

---

## Anti-patterns (never `migrated`)

- `MediaRecorder.setOutputFile(gdFile.path)` / `setOutputFile(java.io.File)`
- `MediaPlayer.setDataSource(gdFile.absolutePath)` / `VideoView.setVideoPath`
- `ParcelFileDescriptor.createPipe()` + `OutputFormat.MPEG_4` / `THREE_GPP` / `WEBM` / omitted format
- `getFilesDir()` / `getCacheDir()` / `openFileOutput` / `createTempFile` staging (rule 4I)
- `GD_fopen` / `GD_UNISTD_open` as a MediaRecorder FD
- `GDFileSystem.getAbsoluteEncryptedPath()` as a media path
- Marking class C `migrated` because public storage was removed

---

## Prompt split

| Prompt | Media work |
|---|---|
| 00 | `mediaCapabilities[]` inventory; class C/D call sites `ownerPrompt: "05c"` |
| 05a | File type + Java streams. **Do not** close MediaRecorder/Muxer/Player path sites. Hand them to 05c. Still-capture `OutputStream` may stay 05a. |
| 05b | Glide/Bitmap/text readers. Path-based player/retriever is 05c. |
| **05c** | Apply this document. Skip if `mediaCapabilities[]` is empty. |
| 05z | Domain closure only after 05c is `completed` or `skipped`. Phase 4 media rules must be clean. |
| 10 | Runtime plan includes record/seek/play when capabilities exist. Residual 4L/4H media hits block full `secureFileStorage` `migrated`. |

---

## Validator tokens

| Rule | Token | Fail when |
|---|---|---|
| 4H.mediarecorder | `mediarecorder-file-output` | `setOutputFile(path\|file)` (unchanged) |
| 4H.mediamuxer | `mediamuxer-file-constructor` | `new MediaMuxer(path\|file, …)` (unchanged) |
| 4H.camerax | `camerax-output-file-builder` | still `ImageCapture.OutputFileOptions.Builder(File)` |
| 4H.camerax-video | `camerax-video-file-output` | CameraX video `FileOutputOptions` / `MediaStoreOutputOptions` |
| 4H.mediaplayer-path | `mediaplayer-path-datasource` | `setDataSource`/`setVideoPath`/`FileDataSource` path |
| 4H.retriever-path | `retriever-path-datasource` | retriever/`ThumbnailUtils` path/File |
| 4I | `fd-media-sandbox-provenance` | FD writer + sandbox path in the same file |
| 4L | `mpeg4-nonseekable-fd` | seekable muxer format (or omitted format) + `createPipe` |

Catalog rows: `fs-java-media-record-001`, `fs-java-media-play-001`,
`fs-java-media-muxer-001`, `fs-java-media-video-capture-001`,
`fs-java-media-retriever-001`.

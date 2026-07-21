# Steering: App Extensions & Share Extensions under BlackBerry Dynamics (iOS)

BlackBerry Dynamics **does not support iOS Share Extensions** (or other app
extensions) as Dynamics-authorized secure-container citizens. Extensions run
in a separate process/lifecycle and **cannot** unlock or access the Dynamics
secure container the way the main app does after `GDiOS.authorize()`.

This file is the playbook when Prompt `00pre` / `00` / `target-map.json`
detects a Share Extension (or sibling extension targets).

---

## Why Share Extensions are incompatible

1. **No container access** — `GDFileManager`, `sqlite3enc_*`, Dynamics Keychain
   group semantics, and post-auth networking assume the main app’s authorized
   container. Share Extensions do not get that session.
2. **Lifecycle** — The extension can launch without the main app completing
   Dynamics activation/unlock.
3. **App Group bridges are a trust-boundary leak** — Copying “secure” data into
   an App Group for the extension (or writing extension inbox data into a
   shared group the main app later treats as trusted) bypasses the container.
4. **Linking Dynamics into the extension is not a supported product path** —
   Do not call `GDiOS.authorize()` inside a Share Extension or Embed
   `BlackBerryDynamics` / `GSEProvider` into the extension target as a
   “migration.”

---

## Detection signals

Treat **any** of the following as Share Extension detection:

| Signal | Example |
|--------|---------|
| Extension point | `NSExtensionPointIdentifier` = `com.apple.share-services` |
| Target product | `com.apple.product-type.app-extension` with Share naming / share plist |
| Classes | `SLComposeServiceViewController`, Share `ShareViewController` |
| target-map | `type: extension` + share-services evidence in Info.plist |
| bootstrap | `extensionCandidates[].extensionType` containing `share` / `share-services` |

Also inventory related unsupported extension families the same way (do not
Dynamics-migrate them):

- WidgetKit (`com.apple.widgetkit-extension`)
- Share / Action / Intent / Safari content blockers / Notification Service
- App Clips

---

## Required agent actions (main app may still migrate)

Unlike Flutter (whole-app out of scope), **continue migrating the main
application target**, but execute this checklist:

### 1. Call it out (mandatory)

- Add `unsupportedDetections[]` / report `unsupportedFeatures[]` entry:
  feature `Share-Extension` (or specific target name)
- Add **high** `manualTodos`: Dynamics builds must not ship the Share
  Extension until redesign is approved
- Record every Share Extension target in `bootstrap.extensionCandidates[]`
  with `extensionType: "share-services"`

### 2. Do not Dynamics-enable the extension

- Do **not** add BlackBerry Dynamics SPM/CocoaPods/manual frameworks to the
  Share Extension target
- Do **not** call `authorize()` / implement `GDiOSDelegate` in the extension
- Do **not** invent “mini-container” or App Group stand-ins for Dynamics storage

### 3. Isolate for Dynamics shipping builds (mandatory product step)

Pick **one** and document it in the report:

| Option | When to use |
|--------|-------------|
| **A — Non-shipping** | Remove Share Extension from the Dynamics app scheme / Archive / Embed App Extensions so the Dynamics IPA does not include it (preferred default) |
| **B — Unmanaged stub retained off Dynamics path** | Only if the developer explicitly keeps a non-Dynamics flavor; Dynamics flavor still excludes it |
| **C — Redesign inbound handoff into main app** | Product requires “share into app”: extension (or share sheet) only opens the **main** Dynamics app via URL scheme / Universal Link; main app copies inbound bytes into `GDFileManager` **after** `GDAppEventAuthorized` |

Outbound “share from Dynamics app” is **not** a Share Extension problem —
handle via Prompt `08` / `09` (remove unmanaged `UIActivityViewController` /
Files export, or AppKinetics for Dynamics-to-Dynamics).

### 4. Tear down insecure bridges

- Remove or hard-disable App Group read/write paths that move feed/DB/token
  data between the main app and the Share Extension
- Disposition ICC/DLP/share call sites that depended on the extension
  (`removed` / `blocked` with rationale)
- Ensure Prompt `05` does not leave “widget/share App Group = secure storage”

### 5. Release readiness

| Situation | Recommendation |
|-----------|----------------|
| Share Extension detected, excluded from Dynamics shipping, main app domains closed | `go-with-risks` with explicit residual risk + UEM/runtime TODO |
| Share Extension still embedded in the Dynamics Archive / still bridges App Group sensitive data | `no-go` until isolated |
| Core product workflow requires Share Extension with no approved redesign | `no-go` |

---

## What “done” looks like

- Main app Dynamics auth + secure domains migrated normally
- Share Extension **called out** in analysis + final report
- Dynamics build does **not** embed/ship the Share Extension (or redesign
  handoff is implemented post-auth into the container)
- No Dynamics framework linkage / authorize in the extension
- No App Group sensitive bridge left active
- Manual TODO tracks any future AppKinetics / URL-handoff redesign

---

## Cross-reference

- Detection matrix: `13-unsupported-feature-detection-matrix.md`
- Capability / tier: `12-capability-and-support-model.md`
- ICC / outbound share: `60-appkinetics-icc.md`, Prompt `08`
- Files / App Groups: Prompt `05`, `40-secure-storage-filesystem.md`

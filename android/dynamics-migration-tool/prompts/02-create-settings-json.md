# Task: Create Dynamics Configuration File

**Prerequisite**: Prompt `00pre-bootstrap.md` has run successfully and
`dynamics-migration-tool/output/bootstrap.json` exists with valid
`uem.gdApplicationId` and `uem.gdApplicationVersion` values. Prompt 01
(gradle-integration) must also be complete.

## Goal
Set up the required `settings.json` configuration file for BlackBerry
Dynamics, using the UEM credentials captured during bootstrap.

## Module map context (read first)

Load `dynamics-migration-tool/output/module-map.json` and resolve:

- `${primary}` — `primaryAppModule.path`.
- `${primary_assets_dirs}` — every `assetsDirs` entry attached to the
  primary application module's source sets in `module-map.json`.
  Concretely this includes the `main` source set's `assets/` directory
  **and**, when the primary application module declares product
  flavors, every flavor's and build-type-flavor combination's
  `assets/` directory listed by the module map. The single canonical
  case is `${primary}/src/main/assets`.

`settings.json` MUST be written to **every** entry in
`${primary_assets_dirs}` so flavor-specific builds (`fossDebug`,
`googleRelease`, `secondaryDebug`, etc.) all carry the same activation
contract. Flavor-specific overrides of UEM credentials are NOT
supported by this kit — the file content is identical across every
target. Library modules and other application modules never receive
`settings.json`.

If `module-map.json` is missing, STOP and re-run `00pre-bootstrap.md`.
Do NOT fall back to a literal `app/src/main/assets/` path.

## NO_INTERACTION_REQUIRED

This prompt does **not** ask the developer for input. UEM credentials are
collected once, up front, by `00pre-bootstrap.md`. This prompt reads them
from `bootstrap.json` and writes them into `settings.json`. If the
bootstrap is missing or its UEM block is invalid, abort and ask the
developer to re-run `00pre-bootstrap.md` — never collect UEM credentials
in this prompt.

---

## Steps

### 1. Read UEM credentials from `bootstrap.json`

```bash
cat dynamics-migration-tool/output/bootstrap.json
```

Extract:
- `uem.gdApplicationId` — must be a non-empty string matching
  `^[a-zA-Z0-9._-]+$`, length 1–255.
- `uem.gdApplicationVersion` — must match `^\d+\.\d+\.\d+\.\d+$`.
- `uem.source` — must be `"uem-admin-confirmed"`.

If any of these are missing, malformed, or `uem.source` is not
`"uem-admin-confirmed"`, STOP and instruct the developer:

> "bootstrap.json is missing valid UEM credentials. Re-run
>  00pre-bootstrap.md before continuing. This prompt does not collect
>  UEM credentials directly — they belong to the bootstrap step."

Do NOT fall back to asking the developer for the values here.

### 2. Create the assets directories if needed

For every entry in `${primary_assets_dirs}`:

```bash
mkdir -p <assets_dir>
```

### 3. Write `settings.json`

Use the template below, substituting the bootstrap values. **Use a
full-file overwrite (Write/CreateFile)** — do not patch a pre-existing
`settings.json` with placeholder values, and do not append.

Write the **same** file contents to every entry in
`${primary_assets_dirs}` — the `main` source set always, plus every
flavor and flavor+build-type assets directory enumerated by the
module map. Iterate the list; do not skip flavors.

If any target `settings.json` already exists with non-bootstrap values,
log a warning summarizing the diff and replace the file with the
bootstrap-driven values. Bootstrap is the source of truth.

### 4. Verify the resulting files

For each `<assets_dir>` in `${primary_assets_dirs}`:

```bash
python3 -m json.tool <assets_dir>/settings.json > /dev/null && \
    echo "✅ settings.json is valid JSON at <assets_dir>/settings.json"
```

Confirm for every target:

- File present at `<assets_dir>/settings.json`.
- `GDApplicationID` matches the bootstrap value byte-for-byte.
- `GDApplicationVersion` matches the bootstrap value byte-for-byte.
- `GDLibraryMode` is `"GDEnterprise"`.

---

## Template

```json
{
  "GDApplicationID": "<from bootstrap.uem.gdApplicationId>",
  "GDLibraryMode": "GDEnterprise",
  "GDApplicationVersion": "<from bootstrap.uem.gdApplicationVersion>",
  "GDConsoleLogger": [
    "GDFilterErrors_",
    "GDFilterWarnings_",
    "GDFilterInfo",
    "GDFilterDetailed"
  ]
}
```

The `GDConsoleLogger` array controls ADB console logging. Categories
with trailing underscore (`_`) are included; without it they are
excluded. Use `["GDFilterNone"]` for maximum verbosity during
development.

See `11-settings-json-reference.md` for the full reference of both
`settings.json` and `com.blackberry.dynamics.settings.json`.

---

## Output

- For every entry in `${primary_assets_dirs}`, a `settings.json` file
  written with bootstrap-derived UEM values (identical content across
  every target). On a single-module / no-flavor project this is just
  `${primary}/src/main/assets/settings.json`.
- JSON validity confirmed for every emitted file
- A one-line summary printed to the developer:

```
settings.json written. GDApplicationID=<id>; GDApplicationVersion=<ver>
(both sourced from bootstrap.json/uem; UEM admin confirmed at
<bootstrap.uem.source/permissions.developerConfirmedAt>).
```

---

## Critical Rules

- Do NOT ask the developer for `GDApplicationID` or `GDApplicationVersion`
  here — these are captured by `00pre-bootstrap.md` and live in
  `bootstrap.json`.
- Do NOT use the app's package name as `GDApplicationID`.
- Do NOT use `<MUST-ASK-DEVELOPER>` placeholder strings or any other
  placeholder.
- The app will NOT authorize without this file.
- If `bootstrap.json` is missing, ABORT — do not migrate around it.
- If `settings.json` already exists with different values than bootstrap,
  bootstrap wins (overwrite). Log the diff so the developer knows.

---

## Record execution

After `settings.json` is written and validated, append the execution
record:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 02 \
    --status completed \
    --files-touched <comma-separated list of every settings.json path written, taken from ${primary_assets_dirs}>
```

# Steering: settings.json and com.blackberry.dynamics.settings.json Reference

Dynamics apps use two JSON configuration files in `app/src/main/assets/`.
Both are read by the SDK at startup.

> **Multi-module note**: `app/src/main/assets/...` paths in this document
> are canonical-shape illustrations. On multi-module / flavored projects,
> place identical file contents at every entry in `${primary_assets_dirs}`
> from `dynamics-migration-tool/output/module-map.json` (main + each
> declared product flavor / build type). The kit does not support
> per-flavor UEM credentials — see `04-multi-module-projects.md` and
> `02-create-settings-json.md`.

---

## settings.json (REQUIRED)

This file is mandatory. Without it the app will not authorize.

```json
{
  "GDApplicationID": "<from bootstrap.json uem.gdApplicationId — UEM admin confirmed in 00pre>",
  "GDLibraryMode": "GDEnterprise",
  "GDApplicationVersion": "<from bootstrap.json uem.gdApplicationVersion>",
  "GDConsoleLogger": [
    "GDFilterErrors_",
    "GDFilterWarnings_",
    "GDFilterInfo",
    "GDFilterDetailed"
  ]
}
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `GDApplicationID` | Yes | Entitlement ID from UEM admin (captured in `output/bootstrap.json` during `00pre-bootstrap.md`; prompt 02 copies into this file). May differ from app package name. |
| `GDLibraryMode` | Yes | `"GDEnterprise"` for standard deployments. |
| `GDApplicationVersion` | Yes | Entitlement version from UEM admin (same bootstrap source as `GDApplicationID`). Format: `"X.Y.Z.W"`. May differ from app versionName. |
| `GDConsoleLogger` | No | Array of log filter strings. See Logging section below. |

### GDConsoleLogger Values

| Value | Effect |
|-------|--------|
| `"GDFilterNone"` | Print ALL messages (detailed logging) |
| `"GDFilterErrors_"` | Include error messages (trailing `_` = include) |
| `"GDFilterWarnings_"` | Include warning messages |
| `"GDFilterInfo"` | Exclude info messages (no trailing `_` = exclude) |
| `"GDFilterDetailed"` | Exclude detailed messages |

Categories with trailing underscore (`_`) are included; without it they
are excluded. Use `"GDFilterNone"` alone for maximum verbosity during
development.

### Character Encoding

The file MUST use UTF-8 encoding. Do NOT use UTF-8-BOM (byte order mark).
Java does not work with BOM headers.

---

## com.blackberry.dynamics.settings.json (OPTIONAL)

This separate file controls optional SDK features. Create it in
`app/src/main/assets/` only if needed.

```json
{
  "GDEnableBackgroundAuthorize": true,
  "AutomaticLauncherManagement": false,
  "GDEnterpriseSimulation": true
}
```

### Fields

| Field | Default | Description |
|-------|---------|-------------|
| `GDEnableBackgroundAuthorize` | `false` | Enable Background Authorize for push/FCM/JobService/Worker handling. **Required (must be `true`) only when at least one entry in `bootstrap.json.backgroundAuthorize.decisions[]` has `intent: "migrate"`** — i.e. the developer opted in to wire the canonical handshake for that candidate. When every recorded decision is `deferred` or `not-applicable`, the flag is intentionally **not** set and any stale `true` value from a previous run must be removed or set to `false`; setting it to `true` without a corresponding canonical handshake misleads UEM administrators into enabling autonomous authorization at the profile level for an app that cannot use it. See `70-background-authorize.md` and `prompts/03c-background-authorize.md`. |
| `AutomaticLauncherManagement` | `true` | Enable/disable the BlackBerry Dynamics Launcher (blue BB icon). Set `false` to disable. |
| `GDEnterpriseSimulation` | `false` | Enable enterprise simulation mode for testing without UEM. See `90-test-against-uem.md`. |

---

## Entitlement Version in AndroidManifest.xml (Service Providers Only)

If the app provides a Shared Service consumed by other Dynamics apps,
add the entitlement version as manifest metadata:

```xml
<application ...>
    <!-- [BB_DYNAMICS-MIGRATION] Entitlement version for Shared Services Framework -->
    <meta-data android:name="GDApplicationVersion" android:value="1.0.0.0"/>
</application>
```

The value MUST match `GDApplicationVersion` in `settings.json`.

---

## Key Rules

- **NEVER guess** `GDApplicationID` or `GDApplicationVersion` — they must match
  `bootstrap.json` (`uem` block, `source: "uem-admin-confirmed"`), produced when
  the developer supplied UEM admin values in `00pre-bootstrap.md`. Prompt
  `02-create-settings-json.md` reads bootstrap only; it does not ask for UEM
  input again.
- If bootstrap is missing or invalid, re-run `00pre-bootstrap.md` — do not
  collect UEM credentials in prompt 02 or later steering-driven steps.
- `settings.json` must exist or the app will not authorize
- `com.blackberry.dynamics.settings.json` is optional in general, but
  becomes **required** with `"GDEnableBackgroundAuthorize": true` at
  every `${primary_assets_dirs}` target when the developer chose
  `intent: "migrate"` for at least one candidate in
  `bootstrap.json.backgroundAuthorize.decisions[]` (see prompt
  `03c-background-authorize.md`). When every decision is `deferred` or
  `not-applicable`, do not write the flag. Otherwise create
  it only if the app needs Launcher control or simulation mode.
- Both files must be valid JSON with UTF-8 encoding


## Production logging profile (recommended)

For enterprise release builds, keep console logging minimal:

```json
{
  "GDConsoleLogger": [
    "GDFilterErrors_",
    "GDFilterWarnings_",
    "GDFilterInfo",
    "GDFilterDetailed"
  ]
}
```

Avoid logging sensitive app data (`token`, `password`, `secret`, `PII`) via any logger (`Log.*`, Timber, Napier).

# Task: Migrate Covered Text/Search Widgets to Dynamics Equivalents

**Prerequisite**: Prompts 03 and 03b must be complete. Secure UI widgets
require the Dynamics SDK to be initialized and the authorization lifecycle
in place.

## Goal
Apply the toolkit's production UI widget catalog so every supported
text/search input surface is migrated with type-safe Dynamics behavior,
and unsupported widgets remain native with explicit residual-risk
documentation. Preserve DLP enforcement for clipboard/drag paths and
avoid migration-introduced cast crashes.

### Migration Rule (NON-NEGOTIABLE)

All widgets listed under `tooling/lib/ui-widget-catalog.json` `replaceRows[]`
must migrate according to their lane rule (`appcompat_inflater` or
`explicit_gd_widgets`). `keepNativeRows[]` entries stay native and are
tracked as residual risk/manual follow-up; do not invent GD replacements.

The **only** valid way to leave a `replaceRows[]` call site unmigrated is for
the developer to record a domain-level deferral in
`bootstrap.json.deferredDomains[]` for `secureUiWidgets` (see
`steering/79-migration-plan-state-and-call-site-closure.md` and
`steering/21-authorization-deferral-patterns.md`). Per-call-site
sensitivity rationale is not accepted; if the call site exists, it
migrates or the whole `secureUiWidgets` domain is deferred.

## Module map context (read first)

Load `dynamics-migration-tool/output/module-map.json` and resolve
`${in_scope_main_src}` (every primary + library `src/main/java` and
`src/main/kotlin`) and `${in_scope_res_dirs}` (every primary + library
resource directory across main + flavors). Custom widgets, layout XML,
and clipboard utility helpers commonly live in shared `ui` / `core/ui`
library modules; every search below scans the full set. If
`module-map.json` is missing, STOP and re-run `00pre-bootstrap.md`.

---

## Steps

### 0. Enumerate Call Sites (MANDATORY — do this before editing any code)

Before writing migration code, read `migration-analysis.json` and list
one planned disposition per call site for **both** domains covered by
this prompt (`secureUiWidgets` and `secureClipboard`). Do **not**
pre-register final `migrated` dispositions before the corresponding
code or XML is actually changed; the ledger is a closure record, not a
worklist.

**Step 0a — List all applicable call sites for this prompt:**

```bash
python3 - dynamics-migration-tool/output/migration-analysis.json <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
for row in a.get("executionPlan", []):
    if row.get("domain") in ("secureUiWidgets", "secureClipboard") and row.get("applicable"):
        for cs in row.get("callSites", []):
            print(f"  domain={row['domain']!r}  id={cs['id']!r}  file={cs.get('file')}:{cs.get('line')}  kind={cs.get('kind')}")
PY
```

If this prints nothing for a domain that was inventoried as applicable, re-run
`00-analyze-app.md` — `callSites[]` must be non-empty when `applicable: true`.

**Step 0b — List Prompt-00 egress features owned by prompt 09:**

```bash
python3 - dynamics-migration-tool/output/migration-analysis.json <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
for feat in a.get("egressFeatures", []):
    if feat.get("ownerPrompt") == "09":
        print(
            f"id={feat.get('id')!r} outcome={feat.get('recommendedOutcome')!r} "
            f"feature={feat.get('featureName')!r} target={feat.get('targetMechanism')!r}"
        )
PY
```

Use `egressFeatureDecisions[]` for feature-level DLP/egress outcomes such as
clipboard replacement, drag-and-drop removal, or printing/screen-export
manual follow-up. Example:

```json
{
  "featureId": "egress-clipboard-main-001",
  "domain": "secureClipboard",
  "outcome": "REPLACE_WITH_DYNAMICS",
  "module": "app",
  "note": "Platform clipboard path replaced with Dynamics secure clipboard APIs.",
  "secureAlternative": "Dynamics secure clipboard",
  "uiDisposition": "replaced",
  "codePathReachable": true
}
```

**Step 0c — Write one `dispositions[]` entry per call site only after
the call site is migrated or removed:**

Use the canonical top-level shape and merge/upsert this prompt's
entries while preserving existing rows from other domains:

```json
{
  "schemaVersion": "1.1.0",
  "runId": "<copied unchanged from bootstrap.json / existing migration-plan-state.json>",
  "egressFeatureDecisions": [
    {
      "featureId": "<existing value or new prompt-owned feature id>",
      "domain": "secureFileStorage|secureNetworking|icc|secureClipboard|secureUiWidgets|policyManagement",
      "outcome": "REMOVE|REPLACE_WITH_DYNAMICS|MANUAL_INTERVENTION_REQUIRED|BLOCKED_UNTIL_APPROVED",
      "module": "<optional module path from module-map.json>",
      "note": "<optional detail>",
      "secureAlternative": "<optional string or null>",
      "uiDisposition": "removed|disabled|replaced|flagged",
      "codePathReachable": false
    }
  ],
  "dispositions": [
    {
      "callSiteId": "<exact id from migration-analysis.json callSites[].id>",
      "domain": "secureClipboard",
      "status": "migrated",
      "module": "<module path from module-map.json, e.g. app>",
      "note": "<brief description of what replaced the call site>"
    }
  ]
}
```

Use `"domain": "secureUiWidgets"` for widget call sites and
`"domain": "secureClipboard"` for clipboard call sites. Use `"status":
"removed"` when the call site is eliminated rather than migrated. The only
valid status values are `migrated` and `removed`.

> **CRITICAL — do NOT invent custom top-level keys.** The following shapes
> are incorrect and will be rejected by the schema validator:
>
> ```json
> { "clipboardDispositions": [ ... ] }      ← WRONG: unknown top-level key
> { "secureUiWidgetsDispositions": [ ... ] } ← WRONG: unknown top-level key
> ```
>
> `dispositions[]` is the **only** canonical array for all closure-gated
> domains (`secureSql`, `secureFileStorage`, `secureNetworking`, `icc`,
> **`secureUiWidgets`**, **`secureClipboard`**). Always write to
> `migration-plan-state.json` at the top level key `dispositions`.
>
> Feature-level remove/block/replace/manual outcomes belong in
> `egressFeatureDecisions[]`, not in a second clipboard- or widget-specific
> top-level key.

**Step 0d — Verify the file parses correctly after writing dispositions:**

```bash
python3 -c "import json; json.load(open('dynamics-migration-tool/output/migration-plan-state.json'))" \
  && echo "✅ valid JSON" || echo "❌ invalid JSON — fix before proceeding"
```

---

1. **Detect migration lane before editing UI**
   Choose one lane for this app and keep it consistent:
   - **Lane A (default for modern apps):** AppCompat theme with
     `viewInflaterClass=com.good.gd.app.GDAppCompatViewInflater`.
   - **Lane B (legacy/no inflater):** explicit `com.good.gd.widget.GD*`
     widget classes in XML/programmatic construction.

   Detect lane:

   ```bash
   rg 'viewInflaterClass' ${in_scope_res_dirs}
   rg 'GDAppCompatViewInflater' ${in_scope_res_dirs}
   rg 'com\\.good\\.gd\\.widget\\.GD(TextView|EditText)\\b' ${in_scope_res_dirs}
   ```

   **Already-migrated apps:** if layouts already use explicit `GDTextView` /
   `GDEditText` (Lane B) and there is no inflater, **finish Lane B**. Do not
   install `GDAppCompatViewInflater` on top of those tags. New AppCompat
   migrations still prefer Lane A.

   **Do not mix lanes.** If inflater is enabled and explicit `GDTextView` /
   `GDEditText` XML tags still exist, normalize to one lane before continuing.

2. **Run catalog-based UI scan (MANDATORY)**
   Use the toolkit scanner backed by
   `tooling/lib/ui-widget-catalog.json`:

   ```bash
   python3 dynamics-migration-tool/tooling/lib/ui-surface-scan.py ${in_scope_main_src}
   ```

   Resolve all `FAIL` checks:
   - `UI_LANE`, `UI_BIND_001`, `UI_CHILD_001`, `UI_CUSTOM_001`,
     `UI_PROG_001`, `UI_SEARCH_001`, `UI_TIN_001`, `UI_REMOTE_001`,
     `UI_DRAG_001`.

3. **Apply catalog dispositions**
   Follow the catalog exactly:
   - `replaceRows[]` => migrate call sites to Dynamics class or inflater lane rule.
   - `keepNativeRows[]` => keep native class (record residual risk, no forced rewrite).

   Appcompat lane specifics:
   - Keep `<TextView>` / `<EditText>` / AppCompat XML tags.
   - Bind inflated views as Android/AppCompat base types, not `GDTextView` /
     `GDEditText`.
   - `SearchView`: use `androidx.appcompat.widget.SearchView` FQCN in XML.
   - `MaterialTextView`: normalize XML tag to `<TextView>` so inflater substitution applies.

   Explicit lane specifics:
   - Replace covered tags with explicit `com.good.gd.widget.GD*` tags.
   - Update Java/Kotlin binding types to match inflated GD class.

4. **Custom views and mixed siblings**
   - Never rewrite project custom XML tags (`com.example.HighlightableTextView`)
     to `GDTextView`/`GDEditText`.
   - Migrate the custom class parent to matching `GDAppCompat*` / `GD*`.
   - If a ViewGroup mixes custom widgets with GD siblings, avoid homogeneous casts:

   ```kotlin
   // NOT OK
   linearLayout.children.forEach { it as HighlightableTextView }

   // OK
   linearLayout.children.filterIsInstance<HighlightableTextView>().forEach { ... }
   ```

5. **Programmatic widget construction**
   Migrate constructors too; inflater does not cover programmatic creation:
   - Lane A: construct `GDAppCompat*` classes (and `GDTextInputEditText`).
   - Lane B: construct explicit `GD*` classes.
   - Compose `AndroidView { ... }` factories are included in this requirement.

6. **Record sensitivity and residual risk**
   Sensitivity buckets (reporting only):
   - Sensitive, Semi-sensitive, Decorative/static.

   KEEP_NATIVE classes (no Dynamics equivalent) remain native and must be
   documented as residual risk / manual follow-up in the report; do not
   invent a GD class replacement.

7. **Test UI behavior**
   - Inflate and navigate screens that host migrated widgets.
   - Verify no cast crashes in adapters/view holders.
   - Verify copy/paste and drag/drop behavior follows policy expectations.
   - Run prompt-scoped validator:

   ```bash
   bash dynamics-migration-tool/tooling/validate.sh --check-prompt 09
   ```

---

## Widget Mapping

Use `tooling/lib/ui-widget-catalog.json` as the only mapping source.
Do not invent additional replacements.

| Native/AppCompat/Material source | Lane A (`GDAppCompatViewInflater`) | Lane B (explicit GD tags/classes) |
|---|---|---|
| `TextView` | keep `<TextView>`; inflates as `GDAppCompatTextView` | replace with `GDTextView` |
| `EditText` | keep `<EditText>`; inflates as `GDAppCompatEditText` | replace with `GDEditText` |
| `AutoCompleteTextView` | keep standard/AppCompat tag; inflates as `GDAppCompatAutoCompleteTextView` | replace with `GDAutoCompleteTextView` |
| `MultiAutoCompleteTextView` | keep standard/AppCompat tag; inflates as `GDAppCompatMultiAutoCompleteTextView` | replace with `GDMultiAutoCompleteTextView` |
| `androidx.appcompat.widget.SearchView` | keep FQCN tag; inflates as `GDAppCompatSearchView` | use `GDAppCompatSearchView` |
| `android.widget.SearchView` | not auto-substituted in Lane A; migrate to AppCompat FQCN tag first | replace with `GDSearchView` |
| `MaterialTextView` | normalize to `<TextView>` so inflater substitutes securely | replace with `GDTextView` |
| `CheckedTextView` / `AppCompatCheckedTextView` | keep tag; inflates as `GDAppCompatCheckedTextView` | use `GDAppCompatCheckedTextView` |
| `TextInputEditText` | keep `TextInputEditText` tag; inflater creates `GDTextInputEditText` | replace with `GDTextInputEditText` |

KEEP_NATIVE (no Dynamics equivalent in SDK 15): leave native and record residual risk
(`manualTodos[]` / coverage notes): `Button`, `MaterialButton`, `ImageButton`,
`CheckBox`, `RadioButton`, `Switch`, `Chip`, `ChipGroup`, `TextInputLayout`,
`MaterialAutoCompleteTextView`, `ExposedDropdownMenu`, `Preference*`, Compose text fields,
and other widgets listed under `keepNativeRows[]`.

WebView remains out of scope for this prompt: migrate in prompt `07` to
`com.blackberry.bbwebview.BBWebView`.

## Example Changes

### Lane A (AppCompat inflater)

```xml
<!-- Keep standard tag; inflater substitutes at runtime -->
<EditText
    android:id="@+id/passwordField"
    android:layout_width="match_parent"
    android:layout_height="wrap_content" />
```

```xml
<!-- AppCompat SearchView must use FQCN in XML -->
<androidx.appcompat.widget.SearchView
    android:id="@+id/search"
    android:layout_width="match_parent"
    android:layout_height="wrap_content" />
```

```java
// Bind as Android/AppCompat base type in inflater lane
import android.widget.EditText;
EditText passwordField = findViewById(R.id.passwordField);
```

### Lane B (explicit GD)

```xml
<com.good.gd.widget.GDEditText
    android:id="@+id/passwordField"
    android:layout_width="match_parent"
    android:layout_height="wrap_content" />
```

```java
import com.good.gd.widget.GDEditText;
GDEditText passwordField = findViewById(R.id.passwordField);
```

### Custom view safety

```kotlin
// Keep custom XML tag; migrate the class parent to GDAppCompatTextView.
linearLayout.children
    .filterIsInstance<HighlightableTextView>()
    .forEach { it.setTextSize(TypedValue.COMPLEX_UNIT_SP, body) }
```

### Material TextInput handling

```xml
<!-- Parent stays TextInputLayout -->
<com.google.android.material.textfield.TextInputLayout ...>
    <com.google.android.material.textfield.TextInputEditText ... />
</com.google.android.material.textfield.TextInputLayout>
```

In Lane A, the inflater substitutes `TextInputEditText` with `GDTextInputEditText`.
In Lane B, use explicit `<com.good.gd.widget.GDTextInputEditText .../>`.

## Output

- UI widget inventory table with columns:
  - Widget ID/name
  - Current type
  - Data sensitivity classification (reporting only — see step 2)
  - Action taken (replaced / deferred-via-`secureUiWidgets`)
  - Notes (e.g. layout file, owning module, deferral reference)
- List of XML layout files modified
- List of Java/Kotlin files modified
- **`dynamics-migration-tool/output/migration-plan-state.json` updated**
  with canonical top-level keys (`schemaVersion`, `runId`,
  `egressFeatureDecisions[]`, `dispositions[]`) and merged
  `secureUiWidgets`/`secureClipboard` dispositions
- For any covered widget left unmigrated: the corresponding
  `deferredDomains[]` entry for `secureUiWidgets` in
  `bootstrap.json` (per-call-site "kept as standard" with local
  rationale is not accepted).
- Testing notes for UI functionality

---

## When NOT to Replace

Use the catalog:

- If widget is in `replaceRows[]`, migrate it.
- If widget is in `keepNativeRows[]`, keep it native and capture residual risk
  in report/manual todos.

Legitimate unmigrated covered call sites (from `replaceRows[]`) are limited to:

- **Third-party / vendored UI you cannot edit**
- **Developer-signed `secureUiWidgets` deferral** in `bootstrap.json`

`keepNativeRows[]` items are not considered migration failures on their own.
Do not force fake replacements for unsupported widgets.

---

## Critical Notes

- `ui-widget-catalog.json` is authoritative for replace/keep-native behavior.
- Lane A and Lane B are both valid, but mixed-lane migrations are invalid.
- Do not rewrite custom XML FQCN tags to GD widgets.
- Programmatic constructors and Compose `AndroidView` wrappers are in scope.
- Compose-only text widgets have no Dynamics equivalent; migrate clipboard and
  record residual risk.

### Developer Deferral Stop (MANDATORY when any covered widget remains standard)

If any app-controlled covered widget remains standard after your code changes,
STOP and hand the developer this exact `deferredDomains[]` template. The agent
must not write it:

```json
{
  "deferredAt": "2026-06-25T12:00:00Z",
  "deferredBy": "developer",
  "developerSignedOff": true,
  "classification": "acceptedResidualRisk",
  "domain": "secureUiWidgets",
  "expiresAt": "2026-09-25T12:00:00Z",
  "reason": "Remaining standard text/search widgets need UI QA and product sign-off before a full GD widget migration."
}
```

Do not create a partial placeholder. Missing `developerSignedOff`,
`classification`, or `expiresAt` means the validator ignores the deferral and
prompt 10 still hard-fails.

Independent-evidence note:
- Import-only rediscovery in adapters, view holders, or bridge UI files is
  still part of the audit trail. Backfill Prompt-00 `callSites[]` inventory
  and matching `dispositions[]` rows for those files; do not assume prompt 10
  will infer them automatically from code changes alone.

---

## Secure Clipboard Migration (MANDATORY)

Replacing widgets alone is NOT sufficient for DLP enforcement. The app
must also replace all programmatic clipboard access — **including Jetpack
Compose clipboard abstractions** — with Dynamics secure clipboard controls.

During analysis, detect Compose clipboard usage **separately** from
`android.content.ClipboardManager`. During implementation, classify it under
`secureClipboard` / DLP migration. During reporting, record whether each
Compose clipboard call site was migrated to `GDClipboardAdapter` or requires
manual remediation.

### Steps

1. **Search for platform clipboard usage**
   - `rg "android.content.ClipboardManager" -g "*.java" -g "*.kt" -n ${in_scope_main_src}`
   - `rg "ClipboardManager" -g "*.java" -g "*.kt" -n ${in_scope_main_src}`
   - `rg "CLIPBOARD_SERVICE" -g "*.java" -g "*.kt" -n ${in_scope_main_src}`

1b. **Search for Jetpack Compose clipboard usage (MANDATORY when Compose is present)**
   - `rg "LocalClipboardManager\\.current|LocalClipboard\\.current" -g "*.kt" -n ${in_scope_main_src}`
   - `rg "androidx\\.compose\\.ui\\.platform\\.(LocalClipboardManager|LocalClipboard|ClipboardManager|Clipboard|ClipEntry)" -g "*.kt" -n ${in_scope_main_src}`
   - `rg "setClipEntry|getClipEntry|ClipEntry\\(" -g "*.kt" -n ${in_scope_main_src}`
   - `rg "clipboardManager\\.setText|clipboardManager\\.getText|clipboard\\.setClipEntry|clipboard\\.getClipEntry" -g "*.kt" -n ${in_scope_main_src}`
   - Treat every hit as `secureClipboard` — do not defer silently and do not
     mark the domain not-applicable while these remain.

2. **Replace imports**
   - `android.content.ClipboardManager` → `com.good.gd.content.ClipboardManager`

3. **Replace instance creation**
   - `ContextCompat.getSystemService(context, ClipboardManager::class.java)` → `ClipboardManager.getInstance(context)`
   - `context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager` → `ClipboardManager.getInstance(context)`
   - Drag/drop start should route through `ClipboardManager.startDragAndDrop(...)`,
     not direct `View.startDragAndDrop(...)` for app payloads.

4. **Check utility/extension functions**
   - Apps commonly have `copyToClipBoard()`, `getLatestText()`, or
     similar helper functions that wrap clipboard access
   - These MUST be updated — they are the most common source of DLP bypass

5. **Check custom views**
   - Custom EditText/TextView subclasses may access the clipboard directly
     (e.g., to pre-fill a URL from clipboard contents)
   - These MUST be updated

5b. **Migrate custom widget parent classes (MANDATORY)**
   - Find all custom subclasses across the full widget family:
     `rg "AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|AppCompatSearchView|AutoCompleteTextView|MultiAutoCompleteTextView|SearchView|TextInputEditText" -g "*.java" -g "*.kt" -n ${in_scope_main_src}`
   - Change the root parent class to the GD equivalent:
     - `AppCompatEditText` → `GDAppCompatEditText` (`com.good.gd.widget.GDAppCompatEditText`)
     - `AppCompatTextView` → `GDAppCompatTextView` (`com.good.gd.widget.GDAppCompatTextView`)
     - `AppCompatCheckedTextView` → `GDAppCompatCheckedTextView` (`com.good.gd.widget.GDAppCompatCheckedTextView`)
     - `AppCompatAutoCompleteTextView` → `GDAppCompatAutoCompleteTextView` (`com.good.gd.widget.GDAppCompatAutoCompleteTextView`)
     - `AppCompatMultiAutoCompleteTextView` → `GDAppCompatMultiAutoCompleteTextView` (`com.good.gd.widget.GDAppCompatMultiAutoCompleteTextView`)
     - `androidx.appcompat.widget.SearchView` → `GDAppCompatSearchView` (`com.good.gd.widget.GDAppCompatSearchView`)
     - `android.widget.AutoCompleteTextView` → `GDAutoCompleteTextView` (`com.good.gd.widget.GDAutoCompleteTextView`)
     - `android.widget.MultiAutoCompleteTextView` → `GDMultiAutoCompleteTextView` (`com.good.gd.widget.GDMultiAutoCompleteTextView`)
     - `android.widget.SearchView` → `GDSearchView` (`com.good.gd.widget.GDSearchView`)
     - `com.google.android.material.textfield.TextInputEditText` → `GDTextInputEditText` (`com.good.gd.widget.GDTextInputEditText`)
   - Only change the root class in the inheritance chain — subclasses inherit automatically
   - This is MANDATORY because the system copy/paste action bar is handled
     at the widget level, not through the programmatic ClipboardManager
   - **Do NOT** add `GDWebView` to this list. Custom `WebView` subclasses
     are handled by prompt `07` and must extend `BBWebView` (or a
     `BBWebViewClient` / `BBWebChromeClient`).

6. **Verify no `android.content.ClipboardManager` imports remain**
   - `rg "android.content.ClipboardManager" -g "*.java" -g "*.kt" -n ${in_scope_main_src}`
   - This should return zero results after migration

### Jetpack Compose Clipboard (interim `GDClipboardAdapter`)

When Compose clipboard usage is detected:

1. **Copy the kit adapter** (do not hand-roll from scratch):
   ```bash
   cp dynamics-migration-tool/templates/clipboard/GDClipboardAdapter.kt \
      <owning-module>/src/main/java/<your/package/path>/dynamicsclipboard/
   ```
   Replace `__APP_PACKAGE__` with your app package.

2. **Migrate deterministic plain-text flows** to `GDClipboardAdapter`:
   - `LocalClipboardManager.current` + `setText` / `getText` →
     `remember { GDClipboardAdapter(context) }` + `setPlainText` / `getPlainText`
   - `LocalClipboard.current` + plain `ClipEntry(ClipData.newPlainText(...))` →
     `GDClipboardAdapter.setPlainText` / `getPlainText`

3. **FORBIDDEN in migrated code:**
   - `LocalClipboardManager.current` or `LocalClipboard.current`
   - Compose `androidx.compose.ui.platform.ClipboardManager` for app copy/paste
   - `context.getSystemService(Context.CLIPBOARD_SERVICE)` as a workaround
   - Leaving Compose clipboard in place because platform clipboard was migrated elsewhere

4. **Manual remediation (high priority `manualTodos[]`):** non-plain `ClipEntry`
   payloads (URI, intent, HTML) that cannot be safely converted — document file,
   line, and remediation in the migration report.

5. **Verify Compose clipboard closure:**
   - `rg "LocalClipboardManager\\.current|LocalClipboard\\.current" -g "*.kt" -n ${in_scope_main_src}`
   - Expect zero hits after migration (adapter file may reference Dynamics APIs only).

See `steering/45-secure-ui-widgets.md` § "Jetpack Compose Clipboard" for
before/after examples.

### Why This Matters

Without secure clipboard migration:
- UEM DLP policies restricting copy/paste are completely ignored
- Users can copy sensitive data to unmanaged apps outside the container
- Compliance violations go undetected
- Security audits will flag this as a data leakage risk

See `45-secure-ui-widgets.md` steering file for full migration patterns
and code examples.

---

## Record execution

This prompt covers two related domains: `secureUiWidgets` and
`secureClipboard`. After it completes — whether it migrated either or
skipped them because both are `not-applicable` — append the execution
record so prompt 10's hard gate sees that the plan was honored:

```bash
# Migrated case
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 09 \
    --status completed \
    --files-touched "<comma-separated relative paths, including dynamics-migration-tool/output/migration-plan-state.json>"

# Skipped case (both domains marked not-applicable in migration-analysis.json)
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 09 \
    --status skipped \
    --note "secureUiWidgets and secureClipboard not-applicable per executionPlan"
```

A single recorded entry covers both domains; prompt 10's hard gate
treats prompt `09` as the owner of both `secureUiWidgets` and
`secureClipboard`.

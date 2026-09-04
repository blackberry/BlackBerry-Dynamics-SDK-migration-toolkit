# Task: Migrate Covered Text/Search Widgets to Dynamics Equivalents

**Prerequisite**: Prompts 03 and 03b must be complete. Secure UI widgets
require the Dynamics SDK to be initialized and the authorization lifecycle
in place.

## Goal
Replace **every** usage of the covered standard / AppCompat / Material
text and search widget family in app-controlled UI with its BlackBerry
Dynamics equivalent so DLP enforcement (clipboard, screenshot, paste,
share, autofill) cannot be bypassed at the widget level.

### Migration Rule (NON-NEGOTIABLE)

All covered standard / AppCompat / Material text and search widgets in
app-controlled UI **must** migrate to their `com.good.gd.widget.*`
equivalent. There is no local "non-sensitive label" escape: the
copy/paste action bar, screenshot interception, and DLP hooks live on
the widget class, not on the data flowing through it, so even a static
label can participate in selection / copy / share / suggestions.

The **only** valid way to leave a covered widget unmigrated is for the
developer to record a domain-level deferral in
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

1. **Identify all secure-widget-family usage**
   Inventory every occurrence of the direct-replacement widget family
   (each one has a 1:1 GD equivalent — see `45-secure-ui-widgets.md`):
   - Standard Android: `EditText`, `TextView`, `AutoCompleteTextView`,
     `MultiAutoCompleteTextView`, `SearchView`.
   - AndroidX AppCompat: `AppCompatEditText`, `AppCompatTextView`,
     `AppCompatCheckedTextView`, `AppCompatAutoCompleteTextView`,
     `AppCompatMultiAutoCompleteTextView`,
     `androidx.appcompat.widget.SearchView`.
   - Material Components: `MaterialTextView`.
   Search Java/Kotlin code AND XML layout files. Also enumerate
   custom subclasses that extend any of these bases (these need
   parent-class migration to the GD equivalent — see step 5b).

   Use explicit source scans aligned to validator Phase 8:

   ```bash
   rg 'import\s+android\.widget\.(EditText|TextView|AutoCompleteTextView|MultiAutoCompleteTextView|SearchView)\b' app/src/main/java app/src/main/kotlin
   rg 'import\s+androidx\.appcompat\.widget\.(AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|SearchView)\b' app/src/main/java app/src/main/kotlin
   rg 'import\s+com\.google\.android\.material\.textview\.MaterialTextView\b' app/src/main/java app/src/main/kotlin
   rg '<\s*(EditText|TextView|AutoCompleteTextView|MultiAutoCompleteTextView|SearchView|androidx\.appcompat\.widget\.(AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|SearchView)|com\.google\.android\.material\.textview\.MaterialTextView)\b' app/src/main/res
   ```

   > **Out of scope here**: `android.webkit.WebView` migration is
   > handled by prompt `07` and `50-webview-bbwebview.md`. The only
   > supported WebView migration target is
   > `com.blackberry.bbwebview.BBWebView`. **Do not** introduce
   > `com.good.gd.widget.GDWebView` — it is deprecated/legacy.

2. **Record data sensitivity (reporting only — does NOT gate migration)**
   The migration rule above is unconditional for the covered widget
   family. Sensitivity classification is recorded in the UI widget
   inventory table (and the migration report) so reviewers can see
   what each call site carries, but it is **not** used to decide
   whether to migrate. Use these buckets when filling in the
   inventory:
   - Sensitive: Passwords, PII, business data, credentials
   - Semi-sensitive: User-generated content, messages
   - Decorative / static: UI chrome, public copy, brand text

3. **Replace every covered widget**
   Apply the deterministic mapping below for **every** covered
   standard / AppCompat / Material widget in app-controlled UI:

   | Standard / AppCompat / Material | BlackBerry Dynamics |
   |---|---|
   | `android.widget.EditText` | `com.good.gd.widget.GDEditText` |
   | `android.widget.TextView` | `com.good.gd.widget.GDTextView` |
   | `android.widget.AutoCompleteTextView` | `com.good.gd.widget.GDAutoCompleteTextView` |
   | `android.widget.MultiAutoCompleteTextView` | `com.good.gd.widget.GDMultiAutoCompleteTextView` |
   | `android.widget.SearchView` / `androidx.appcompat.widget.SearchView` | `com.good.gd.widget.GDSearchView` (or `GDAppCompatSearchView` for AppCompat-themed activities) |
   | `androidx.appcompat.widget.AppCompatEditText` | `com.good.gd.widget.GDAppCompatEditText` |
   | `androidx.appcompat.widget.AppCompatTextView` | `com.good.gd.widget.GDAppCompatTextView` |
   | `androidx.appcompat.widget.AppCompatCheckedTextView` | `com.good.gd.widget.GDAppCompatCheckedTextView` |
   | `androidx.appcompat.widget.AppCompatAutoCompleteTextView` | `com.good.gd.widget.GDAppCompatAutoCompleteTextView` |
   | `androidx.appcompat.widget.AppCompatMultiAutoCompleteTextView` | `com.good.gd.widget.GDAppCompatMultiAutoCompleteTextView` |
   | `com.google.android.material.textview.MaterialTextView` | `com.good.gd.widget.GDTextView` |

   Every match in the covered family migrates. The only accepted
   escape is a developer-signed deferral of the `secureUiWidgets`
   domain in `bootstrap.json.deferredDomains[]` — local "this label
   looks static" rationale is **not** accepted by the validator and
   must not be used to skip a call site.

4. **Update XML layouts**
   - Change widget class names in layout files
   - Keep all existing attributes
   - Verify layout preview still works

5. **Update Java/Kotlin code**
   - Update import statements
   - Update variable types
   - When XML used `MaterialTextView`, change code to `GDTextView` — not only `android.widget.TextView`
   - API is compatible - no logic changes needed

5a. **Verify source-level imports and bindings are fully migrated (MANDATORY)**
   Run these checks and resolve every hit before recording prompt completion:

   ```bash
   rg 'import\s+android\.widget\.(AutoCompleteTextView|MultiAutoCompleteTextView|SearchView)\b' app/src/main/java app/src/main/kotlin
   rg 'import\s+androidx\.appcompat\.widget\.(AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|SearchView)\b' app/src/main/java app/src/main/kotlin
   rg 'import\s+com\.google\.android\.material\.textview\.MaterialTextView\b' app/src/main/java app/src/main/kotlin
   rg 'findViewById\([^)]*\)\s*(as\s+(EditText|TextView|AutoCompleteTextView|MultiAutoCompleteTextView|AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|MaterialTextView)|:\s*(EditText|TextView|AutoCompleteTextView|MultiAutoCompleteTextView|AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|MaterialTextView)\b)' app/src/main/java app/src/main/kotlin
   bash dynamics-migration-tool/tooling/validate.sh --check-prompt 09
   ```

   Any remaining hits indicate prompt 09 is not closure-ready.

5b. **Compose-first apps (MANDATORY review)**
   - If the app is primarily Jetpack Compose and has little/no XML widget usage,
     do not force artificial XML rewrites.
   - Focus prompt 09 outcomes on:
     - **secure clipboard migration** — platform APIs **and** Compose clipboard
       (see § "Jetpack Compose Clipboard" below)
     - classification of sensitive text-entry surfaces and documented residual risk
     - any custom Android View bridges used inside Compose (`AndroidView`, custom views)
   - For Compose-only text fields where no direct Dynamics widget equivalent is used,
     record explicit rationale in `coverage.secureUiWidgets.details` and `manualTodos`.
   - Compose clipboard is **not** satisfied by migrating widgets alone or by
     marking `secureClipboard` not-applicable when only Compose locals are used.

6. **Test UI functionality**
   - Verify all widgets display correctly
   - Test user input and data display
   - Verify screenshot protection (if applicable)

---

## Widget Mapping

See step 3 above for the full direct-replacement table. `MaterialTextView`
is binding-compatible at the XML level but **not** at the Java/Kotlin
binding type level — see the next subsection. `com.good.gd.widget.GDWebView`
is **not** in this mapping: WebView migration is owned exclusively by
prompt `07` and targets `com.blackberry.bbwebview.BBWebView`.

### Material Components — mandatory Java/Kotlin bind step

Material Design `MaterialTextView` is **not** assignment-compatible with
`GDTextView`. If you change the XML tag to `<com.good.gd.widget.GDTextView>`
(handling the same `@+id/...`), you **must** update every Java/Kotlin binding:
imports, field/local types, and method parameters that referenced
`MaterialTextView` for that id.

Skipping this step produces a **runtime** failure after Dynamics activation:

`java.lang.ClassCastException: com.good.gd.widget.GDTextView cannot be cast to com.google.android.material.textview.MaterialTextView`

Layout-only migration (XML updated, code left on `MaterialTextView`) is a
common migration-kit gap — `validate.sh` Phase 8 flags remaining
`MaterialTextView` references when layouts contain `GDTextView`.

---

## Example Changes

### XML Layout
```xml
<!-- Before -->
<EditText
    android:id="@+id/passwordField"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:inputType="textPassword" />

<!-- After -->
<com.good.gd.widget.GDEditText
    android:id="@+id/passwordField"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:inputType="textPassword" />
```

### Java Code
```java
// Before
import android.widget.EditText;
EditText passwordField = findViewById(R.id.passwordField);

// After — if XML was changed to <com.good.gd.widget.GDEditText>
import com.good.gd.widget.GDEditText;
GDEditText passwordField = findViewById(R.id.passwordField);

// After — if the theme uses GDAppCompatViewInflater (XML stays <EditText>)
// GDAppCompatEditText does NOT extend GDEditText. Bind as EditText.
import android.widget.EditText;
EditText passwordField = findViewById(R.id.passwordField);
```

### Java — MaterialTextView → GDTextView (same pattern)

```java
// Before (layout used MaterialTextView; after migration layout uses GDTextView)
import com.google.android.material.textview.MaterialTextView;
MaterialTextView detail = view.findViewById(R.id.resolution_detail_text);

// After — type must match inflated widget class
import com.good.gd.widget.GDTextView;
GDTextView detail = view.findViewById(R.id.resolution_detail_text);
```

---

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

The covered text/search widget family is an **all-or-nothing**
migration. The only legitimate reasons to leave a covered widget
unmigrated are:

- **Third-party / vendored UI you do not control** — e.g. a closed
  source library inflating its own `EditText`. Record this as a
  manual TODO and treat it as out of scope for app-controlled UI.
  It does not satisfy the migration rule; the developer must still
  defer the `secureUiWidgets` domain if any in-scope call site
  remains standard.
- **Domain-level deferral** of `secureUiWidgets` recorded by the
  developer in `bootstrap.json.deferredDomains[]`. This is the
  **only** sanctioned escape for app-controlled UI.

The following are **NOT** valid reasons to skip migration (the
validator will reject them and they explicitly contradict the DLP
threat model):

- "This is just a static label / brand text / decorative chrome."
- "This widget never holds sensitive data."
- "This widget is read-only / not editable."
- "We optimised this view for performance."

All of the above still participate in selection, long-press copy,
share intents, and screenshot capture at the framework level.

---

## Critical Notes

- Every covered standard / AppCompat / Material text/search widget
  in app-controlled UI migrates to its `com.good.gd.widget.*`
  equivalent. No per-call-site sensitivity escape.
- API is compatible — minimal code changes required.
- Test thoroughly to ensure UI functionality is preserved.
- For widgets left unmigrated, the only acceptable record is a
  developer-signed deferral of `secureUiWidgets` in
  `bootstrap.json.deferredDomains[]`.
- Compose-first apps satisfy this prompt by migrating clipboard
  and any Android `View` bridges (`AndroidView`, custom views)
  that wrap a covered widget; for Compose-only text fields with
  no XML equivalent, record explicit rationale in
  `coverage.secureUiWidgets.details` and `manualTodos`.

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
     `rg "AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|AppCompatSearchView|AutoCompleteTextView|MultiAutoCompleteTextView|SearchView" -g "*.java" -g "*.kt" -n ${in_scope_main_src}`
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

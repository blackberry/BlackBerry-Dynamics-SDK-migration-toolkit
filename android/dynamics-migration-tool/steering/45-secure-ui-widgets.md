# Steering: Secure UI Widgets

BlackBerry Dynamics provides secure UI widgets that prevent data leakage through:
- Screenshot prevention
- Clipboard protection  
- Screen recording protection
- Copy/paste restrictions

---

## Discovery Phase (MANDATORY)

Find all usages of the **direct-replacement widget family** the SDK
ships under `com.good.gd.widget.*`. Each entry below is a 1:1
replacement for its standard Android / AppCompat equivalent:

Standard Android:
- `EditText`
- `TextView`
- `AutoCompleteTextView`
- `MultiAutoCompleteTextView`
- `SearchView`

AndroidX AppCompat:
- `AppCompatEditText`
- `AppCompatTextView`
- `AppCompatCheckedTextView` (and `CheckedTextView` via AppCompat inflation)
- `AppCompatAutoCompleteTextView`
- `AppCompatMultiAutoCompleteTextView`
- `androidx.appcompat.widget.SearchView`

Material Components:
- `com.google.android.material.textview.MaterialTextView`
- `com.google.android.material.textfield.TextInputEditText`

Check both Java/Kotlin code and XML layouts. Custom subclasses that
extend any of these base classes also need migration (see "Custom
Subclasses" below). `TextInputLayout` itself stays native; only
`TextInputEditText` is in the replacement set.

> **WebView is out of scope for this steering file.** Secure WebView
> migration is owned by prompt `07` and `50-webview-bbwebview.md`. The
> only supported WebView migration target is
> `com.blackberry.bbwebview.BBWebView`. **Do not** introduce
> `com.good.gd.widget.GDWebView` — it is legacy/deprecated and must
> not be used as a migration target.

---

## Classification Rules (reporting only)

The sensitivity buckets below are **reporting metadata**, not a
migration gate. They populate the UI widget inventory column in the
migration report so reviewers can see what each call site carries —
they do **not** decide whether a covered widget migrates.

- **Sensitive**: Passwords, PII, business data, credentials
- **Semi-sensitive**: User-generated content, messages
- **Decorative / static**: UI chrome, public copy, brand text

---

## Migration Rule (NON-NEGOTIABLE)

Migration uses a **closed catalog** in
`tooling/lib/ui-widget-catalog.json`.

- `replaceRows[]` call sites must migrate.
- `keepNativeRows[]` call sites remain native and are reported as residual-risk
  surfaces (no invented GD replacement classes).
- For `replaceRows[]` call sites only, unresolved migrations require a
  developer-signed `secureUiWidgets` deferral.

### Two supported lanes

1. **Lane A: AppCompat inflater**
   - Theme declares:
     `<item name="viewInflaterClass">com.good.gd.app.GDAppCompatViewInflater</item>`
   - Keep standard/AppCompat XML tags and bind inflated widgets as Android/AppCompat
     base types.
   - Migrate custom classes by changing parent to `GDAppCompat*`.
   - Do not cast inflated views to `GDEditText`/`GDTextView`.

2. **Lane B: explicit GD widgets**
   - No inflater.
   - Replace covered XML/programmatic classes with explicit `com.good.gd.widget.GD*`
     classes and update binding types accordingly.

Mixed lane (`viewInflaterClass` plus explicit `GDTextView`/`GDEditText` XML tags)
is invalid and fails Phase 8.

Re-runs on an app that already rewrote XML to `GDTextView`/`GDEditText` should
**finish Lane B**. Installing the inflater on top of those tags recreates the
dual-hierarchy `ClassCastException`. Lane A remains the default only for apps
that still have standard/AppCompat XML tags.

### Replacement table (SDK 15.0.8513.64)

| Source | Lane A replacement behavior | Lane B replacement behavior |
|---|---|---|
| `EditText` | keep tag; inflater => `GDAppCompatEditText` | `GDEditText` |
| `TextView` | keep tag; inflater => `GDAppCompatTextView` | `GDTextView` |
| `CheckedTextView` / `AppCompatCheckedTextView` | keep tag; inflater => `GDAppCompatCheckedTextView` | `GDAppCompatCheckedTextView` |
| `AutoCompleteTextView` | keep tag; inflater => `GDAppCompatAutoCompleteTextView` | `GDAutoCompleteTextView` |
| `MultiAutoCompleteTextView` | keep tag; inflater => `GDAppCompatMultiAutoCompleteTextView` | `GDMultiAutoCompleteTextView` |
| `androidx.appcompat.widget.SearchView` | keep FQCN tag; inflater => `GDAppCompatSearchView` | `GDAppCompatSearchView` |
| `android.widget.SearchView` | normalize XML to AppCompat FQCN first | `GDSearchView` |
| `MaterialTextView` | normalize XML to `<TextView>`; inflater secures it | `GDTextView` |
| `TextInputEditText` | keep tag; inflater => `GDTextInputEditText` | `GDTextInputEditText` |
| custom classes extending covered parents | change parent to matching `GDAppCompat*` | change parent to matching `GD*`/`GDAppCompat*` |

### Keep-native table (no SDK 15 equivalent)

Keep native and document residual risk/manual follow-up:

- `Button`, `MaterialButton`, `ImageButton`, `CheckBox`, `RadioButton`, `Switch`, `Chip`, `ChipGroup`
- `TextInputLayout`, `MaterialAutoCompleteTextView`, `ExposedDropdownMenu`
- `EditTextPreference`, `Preference`, `PreferenceFragmentCompat`
- Compose text fields (`TextField`, `OutlinedTextField`, `BasicTextField`, etc.)
- `RemoteViews` layouts used by app widgets/notifications (must not host GD widgets)

### DLP rationale

DLP enforcement lives on the widget class and clipboard/drag integrations.
For supported classes, migration is mandatory. For unsupported classes, keep-native
is explicit and auditable; do not fake replacements.

> **WebView is not in this table.** Replace `android.webkit.WebView`
> with `com.blackberry.bbwebview.BBWebView` per prompt `07` and
> `50-webview-bbwebview.md`. `com.good.gd.widget.GDWebView` is
> deprecated and must not be used.

---

## Migration workflow (lane-aware)

1. Detect lane:
   - Lane A (recommended): AppCompat theme uses `GDAppCompatViewInflater`
   - Lane B: explicit GD widget classes
2. Run scanner:
   - `python3 dynamics-migration-tool/tooling/lib/ui-surface-scan.py ${in_scope_main_src}`
3. Apply catalog dispositions from `ui-widget-catalog.json`.
4. Re-run scanner and `validate.sh --check-prompt 09`.

### Lane A import + binding guidance

- Keep Android/AppCompat imports for inflated view bindings (`TextView`,
  `EditText`, AppCompat `SearchView`, etc.).
- Do not cast/bind `findViewById` results to `GDTextView`/`GDEditText` in
  inflater lane.

```java
// AppCompat inflater lane: bind as base type
import android.widget.EditText;
EditText passwordField = findViewById(R.id.passwordField);
```

### Lane B import + binding guidance

- Explicit GD XML tags or programmatic GD constructors require matching GD types.

```java
import com.good.gd.widget.GDEditText;
GDEditText passwordField = findViewById(R.id.passwordField);
```

### XML migration guidance

- Lane A: keep standard/AppCompat XML tags for covered widgets.
- Lane B: replace covered XML tags with explicit `com.good.gd.widget.GD*`.
- Never rewrite project custom FQCN tags to GD tags.
- In Lane A, use `androidx.appcompat.widget.SearchView` FQCN in XML;
  naked `<SearchView>` is not auto-substituted.
- For `MaterialTextView` in Lane A, normalize to `<TextView>` so inflater applies.
- `TextInputEditText` is covered:
  - Lane A: keep Material tag; inflater creates `GDTextInputEditText`
  - Lane B: explicit `GDTextInputEditText`

### Mandatory post-migration verification

```bash
python3 dynamics-migration-tool/tooling/lib/ui-surface-scan.py ${in_scope_main_src}
bash dynamics-migration-tool/tooling/validate.sh --check-prompt 09
```

---

## When NOT to Replace

Do not replace widgets listed in `ui-widget-catalog.json` `keepNativeRows[]`.
These stay native and must be reported as residual DLP risk/manual follow-up.

Examples that stay native in SDK 15:
- `Button`, `MaterialButton`, `CheckBox`, `Switch`, `Chip`, `ChipGroup`
- `TextInputLayout`, `MaterialAutoCompleteTextView`
- `Preference*` classes (including `EditTextPreference`)
- Compose text fields (`TextField`, `OutlinedTextField`, `BasicTextField`)

For widgets listed in `replaceRows[]`, exclusions remain limited to:
- third-party closed-source UI you cannot edit
- developer-signed `secureUiWidgets` deferral in `bootstrap.json`

---

## Automatic Widget Substitution (AppCompat Apps)

If the app uses `AppCompatActivity` with an AppCompat theme, you can
enable automatic widget substitution instead of manually replacing each
widget. Add this to your app's theme:

```xml
<!-- [BB_DYNAMICS-MIGRATION] Auto-substitute widgets with GDAppCompat equivalents -->
<item name="viewInflaterClass">com.good.gd.app.GDAppCompatViewInflater</item>
```

When installed, widgets defined in XML layouts are automatically replaced
at inflation time with their GDAppCompat equivalents:

| Standard Widget | Auto-Replaced With |
|----------------|-------------------|
| `EditText` | `GDAppCompatEditText` |
| `TextView` | `GDAppCompatTextView` |
| `CheckedTextView` | `GDAppCompatCheckedTextView` |
| `AutoCompleteTextView` | `GDAppCompatAutoCompleteTextView` |
| `MultiAutoCompleteTextView` | `GDAppCompatMultiAutoCompleteTextView` |
| `SearchView` | `GDAppCompatSearchView` |
| `com.google.android.material.textfield.TextInputEditText` | `GDTextInputEditText` |

### IMPORTANT: Do not cast inflated views to `GDEditText` / `GDTextView`

`GDAppCompatEditText` does **not** extend `GDEditText` (same for
`GDAppCompatTextView` vs `GDTextView`). After `viewInflaterClass` is
set, XML `<EditText>` inflates as `GDAppCompatEditText`. Binding or
casting that view to `GDEditText` throws:

```text
java.lang.ClassCastException: com.good.gd.widget.GDAppCompatEditText
    cannot be cast to com.good.gd.widget.GDEditText
```

Bind inflated views as the Android base type. DLP still applies because
the inflater already substituted the widget:

```java
// WRONG — ClassCastException when viewInflaterClass is installed
GDEditText nameField = view.findViewById(R.id.et_chat_name);

// RIGHT
EditText nameField = view.findViewById(R.id.et_chat_name);
```

Use `GDEditText` / `GDTextView` only for `new GDEditText(context)` or
XML that names that class explicitly (not `<EditText>`). Scan for
`(GDEditText)`, `@ViewById GDEditText`, and `as GDEditText` on inflated
views.

This approach is simpler than manual replacement for supported classes.
Unsupported classes still remain native and must be documented via
`keepNativeRows[]` residual risk/report fields.

### IMPORTANT: Do not mix lanes

If `GDAppCompatViewInflater` is installed, do not keep explicit
`com.good.gd.widget.GDTextView` / `GDEditText` XML tags in the same app.
Mixed lane migrations create type divergence and cast crashes.

### IMPORTANT: Auto-Substitution Does NOT Cover Custom Subclasses

`GDAppCompatViewInflater` only substitutes standard widget class names
(`EditText`, `TextView`, etc.) at XML inflation time. It does NOT
substitute custom subclasses like `MyCustomEditText` or
`StylableEditTextWithHistory` — even if they extend `AppCompatEditText`.

If the app has custom subclasses of `EditText`, `TextView`,
`AutoCompleteTextView`, `MultiAutoCompleteTextView`, `SearchView`,
`CheckedTextView`, or any of their AppCompat counterparts, you must
change their parent class to the GD equivalent (regardless of whether
the subclass appears to handle sensitive data — the DLP hooks live on
the parent class, not on the data)
(e.g., extend `GDAppCompatEditText` instead of `AppCompatEditText`,
`GDAppCompatAutoCompleteTextView` instead of
`AppCompatAutoCompleteTextView`, and so on per the full widget list
above).

**Why this is mandatory (not optional)**: When a user long-presses text
and uses the system copy/paste action bar, the copy operation is handled
internally by the widget at the framework level. It does NOT go through
the app's programmatic `ClipboardManager` code. Only GD widget classes
intercept the system copy/paste action bar to enforce DLP policies.
Migrating the programmatic `ClipboardManager` alone is NOT sufficient —
both the widget parent class AND the clipboard must be migrated for
complete DLP coverage.

**Best practice**: Change the root custom class in the inheritance chain.
For example, if the hierarchy is `StylableEditText` → `HighlightableEditText`
→ `EditTextWithWatcher` → `AppCompatEditText`, change only
`EditTextWithWatcher` to extend `GDAppCompatEditText`. All subclasses
inherit the DLP protection automatically. **Keep the custom class name
in XML** — do not replace `<com.example.HighlightableTextView>` with
`<com.good.gd.widget.GDTextView>`.

### IMPORTANT: Mixed siblings + `children.forEach { it as CustomView }`

Prompt 09 must not rewrite a leftover `<TextView>` sibling inside a
ViewGroup that already hosts custom text widgets if Java/Kotlin iterates
**all** children and casts them to the custom type.

```
ClassCastException: com.good.gd.widget.GDTextView cannot be cast to
com.example.HighlightableTextView
    at BaseNoteVH.<init>
```

That crash fires when the list/adapter first inflates after activation
(creating a note, opening Notes). Phase 8 `[UI_CHILD_001]` fails when a
layout mixes a custom `*TextView`/`*EditText` subclass with
`GDTextView`/`GDEditText` siblings **and** source does `as CustomView`
/ `(CustomView) getChildAt` over `.children` / `childCount`.

Fix: `filterIsInstance<CustomView>()` (Kotlin) or `instanceof` (Java),
and style the GD sibling via its `@id`. Alternatively use the custom
class for every text sibling (parent already provides DLP).

---

## Secure Clipboard (MANDATORY for DLP Enforcement)

### Why This Is Critical

The Dynamics SDK enforces DLP (Data Loss Prevention) policies on
copy/paste operations through `com.good.gd.content.ClipboardManager`.
If the app uses the standard `android.content.ClipboardManager`, all
clipboard operations bypass DLP policy enforcement entirely — users can
copy sensitive data out of the app to unmanaged apps regardless of UEM
policy settings.

This is the most commonly missed DLP gap in migrated apps because:
- `GDAppCompatViewInflater` handles widget-level DLP for standard widgets
- But programmatic clipboard access (copy/paste utility functions,
  clipboard reads in custom views) is a separate code path
- Both must be migrated for complete DLP coverage

### Discovery Phase (MANDATORY)

When scanning for clipboard usage, include **both** direct Android clipboard
APIs **and** indirect Jetpack Compose clipboard abstractions. Compose
clipboard usage is an external clipboard surface even when
`android.content.ClipboardManager` is never imported.

Find ALL usages of:

**Platform clipboard**
- `android.content.ClipboardManager` (import statements)
- `ContextCompat.getSystemService(context, ClipboardManager::class.java)`
- `context.getSystemService(Context.CLIPBOARD_SERVICE)`
- `ClipData.newPlainText()` / `setPrimaryClip()` / `getPrimaryClip()`
- `View.startDragAndDrop()` / `View.startDrag()` where app payload is shared
- Any utility functions that wrap clipboard operations (e.g.,
  `copyToClipBoard()`, `getLatestText()`, `pasteFromClipboard()`)

**Jetpack Compose clipboard** (treat as `secureClipboard`, not optional)
- `LocalClipboardManager.current`
- `LocalClipboard.current`
- Imports from `androidx.compose.ui.platform.LocalClipboardManager`,
  `LocalClipboard`, `ClipboardManager`, `Clipboard`, `ClipEntry`
- `clipboardManager.setText(...)` / `clipboardManager.getText()`
- `clipboard.setClipEntry(...)` / `clipboard.getClipEntry()`
- `ClipEntry(...)` constructed for Compose clipboard
- Variables assigned from the Compose locals above and then used for
  `setText` / `getText` / `setClipEntry` / `getClipEntry`
- `ClipData.newPlainText(...)` used only to feed Compose `ClipEntry` —
  still a clipboard surface

Do **not** confuse these with:
- `com.good.gd.content.ClipboardManager` (Dynamics secure clipboard — target)
- `GDClipboardAdapter` (kit interim Compose adapter — acceptable stop-gap)

### Migration: Import Changes

```kotlin
// REMOVE this import
import android.content.ClipboardManager

// ADD this import
// [BB_DYNAMICS-MIGRATION] Replaced android.content.ClipboardManager with Dynamics secure ClipboardManager for DLP policy enforcement
import com.good.gd.content.ClipboardManager
```

### Migration: Obtaining the ClipboardManager Instance

```kotlin
// OLD — standard Android ClipboardManager (bypasses DLP)
val clipboard = ContextCompat.getSystemService(context, ClipboardManager::class.java)
// or
val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

// NEW — Dynamics secure ClipboardManager (enforces DLP)
// [BB_DYNAMICS-MIGRATION] Uses Dynamics secure ClipboardManager for DLP-enforced clipboard access
val clipboard = ClipboardManager.getInstance(context)
```

### Migration: Copy to Clipboard

```kotlin
// OLD
fun Context.copyToClipBoard(text: CharSequence) {
    ContextCompat.getSystemService(this, ClipboardManager::class.java)?.let {
        val clip = ClipData.newPlainText("label", text)
        it.setPrimaryClip(clip)
    }
}

// NEW
// [BB_DYNAMICS-MIGRATION] Replaced with Dynamics secure ClipboardManager for DLP policy enforcement
fun Context.copyToClipBoard(text: CharSequence) {
    val clipboard = ClipboardManager.getInstance(this)
    val clip = ClipData.newPlainText("label", text)
    clipboard.setPrimaryClip(clip)
}
```

### Migration: Read from Clipboard

```kotlin
// OLD
val clipboard = ContextCompat.getSystemService(context, ClipboardManager::class.java)
val text = clipboard?.primaryClip?.getItemAt(0)?.text

// NEW
// [BB_DYNAMICS-MIGRATION] Uses Dynamics secure ClipboardManager for DLP-enforced clipboard read
val clipboard = ClipboardManager.getInstance(context)
val text = clipboard.primaryClip?.getItemAt(0)?.text
```

### API Compatibility

`com.good.gd.content.ClipboardManager` provides the same API surface as
`android.content.ClipboardManager`:
- `setPrimaryClip(ClipData)` — works identically
- `getPrimaryClip()` — works identically
- `hasPrimaryClip()` — works identically
- `primaryClip` property — works identically

The only difference is how you obtain the instance: use
`ClipboardManager.getInstance(context)` instead of
`getSystemService()`.

### What DLP Policies Are Enforced

When using the Dynamics `ClipboardManager`, the UEM admin can:
- Block copy from Dynamics apps to non-Dynamics apps
- Block paste from non-Dynamics apps into Dynamics apps
- Allow copy/paste only between Dynamics apps
- Log clipboard operations for compliance auditing

None of these policies work if the app uses the standard Android
`ClipboardManager`.

### Jetpack Compose Clipboard (interim `GDClipboardAdapter`)

BlackBerry Dynamics does not ship an official Compose-native clipboard API
today. For deterministic plain-text Compose clipboard flows, copy the kit
template and route through Dynamics secure clipboard:

```bash
cp dynamics-migration-tool/templates/clipboard/GDClipboardAdapter.kt \
   <owning-module>/src/main/java/<your/package/path>/dynamicsclipboard/
```

Rewrite package `__APP_PACKAGE__` to your app package.

```kotlin
// BEFORE — Compose routes through the Android system clipboard (DLP bypass)
@Composable
fun CopyLabel(label: String) {
    val clipboardManager = LocalClipboardManager.current
    Button(onClick = { clipboardManager.setText(AnnotatedString(label)) }) {
        Text("Copy")
    }
}

// AFTER — interim adapter backed by com.good.gd.content.ClipboardManager
@Composable
fun CopyLabel(label: String) {
    val context = LocalContext.current
    val gdClipboard = remember(context) { GDClipboardAdapter(context) }
    Button(onClick = { gdClipboard.setPlainText(label) }) {
        Text("Copy")
    }
}
```

**Migration rules for Compose clipboard:**
- Do **not** leave `LocalClipboardManager.current` or `LocalClipboard.current`
  in migrated production code.
- Do **not** continue using Compose `ClipboardManager` / `Clipboard` /
  `ClipEntry` for app-controlled copy/paste after migration.
- Do **not** use `context.getSystemService(Context.CLIPBOARD_SERVICE)` or
  `android.content.ClipboardManager` as a workaround.
- Plain-text `setText` / `getText` and `ClipData.newPlainText` flows →
  `GDClipboardAdapter.setPlainText` / `getPlainText`.
- Rich or non-plain `ClipEntry` payloads (URI lists, intents, HTML) → record a
  **high**-priority `manualTodos[]` entry; do not silently defer.

### Migration Rules

- Replace ALL `android.content.ClipboardManager` usage with
  `com.good.gd.content.ClipboardManager` — there are no exceptions
- This includes utility/extension functions, custom views, dialogs,
  and any other code that reads or writes the clipboard
- Replace app payload drag/drop start calls with
  `ClipboardManager.startDragAndDrop(...)` and use
  `ClipboardManager.getClipData(DragEvent)` when handling drops
- `android.content.ClipData` does NOT need to change — only the
  `ClipboardManager` class is replaced
- The secure clipboard requires the container to be unlocked, but
  clipboard operations only happen during user interaction (post-auth),
  so no authorization deferral is needed

### Full Widget List (direct replacement family)

The SDK provides these secure widget classes. All are 1:1 drop-in
replacements for the standard Android / AppCompat widget with the same
name suffix.

| Widget | Package | Replaces |
|--------|---------|----------|
| `GDEditText` | `com.good.gd.widget` | `android.widget.EditText` |
| `GDTextView` | `com.good.gd.widget` | `android.widget.TextView` / `MaterialTextView` |
| `GDAutoCompleteTextView` | `com.good.gd.widget` | `android.widget.AutoCompleteTextView` |
| `GDMultiAutoCompleteTextView` | `com.good.gd.widget` | `android.widget.MultiAutoCompleteTextView` |
| `GDSearchView` | `com.good.gd.widget` | `android.widget.SearchView` |
| `GDAppCompatEditText` | `com.good.gd.widget` | `androidx.appcompat.widget.AppCompatEditText` |
| `GDAppCompatTextView` | `com.good.gd.widget` | `androidx.appcompat.widget.AppCompatTextView` |
| `GDAppCompatCheckedTextView` | `com.good.gd.widget` | `androidx.appcompat.widget.AppCompatCheckedTextView` |
| `GDAppCompatAutoCompleteTextView` | `com.good.gd.widget` | `androidx.appcompat.widget.AppCompatAutoCompleteTextView` |
| `GDAppCompatMultiAutoCompleteTextView` | `com.good.gd.widget` | `androidx.appcompat.widget.AppCompatMultiAutoCompleteTextView` |
| `GDAppCompatSearchView` | `com.good.gd.widget` | `androidx.appcompat.widget.SearchView` |
| `GDTextInputEditText` | `com.good.gd.widget` | `com.google.android.material.textfield.TextInputEditText` |

> **`com.good.gd.widget.GDWebView` is intentionally not in this list.**
> It is legacy/deprecated. The only supported secure WebView is
> `com.blackberry.bbwebview.BBWebView` (see `50-webview-bbwebview.md`).
> If you discover existing migrated code or generated output using
> `GDWebView`, treat it as a defect and migrate to `BBWebView`.

Widgets outside this list remain native by design and must be documented via
`keepNativeRows[]` residual-risk handling.

### Clipboard Manager

See the detailed **Secure Clipboard (MANDATORY for DLP Enforcement)**
section above for import changes, instance creation patterns, and
migration rules.

### Limitation

The `setOnReceiveContentListener` method is NOT supported on any of the
GD widget classes.

---

## Output

- UI widget inventory table (widget type, sensitivity classification
  **for reporting only**, action taken — migrated /
  deferred-via-`secureUiWidgets` / out-of-scope-third-party)
- List of XML layout files modified
- List of Java/Kotlin files modified
- For any covered widget left unmigrated: the `secureUiWidgets`
  entry in `bootstrap.json.deferredDomains[]` (per-call-site local
  rationale is not accepted)
- Testing notes for UI functionality

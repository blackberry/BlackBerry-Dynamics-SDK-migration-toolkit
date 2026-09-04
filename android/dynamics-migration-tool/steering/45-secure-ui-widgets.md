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
  (binding-compatible with `GDTextView`, but see the
  `MaterialTextView` cast note below)

Check both Java/Kotlin code and XML layouts. Custom subclasses that
extend any of these base classes also need migration (see "Custom
Subclasses" below).

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

**All covered standard / AppCompat / Material text and search widgets
in app-controlled UI must migrate to their `com.good.gd.widget.*`
equivalent. Exceptions require a developer-signed deferral of the
`secureUiWidgets` domain in `bootstrap.json.deferredDomains[]`, not a
local sensitivity rationale.**

### Why "every widget" and not "only the sensitive ones"

DLP enforcement lives on the **widget class**, not on the data flowing
through it. A `TextView` that today holds a brand name can tomorrow
be reused to display an account number, a meeting attendee list, or a
clipboard suggestion. Even when nothing sensitive ever flows through
it, the system long-press action bar, screenshot capture path, share
intent, and autofill provider all hook the widget itself. Leaving any
covered widget on the standard class punches a permanent hole in DLP
for that screen.

Phrased more carefully: replace every usage of the covered text/search
widget family unless it is provably decorative/static **and** cannot
participate in selection, editing, search input, suggestions,
clipboard, or user-entered/displayed business data. In practice almost
no `TextView` / `EditText` / `SearchView` clears that bar — which is
why the simpler operational rule above (migrate everything, defer the
whole domain if you cannot) is what the validator enforces.

### When to Replace

Replace **every** match in the covered family across app-controlled
UI:
- Java/Kotlin call sites that bind, construct, or reference a covered
  standard / AppCompat / Material class.
- XML layout elements declaring a covered tag.
- Custom subclasses extending any covered base (see "Custom
  Subclasses" below).

The previous "replace when displaying sensitive data / clipboard
applies / DLP applies" trigger list is **deprecated** — those
conditions are always-on for any widget that can take focus or be
selected, which is every member of the covered family.

### Widget Mapping (direct replacement family)

All of the rows below are deterministic 1:1 replacements. None of them
introduce behavior changes beyond DLP enforcement (screenshot/clipboard
/copy-paste).

| Standard Android / AppCompat / Material | BlackBerry Dynamics |
|-----------------------------------------|---------------------|
| `android.widget.EditText` | `com.good.gd.widget.GDEditText` |
| `android.widget.TextView` | `com.good.gd.widget.GDTextView` |
| `android.widget.AutoCompleteTextView` | `com.good.gd.widget.GDAutoCompleteTextView` |
| `android.widget.MultiAutoCompleteTextView` | `com.good.gd.widget.GDMultiAutoCompleteTextView` |
| `android.widget.SearchView` / `androidx.appcompat.widget.SearchView` | `com.good.gd.widget.GDSearchView` |
| `androidx.appcompat.widget.AppCompatEditText` | `com.good.gd.widget.GDAppCompatEditText` |
| `androidx.appcompat.widget.AppCompatTextView` | `com.good.gd.widget.GDAppCompatTextView` |
| `androidx.appcompat.widget.AppCompatCheckedTextView` | `com.good.gd.widget.GDAppCompatCheckedTextView` |
| `androidx.appcompat.widget.AppCompatAutoCompleteTextView` | `com.good.gd.widget.GDAppCompatAutoCompleteTextView` |
| `androidx.appcompat.widget.AppCompatMultiAutoCompleteTextView` | `com.good.gd.widget.GDAppCompatMultiAutoCompleteTextView` |
| `com.google.android.material.textview.MaterialTextView` | `com.good.gd.widget.GDTextView` |

> **WebView is not in this table.** Replace `android.webkit.WebView`
> with `com.blackberry.bbwebview.BBWebView` per prompt `07` and
> `50-webview-bbwebview.md`. `com.good.gd.widget.GDWebView` is
> deprecated and must not be used.

When XML is migrated from `MaterialTextView` to `GDTextView`, **every** Java/Kotlin
binding for those `@id` values must use `GDTextView`. Leaving `MaterialTextView`
in code causes `ClassCastException` at inflation time — see `95-troubleshooting.md`.
The same binding rule applies to every entry in the table above: if you change
the XML element class, every Java/Kotlin `findViewById`/view-binding type for
that `@id` must change to the GD replacement type, otherwise inflation throws
`ClassCastException`.

---

## Migration: Import Changes (Java/Kotlin)

```java
// REMOVE these imports (if present)
import android.widget.EditText;
import android.widget.TextView;

// ADD these imports
import com.good.gd.widget.GDEditText;
import com.good.gd.widget.GDTextView;
```

Before editing, run source-level inventory scans that match validator
Phase 8 import checks:

```bash
rg 'import\s+android\.widget\.(EditText|TextView|AutoCompleteTextView|MultiAutoCompleteTextView|SearchView)\b' app/src/main/java app/src/main/kotlin
rg 'import\s+androidx\.appcompat\.widget\.(AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|SearchView)\b' app/src/main/java app/src/main/kotlin
rg 'import\s+com\.google\.android\.material\.textview\.MaterialTextView\b' app/src/main/java app/src/main/kotlin
```

---

## Migration: XML Layout Changes

```xml
<!-- OLD -->
<EditText
    android:id="@+id/passwordField"
    android:layout_width="match_parent"
    android:layout_height="wrap_content" />

<!-- NEW -->
<com.good.gd.widget.GDEditText
    android:id="@+id/passwordField"
    android:layout_width="match_parent"
    android:layout_height="wrap_content" />
```

```xml
<!-- OLD -->
<TextView
    android:id="@+id/sensitiveData"
    android:layout_width="match_parent"
    android:layout_height="wrap_content" />

<!-- NEW -->
<com.good.gd.widget.GDTextView
    android:id="@+id/sensitiveData"
    android:layout_width="match_parent"
    android:layout_height="wrap_content" />
```

---

## Migration: Java/Kotlin Code Changes

```java
// OLD
EditText passwordField = (EditText) view.findViewById(R.id.passwordField);
TextView dataView = (TextView) view.findViewById(R.id.sensitiveData);

// NEW — only if XML uses <com.good.gd.widget.GDEditText> / GDTextView
GDEditText passwordField = (GDEditText) view.findViewById(R.id.passwordField);
GDTextView dataView = (GDTextView) view.findViewById(R.id.sensitiveData);

// NEW — if the theme uses GDAppCompatViewInflater (XML stays <EditText>)
// GDAppCompatEditText does NOT extend GDEditText. Bind as EditText / TextView.
EditText passwordField = view.findViewById(R.id.passwordField);
TextView dataView = view.findViewById(R.id.sensitiveData);
```

### API Compatibility

GDEditText and GDTextView extend the standard Android widgets, so:
- All standard methods work (`setText()`, `getText()`, `setHint()`, etc.)
- Only the type declaration and import need to change
- No other code changes required

---

## IMPORTANT: Update Both XML AND Java/Kotlin

When migrating widgets, you MUST update:
1. **XML layout files** - Change the element name to fully qualified class
2. **Java/Kotlin code** - Change the import and variable type

Missing either will cause runtime errors or lose security benefits.

### Checklist per Widget

- [ ] Update XML layout element name
- [ ] Update Java/Kotlin import statement
- [ ] Update variable type declaration
- [ ] Verify no casting errors

### Mandatory post-migration verification

Run these checks before recording prompt `09`:

```bash
rg 'import\s+android\.widget\.(AutoCompleteTextView|MultiAutoCompleteTextView|SearchView)\b' app/src/main/java app/src/main/kotlin
rg 'import\s+androidx\.appcompat\.widget\.(AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|SearchView)\b' app/src/main/java app/src/main/kotlin
rg 'import\s+com\.google\.android\.material\.textview\.MaterialTextView\b' app/src/main/java app/src/main/kotlin
rg 'findViewById\([^)]*\)\s*(as\s+(EditText|TextView|AutoCompleteTextView|MultiAutoCompleteTextView|AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|MaterialTextView)|:\s*(EditText|TextView|AutoCompleteTextView|MultiAutoCompleteTextView|AppCompatEditText|AppCompatTextView|AppCompatCheckedTextView|AppCompatAutoCompleteTextView|AppCompatMultiAutoCompleteTextView|MaterialTextView)\b)' app/src/main/java app/src/main/kotlin
bash dynamics-migration-tool/tooling/validate.sh --check-prompt 09
```

All scans above should return zero matches for unresolved standard/widget
bindings before prompt `09` is recorded as completed.

---

## When NOT to Replace

The covered text/search widget family is an all-or-nothing migration.
Legitimate exclusions are limited to:

- **Third-party / vendored UI you do not control** — closed-source
  libraries that inflate their own `EditText` / `TextView`. Record
  these as manual TODOs; they do **not** satisfy the migration rule
  for app-controlled UI. If any in-scope call site remains standard,
  the developer must defer `secureUiWidgets`.
- **Domain-level deferral** of `secureUiWidgets` recorded by the
  developer in `bootstrap.json.deferredDomains[]`. This is the only
  sanctioned escape for app-controlled call sites.

Do **not** use any of the following as a reason to leave a covered
widget on the standard class — the validator will reject them and the
DLP threat model explicitly contradicts them:

- "It's a static label / UI chrome."
- "It never carries sensitive data."
- "It's read-only / not focusable today."
- "It's performance-critical."

All of those still take part in selection, copy/paste, screenshots,
share intents, autofill, and suggestions at the framework level.

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

This approach is simpler than manual replacement and applies to ALL
widgets of the covered types — which matches the all-or-nothing
migration rule above. It is the recommended path for AppCompat apps:
because every covered widget must migrate anyway, selectively excluding
"non-sensitive" widgets is neither possible nor desirable.

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
inherit the DLP protection automatically.

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

> **`com.good.gd.widget.GDWebView` is intentionally not in this list.**
> It is legacy/deprecated. The only supported secure WebView is
> `com.blackberry.bbwebview.BBWebView` (see `50-webview-bbwebview.md`).
> If you discover existing migrated code or generated output using
> `GDWebView`, treat it as a defect and migrate to `BBWebView`.

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

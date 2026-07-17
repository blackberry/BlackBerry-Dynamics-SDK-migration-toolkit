# Steering: Inline Migration Comments

Every code change made during the BlackBerry Dynamics migration **must** include
an inline comment at the exact point of modification. This allows any developer
reviewing a diff to immediately understand what changed and why.

---

## Comment Tag

There is exactly **one** migration tag:

- `[BB_DYNAMICS-MIGRATION]` — marks a line that was migrated to a
  Dynamics implementation. This tag is **audit-only**: validators do
  not suppress findings on its account.

The toolkit does not support line-level exceptions. If a call-site
cannot be migrated, the correct response is to either (a) refactor the
feature so the call-site is no longer needed using a Dynamics-compatible
API (e.g. a custom Glide loader backed by `GDFileSystem`-derived
`InputStream`/`byte[]`), or (b) ask the developer to record the
**entire owning domain** in `deferredDomains[]`. Deferrals are dated,
classified, expire, and surface as release-readiness blockers. The
agent must never invent a deferral.

---

## Comment Syntax by File Type

### Java / Kotlin

```java
// [BB_DYNAMICS-MIGRATION] Replaced android.database.sqlite.SQLiteDatabase with Dynamics secure SQLiteDatabase
import com.good.gd.database.sqlite.SQLiteDatabase;
```

### Groovy Gradle (build.gradle)

```groovy
// [BB_DYNAMICS-MIGRATION] Added BlackBerry Dynamics SDK dependency
implementation "com.blackberry.blackberrydynamics:android_handheld_platform:$dynamics_version"

// [BB_DYNAMICS-MIGRATION] Added BlackBerry Maven repository for Dynamics SDK
maven { url = 'https://software.download.blackberry.com/repository/maven' }
```

### Kotlin DSL Gradle (build.gradle.kts)

```kotlin
// [BB_DYNAMICS-MIGRATION] Added BlackBerry Dynamics SDK dependency
implementation("com.blackberry.blackberrydynamics:android_handheld_platform:$dynamicsVersion")
```

### XML (AndroidManifest.xml, layouts, resources)

```xml
<!-- [BB_DYNAMICS-MIGRATION] Replaced EditText with GDEditText for secure input -->
<com.good.gd.widget.GDEditText
    android:id="@+id/fileContents"
    android:layout_width="fill_parent"
    android:layout_height="246dp" />
```

### JSON (settings.json) and other comment-less formats

JSON, YAML values, and binary files do not support inline comments.
Do NOT add fake keys, wrapper objects, or any other workaround to simulate
comments — they pollute the data and may cause parsing issues.

No `[BB_DYNAMICS-MIGRATION]` annotation is needed for these files. The migration
is tracked by surrounding files and commit history.

### Properties files (gradle.properties)

```properties
# [BB_DYNAMICS-MIGRATION] Enabled AndroidX and Jetifier for Dynamics SDK compatibility
android.enableJetifier=true
android.useAndroidX=true
```

### ProGuard rules (proguard-rules.pro)

```proguard
# [BB_DYNAMICS-MIGRATION] Keep Dynamics SDK classes from obfuscation
-keep class com.good.gd.** { *; }
```

---

## What to Comment

Add a `[BB_DYNAMICS-MIGRATION]` comment at every point where code was changed, added, or
removed for the Dynamics migration. Specifically:

### Import changes

```java
// [BB_DYNAMICS-MIGRATION] Replaced java.io.FileOutputStream with Dynamics secure FileOutputStream
import com.good.gd.file.FileOutputStream;
// [BB_DYNAMICS-MIGRATION] Added GDFileSystem for secure file I/O
import com.good.gd.file.GDFileSystem;
```

### API replacements

```java
// [BB_DYNAMICS-MIGRATION] Replaced context.openFileOutput() with GDFileSystem.openFileOutput() for encrypted storage
outputStream = GDFileSystem.openFileOutput(FILENAME, Context.MODE_PRIVATE);
```

### New interface implementations

```java
// [BB_DYNAMICS-MIGRATION] Added GDStateListener to handle Dynamics authorization lifecycle
public class MainActivity extends AppCompatActivity implements GDStateListener
```

### New method implementations

```java
// [BB_DYNAMICS-MIGRATION] Dynamics authorization callback — safe to access secure APIs after this fires
@Override
public void onAuthorized() {
    Log.d("MainActivity", "Dynamics authorized");
}
```

### Initialization calls

```java
// [BB_DYNAMICS-MIGRATION] Required Dynamics activity initialization — must be called before setContentView
GDAndroid.getInstance().activityInit(this);
```

### New files

If the new file's format supports inline comments, add a single
`[BB_DYNAMICS-MIGRATION]` comment at the top of the file. This helps a developer
immediately recognize the file was added as part of the Dynamics migration.

```java
// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration
```

```xml
<!-- [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration -->
```

If the file format does NOT support comments (JSON, binary, etc.), skip it —
do not use fake keys or workarounds.

### Layout widget replacements

```xml
<!-- [BB_DYNAMICS-MIGRATION] Replaced EditText with GDEditText for DLP-protected input -->
<com.good.gd.widget.GDEditText
    android:id="@+id/fileContents" />
```

### Gradle dependency and repository additions

```groovy
// [BB_DYNAMICS-MIGRATION] BlackBerry Maven repository required for Dynamics SDK artifacts
maven { url = 'https://software.download.blackberry.com/repository/maven' }

// [BB_DYNAMICS-MIGRATION] BlackBerry Dynamics SDK — provides secure storage, networking, and auth APIs
implementation "com.blackberry.blackberrydynamics:android_handheld_platform:$dynamics_version"
```

### Removed code

When removing code (e.g., removing RestrictionsManager), leave a comment at the
removal site:

```java
// [BB_DYNAMICS-MIGRATION] Removed RestrictionsManager — replaced by GDAndroid.getApplicationPolicy()
```

---

## Comment Style Rules

1. Use `[BB_DYNAMICS-MIGRATION]` on migrated lines. It is the **only**
   migration-related tag in this toolkit. Do not invent variants such
   as `[BB_DYNAMICS-WAIVER:...]` or `[BB_DYNAMICS-MIGRATION] EXCEPTION`
   — `validate.sh` rejects unknown audit tags.
2. Keep comments on the line immediately above or on the same line as the change
3. Be concise but specific — state what was replaced and why
4. Use the pattern: `Replaced X with Y for Z` or `Added X for Y`
5. Do not add comments to unchanged lines
6. One comment per logical change — don't repeat the same comment on consecutive related lines when a single comment above the block suffices
7. For entirely new files, add a single comment at the top if the format supports it — skip if it doesn't (JSON, binary, etc.)
8. Do NOT add comments to file formats that lack comment syntax (JSON, binary, etc.) — no fake keys or workarounds
9. If a call-site cannot be migrated, do not annotate it. Either
   refactor (preferred) or have the developer record a domain-level
   entry in `deferredDomains[]`. There is no line-level escape hatch.

---

## Verification

After migration, the developer can find all migration touchpoints with:

```bash
rg "\[BB_DYNAMICS-MIGRATION\]" -g "*.java" -g "*.kt" \
  -g "*.xml" -g "*.gradle" -g "*.gradle.kts" -n
```

This should return every file and line that was modified as part of
the BlackBerry Dynamics integration.

---

## Example: Complete Migrated Import Block

```java
// [BB_DYNAMICS-MIGRATION] Added Dynamics runtime and lifecycle imports
import com.good.gd.GDAndroid;
import com.good.gd.GDStateListener;

// [BB_DYNAMICS-MIGRATION] Replaced java.io.FileInputStream/FileOutputStream with Dynamics secure equivalents
import com.good.gd.file.FileInputStream;
import com.good.gd.file.FileOutputStream;
import com.good.gd.file.GDFileSystem;

// [BB_DYNAMICS-MIGRATION] Replaced android.database.sqlite with Dynamics secure database
import com.good.gd.database.sqlite.SQLiteDatabase;
import com.good.gd.database.sqlite.SQLiteOpenHelper;

// [BB_DYNAMICS-MIGRATION] Replaced android.widget.EditText with Dynamics secure widget
import com.good.gd.widget.GDEditText;
```

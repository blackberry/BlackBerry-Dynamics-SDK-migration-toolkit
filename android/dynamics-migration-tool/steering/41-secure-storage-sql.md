# Steering: Secure SQL Databases

Dynamics supports secure SQLite databases protected by policy.

> **Multi-module note**: SQLite/Room call sites and bridge templates
> commonly live in dedicated `core/database` library modules — scan
> `${in_scope_main_src}` from
> `dynamics-migration-tool/output/module-map.json`. Bridge templates
> (Room and SQLiteOpenHelper) are copied into the module that owns
> the database builder, not always `app/`. The owning library module
> receives the Dynamics SDK as `compileOnly` (see
> `01-gradle-integration.md`). For multi-module guidance see
> `04-multi-module-projects.md`.

---

## Required Analysis

Locate:
- SQLiteOpenHelper usage
- Room databases
- Raw SQLiteDatabase access

Identify:
- Database names
- Storage locations
- Schema ownership

---

## Migration: Import Changes

### SQLiteOpenHelper

```java
// REMOVE this import
import android.database.sqlite.SQLiteOpenHelper;

// ADD this import
import com.good.gd.database.sqlite.SQLiteOpenHelper;
```

### SQLiteDatabase

```java
// REMOVE this import
import android.database.sqlite.SQLiteDatabase;

// ADD this import
import com.good.gd.database.sqlite.SQLiteDatabase;
```

### Note on Cursor

The `Cursor` class remains from Android SDK:
```java
import android.database.Cursor;  // Keep this - no change needed
```

---

## Migration: SQLiteOpenHelper Example

```java
import android.content.Context;
import com.good.gd.database.sqlite.SQLiteDatabase;
import com.good.gd.database.sqlite.SQLiteOpenHelper;

public class MyDbHelper extends SQLiteOpenHelper {
    public static final int DATABASE_VERSION = 1;
    public static final String DATABASE_NAME = "MyDatabase.db";

    public MyDbHelper(Context context) {
        super(context, DATABASE_NAME, null, DATABASE_VERSION);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE my_table (id INTEGER PRIMARY KEY, name TEXT)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        // Handle upgrades
    }
}
```

---

## Migration: Database Usage Example

```java
import android.content.ContentValues;
import android.database.Cursor;
import com.good.gd.database.sqlite.SQLiteDatabase;

// Get database instance
MyDbHelper dbHelper = new MyDbHelper(context);
SQLiteDatabase db = dbHelper.getWritableDatabase();

// Insert
ContentValues values = new ContentValues();
values.put("name", "Example");
db.insert("my_table", null, values);

// Query
Cursor cursor = db.query("my_table", null, null, null, null, null, null);
while (cursor.moveToNext()) {
    String name = cursor.getString(cursor.getColumnIndexOrThrow("name"));
}
cursor.close();

// Update
ContentValues updateValues = new ContentValues();
updateValues.put("name", "Updated");
db.update("my_table", updateValues, "id = ?", new String[]{"1"});

// Close
db.close();
```

---

## Context in Fragments

In Fragments, use `getActivity()` for the Context parameter:

```java
// In a Fragment
MyDbHelper dbHelper = new MyDbHelper(getActivity());

// Use getActivity() for consistency with Dynamics APIs
```

---

## CRITICAL: Secure SQLite Requires an Unlocked Container

Dynamics secure SQLite (`com.good.gd.database.sqlite.*`) stores data inside
the encrypted Dynamics container. The container is locked when the app
starts and only becomes accessible after the SDK signals `onAuthorized()`.

This means:
- On **first launch**, the container does not even exist yet — the SDK must
  complete activation (provisioning with UEM) before any database can be
  created or queried.
- On **subsequent launches**, the container is locked until the user
  authenticates (password or biometric). No database access is possible
  until then.
- Any call to `getReadableDatabase()`, `getWritableDatabase()`, or
  `openOrCreateDatabase()` before the container is unlocked will throw
  `GDNotAuthorizedError` and crash the app.

**This is the #1 cause of crashes in migrated apps.** The original app
loads data in `onCreate()`. After migration the imports change to Dynamics
secure SQLite, but the call site stays in `onCreate()` — which runs before
the container is unlocked.

**Fix**: Move all database access into `onAuthorized()` or a method called
from it. The app's data-loading logic is effectively deferred until the
container is ready. See `20-auth-initialization.md` for the full
two-phase initialization pattern and container lifecycle details.

```java
// [NOT OK] WRONG — container is still locked in onCreate
@Override
protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    GDAndroid.getInstance().activityInit(this);
    setContentView(R.layout.activity_main);
    List<Item> items = dbHelper.getAllItems();  // CRASH: GDNotAuthorizedError
}

// [OK] CORRECT — container is unlocked when onAuthorized fires
@Override
public void onAuthorized() {
    runOnUiThread(() -> {
        List<Item> items = dbHelper.getAllItems();
        adapter = new MyAdapter(this, items);
        listView.setAdapter(adapter);
    });
}
```

---

## Migration Strategy

- Prefer minimal schema disruption
- Preserve migrations
- **All database access MUST happen after `onAuthorized()` fires** — review
  every call site (onCreate, onResume, background tasks) and verify it
  cannot execute before the container is unlocked
- API is identical to Android SQLite — only imports change
- Secondary activities launched after authorization can access the database
  normally (the container is already unlocked by then)

### IMPORTANT: Room LiveData Queries Fire Immediately When Observed

Room LiveData queries execute on `arch_disk_io` background threads as
soon as they are observed. If a ViewModel observes a Room DAO LiveData
in its `init {}` block (which runs during `Activity.onCreate()`), the
query fires before the container is authorized, causing
`GDNotAuthorizedError`.

This is a subtle trap because the crash happens on a background thread,
not on the line where `observe()` is called. The stack trace will show
Room's internal query executor hitting the Dynamics secure SQLite layer.

**Fix**: Defer all Room LiveData observation until after authorization.
See `21-authorization-deferral-patterns.md` for the ViewModel deferral
pattern (Pattern 2) and the Fragment deferral pattern (Pattern 3).

---

## Room Database Migration (IMPORTANT)

The import-swap approach above works for raw `SQLiteOpenHelper` usage.
However, if the app uses **Room**, the migration is significantly more
complex because Room uses its own `SupportSQLiteOpenHelper` abstraction.

### The Problem

Room does not use `android.database.sqlite.SQLiteOpenHelper` directly.
It uses `androidx.sqlite.db.SupportSQLiteOpenHelper`, which wraps the
Android SQLite classes. Simply swapping imports does not work — you need
a bridge layer that implements Room's interfaces using Dynamics SQLite.

### The Solution: Use the 5-file bridge template — do not write this from scratch

The bridge is ~300 lines across 5 inter-dependent adapters. Writing it from scratch
produces incorrect or scaffold-only code. Always use the template:

```bash
cp -r dynamics-migration-tool/templates/sql/room-bridge/ \
      app/src/main/java/<your/package>/dynamicsdb/
```

Replace `__APP_PACKAGE__` in each file, then wire the factory:

```java
// [BB_DYNAMICS-MIGRATION] Room database backed by Dynamics secure SQLite via GDRoomOpenHelperFactory.
AppDatabase db = Room.databaseBuilder(context, AppDatabase.class, "my_db")
    .openHelperFactory(new GDRoomOpenHelperFactory())   // ← wires the bridge
    .build();
```

**The factory's `create()` method MUST return a `GDRoomOpenHelper`, not a
`FrameworkSQLiteOpenHelperFactory` delegate.** Any bridge that ends with
`return new FrameworkSQLiteOpenHelperFactory().create(configuration)` is leaving
Room on standard unencrypted SQLite. This is the most common Room migration failure.

The 5 template files and their responsibilities:

1. **`GDRoomOpenHelperFactory`** — implements `SupportSQLiteOpenHelper.Factory`; `create()` returns a `GDRoomOpenHelper`
2. **`GDRoomOpenHelper`** — implements `SupportSQLiteOpenHelper`; wraps Dynamics `SQLiteOpenHelper` and forwards `onCreate`/`onUpgrade`/`onOpen` callbacks
3. **`GDRoomDatabase`** — implements `SupportSQLiteDatabase`; wraps Dynamics `SQLiteDatabase`; includes the `SQLiteTransactionListener` type-bridge
4. **`GDRoomStatement`** — implements `SupportSQLiteStatement`; wraps Dynamics `SQLiteStatement`
5. **`GDRoomQueryBindingHelper`** — implements `SupportSQLiteProgram`; captures `bindTo()` bindings as `String[]` for `rawQuery()`

### Key Pitfall: `SQLiteTransactionListener` Type Mismatch

Room's `SupportSQLiteDatabase.beginTransactionWithListener()` accepts
`android.database.sqlite.SQLiteTransactionListener`, but the Dynamics
`SQLiteDatabase.beginTransactionWithListener()` expects
`com.good.gd.database.sqlite.SQLiteTransactionListener`.

You must wrap the Android listener into a Dynamics listener:

```java
@Override
public void beginTransactionWithListener(
        android.database.sqlite.SQLiteTransactionListener listener) {
    db.beginTransactionWithListener(
        new com.good.gd.database.sqlite.SQLiteTransactionListener() {
            @Override public void onBegin() { listener.onBegin(); }
            @Override public void onCommit() { listener.onCommit(); }
            @Override public void onRollback() { listener.onRollback(); }
        });
}
```

### Key Pitfall: Query Binding

Room uses `SupportSQLiteQuery.bindTo(SupportSQLiteProgram)` to bind
parameters. The Dynamics `SQLiteDatabase.rawQuery()` expects a `String[]`
of arguments. You need a helper class that captures bindings from
`bindTo()` and converts them to a `String[]` for `rawQuery()`.

### Estimated Effort

The Room bridge is approximately 300-500 lines of adapter code across
5 new files:

1. **`GDSupportSQLiteOpenHelperFactory`** — implements `SupportSQLiteOpenHelper.Factory`
2. **`GDSupportSQLiteOpenHelper`** — wraps Dynamics `SQLiteOpenHelper`
3. **`GDSupportSQLiteDatabase`** — wraps Dynamics `SQLiteDatabase`
4. **`GDSupportSQLiteStatement`** — wraps Dynamics `SQLiteStatement`
5. **`GDQueryBindingHelper`** — captures Room query bindings for `rawQuery()` conversion

It requires thorough runtime testing because the adapter
layer is complex and type mismatches only surface at compile time or
runtime.

### Complete Method Catalog for Room Bridge (androidx.sqlite 2.4.0)

When implementing `GDSupportSQLiteDatabase`, you must implement every method
in `SupportSQLiteDatabase`. Missing any method causes a compile error. The
following three methods are most commonly overlooked:

| Method | Common Mistake |
|--------|----------------|
| `void setMaxSqlCacheSize(int cacheSize)` | Forgotten entirely — not obvious from the interface name |
| `void setLocale(Locale locale)` | Overlooked because Dynamics `SQLiteDatabase` uses a different locale API |
| `void close() throws IOException` | Implemented as `throws Exception` instead of `throws IOException` (from `Closeable`) |

#### Critical: `close()` Signature

`SupportSQLiteDatabase` extends `java.io.Closeable`, which declares:

```java
void close() throws IOException;
```

Do NOT declare `throws Exception` — it will not satisfy the interface and the
class will fail to compile. The correct implementation:

```java
@Override
public void close() throws IOException {
    db.close();  // Dynamics SQLiteDatabase.close() does not throw checked exceptions
}
```

#### Full `SupportSQLiteDatabase` Method List

```java
// Queries
Cursor query(String sql);
Cursor query(String sql, Object[] bindArgs);
Cursor query(SupportSQLiteQuery query);
Cursor query(SupportSQLiteQuery query, CancellationSignal cancellationSignal);

// DML
long insert(String table, int conflictAlgorithm, ContentValues values) throws SQLException;
int delete(String table, String whereClause, Object[] whereArgs);
int update(String table, int conflictAlgorithm, ContentValues values, String whereClause, Object[] whereArgs);
void execSQL(String sql) throws SQLException;
void execSQL(String sql, Object[] bindArgs) throws SQLException;

// Compiled statements
SupportSQLiteStatement compileStatement(String sql);

// Transactions
void beginTransaction();
void beginTransactionNonExclusive();
void beginTransactionWithListener(SQLiteTransactionListener listener);
void beginTransactionWithListenerNonExclusive(SQLiteTransactionListener listener);
void endTransaction();
void setTransactionSuccessful();
boolean inTransaction();

// Locking / yielding
boolean isDbLockedByCurrentThread();
boolean yieldIfContendedSafely();
boolean yieldIfContendedSafely(long sleepAfterYieldDelay);

// Version
int getVersion();
void setVersion(int version);

// Size / page
long getMaximumSize();
long setMaximumSize(long numBytes);
long getPageSize();
void setPageSize(long numBytes);

// State
String getPath();
boolean isOpen();
boolean needUpgrade(int newVersion);
boolean isReadOnly();
boolean isWriteAheadLoggingEnabled();
void setForeignKeyConstraintsEnabled(boolean enable);
boolean enableWriteAheadLogging();
void disableWriteAheadLogging();

// Integrity / attached
List<Pair<String, String>> getAttachedDbs();
boolean isDatabaseIntegrityOk();

// Commonly missed
void setMaxSqlCacheSize(int cacheSize);
void setLocale(Locale locale);

// From Closeable — must be IOException, NOT Exception
void close() throws IOException;
```

#### Full `SupportSQLiteStatement` Method List

`SupportSQLiteStatement` extends `SupportSQLiteProgram` (which extends `Closeable`):

```java
// Execution (SupportSQLiteStatement)
void execute();
long executeInsert();
int executeUpdateDelete();
long simpleQueryForLong();
String simpleQueryForString();

// Bindings (from SupportSQLiteProgram)
void bindNull(int index);
void bindLong(int index, long value);
void bindDouble(int index, double value);
void bindString(int index, String value);
void bindBlob(int index, byte[] value);
void clearBindings();

// From Closeable
void close() throws IOException;
```

#### Full `SupportSQLiteProgram` Method List (used by `GDQueryBindingHelper`)

`SupportSQLiteProgram` extends `Closeable` and is implemented by
`GDQueryBindingHelper` to capture bindings for `rawQuery()`:

```java
void bindNull(int index);
void bindLong(int index, long value);
void bindDouble(int index, double value);
void bindString(int index, String value);
void bindBlob(int index, byte[] value);
void clearBindings();
void close() throws IOException;  // no-op in the binding helper
```

### Key Pitfall: SQLCipher Coexistence

If the app already uses SQLCipher, remove it before wiring the Dynamics bridge factory.
The Dynamics container encrypts all data at rest; running both is redundant and the
SQLCipher passphrase may not be available before `onAuthorized()`.

See `15-redundant-feature-removal.md` (Category 3) for the full SQLCipher removal procedure.
A Dynamics conversion is always a fresh install
(`18-fresh-dynamics-install.md`): remove SQLCipher and wire Dynamics
SQLite. Do not add a rekey/copy helper.

**Wire the factory unconditionally** after SQLCipher is removed:

```kotlin
// CORRECT — factory always applied after SQLCipher removal
val db = Room.databaseBuilder(context, AppDatabase::class.java, DB_NAME)
    .openHelperFactory(GDRoomOpenHelperFactory())
    .build()
```

**DO NOT** use a conditional that leaves the factory unwired for some code paths:

```kotlin
// WRONG — leaves Room on unencrypted SQLite when usingSQLCipher is true
if (!usingSQLCipher) {
    instanceBuilder.openHelperFactory(GDRoomOpenHelperFactory())
}
```

If you cannot remove SQLCipher immediately (e.g., it requires a separate PR), mark the
domain as deferred in `bootstrap.json` with `developerSignedOff: true` and a reason.
Do not merge a migration report that claims `secureSql: migrated` while the conditional
above is still present.

### Key Pitfall: Exception Classes Have No Dynamics Equivalent

Android SQLite exception classes like `SQLiteBlobTooBigException`,
`SQLiteConstraintException`, and `SQLiteException` do NOT have Dynamics
equivalents. These imports MUST remain as `android.database.sqlite.*`:

```kotlin
// These are CORRECT — no Dynamics equivalent exists
import android.database.sqlite.SQLiteBlobTooBigException
import android.database.sqlite.SQLiteConstraintException
```

Do not flag these as unmigrated. They are exception types used for error
handling, not data access APIs.

### Key Pitfall: External Database Access Is Legitimate

Apps that import or restore data from external SQLite files (e.g., backup
restore) legitimately use `android.database.sqlite.SQLiteDatabase.openDatabase()`
to read standard (non-encrypted) database files from disk. This is NOT
the app's own database — it's reading an external file.

```kotlin
// This is CORRECT — reading an external backup file, not the app's database
val database = SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY)
```

Do not migrate this to Dynamics secure SQLite. The external file is not
inside the Dynamics container.

### Key Pitfall: `RoomDatabase.Builder.hasOpenHelperFactory()` Does Not Exist

Some migration agents attempt to call `RoomDatabase.Builder.hasOpenHelperFactory()`
to conditionally apply the GD factory only when SQLCipher is not active. This
method does **not exist** in the public Room API — it is an internal method or
does not exist at all, depending on the Room version.

**Fix**: Use a boolean flag instead of reflection or API probing:

```kotlin
val instanceBuilder = Room.databaseBuilder(context, AppDatabase::class.java, DB_NAME)
if (!usingSqlCipher) {
    instanceBuilder.openHelperFactory(GDSupportSQLiteOpenHelperFactory())
}
```

### Key Pitfall: `SimpleSQLiteQuery.bind()` Is Private

The `GDSupportSQLiteDatabase.query(SupportSQLiteQuery)` implementation needs
to extract SQL and bind args from a `SupportSQLiteQuery`. A common approach
is to call `SimpleSQLiteQuery.bind()` or `SimpleSQLiteQuery.Companion.bind()`,
but this method is **private** in the `SimpleSQLiteQuery` class.

**Fix**: Create a `QueryBindingHelper` class that implements
`SupportSQLiteProgram` and captures bindings via `bindTo()`:

```kotlin
class QueryBindingHelper : SupportSQLiteProgram {
    private val bindings = mutableMapOf<Int, String>()

    fun getBindings(): Array<String> {
        if (bindings.isEmpty()) return emptyArray()
        val maxIndex = bindings.keys.max()
        return Array(maxIndex) { i -> bindings[i + 1] ?: "" }
    }

    override fun bindString(index: Int, value: String) { bindings[index] = value }
    override fun bindLong(index: Int, value: Long) { bindings[index] = value.toString() }
    override fun bindDouble(index: Int, value: Double) { bindings[index] = value.toString() }
    override fun bindBlob(index: Int, value: ByteArray) { bindings[index] = String(value) }
    override fun bindNull(index: Int) { bindings[index] = "" }
    override fun clearBindings() { bindings.clear() }
    override fun close() {}
}
```

Usage in `GDSupportSQLiteDatabase`:

```kotlin
override fun query(query: SupportSQLiteQuery): Cursor {
    val helper = QueryBindingHelper()
    query.bindTo(helper)
    return db.rawQuery(query.sql, helper.getBindings())
}
```

---

## Output

- Database inventory
- Migration approach
- Risks or manual verification steps

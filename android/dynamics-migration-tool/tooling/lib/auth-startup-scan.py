#!/usr/bin/env python3
"""
Phase 11 auth-startup scanner.

Reads in-scope source roots from:
  MM_IN_SCOPE_SOURCE_ROOTS_P11
  SRC_DIR_P11

Emits stable KEY=value lines consumed by phase-11.sh and the maintainer
hardening smoke.
"""

import os
import re
import sys
import xml.etree.ElementTree as ET

walk_roots = [
    r for r in os.environ.get("MM_IN_SCOPE_SOURCE_ROOTS_P11", "").split()
    if r.strip()
]
src_dir_fallback = os.environ.get("SRC_DIR_P11", "").strip()
if not walk_roots and src_dir_fallback:
    walk_roots = [src_dir_fallback]

manifest_paths = []
for p in os.environ.get("MM_IN_SCOPE_MANIFESTS_P11", "").split():
    if not p.strip():
        continue
    ap = os.path.abspath(p)
    if os.path.isfile(ap):
        manifest_paths.append(ap)

SKIP_DIRS = {
    "build", ".gradle", ".git", "out", "intermediates",
    "node_modules", "dynamics-migration-tool",
}

CLASS_RE = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)")
OBJECT_RE = re.compile(r"\bobject\s+([A-Za-z_][A-Za-z0-9_]*)")
# Top-level `object Foo` (column 0). Skips indented companion objects.
TOPLEVEL_OBJECT_RE = re.compile(r"(?m)^object\s+([A-Za-z_][A-Za-z0-9_]*)")
JAVA_PARENT_RE = re.compile(
    r"\bclass\s+[A-Za-z_][A-Za-z0-9_]*\s+extends\s+([A-Za-z_][A-Za-z0-9_]*)"
)
KT_PARENT_RE = re.compile(
    r"\bclass\s+[A-Za-z_][A-Za-z0-9_<>, ]*\s*:\s*([A-Za-z_][A-Za-z0-9_]*)"
)
ACTIVITY_MARKER_RE = re.compile(
    r"extends\s+\S*Activity\b|:\s*\S*Activity\s*[<(]"
)
APPLICATION_MARKER_RE = re.compile(r"extends\s+.*Application|:\s*.*Application\(")
SERVICE_MARKER_RE = re.compile(r"extends\s+.*Service|:\s*.*Service\(")
RECEIVER_MARKER_RE = re.compile(r"extends\s+.*BroadcastReceiver|:\s*.*BroadcastReceiver\(")
FRAGMENT_MARKER_RE = re.compile(r"extends\s+.*Fragment|:\s*.*Fragment\(")
WORKER_MARKER_RE = re.compile(
    r"extends\s+.*(?:CoroutineWorker|ListenableWorker|Worker)\b|"
    r":\s*.*(?:CoroutineWorker|ListenableWorker|Worker)\("
)
PROVIDER_MARKER_RE = re.compile(r"extends\s+.*ContentProvider|:\s*.*ContentProvider\(")
APP_STARTUP_INITIALIZER_RE = re.compile(
    r"\b(?:androidx\.startup\.)?Initializer\b|:\s*.*Initializer\s*<"
)
WORK_MANAGER_CONFIG_PROVIDER_RE = re.compile(
    r"\b(?:androidx\.work\.)?Configuration\.Provider\b"
)
WORKER_FACTORY_MARKER_RE = re.compile(
    r"extends\s+.*(?:androidx\.work\.)?WorkerFactory\b|"
    r":\s*.*(?:androidx\.work\.)?WorkerFactory\("
)
ACTIVITY_INIT_RE = re.compile(r"\bactivityInit\s*\(")

VIEWMODEL_RE = re.compile(r"\b(AndroidViewModel|ViewModel)\b")
ROOM_RE = re.compile(
    r"androidx\.room|RoomDatabase|SupportSQLiteOpenHelper|"
    r"\b[A-Za-z_][A-Za-z0-9_]*Dao\b"
)
INIT_BLOCK_RE = re.compile(r"\binit\s*\{")
DB_DANGER_RE = re.compile(
    r"observeForever|\.observe\s*\(|asLiveData\s*\(|"
    r"getWritableDatabase|getReadableDatabase|openOrCreateDatabase|"
    r"writableDatabase|readableDatabase"
)
AUTH_GUARD_RE = re.compile(
    r"authorized\s*\.observe|getAuthorized\s*\(\)\s*\.observe|"
    r"isContainerAuthorized|databaseReady|runOnAuthorized"
)
DATABASE_READY_RE = re.compile(r"\bdatabaseReady\b")
MANUAL_BOOTSTRAP_METHOD_RE = re.compile(
    r"(?i)\b(startObserving|startListening|bootstrap|bootstrapData|"
    r"wireDatabase|wireObservers|attachObservers|initDatabase|initializeDatabase)\b"
)
MODEL_READY_CALL_RE = re.compile(
    r"\b(?:baseModel|viewModel|model)\s*\.\s*startObserving\s*\(|"
    r"databaseReady\s*\.observe|runOnAuthorized|getAuthorized\s*\(\)\s*\.observe|"
    r"authorized\s*\.observe"
)
MODEL_FIELD_ACCESS_RE = re.compile(r"\b(?:baseModel|viewModel|model)\.")

DEFERRED_MARKER_RE = re.compile(
    r"authorized\s*\.observe|getAuthorized\s*\(\)\s*\.observe|"
    r"databaseReady|runOnAuthorized|isContainerAuthorized"
)

STARTUP_METHOD_NAMES = (
    "onViewCreated", "onCreateView", "onActivityCreated",
    "onAttach", "onStart",
    "getObservable", "setupObserver", "setupObservers",
    "observeData", "subscribeUi", "subscribeUI",
    "setupAdapter", "initAdapter", "createAdapter",
)
STARTUP_SCOPE_RE = re.compile(
    r"\b(" + "|".join(STARTUP_METHOD_NAMES) + r")\b"
)
STARTUP_EXPR_OVERRIDE_RE = re.compile(
    r"\boverride\s+fun\s+(?:" + "|".join(STARTUP_METHOD_NAMES)
    + r")\b[^=\n]*=\s*[^\n]*!!"
)
STARTUP_HEADER_BANG_RE = re.compile(
    r"\b(?:fun|override\s+fun)\s+(?:" + "|".join(STARTUP_METHOD_NAMES)
    + r")\b[^\n]*!!"
)
RISKY_BANG_RE = re.compile(
    r"\b([A-Za-z_][A-Za-z0-9_]{1,40})(?:\.[A-Za-z_][A-Za-z0-9_]*){0,4}!!"
)
_TYPE_PARAM = r"<[^<>]*(?:<[^<>]*>[^<>]*)*>"
NULLABLE_LD_RE = re.compile(
    r"(?:Mutable|Mediator)?LiveData" + _TYPE_PARAM + r"\?\s*=\s*null|"
    r"(?:Mutable)?StateFlow" + _TYPE_PARAM + r"\?\s*=\s*null"
)
PLACEHOLDER_RE = re.compile(
    r"(?:Mutable|Mediator)?LiveData" + _TYPE_PARAM + r"\s*\([^)\s][^)]*\)|"
    r"(?:Mutable)?StateFlow" + _TYPE_PARAM + r"\s*\([^)\s][^)]*\)|"
    r"MediatorLiveData" + _TYPE_PARAM + r"\s*\(\s*\)\s*\.apply\s*\{[^}]*value\s*=|"
    r"\bemptyFlow\s*\(|UiState\.Loading|\bpostValue\s*\("
)

SECURE_TOKEN_PATTERNS = {
    "file": re.compile(r"GDFileSystem|GDFileHelper|com\.good\.gd\.file\."),
    "db": re.compile(
        r"com\.good\.gd\.database\.sqlite|GDSQLite|GDSQLite|"
        r"getWritableDatabase|getReadableDatabase|openOrCreateDatabase|"
        r"\breadableDatabase\b|\bwritableDatabase\b"
    ),
    "policy": re.compile(
        r"getApplicationPolicy(?:String)?|getApplicationConfig(?:String)?"
    ),
    "clipboard": re.compile(
        r"com\.good\.gd\.content\.ClipboardManager|GDClipboardAdapter"
    ),
    "network": re.compile(r"GDHttpClient|GDSocket|BBCustomInterceptor"),
}
# Categories that AUTH-PREF-001 reports from Activity/Application lifecycle.
PREF_AUTH_CATEGORIES = frozenset({"file", "prefs"})
PREF_LIFECYCLE_METHODS = ("onCreate", "onStart", "onResume")
# Prefs-helper I/O call sites (not mere construction — constructors are often
# side-effect free; GD file I/O lives in get/put/open methods).
# Optional `()` so Kotlin `object SecurePreferencesHelper.getString(` matches
# as well as Java `new SecurePreferencesHelper().getString(`.
PREFS_HELPER_IO_CALL_RE = re.compile(
    r"\b(?:SecurePreferencesHelper|SecurePrefs(?:Helper|Store)?|SecureFileStore|"
    r"SecureFileIO|SecureFileHelper)"
    r"(?:\s*\([^)]*\))?"
    r"\s*\.\s*"
    r"(?:get|put|remove|contains|read|write|open|delete|exists|load|"
    r"prefsFile|clear|getAll|invalidate)\w*\s*\("
)
# Repository property chains that perform prefs I/O without a `(` call:
# `preferences.theme.value`, `prefs.isLockEnabled`.
# Negative lookbehind skips `model.preferences` / `viewModel.preferences`
# (typical post-auth Fragment UI). AUTH-PREF still sees Activity fields.
# `preferences.theme.value`, `prefs.isLockEnabled` — field-named chains.
# Named `FooPreferences.getInstance().theme.value` is handled separately so
# plain data classes ending in Preferences are not flagged.
PREFS_FIELD_CHAIN_RE = re.compile(
    r"(?<![.\w])(?:preferences|prefs|settings)\s*\.\s*[A-Za-z_][A-Za-z0-9_]*"
    r"\s*\.\s*(?:value|getFreshValue)\b"
    r"|(?<![.\w])(?:preferences|prefs|settings)\s*\.\s*(?:isLockEnabled)\b"
)
PREFS_NAMED_PREFERENCES_CHAIN_RE = re.compile(
    r"\b([A-Z][A-Za-z0-9_]*Preferences)(?:\.getInstance\s*\([^)]*\))?"
    r"\s*\.\s*[A-Za-z_][A-Za-z0-9_]*\s*\.\s*(?:value|getFreshValue)\b"
)
PREFS_PROPERTY_CHAIN_RE = PREFS_FIELD_CHAIN_RE
# `if (!isContainerAuthorized) return` / braced `{ log; return }` — remainder
# of the method is post-auth. Head only; body is resolved with brace matching
# so nested `{ }` and multi-line guards work. Optional `()` covers Java
# `isContainerAuthorized()`.
AUTH_EARLY_RETURN_HEAD_RE = re.compile(
    r"if\s*\(\s*!(?:[A-Za-z_][A-Za-z0-9_.]*\.)?"
    r"(?:isContainerAuthorized|databaseReady)\s*(?:\(\s*\))?\s*\)"
)
GD_FILE_IMPORT_RE = re.compile(
    r"import\s+com\.good\.gd\.file\.([A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?"
)
INSTANCE_CALL_RE = re.compile(
    r"\b([a-z_][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\("
)
CHAINED_CTOR_CALL_RE = re.compile(
    r"\b([A-Z][A-Za-z0-9_]*)\s*\([^;)\n]*\)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\("
)
KT_TYPED_FIELD_RE = re.compile(
    r"(?:val|var)\s+([a-z_][A-Za-z0-9_]*)\s*:\s*([A-Z][A-Za-z0-9_]*)"
)
KT_ASSIGN_FIELD_RE = re.compile(
    r"(?:val|var)\s+([a-z_][A-Za-z0-9_]*)\s*=\s*([A-Z][A-Za-z0-9_]*)\s*\("
)
KT_LAZY_FIELD_RE = re.compile(
    r"(?:val|var)\s+([a-z_][A-Za-z0-9_]*)\s+by\s+lazy\s*(?:\{|\()\s*"
    r"([A-Z][A-Za-z0-9_]*)\s*\("
)
JAVA_FIELD_RE = re.compile(
    r"(?:private|protected|public|final|static|\s)+([A-Z][A-Za-z0-9_]*)\s+"
    r"([a-z_][A-Za-z0-9_]*)\s*[=;]"
)
KT_LOCAL_ASSIGN_RE = re.compile(
    r"\b(?:val|var)\s+([a-z_][A-Za-z0-9_]*)\s*"
    r"(?::\s*[A-Z][A-Za-z0-9_]*)?\s*=\s*(?:new\s+)?([A-Z][A-Za-z0-9_]*)\s*\("
)
JAVA_LOCAL_ASSIGN_RE = re.compile(
    r"\b([A-Z][A-Za-z0-9_]*)\s+([a-z_][A-Za-z0-9_]*)\s*=\s*new\s+[A-Z]"
)

GD_FILE_CTOR_RE = re.compile(
    r"com\.good\.gd\.file\.File\s*\(|"
    r"\bGDFile\s*\(|"
    r"GDFileSystem\s*\.\s*\w+\s*\(|"
    r"GDFileHelper\s*\.\s*\w+\s*\("
)
# Simple names after `import com.good.gd.file.File` (not the GDFile alias the
# older fixtures use). Constructing these before onAuthorized() throws.
GD_SIMPLE_FILE_TYPES = frozenset({
    "File", "FileInputStream", "FileOutputStream", "RandomAccessFile",
})
KT_EXT_FUN_RE = re.compile(
    r"(?mx)"
    r"(?:^|\n)\s*"
    r"(?:(?:public|protected|private|internal|open|final|override|abstract|"
    r"suspend|inline|operator|tailrec)\s+)*"
    r"fun\s+[A-Za-z_][A-Za-z0-9_.<>]*\."
    r"([A-Za-z_][A-Za-z0-9_]*)\s*"
    r"\([^;\n{}]*\)\s*"
    r"(?::\s*[^=\n{]+)?\{"
)
KT_EXT_EXPR_FUN_RE = re.compile(
    r"(?mx)"
    r"(?:^|\n)\s*"
    r"(?:(?:public|protected|private|internal|open|final|override|abstract|"
    r"suspend|inline)\s+)*"
    r"fun\s+[A-Za-z_][A-Za-z0-9_.<>]*\."
    r"([A-Za-z_][A-Za-z0-9_]*)\s*\([^)\n]*\)\s*"
    r"(?::\s*[^=\n{]+)?=\s*([^\n]+)"
)
FRAGMENT_LIFECYCLE_METHODS = (
    "onViewCreated", "onCreateView", "onResume",
    "setupAdapter", "initAdapter",
)
KT_COMPUTED_PROP_RE = re.compile(
    r"\b(?:val|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^\n={]+)?\s*"
    r"get\s*\(\s*\)\s*=\s*([^\n]+)"
)
KT_BRACED_GETTER_RE = re.compile(
    r"(?ms)(?:^|\n)\s*(?:val|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*"
    r"(?::[^\n={]+)?\s*get\s*\(\s*\)\s*\{"
)
INSTANCE_PROP_RE = re.compile(
    r"\b([a-z_][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\b"
)
DEFERRED_BLOCK_RE = re.compile(
    r"runOnAuthorized|getAuthorized\s*\(\)\s*\.observe|authorized\s*\.observe|"
    r"databaseReady\s*\.observe|observeForever|"
    r"if\s*\([^)\n]*(?:isContainerAuthorized|databaseReady)[^)\n]*\)"
)
# AUTH-UI-004 — deferred Activity UI fields used from lifecycle methods.
DEFERRED_UI_SIGNAL_RE = re.compile(
    r"\brunOnAuthorized\b|\binitializeAuthorizedUi\b|\binitAuthorizedUi\b|"
    r"\bsetupAuthorizedUi\b|\bauthorizedUiInitialized\b|\bauthorizedUiReady\b|"
    r"\bonDynamicsAuthorized\b|\bsetupNavigation\b|\bsetupNavController\b"
)
DEFERRED_UI_ASSIGN_METHODS = {
    "initializeAuthorizedUi",
    "initAuthorizedUi",
    "setupAuthorizedUi",
    "loadAppData",
    "initAuthorizedDependencies",
    "setupNavigation",
    "setupNavController",
    "onDynamicsAuthorized",
}
LIFECYCLE_UI004_METHODS = (
    "onResume",
    "onPause",
    "onStop",
    "onDestroy",
    "onCreateOptionsMenu",
    "onPrepareOptionsMenu",
)
PHASE2_INIT_METHODS = (
    "initializeAuthorizedUi",
    "initAuthorizedUi",
    "setupAuthorizedUi",
    "onDynamicsAuthorized",
)
OBSERVE_RE = re.compile(r"\.observe(?:Forever)?\s*\(")
FIELD_WRITE_RE = re.compile(r"(?:this\.)?([a-z_][A-Za-z0-9_]*)\s*=(?!=)")
FIELD_USE_UNSAFE_RE = re.compile(r"\b([a-z_][A-Za-z0-9_]*)\s*(?:!!\s*)?\.")
READY_FLAG_NAMES = (
    "authorizedUiInitialized",
    "authorizedUiReady",
    "isAuthorized",
    "dependenciesInitialized",
)
STARTUP_METHODS_BY_KIND = {
    "activity": ("onCreate",),
    "application": ("onCreate",),
    "provider": ("onCreate",),
    "initializer": ("create",),
    "work_manager_provider": ("getWorkManagerConfiguration",),
    "worker_factory": ("createWorker",),
    "fragment": (
        "onViewCreated", "onCreateView", "onResume",
        "setupAdapter", "initAdapter", "createAdapter",
    ),
    "service": ("onCreate", "onStartCommand", "onHandleIntent", "onHandleWork", "onStartJob"),
    "receiver": ("onReceive",),
    "worker": ("doWork", "onStartJob"),
}
BRACED_METHOD_RE = re.compile(
    r"(?mx)"
    r"(?:^|\n)\s*"
    r"(?:(?:public|protected|private|internal|open|final|override|abstract|"
    r"suspend|inline|operator|tailrec|static|synchronized)\s+)*"
    r"(?:(?:fun|[A-Za-z_][A-Za-z0-9_<>\[\],?. ]+)\s+)"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*"
    r"\([^;\n{}]*\)\s*"
    r"(?:throws\s+[A-Za-z0-9_., ?]+\s*)?"
    r"(?::\s*[^=\n{]+)?\{"
)
EXPR_METHOD_RE = re.compile(
    r"(?mx)"
    r"(?:^|\n)\s*"
    r"(?:(?:public|protected|private|internal|open|final|override|abstract|"
    r"suspend|inline|operator|tailrec)\s+)*"
    r"fun\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^)\n]*\)\s*"
    r"(?::\s*[^=\n{]+)?=\s*([^\n]+)"
)
NEW_CLASS_RE = re.compile(r"\bnew\s+([A-Z][A-Za-z0-9_]*)\s*\(")
BARE_CLASS_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\s*\(")
QUALIFIED_CALL_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(")
LOCAL_CALL_RE = re.compile(r"\b([a-z_][A-Za-z0-9_]*)\s*\(")
JAVA_CTOR_FMT = r"(?mx)(?:^|\n)\s*(?:(?:public|protected|private)\s+)*%s\s*\([^;\n{}]*\)\s*\{"
KT_SECONDARY_CTOR_RE = re.compile(r"(?mx)(?:^|\n)\s*constructor\s*\([^)\n]*\)\s*\{")
INIT_CAPTURE_RE = re.compile(r"\binit\s*\{")
CONTROL_WORDS = {
    "if", "for", "while", "when", "catch", "switch", "return", "throw",
    "super", "this", "class", "fun", "new", "try", "else", "do",
}
TOP_LEVEL_INIT_SKIP_RE = re.compile(
    r"^(?:class\b|fun\b|override\s+fun\b|public\s+fun\b|private\s+fun\b|"
    r"protected\s+fun\b|internal\s+fun\b|@|import\b)"
)

class_to_file = {}
parent_of = {}
has_activity_init = {}
is_activity = set()
room_vm_findings = []
room_vm_scanned = 0
deferred_files = 0
auth_ui_001_hits = []
auth_ui_002_hits = []
auth_file_001_hits = []
auth_pref_001_hits = []
auth_ui_004_hits = []
auth_ui_004_scanned = 0
bang_field_refs = set()
viewmodel_files = []

class_texts = {}
raw_class_texts = {}
class_methods = {}
class_init_blocks = {}
class_field_types = {}
class_gd_imports = {}
startup_class_kinds = {}
gd_file_functions = {}
gd_file_fn_names = set()
gd_file_colocated_fns = set()
computed_props = {}
live_wrapper_classes = set()
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"
TOOLS_NS = "{http://schemas.android.com/tools}"
manifest_provider_classes = set()
app_startup_initializer_classes = set()
workmanager_default_initializer_enabled = False
workmanager_default_initializer_disabled = False
auth_ui_003_hits = []
auth_ui_003_scanned = 0


def local_tag(tag):
    return tag.split("}", 1)[-1] if "}" in tag else tag


def resolve_manifest_name(raw_name, pkg):
    if not raw_name:
        return ""
    if raw_name.startswith("."):
        return f"{pkg}{raw_name}" if pkg else raw_name.lstrip(".")
    if "." in raw_name:
        return raw_name
    return f"{pkg}.{raw_name}" if pkg else raw_name


for manifest_path in manifest_paths:
    try:
        root = ET.parse(manifest_path).getroot()
    except Exception:
        continue
    package_name = root.get("package") or root.get(f"{ANDROID_NS}package") or ""
    for elem in root.iter():
        if local_tag(elem.tag) != "provider":
            continue
        provider_name = resolve_manifest_name(
            elem.get(f"{ANDROID_NS}name") or "",
            package_name,
        )
        if not provider_name:
            continue
        manifest_provider_classes.add(provider_name)
        provider_tools_node = (elem.get(f"{TOOLS_NS}node") or "").lower()
        provider_removed = "remove" in provider_tools_node
        if provider_name == "androidx.work.impl.WorkManagerInitializer":
            if provider_removed:
                workmanager_default_initializer_disabled = True
            else:
                workmanager_default_initializer_enabled = True
        if provider_name != "androidx.startup.InitializationProvider":
            continue
        for child in list(elem):
            if local_tag(child.tag) != "meta-data":
                continue
            md_name = resolve_manifest_name(
                child.get(f"{ANDROID_NS}name") or "",
                package_name,
            )
            md_value = (child.get(f"{ANDROID_NS}value") or "").strip()
            md_tools_node = (child.get(f"{TOOLS_NS}node") or "").lower()
            md_removed = provider_removed or ("remove" in md_tools_node)
            if md_name == "androidx.work.WorkManagerInitializer":
                if md_removed:
                    workmanager_default_initializer_disabled = True
                else:
                    workmanager_default_initializer_enabled = True
                continue
            if md_value == "androidx.startup" and md_name and not md_removed:
                app_startup_initializer_classes.add(md_name)


def strip_comments_and_strings(text):
    out = []
    i = 0
    n = len(text)
    state = "code"
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if ch == "/" and nxt == "/":
                state = "line_comment"
                i += 2
                continue
            if ch == "/" and nxt == "*":
                state = "block_comment"
                i += 2
                continue
            if ch == '"' and text[i:i + 3] == '"""':
                state = "triple_double"
                out.append("   ")
                i += 3
                continue
            if ch == "'":
                state = "single_quote"
                out.append(" ")
                i += 1
                continue
            if ch == '"':
                state = "double_quote"
                out.append(" ")
                i += 1
                continue
            out.append(ch)
            i += 1
            continue
        if state == "line_comment":
            if ch == "\n":
                out.append("\n")
                state = "code"
            i += 1
            continue
        if state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 2
            else:
                i += 1
            continue
        if state == "single_quote":
            if ch == "\\":
                i += 2
                continue
            if ch == "'":
                state = "code"
            i += 1
            continue
        if state == "double_quote":
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                state = "code"
            i += 1
            continue
        if state == "triple_double":
            if text[i:i + 3] == '"""':
                state = "code"
                i += 3
            else:
                i += 1
            continue
    return "".join(out)


def find_matching_brace(text, brace_open):
    depth = 1
    i = brace_open + 1
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def extract_braced_blocks(text, regex):
    blocks = []
    for m in regex.finditer(text):
        brace_open = text.find("{", m.end() - 1)
        if brace_open == -1:
            continue
        brace_close = find_matching_brace(text, brace_open)
        if brace_close == -1:
            continue
        blocks.append((m, text[brace_open + 1: brace_close]))
    return blocks


def extract_methods(text):
    methods = {}
    for m, body in extract_braced_blocks(text, BRACED_METHOD_RE):
        methods.setdefault(m.group(1), []).append(body)
    for m, body in extract_braced_blocks(text, KT_BRACED_GETTER_RE):
        methods.setdefault(m.group(1), []).append(body)
    for m, body in extract_braced_blocks(text, KT_EXT_FUN_RE):
        methods.setdefault(m.group(1), []).append(body)
    for m in EXPR_METHOD_RE.finditer(text):
        methods.setdefault(m.group(1), []).append(m.group(2))
    for m in KT_COMPUTED_PROP_RE.finditer(text):
        methods.setdefault(m.group(1), []).append(m.group(2))
    for m in KT_EXT_EXPR_FUN_RE.finditer(text):
        methods.setdefault(m.group(1), []).append(m.group(2))
    return methods


def extract_top_level_initializers(text):
    snippets = []
    class_seen = False
    class_depth = 0
    for line in text.splitlines():
        stripped = line.strip()
        opens = line.count("{")
        closes = line.count("}")
        if not class_seen:
            if "class " in stripped and "{" in stripped:
                class_seen = True
                class_depth = max(1, opens - closes)
            continue
        if class_depth == 1:
            if ("=" in stripped or "by lazy" in stripped or "lazy {" in stripped) \
                    and not TOP_LEVEL_INIT_SKIP_RE.search(stripped):
                snippets.append(stripped)
        class_depth += opens - closes
        if class_depth <= 0:
            class_seen = False
            class_depth = 0
    return snippets


def extract_init_blocks(text, cls_name):
    blocks = []
    ctor_re = re.compile(JAVA_CTOR_FMT % re.escape(cls_name))
    for idx, (_, body) in enumerate(extract_braced_blocks(text, ctor_re), start=1):
        blocks.append((f"<init#{idx}>", body))
    for idx, (_, body) in enumerate(extract_braced_blocks(text, KT_SECONDARY_CTOR_RE), start=1):
        blocks.append((f"<kctor#{idx}>", body))
    for idx, (_, body) in enumerate(extract_braced_blocks(text, INIT_CAPTURE_RE), start=1):
        blocks.append((f"<init-block#{idx}>", body))
    for idx, snippet in enumerate(extract_top_level_initializers(text), start=1):
        blocks.append((f"<field-init#{idx}>", snippet))
    return blocks


def direct_secure_categories(text, cls_name=None):
    cats = [name for name, rx in SECURE_TOKEN_PATTERNS.items() if rx.search(text)]
    if PREFS_HELPER_IO_CALL_RE.search(text) and "prefs" not in cats:
        cats.append("prefs")
    if text_has_prefs_property_chain(text) and "prefs" not in cats:
        cats.append("prefs")
    if cls_name:
        for simple in class_gd_imports.get(cls_name, ()):
            if re.search(rf"\b{re.escape(simple)}\s*[\.(]", text):
                if "file" not in cats:
                    cats.append("file")
                break
    return cats


def extract_field_types(text):
    fields = {}
    for m in KT_TYPED_FIELD_RE.finditer(text):
        fields[m.group(1)] = m.group(2)
    for m in KT_ASSIGN_FIELD_RE.finditer(text):
        fields.setdefault(m.group(1), m.group(2))
    for m in KT_LAZY_FIELD_RE.finditer(text):
        fields.setdefault(m.group(1), m.group(2))
    for m in JAVA_FIELD_RE.finditer(text):
        fields.setdefault(m.group(2), m.group(1))
    return fields


def extract_gd_import_names(text):
    names = set()
    for m in GD_FILE_IMPORT_RE.finditer(text):
        names.add(m.group(2) or m.group(1))
    return names


def imported_gd_simple_ctor_re(raw_text):
    names = extract_gd_import_names(raw_text) & GD_SIMPLE_FILE_TYPES
    if not names:
        return None
    return re.compile(
        r"\b(?:" + "|".join(re.escape(n) for n in sorted(names)) + r")\s*\("
    )


def text_has_gd_file_ctor(stripped_text, imported_ctor_rx):
    if GD_FILE_CTOR_RE.search(stripped_text):
        return True
    return bool(imported_ctor_rx and imported_ctor_rx.search(stripped_text))


def class_has_secure_prefs_backend(cls_name):
    blob = class_texts.get(cls_name, "")
    raw = raw_class_texts.get(cls_name, "")
    if not blob:
        return False
    if PREFS_HELPER_IO_CALL_RE.search(blob):
        return True
    return text_has_gd_file_ctor(blob, imported_gd_simple_ctor_re(raw))


def text_has_prefs_property_chain(text):
    if PREFS_FIELD_CHAIN_RE.search(text):
        return True
    for match in PREFS_NAMED_PREFERENCES_CHAIN_RE.finditer(text):
        if class_has_secure_prefs_backend(match.group(1)):
            return True
    return False


def resolve_field_type(cls_name, field_name):
    seen = set()
    cur = cls_name
    while cur and cur not in seen:
        seen.add(cur)
        mapped = class_field_types.get(cur, {}).get(field_name)
        if mapped:
            return mapped
        cur = parent_of.get(cur)
    return None


def local_types_in(body):
    types = {}
    for m in KT_LOCAL_ASSIGN_RE.finditer(body):
        types[m.group(1)] = m.group(2)
    for m in JAVA_LOCAL_ASSIGN_RE.finditer(body):
        types[m.group(2)] = m.group(1)
    return types


def instance_calls_in(body, cls_name):
    results = set()
    local_types = local_types_in(body)
    for m in INSTANCE_CALL_RE.finditer(body):
        recv, method = m.group(1), m.group(2)
        target = local_types.get(recv) or resolve_field_type(cls_name, recv)
        if target and target in class_texts:
            results.add((target, method))
    for m in CHAINED_CTOR_CALL_RE.finditer(body):
        target, method = m.group(1), m.group(2)
        if target in class_texts:
            results.add((target, method))
    for m in INSTANCE_PROP_RE.finditer(body):
        recv, prop = m.group(1), m.group(2)
        target = local_types.get(recv) or resolve_field_type(cls_name, recv)
        if not target or target not in class_texts:
            continue
        if prop in class_methods.get(target, {}):
            results.add((target, prop))
    return results


def _early_return_guard_end(text):
    """End index of a not-authorized / not-ready early-return guard, or None.

    Matches single-line `if (!isContainerAuthorized) return` and the common
    multi-line form:

        if (!isContainerAuthorized) {
            Log.d(TAG, "not authorized")
            return
        }

    Brace bodies use find_matching_brace so nested blocks and newlines are
    included. A braced `if` that does not `return` is not an early-return
    (the remainder of the method may still run unauthorized).
    """
    match = AUTH_EARLY_RETURN_HEAD_RE.search(text)
    if not match:
        return None
    i = match.end()
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    if i < len(text) and text[i] == "{":
        close = find_matching_brace(text, i)
        if close == -1:
            return None
        if not re.search(r"\breturn\b", text[i + 1:close]):
            return None
        return close + 1
    if text.startswith("return", i):
        j = i
        while j < len(text) and text[j] not in ";\n":
            j += 1
        if j < len(text):
            j += 1
        return j
    return None


def mask_deferred_regions(text):
    chars = list(text)
    # Early-return first. DEFERRED_BLOCK_RE would otherwise blank a braced
    # `if (!isContainerAuthorized) { ... return }` and leave the post-guard
    # body unmasked (false-positive AUTH-PREF / AUTH-CTOR hits).
    early_end = _early_return_guard_end(text)
    if early_end is not None:
        for i in range(early_end, len(chars)):
            if chars[i] != "\n":
                chars[i] = " "
        text = "".join(chars)
        chars = list(text)
    pos = 0
    while True:
        match = DEFERRED_BLOCK_RE.search(text, pos)
        if not match:
            break
        brace_open = text.find("{", match.end())
        if brace_open == -1:
            pos = match.end()
            continue
        brace_close = find_matching_brace(text, brace_open)
        if brace_close == -1:
            break
        for i in range(match.start(), brace_close + 1):
            chars[i] = " "
        pos = brace_close + 1
    return "".join(chars)


def instantiations_in(body):
    results = set()
    for m in NEW_CLASS_RE.finditer(body):
        results.add(m.group(1))
    for m in BARE_CLASS_RE.finditer(body):
        name = m.group(1)
        if name in class_texts:
            results.add(name)
    return results


def qualified_calls_in(body):
    return {
        (m.group(1), m.group(2))
        for m in QUALIFIED_CALL_RE.finditer(body)
        if m.group(1) in class_texts
    }


def local_calls_in(body):
    calls = set()
    for m in LOCAL_CALL_RE.finditer(body):
        name = m.group(1)
        if name not in CONTROL_WORDS:
            calls.add(name)
    return calls


def render_member(cls_name, member_name):
    base = os.path.basename(class_to_file.get(cls_name, cls_name))
    return f"{base}.{member_name}"


def render_categories(cats):
    return ",".join(cats)


class_init_cache = {}
method_cache = {}


def explore_body(cls_name, member_name, body, allow_direct, seen, depth):
    if depth > 8:
        return None
    masked = mask_deferred_regions(body)
    if allow_direct:
        cats = direct_secure_categories(masked, cls_name)
        if cats:
            return f"{render_member(cls_name, member_name)} [{render_categories(cats)}]"

    for target_cls in sorted(instantiations_in(masked)):
        if target_cls == cls_name and not allow_direct:
            continue
        key = ("class", target_cls)
        if key in seen:
            continue
        nested = class_init_path(target_cls, seen | {key}, depth + 1)
        if nested:
            return f"{render_member(cls_name, member_name)} -> {nested}"

    for target_cls, target_method in sorted(qualified_calls_in(masked)):
        key = ("method", target_cls, target_method)
        if key in seen:
            continue
        nested = method_path(target_cls, target_method, seen, depth + 1)
        if nested:
            return f"{render_member(cls_name, member_name)} -> {nested}"

    for target_cls, target_method in sorted(instance_calls_in(masked, cls_name)):
        key = ("method", target_cls, target_method)
        if key in seen:
            continue
        nested = method_path(target_cls, target_method, seen, depth + 1)
        if nested:
            return f"{render_member(cls_name, member_name)} -> {nested}"

    for local_method in sorted(local_calls_in(masked)):
        if local_method not in class_methods.get(cls_name, {}):
            continue
        key = ("method", cls_name, local_method)
        if key in seen:
            continue
        nested = method_path(cls_name, local_method, seen, depth + 1)
        if nested:
            return f"{render_member(cls_name, member_name)} -> {nested}"
    return None


def class_init_path(cls_name, seen=None, depth=0):
    if cls_name not in class_init_blocks:
        return None
    if seen is None:
        seen = set()
    if cls_name in class_init_cache:
        return class_init_cache[cls_name]
    for member_name, body in class_init_blocks.get(cls_name, []):
        key = ("init", cls_name, member_name)
        if key in seen:
            continue
        hit = explore_body(cls_name, member_name, body, True, seen | {key}, depth + 1)
        if hit:
            class_init_cache[cls_name] = hit
            return hit
    class_init_cache[cls_name] = None
    return None


def method_path(cls_name, method_name, seen=None, depth=0):
    if seen is None:
        seen = set()
    cache_key = (cls_name, method_name)
    if cache_key in method_cache:
        return method_cache[cache_key]
    for idx, body in enumerate(class_methods.get(cls_name, {}).get(method_name, []), start=1):
        member_name = f"{method_name}#{idx}" if len(class_methods.get(cls_name, {}).get(method_name, [])) > 1 else method_name
        key = ("method", cls_name, member_name)
        if key in seen:
            continue
        hit = explore_body(cls_name, member_name, body, True, seen | {key}, depth + 1)
        if hit:
            method_cache[cache_key] = hit
            return hit
    method_cache[cache_key] = None
    return None


def class_name_from_file(text):
    match = CLASS_RE.search(text) or OBJECT_RE.search(text)
    return match.group(1) if match else None


for root in walk_roots:
    if not os.path.isdir(root):
        continue
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in files:
            if not fn.endswith((".java", ".kt")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                raw_text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue

            stripped_text = strip_comments_and_strings(raw_text)

            match = CLASS_RE.search(raw_text) or OBJECT_RE.search(raw_text)
            if match:
                cls = match.group(1)
                class_to_file.setdefault(cls, path)
                class_texts.setdefault(cls, stripped_text)
                raw_class_texts.setdefault(cls, raw_text)
                class_methods.setdefault(cls, extract_methods(stripped_text))
                class_init_blocks.setdefault(cls, extract_init_blocks(stripped_text, cls))
                class_field_types.setdefault(cls, extract_field_types(stripped_text))
                class_gd_imports.setdefault(cls, extract_gd_import_names(raw_text))
                has_activity_init[cls] = bool(ACTIVITY_INIT_RE.search(stripped_text))
                if re.search(r":\s*(?:[A-Za-z0-9_.]+\.)?LiveData(?:<|\s)", raw_text) and "observeForever" in raw_text:
                    live_wrapper_classes.add(cls)
                if ACTIVITY_MARKER_RE.search(raw_text):
                    is_activity.add(cls)
                    startup_class_kinds.setdefault(cls, set()).add("activity")
                if APPLICATION_MARKER_RE.search(raw_text):
                    startup_class_kinds.setdefault(cls, set()).add("application")
                if SERVICE_MARKER_RE.search(raw_text):
                    startup_class_kinds.setdefault(cls, set()).add("service")
                if RECEIVER_MARKER_RE.search(raw_text):
                    startup_class_kinds.setdefault(cls, set()).add("receiver")
                if FRAGMENT_MARKER_RE.search(raw_text):
                    startup_class_kinds.setdefault(cls, set()).add("fragment")
                if WORKER_MARKER_RE.search(raw_text):
                    startup_class_kinds.setdefault(cls, set()).add("worker")
                if PROVIDER_MARKER_RE.search(raw_text):
                    startup_class_kinds.setdefault(cls, set()).add("provider")
                if APP_STARTUP_INITIALIZER_RE.search(raw_text):
                    startup_class_kinds.setdefault(cls, set()).add("initializer")
                if WORK_MANAGER_CONFIG_PROVIDER_RE.search(raw_text):
                    startup_class_kinds.setdefault(cls, set()).add("work_manager_provider")
                if WORKER_FACTORY_MARKER_RE.search(raw_text):
                    startup_class_kinds.setdefault(cls, set()).add("worker_factory")
                parent_match = JAVA_PARENT_RE.search(raw_text) or KT_PARENT_RE.search(raw_text)
                if parent_match:
                    parent_of[cls] = parent_match.group(1)

            for obj_m in TOPLEVEL_OBJECT_RE.finditer(raw_text):
                obj_name = obj_m.group(1)
                if obj_name in class_texts:
                    continue
                brace_open = raw_text.find("{", obj_m.end())
                if brace_open == -1:
                    continue
                brace_close = find_matching_brace(raw_text, brace_open)
                if brace_close == -1:
                    continue
                obj_raw = raw_text[obj_m.start():brace_close + 1]
                obj_stripped = strip_comments_and_strings(obj_raw)
                class_to_file.setdefault(obj_name, path)
                class_texts.setdefault(obj_name, obj_stripped)
                raw_class_texts.setdefault(obj_name, obj_raw)
                class_methods.setdefault(obj_name, extract_methods(obj_stripped))
                class_init_blocks.setdefault(
                    obj_name, extract_init_blocks(obj_stripped, obj_name)
                )
                class_field_types.setdefault(obj_name, extract_field_types(obj_stripped))
                class_gd_imports.setdefault(obj_name, extract_gd_import_names(raw_text))

            if VIEWMODEL_RE.search(raw_text) and ROOM_RE.search(raw_text):
                room_vm_scanned += 1
                for im in INIT_BLOCK_RE.finditer(raw_text):
                    window = raw_text[im.start(): im.start() + 1800]
                    if DB_DANGER_RE.search(window) and not AUTH_GUARD_RE.search(window):
                        room_vm_findings.append(fn)
                        break

            if DEFERRED_MARKER_RE.search(raw_text):
                deferred_files += 1

            if STARTUP_SCOPE_RE.search(raw_text):
                lines = raw_text.splitlines()
                in_scope = False
                scope_braces = 0
                for ln, line in enumerate(lines, start=1):
                    stripped = line.strip()
                    if STARTUP_EXPR_OVERRIDE_RE.search(stripped) or STARTUP_HEADER_BANG_RE.search(stripped):
                        auth_ui_001_hits.append(f"{fn}:{ln}")
                        continue
                    if STARTUP_SCOPE_RE.search(stripped) and "{" in stripped:
                        in_scope = True
                        scope_braces = stripped.count("{") - stripped.count("}")
                        continue
                    if in_scope:
                        scope_braces += line.count("{") - line.count("}")
                        if scope_braces <= 0:
                            in_scope = False
                        if RISKY_BANG_RE.search(line):
                            auth_ui_001_hits.append(f"{fn}:{ln}")

            if (VIEWMODEL_RE.search(raw_text)
                    and ROOM_RE.search(raw_text)
                    and NULLABLE_LD_RE.search(raw_text)
                    and not PLACEHOLDER_RE.search(raw_text)):
                auth_ui_002_hits.append(fn)

            for sm in re.finditer(
                r"override\s+fun\s+(?:" + "|".join(STARTUP_METHOD_NAMES)
                + r")\b[^=\n]*=\s*(?:model|viewModel|baseModel)"
                r"\.([A-Za-z_][A-Za-z0-9_]*)\s*!!",
                raw_text,
            ):
                bang_field_refs.add(sm.group(1))

            if VIEWMODEL_RE.search(raw_text):
                viewmodel_files.append((cls if match else fn, fn, raw_text))

            imported_ctor_rx = imported_gd_simple_ctor_re(raw_text)
            if text_has_gd_file_ctor(stripped_text, imported_ctor_rx):
                all_fns_in_file = extract_methods(stripped_text)
                for mname in all_fns_in_file:
                    gd_file_colocated_fns.add(mname)
                for mname, bodies in all_fns_in_file.items():
                    for body in bodies:
                        if text_has_gd_file_ctor(body, imported_ctor_rx) and not AUTH_GUARD_RE.search(body):
                            gd_file_fn_names.add(mname)
                            if match:
                                cls = match.group(1)
                                gd_file_functions.setdefault(cls, set()).add(mname)

            if match:
                cls = match.group(1)
                for prop_m in KT_COMPUTED_PROP_RE.finditer(stripped_text):
                    computed_props.setdefault(cls, {})[prop_m.group(1)] = prop_m.group(2).strip()

for provider_name in sorted(manifest_provider_classes):
    simple = provider_name.rsplit(".", 1)[-1]
    if simple in class_to_file:
        startup_class_kinds.setdefault(simple, set()).add("provider")
for initializer_name in sorted(app_startup_initializer_classes):
    simple = initializer_name.rsplit(".", 1)[-1]
    if simple in class_to_file:
        startup_class_kinds.setdefault(simple, set()).add("initializer")
if workmanager_default_initializer_enabled and not workmanager_default_initializer_disabled:
    for cls_name, text in class_texts.items():
        if WORK_MANAGER_CONFIG_PROVIDER_RE.search(text):
            startup_class_kinds.setdefault(cls_name, set()).add("work_manager_provider")
        if WORKER_FACTORY_MARKER_RE.search(text):
            startup_class_kinds.setdefault(cls_name, set()).add("worker_factory")

if bang_field_refs and viewmodel_files:
    for field_name in bang_field_refs:
        decl_re = re.compile(
            r"\bvar\s+" + re.escape(field_name)
            + r"\s*:\s*[A-Za-z_][A-Za-z0-9_<>?,\s]*\?\s*=\s*null\b"
        )
        for _, vm_fn, vm_text in viewmodel_files:
            if decl_re.search(vm_text):
                auth_ui_002_hits.append(f"{vm_fn}:{field_name}")
                break

for vm_cls, vm_fn, vm_text in viewmodel_files:
    if not ROOM_RE.search(vm_text):
        continue
    vm_methods = class_methods.get(vm_cls, {})
    has_database_ready = bool(DATABASE_READY_RE.search(vm_text))
    wrapper_placeholder = False
    if live_wrapper_classes:
        for wrapper_cls in sorted(live_wrapper_classes):
            if re.search(
                rf"\b(?:var|val)\s+\w+\s*:\s*{re.escape(wrapper_cls)}\b[^\n=]*=\s*[A-Za-z_][A-Za-z0-9_]*\s*\(",
                vm_text,
            ) or re.search(
                rf"\breturn\s+{re.escape(wrapper_cls)}\s*\(",
                vm_text,
            ):
                wrapper_placeholder = True
                break

    manual_bootstrap_hits = []
    for method_name, bodies in vm_methods.items():
        if not MANUAL_BOOTSTRAP_METHOD_RE.search(method_name):
            continue
        for body in bodies:
            if (ROOM_RE.search(body) or DB_DANGER_RE.search(body)) and not AUTH_GUARD_RE.search(body):
                manual_bootstrap_hits.append(method_name)
                break

    if manual_bootstrap_hits or wrapper_placeholder:
        auth_ui_003_scanned += 1
        reasons = []
        if manual_bootstrap_hits and not has_database_ready:
            reasons.append(
                f"{vm_fn}:{','.join(sorted(set(manual_bootstrap_hits)))} "
                f"[manual deferred Room bootstrap without databaseReady]"
            )
        if wrapper_placeholder and not has_database_ready and (manual_bootstrap_hits or AUTH_GUARD_RE.search(vm_text)):
            reasons.append(f"{vm_fn} [custom LiveData wrapper placeholder without databaseReady]")
        auth_ui_003_hits.extend(reasons)

dupes = []
for cls in sorted(is_activity):
    if not has_activity_init.get(cls, False):
        continue
    seen = set()
    parent = parent_of.get(cls)
    depth = 0
    while parent and parent not in seen and depth < 8:
        seen.add(parent)
        if has_activity_init.get(parent, False):
            child_file = os.path.basename(class_to_file.get(cls, cls))
            parent_file = os.path.basename(class_to_file.get(parent, parent))
            dupes.append(f"{child_file}<-{parent_file}")
            break
        parent = parent_of.get(parent)
        depth += 1

auth_ctor_hits = []
startup_scanned = 0
startup_model_scanned = 0
startup_model_hits = []
startup_model_kinds = {"provider", "initializer", "work_manager_provider", "worker_factory"}
for cls_name, kinds in sorted(startup_class_kinds.items()):
    startup_scanned += 1
    if startup_model_kinds.intersection(kinds):
        startup_model_scanned += 1
    for member_name, body in class_init_blocks.get(cls_name, []):
        hit = explore_body(
            cls_name,
            member_name,
            body,
            bool(startup_model_kinds.intersection(kinds)),
            {("seed", cls_name, member_name)},
            0,
        )
        if hit:
            auth_ctor_hits.append(hit)
            if startup_model_kinds.intersection(kinds):
                startup_model_hits.append(f"{cls_name}:ctor -> {hit}")
            break
    for kind in sorted(kinds):
        for method_name in STARTUP_METHODS_BY_KIND.get(kind, ()):
            for idx, body in enumerate(class_methods.get(cls_name, {}).get(method_name, []), start=1):
                member_name = f"{method_name}#{idx}" if len(class_methods.get(cls_name, {}).get(method_name, [])) > 1 else method_name
                hit = explore_body(
                    cls_name,
                    member_name,
                    body,
                    kind in startup_model_kinds,
                    {("seed", cls_name, member_name)},
                    0,
                )
                if hit:
                    auth_ctor_hits.append(hit)
                    if kind in startup_model_kinds:
                        startup_model_hits.append(f"{kind}:{hit}")
                    break
            if auth_ctor_hits and auth_ctor_hits[-1].startswith(os.path.basename(class_to_file.get(cls_name, cls_name))):
                break


fragment_classes = {
    cls for cls, kinds in startup_class_kinds.items() if "fragment" in kinds
}
for frag_cls in sorted(fragment_classes):
    frag_methods = class_methods.get(frag_cls, {})
    for lifecycle_method in FRAGMENT_LIFECYCLE_METHODS:
        for body in frag_methods.get(lifecycle_method, []):
            masked = mask_deferred_regions(body)
            frag_imported_ctor = imported_gd_simple_ctor_re(
                raw_class_texts.get(frag_cls, "")
            )
            if text_has_gd_file_ctor(masked, frag_imported_ctor):
                frag_file = os.path.basename(class_to_file.get(frag_cls, frag_cls))
                auth_file_001_hits.append(
                    f"{frag_file}.{lifecycle_method} [direct GD file ctor]"
                )
                continue
            for local_fn in sorted(local_calls_in(masked)):
                if local_fn in gd_file_functions.get(frag_cls, set()):
                    frag_file = os.path.basename(class_to_file.get(frag_cls, frag_cls))
                    auth_file_001_hits.append(
                        f"{frag_file}.{lifecycle_method} -> {local_fn} [file]"
                    )
                elif local_fn in gd_file_fn_names:
                    frag_file = os.path.basename(class_to_file.get(frag_cls, frag_cls))
                    auth_file_001_hits.append(
                        f"{frag_file}.{lifecycle_method} -> {local_fn} [file]"
                    )
            for prop_cls, props in computed_props.items():
                for prop_name, prop_body in props.items():
                    prop_access_re = re.compile(
                        r"\b(?:model|viewModel|baseModel)\." + re.escape(prop_name) + r"\b"
                    )
                    if prop_access_re.search(masked):
                        called_fn = prop_body.split("(")[0].split(".")[-1].strip()
                        if called_fn in gd_file_fn_names or called_fn in gd_file_colocated_fns:
                            frag_file = os.path.basename(
                                class_to_file.get(frag_cls, frag_cls)
                            )
                            auth_file_001_hits.append(
                                f"{frag_file}.{lifecycle_method} -> "
                                f"model.{prop_name} -> {called_fn} [file]"
                            )
                        elif text_has_gd_file_ctor(
                            prop_body,
                            imported_gd_simple_ctor_re(raw_class_texts.get(prop_cls, "")),
                        ):
                            frag_file = os.path.basename(
                                class_to_file.get(frag_cls, frag_cls)
                            )
                            auth_file_001_hits.append(
                                f"{frag_file}.{lifecycle_method} -> "
                                f"model.{prop_name} [computed prop -> GD file ctor]"
                            )

for cls_name, kinds in sorted(startup_class_kinds.items()):
    if "activity" not in kinds:
        continue
    methods = class_methods.get(cls_name, {})
    ready_helpers = {
        method_name
        for method_name, bodies in methods.items()
        if any(MODEL_READY_CALL_RE.search(body) for body in bodies)
    }
    if not ready_helpers:
        continue
    auth_ui_003_scanned += 1
    activity_file = os.path.basename(class_to_file.get(cls_name, cls_name))
    for body in methods.get("onCreate", []):
        ordered_calls = []
        for match in LOCAL_CALL_RE.finditer(mask_deferred_regions(body)):
            method_name = match.group(1)
            if method_name in CONTROL_WORDS or method_name not in methods:
                continue
            ordered_calls.append((match.start(), method_name))
        ready_pos = None
        ready_method = None
        for pos, method_name in ordered_calls:
            if method_name in ready_helpers:
                ready_pos = pos
                ready_method = method_name
                break
        if ready_pos is None:
            continue
        for pos, method_name in ordered_calls:
            if pos >= ready_pos:
                break
            helper_bodies = methods.get(method_name, [])
            if not any(MODEL_FIELD_ACCESS_RE.search(helper_body) for helper_body in helper_bodies):
                continue
            if any(DATABASE_READY_RE.search(helper_body) or AUTH_GUARD_RE.search(helper_body) for helper_body in helper_bodies):
                continue
            auth_ui_003_hits.append(
                f"{activity_file}.onCreate -> {method_name} "
                f"[uses baseModel before {ready_method}]"
            )
            break


def _has_lifecycle_ui_guard(body, deferred_fields):
    ready_alt = "|".join(READY_FLAG_NAMES)
    for match in re.finditer(r"if\s*\(([^)]*)\)\s*(?:return\b|\{)", body):
        cond = match.group(1)
        if re.search(rf"\b(?:{ready_alt})\b", cond):
            return True
        for field in deferred_fields:
            if re.search(rf"::{re.escape(field)}\.isInitialized", cond):
                return True
            if re.search(rf"\b{re.escape(field)}\s*==\s*null", cond):
                return True
            if re.search(rf"\b{re.escape(field)}\s*!=\s*null", cond):
                return True
    if re.search(rf"if\s*\(\s*(?:{ready_alt})\s*\)\s*\{{", body):
        return True
    if re.search(
        rf"if\s*\(\s*!\s*(?:{ready_alt})\s*\)\s*(?:return\b|\{{[^}}]*return)",
        body,
    ):
        return True
    for field in deferred_fields:
        if re.search(rf"if\s*\(\s*{re.escape(field)}\s*==\s*null\s*\)", body):
            return True
        if re.search(rf"if\s*\(\s*{re.escape(field)}\s*!=\s*null\s*\)\s*\{{", body):
            return True
        if re.search(
            rf"if\s*\(\s*!\s*::{re.escape(field)}\.isInitialized\s*\)",
            body,
        ):
            return True
        if re.search(rf"if\s*\(\s*::{re.escape(field)}\.isInitialized\s*\)", body):
            return True
    return False


def _deferred_fields_from_assign_methods(cls_name, methods):
    declared = set(class_field_types.get(cls_name, {}))
    deferred = set()
    for method_name in DEFERRED_UI_ASSIGN_METHODS:
        for body in methods.get(method_name, []):
            for match in FIELD_WRITE_RE.finditer(body):
                name = match.group(1)
                if name in declared:
                    deferred.add(name)
    return deferred


def _unsafe_deferred_field_uses(body, deferred_fields):
    used = set()
    if not deferred_fields:
        return used
    for match in FIELD_USE_UNSAFE_RE.finditer(body):
        name = match.group(1)
        if name in deferred_fields:
            used.add(name)
    # Bare identifier uses (e.g. setupActionBarWithNavController(navController)).
    for match in re.finditer(r"\b([a-z_][A-Za-z0-9_]*)\b", body):
        name = match.group(1)
        if name not in deferred_fields:
            continue
        start = match.start()
        if start >= 2 and body[start - 2:start] == "::":
            continue
        after = body[match.end():]
        if re.match(r"\s*=(?!=)", after):
            continue
        if re.match(r"\s*(?:==|!=)", after):
            continue
        if re.match(r"\s*\?", after):
            continue
        used.add(name)
    return used


def _find_matching_paren(text, paren_open):
    depth = 1
    i = paren_open + 1
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _observe_callback_snippets(body):
    """Return (observe_start, callback_text) for each LiveData/prefs observe."""
    snippets = []
    for match in OBSERVE_RE.finditer(body):
        paren_open = body.find("(", match.start())
        if paren_open == -1:
            continue
        paren_close = _find_matching_paren(body, paren_open)
        if paren_close == -1:
            continue
        callback = body[paren_open + 1:paren_close]
        k = paren_close + 1
        while k < len(body) and body[k] in " \t\n":
            k += 1
        if k < len(body) and body[k] == "{":
            brace_close = find_matching_brace(body, k)
            if brace_close != -1:
                callback = body[k + 1:brace_close]
        snippets.append((match.start(), callback))
    return snippets


def _fields_assigned_in_body(body, deferred_fields):
    assigned = set()
    for match in FIELD_WRITE_RE.finditer(body):
        name = match.group(1)
        if name in deferred_fields:
            assigned.add(name)
    return assigned


def _observe_snippets_reach_deferred(snippets, methods, deferred_fields):
    reached = set()
    for _, snippet in snippets:
        reached |= _unsafe_deferred_field_uses(snippet, deferred_fields)
        for match in LOCAL_CALL_RE.finditer(snippet):
            name = match.group(1)
            if name in CONTROL_WORDS or name not in methods:
                continue
            for callee_body in methods.get(name, []):
                if _has_lifecycle_ui_guard(callee_body, deferred_fields):
                    continue
                reached |= _unsafe_deferred_field_uses(callee_body, deferred_fields)
    return reached


def _phase2_observe_before_assign_hits(activity_file, init_name, body, methods, deferred_fields):
    """Fail when LiveData.observe uses deferred fields before they are assigned.

    After activation, initializeAuthorizedUi often runs from onPostResume, so
    observe() dispatches immediately on an already-resumed Activity.
    """
    hits = []
    assigned = set()
    events = []
    for match in FIELD_WRITE_RE.finditer(body):
        name = match.group(1)
        if name in deferred_fields:
            events.append((match.start(), "assign", name))
    for match in LOCAL_CALL_RE.finditer(body):
        name = match.group(1)
        if name in CONTROL_WORDS:
            continue
        events.append((match.start(), "call", name))
    for match in OBSERVE_RE.finditer(body):
        events.append((match.start(), "observe", None))
    kind_order = {"assign": 0, "call": 1, "observe": 2}
    events.sort(key=lambda item: (item[0], kind_order.get(item[1], 3)))

    callback_by_pos = {
        pos: snippet for pos, snippet in _observe_callback_snippets(body)
    }

    for pos, kind, name in events:
        if kind == "assign":
            assigned.add(name)
            continue
        if kind == "observe":
            snippet = callback_by_pos.get(pos)
            if snippet is None:
                continue
            reached = _observe_snippets_reach_deferred(
                [(pos, snippet)], methods, deferred_fields
            )
            early = sorted(reached - assigned)
            if early:
                hits.append(
                    f"{activity_file}.{init_name} observes before assigning "
                    f"{','.join(early)}"
                )
            continue
        if name not in methods:
            continue
        callee_bodies = methods.get(name, [])
        snippets = []
        for callee_body in callee_bodies:
            snippets.extend(_observe_callback_snippets(callee_body))
        reached = _observe_snippets_reach_deferred(
            snippets, methods, deferred_fields
        )
        early = sorted(reached - assigned)
        if early:
            hits.append(
                f"{activity_file}.{init_name} -> {name}() observes before "
                f"assigning {','.join(early)}"
            )
        for callee_body in callee_bodies:
            assigned |= _fields_assigned_in_body(callee_body, deferred_fields)
    return hits


# AUTH-UI-004 — Activity deferred UI fields used in lifecycle without guard,
# plus Phase-2 observe-before-navigation order.
for cls_name, kinds in sorted(startup_class_kinds.items()):
    if "activity" not in kinds:
        continue
    methods = class_methods.get(cls_name, {})
    class_text = class_texts.get(cls_name, "")
    has_deferred_signal = bool(DEFERRED_UI_SIGNAL_RE.search(class_text))
    has_assign_method = bool(DEFERRED_UI_ASSIGN_METHODS & set(methods.keys()))
    if not has_deferred_signal and not has_assign_method:
        continue
    deferred_fields = _deferred_fields_from_assign_methods(cls_name, methods)
    if not deferred_fields:
        continue
    auth_ui_004_scanned += 1
    activity_file = os.path.basename(class_to_file.get(cls_name, cls_name))
    for lifecycle in LIFECYCLE_UI004_METHODS:
        for body in methods.get(lifecycle, []):
            if _has_lifecycle_ui_guard(body, deferred_fields):
                continue
            used = _unsafe_deferred_field_uses(body, deferred_fields)
            if not used:
                continue
            auth_ui_004_hits.append(
                f"{activity_file}.{lifecycle} uses deferred field(s) "
                f"{','.join(sorted(used))} without ready/null guard"
            )
    for init_name in PHASE2_INIT_METHODS:
        for body in methods.get(init_name, []):
            auth_ui_004_hits.extend(
                _phase2_observe_before_assign_hits(
                    activity_file, init_name, body, methods, deferred_fields
                )
            )


def emit(key, status, payload=""):
    if payload:
        print(f"{key}={status}|{payload}")
    else:
        print(f"{key}={status}")


if dupes:
    emit("AUTH_INIT_001", "FAIL", " ".join(sorted(set(dupes))))
elif is_activity:
    emit("AUTH_INIT_001", "PASS", str(len(is_activity)))
else:
    emit("AUTH_INIT_001", "NA")

if room_vm_findings:
    emit("AUTH_DB_001", "FAIL", " ".join(sorted(set(room_vm_findings))))
elif room_vm_scanned > 0:
    emit("AUTH_DB_001", "PASS", str(room_vm_scanned))
else:
    emit("AUTH_DB_001", "NA")

if deferred_files == 0:
    emit("AUTH_UI_001", "NA")
    emit("AUTH_UI_002", "NA")
else:
    if auth_ui_001_hits:
        emit("AUTH_UI_001", "FAIL", " ".join(sorted(set(auth_ui_001_hits))[:12]))
    else:
        emit("AUTH_UI_001", "PASS")
    if auth_ui_002_hits:
        emit("AUTH_UI_002", "WARN", " ".join(sorted(set(auth_ui_002_hits))[:12]))
    else:
        emit("AUTH_UI_002", "PASS")

if auth_ui_003_hits:
    emit("AUTH_UI_003", "FAIL", " | ".join(sorted(set(auth_ui_003_hits))[:12]))
elif auth_ui_003_scanned > 0:
    emit("AUTH_UI_003", "PASS")
else:
    emit("AUTH_UI_003", "NA")

if auth_ui_004_hits:
    emit("AUTH_UI_004", "FAIL", " | ".join(sorted(set(auth_ui_004_hits))[:12]))
elif auth_ui_004_scanned > 0:
    emit("AUTH_UI_004", "PASS")
else:
    emit("AUTH_UI_004", "NA")

if auth_ctor_hits:
    emit("AUTH_CTOR_001", "FAIL", " | ".join(sorted(set(auth_ctor_hits))[:8]))
elif startup_scanned > 0:
    emit("AUTH_CTOR_001", "PASS", str(startup_scanned))
else:
    emit("AUTH_CTOR_001", "NA")

if startup_model_hits:
    emit("AUTH_STARTUP_001", "FAIL", " | ".join(sorted(set(startup_model_hits))[:8]))
elif startup_model_scanned > 0:
    emit("AUTH_STARTUP_001", "PASS", str(startup_model_scanned))
else:
    emit("AUTH_STARTUP_001", "NA")

if auth_file_001_hits:
    emit("AUTH_FILE_001", "FAIL", " | ".join(sorted(set(auth_file_001_hits))[:8]))
elif fragment_classes:
    emit("AUTH_FILE_001", "PASS", str(len(fragment_classes)))
else:
    emit("AUTH_FILE_001", "NA")

# AUTH-PREF-001 — Activity/Application lifecycle reaches GD file or secure
# prefs I/O before authorization (method-body sinks, not only constructors).
# Includes Kotlin object-style helpers and preference property getters
# (`preferences.theme.value`) in addition to `helper().getXxx(` calls.
auth_pref_scanned = 0
for cls_name, kinds in sorted(startup_class_kinds.items()):
    if not ({"activity", "application"} & set(kinds)):
        continue
    auth_pref_scanned += 1
    for method_name in PREF_LIFECYCLE_METHODS:
        bodies = class_methods.get(cls_name, {}).get(method_name, [])
        for idx, body in enumerate(bodies, start=1):
            member_name = (
                f"{method_name}#{idx}" if len(bodies) > 1 else method_name
            )
            hit = explore_body(
                cls_name,
                member_name,
                body,
                True,
                {("seed-pref", cls_name, member_name)},
                0,
            )
            if not hit:
                continue
            # Report file/prefs crashes; other secure categories remain
            # covered by AUTH-CTOR / AUTH-DB / AUTH-STARTUP.
            if re.search(r"\[(?:[^\]]*?\b(?:file|prefs)\b)", hit):
                auth_pref_001_hits.append(hit)

if auth_pref_001_hits:
    emit("AUTH_PREF_001", "FAIL", " | ".join(sorted(set(auth_pref_001_hits))[:8]))
elif auth_pref_scanned > 0:
    emit("AUTH_PREF_001", "PASS", str(auth_pref_scanned))
else:
    emit("AUTH_PREF_001", "NA")

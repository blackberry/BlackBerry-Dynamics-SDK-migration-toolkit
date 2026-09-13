# BlackBerry Dynamics Migration — validator phase 11
#
# Sourced by tooling/validate.sh once should_run_phase "11" passes.
# Inherits PASS/FAIL/WARN counters, helpers (check_pass/check_fail/
# check_warn, fail_or_defer, strip_audit_noise, NATIVE_SCAN_PY, …)
# and the module-map scope vars from the parent shell.
#
# Do not edit the inner body without preserving validation semantics
# (see docs/android-dynamics-migration-tool-production-readiness-review.md
# and the per-domain steering files for what each check enforces).
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2086,SC2046,SC2016

    # ========================================
    # Phase 11: Authorization Guard
    # ========================================
    echo "Phase 11: Authorization Guard"
    echo "-----------------------------------------"

# Check that Activities do not access secure APIs in onCreate() before authorization.
# This catches the #1 runtime crash: GDNotAuthorizedError from calling secure APIs
# before onAuthorized() fires.
if [ -n "$ALL_ACTIVITIES" ]; then
    AUTH_ISSUE=0

    for ACTIVITY_FILE in $ALL_ACTIVITIES; do
        BASENAME=$(basename "$ACTIVITY_FILE")
        ONCREATE_SCAN="$(python3 - "$ACTIVITY_FILE" <<'PY' 2>/dev/null || echo "DB=0 FILE=0 NET=0"
import re
import sys

path = sys.argv[1]
try:
    raw = open(path, "r", encoding="utf-8", errors="ignore").read()
except Exception:
    print("DB=0 FILE=0 NET=0")
    sys.exit(0)

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
            if ch == '"' and text[i:i+3] == '"""':
                state = "triple_double"
                i += 3
                out.append("   ")
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
            if text[i:i+3] == '"""':
                state = "code"
                i += 3
            else:
                i += 1
            continue
    return "".join(out)

text = strip_comments_and_strings(raw)

sig_re = re.compile(
    r"\\b(?:public|protected|private|internal|final|open|suspend|static\\s+)*"
    r"(?:void\\s+)?onCreate\\s*\\([^)]*\\)"
)
db_re = re.compile(r"getReadableDatabase|getWritableDatabase|openOrCreateDatabase|SQLiteDatabase\\.open")
file_re = re.compile(r"GDFileSystem|com\\.good\\.gd\\.file\\.")
net_re = re.compile(r"GDHttpClient|GDSocket")

flags = {"DB": 0, "FILE": 0, "NET": 0}
pos = 0
while True:
    m = sig_re.search(text, pos)
    if not m:
        break
    brace_open = text.find("{", m.end())
    if brace_open == -1:
        pos = m.end()
        continue
    depth = 1
    i = brace_open + 1
    while i < len(text) and depth > 0:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    body = text[brace_open + 1 : i - 1] if i <= len(text) else text[brace_open + 1 :]
    if db_re.search(body):
        flags["DB"] = 1
    if file_re.search(body):
        flags["FILE"] = 1
    if net_re.search(body):
        flags["NET"] = 1
    pos = i

print(f"DB={flags['DB']} FILE={flags['FILE']} NET={flags['NET']}")
PY
)"
        ONCREATE_DB=$(printf '%s' "$ONCREATE_SCAN" | sed -n 's/.*DB=\([01]\).*/\1/p')
        ONCREATE_FILE=$(printf '%s' "$ONCREATE_SCAN" | sed -n 's/.*FILE=\([01]\).*/\1/p')
        ONCREATE_NET=$(printf '%s' "$ONCREATE_SCAN" | sed -n 's/.*NET=\([01]\).*/\1/p')

        [ -z "$ONCREATE_DB" ] && ONCREATE_DB=0
        [ -z "$ONCREATE_FILE" ] && ONCREATE_FILE=0
        [ -z "$ONCREATE_NET" ] && ONCREATE_NET=0

        if [ "$ONCREATE_DB" -eq 1 ]; then
            check_fail "Secure SQLite accessed in onCreate() before onAuthorized() ($BASENAME) — re-run prompt 03b (authorization deferral audit)"
            AUTH_ISSUE=1
        fi

        if [ "$ONCREATE_FILE" -eq 1 ]; then
            check_fail "Secure file I/O accessed in onCreate() before onAuthorized() ($BASENAME) — re-run prompt 03b (authorization deferral audit)"
            AUTH_ISSUE=1
        fi

        if [ "$ONCREATE_NET" -eq 1 ]; then
            check_fail "Secure networking accessed in onCreate() before onAuthorized() ($BASENAME) — re-run prompt 03b (authorization deferral audit)"
            AUTH_ISSUE=1
        fi
    done

    # Combined startup-hardening scan: one Python pass across every
    # in-scope source root (primary + library modules). Emits a stable
    # KEY=value report consumed by the shell case statements below.
    #
    #   AUTH-INIT-001  Duplicate activityInit() in inheritance chains
    #                  (base+subclass double-call; triggers "GD Monitor
    #                  Fragment already inserted").
    #   AUTH-DB-001    Pre-auth Room/DAO observer wiring in ViewModel
    #                  init{} (RoomTrackingLiveData on arch_disk_io).
    #   AUTH-UI-001    Startup hard-dereference (!!) of delayed
    #                  ViewModel/binding fields when auth deferral is
    #                  in play (NPE in onViewCreated/setupObserver).
    #   AUTH-UI-002    Delayed DB init publishes nullable UI observables
    #                  without a clear non-null placeholder.
    #   AUTH-UI-003    Deferred-init startup state machine is incomplete:
    #                  manual ViewModel bootstrap with no databaseReady,
    #                  custom placeholder wrapper constructed pre-auth, or
    #                  Activity startup helper touches model before ready.
    #   AUTH-UI-004    Deferred Activity UI fields (assigned in
    #                  initializeAuthorizedUi / setupNavigation /
    #                  onDynamicsAuthorized) used from onResume/onPause/
    #                  onStop/onDestroy/onCreateOptionsMenu/
    #                  onPrepareOptionsMenu without ready/null/
    #                  isInitialized guard (cold-start NPE / lateinit);
    #                  also Phase-2 LiveData/prefs observe before
    #                  setupNavigation assigns those fields.
    #   AUTH-CTOR-001  Startup object graph reaches secure APIs through
    #                  constructors, field initializers, or helper/factory
    #                  methods before authorization.
    #   AUTH-STARTUP-001 Provider/App Startup/WorkManager startup paths
    #                  (ContentProvider, androidx.startup Initializer,
    #                  WorkManager default initializer + worker factory /
    #                  Configuration.Provider) reach secure APIs before auth.
    #   AUTH-FILE-001  GD file constructor reachable from Fragment
    #                  lifecycle / adapter setup before authorization.
    #   AUTH-PREF-001  Activity/Application onCreate/onStart/onResume
    #                  reaches GD file or secure-preferences I/O (including
    #                  helper get/put methods) before authorization.
    export MM_IN_SCOPE_SOURCE_ROOTS_P11="$MM_IN_SCOPE_SOURCE_ROOTS"
    export SRC_DIR_P11="$SRC_DIR_MM"
    export MM_IN_SCOPE_MANIFESTS_P11="$MM_IN_SCOPE_MANIFESTS"
    AUTH_STARTUP_SCAN="$SCRIPT_DIR/lib/auth-startup-scan.py"
    STARTUP_HARDENING_RESULT=$(python3 "$AUTH_STARTUP_SCAN" 2>/dev/null) || STARTUP_HARDENING_RESULT="AUTH_INIT_001=ERROR
AUTH_DB_001=ERROR
AUTH_UI_001=ERROR
AUTH_UI_002=ERROR
AUTH_UI_003=ERROR
AUTH_UI_004=ERROR
AUTH_CTOR_001=ERROR
AUTH_STARTUP_001=ERROR
AUTH_FILE_001=ERROR
AUTH_PREF_001=ERROR"

    # Helper: pull "STATUS|payload" (or just "STATUS") for a given key.
    _ph11_get() {
        printf "%s\n" "$STARTUP_HARDENING_RESULT" | awk -F= -v k="$1" '$1==k{print substr($0,length(k)+2);exit}'
    }

    # AUTH-INIT-001 — duplicate activityInit() in inheritance chains
    _r="$(_ph11_get AUTH_INIT_001)"
    case "${_r%%|*}" in
        FAIL)
            check_fail "[AUTH-INIT-001] Duplicate activityInit() in inheritance chain(s): ${_r#FAIL|} — enforce exactly-once call per launch path (base OR subclass, not both)"
            AUTH_ISSUE=1
            ;;
        PASS)
            check_pass "[AUTH-INIT-001] activityInit() inheritance scan clean (${_r#PASS|} Activity class(es) audited)"
            ;;
        NA)
            check_warn "[AUTH-INIT-001] No Activity classes found for duplicate activityInit() scan"
            ;;
        *)
            check_warn "[AUTH-INIT-001] Duplicate activityInit() scan could not run cleanly — manually verify exactly-once rule"
            ;;
    esac

    # AUTH-DB-001 — pre-auth Room observer wiring in ViewModel init{}
    _r="$(_ph11_get AUTH_DB_001)"
    case "${_r%%|*}" in
        FAIL)
            check_fail "[AUTH-DB-001] Potential pre-auth Room observer wiring in ViewModel init{}: ${_r#FAIL|} — defer Room/DAO observer setup until authorized LiveData emits true (see prompt 03b + steering/21-authorization-deferral-patterns.md)"
            AUTH_ISSUE=1
            ;;
        PASS)
            check_pass "[AUTH-DB-001] ViewModel/Room pre-auth guard scan clean (${_r#PASS|} Room-aware ViewModel file(s) audited)"
            ;;
        NA)
            check_pass "[AUTH-DB-001] No Room-aware ViewModel patterns detected for pre-auth scan"
            ;;
        *)
            check_warn "[AUTH-DB-001] ViewModel/Room pre-auth guard scan could not run cleanly — manually verify prompt 03b Step 5 runtime smoke"
            ;;
    esac

    # AUTH-UI-001 — startup '!!' hard-dereference of delayed model fields
    _r="$(_ph11_get AUTH_UI_001)"
    case "${_r%%|*}" in
        FAIL)
            check_fail "[AUTH-UI-001] Deferred-init nullability risk: startup path hard-dereferences delayed model fields with '!!' (${_r#FAIL|}) — publish non-null placeholder observable and remove startup '!!' dereferences (see steering/21-authorization-deferral-patterns.md Pattern 12)"
            AUTH_ISSUE=1
            ;;
        PASS)
            check_pass "[AUTH-UI-001] Deferred-init nullability scan clean"
            ;;
        NA)
            check_pass "[AUTH-UI-001] No auth-deferred startup markers detected for nullability scan"
            ;;
        *)
            check_warn "[AUTH-UI-001] Deferred-init nullability scan could not run cleanly — run prompt 03b startup NPE smoke"
            ;;
    esac

    # AUTH-UI-002 — placeholder-observable heuristic (warn-only)
    _r="$(_ph11_get AUTH_UI_002)"
    case "${_r%%|*}" in
        WARN)
            check_warn "[AUTH-UI-002] Delayed DB init appears to rely on nullable observable fields without clear placeholder publication (${_r#WARN|}) — add explicit placeholder/loading observable before attaching DAO stream (see steering/21-authorization-deferral-patterns.md Pattern 12)"
            ;;
        PASS)
            check_pass "[AUTH-UI-002] Placeholder-observable heuristic clean"
            ;;
        NA)
            check_pass "[AUTH-UI-002] Placeholder-observable heuristic not applicable"
            ;;
        *)
            check_warn "[AUTH-UI-002] Placeholder-observable heuristic could not run cleanly"
            ;;
    esac

    # AUTH-UI-003 — incomplete deferred-init startup state machine
    _r="$(_ph11_get AUTH_UI_003)"
    case "${_r%%|*}" in
        FAIL)
            check_fail "[AUTH-UI-003] Deferred-init startup state machine is incomplete (${_r#FAIL|}) — Room-aware ViewModels that bootstrap after authorization must publish databaseReady, custom placeholder wrappers must stay side-effect free until post-auth wiring, and Activity startup helpers must not touch baseModel/viewModel before the model-ready gate (see prompt 03b + steering/21-authorization-deferral-patterns.md Patterns 2, 9, and 12)"
            AUTH_ISSUE=1
            ;;
        PASS)
            check_pass "[AUTH-UI-003] Deferred-init startup state-machine scan clean"
            ;;
        NA)
            check_pass "[AUTH-UI-003] Deferred-init startup state-machine scan not applicable"
            ;;
        *)
            check_warn "[AUTH-UI-003] Deferred-init startup state-machine scan could not run cleanly — manually audit manual startObserving()/databaseReady gating and custom placeholder wrappers"
            ;;
    esac

    # AUTH-UI-004 — deferred Activity UI fields used in lifecycle without
    # guard, or Phase-2 observe-before-navigation order
    _r="$(_ph11_get AUTH_UI_004)"
    case "${_r%%|*}" in
        FAIL)
            check_fail "[AUTH-UI-004] Deferred Activity UI lifecycle hole (${_r#FAIL|}) — fields assigned in initializeAuthorizedUi/setupNavigation/onDynamicsAuthorized/runOnAuthorized must not be used from onResume/onPause/onStop/onDestroy/onCreateOptionsMenu/onPrepareOptionsMenu without a ready/null/isInitialized guard; establish navigation/controllers before LiveData/prefs observes that use those fields (observe() dispatches immediately when Phase-2 runs from onPostResume), and invalidateOptionsMenu() after Phase-2 (see prompt 03/03b + steering/21-authorization-deferral-patterns.md Pattern 14)"
            AUTH_ISSUE=1
            ;;
        PASS)
            check_pass "[AUTH-UI-004] Deferred Activity UI lifecycle guard scan clean"
            ;;
        NA)
            check_pass "[AUTH-UI-004] Deferred Activity UI lifecycle guard scan not applicable"
            ;;
        *)
            check_warn "[AUTH-UI-004] Deferred Activity UI lifecycle guard scan could not run cleanly — manually audit onResume/onCreateOptionsMenu for fields created only post-auth"
            ;;
    esac

    # AUTH-CTOR-001 — constructor/initializer/factory reachability from startup
    _r="$(_ph11_get AUTH_CTOR_001)"
    case "${_r%%|*}" in
        FAIL)
            check_fail "[AUTH-CTOR-001] Startup path reaches secure APIs through constructors, field initializers, or helper/factory methods before authorization (${_r#FAIL|}) — move the allocation behind runOnAuthorized()/authorized observers or make the object graph side-effect free until post-auth work begins (see prompt 03 + steering/20-auth-initialization.md)"
            AUTH_ISSUE=1
            ;;
        PASS)
            check_pass "[AUTH-CTOR-001] Constructor/initializer startup reachability scan clean (${_r#PASS|} startup class(es) audited)"
            ;;
        NA)
            check_pass "[AUTH-CTOR-001] No startup classes found for constructor reachability scan"
            ;;
        *)
            check_warn "[AUTH-CTOR-001] Constructor reachability scan could not run cleanly — manually audit startup object graphs"
            ;;
    esac

    # AUTH-FILE-001 — GD file constructor reachable from Fragment lifecycle
    _r="$(_ph11_get AUTH_STARTUP_001)"
    case "${_r%%|*}" in
        FAIL)
            check_fail "[AUTH-STARTUP-001] Startup provider/initializer path reaches secure APIs before authorization (${_r#FAIL|}) — defer provider/initializer/work-manager startup work behind runOnAuthorized()/authorized observers and keep startup constructors side-effect free (see steering/20-auth-initialization.md and steering/22-multi-process-app-handling.md)"
            AUTH_ISSUE=1
            ;;
        PASS)
            check_pass "[AUTH-STARTUP-001] Provider/App Startup/WorkManager startup-path scan clean (${_r#PASS|} startup class(es) audited)"
            ;;
        NA)
            check_pass "[AUTH-STARTUP-001] No provider/app-startup/work-manager startup classes detected"
            ;;
        *)
            check_warn "[AUTH-STARTUP-001] Provider/App Startup/WorkManager startup-path scan could not run cleanly — manually verify no pre-auth secure API in providers/initializers/worker factories"
            ;;
    esac

    # AUTH-FILE-001 — GD file constructor reachable from Fragment lifecycle
    _r="$(_ph11_get AUTH_FILE_001)"
    case "${_r%%|*}" in
        FAIL)
            check_fail "[AUTH-FILE-001] GD file constructor (com.good.gd.file.File, including import-then-File( and Kotlin extensions) reachable from Fragment lifecycle method before authorization (${_r#FAIL|}) — defer adapter setup or guard utility function with isContainerAuthorized (see steering/21-authorization-deferral-patterns.md Pattern 7 — Common Consumers)"
            AUTH_ISSUE=1
            ;;
        PASS)
            check_pass "[AUTH-FILE-001] Fragment lifecycle GD file reachability scan clean (${_r#PASS|} Fragment class(es) audited)"
            ;;
        NA)
            check_pass "[AUTH-FILE-001] No Fragment classes found for GD file lifecycle reachability scan"
            ;;
        *)
            check_warn "[AUTH-FILE-001] Fragment GD file reachability scan could not run cleanly — manually verify no GD file access in onViewCreated/setupAdapter"
            ;;
    esac

    # AUTH-PREF-001 — Activity/Application lifecycle reaches GD file or
    # secure-prefs I/O (including helper get/put methods) before authorization.
    _r="$(_ph11_get AUTH_PREF_001)"
    case "${_r%%|*}" in
        FAIL)
            check_fail "[AUTH-PREF-001] Activity/Application lifecycle reaches Dynamics secure file or secure-preferences I/O before authorization (${_r#FAIL|}) — defer theme/settings/PIN/prefs, Kotlin preference property getters (`.value` / `isLockEnabled`), object-style SecurePreferencesHelper.get/put, and any com.good.gd.file.* reads/writes until runOnAuthorized()/authorized observers (see prompt 03 + 05c and steering/21-authorization-deferral-patterns.md Pattern 13)"
            AUTH_ISSUE=1
            ;;
        PASS)
            check_pass "[AUTH-PREF-001] Activity/Application secure prefs/file lifecycle scan clean (${_r#PASS|} startup class(es) audited)"
            ;;
        NA)
            check_pass "[AUTH-PREF-001] No Activity/Application classes found for secure prefs/file lifecycle scan"
            ;;
        *)
            check_warn "[AUTH-PREF-001] Secure prefs/file lifecycle scan could not run cleanly — manually verify no SecurePreferencesHelper/com.good.gd.file.* I/O from onCreate/onStart/onResume before auth"
            ;;
    esac

    unset MM_IN_SCOPE_SOURCE_ROOTS_P11 SRC_DIR_P11 MM_IN_SCOPE_MANIFESTS_P11

    # AUTH-LISTENER-001 — belt-and-suspenders cross-check for
    # setGDStateListener() registration. Phase 3 is the primary gate;
    # this re-check catches the invariant violation even when phase 3 is
    # skipped or the phase-3 result is stale from a prior run.
    GLOBAL_LISTENER_P11=$(grep -rl "setGDStateListener" "$SRC_DIR_MM/" 2>/dev/null | head -1)
    if [ -z "$GLOBAL_LISTENER_P11" ]; then
        AUTH_LISTENER_P11=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os, re, sys

src_root = sys.argv[1]
ACTIVITY_INIT_RE = re.compile(r"\bactivityInit\s*\(")
GD_LISTENER_RE = re.compile(
    r"implements\s+.*\bGDStateListener\b|[,:]\s*GDStateListener\b"
)
ACTIVITY_CLASS_RE = re.compile(
    r"extends\s+.*\b(?:Activity|AppCompatActivity|FragmentActivity|ComponentActivity)\b"
    r"|:\s*(?:Activity|AppCompatActivity|FragmentActivity|ComponentActivity)\s*\("
)
SKIP = frozenset({"Activity", "AppCompatActivity", "FragmentActivity", "ComponentActivity"})

def read_file(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""

def parent_class(text):
    m = re.search(r"class\s+\w+\s*:\s*([A-Za-z_]\w*)", text)
    if m: return m.group(1)
    m = re.search(r"class\s+\w+\s+extends\s+([A-Za-z_]\w*)", text)
    return m.group(1) if m else None

def find_cls(name):
    pat = re.compile(rf"\bclass\s+{re.escape(name)}\b")
    for dp, _, fs in os.walk(src_root):
        for fn in fs:
            if fn.endswith((".java", ".kt")):
                p = os.path.join(dp, fn)
                if pat.search(read_file(p)[:8192]):
                    return p
    return None

def chain_check(path, pred):
    cur, seen = path, set()
    for _ in range(8):
        if not cur or cur in seen: break
        seen.add(cur)
        if pred(cur): return True
        pc = parent_class(read_file(cur))
        if not pc or pc in SKIP: break
        cur = find_cls(pc)
        if not cur: break
    return False

def code_lines(text):
    for l in text.splitlines():
        s = l.lstrip()
        if not s or s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        yield l

unprotected = []
for dp, _, fs in os.walk(src_root):
    for fn in fs:
        if not fn.endswith((".java", ".kt")): continue
        p = os.path.join(dp, fn)
        t = read_file(p)[:4096]
        if not ACTIVITY_CLASS_RE.search(t): continue
        if not chain_check(p, lambda x: any(ACTIVITY_INIT_RE.search(s) for s in code_lines(read_file(x)))): continue
        if chain_check(p, lambda x: bool(GD_LISTENER_RE.search(read_file(x)))): continue
        unprotected.append(fn)
if unprotected:
    print("FAIL|" + " ".join(sorted(set(unprotected))))
else:
    print("OK")
PY
) || AUTH_LISTENER_P11="ERROR"
        case "${AUTH_LISTENER_P11%%|*}" in
            FAIL)
                _set_violation_context "authorization" "11" \
                    "Add GDAndroid.getInstance().setGDStateListener(this) to Application.onCreate()" \
                    "${AUTH_LISTENER_P11#FAIL|}"
                check_fail "[AUTH-LISTENER-001] RUNTIME CRASH: activityInit() in ${AUTH_LISTENER_P11#FAIL|} but no GDStateListener registered (neither global setGDStateListener() nor per-Activity). SDK will throw GDInitializationError. Fix: add setGDStateListener(this) to Application.onCreate(). See steering/20-auth-initialization.md"
                AUTH_ISSUE=1
                ;;
            OK)
                check_pass "[AUTH-LISTENER-001] GDStateListener registration covers all activityInit() call sites"
                ;;
            *)
                check_warn "[AUTH-LISTENER-001] GDStateListener cross-check could not run — manually verify listener registration"
                ;;
        esac
    else
        check_pass "[AUTH-LISTENER-001] Global setGDStateListener() present ($(basename "$GLOBAL_LISTENER_P11"))"
    fi

    # Guard against a common post-activation crash pattern:
    #   IllegalStateException: Can not perform this action after onSaveInstanceState
    # caused when runOnAuthorized(...) directly performs fragment commit() while
    # the Activity state is already saved (e.g. app backgrounded during activation).
    # Heuristic: Activity contains runOnAuthorized + fragment commit(), but lacks any
    # lifecycle/state-saved guard markers.
    FRAGMENT_COMMIT_STATE_GUARD_ISSUE=0
    for ACTIVITY_FILE in $ALL_ACTIVITIES; do
        [ -z "$ACTIVITY_FILE" ] && continue
        BASENAME=$(basename "$ACTIVITY_FILE")
        if grep -q "runOnAuthorized" "$ACTIVITY_FILE" 2>/dev/null && grep -q "\.commit(" "$ACTIVITY_FILE" 2>/dev/null; then
            if ! grep -q "isStateSaved\|pendingAuthorizedUiInit\|onPostResume\|Lifecycle\.State\.RESUMED\|Lifecycle\.State\.STARTED\|launchWhenResumed\|repeatOnLifecycle" "$ACTIVITY_FILE" 2>/dev/null; then
                check_fail "Activity performs fragment commit from runOnAuthorized() without lifecycle/state-saved guard ($BASENAME) — risk of IllegalStateException after activation. Add isStateSaved/onPostResume deferral gate (see prompt 03 + steering 20)."
                AUTH_ISSUE=1
                FRAGMENT_COMMIT_STATE_GUARD_ISSUE=1
            fi
        fi
    done
    [ "$FRAGMENT_COMMIT_STATE_GUARD_ISSUE" -eq 0 ] && check_pass "No unsafe fragment commit detected in runOnAuthorized() callbacks"

    # Check that onAuthorized() has meaningful content (not just a log/no-op).
    # Heuristic intent: warn ONLY when the body is provably empty or
    # logging-only. A body that flushes a deferral queue, posts to LiveData,
    # toggles a flag, or invokes any non-Log method should pass.
    #
    # Match both Java (public void onAuthorized) and Kotlin (override fun onAuthorized).
    # The previous version used `grep -v "onAuthorized\|Log\.\|..."` which
    # over-stripped lines whose substrings happened to contain the method
    # name (e.g. `pendingOnAuthorizedCallbacks.flush()`) or any reference to
    # `Log.` (e.g. `_authLog.update(true)`), producing false-empty warnings.
    if [ -n "$GD_LISTENER_FILE" ]; then
        AUTHORIZED_BODY=$(awk '
            function count_chars(s, ch,    n, ignore) {
                n = split(s, ignore, ch)
                return n - 1
            }
            BEGIN { in_body = 0; brace_depth = 0; meaningful = 0 }
            /public[[:space:]]+void[[:space:]]+onAuthorized[[:space:]]*\(|override[[:space:]]+fun[[:space:]]+onAuthorized[[:space:]]*\(/ {
                in_body = 1
                brace_depth += count_chars($0, "{") - count_chars($0, "}")
                next
            }
            in_body == 1 {
                # Track brace depth to detect end-of-method reliably,
                # independent of indentation (tabs vs spaces) or nested blocks.
                brace_depth += count_chars($0, "{") - count_chars($0, "}")

                trimmed = $0
                sub(/^[[:space:]]+/, "", trimmed)
                sub(/[[:space:]]+$/, "", trimmed)

                # Skip blanks, comment-only lines, and pure brace lines.
                if (trimmed == "" || trimmed ~ /^\/\// || trimmed ~ /^\/\*/ || trimmed ~ /^\*/ || trimmed ~ /^[{}]+$/) {
                    if (brace_depth <= 0) { in_body = 0 }
                    next
                }

                # Skip Log.x(...) call statements anchored at start of trimmed line.
                # Anchored match avoids false-stripping `myAuthLog.update(...)`.
                if (trimmed ~ /^(android\.util\.)?Log\.(v|d|i|w|e|wtf)[[:space:]]*\(/) {
                    if (brace_depth <= 0) { in_body = 0 }
                    next
                }

                # Anything else (assignments, postValue, queue flushes, method
                # calls, returns with values, etc.) counts as meaningful.
                meaningful++

                if (brace_depth <= 0) { in_body = 0 }
            }
            END { print meaningful }
        ' "$GD_LISTENER_FILE" 2>/dev/null)
        AUTHORIZED_BODY=${AUTHORIZED_BODY:-0}

        if [ "$AUTHORIZED_BODY" -gt 0 ]; then
            check_pass "onAuthorized() contains initialization logic"
        else
            check_warn "onAuthorized() appears empty or logging-only — secure API init may be missing"
        fi
    fi

    [ "$AUTH_ISSUE" -eq 0 ] && check_pass "No secure API access in onCreate() before authorization"
else
    check_warn "No Activities found — cannot check authorization guard"
fi
echo ""

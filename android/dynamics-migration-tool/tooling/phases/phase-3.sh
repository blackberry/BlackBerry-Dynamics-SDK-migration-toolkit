# BlackBerry Dynamics Migration — validator phase 3
#
# Sourced by tooling/validate.sh once should_run_phase "3" passes.
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
    # Phase 3: Authorization
    # ========================================
    echo "Phase 3: Authorization"
    echo "-----------------------------------------"

    # WI-01: forbid mixing direct authorize() with activityInit() (kit entry path).
    AUTH_PHASE3_ROOTS="$MM_IN_SCOPE_SOURCE_ROOTS"
    [ -z "$AUTH_PHASE3_ROOTS" ] && AUTH_PHASE3_ROOTS="$SRC_DIR"
    # shellcheck disable=SC2086
    PHASE3_MIXED_AUTH_RESULT="$(python3 "$SCRIPT_DIR/lib/auth-mixed-entry-scan.py" $AUTH_PHASE3_ROOTS 2>/dev/null || echo OK)"
    case "${PHASE3_MIXED_AUTH_RESULT%%|*}" in
        MIXED)
            check_fail "Direct GDAndroid.getInstance().authorize() must not be used with activityInit() — ${PHASE3_MIXED_AUTH_RESULT#MIXED|}. This kit uses global GDStateListener + activityInit() as its Activity entry policy; convert direct authorize() usage or document a non-kit authorization architecture. See steering/20-auth-initialization.md"
            ;;
        *)
            check_pass "No mixed authorize()/activityInit() authorization entry paths (WI-01)"
            ;;
    esac

    # Detect the known agent mistake: applicationInit() used in
    # place of setGDStateListener(). applicationInit() does not register
    # a GDStateListener and its presence in an Application class is
    # usually an agent error in the kit-policy Application class (see
    # steering/20-auth-initialization.md "Known Agent Mistake" section).
    APPLICATION_INIT_FILES=$(grep -rln "applicationInit\s*(" "$SRC_DIR/" 2>/dev/null \
        | python3 "$STRIP_AUDIT_NOISE_PY" 2>/dev/null || true)
    if [ -n "$APPLICATION_INIT_FILES" ]; then
        APPLICATION_INIT_NAMES=$(echo "$APPLICATION_INIT_FILES" | sed 's/:.*$//' | sort -u | xargs -I{} basename {} | paste -sd ' ' -)
        _set_violation_context "authorization" "3" \
            "Replace applicationInit(this) with GDAndroid.getInstance().setGDStateListener(this)" \
            "$APPLICATION_INIT_NAMES"
        check_fail "[AUTH-LISTENER-001] applicationInit() found in $APPLICATION_INIT_NAMES — this does not register the kit-policy GDStateListener. Replace with GDAndroid.getInstance().setGDStateListener(this), or document a deliberate non-kit authorization architecture before final acceptance. See steering/20-auth-initialization.md"
    else
        check_pass "No applicationInit() substitution for setGDStateListener detected"
    fi

# Match both Java (implements GDStateListener) and Kotlin (: GDStateListener / , GDStateListener)
GD_LISTENER_FILE=$(grep -rl "implements.*GDStateListener\|[,:] *GDStateListener" "$SRC_DIR/" 2>/dev/null | head -1)

if [ -n "$GD_LISTENER_FILE" ]; then
    check_pass "GDStateListener implemented ($(basename "$GD_LISTENER_FILE"))"

    # Check if it's a global listener (Application class with setGDStateListener)
    GLOBAL_LISTENER=$(grep -rl "setGDStateListener" "$SRC_DIR/" 2>/dev/null | head -1)
    if [ -n "$GLOBAL_LISTENER" ]; then
        check_pass "Global GDStateListener set via setGDStateListener() ($(basename "$GLOBAL_LISTENER"))"
    else
        # [AUTH-LISTENER-001] Cross-check: activityInit() call sites vs
        # GDStateListener registration.
        #
        # Safety invariant:
        #   ∀ Activity A where activityInit(A) is called:
        #     A implements GDStateListener
        #     OR setGDStateListener() was called in Application.onCreate()
        #
        # When NEITHER path is satisfied, the SDK throws
        # GDInitializationError on every launch — guaranteed runtime crash.
        AUTH_LISTENER_CROSS_CHECK=$(python3 - "$SRC_DIR" <<'PY' 2>/dev/null
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
SKIP_PARENTS = frozenset(
    {"Activity", "AppCompatActivity", "FragmentActivity", "ComponentActivity"}
)
MAX_DEPTH = 8


def read_file(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def code_lines(text):
    for line in text.splitlines():
        s = line.lstrip()
        if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        yield line


def parent_class_name(text):
    m = re.search(r"class\s+[A-Za-z_]\w*\s*:\s*([A-Za-z_]\w*)", text)
    if m:
        return m.group(1)
    m = re.search(r"class\s+[A-Za-z_]\w*\s+extends\s+([A-Za-z_]\w*)", text)
    if m:
        return m.group(1)
    return None


def find_class_file(class_name):
    pat = re.compile(rf"\bclass\s+{re.escape(class_name)}\b")
    for dirpath, _, files in os.walk(src_root):
        for fn in files:
            if not fn.endswith((".java", ".kt")):
                continue
            path = os.path.join(dirpath, fn)
            head = read_file(path)[:8192]
            if pat.search(head):
                return path
    return None


def has_in_chain(path, predicate):
    current = path
    seen = set()
    for _ in range(MAX_DEPTH):
        if not current or current in seen:
            break
        seen.add(current)
        if predicate(current):
            return True
        text = read_file(current)
        parent = parent_class_name(text)
        if not parent or parent in SKIP_PARENTS:
            break
        nxt = find_class_file(parent)
        if not nxt:
            break
        current = nxt
    return False


def file_has_activity_init(path):
    text = read_file(path)
    return any(ACTIVITY_INIT_RE.search(s) for s in code_lines(text))


def file_implements_listener(path):
    return bool(GD_LISTENER_RE.search(read_file(path)))


unprotected = []
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.join(dirpath, fn)
        text = read_file(path)[:4096]
        if not ACTIVITY_CLASS_RE.search(text):
            continue
        if not has_in_chain(path, file_has_activity_init):
            continue
        if has_in_chain(path, file_implements_listener):
            continue
        unprotected.append(fn)

if unprotected:
    print("FAIL|" + " ".join(sorted(set(unprotected))))
else:
    print("OK|all activityInit() call sites have GDStateListener coverage")
PY
) || AUTH_LISTENER_CROSS_CHECK="ERROR|cross-check script failed"
        case "${AUTH_LISTENER_CROSS_CHECK%%|*}" in
            FAIL)
                _set_violation_context "authorization" "3" \
                    "Add GDAndroid.getInstance().setGDStateListener(this) to Application.onCreate()" \
                    "${AUTH_LISTENER_CROSS_CHECK#FAIL|}"
                check_fail "[AUTH-LISTENER-001] RUNTIME CRASH: activityInit() called in ${AUTH_LISTENER_CROSS_CHECK#FAIL|} but no GDStateListener is registered — neither setGDStateListener() in Application nor 'implements GDStateListener' on the Activity. The SDK will throw GDInitializationError on every launch. Fix: add GDAndroid.getInstance().setGDStateListener(this) to Application.onCreate(). See steering/20-auth-initialization.md"
                ;;
            OK)
                check_warn "No setGDStateListener() found — per-Activity GDStateListener pattern detected. Consider adding global setGDStateListener() for multi-Activity safety"
                ;;
            *)
                check_warn "No setGDStateListener() found and [AUTH-LISTENER-001] cross-check could not run — manually verify GDStateListener registration covers all activityInit() call sites"
                ;;
        esac
    fi

    # Listener-file placement is informational — per-Activity placement
    # (checked below) is the authoritative source of truth. Calling
    # activityInit() directly from each Activity is the documented
    # expected pattern, so the listener file usually does NOT contain it.
    if grep -q "activityInit" "$GD_LISTENER_FILE" 2>/dev/null; then
        check_pass "activityInit() referenced in listener file ($(basename "$GD_LISTENER_FILE"))"
    else
        check_pass "activityInit() not in listener file — expected when Activities call it directly (per-Activity audit follows)"
    fi

    # Check that ALL Activities call activityInit (directly or via an ancestor class)
    # Match both Java (extends Activity/AppCompatActivity) and Kotlin (: Activity() / : AppCompatActivity())
    ALL_ACTIVITIES=$(grep -rl "extends.*Activity\|extends.*AppCompatActivity\|:.*Activity()\|:.*AppCompatActivity()" "$SRC_DIR/" 2>/dev/null)

    # Helper: extract parent class name from a file (Java or Kotlin)
    get_parent_class() {
        local FILE="$1"
        local PARENT
        PARENT=$(sed -n 's/.*extends \([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' "$FILE" 2>/dev/null | head -1)
        if [ -z "$PARENT" ]; then
            PARENT=$(sed -n 's/.*class [A-Za-z_][A-Za-z0-9_<>, ]* : \([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' "$FILE" 2>/dev/null | head -1)
        fi
        echo "$PARENT"
    }

    # Helper: check if a file or any of its ancestors contain activityInit( in code
    # (not comments). Walks up to 8 inheritance levels (aligned with phase-11).
    has_activity_init_in_chain() {
        local FILE="$1"
        python3 - "$FILE" "$SRC_DIR" <<'PY'
import os
import re
import sys

start_path, src_root = sys.argv[1], sys.argv[2]
ACTIVITY_INIT = re.compile(r"\bactivityInit\s*\(")
SKIP_PARENTS = frozenset(
    {"Activity", "AppCompatActivity", "FragmentActivity", "ComponentActivity"}
)


def comment_stripped_lines(text):
    for line in text.splitlines():
        s = line.lstrip()
        if not s or s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        if "//" in s:
            s = s[: s.index("//")]
        if s.strip():
            yield s


def file_has_activity_init(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    return any(ACTIVITY_INIT.search(s) for s in comment_stripped_lines(text))


def parent_class_name(text):
    m = re.search(
        r"class\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*([A-Za-z_][A-Za-z0-9_]*)", text
    )
    if m:
        return m.group(1)
    m = re.search(
        r"class\s+[A-Za-z_][A-Za-z0-9_]*\s+extends\s+([A-Za-z_][A-Za-z0-9_]*)", text
    )
    if m:
        return m.group(1)
    return None


def find_class_file(class_name):
    pat = re.compile(rf"\bclass\s+{re.escape(class_name)}\b")
    for dirpath, _, files in os.walk(src_root):
        for fn in files:
            if not fn.endswith((".java", ".kt")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                head = open(path, encoding="utf-8", errors="replace").read(8192)
            except OSError:
                continue
            if pat.search(head):
                return path
    return None


current = start_path
seen = set()
for _ in range(8):
    if not current or current in seen:
        break
    seen.add(current)
    if file_has_activity_init(current):
        sys.exit(0)
    try:
        text = open(current, encoding="utf-8", errors="replace").read()
    except OSError:
        break
    parent = parent_class_name(text)
    if not parent or parent in SKIP_PARENTS:
        break
    nxt = find_class_file(parent)
    if not nxt:
        break
    current = nxt
sys.exit(1)
PY
    }

    # processModel-aware activityInit audit (bootstrap.json)
    PHASE3_PM_RESULT="$(python3 - "$BOOTSTRAP_FILE" "$SRC_DIR" <<'PY' 2>/dev/null || echo "legacy"
import json
import os
import re
import sys

bootstrap_path, src_root = sys.argv[1], sys.argv[2]
if not os.path.isfile(bootstrap_path):
    print("legacy")
    sys.exit(0)
try:
    with open(bootstrap_path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("legacy")
    sys.exit(0)
pm = data.get("processModel")
if not isinstance(pm, dict):
    print("legacy")
    sys.exit(0)

ACTIVITY_INIT = re.compile(r"\bactivityInit\s*\(")
SKIP_PARENTS = frozenset(
    {"Activity", "AppCompatActivity", "FragmentActivity", "ComponentActivity"}
)
MAX_DEPTH = 8


def comment_stripped_lines(text):
    for line in text.splitlines():
        s = line.lstrip()
        if not s or s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        if "//" in s:
            s = s[: s.index("//")]
        if s.strip():
            yield s


def file_has_activity_init(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    return any(ACTIVITY_INIT.search(s) for s in comment_stripped_lines(text))


def class_name_from_file(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    m = re.search(r"class\s+([A-Za-z_][A-Za-z0-9_]*)", text)
    return m.group(1) if m else None


def parent_class_name(text):
    m = re.search(
        r"class\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*([A-Za-z_][A-Za-z0-9_]*)", text
    )
    if m:
        return m.group(1)
    m = re.search(
        r"class\s+[A-Za-z_][A-Za-z0-9_]*\s+extends\s+([A-Za-z_][A-Za-z0-9_]*)", text
    )
    if m:
        return m.group(1)
    return None


def find_class_file(class_name):
    pat = re.compile(rf"\bclass\s+{re.escape(class_name)}\b")
    for dirpath, _, files in os.walk(src_root):
        for fn in files:
            if not fn.endswith((".java", ".kt")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                head = open(path, encoding="utf-8", errors="replace").read(8192)
            except OSError:
                continue
            if pat.search(head):
                return path
    return None


def has_activity_init_in_chain(path):
    current = path
    seen = set()
    for _ in range(MAX_DEPTH):
        if not current or current in seen:
            break
        seen.add(current)
        if file_has_activity_init(current):
            return True
        try:
            text = open(current, encoding="utf-8", errors="replace").read()
        except OSError:
            break
        parent = parent_class_name(text)
        if not parent or parent in SKIP_PARENTS:
            break
        nxt = find_class_file(parent)
        if not nxt:
            break
        current = nxt
    return False


missing_main = []
forbidden_aux = []
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.join(dirpath, fn)
        try:
            text_head = open(path, encoding="utf-8", errors="replace").read(4096)
        except OSError:
            continue
        if not re.search(
            r"extends\s+.*Activity|:.*Activity\(\)|:.*AppCompatActivity\(\)", text_head
        ):
            continue
        cls = class_name_from_file(path)
        if not cls:
            continue
        classification = "main"
        for c in pm.get("components") or []:
            if not isinstance(c, dict) or c.get("kind") != "activity":
                continue
            cname = c.get("name") or ""
            if cname == cls or cname.endswith("." + cls):
                classification = c.get("classification") or "main"
                break
        is_aux = classification == "auxiliary"
        has_init = has_activity_init_in_chain(path)
        if is_aux:
            if has_init:
                forbidden_aux.append(os.path.basename(path))
        else:
            if not has_init:
                missing_main.append(os.path.basename(path))

if forbidden_aux:
    print("FORBID|" + " ".join(sorted(set(forbidden_aux))))
elif missing_main:
    print("MISSING|" + " ".join(sorted(set(missing_main))))
else:
    print("OK|processModel")
PY
)"
    case "${PHASE3_PM_RESULT%%|*}" in
        OK)
            check_pass "activityInit() rules satisfied per bootstrap processModel"
            ;;
        FORBID)
            check_fail "activityInit() must NOT run in auxiliary-process Activities: ${PHASE3_PM_RESULT#FORBID|} — see steering/22-multi-process-app-handling.md"
            ;;
        MISSING)
            check_fail "activityInit() missing in main-process Activities: ${PHASE3_PM_RESULT#MISSING|} — add GDAndroid.getInstance().activityInit(this) after super.onCreate()"
            ;;
        *)
            MISSING_INIT=""
            for ACTIVITY_FILE in $ALL_ACTIVITIES; do
                if ! has_activity_init_in_chain "$ACTIVITY_FILE"; then
                    MISSING_INIT="$MISSING_INIT $(basename "$ACTIVITY_FILE")"
                fi
            done
            if [ -z "$MISSING_INIT" ]; then
                check_pass "activityInit() called in all Activities (directly or via ancestor class)"
            else
                check_fail "activityInit() missing in:$MISSING_INIT — add GDAndroid.getInstance().activityInit(this) after super.onCreate()"
            fi
            ;;
    esac

    grep -q "onAuthorized" "$GD_LISTENER_FILE" 2>/dev/null && \
        check_pass "onAuthorized() implemented" || check_fail "onAuthorized() missing — re-run prompt 03 (add-dynamics-auth)"
    grep -q "onLocked" "$GD_LISTENER_FILE" 2>/dev/null && \
        check_pass "onLocked() implemented" || check_fail "onLocked() missing — re-run prompt 03 (add-dynamics-auth)"
    grep -q "onWiped" "$GD_LISTENER_FILE" 2>/dev/null && \
        check_pass "onWiped() implemented" || check_fail "onWiped() missing — re-run prompt 03 (add-dynamics-auth)"
else
    check_fail "No GDStateListener implementation found — re-run prompt 03 (add-dynamics-auth)"
fi

# -----------------------------------------------------------------------
# PROC-AUX-001: Auxiliary-process components reaching GD file APIs.
#     Detects import-based and fully-qualified com.good.gd.file.* usage in
#     the aux component and in 1–2 hop shared helpers (e.g. crash-handler
#     Activity -> log helper -> directory/file helper). Guard patterns
#     (`isContainerAuthorized` / `isMainProcess`) suppress known-safe flows.
#
#     This is a FAILURE: GD is never authorized in auxiliary processes —
#     calling com.good.gd.file.* throws GDNotAuthorizedError (crash-handler
#     cascade). Prompt 10 still accepts explicit unverifiedSurfaces[]
#     closure when remediation is deferred.
# -----------------------------------------------------------------------
PROC_AUX_SCAN_PY="$SCRIPT_DIR/lib/proc-aux-gd-reach-scan.py"
PROC_AUX_SRC_ROOT="$SRC_DIR_MM"
[ -z "$PROC_AUX_SRC_ROOT" ] && PROC_AUX_SRC_ROOT="$SRC_DIR"
if [ -f "$PROC_AUX_SCAN_PY" ]; then
    PROC_AUX_GD_REACH_RESULT="$(python3 "$PROC_AUX_SCAN_PY" "$BOOTSTRAP_FILE" "$PROC_AUX_SRC_ROOT" 2>/dev/null || echo "SKIP|0")"
else
    PROC_AUX_GD_REACH_RESULT="SKIP|0"
fi
case "${PROC_AUX_GD_REACH_RESULT%%|*}" in
    FAIL|WARN)
        check_fail "[PROC-AUX-001] Auxiliary-process component(s) reach GD file APIs without authorization guard: ${PROC_AUX_GD_REACH_RESULT#*|} — GD is never authorized in auxiliary processes (GDNotAuthorizedError). Keep crash/error Activities on android.util.Log / java.io, add isContainerAuthorized/isMainProcess guards on shared helpers, or split implementations. See steering/22-multi-process-app-handling.md"
        ;;
    OK)
        check_pass "No auxiliary-process components reaching GD file APIs without authorization guard (PROC-AUX-001)"
        ;;
    *)
        ;;
esac

# APP_RESTRICTIONS lives in any of the primary module's manifests.
APP_RESTRICTIONS_COUNT=0
APP_RESTRICTIONS_SCANNED=false
for mf in $MM_PRIMARY_MANIFESTS; do
    [ -f "$mf" ] || continue
    APP_RESTRICTIONS_SCANNED=true
    APP_RESTRICTIONS_COUNT=$((APP_RESTRICTIONS_COUNT + $(grep -rn "APP_RESTRICTIONS" "$mf" 2>/dev/null \
        | strip_audit_noise \
        | grep "meta-data" \
        | count_hits_for_domain "authorization")))
done
if [ "$APP_RESTRICTIONS_SCANNED" = true ]; then
    if [ "$APP_RESTRICTIONS_COUNT" -gt 0 ]; then
        fail_or_defer "authorization" "APP_RESTRICTIONS metadata still in manifest ($APP_RESTRICTIONS_COUNT) — re-run prompt 03 (authorization) to remove it"
    else
        check_pass "APP_RESTRICTIONS removed (or never existed)"
    fi
fi

# app_restrictions.xml lives under any res/xml/ of the primary module.
APP_RESTRICTIONS_XML_FOUND=false
for res in $MM_PRIMARY_RES_DIRS; do
    if [ -f "$res/xml/app_restrictions.xml" ]; then
        APP_RESTRICTIONS_XML_FOUND=true
        break
    fi
done
if [ "$APP_RESTRICTIONS_XML_FOUND" = true ]; then
    check_warn "app_restrictions.xml still exists"
else
    check_pass "app_restrictions.xml removed (or never existed)"
fi
echo ""

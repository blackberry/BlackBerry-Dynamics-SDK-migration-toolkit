#!/usr/bin/env bash
# BlackBerry Dynamics Migration — Mid-run progress dashboard
#
# Reads bootstrap.json (executedPrompts[]) and optionally the last
# validation sidecar (.last-check.json) to display a compact progress
# view showing which prompts are done, which are pending, and the
# current validation state.
#
# Usage:
#   bash dynamics-migration-tool/tooling/progress.sh [project-directory]
#
# The output is both human-readable (terminal) and machine-parseable
# (a --json flag emits a JSON summary suitable for agent consumption).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

JSON_MODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_MODE=true; shift ;;
        --help|-h)
            echo "Usage: bash dynamics-migration-tool/tooling/progress.sh [--json] [project-directory]"
            echo ""
            echo "Options:"
            echo "  --json    Emit progress as a JSON object (for agent consumption)"
            echo "  --help    Show this message and exit"
            exit 0
            ;;
        *) PROJECT_DIR="$1"; shift ;;
    esac
done

PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
if [[ ! "$PROJECT_DIR" = /* ]]; then
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
fi

BOOTSTRAP_FILE="$TOOL_DIR/output/bootstrap.json"
LAST_CHECK_FILE="$TOOL_DIR/output/.last-check.json"
LOOP_STATE_FILE="$TOOL_DIR/output/migration-loop-state.json"

CANONICAL_ORDER="00pre 00 00b 01 02 03 03b 04 05a 05b 05c 06 07 08 09 11 03c 10 12"

PROMPT_LABELS=(
    "00pre:Bootstrap & Environment"
    "00:Analyze App"
    "00b:Architecture Diagrams (optional)"
    "01:Gradle Integration"
    "02:Settings JSON"
    "03:Authorization Init"
    "03b:Authorization Audit"
    "04:SQLite Migration"
    "05a:File I/O Core"
    "05b:File I/O Reader Closure"
    "05c:SharedPreferences & Closure"
    "06:Networking"
    "07:WebView"
    "08:ICC"
    "09:Secure UI Widgets"
    "11:Push Channel"
    "03c:Background Authorize"
    "10:Final Report"
    "12:Post-Migration Review (optional)"
)

get_label() {
    local id="$1"
    for entry in "${PROMPT_LABELS[@]}"; do
        local key="${entry%%:*}"
        local val="${entry#*:}"
        if [ "$key" = "$id" ]; then
            echo "$val"
            return
        fi
    done
    echo "$id"
}

if [ ! -f "$BOOTSTRAP_FILE" ]; then
    if [ "$JSON_MODE" = true ]; then
        echo '{"status":"not-started","message":"No bootstrap.json found. Run prompt 00pre first."}'
    else
        echo "⚠️  No bootstrap.json found at: $BOOTSTRAP_FILE"
        echo "   Run prompt 00pre-bootstrap first to initialize the migration."
    fi
    exit 0
fi

PROGRESS_DATA=$(python3 - "$BOOTSTRAP_FILE" "$LAST_CHECK_FILE" "$LOOP_STATE_FILE" "$CANONICAL_ORDER" <<'PY'
import json
import os
import sys

bootstrap_path = sys.argv[1]
last_check_path = sys.argv[2]
loop_state_path = sys.argv[3]
canonical_str = sys.argv[4]
canonical = canonical_str.split()

with open(bootstrap_path) as f:
    bootstrap = json.load(f)

executed = {}
for ep in bootstrap.get("executedPrompts", []):
    pid = ep.get("promptId", "")
    executed[pid] = {
        "status": ep.get("status", "unknown"),
        "completedAt": ep.get("completedAt", ""),
        "note": ep.get("note", "")
    }

deferred = bootstrap.get("deferredDomains", [])
agent_name = bootstrap.get("agent", {}).get("name", "unknown")
started_at = bootstrap.get("generatedAt", "unknown")
uem_block = bootstrap.get("uem")
if isinstance(uem_block, dict):
    app_id = uem_block.get("gdApplicationId", "")
else:
    app_id = ""

if not app_id:
    # Backward compatibility for older bootstrap.json shapes.
    app_id = bootstrap.get("environment", {}).get("gdApplicationId", "")

last_check = None
if os.path.isfile(last_check_path):
    try:
        with open(last_check_path) as f:
            last_check = json.load(f)
    except (json.JSONDecodeError, OSError):
        pass

loop_state = None
if os.path.isfile(loop_state_path):
    try:
        with open(loop_state_path) as f:
            loop_state = json.load(f)
    except (json.JSONDecodeError, OSError):
        pass

completed = []
failed = []
pending = []
skipped = []

for pid in canonical:
    if pid in executed:
        s = executed[pid]["status"]
        if s == "completed":
            completed.append(pid)
        elif s == "skipped":
            skipped.append(pid)
        elif s in ("failed", "aborted"):
            failed.append(pid)
        else:
            pending.append(pid)
    else:
        pending.append(pid)

total = len(canonical)
done = len(completed) + len(skipped)
pct = int(done * 100 / total) if total > 0 else 0

result = {
    "status": "in-progress",
    "agent": agent_name,
    "startedAt": started_at,
    "gdApplicationId": app_id,
    "progress": {"completed": done, "total": total, "percent": pct},
    "completedPrompts": completed,
    "failedPrompts": failed,
    "skippedPrompts": skipped,
    "pendingPrompts": pending,
    "deferredDomains": deferred,
    "executed": executed,
}
if last_check:
    result["lastValidation"] = {
        "status": last_check.get("status", "unknown"),
        "passCount": last_check.get("passCount", 0),
        "failCount": last_check.get("failCount", 0),
        "warnCount": last_check.get("warnCount", 0),
        "promptId": last_check.get("promptId", ""),
        "generatedAt": last_check.get("generatedAt", ""),
        "domainSummary": last_check.get("domainSummary", []),
    }

if isinstance(loop_state, dict):
    attempts = loop_state.get("attempts") if isinstance(loop_state.get("attempts"), list) else []
    escalations = loop_state.get("escalations") if isinstance(loop_state.get("escalations"), list) else []
    latest_escalation = escalations[-1] if escalations else None
    latest_failure = None
    for attempt in reversed(attempts):
        if isinstance(attempt, dict) and attempt.get("failureHash"):
            latest_failure = {
                "failureHash": attempt.get("failureHash"),
                "promptId": attempt.get("promptId"),
                "stage": attempt.get("stage"),
                "timestamp": attempt.get("timestamp"),
            }
            break

    stuck = False
    active_escalation = None
    if isinstance(latest_escalation, dict):
        stuck = True
        esc_prompt = latest_escalation.get("promptId")
        esc_ts = latest_escalation.get("timestamp") or ""
        for attempt in reversed(attempts):
            if not isinstance(attempt, dict):
                continue
            if attempt.get("promptId") != esc_prompt:
                continue
            if attempt.get("result") != "passed":
                continue
            if (attempt.get("timestamp") or "") > esc_ts:
                stuck = False
                break
        if stuck:
            active_escalation = {
                "promptId": latest_escalation.get("promptId"),
                "stage": latest_escalation.get("stage"),
                "reason": latest_escalation.get("reason"),
                "safeNextAction": latest_escalation.get("safeNextAction"),
                "timestamp": latest_escalation.get("timestamp"),
            }

    result["loopState"] = {
        "stuck": stuck,
        "activeEscalation": active_escalation,
        "latestRepeatedFailure": latest_failure,
    }
print(json.dumps(result))
PY
)

if [ "$JSON_MODE" = true ]; then
    echo "$PROGRESS_DATA"
    exit 0
fi

# Human-readable output
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║      Dynamics Migration — Progress Dashboard        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

python3 - "$PROGRESS_DATA" "$CANONICAL_ORDER" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
canonical = sys.argv[2].split()

PROMPT_LABELS = {
    "00pre": "Bootstrap & Environment",
    "00": "Analyze App",
    "00b": "Architecture Diagrams",
    "01": "Gradle Integration",
    "02": "Settings JSON",
    "03": "Authorization Init",
    "03b": "Authorization Audit",
    "04": "SQLite Migration",
    "05a": "File I/O Core",
    "05b": "File I/O Reader Closure",
    "05c": "SharedPreferences & Closure",
    "06": "Networking",
    "07": "WebView",
    "08": "ICC",
    "09": "Secure UI Widgets",
    "11": "Push Channel",
    "03c": "Background Authorize",
    "10": "Final Report",
    "12": "Post-Migration Review",
}

prog = data["progress"]
bar_width = 30
filled = int(bar_width * prog["percent"] / 100)
bar = "█" * filled + "░" * (bar_width - filled)
print(f"  Progress: [{bar}] {prog['percent']}% ({prog['completed']}/{prog['total']})")
print(f"  Agent: {data['agent']}   Started: {data['startedAt'][:10]}")
if data.get("gdApplicationId"):
    print(f"  App ID: {data['gdApplicationId']}")
print()

executed = data.get("executed", {})
completed_set = set(data["completedPrompts"])
failed_set = set(data["failedPrompts"])
skipped_set = set(data["skippedPrompts"])

print("  Prompt Status:")
print("  " + "─" * 50)
for pid in canonical:
    label = PROMPT_LABELS.get(pid, pid)
    if pid in completed_set:
        icon = "✅"
        ts = executed.get(pid, {}).get("completedAt", "")[:16].replace("T", " ")
        extra = f"  ({ts})" if ts else ""
    elif pid in failed_set:
        icon = "❌"
        note = executed.get(pid, {}).get("note", "")
        extra = f"  — {note}" if note else ""
    elif pid in skipped_set:
        icon = "⏭️ "
        extra = " (skipped)"
    else:
        found_current = False
        for c in canonical:
            if c in completed_set or c in skipped_set:
                continue
            if c == pid:
                found_current = True
            break
        if found_current:
            icon = "🔄"
            extra = " ← current"
        else:
            icon = "⬜"
            extra = ""
    print(f"  {icon} {pid:6s} {label}{extra}")

if data.get("deferredDomains"):
    print()
    print(f"  Deferred Domains: {', '.join(data['deferredDomains'])}")

lv = data.get("lastValidation")
if lv:
    print()
    print("  Last Validation:")
    print("  " + "─" * 50)
    status_icon = "✅" if lv["status"] == "passed" else "❌"
    print(f"  {status_icon} Status: {lv['status']}  (prompt: {lv['promptId']})")
    print(f"     Pass: {lv['passCount']}  Fail: {lv['failCount']}  Warn: {lv['warnCount']}")
    ds = lv.get("domainSummary", [])
    if ds:
        print("     Failing domains: " + ", ".join(
            f"{d['domain']}({d['failCount']})" for d in ds
        ))
    if lv.get("generatedAt"):
        print(f"     At: {lv['generatedAt']}")

ls = data.get("loopState")
if ls:
    print()
    print("  Retry State:")
    print("  " + "─" * 50)
    print(f"  Stuck: {'yes' if ls.get('stuck') else 'no'}")
    esc = ls.get("activeEscalation")
    if esc:
        print(
            "  Active escalation: "
            f"prompt={esc.get('promptId')} stage={esc.get('stage')} "
            f"reason={esc.get('reason')} action={esc.get('safeNextAction')}"
        )
    lf = ls.get("latestRepeatedFailure")
    if lf:
        print(
            "  Latest repeated failure: "
            f"prompt={lf.get('promptId')} stage={lf.get('stage')} hash={lf.get('failureHash')}"
        )

print()
PY

#!/bin/bash

# BlackBerry Dynamics Migration — Prompt Execution Recorder
#
# Appends (or upserts) an entry to dynamics-migration-tool/output/bootstrap.json's
# executedPrompts[] array, recording that a migration prompt has run. The
# resulting array is the canonical execution audit consumed by prompt 10's
# hard gate (step 9: cross-check execution plan).
#
# Validation ownership:
#   Prompt-scoped validation is the prompt-boundary gate. After a successful
#   `--status completed`:
#     - prompts with scopedChecks run `validate.sh --check-prompt <id>`;
#     - no-op prompts record progress only and keep the run moving;
#     - prompt 10 runs split acceptance gates:
#         1) `validate.sh --mode final-source --prompt 10`
#         2) `validate.sh --mode report --prompt 10`
#       guarded so completion cannot be recorded unless both pass.
#   After bootstrap.json is updated, when migration-report.json exists the
#   recorder syncs report provenance from bootstrap (executedPrompts, runId,
#   toolkit/SDK fields, validation summary) and runs a provenance consistency
#   check so validate.sh cannot fail on bootstrap/report drift.
#   If validation fails, no executedPrompts entry is written and the recorder
#   exits non-zero. The AI agent re-runs the prompt's edit step and re-invokes
#   this recorder. Incremental selection is internal; the agent calls the
#   recorder exactly as before (no new arguments).
#
# M2 / evidence / requires[]:
#   These closure gates are enforced at prompt 10, alongside split final
#   validation gates, so intermediate prompts do not get stuck proving that
#   later-prompt work is unfinished. See
#   steering/79-migration-plan-state-and-call-site-closure.md.
#
# Why a helper script:
#   - Centralizes the JSON merge logic so individual prompts don't write
#     ad-hoc Python in their final step.
#   - Avoids the JSON-corruption class of bugs (multiple root objects from
#     patch-style writes) that the kit's output-file-hygiene rule was
#     introduced to prevent.
#   - Makes re-running a prompt idempotent: if an entry for the same
#     promptId already exists, it is REPLACED, not duplicated.
#   - Provides a single source of truth for which validator phases run
#     after each prompt (via check-prompt-map.json).
#
# Usage:
#   bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
#       --prompt-id <PROMPT-ID> \
#       --status <completed|failed|aborted|skipped> \
#       [--files-touched <comma-separated relative paths>] \
#       [--started-at <ISO-8601 UTC>] \
#       [--note <free text>]
#
# Exits 0 on successful append/upsert. Exits 1 if bootstrap.json is missing,
# Git baseline/backup evidence is missing, prompt-10 final validation fails,
# a touched artifact fails cheap schema sanity checks, or prompt-10 closure
# gates fail. Exits 2 on argument/config errors.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$TOOL_DIR/output"
BOOTSTRAP_FILE="$OUT_DIR/bootstrap.json"
ANALYSIS_FILE="$OUT_DIR/migration-analysis.json"
PLAN_STATE_FILE="$OUT_DIR/migration-plan-state.json"
REPORT_FILE="$OUT_DIR/migration-report.json"
MODULE_MAP_FILE="$OUT_DIR/module-map.json"
LAST_CHECK_FILE="$OUT_DIR/.last-check.json"
LAST_SOURCE_CHECK_FILE="$OUT_DIR/.last-source-check.json"
LAST_REPORT_CHECK_FILE="$OUT_DIR/.last-report-check.json"
LOOP_STATE_FILE="$OUT_DIR/migration-loop-state.json"
VALIDATE_SH="$TOOL_DIR/tooling/validate.sh"
CHECK_PROMPT_MAP="$TOOL_DIR/tooling/check-prompt-map.json"
CHANGED_FILES_SH="$TOOL_DIR/tooling/lib/changed-files.sh"
SYNC_REPORT_PROVENANCE_PY="$SCRIPT_DIR/lib/sync-report-provenance.py"
PREP_REPORT_ARTIFACTS_PY="$SCRIPT_DIR/lib/prepare-report-artifacts.py"
LOOP_STATE_SH="$TOOL_DIR/tooling/loop-state.sh"
DIAGNOSTICS_CONTRACT_PY="$TOOL_DIR/tooling/lib/diagnostics-contract.py"
# shellcheck source=lib/toolkit-version.sh
. "$SCRIPT_DIR/lib/toolkit-version.sh"
toolkit_version_load "$TOOL_DIR"

# Schema lookup: prefer the toolkit-bundled copy in
# `dynamics-migration-tool/schemas/` (always present in a consumer
# project), fall back to the canonical-source layout at
# `<repo>/documentation/report-contract/` (only present when running
# inside the BlackBerry Dynamics source tree).
PLAN_STATE_SCHEMA_NAME="migration-plan-state.schema.v1.1.0.json"
REPORT_SCHEMA_NAME="migration-report.schema.v2.1.0.json"
resolve_schema_path() {
    local name="$1"
    local bundled="$TOOL_DIR/schemas/$name"
    local canonical="$TOOL_DIR/../documentation/report-contract/$name"
    if [ -f "$bundled" ]; then
        printf '%s' "$bundled"
        return 0
    fi
    if [ -f "$canonical" ]; then
        printf '%s' "$canonical"
        return 0
    fi
    # Return the preferred (bundled) path; downstream code will produce
    # a clearer error referencing both candidates.
    printf '%s' "$bundled"
    return 0
}
PLAN_STATE_SCHEMA_FILE="$(resolve_schema_path "$PLAN_STATE_SCHEMA_NAME")"
REPORT_SCHEMA_FILE="$(resolve_schema_path "$REPORT_SCHEMA_NAME")"

OBSERVABILITY_PY="$TOOL_DIR/tooling/lib/observability.py"
OBS_RUN_ID="$(python3 - "$BOOTSTRAP_FILE" <<'PY' 2>/dev/null || true
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        print(json.load(f).get("runId") or "")
except Exception:
    print("")
PY
)"
observability_event() {
    [ -f "$OBSERVABILITY_PY" ] || return 0
    python3 "$OBSERVABILITY_PY" event \
        --tool-dir "$TOOL_DIR" \
        --project-root "$PROJECT_ROOT" \
        --platform android \
        --run-id "${OBS_RUN_ID:-}" \
        "$@" >/dev/null 2>&1 || true
}

PROMPT_ID=""
STATUS=""
FILES_TOUCHED=""
STARTED_AT=""
NOTE=""
RETRY_GUIDANCE=false
VALID_PROMPT_IDS=("00pre" "00" "00b" "01" "02" "03" "03b" "04" "05a" "05b" "05c" "05z" "06" "07" "08" "09" "11" "03c" "10" "12")

usage() {
    cat <<USAGE
Usage: bash dynamics-migration-tool/tooling/record-prompt-execution.sh [options]

Required:
  --prompt-id <id>           One of: 00pre, 00, 00b, 01, 02, 03, 03b, 04,
                             05a, 05b, 05c, 05z, 06, 07, 08, 09, 11, 03c, 10, 12
  --status <status>          One of: completed, failed, aborted, skipped

Optional:
  --files-touched <list>     Comma-separated relative paths
  --started-at <ts>          ISO-8601 UTC timestamp; defaults to "now" minus
                             a few seconds if omitted
  --note <text>              Free-form note (e.g. "deferred — Room bridge
                             pending review")
  --retry-guidance           On validation failure, emit structured JSON
                             guidance to stdout describing fixable violations
                             and the re-run command. Designed for agent auto-
                             retry loops.
  --version                  Print toolkit version and exit
  --help                     This message

Behaviour:
  The recorder logs prompt progress and owns deterministic validation gates.
  After --status completed, prompts with scopedChecks run
  validate.sh --check-prompt <id>; no-op prompts record without validation;
  prompt 10 runs the final source/report acceptance gates. If validation
  fails, no executedPrompts entry is written and the recorder exits non-zero.
USAGE
}

is_valid_prompt_id() {
    local candidate="$1"
    local pid
    for pid in "${VALID_PROMPT_IDS[@]}"; do
        if [ "$pid" = "$candidate" ]; then
            return 0
        fi
    done
    return 1
}

closest_prompt_id() {
    python3 - "$1" "${VALID_PROMPT_IDS[@]}" <<'PY'
import difflib
import sys

candidate = sys.argv[1]
options = sys.argv[2:]
matches = difflib.get_close_matches(candidate, options, n=1, cutoff=0.3)
if matches:
    print(matches[0])
PY
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt-id)        PROMPT_ID="$2"; shift 2 ;;
        --status)           STATUS="$2"; shift 2 ;;
        --files-touched)    FILES_TOUCHED="$2"; shift 2 ;;
        --started-at)       STARTED_AT="$2"; shift 2 ;;
        --note)             NOTE="$2"; shift 2 ;;
        --retry-guidance)   RETRY_GUIDANCE=true; shift ;;
        --version)          toolkit_version_print; exit 0 ;;
        --help)             usage; exit 0 ;;
        *)                  echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ----- argument validation -----
if [ -z "$PROMPT_ID" ] || [ -z "$STATUS" ]; then
    echo "❌ --prompt-id and --status are required" >&2
    usage >&2
    exit 2
fi

if ! is_valid_prompt_id "$PROMPT_ID"; then
    SUGGESTED_PROMPT_ID="$(closest_prompt_id "$PROMPT_ID")"
    echo "❌ invalid --prompt-id: $PROMPT_ID" >&2
    if [ -n "$SUGGESTED_PROMPT_ID" ]; then
        echo "   Did you mean '$SUGGESTED_PROMPT_ID'?" >&2
    fi
    echo "   Use one of: ${VALID_PROMPT_IDS[*]}" >&2
    echo "   Remediation: pass the short prompt label (e.g., --prompt-id 00pre), not a file stem like 00pre-bootstrap." >&2
    exit 2
fi

case "$STATUS" in
    completed|failed|aborted|skipped) ;;
    *) echo "❌ invalid --status: $STATUS (must be completed|failed|aborted|skipped)" >&2; exit 2 ;;
esac

if [ ! -f "$BOOTSTRAP_FILE" ]; then
    echo "❌ $BOOTSTRAP_FILE not found — run prompt 00pre-bootstrap.md first" >&2
    exit 1
fi

ensure_git_baseline_for_recording() {
    if ! git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "❌ Git baseline required: $PROJECT_ROOT is not a Git repository." >&2
        echo "   Re-run prompt 00pre and authorize the kit to initialize Git and create" >&2
        echo "   the pre-migration baseline commit. Non-Git Android migrations are not supported." >&2
        exit 1
    fi
    if ! git -C "$PROJECT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
        echo "❌ Git baseline required: repository has no commit baseline." >&2
        echo "   Re-run prompt 00pre and authorize the pre-migration baseline commit." >&2
        exit 1
    fi

    local backup_check
    if ! backup_check="$(BOOTSTRAP_FILE="$BOOTSTRAP_FILE" python3 - <<'PY'
import json
import os
import re
import sys
from collections import Counter

path = os.environ["BOOTSTRAP_FILE"]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(f"ERROR|bootstrap.json is invalid: {exc}")
    sys.exit(1)

backup = data.get("backup") if isinstance(data, dict) else None
if not isinstance(backup, dict):
    print("ERROR|bootstrap.backup must be an object")
    sys.exit(1)

branch = backup.get("branch")
sha = backup.get("createdFromCommit")
if not isinstance(branch, str) or not branch.strip():
    print("ERROR|bootstrap.backup.branch must be populated")
    sys.exit(1)
if not isinstance(sha, str) or not sha.strip():
    print("ERROR|bootstrap.backup.createdFromCommit must be populated")
    sys.exit(1)

print(f"OK|{branch.strip()}|{sha.strip()}")
PY
)"; then
        echo "❌ Git baseline required: ${backup_check#ERROR|}" >&2
        echo "   Re-run prompt 00pre so bootstrap.json records the backup branch evidence." >&2
        exit 1
    fi

    local marker branch sha
    IFS='|' read -r marker branch sha <<< "$backup_check"
    if [ "$marker" != "OK" ]; then
        echo "❌ Git baseline required: ${backup_check#ERROR|}" >&2
        echo "   Re-run prompt 00pre so bootstrap.json records the backup branch evidence." >&2
        exit 1
    fi
    if ! git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
        echo "❌ Git backup branch missing: $branch" >&2
        echo "   Re-run prompt 00pre so it can create the required migration backup branch." >&2
        exit 1
    fi
    if ! git -C "$PROJECT_ROOT" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
        echo "❌ Git backup commit is not resolvable: $sha" >&2
        echo "   Re-run prompt 00pre so it can record a valid backup commit." >&2
        exit 1
    fi
}

PROMPT10_SPLIT_GATE_PENDING=false

if [ "$STATUS" = "completed" ]; then
    ensure_git_baseline_for_recording
fi

# ----- recorder-owned validation (only for --status completed) -----
#
# Prompt 10 is the hard final acceptance gate and MUST run split final
# validation (source gate, then report-contract gate). Intermediate prompts
# with scopedChecks run their prompt-scoped validator here before the recorder
# mutates bootstrap.json.

surface_last_check_failure() {
    local sidecar="$1"
    if [ ! -f "$sidecar" ]; then
        return 0
    fi
    python3 - "$sidecar" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(f"   (could not read {path}: {exc})", file=sys.stderr)
    sys.exit(0)

violations = data.get("violations") or []
if violations:
    print("", file=sys.stderr)
    sidecar_label = path.split("dynamics-migration-tool/output/")[-1]
    print(f"   Violations (from {sidecar_label}):", file=sys.stderr)
    for v in violations:
        if not isinstance(v, dict):
            continue
        loc = ""
        if v.get("file"):
            loc = f" {v['file']}"
            if v.get("line"):
                loc += f":{v['line']}"
        domain = v.get("domain") or ""
        detector = v.get("detector") or ""
        message = v.get("message") or ""
        fix = v.get("fix") or ""
        print(f"     -{loc}", file=sys.stderr)
        if domain or detector:
            print(f"         domain={domain} detector={detector}", file=sys.stderr)
        if message:
            print(f"         message={message}", file=sys.stderr)
        if fix:
            print(f"         FIX: {fix}", file=sys.stderr)

remediation = data.get("remediation")
if remediation:
    print("", file=sys.stderr)
    print("   Remediation:", file=sys.stderr)
    print(f"     {remediation}", file=sys.stderr)

ds = data.get("domainSummary") or []
if ds:
    print("", file=sys.stderr)
    print("   Domain failure summary:", file=sys.stderr)
    for d in ds:
        print(f"     {d.get('domain','?')}: {d.get('failCount',0)} failure(s)", file=sys.stderr)
PY
}

# emit_retry_guidance: writes structured JSON retry guidance to stdout
# when the recorder exits non-zero. Designed for agent consumption
# in automated retry loops.
emit_retry_guidance() {
    local prompt_id="$1"
    local sidecar="$2"
    if [ ! -f "$sidecar" ]; then
        echo '{"retryable":false,"reason":"no sidecar"}'
        return
    fi
    PROMPT_ID_ENV="$prompt_id" LOOP_STATE_FILE_ENV="$LOOP_STATE_FILE" python3 - "$sidecar" <<'PY'
import json, os, sys

path = sys.argv[1]
prompt_id = os.environ.get("PROMPT_ID_ENV", "")
loop_state_path = os.environ.get("LOOP_STATE_FILE_ENV", "")
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print(json.dumps({"retryable": False, "reason": "sidecar parse error"}))
    sys.exit(0)

violations = data.get("violations") or []
fails = [v for v in violations if isinstance(v, dict) and v.get("severity") == "fail"]
fixes = [v for v in fails if v.get("fix")]
ds = data.get("domainSummary") or []

guidance = {
    "retryable": len(fixes) > 0,
    "promptId": prompt_id,
    "failCount": data.get("failCount", 0),
    "warnCount": data.get("warnCount", 0),
    "domainSummary": ds,
    "fixableViolations": len(fixes),
    "totalViolations": len(fails),
    "fixes": [],
}

if loop_state_path:
    try:
        with open(loop_state_path, "r", encoding="utf-8") as lf:
            loop_state = json.load(lf)
    except Exception:
        loop_state = None
    if isinstance(loop_state, dict):
        attempts = loop_state.get("attempts")
        escalations = loop_state.get("escalations")
        latest_attempt = None
        if isinstance(attempts, list):
            for entry in reversed(attempts):
                if isinstance(entry, dict) and entry.get("promptId") == prompt_id:
                    latest_attempt = entry
                    break
        latest_escalation = None
        if isinstance(escalations, list):
            for entry in reversed(escalations):
                if isinstance(entry, dict) and entry.get("promptId") == prompt_id:
                    latest_escalation = entry
                    break
        if isinstance(latest_attempt, dict):
            guidance["retryBudget"] = latest_attempt.get("retryBudget", {})
            rf = latest_attempt.get("repairFeedback")
            if isinstance(rf, dict):
                guidance["safeNextAction"] = rf.get("safeNextAction")
                guidance["suggestedCommand"] = rf.get("suggestedCommand")
        if isinstance(latest_escalation, dict):
            guidance["escalation"] = {
                "reason": latest_escalation.get("reason"),
                "safeNextAction": latest_escalation.get("safeNextAction"),
                "stage": latest_escalation.get("stage"),
                "timestamp": latest_escalation.get("timestamp"),
            }

seen = set()
for v in fixes:
    fix = v.get("fix", "")
    if fix in seen:
        continue
    seen.add(fix)
    guidance["fixes"].append({
        "domain": v.get("domain", ""),
        "fix": fix,
        "message": (v.get("message", "").split(" — ")[0])[:120],
    })

if guidance["retryable"]:
    guidance["action"] = (
        f"Fix the {len(fixes)} violation(s) listed in 'fixes', "
        f"then re-run: record-prompt-execution.sh --prompt-id {prompt_id} --status completed"
    )
else:
    guidance["action"] = (
        f"Review the {len(fails)} violation(s) manually. No automated fix available."
    )

print(json.dumps(guidance, indent=2))
PY
}

record_loop_gate_failure() {
    local stage_label="$1"
    local result_label="$2"
    local gate_id="$3"
    local message="$4"
    local action="${5:-rerun-owner-prompt}"
    [ -f "$LOOP_STATE_SH" ] || return 0

    local _loop_out=""
    local _loop_rc=0
    set +e
    _loop_out="$(
        bash "$LOOP_STATE_SH" record \
            --prompt-id "$PROMPT_ID" \
            --stage "$stage_label" \
            --result "$result_label" \
            --gate-id "$gate_id" \
            --message "$message" \
            --owner-prompt "$PROMPT_ID" \
            --safe-next-action "$action" 2>/dev/null
    )"
    _loop_rc=$?
    set -e
    if [ "$_loop_rc" -eq 3 ]; then
        echo "ESCALATION REQUIRED: retry budget exhausted for prompt=$PROMPT_ID stage=$stage_label." >&2
        [ -n "$_loop_out" ] && echo "$_loop_out" >&2
        return 3
    fi
    return 0
}

if [ "$STATUS" = "completed" ]; then
    if [ ! -f "$VALIDATE_SH" ]; then
        echo "❌ validate.sh not found at $VALIDATE_SH" >&2
        exit 1
    fi
    if [ ! -f "$CHECK_PROMPT_MAP" ]; then
        echo "❌ check-prompt-map.json not found at $CHECK_PROMPT_MAP — toolkit is incomplete" >&2
        exit 1
    fi

    # Auto-select the recorder mode from check-prompt-map.json. Prompt 10 keeps
    # the mandatory source/report gates; prompts with scopedChecks run only
    # their prompt-scoped deterministic phases; no-op prompts record progress.
    PROMPT_CLASS="$(CHECK_PROMPT_MAP="$CHECK_PROMPT_MAP" PROMPT_ID="$PROMPT_ID" python3 - <<'PY'
import json, os, sys
try:
    with open(os.environ["CHECK_PROMPT_MAP"], encoding="utf-8") as f:
        m = json.load(f)
except Exception:
    print("intermediate"); sys.exit(0)
pid = os.environ["PROMPT_ID"]
if pid in (m.get("noOp") or []):
    print("noop")
elif pid in (m.get("scopedChecks") or {}):
    print("scoped")
elif pid in (m.get("fullSweep") or {}):
    print("full")
else:
    print("intermediate")
PY
)"

    if [ "$PROMPT_CLASS" = "full" ]; then
        if [ "$PROMPT_ID" = "10" ]; then
            _VALIDATE_ARGS=(--mode final-source --prompt "$PROMPT_ID")
            echo "Running validate.sh --mode final-source --prompt $PROMPT_ID (source acceptance gate) from: $PROJECT_ROOT"
        else
            _VALIDATE_ARGS=(--mode final --prompt "$PROMPT_ID")
            echo "Running validate.sh --mode final --prompt $PROMPT_ID (final acceptance gate) from: $PROJECT_ROOT"
        fi

        set +e
        (cd "$PROJECT_ROOT" && bash "$VALIDATE_SH" "${_VALIDATE_ARGS[@]}")
        SCOPED_EXIT=$?
        set -e

        case "$SCOPED_EXIT" in
            0)
                : # validation passed; continue to record the entry
                ;;
            1)
                echo "" >&2
                echo "❌ Prompt $PROMPT_ID validation FAILED — executedPrompts entry NOT written." >&2
                if [ "$PROMPT_ID" = "10" ] && [ -f "$LAST_SOURCE_CHECK_FILE" ]; then
                    surface_last_check_failure "$LAST_SOURCE_CHECK_FILE"
                else
                    surface_last_check_failure "$LAST_CHECK_FILE"
                fi
                echo "" >&2
                echo "   Re-run the prompt's edit step, then re-invoke this recorder call." >&2
                echo "   Do not record completed while violations are unresolved." >&2
                if [ "$RETRY_GUIDANCE" = true ]; then
                    echo "" >&2
                    echo "--- RETRY GUIDANCE (JSON) ---" >&2
                    if [ "$PROMPT_ID" = "10" ] && [ -f "$LAST_SOURCE_CHECK_FILE" ]; then
                        emit_retry_guidance "$PROMPT_ID" "$LAST_SOURCE_CHECK_FILE"
                    else
                        emit_retry_guidance "$PROMPT_ID" "$LAST_CHECK_FILE"
                    fi
                fi
                exit 1
                ;;
            3)
                echo "" >&2
                echo "ESCALATION REQUIRED: prompt $PROMPT_ID source validation exhausted its retry budget." >&2
                if [ "$PROMPT_ID" = "10" ] && [ -f "$LAST_SOURCE_CHECK_FILE" ]; then
                    surface_last_check_failure "$LAST_SOURCE_CHECK_FILE"
                else
                    surface_last_check_failure "$LAST_CHECK_FILE"
                fi
                echo "   Stop re-running this broad gate; fix the owner prompt/domain first." >&2
                exit 3
                ;;
            2)
                echo "❌ Validator configuration/project-shape error (exit 2) for prompt $PROMPT_ID." >&2
                if [ "$PROMPT_ID" = "10" ]; then
                    echo "   Run \`bash $VALIDATE_SH --mode final-source --prompt $PROMPT_ID\` from the project root to investigate." >&2
                    if ! record_loop_gate_failure "source-gate" "environment-error" "validator-config-error" "validate.sh --mode final-source exited 2" "fix-environment"; then
                        exit 3
                    fi
                else
                    echo "   Run \`bash $VALIDATE_SH --mode final --prompt $PROMPT_ID\` from the project root to investigate." >&2
                    if ! record_loop_gate_failure "validation" "environment-error" "validator-config-error" "validate.sh --mode final exited 2" "fix-environment"; then
                        exit 3
                    fi
                fi
                exit 1
                ;;
            *)
                echo "❌ Validator exited unexpectedly ($SCOPED_EXIT) for prompt $PROMPT_ID." >&2
                if [ "$PROMPT_ID" = "10" ]; then
                    if ! record_loop_gate_failure "source-gate" "environment-error" "validator-unexpected-exit" "validate.sh --mode final-source exited $SCOPED_EXIT" "fix-environment"; then
                        exit 3
                    fi
                else
                    if ! record_loop_gate_failure "validation" "environment-error" "validator-unexpected-exit" "validate.sh --mode final exited $SCOPED_EXIT" "fix-environment"; then
                        exit 3
                    fi
                fi
                exit 1
                ;;
        esac

        if [ "$PROMPT_ID" = "10" ]; then
            # SOURCE-GATE GUARD (defense-in-depth): prompt 10 must pass source
            # validation before report-contract validation can run.
            GATE_OK="$(LAST_CHECK_FILE="$LAST_SOURCE_CHECK_FILE" python3 - <<'PY'
import json, os, sys
path = os.environ.get("LAST_CHECK_FILE", "")
try:
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print("missing"); sys.exit(0)
mode = d.get("mode")
status = d.get("status")
scope = d.get("scope")
exit_code = d.get("exitCode")
fail_count = d.get("failCount")
def to_int(value, default):
    try:
        if value is None:
            return default
        return int(value)
    except Exception:
        return default
if status == "passed" and scope == "source" and mode in ("final-source", "source") and to_int(exit_code, 1) == 0 and to_int(fail_count, 1) == 0:
    print("ok")
else:
    print("mode=%s scope=%s status=%s exitCode=%s failCount=%s" % (mode, scope, status, exit_code, fail_count))
PY
)"
            if [ "$GATE_OK" != "ok" ]; then
                echo "" >&2
                echo "❌ Source-gate guard: prompt 10 requires a passing source-validation sweep, but" >&2
                echo "   output/.last-source-check.json reports: $GATE_OK" >&2
                echo "   Re-run: bash $VALIDATE_SH --mode final-source --prompt 10 from the project root." >&2
                exit 1
            fi
            PROMPT10_SPLIT_GATE_PENDING=true
        else
            # FINAL-GATE GUARD (defense-in-depth): non-prompt-10 full prompts
            # still require a full/final sweep sidecar.
            GATE_OK="$(LAST_CHECK_FILE="$LAST_CHECK_FILE" python3 - <<'PY'
import json, os, sys
path = os.environ.get("LAST_CHECK_FILE", "")
try:
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print("missing"); sys.exit(0)
mode = d.get("mode")
status = d.get("status")
if status == "passed" and mode in ("full", "final", "fullSweep"):
    print("ok")
else:
    print("mode=%s status=%s" % (mode, status))
PY
)"
            if [ "$GATE_OK" != "ok" ]; then
                echo "" >&2
                echo "❌ Final-gate guard: prompt $PROMPT_ID requires a FULL validation sweep, but" >&2
                echo "   output/.last-check.json reports: $GATE_OK" >&2
                echo "   Re-run: bash $VALIDATE_SH --mode final --prompt $PROMPT_ID from the project root." >&2
                exit 1
            fi
        fi
    elif [ "$PROMPT_CLASS" = "scoped" ]; then
        echo "Running validate.sh --check-prompt $PROMPT_ID (prompt-scoped gate) from: $PROJECT_ROOT"
        set +e
        (cd "$PROJECT_ROOT" && bash "$VALIDATE_SH" --check-prompt "$PROMPT_ID")
        SCOPED_EXIT=$?
        set -e

        case "$SCOPED_EXIT" in
            0)
                : # validation passed; verify proof below
                ;;
            1)
                echo "" >&2
                echo "❌ Prompt $PROMPT_ID scoped validation FAILED — executedPrompts entry NOT written." >&2
                surface_last_check_failure "$LAST_CHECK_FILE"
                echo "" >&2
                echo "   Re-run prompt $PROMPT_ID's edit step, then re-invoke this recorder call." >&2
                echo "   Do not record completed while prompt-scoped violations are unresolved." >&2
                if ! record_loop_gate_failure "validation" "failed" "prompt-scoped-validation" "validate.sh --check-prompt $PROMPT_ID failed" "rerun-owner-prompt"; then
                    exit 3
                fi
                if [ "$RETRY_GUIDANCE" = true ]; then
                    echo "" >&2
                    echo "--- RETRY GUIDANCE (JSON) ---" >&2
                    emit_retry_guidance "$PROMPT_ID" "$LAST_CHECK_FILE"
                fi
                exit 1
                ;;
            3)
                echo "" >&2
                echo "ESCALATION REQUIRED: prompt $PROMPT_ID scoped validation exhausted its retry budget." >&2
                surface_last_check_failure "$LAST_CHECK_FILE"
                exit 3
                ;;
            2)
                echo "❌ Validator configuration/project-shape error (exit 2) for prompt $PROMPT_ID." >&2
                echo "   Run \`bash $VALIDATE_SH --check-prompt $PROMPT_ID\` from the project root to investigate." >&2
                if ! record_loop_gate_failure "validation" "environment-error" "validator-config-error" "validate.sh --check-prompt $PROMPT_ID exited 2" "fix-environment"; then
                    exit 3
                fi
                exit 1
                ;;
            *)
                echo "❌ Validator exited unexpectedly ($SCOPED_EXIT) for prompt $PROMPT_ID." >&2
                if ! record_loop_gate_failure "validation" "environment-error" "validator-unexpected-exit" "validate.sh --check-prompt $PROMPT_ID exited $SCOPED_EXIT" "fix-environment"; then
                    exit 3
                fi
                exit 1
                ;;
        esac

        if [ ! -f "$DIAGNOSTICS_CONTRACT_PY" ]; then
            echo "❌ diagnostics proof helper missing: $DIAGNOSTICS_CONTRACT_PY" >&2
            exit 1
        fi
        if ! SCOPED_PROOF_SUMMARY="$(python3 "$DIAGNOSTICS_CONTRACT_PY" --validate-prompt-proof "$LAST_CHECK_FILE" --platform android --prompt-id "$PROMPT_ID" --check-map "$CHECK_PROMPT_MAP" 2>/tmp/dynamics-scoped-proof.$$.err)"; then
            echo "" >&2
            echo "❌ Prompt-scoped proof guard failed for prompt $PROMPT_ID." >&2
            if [ -s "/tmp/dynamics-scoped-proof.$$.err" ]; then
                sed 's/^/   /' "/tmp/dynamics-scoped-proof.$$.err" >&2
            fi
            rm -f "/tmp/dynamics-scoped-proof.$$.err"
            exit 1
        fi
        rm -f "/tmp/dynamics-scoped-proof.$$.err"
        export SCOPED_PROOF_SUMMARY
    else
        echo "Prompt $PROMPT_ID recorded without auto-running validator phases."
        echo "  Final acceptance happens at prompt 10."
        echo "  No prompt-scoped validator is configured for this prompt."
    fi
fi

# ----- final-gate / artifact sanity checks (before mutating bootstrap.json) -----
export BOOTSTRAP_FILE ANALYSIS_FILE PLAN_STATE_FILE REPORT_FILE LAST_CHECK_FILE LAST_SOURCE_CHECK_FILE LAST_REPORT_CHECK_FILE PLAN_STATE_SCHEMA_FILE REPORT_SCHEMA_FILE PROMPT_ID STATUS CHECK_PROMPT_MAP FILES_TOUCHED

set +e
python3 - <<'PY'
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

prompt_id = os.environ["PROMPT_ID"]
status = os.environ["STATUS"]
bootstrap_path = os.environ["BOOTSTRAP_FILE"]
analysis_path = os.environ["ANALYSIS_FILE"]
plan_state_path = os.environ["PLAN_STATE_FILE"]
report_path = os.environ["REPORT_FILE"]
last_check_path = os.environ.get("LAST_CHECK_FILE", "")
plan_state_schema_path = os.environ["PLAN_STATE_SCHEMA_FILE"]
report_schema_path = os.environ["REPORT_SCHEMA_FILE"]
check_map_path = os.environ.get("CHECK_PROMPT_MAP", "")
files_touched_raw = os.environ.get("FILES_TOUCHED", "")

CLOSURE_PROMPTS = frozenset({"04", "05z", "06", "08", "09"})
# Prompts 08/09: match executionPlan rows by domain (inventory may omit promptId).
CLOSURE_PROMPT_DOMAINS = {
    "08": frozenset({"icc"}),
    "09": frozenset({"secureUiWidgets", "secureClipboard"}),
}
EVIDENCE_DOMAINS = frozenset(
    {
        "secureNetworking",
        "secureFileStorage",
        "secureSql",
        "icc",
        "secureUiWidgets",
        "secureClipboard",
        "webview",
    }
)
PROMPT_EVIDENCE_DOMAINS = {
    "04": ("secureSql",),
    "05a": ("secureFileStorage",),
    "05b": ("secureFileStorage",),
    "05c": ("secureFileStorage",),
    "05z": ("secureFileStorage",),
    "06": ("secureNetworking",),
    "07": ("webview",),
    "08": ("icc",),
    "09": ("secureUiWidgets", "secureClipboard"),
    "10": (),  # final gate checks all domains
}
ICC_PROMPT = "08"
REPORT_PROMPT = "10"
NON_WAIVABLE = frozenset({"authorization", "policyManagement", "secureClipboard", "transportHardening"})
CLOSED_UNVERIFIED_SURFACE_STATUS = frozenset({"resolved", "acceptedRisk", "notApplicable"})
# Canonical domain order for grouped error output — matches prompt execution order.
_DOMAIN_ORDER = [
    "authorization", "secureSql", "secureFileStorage", "secureNetworking",
    "icc", "secureUiWidgets", "secureClipboard",
]


def _parse_iso(v):
    if not isinstance(v, str) or not v.strip():
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00"))
    except Exception:
        return None


def _valid_deferral(bootstrap, domain):
    now = datetime.now(timezone.utc)
    for entry in bootstrap.get("deferredDomains") or []:
        if not isinstance(entry, dict):
            continue
        if entry.get("domain") != domain:
            continue
        if entry.get("developerSignedOff") is not True:
            continue
        reason = entry.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            continue
        if entry.get("classification") not in ("plannedInNextRelease", "acceptedResidualRisk"):
            continue
        exp = _parse_iso(entry.get("expiresAt"))
        if exp is None or exp <= now:
            continue
        return True
    return False


def _load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _normalized_touched_paths(raw):
    out = set()
    for item in (raw or "").split(","):
        item = _normalize_path(item.strip())
        if item:
            out.add(item)
    return out


def _prompt_completed(bootstrap, prompt_id):
    for ep in bootstrap.get("executedPrompts") or []:
        if isinstance(ep, dict) and ep.get("promptId") == prompt_id and ep.get("status") == "completed":
            return True
    return False


def _background_authorize_closed(bootstrap):
    pm = bootstrap.get("processModel") or {}
    candidates = [b for b in (pm.get("backgroundEntryPoints") or []) if isinstance(b, dict)]
    if not candidates:
        return True, None

    ba = bootstrap.get("backgroundAuthorize") or {}
    decisions = ba.get("decisions") if isinstance(ba, dict) else None
    if not isinstance(decisions, list):
        return False, "backgroundAuthorize open: bootstrap.backgroundAuthorize.decisions[] missing"

    allowed = {"migrate", "deferred", "not-applicable"}
    by_name = {}
    for d in decisions:
        if not isinstance(d, dict):
            continue
        name = d.get("name")
        intent = d.get("intent")
        if not isinstance(name, str) or not name.strip():
            continue
        if intent not in allowed:
            return False, f"backgroundAuthorize open: candidate {name!r} has invalid intent {intent!r}"
        by_name[name] = d

    missing = []
    for b in candidates:
        name = b.get("name")
        if isinstance(name, str) and name.strip() and name not in by_name:
            missing.append(name)
    if missing:
        return False, (
            "backgroundAuthorize open: missing decision(s) for "
            + ", ".join(repr(m) for m in missing[:5])
            + (" ..." if len(missing) > 5 else "")
        )
    return True, None


def _normalize_path(value):
    if not isinstance(value, str):
        return ""
    return value.replace("\\", "/").lstrip("./")


def _project_root_from_bootstrap_path(path):
    # .../<project>/dynamics-migration-tool/output/bootstrap.json -> <project>
    out_dir = os.path.dirname(path)
    tool_dir = os.path.dirname(out_dir)
    return os.path.dirname(tool_dir)


# Built at runtime from tooling/lib/ui-widget-catalog.json (replaceRows +
# inventoryKinds, minus keepNativeRows). Longest needle first so
# TextInputEditText is not classified as EditText.
_WIDGET_KIND_PATTERNS = None
_KEEP_NATIVE_SIMPLE = None


def _widget_catalog_candidates():
    paths = []
    if check_map_path:
        paths.append(
            os.path.join(os.path.dirname(os.path.abspath(check_map_path)), "lib", "ui-widget-catalog.json")
        )
    if bootstrap_path:
        tool_dir = os.path.dirname(os.path.dirname(os.path.abspath(bootstrap_path)))
        paths.append(os.path.join(tool_dir, "tooling", "lib", "ui-widget-catalog.json"))
    out = []
    seen = set()
    for path in paths:
        if path and path not in seen:
            seen.add(path)
            out.append(path)
    return out


def _load_widget_kind_index():
    global _WIDGET_KIND_PATTERNS, _KEEP_NATIVE_SIMPLE
    if _WIDGET_KIND_PATTERNS is not None:
        return
    catalog = None
    for path in _widget_catalog_candidates():
        if os.path.isfile(path):
            try:
                catalog = _load_json(path)
                break
            except Exception:
                catalog = None
    keep = set()
    kinds = []
    seen = set()

    def _add_kind(raw):
        if not isinstance(raw, str) or not raw.strip():
            return
        simple = raw.rsplit(".", 1)[-1]
        key = simple.lower()
        if not key or key in seen or key.startswith("gd"):
            return
        if key in keep:
            return
        seen.add(key)
        kinds.append(simple)

    if isinstance(catalog, dict):
        for row in catalog.get("keepNativeRows") or []:
            if not isinstance(row, dict):
                continue
            for widget in row.get("widgets") or []:
                if isinstance(widget, str) and widget.strip():
                    keep.add(widget.rsplit(".", 1)[-1].lower())
        for row in catalog.get("replaceRows") or []:
            if not isinstance(row, dict):
                continue
            for source in row.get("sourceKinds") or []:
                _add_kind(source)
        for kind in catalog.get("inventoryKinds") or []:
            _add_kind(kind)

    kinds.sort(key=lambda s: (-len(s), s.lower()))
    _WIDGET_KIND_PATTERNS = tuple((k.lower(), k) for k in kinds)
    _KEEP_NATIVE_SIMPLE = keep


def _normalize_widget_kind(value):
    if not isinstance(value, str):
        return None
    _load_widget_kind_index()
    lowered = value.lower()
    # Ignore already-migrated Dynamics widget classes for Prompt-00 inventory.
    if "com.good.gd.widget." in lowered or lowered.rsplit(".", 1)[-1].startswith("gd"):
        return None
    simple = lowered.rsplit(".", 1)[-1]
    if simple in (_KEEP_NATIVE_SIMPLE or ()):
        return None
    for needle, canonical in _WIDGET_KIND_PATTERNS or ():
        if simple == needle:
            return canonical
    for needle, canonical in _WIDGET_KIND_PATTERNS or ():
        if needle in lowered:
            return canonical
    return None


def _module_res_dirs(module_obj):
    res_dirs = []
    if not isinstance(module_obj, dict):
        return res_dirs
    for source_set in module_obj.get("sourceSets") or []:
        if not isinstance(source_set, dict):
            continue
        for res in source_set.get("resDirs") or []:
            if isinstance(res, str) and res.strip():
                res_dirs.append(res.strip())
    return res_dirs


def _domain_rows(analysis, domain):
    plan = analysis.get("executionPlan")
    if not isinstance(plan, list):
        return []
    return [row for row in plan if isinstance(row, dict) and row.get("domain") == domain]


def _collect_layout_widget_counts(module_map, project_root):
    res_dirs = []
    if isinstance(module_map, dict):
        res_dirs.extend(_module_res_dirs(module_map.get("primaryAppModule")))
        for lib in module_map.get("libraryModulesInScope") or []:
            res_dirs.extend(_module_res_dirs(lib))
    if not res_dirs:
        res_dirs.append("app/src/main/res")

    counts = Counter()
    for res_dir in sorted(set(res_dirs)):
        abs_res = res_dir if os.path.isabs(res_dir) else os.path.join(project_root, res_dir)
        if not os.path.isdir(abs_res):
            continue
        for dirpath, _, filenames in os.walk(abs_res):
            layout_bucket = os.path.basename(dirpath)
            if not layout_bucket.startswith("layout"):
                continue
            for name in filenames:
                if not name.endswith(".xml"):
                    continue
                path = os.path.join(dirpath, name)
                rel = _normalize_path(os.path.relpath(path, project_root))
                try:
                    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
                except OSError:
                    continue
                for raw in lines:
                    for tag in re.findall(r"<\s*([A-Za-z0-9_.]+)", raw):
                        if tag.startswith(("/", "!", "?")):
                            continue
                        kind = _normalize_widget_kind(tag)
                        if kind:
                            counts[(rel, kind)] += 1
    return counts


def _analysis_widget_callsite_counts(analysis):
    rows = _domain_rows(analysis, "secureUiWidgets")
    applicable = any(r.get("applicable") is True for r in rows)
    counts = Counter()
    for row in rows:
        if row.get("applicable") is not True:
            continue
        call_sites = row.get("callSites")
        if not isinstance(call_sites, list):
            continue
        for cs in call_sites:
            if not isinstance(cs, dict):
                continue
            source = cs.get("file") or cs.get("sourceFile") or cs.get("path")
            if not isinstance(source, str) or not source.strip():
                continue
            kind = (
                _normalize_widget_kind(cs.get("kind"))
                or _normalize_widget_kind(cs.get("context"))
                or _normalize_widget_kind(source)
            )
            if not kind:
                continue
            counts[(_normalize_path(source), kind)] += 1
    return applicable, counts


def _analysis_widget_inventory_closed(bootstrap_path, analysis_path):
    if not os.path.isfile(analysis_path):
        return False, "migration-analysis.json missing; run prompt 00 analysis before recording completion"

    try:
        analysis = _load_json(analysis_path)
    except Exception as exc:
        return False, f"invalid migration-analysis.json: {exc}"

    module_map_path = os.path.join(os.path.dirname(bootstrap_path), "module-map.json")
    if not os.path.isfile(module_map_path):
        return False, "module-map.json missing; re-run prompt 00pre-bootstrap.md before prompt 00"
    try:
        module_map = _load_json(module_map_path)
    except Exception as exc:
        return False, f"invalid module-map.json: {exc}"

    project_root = _project_root_from_bootstrap_path(bootstrap_path)
    _load_widget_kind_index()
    if not _WIDGET_KIND_PATTERNS:
        return (
            False,
            "ui-widget-catalog.json missing or has no replaceRows/inventoryKinds; "
            "cannot validate Prompt 00 widget inventory",
        )
    layout_counts = _collect_layout_widget_counts(module_map, project_root)
    if not layout_counts:
        return True, None

    applicable, callsite_counts = _analysis_widget_callsite_counts(analysis)
    if not applicable:
        return (
            False,
            "secureUiWidgets is marked not-applicable, but layout inventory found covered widget XML tags; "
            "set secureUiWidgets applicable and list every call site in executionPlan callSites[]",
        )

    missing = []
    for key, expected in sorted(layout_counts.items()):
        actual = callsite_counts.get(key, 0)
        if actual < expected:
            rel_file, kind = key
            missing.append(f"{rel_file} [{kind}] expected={expected} inventoried={actual}")

    if missing:
        sample = "; ".join(missing[:8])
        if len(missing) > 8:
            sample += f"; ... ({len(missing) - 8} more)"
        return (
            False,
            "Prompt-00 layout inventory gap: covered widget XML call sites were not fully captured in "
            f"migration-analysis executionPlan.secureUiWidgets.callSites[] ({sample})",
        )
    return True, None


def _run_proc_aux_scan(bootstrap_path, check_map_path):
    if not isinstance(check_map_path, str) or not check_map_path:
        return [], "check-prompt map path missing"
    tooling_dir = os.path.dirname(check_map_path)
    scan_py = os.path.join(tooling_dir, "lib", "proc-aux-gd-reach-scan.py")
    if not os.path.isfile(scan_py):
        return [], f"missing scanner: {scan_py}"
    src_root = _project_root_from_bootstrap_path(bootstrap_path)
    if not os.path.isdir(src_root):
        return [], f"project root not found: {src_root}"

    import subprocess

    proc = subprocess.run(
        [sys.executable, scan_py, bootstrap_path, src_root],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip()
        return [], stderr or f"{os.path.basename(scan_py)} exited {proc.returncode}"
    out = (proc.stdout or "").strip()
    if not out:
        return [], "empty scanner output"
    prefix, _, payload = out.partition("|")
    if prefix in ("SKIP", "OK"):
        return [], None
    if prefix not in ("FAIL", "WARN"):
        return [], f"unexpected scanner output: {out}"
    hits = [h for h in payload.split(" ") if h]
    return hits, None


def _proc_aux_report_closure(hits, report_path):
    if not os.path.isfile(report_path):
        return False, (
            "migration-report.json missing while PROC-AUX-001 findings exist; "
            "re-run prompt 10 report generation and record explicit closure"
        )
    try:
        report = _load_json(report_path)
    except Exception as exc:
        return False, f"invalid migration-report.json: {exc}"

    unverified = report.get("unverifiedSurfaces")
    if not isinstance(unverified, list):
        return False, "migration-report.json unverifiedSurfaces[] missing or invalid"

    closed_proc_aux_sources = set()
    for item in unverified:
        if not isinstance(item, dict):
            continue
        if item.get("pattern") != "PROC-AUX-001":
            continue
        if item.get("status") not in CLOSED_UNVERIFIED_SURFACE_STATUS:
            continue
        src = _normalize_path(item.get("sourceFile"))
        if src:
            closed_proc_aux_sources.add(src)

    missing = []
    for hit in hits:
        # hit shape: AuxClass->relative/path/File.kt:method
        rhs = hit.split("->", 1)[1] if "->" in hit else hit
        src = _normalize_path(rhs.rsplit(":", 1)[0])
        if not src:
            continue
        if src not in closed_proc_aux_sources:
            missing.append(src)

    if missing:
        unique_missing = sorted(set(missing))
        return False, (
            "PROC-AUX-001 findings are still open for source file(s): "
            + ", ".join(unique_missing[:8])
            + (" ..." if len(unique_missing) > 8 else "")
            + ". Add matching unverifiedSurfaces[] entries "
              "(pattern='PROC-AUX-001', securityCritical=true) with status "
              "resolved|acceptedRisk|notApplicable, then re-run prompt 10."
        )
    return True, None


def _domain_closed(domain, bootstrap, analysis, plan_state):
    if domain in NON_WAIVABLE:
        pass
    if _valid_deferral(bootstrap, domain):
        return True, None
    if domain == "authorization" and _prompt_completed(bootstrap, "03"):
        return True, None
    if domain == "backgroundAuthorize":
        # Background Authorize is an opt-in candidate workflow. It is
        # inventoried in migration-analysis.json, but its closure lives in
        # bootstrap.backgroundAuthorize.decisions[] rather than
        # migration-plan-state.json, whose schema is intentionally scoped to
        # prompts 04/05z/06 data-plane call sites.
        return _background_authorize_closed(bootstrap)
    plan = analysis.get("executionPlan") or []
    rows = [r for r in plan if isinstance(r, dict) and r.get("domain") == domain]
    if not rows:
        return True, None
    if all(r.get("applicable") is not True for r in rows):
        return True, None
    dispositions = (plan_state or {}).get("dispositions") or []
    by_key = {}
    for d in dispositions:
        if isinstance(d, dict):
            by_key[(d.get("domain"), d.get("callSiteId"))] = d
    for row in rows:
        if row.get("applicable") is not True:
            continue
        call_sites = row.get("callSites")
        if call_sites is None:
            return (
                False,
                f"domain {domain!r} open: executionPlan row missing callSites[] key",
            )
        if not isinstance(call_sites, list):
            return False, f"domain {domain!r} open: callSites must be an array"
        if domain in EVIDENCE_DOMAINS and len(call_sites) == 0:
            return (
                False,
                f"domain {domain!r} open: applicable row has empty callSites[] — "
                "re-run prompt 00 to inventory ICC/UI/clipboard call sites",
            )
        for cs in call_sites:
            if not isinstance(cs, dict):
                continue
            cid = cs.get("id")
            d = by_key.get((domain, cid))
            st = d.get("status") if d else None
            if st not in ("migrated", "removed"):
                return False, f"domain {domain!r} open: callSiteId={cid!r} status={st!r}"
    return True, None


def _collect_open_call_sites(domain, bootstrap, analysis, plan_state):
    """Return list of (callSiteId, actual_status) for every open/invalid disposition.

    Unlike _domain_closed (which short-circuits on the first failure),
    this function iterates through ALL call sites and returns every gap so
    the caller can report them all at once.
    """
    if _valid_deferral(bootstrap, domain):
        return []
    if domain == "authorization" and _prompt_completed(bootstrap, "03"):
        return []
    if domain == "backgroundAuthorize":
        ok, msg = _background_authorize_closed(bootstrap)
        if not ok:
            return [("<backgroundAuthorize-decisions>", msg)]
        return []
    plan = analysis.get("executionPlan") or []
    rows = [r for r in plan if isinstance(r, dict) and r.get("domain") == domain]
    if not rows:
        return []
    if all(r.get("applicable") is not True for r in rows):
        return []
    dispositions = (plan_state or {}).get("dispositions") or []
    by_key = {}
    for d in dispositions:
        if isinstance(d, dict):
            by_key[(d.get("domain"), d.get("callSiteId"))] = d
    failures = []
    for row in rows:
        if row.get("applicable") is not True:
            continue
        call_sites = row.get("callSites")
        if call_sites is None:
            failures.append((
                "<callSites-missing>",
                f"executionPlan row missing callSites[] key for domain={domain!r} — re-run prompt 00",
            ))
            continue
        if not isinstance(call_sites, list):
            failures.append(("<callSites-type>", f"callSites must be an array for domain={domain!r}"))
            continue
        if domain in EVIDENCE_DOMAINS and len(call_sites) == 0:
            failures.append((
                "<callSites-empty>",
                f"applicable row has empty callSites[] for domain={domain!r} — re-run prompt 00",
            ))
            continue
        for cs in call_sites:
            if not isinstance(cs, dict):
                continue
            cid = cs.get("id")
            d = by_key.get((domain, cid))
            st = d.get("status") if d else None
            if st not in ("migrated", "removed"):
                failures.append((cid, st))
    return failures


_VALID_EGRESS_OUTCOMES = frozenset({
    "REMOVE",
    "REPLACE_WITH_DYNAMICS",
    "MANUAL_INTERVENTION_REQUIRED",
    "BLOCKED_UNTIL_APPROVED",
})
_VALID_EGRESS_UI = frozenset({"removed", "disabled", "replaced", "flagged"})


def _collect_open_egress_features(owner_prompt, analysis, plan_state):
    """Return list of (featureId, reason) for missing/invalid egress decisions.

    owner_prompt:
      - None => collect all applicable features
      - "05a"/"05c"/"08"/"09"/"10" => collect only features whose ownerPrompt matches
    """
    features = analysis.get("egressFeatures")
    if features is None:
        return []
    if not isinstance(features, list):
        return [("<egressFeatures-type>", "migration-analysis.json egressFeatures must be an array")]

    decisions = (plan_state or {}).get("egressFeatureDecisions")
    if decisions is None:
        return [("<egressFeatureDecisions-missing>", "migration-plan-state.json egressFeatureDecisions[] is missing")]
    if not isinstance(decisions, list):
        return [("<egressFeatureDecisions-type>", "migration-plan-state.json egressFeatureDecisions must be an array")]

    by_id = {}
    for item in decisions:
        if isinstance(item, dict):
            fid = item.get("featureId")
            if isinstance(fid, str) and fid:
                by_id[fid] = item

    failures = []
    for feat in features:
        if not isinstance(feat, dict):
            continue
        if feat.get("applicable") is False:
            continue
        feat_owner = feat.get("ownerPrompt")
        if owner_prompt is not None:
            if owner_prompt == "10":
                # Prompt 10 is the final closure gate and must see all egress features.
                pass
            elif feat_owner != owner_prompt:
                continue
        fid = feat.get("id")
        if not isinstance(fid, str) or not fid.strip():
            failures.append(("<featureId-missing>", f"egressFeatures entry missing id (ownerPrompt={feat_owner!r})"))
            continue
        decision = by_id.get(fid)
        if decision is None:
            failures.append((fid, "missing egressFeatureDecisions[] entry"))
            continue
        outcome = decision.get("outcome")
        ui = decision.get("uiDisposition")
        reachable = decision.get("codePathReachable")
        secure_alt = decision.get("secureAlternative")
        if outcome not in _VALID_EGRESS_OUTCOMES:
            failures.append((fid, f"invalid outcome {outcome!r}"))
            continue
        if ui not in _VALID_EGRESS_UI:
            failures.append((fid, f"invalid uiDisposition {ui!r}"))
            continue
        if not isinstance(reachable, bool):
            failures.append((fid, f"codePathReachable must be boolean, got {reachable!r}"))
            continue
        if outcome in ("REMOVE", "BLOCKED_UNTIL_APPROVED") and reachable:
            failures.append((fid, f"outcome {outcome} requires codePathReachable=false"))
            continue
        if outcome == "REPLACE_WITH_DYNAMICS":
            if ui != "replaced":
                failures.append((fid, "REPLACE_WITH_DYNAMICS requires uiDisposition='replaced'"))
                continue
            if not isinstance(secure_alt, str) or not secure_alt.strip():
                failures.append((fid, "REPLACE_WITH_DYNAMICS requires non-empty secureAlternative"))
                continue
    return failures


def _evaluate_requires(prompt_id, bootstrap, analysis, plan_state, requires):
    for req in requires or []:
        if not isinstance(req, dict):
            continue
        kind = req.get("kind")
        if kind == "domainClosed":
            domain = req.get("domain")
            if not isinstance(domain, str) or not domain:
                print("❌ requires[] entry missing domain", file=sys.stderr)
                sys.exit(1)
            ok, msg = _domain_closed(domain, bootstrap, analysis, plan_state)
            if not ok:
                print(f"❌ requires[] gate failed for prompt {prompt_id}: {msg}", file=sys.stderr)
                print(
                    f"   Complete {domain} migration (or add a valid deferredDomains[] entry) before recording completed.",
                    file=sys.stderr,
                )
                print(
                    "   If prompt 10 artifacts already exist, refresh migration-report.json, "
                    "Dynamics_Migration_Readme.md, and the retrospective after remediation, "
                    "then re-run this recorder.",
                    file=sys.stderr,
                )
                sys.exit(1)
        elif kind == "allApplicableDomainsClosed":
            # Collect ALL open call sites across ALL domains before reporting
            # so the agent sees the full gap in a single error message.
            all_failures = {}  # domain -> [(callSiteId, actual_status)]
            seen_domains = set()
            for row in analysis.get("executionPlan") or []:
                if not isinstance(row, dict) or row.get("applicable") is not True:
                    continue
                dom = row.get("domain")
                if not isinstance(dom, str) or dom in seen_domains:
                    continue
                seen_domains.add(dom)
                failures = _collect_open_call_sites(dom, bootstrap, analysis, plan_state)
                if failures:
                    all_failures[dom] = failures
            egress_failures = _collect_open_egress_features("10", analysis, plan_state)
            if all_failures or egress_failures:
                total = sum(len(v) for v in all_failures.values()) + len(egress_failures)
                print(
                    f"❌ requires[] gate failed for prompt {prompt_id}: "
                    f"{total} closure item(s) not closed",
                    file=sys.stderr,
                )
                # Sort by canonical domain order for stable, predictable output.
                ordered = sorted(
                    all_failures.items(),
                    key=lambda kv: _DOMAIN_ORDER.index(kv[0]) if kv[0] in _DOMAIN_ORDER else 99,
                )
                for dom, failures in ordered:
                    print(f"   domain={dom!r}:", file=sys.stderr)
                    for cid, st in failures:
                        if isinstance(cid, str) and cid.startswith("<"):
                            print(f"     ❌ {st}", file=sys.stderr)
                        else:
                            print(
                                f"     ❌ callSiteId={cid!r} current status={st!r}",
                                file=sys.stderr,
                            )
                            print(
                                f'        add to dispositions[]: {{"callSiteId": {cid!r}, '
                                f'"domain": {dom!r}, "status": "migrated", "note": "..."}}',
                                file=sys.stderr,
                            )
                if egress_failures:
                    print("   egressFeatures:", file=sys.stderr)
                    for fid, reason in egress_failures:
                        if isinstance(fid, str) and fid.startswith("<"):
                            print(f"     ❌ {reason}", file=sys.stderr)
                        else:
                            print(
                                f"     ❌ featureId={fid!r} {reason}",
                                file=sys.stderr,
                            )
                            print(
                                f'        add to egressFeatureDecisions[]: {{"featureId": {fid!r}, '
                                f'"domain": "secureFileStorage|icc|secureClipboard", '
                                f'"outcome": "REMOVE|REPLACE_WITH_DYNAMICS|MANUAL_INTERVENTION_REQUIRED|BLOCKED_UNTIL_APPROVED", '
                                f'"uiDisposition": "removed|disabled|replaced|flagged", '
                                f'"codePathReachable": false, "note": "..."}}',
                                file=sys.stderr,
                            )
                print("", file=sys.stderr)
                print(
                    "   Do NOT create custom top-level keys (e.g. iccDispositions, "
                    "clipboardDispositions, blockedFeatures). Use dispositions[] "
                    "for call-site closure and egressFeatureDecisions[] for feature-level egress outcomes.",
                    file=sys.stderr,
                )
                print(
                    "   Resolve the state gap, refresh prompt-10 report artifacts, "
                    "and re-run record-prompt-execution.sh --prompt-id 10 --status completed.",
                    file=sys.stderr,
                )
                sys.exit(1)
        elif kind == "backgroundAuthorizeDecisionsCaptured":
            pm = bootstrap.get("processModel") or {}
            bgs = pm.get("backgroundEntryPoints") or []
            if not bgs:
                continue
            ba = bootstrap.get("backgroundAuthorize") or {}
            decisions = ba.get("decisions") or []
            by_name = {d.get("name") for d in decisions if isinstance(d, dict)}
            missing = [b.get("name") for b in bgs if isinstance(b, dict) and b.get("name") not in by_name]
            if missing:
                print(
                    f"❌ requires[] gate failed for prompt {prompt_id}: backgroundAuthorize.decisions[] missing {len(missing)} candidate(s)",
                    file=sys.stderr,
                )
                for m in missing:
                    print(f"   - {m}", file=sys.stderr)
                print(
                    "   Re-run prompt 03c (background-authorize) to capture developer intent for each candidate.",
                    file=sys.stderr,
                )
                sys.exit(1)
        elif kind == "auxProcessGdReachClosed":
            hits, scan_error = _run_proc_aux_scan(bootstrap_path, check_map_path)
            if scan_error:
                print(
                    f"❌ requires[] gate failed for prompt {prompt_id}: PROC-AUX-001 scan error: {scan_error}",
                    file=sys.stderr,
                )
                print(
                    "   Ensure tooling/lib/proc-aux-gd-reach-scan.py exists and retry.",
                    file=sys.stderr,
                )
                sys.exit(1)
            if not hits:
                continue
            ok, msg = _proc_aux_report_closure(hits, report_path)
            if not ok:
                print(
                    f"❌ requires[] gate failed for prompt {prompt_id}: {msg}",
                    file=sys.stderr,
                )
                print("   Open PROC-AUX-001 hit(s):", file=sys.stderr)
                for h in hits[:12]:
                    print(f"   - {h}", file=sys.stderr)
                if len(hits) > 12:
                    print(f"   ... ({len(hits) - 12} more)", file=sys.stderr)
                print(
                    "   Resolve in code (guard/remove) or close explicitly in report unverifiedSurfaces[].",
                    file=sys.stderr,
                )
                sys.exit(1)
        else:
            # Hybrid schema: ignore unknown kinds on day one.
            continue


def _prompt_requires(prompt_id, check_map):
    if not isinstance(check_map, dict):
        return []
    scoped = check_map.get("scopedChecks") or {}
    if prompt_id in scoped and isinstance(scoped[prompt_id], dict):
        return scoped[prompt_id].get("requires") or []
    full = check_map.get("fullSweep") or {}
    if prompt_id in full and isinstance(full[prompt_id], dict):
        return full[prompt_id].get("requires") or []
    return []


def _escape_json_pointer_token(token):
    return str(token).replace("~", "~0").replace("/", "~1")


def _pointer_from_parts(parts):
    if not parts:
        return "/"
    return "/" + "/".join(_escape_json_pointer_token(p) for p in parts)


def _minimal_validate(instance, schema, path_parts, errors):
    schema_type = schema.get("type")
    if isinstance(schema_type, list):
        type_ok = any(_is_type(instance, t) for t in schema_type)
    elif isinstance(schema_type, str):
        type_ok = _is_type(instance, schema_type)
    else:
        type_ok = True
    if not type_ok:
        errors.append((_pointer_from_parts(path_parts), f"type mismatch: expected {schema_type}"))
        return

    if "const" in schema and instance != schema["const"]:
        errors.append((_pointer_from_parts(path_parts), f"value must equal {schema['const']!r}"))
    if "enum" in schema and instance not in schema["enum"]:
        errors.append((_pointer_from_parts(path_parts), f"value must be one of {schema['enum']!r}"))
    if isinstance(instance, str) and "minLength" in schema and len(instance) < schema["minLength"]:
        errors.append((_pointer_from_parts(path_parts), f"string length must be >= {schema['minLength']}"))
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append((_pointer_from_parts(path_parts), f"array size must be >= {schema['minItems']}"))
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for idx, item in enumerate(instance):
                _minimal_validate(item, item_schema, path_parts + [idx], errors)
    if isinstance(instance, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                errors.append((_pointer_from_parts(path_parts), f"missing required property '{key}'"))
        props = schema.get("properties", {})
        if isinstance(props, dict):
            for key, subschema in props.items():
                if key in instance and isinstance(subschema, dict):
                    _minimal_validate(instance[key], subschema, path_parts + [key], errors)
        if schema.get("additionalProperties") is False and isinstance(props, dict):
            allowed = set(props.keys())
            for key in instance.keys():
                if key not in allowed:
                    errors.append((_pointer_from_parts(path_parts + [key]), "additional property not allowed"))


def _is_type(value, json_type):
    if json_type == "object":
        return isinstance(value, dict)
    if json_type == "array":
        return isinstance(value, list)
    if json_type == "string":
        return isinstance(value, str)
    if json_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if json_type == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if json_type == "boolean":
        return isinstance(value, bool)
    if json_type == "null":
        return value is None
    return True


def validate_with_schema(instance_path, schema_path, label):
    if not os.path.isfile(schema_path):
        print(f"❌ {label} schema file missing: {schema_path}", file=sys.stderr)
        print(
            "   Expected one of:\n"
            "     - <project>/dynamics-migration-tool/schemas/<schema>.json (bundled)\n"
            "     - <repo>/documentation/report-contract/<schema>.json (canonical source)",
            file=sys.stderr,
        )
        print(
            "   Remediation: re-copy `dynamics-migration-tool/` from the kit so its\n"
            "   `schemas/` directory is present alongside `tooling/`.",
            file=sys.stderr,
        )
        return False, None
    if not os.path.isfile(instance_path):
        print(f"❌ {label} file missing: {instance_path}", file=sys.stderr)
        return False, None
    try:
        with open(schema_path, "r", encoding="utf-8") as sf:
            schema = json.load(sf)
    except Exception as exc:
        print(f"❌ {label} schema is invalid JSON: {exc}", file=sys.stderr)
        return False, None
    try:
        with open(instance_path, "r", encoding="utf-8") as inf:
            instance = json.load(inf)
    except Exception as exc:
        print(f"❌ {label} file is invalid JSON: {exc}", file=sys.stderr)
        return False, None

    errors = []
    try:
        import jsonschema  # type: ignore
        validator = jsonschema.Draft202012Validator(schema)
        for err in sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path)):
            errors.append((_pointer_from_parts(list(err.absolute_path)), err.message))
    except Exception:
        _minimal_validate(instance, schema, [], errors)

    if errors:
        print(f"❌ {label} schema validation failed:", file=sys.stderr)
        has_additional_prop_error = False
        for pointer, message in errors:
            print(f"   - {pointer}: {message}", file=sys.stderr)
            if "additional property" in message.lower():
                has_additional_prop_error = True
        if has_additional_prop_error and "plan-state" in label.lower():
            print("", file=sys.stderr)
            print(
                "   migration-plan-state.json only allows: schemaVersion, runId, dispositions, egressFeatureDecisions.",
                file=sys.stderr,
            )
            print(
                "   Do NOT add custom top-level keys such as iccDispositions, "
                "clipboardDispositions, secureUiWidgetsDispositions, blockedFeatures, removedFeatures, etc.",
                file=sys.stderr,
            )
            print(
                "   All domains (secureSql, secureFileStorage, secureNetworking, icc, "
                "secureUiWidgets, secureClipboard) write to the same dispositions[] array.",
                file=sys.stderr,
            )
            print(
                "   Feature-level strip/block/replace decisions write to egressFeatureDecisions[].",
                file=sys.stderr,
            )
            print(
                "   See steering/79-migration-plan-state-and-call-site-closure.md for the "
                "correct shape.",
                file=sys.stderr,
            )
        return False, instance
    return True, instance


if status != "completed":
    sys.exit(0)

touched_paths = _normalized_touched_paths(files_touched_raw)
plan_state_touched = (
    "dynamics-migration-tool/output/migration-plan-state.json" in touched_paths
    or "output/migration-plan-state.json" in touched_paths
)

if prompt_id != REPORT_PROMPT:
    if prompt_id == "00":
        ok, msg = _analysis_widget_inventory_closed(bootstrap_path, analysis_path)
        if not ok:
            print(f"❌ Prompt 00 inventory validation failed: {msg}", file=sys.stderr)
            print(
                "   Re-run prompt 00-analyze-app.md and update migration-analysis.json so all in-scope "
                "layout covered widgets are inventoried before prompt 09.",
                file=sys.stderr,
            )
            sys.exit(1)
    if plan_state_touched:
        if not os.path.isfile(plan_state_path):
            print(
                "❌ migration-plan-state.json was listed in --files-touched but the file is missing",
                file=sys.stderr,
            )
            sys.exit(1)
        ok, _ = validate_with_schema(
            plan_state_path, plan_state_schema_path, "migration-plan-state.json"
        )
        if not ok:
            sys.exit(1)
    sys.exit(0)

check_map = {}
if check_map_path and os.path.isfile(check_map_path):
    try:
        check_map = _load_json(check_map_path)
    except Exception as exc:
        print(f"❌ could not read {check_map_path}: {exc}", file=sys.stderr)
        sys.exit(1)

requires = _prompt_requires(prompt_id, check_map)
analysis = {}
plan_state = {}
bootstrap = {}
if requires or prompt_id in (
    "04", "05a", "05b", "05c", "05z", "06", "07", "08", "09", "11", "03c", "10"
):
    try:
        bootstrap = _load_json(bootstrap_path)
    except Exception as exc:
        print(f"❌ {bootstrap_path}: {exc}", file=sys.stderr)
        sys.exit(1)
    if os.path.isfile(analysis_path):
        try:
            analysis = _load_json(analysis_path)
        except Exception as exc:
            print(f"❌ {analysis_path}: {exc}", file=sys.stderr)
            sys.exit(1)
    if os.path.isfile(plan_state_path):
        try:
            plan_state = _load_json(plan_state_path)
        except Exception as exc:
            print(f"❌ {plan_state_path}: {exc}", file=sys.stderr)
            sys.exit(1)
if requires:
    _evaluate_requires(prompt_id, bootstrap, analysis, plan_state, requires)

if prompt_id in ("04", "05a", "05b", "05c", "05z", "06", "07", "08", "09", "10"):
    evidence_path = os.path.join(os.path.dirname(bootstrap_path), ".independent-evidence.json")
    tooling_dir = os.path.dirname(check_map_path) if check_map_path else os.path.join(
        os.path.dirname(bootstrap_path), "..", "tooling"
    )
    closure_py = os.path.join(tooling_dir, "lib", "evidence-closure-check.py")
    if not os.path.isfile(analysis_path):
        print(
            f"❌ independent-evidence gate failed for prompt {prompt_id}: "
            "migration-analysis.json is required before recording completed",
            file=sys.stderr,
        )
        sys.exit(1)
    if not os.path.isfile(evidence_path):
        print(
            f"❌ independent-evidence gate failed for prompt {prompt_id}: "
            "output/.independent-evidence.json is missing — re-run validate.sh",
            file=sys.stderr,
        )
        sys.exit(1)
    if os.path.isfile(closure_py):
        import subprocess

        prompt_domains = PROMPT_EVIDENCE_DOMAINS.get(prompt_id)
        if prompt_domains is None:
            # Prompt does not own an evidence-domain closure gate.
            prompt_domains = ()
        cmd = [
            sys.executable,
            closure_py,
            "--mode",
            "recorder",
            "--evidence",
            evidence_path,
            "--analysis",
            analysis_path,
            "--plan-state",
            plan_state_path,
        ]
        if prompt_id != "10":
            for dom in prompt_domains:
                cmd.extend(["--domain", dom])
        if os.path.isfile(report_path):
            cmd.extend(["--report", report_path])
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"❌ independent-evidence gate failed for prompt {prompt_id}:", file=sys.stderr)
            if proc.stderr.strip():
                print(proc.stderr, file=sys.stderr)
            else:
                print(proc.stdout, file=sys.stderr)
            print(
                "   Prompt execution cannot close domains without independent validator evidence.",
                file=sys.stderr,
            )
            sys.exit(1)

if prompt_id == ICC_PROMPT:
    import os
    import re

    project_root = os.path.abspath(os.path.join(os.path.dirname(bootstrap_path), "..", ".."))
    src_root = os.path.join(project_root, "app", "src", "main")
    if not os.path.isdir(src_root):
        sys.exit(0)

    sendto_seen = False
    chooser_bypass_hits = []
    for dirpath, _, filenames in os.walk(src_root):
        for name in filenames:
            if not (name.endswith(".kt") or name.endswith(".java")):
                continue
            path = os.path.join(dirpath, name)
            try:
                text = open(path, "r", encoding="utf-8", errors="ignore").read()
            except Exception:
                continue
            if "GDServiceClient.sendTo" in text or "sendTo(" in text:
                sendto_seen = True
            if re.search(r"providers\s*\.\s*first\(|providers\s*\[\s*0\s*\]|providers\s*\.\s*get\s*\(\s*0\s*\)", text):
                chooser_bypass_hits.append(os.path.relpath(path, project_root))

    if sendto_seen and chooser_bypass_hits:
        print("❌ ICC closure failed for prompt 08:", file=sys.stderr)
        print("   providers.first/index chooser bypass detected in:", file=sys.stderr)
        for rel in sorted(set(chooser_bypass_hits)):
            print(f"   - {rel}", file=sys.stderr)
        print("   Replace with a user provider chooser before recording prompt 08 as completed.", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

if prompt_id == REPORT_PROMPT:
    sys.exit(0)  # M2 gate does not apply to the report prompt

if prompt_id not in CLOSURE_PROMPTS:
    sys.exit(0)

if not os.path.isfile(analysis_path):
    print(f"❌ M2 closure: {analysis_path} not found — run prompt 00 first", file=sys.stderr)
    sys.exit(1)

try:
    with open(analysis_path, "r", encoding="utf-8") as f:
        analysis = json.load(f)
except Exception as exc:
    print(f"❌ M2 closure: invalid migration-analysis.json: {exc}", file=sys.stderr)
    sys.exit(1)

plan = analysis.get("executionPlan", [])
if not isinstance(plan, list):
    print("❌ M2 closure: executionPlan must be an array", file=sys.stderr)
    sys.exit(1)

required = []
missing_call_sites_key = []
for row in plan:
    if not isinstance(row, dict):
        continue
    domain = row.get("domain")
    if prompt_id in CLOSURE_PROMPT_DOMAINS:
        if not isinstance(domain, str) or domain not in CLOSURE_PROMPT_DOMAINS[prompt_id]:
            continue
    elif row.get("promptId") != prompt_id:
        continue
    if row.get("applicable") is not True:
        continue
    if not isinstance(domain, str) or not domain:
        print(f"❌ M2 closure: executionPlan row for prompt {prompt_id} missing domain", file=sys.stderr)
        sys.exit(1)
    if "callSites" not in row:
        missing_call_sites_key.append(domain)
        continue
    cs = row.get("callSites")
    if not isinstance(cs, list):
        print(f"❌ M2 closure: callSites for domain={domain} must be an array", file=sys.stderr)
        sys.exit(1)
    for item in cs:
        if not isinstance(item, dict):
            print(f"❌ M2 closure: callSites entry must be object (domain={domain})", file=sys.stderr)
            sys.exit(1)
        cid = item.get("id")
        if not isinstance(cid, str) or not cid.strip():
            print(f"❌ M2 closure: callSites entry missing id (domain={domain})", file=sys.stderr)
            sys.exit(1)
        required.append((domain, cid.strip()))

if missing_call_sites_key:
    print(
        "❌ M2 closure: applicable executionPlan row(s) missing callSites key: "
        + ", ".join(sorted(set(missing_call_sites_key))),
        file=sys.stderr,
    )
    print(
        "   Re-run prompt 00-analyze-app.md — schemaVersion 1.2.0 requires callSites[] on each applicable 04/05z/06/08/09 row.",
        file=sys.stderr,
    )
    print(
        "   If prompt 10 artifacts already exist, refresh them after remediation and re-run the recorder.",
        file=sys.stderr,
    )
    sys.exit(1)

analysis_egress_features = analysis.get("egressFeatures")
prompt_has_egress_features = False
if isinstance(analysis_egress_features, list):
    for feat in analysis_egress_features:
        if not isinstance(feat, dict):
            continue
        if feat.get("applicable") is False:
            continue
        if feat.get("ownerPrompt") == prompt_id:
            prompt_has_egress_features = True
            break

if not required and not prompt_has_egress_features:
    sys.exit(0)

if not os.path.isfile(plan_state_path):
    print(
        f"❌ M2 closure: {plan_state_path} not found but {len(required)} call site(s) and/or prompt-owned egress features require recording",
        file=sys.stderr,
    )
    print(
        "   Prompts 04/05a/05c/05z/06/08/09 must full-file-write migration-plan-state.json with dispositions[] and egressFeatureDecisions[] before recording completed.",
        file=sys.stderr,
    )
    print(
        "   If prompt 10 artifacts already exist, refresh them after remediation and re-run the recorder.",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    with open(plan_state_path, "r", encoding="utf-8") as f:
        plan_state = json.load(f)
except Exception as exc:
    print(f"❌ M2 closure: invalid migration-plan-state.json: {exc}", file=sys.stderr)
    sys.exit(1)

ok, _ = validate_with_schema(plan_state_path, plan_state_schema_path, "migration-plan-state.json")
if not ok:
    sys.exit(1)

dispositions = plan_state.get("dispositions", [])
if not isinstance(dispositions, list):
    print("❌ M2 closure: dispositions must be an array", file=sys.stderr)
    sys.exit(1)

by_key = {}
for d in dispositions:
    if not isinstance(d, dict):
        continue
    cid = d.get("callSiteId")
    dom = d.get("domain")
    if isinstance(cid, str) and isinstance(dom, str):
        by_key[(dom, cid)] = d

# Allowed closure statuses. The toolkit does not support line-level
# exceptions; defense-in-depth check for the most likely unsupported
# shape ("waived" / waiverId) is below.
allowed_status = frozenset({"migrated", "removed"})
errors = []
# Track missing IDs separately so we can emit JSON skeletons grouped by domain.
missing_by_domain = {}  # domain -> [cid, ...]
for domain, cid in required:
    d = by_key.get((domain, cid))
    if d is None:
        errors.append(f"missing disposition for callSiteId={cid!r} domain={domain!r}")
        missing_by_domain.setdefault(domain, []).append(cid)
        continue
    st = d.get("status")
    if st == "waived" or "waiverId" in d:
        errors.append(
            f"unsupported disposition shape for callSiteId={cid!r} domain={domain!r}: "
            f"this toolkit does not support line-level exceptions. Migrate the call "
            f"site to a Dynamics API or have the developer defer the entire "
            f"{domain!r} domain in bootstrap.json deferredDomains[]."
        )
        continue
    if st not in allowed_status:
        errors.append(
            f"invalid status for callSiteId={cid!r} domain={domain!r}: {st!r} (want migrated|removed)"
        )
        continue

if errors:
    print("❌ M2 closure failed:", file=sys.stderr)
    for e in errors:
        print(f"   - {e}", file=sys.stderr)
    if missing_by_domain:
        print("", file=sys.stderr)
        print("   Expected dispositions[] entries (add to migration-plan-state.json):", file=sys.stderr)
        ordered_domains = sorted(
            missing_by_domain.items(),
            key=lambda kv: _DOMAIN_ORDER.index(kv[0]) if kv[0] in _DOMAIN_ORDER else 99,
        )
        for dom, cids in ordered_domains:
            print(f"   domain={dom!r}:", file=sys.stderr)
            for missing_cid in cids:
                print(
                    f'     {{"callSiteId": "{missing_cid}", "domain": "{dom}", '
                    f'"status": "migrated", "note": "replace with actual status"}}',
                    file=sys.stderr,
                )
        print("", file=sys.stderr)
        print(
            "   Do NOT create custom top-level keys (e.g. iccDispositions, "
            "clipboardDispositions).",
            file=sys.stderr,
        )
        print(
            "   Use dispositions[] — it is the canonical array for all closure-gated "
            "domains (secureSql, secureFileStorage, secureNetworking, icc, "
            "secureUiWidgets, secureClipboard).",
            file=sys.stderr,
        )
    print("", file=sys.stderr)
    print(
        "   Refresh migration-plan-state.json, then refresh prompt-10 report artifacts if they already exist, "
        "and re-run record-prompt-execution.sh.",
        file=sys.stderr,
    )
    sys.exit(1)

# --- Feature-level egress closure for prompts that own strip/block/replace work ---
egress_failures = _collect_open_egress_features(prompt_id, analysis, plan_state)
if egress_failures:
    print("❌ Egress feature closure failed:", file=sys.stderr)
    for fid, reason in egress_failures:
        if isinstance(fid, str) and fid.startswith("<"):
            print(f"   - {reason}", file=sys.stderr)
        else:
            print(f"   - featureId={fid!r}: {reason}", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "   Add matching entries to egressFeatureDecisions[] in migration-plan-state.json.",
        file=sys.stderr,
    )
    print(
        "   Use egressFeatureDecisions[] for feature-level remove/block/replace/manual outcomes; "
        "do not invent parallel top-level keys such as blockedFeatures or removedFeatures.",
        file=sys.stderr,
    )
    print(
        "   Refresh migration-plan-state.json, then refresh prompt-10 report artifacts if they already exist, "
        "and re-run record-prompt-execution.sh.",
        file=sys.stderr,
    )
    sys.exit(1)

# --- Caller-liveness check for "removed" dispositions ---
# When a call site is marked "removed", verify that the method/class
# containing the original call site is actually dead (deleted or has no
# callers). A "removed" disposition on a method that still has active
# UI callers is a silent functional regression, not a valid removal.
#
# Heuristic: extract the method/function name from the callSiteId (the
# segment after the last hyphen-delimited file stem, e.g.
# "icc-open-viewer-openUri-186" -> "openUri") or from the call site
# context in migration-analysis.json. Then grep the source tree for
# callers of that method. If callers exist, warn (not hard-fail) so the
# agent investigates. This is best-effort; complex call graphs may
# produce false positives, which is why it is a warning.
removed_dispositions = []
for domain, cid in required:
    d = by_key.get((domain, cid))
    if d is not None and d.get("status") == "removed":
        cs_info = None
        for row in plan:
            if not isinstance(row, dict) or row.get("applicable") is not True:
                continue
            for cs in row.get("callSites") or []:
                if isinstance(cs, dict) and cs.get("id") == cid:
                    cs_info = cs
                    break
            if cs_info:
                break
        removed_dispositions.append((domain, cid, d, cs_info))

if removed_dispositions:
    project_root = os.path.abspath(
        os.path.join(os.path.dirname(bootstrap_path), "..", "..")
    )
    src_root = os.path.join(project_root, "app", "src", "main")
    if not os.path.isdir(src_root):
        for candidate in ("app/src/main/java", "app/src/main/kotlin"):
            test = os.path.join(project_root, candidate)
            if os.path.isdir(test):
                src_root = os.path.join(project_root, "app", "src", "main")
                break

    if os.path.isdir(src_root):
        liveness_warnings = []
        for domain, cid, disp, cs_info in removed_dispositions:
            method_name = None
            source_file = None
            if cs_info:
                context = cs_info.get("context", "")
                source_file = cs_info.get("file", "")
                kind = cs_info.get("kind", "")
                # Try to extract method name from the context or id
                # Common id formats: "icc-share-openUri-186", "icc-intent-view-1"
                # Context might be: "ACTION_VIEW intent in openUri()"
                import re as _re
                ctx_match = _re.search(r'\b([a-z][A-Za-z0-9_]+)\s*\(', context)
                if ctx_match:
                    method_name = ctx_match.group(1)
            if not method_name:
                parts = cid.rsplit("-", 2)
                if len(parts) >= 2:
                    candidate = parts[-2] if parts[-1].isdigit() else parts[-1]
                    if candidate and candidate[0].islower() and len(candidate) > 2:
                        method_name = candidate

            if not method_name:
                continue

            caller_count = 0
            caller_locations = []
            for dirpath, _, filenames in os.walk(src_root):
                for name in filenames:
                    if not (name.endswith(".kt") or name.endswith(".java")):
                        continue
                    fpath = os.path.join(dirpath, name)
                    rel = os.path.relpath(fpath, project_root)
                    if source_file and rel == source_file:
                        continue
                    try:
                        text = open(fpath, "r", encoding="utf-8", errors="ignore").read()
                    except Exception:
                        continue
                    pat = _re.compile(
                        r'(?:^|[^A-Za-z0-9_])' + _re.escape(method_name) + r'\s*\(',
                        _re.MULTILINE,
                    )
                    for lineno, line in enumerate(text.splitlines(), 1):
                        stripped = line.lstrip()
                        if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
                            continue
                        if stripped.startswith("fun ") or stripped.startswith("private ") or stripped.startswith("internal "):
                            if method_name + "(" in stripped:
                                continue
                        if pat.search(line):
                            caller_count += 1
                            if len(caller_locations) < 5:
                                caller_locations.append(f"{rel}:{lineno}")

            if caller_count > 0:
                liveness_warnings.append(
                    f"callSiteId={cid!r} domain={domain!r}: disposition is 'removed' "
                    f"but method {method_name}() still has {caller_count} caller(s):\n"
                    + "\n".join(f"       - {loc}" for loc in caller_locations)
                    + f"\n     Use 'migrated' and replace with ICC/secure-API, or remove the callers."
                )

        if liveness_warnings:
            print("", file=sys.stderr)
            print(
                f"⚠️  Caller-liveness check: {len(liveness_warnings)} 'removed' disposition(s) "
                "have active callers (potential silent regression):",
                file=sys.stderr,
            )
            for w in liveness_warnings:
                print(f"   ⚠️  {w}", file=sys.stderr)
            print("", file=sys.stderr)
            print(
                "   A 'removed' disposition means the feature was intentionally eliminated.",
                file=sys.stderr,
            )
            print(
                "   If UI elements still call the method, the feature is NOT removed — it is broken.",
                file=sys.stderr,
            )
            print(
                "   Either migrate the method to ICC/secure-API (status='migrated') or",
                file=sys.stderr,
            )
            print(
                "   remove/disable the calling UI elements before recording completed.",
                file=sys.stderr,
            )
            sys.exit(1)

sys.exit(0)
PY
_CLOSURE_GATE_EXIT=$?
set -e

if [ "$_CLOSURE_GATE_EXIT" -ne 0 ]; then
    if ! record_loop_gate_failure "closure-gate" "failed" "requires-or-closure" "recorder closure gate failed for prompt $PROMPT_ID" "rerun-owner-prompt"; then
        exit 3
    fi
    exit 1
fi

if [ "$PROMPT10_SPLIT_GATE_PENDING" = true ]; then
    if [ ! -f "$REPORT_FILE" ]; then
        echo "❌ Prompt 10 report gate requires output/migration-report.json before recording completed." >&2
        echo "   Re-run prompt 10's report write step, then re-invoke this recorder call." >&2
        exit 1
    fi
    if [ ! -f "$MODULE_MAP_FILE" ]; then
        echo "❌ Prompt 10 report gate requires output/module-map.json before recording completed." >&2
        echo "   Re-run prompt 00pre so module ownership can be validated deterministically." >&2
        exit 1
    fi
    if [ ! -f "$PREP_REPORT_ARTIFACTS_PY" ]; then
        echo "❌ report artifact prep helper not found at $PREP_REPORT_ARTIFACTS_PY" >&2
        exit 1
    fi
    if [ ! -f "$LAST_SOURCE_CHECK_FILE" ]; then
        echo "❌ Prompt 10 report gate requires output/.last-source-check.json before artifact normalization." >&2
        echo "   Re-run: bash $VALIDATE_SH --mode final-source --prompt 10 from the project root." >&2
        exit 1
    fi
    echo "Normalizing prompt-10 report artifacts (module ownership, validation snapshot, README headings)..."
    if ! python3 "$PREP_REPORT_ARTIFACTS_PY" \
        --project-root "$PROJECT_ROOT" \
        --report "$REPORT_FILE" \
        --module-map "$MODULE_MAP_FILE" \
        --source-check "$LAST_SOURCE_CHECK_FILE" \
        --readme "$PROJECT_ROOT/Dynamics_Migration_Readme.md"; then
        echo "❌ Prompt 10 artifact normalization failed — report-contract gate not attempted." >&2
        echo "   Fix the report ownership/shape issues surfaced above, then re-run this recorder call." >&2
        exit 1
    fi

    echo "Running validate.sh --mode report --prompt 10 (report contract gate) from: $PROJECT_ROOT"
    set +e
    (cd "$PROJECT_ROOT" && bash "$VALIDATE_SH" --mode report --prompt 10)
    REPORT_GATE_EXIT=$?
    set -e

    case "$REPORT_GATE_EXIT" in
        0)
            :
            ;;
        1)
            echo "" >&2
            echo "❌ Prompt 10 report-contract validation FAILED — executedPrompts entry NOT written." >&2
            if [ -f "$LAST_REPORT_CHECK_FILE" ]; then
                surface_last_check_failure "$LAST_REPORT_CHECK_FILE"
            else
                surface_last_check_failure "$LAST_CHECK_FILE"
            fi
            echo "" >&2
            echo "   Refresh migration-report.json and Dynamics_Migration_Readme.md, then re-run this recorder call." >&2
            exit 1
            ;;
        3)
            echo "" >&2
            echo "ESCALATION REQUIRED: prompt 10 report validation exhausted its retry budget." >&2
            if [ -f "$LAST_REPORT_CHECK_FILE" ]; then
                surface_last_check_failure "$LAST_REPORT_CHECK_FILE"
            fi
            echo "   Stop re-running report gate without owner-prompt fixes." >&2
            exit 3
            ;;
        2)
            echo "❌ Validator configuration/project-shape error (exit 2) during prompt-10 report gate." >&2
            echo "   Run \`bash $VALIDATE_SH --mode report --prompt 10\` from the project root to investigate." >&2
            if ! record_loop_gate_failure "report-gate" "environment-error" "validator-config-error" "validate.sh --mode report exited 2" "fix-environment"; then
                exit 3
            fi
            exit 1
            ;;
        *)
            echo "❌ Validator exited unexpectedly ($REPORT_GATE_EXIT) during prompt-10 report gate." >&2
            if ! record_loop_gate_failure "report-gate" "environment-error" "validator-unexpected-exit" "validate.sh --mode report exited $REPORT_GATE_EXIT" "fix-environment"; then
                exit 3
            fi
            exit 1
            ;;
    esac

    REPORT_GATE_OK="$(LAST_CHECK_FILE="$LAST_REPORT_CHECK_FILE" python3 - <<'PY'
import json, os, sys
path = os.environ.get("LAST_CHECK_FILE", "")
try:
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print("missing"); sys.exit(0)
mode = d.get("mode")
scope = d.get("scope")
status = d.get("status")
exit_code = d.get("exitCode")
fail_count = d.get("failCount")
def to_int(value, default):
    try:
        if value is None:
            return default
        return int(value)
    except Exception:
        return default
if status == "passed" and scope == "report" and mode == "report" and to_int(exit_code, 1) == 0 and to_int(fail_count, 1) == 0:
    print("ok")
else:
    print("mode=%s scope=%s status=%s exitCode=%s failCount=%s" % (mode, scope, status, exit_code, fail_count))
PY
)"
    if [ "$REPORT_GATE_OK" != "ok" ]; then
        echo "❌ Prompt 10 report gate sidecar validation failed: $REPORT_GATE_OK" >&2
        STALE_PROMPT10_STATE="$(BOOTSTRAP_FILE="$BOOTSTRAP_FILE" REPORT_FILE="$REPORT_FILE" python3 - <<'PY'
import json
import os
import sys

boot_path = os.environ.get("BOOTSTRAP_FILE", "")
report_path = os.environ.get("REPORT_FILE", "")
try:
    with open(boot_path, encoding="utf-8") as f:
        boot = json.load(f)
    with open(report_path, encoding="utf-8") as f:
        report = json.load(f)
except Exception:
    print("unknown")
    sys.exit(0)

def pairs(rows):
    out = set()
    if not isinstance(rows, list):
        return out
    for item in rows:
        if not isinstance(item, dict):
            continue
        pid = item.get("promptId")
        status = item.get("status")
        if isinstance(pid, str) and isinstance(status, str):
            out.add((pid, status))
    return out

boot_pairs = pairs(boot.get("executedPrompts"))
prov = report.get("provenance")
report_pairs = pairs(prov.get("executedPrompts") if isinstance(prov, dict) else [])

if ("10", "completed") in boot_pairs and ("10", "completed") not in report_pairs:
    print("stale")
else:
    print("ok")
PY
)"
        if [ "$STALE_PROMPT10_STATE" = "stale" ]; then
            echo "   Detected stale prompt-10 state: bootstrap.json already records prompt 10," >&2
            echo "   but migration-report provenance does not. This usually comes from an" >&2
            echo "   interrupted post-record sync in an earlier run." >&2
            echo "   Recovery: python3 \"$SYNC_REPORT_PROVENANCE_PY\" sync --bootstrap \"$BOOTSTRAP_FILE\" --report \"$REPORT_FILE\" --source-check \"$LAST_SOURCE_CHECK_FILE\" --report-check \"$LAST_REPORT_CHECK_FILE\" --check" >&2
            echo "   Then re-run: bash $VALIDATE_SH --mode report --prompt 10" >&2
        fi
        echo "   Re-run: bash $VALIDATE_SH --mode report --prompt 10 from the project root." >&2
        exit 1
    fi
fi

# Prompt-10 post-record actions (bootstrap merge + provenance sync) are
# transactional so partial failures do not leave bootstrap/report out of sync.
PROMPT10_TX_ACTIVE=false
PROMPT10_BOOTSTRAP_SNAPSHOT=""
PROMPT10_REPORT_SNAPSHOT=""

prompt10_tx_cleanup() {
    [ -n "$PROMPT10_BOOTSTRAP_SNAPSHOT" ] && rm -f "$PROMPT10_BOOTSTRAP_SNAPSHOT" || true
    [ -n "$PROMPT10_REPORT_SNAPSHOT" ] && rm -f "$PROMPT10_REPORT_SNAPSHOT" || true
    PROMPT10_BOOTSTRAP_SNAPSHOT=""
    PROMPT10_REPORT_SNAPSHOT=""
}

prompt10_tx_restore() {
    if [ -n "$PROMPT10_BOOTSTRAP_SNAPSHOT" ] && [ -f "$PROMPT10_BOOTSTRAP_SNAPSHOT" ]; then
        cp "$PROMPT10_BOOTSTRAP_SNAPSHOT" "$BOOTSTRAP_FILE"
    fi
    if [ -n "$PROMPT10_REPORT_SNAPSHOT" ] && [ -f "$PROMPT10_REPORT_SNAPSHOT" ] && [ -f "$REPORT_FILE" ]; then
        cp "$PROMPT10_REPORT_SNAPSHOT" "$REPORT_FILE"
    fi
    echo "WARNING: Prompt 10 post-record step failed; restored bootstrap/report to pre-record state." >&2
    echo "   Retry the prompt 10 recorder call after fixing the reported error." >&2
    echo "   A full migration rerun is not required." >&2
    PROMPT10_TX_ACTIVE=false
    prompt10_tx_cleanup
}

prompt10_tx_commit() {
    PROMPT10_TX_ACTIVE=false
    trap - EXIT
    prompt10_tx_cleanup
}

if [ "$STATUS" = "completed" ] && [ "$PROMPT_ID" = "10" ] && [ -f "$REPORT_FILE" ]; then
    PROMPT10_BOOTSTRAP_SNAPSHOT="$(mktemp)"
    PROMPT10_REPORT_SNAPSHOT="$(mktemp)"
    cp "$BOOTSTRAP_FILE" "$PROMPT10_BOOTSTRAP_SNAPSHOT"
    cp "$REPORT_FILE" "$PROMPT10_REPORT_SNAPSHOT"
    PROMPT10_TX_ACTIVE=true
    trap 'if [ "$PROMPT10_TX_ACTIVE" = true ]; then prompt10_tx_restore; fi' EXIT
fi

# ----- merge into bootstrap.json -----
export BOOTSTRAP_FILE PROMPT_ID STATUS FILES_TOUCHED STARTED_AT NOTE SCOPED_PROOF_SUMMARY

python3 - <<'PY'
import datetime
import json
import os
import sys

path = os.environ["BOOTSTRAP_FILE"]
prompt_id = os.environ["PROMPT_ID"]
status = os.environ["STATUS"]
files_touched_raw = os.environ.get("FILES_TOUCHED", "")
started_at_arg = os.environ.get("STARTED_AT", "")
note = os.environ.get("NOTE", "")
proof_summary_raw = os.environ.get("SCOPED_PROOF_SUMMARY", "")

now = (
    datetime.datetime.now(datetime.timezone.utc)
    .replace(microsecond=0)
    .isoformat()
    .replace("+00:00", "Z")
)

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(f"❌ {path} is not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print(f"❌ {path} root is not a JSON object", file=sys.stderr)
    sys.exit(1)

executed = data.get("executedPrompts")
if not isinstance(executed, list):
    print(f"❌ {path} missing 'executedPrompts' array (schema v1.0.0 violation)", file=sys.stderr)
    sys.exit(1)

files_touched = [p.strip() for p in files_touched_raw.split(",") if p.strip()] if files_touched_raw else []

started_at = started_at_arg if started_at_arg else now

entry = {
    "completedAt": now,
    "filesTouched": files_touched,
    "promptId": prompt_id,
    "startedAt": started_at,
    "status": status,
}
if note:
    entry["note"] = note
if proof_summary_raw:
    try:
        proof_summary = json.loads(proof_summary_raw)
    except Exception:
        proof_summary = None
    if isinstance(proof_summary, dict):
        entry["validationProof"] = proof_summary

# Idempotency: replace any existing entry with the same promptId.
existing_idx = next(
    (i for i, e in enumerate(executed) if isinstance(e, dict) and e.get("promptId") == prompt_id),
    None,
)
if existing_idx is not None:
    executed[existing_idx] = entry
    action = "updated"
else:
    executed.append(entry)
    action = "appended"

# Keep ordering stable: sort by promptId using the canonical run order.
ORDER = ["00pre", "00", "00b", "01", "02", "03", "03b", "04", "05a", "05b", "05c", "05z", "06", "07", "08", "09", "11", "03c", "10", "12"]


def order_key(e):
    pid = e.get("promptId", "") if isinstance(e, dict) else ""
    return ORDER.index(pid) if pid in ORDER else len(ORDER)


executed.sort(key=order_key)
data["executedPrompts"] = executed

# Full-file overwrite preserves alphabetical key ordering and stable formatting.
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"✅ Recorded prompt {prompt_id} as {status} ({action} executedPrompts entry)")
PY
if [ -n "$NOTE" ]; then
    _OBS_NOTE_PRESENT=true
else
    _OBS_NOTE_PRESENT=false
fi
observability_event \
    --operation-type prompt-record \
    --prompt-id "$PROMPT_ID" \
    --status "$STATUS" \
    --metadata-json "{\"notePresent\":$_OBS_NOTE_PRESENT}"
unset _OBS_NOTE_PRESENT

if [ "$STATUS" = "completed" ] && [ -f "$CHANGED_FILES_SH" ]; then
    # Prompt-boundary checkpoint for optional maintainer incremental-validation
    # debugging. Best effort only; prompt completion does not depend on it.
    (cd "$PROJECT_ROOT" && bash "$CHANGED_FILES_SH" checkpoint-write) >/dev/null 2>&1 || true
fi

# ----- sync migration-report.json provenance from bootstrap (prompt 10 only) -----
if [ "$STATUS" = "completed" ] && [ "$PROMPT_ID" = "10" ] && [ -f "$REPORT_FILE" ]; then
    if [ ! -f "$SYNC_REPORT_PROVENANCE_PY" ]; then
        echo "❌ sync-report-provenance.py not found at $SYNC_REPORT_PROVENANCE_PY" >&2
        exit 1
    fi
    if [ ! -f "$LAST_SOURCE_CHECK_FILE" ]; then
        echo "❌ output/.last-source-check.json missing after prompt-10 source gate" >&2
        echo "   Re-run: bash $VALIDATE_SH --mode final-source --prompt 10" >&2
        exit 1
    fi
    if [ ! -f "$LAST_REPORT_CHECK_FILE" ]; then
        echo "❌ output/.last-report-check.json missing after prompt-10 report gate" >&2
        echo "   Re-run: bash $VALIDATE_SH --mode report --prompt 10" >&2
        exit 1
    fi

    SYNC_ARGS=(
        sync
        --bootstrap "$BOOTSTRAP_FILE"
        --report "$REPORT_FILE"
        --source-check "$LAST_SOURCE_CHECK_FILE"
        --report-check "$LAST_REPORT_CHECK_FILE"
        --check
    )
    if ! python3 "$SYNC_REPORT_PROVENANCE_PY" "${SYNC_ARGS[@]}"; then
        echo "❌ Report provenance sync failed — migration-report.json was not left validation-clean." >&2
        exit 1
    fi

    export REPORT_FILE REPORT_SCHEMA_FILE LAST_SOURCE_CHECK_FILE LAST_REPORT_CHECK_FILE
    python3 - <<'PY'
import json
import os
import sys

report_path = os.environ["REPORT_FILE"]
schema_path = os.environ["REPORT_SCHEMA_FILE"]
source_check_path = os.environ.get("LAST_SOURCE_CHECK_FILE", "")
report_check_path = os.environ.get("LAST_REPORT_CHECK_FILE", "")

try:
    with open(source_check_path, encoding="utf-8") as f:
        source_check = json.load(f)
except Exception as exc:
    print(f"❌ output/.last-source-check.json invalid: {exc}", file=sys.stderr)
    sys.exit(1)

try:
    with open(report_check_path, encoding="utf-8") as f:
        report_check = json.load(f)
except Exception as exc:
    print(f"❌ output/.last-report-check.json invalid: {exc}", file=sys.stderr)
    sys.exit(1)

if (
    source_check.get("status") != "passed"
    or int(source_check.get("exitCode", 1)) != 0
    or source_check.get("scope") != "source"
):
    print(
        "❌ prompt-10 source gate did not pass; report was not refreshed",
        file=sys.stderr,
    )
    sys.exit(1)

if (
    report_check.get("status") != "passed"
    or int(report_check.get("exitCode", 1)) != 0
    or report_check.get("scope") != "report"
):
    print(
        "❌ prompt-10 report gate did not pass; report was not refreshed",
        file=sys.stderr,
    )
    sys.exit(1)

if not os.path.isfile(schema_path):
    print(f"❌ migration-report schema missing: {schema_path}", file=sys.stderr)
    sys.exit(1)

try:
    with open(report_path, encoding="utf-8") as f:
        report = json.load(f)
    with open(schema_path, encoding="utf-8") as sf:
        schema = json.load(sf)
except Exception as exc:
    print(f"❌ could not load report/schema: {exc}", file=sys.stderr)
    sys.exit(1)

errors = []
try:
    import jsonschema  # type: ignore

    validator = jsonschema.Draft202012Validator(schema)
    for err in sorted(validator.iter_errors(report), key=lambda e: list(e.absolute_path)):
        path = "/" + "/".join(str(p) for p in err.absolute_path)
        errors.append(f"{path}: {err.message}")
except Exception:
    pass

if errors:
    print("❌ migration-report.json schema validation failed after provenance sync:", file=sys.stderr)
    for line in errors:
        print(f"   - {line}", file=sys.stderr)
    sys.exit(1)

val = report.get("validation")
if isinstance(val, dict):
    rp = val.get("passed")
    rf = val.get("failures")
    rw = val.get("warnings")
    rm = val.get("mode")
    lc_status = source_check.get("status")
    lc_fc = source_check.get("failCount")
    lc_wc = source_check.get("warnCount")
    lc_mode = source_check.get("mode")
    val_errors = []
    if lc_status == "passed" and rp is False:
        val_errors.append(
            "validation.passed is false but .last-source-check.json status is "
            "'passed' — stale placeholder was not refreshed by the recorder"
        )
    if lc_status == "passed" and isinstance(rf, int) and rf > 0:
        val_errors.append(
            "validation.failures is %d but .last-source-check.json status is "
            "'passed' — stale placeholder was not refreshed" % rf
        )
    if rp is True and isinstance(rf, int) and rf > 0:
        val_errors.append(
            "validation.passed is true but validation.failures is %d "
            "— mutually inconsistent" % rf
        )
    if rp is False and isinstance(rf, int) and rf == 0:
        val_errors.append(
            "validation.passed is false but validation.failures is 0 "
            "— mutually inconsistent"
        )
    if isinstance(lc_fc, int) and isinstance(rf, int) and rf != lc_fc:
        val_errors.append(
            "validation.failures is %d but .last-source-check.json failCount "
            "is %d — values must match after source validation"
            % (rf, lc_fc)
        )
    if isinstance(lc_wc, int) and isinstance(rw, int) and rw != lc_wc:
        val_errors.append(
            "validation.warnings is %d but .last-source-check.json warnCount "
            "is %d — values must match after source validation"
            % (rw, lc_wc)
        )
    if lc_mode not in ("source", "final-source"):
        val_errors.append(
            ".last-source-check.json mode must be source|final-source"
        )
    if rm not in ("source", "final-source"):
        val_errors.append(
            "validation.mode must represent source validation "
            "(expected source|final-source)"
        )
    if val_errors:
        print(
            "❌ Validation consistency check failed "
            "(report validation block vs .last-source-check.json):",
            file=sys.stderr,
        )
        for ve in val_errors:
            print("   - " + ve, file=sys.stderr)
        sys.exit(1)
PY
fi

if [ "$PROMPT10_TX_ACTIVE" = true ]; then
    prompt10_tx_commit
fi

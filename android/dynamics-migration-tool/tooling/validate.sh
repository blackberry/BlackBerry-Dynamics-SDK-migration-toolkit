#!/bin/bash

# BlackBerry Dynamics Migration — Validation Script
#
# Verifies migration-tool changes and report contract correctness.
# When output/bootstrap.json exists, Phase 0 validates its contract (schema,
# UEM block, workingTree, deprecated-field guard) before domain phases run.
# This is a migration self-check, not a full app QA/UAT suite.
#
# Usage:
#   ./dynamics-migration-tool/tooling/validate.sh [OPTIONS] [project-directory]
#
# Options:
#   --preflight              Run pre-flight checks only (verify project can build
#                            before migration starts).
#   --check-prompt <id>      Run only the validator phases owned by the given
#                            prompt id (e.g. 01, 04, 05z, 06, 10). The mapping
#                            is read from `tooling/check-prompt-map.json`. This
#                            is an optional diagnostic mode; the recorder no
#                            longer auto-runs it for intermediate prompts.
#                            Writes `output/.last-check.json` (see
#                            documentation/report-contract/last-check-schema-v1.0.0.md).
#   --mode <m>               m ∈ {incremental, full, final, final-source, report}
#                            final-source runs every final-source phase except
#                            report and writes output/.last-source-check.json.
#                            report runs only the report contract phase and
#                            writes output/.last-report-check.json.
#   --version                Print the toolkit version and exit.
#
# Without --preflight, --check-prompt, or --mode, the full validator runs end-to-end
# (prompt 10 uses split gates through the recorder: final-source then report).
#
# If no directory is specified, validates the current project (grandparent of
# this script).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/toolkit-version.sh
. "$SCRIPT_DIR/lib/toolkit-version.sh"
toolkit_version_load "$TOOL_DIR"
PREFLIGHT=false
CHECK_PROMPT_ID=""
CHECK_PROMPT_MODE=false
CHECK_PROMPT_MAP="$TOOL_DIR/tooling/check-prompt-map.json"
PHASES_ONLY_RAW=""
PHASES_ONLY_MODE=false
APP_MODULE_OVERRIDE=""

# Incremental-validation affordances (agent/maintainer debugging only; the
# third-party developer never sets these — record-prompt-execution.sh selects
# the mode automatically). See validationRegistry in check-prompt-map.json.
VALIDATION_MODE=""              # incremental | full | final | final-source | report
SINCE_BASELINE="last-prompt"    # start | last-checkpoint | last-prompt
FORCE_DOMAINS=""                # --domains a,b,c (force these domains' phases)
CHANGED_FILE=""                 # explicit changed-file list (recorder supplies)
INCR_PROMPT_ID=""               # --prompt <id>: union owned phases + sidecar id
EXPLAIN_PLAN=false              # --explain-plan: print plan and exit (no run)
LIST_CHECKS=false               # --list-checks: print the registry and exit
RESOLVE_DOMAINS_PY="$TOOL_DIR/tooling/lib/resolve-domains.py"
CHANGED_FILES_SH="$TOOL_DIR/tooling/lib/changed-files.sh"
VALIDATION_PLAN_FILE=""         # path to resolver JSON for this run
SELECTION_REASON=""             # compact human summary recorded in the sidecar
VALIDATION_SCOPE="full"         # source | report | full
VALIDATION_RUN_ID="$(python3 -c 'import uuid; print(str(uuid.uuid4()))' 2>/dev/null || printf 'run-%s' "$VALIDATE_START_EPOCH_MS")"

LAST_CHECK_FILE="$TOOL_DIR/output/.last-check.json"
LAST_SOURCE_CHECK_FILE="$TOOL_DIR/output/.last-source-check.json"
LAST_REPORT_CHECK_FILE="$TOOL_DIR/output/.last-report-check.json"
LOOP_STATE_SH="$TOOL_DIR/tooling/loop-state.sh"

usage() {
    cat <<USAGE
Usage: bash dynamics-migration-tool/tooling/validate.sh [OPTIONS] [project-directory]

Options:
  --preflight              Run pre-flight checks only (verify the project can
                           build before migration starts).
  --check-prompt <id>      Run only validator phases owned by the given prompt
                           id (e.g. 01, 04, 05z, 06, 10). Mapping is read from
                           tooling/check-prompt-map.json. Optional diagnostic
                           mode; writes output/.last-check.json.
  --app-module <name>      Select primary application module by repo-relative
                           path (e.g. app-primary). Required when multiple
                           com.android.application modules exist.
  --version                Print toolkit version and exit.
  --help                   Show this message and exit.

Incremental-validation flags (AGENT/MAINTAINER DEBUGGING ONLY — third-party
developers never set these; prompt 10 runs split source/report gates and these flags are
for manual debugging only):
  --mode <m>               m ∈ {incremental, full, final, final-source, report}.
                           incremental runs
                           only the phases the change set + registry select;
                           full/final run every phase (the acceptance gate).
                           final-source runs every final-source phase except
                           report and writes output/.last-source-check.json.
                           report runs only report-contract validation and
                           writes output/.last-report-check.json.
  --since <baseline>       baseline ∈ {start, last-checkpoint, last-prompt}
                           for --mode incremental (default last-prompt).
  --domains <a,b,c>        Force the phases owning these domains to run.
  --changed-file <path>    Use an explicit changed-path list instead of git.
  --prompt <id>            Union the prompt's owned phases into the plan and
                           record it as the sidecar promptId.
  --explain-plan           Print the resolved validation plan and exit (no run).
  --list-checks            Print the validation registry (phases, domains,
                           triggers, cost) and exit.
  --fix-suggestions        After validation, print actionable fix instructions
                           for every failure (API replacement, file, catalog ref).

Without --preflight, --check-prompt, or --mode, the full validator runs
end-to-end (manual/maintainer path; prompt 10 recorder uses split gates).

If no directory is specified, validates the current project (grandparent of
this script).
USAGE
}

VALIDATE_START_EPOCH_MS="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)"
CATALOG_VIOLATIONS_JSON=""

# Parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --preflight)
            PREFLIGHT=true
            shift
            ;;
        --check-prompt)
            CHECK_PROMPT_ID="$2"
            CHECK_PROMPT_MODE=true
            shift 2
            ;;
        --app-module)
            APP_MODULE_OVERRIDE="$2"
            shift 2
            ;;
        --app-module=*)
            APP_MODULE_OVERRIDE="${1#--app-module=}"
            shift
            ;;
        --mode)
            VALIDATION_MODE="$2"
            shift 2
            ;;
        --mode=*)
            VALIDATION_MODE="${1#--mode=}"
            shift
            ;;
        --since)
            SINCE_BASELINE="$2"
            shift 2
            ;;
        --since=*)
            SINCE_BASELINE="${1#--since=}"
            shift
            ;;
        --domains)
            FORCE_DOMAINS="$2"
            shift 2
            ;;
        --domains=*)
            FORCE_DOMAINS="${1#--domains=}"
            shift
            ;;
        --changed-file)
            CHANGED_FILE="$2"
            shift 2
            ;;
        --changed-file=*)
            CHANGED_FILE="${1#--changed-file=}"
            shift
            ;;
        --prompt)
            INCR_PROMPT_ID="$2"
            shift 2
            ;;
        --prompt=*)
            INCR_PROMPT_ID="${1#--prompt=}"
            shift
            ;;
        --explain-plan)
            EXPLAIN_PLAN=true
            shift
            ;;
        --list-checks)
            LIST_CHECKS=true
            shift
            ;;
        --fix-suggestions)
            FIX_SUGGESTIONS=true
            shift
            ;;
        --version)
            toolkit_version_print
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

PROJECT_DIR="${POSITIONAL[0]:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

if [[ ! "$PROJECT_DIR" = /* ]]; then
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
fi

OBSERVABILITY_PY="$TOOL_DIR/tooling/lib/observability.py"
OBS_RUN_ID="$(python3 - "$PROJECT_DIR/dynamics-migration-tool/output/bootstrap.json" "$VALIDATION_RUN_ID" <<'PY' 2>/dev/null || true
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        print(json.load(f).get("runId") or sys.argv[2])
except Exception:
    print(sys.argv[2])
PY
)"
observability_event() {
    [ -f "$OBSERVABILITY_PY" ] || return 0
    python3 "$OBSERVABILITY_PY" event \
        --tool-dir "$TOOL_DIR" \
        --project-root "$PROJECT_DIR" \
        --platform android \
        --run-id "${OBS_RUN_ID:-$VALIDATION_RUN_ID}" \
        "$@" >/dev/null 2>&1 || true
}

if [ "$PREFLIGHT" = true ] && [ "$CHECK_PROMPT_MODE" = true ]; then
    echo "❌ --preflight and --check-prompt cannot be used together"
    exit 2
fi

# --list-checks: print the validation registry and exit. Needs only the map.
if [ "$LIST_CHECKS" = true ]; then
    if [ ! -f "$CHECK_PROMPT_MAP" ]; then
        echo "❌ check-prompt map not found: $CHECK_PROMPT_MAP" >&2
        exit 2
    fi
    CHECK_PROMPT_MAP="$CHECK_PROMPT_MAP" python3 - <<'PY'
import json, os, sys

with open(os.environ["CHECK_PROMPT_MAP"], encoding="utf-8") as f:
    cfg = json.load(f)
reg = cfg.get("validationRegistry") or {}
phases = reg.get("phases") or {}
order = reg.get("phaseOrder") or sorted(phases)
expensive = set(reg.get("expensiveFullOnly") or [])
report_only = set(reg.get("reportOnly") or [])

print("Validation registry (schemaVersion %s)" % cfg.get("schemaVersion"))
print("=" * 78)
print("%-8s %-9s %-9s %-7s  %s" % ("phase", "always", "class", "cost(ms)", "domains"))
print("-" * 78)
for p in order:
    m = phases.get(p, {})
    cls = "fullOnly" if p in expensive else ("report" if p in report_only else "domain")
    if m.get("alwaysRun"):
        cls = "alwaysRun"
    print("%-8s %-9s %-9s %-7s  %s" % (
        p,
        "yes" if m.get("alwaysRun") else "-",
        cls,
        m.get("estimatedCostMs", 0),
        ",".join(m.get("domains", [])),
    ))
print("-" * 78)
print("alwaysRun phases run on every incremental pass when any source/manifest/")
print("gradle file changed. fullOnly/report phases run only at the full/final gate.")
print("A change to a crossCutting file forces the full domain set; UNKNOWN -> full.")
PY
    exit 0
fi

normalize_phase_list() {
    printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

phase_is_allowed() {
    case "$1" in
        0|1|2|3|3b|4|5|5b|6|6b|7|8|8b|9|10|11|12|comments|catalog|report)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

PHASES_ONLY_NORM=""
CHECK_PROMPT_MODE_LABEL=""

# Resolve --check-prompt <id> against tooling/check-prompt-map.json. This is
# the single source of truth shared with record-prompt-execution.sh.
if [ "$CHECK_PROMPT_MODE" = true ]; then
    if [ -z "$CHECK_PROMPT_ID" ]; then
        echo "❌ --check-prompt requires a prompt id (e.g. 04, 05z, 10)"
        exit 2
    fi
    if [ ! -f "$CHECK_PROMPT_MAP" ]; then
        echo "❌ check-prompt map not found: $CHECK_PROMPT_MAP"
        echo "   The migration toolkit is incomplete — re-copy dynamics-migration-tool/."
        exit 2
    fi
    CHECK_PROMPT_RESOLVED="$(CHECK_PROMPT_ID="$CHECK_PROMPT_ID" CHECK_PROMPT_MAP="$CHECK_PROMPT_MAP" python3 - <<'PY'
import json, os, sys

prompt_id = os.environ["CHECK_PROMPT_ID"]
path = os.environ["CHECK_PROMPT_MAP"]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(f"ERR|map JSON invalid: {exc}")
    sys.exit(2)

if not isinstance(data, dict):
    print("ERR|map root must be an object")
    sys.exit(2)

no_op = data.get("noOp", [])
scoped = data.get("scopedChecks", {}) or {}
full = data.get("fullSweep", {}) or {}

if isinstance(no_op, list) and prompt_id in no_op:
    print("NOOP|")
    sys.exit(0)
if isinstance(scoped, dict) and prompt_id in scoped:
    entry = scoped[prompt_id] or {}
    phases = entry.get("phases") or []
    if not isinstance(phases, list) or not phases:
        print(f"ERR|scopedChecks.{prompt_id}.phases must be a non-empty array")
        sys.exit(2)
    print("SCOPED|" + ",".join(str(p) for p in phases))
    sys.exit(0)
if isinstance(full, dict) and prompt_id in full:
    entry = full[prompt_id] or {}
    phases = entry.get("phases") or []
    if not isinstance(phases, list) or not phases:
        print(f"ERR|fullSweep.{prompt_id}.phases must be a non-empty array")
        sys.exit(2)
    print("FULLSWEEP|" + ",".join(str(p) for p in phases))
    sys.exit(0)

print(f"ERR|unknown prompt id '{prompt_id}' — not present in noOp/scopedChecks/fullSweep")
sys.exit(2)
PY
)"
    RESOLVE_EXIT=$?
    if [ "$RESOLVE_EXIT" -ne 0 ] || [ -z "$CHECK_PROMPT_RESOLVED" ]; then
        echo "❌ check-prompt resolution failed: ${CHECK_PROMPT_RESOLVED#ERR|}"
        exit 2
    fi
    CHECK_PROMPT_MODE_LABEL="${CHECK_PROMPT_RESOLVED%%|*}"
    CHECK_PROMPT_PHASES="${CHECK_PROMPT_RESOLVED#*|}"
    case "$CHECK_PROMPT_MODE_LABEL" in
        NOOP)
            # No-op: emit a sidecar marking the run as passed without invoking
            # any phase machinery, then exit 0. record-prompt-execution.sh
            # treats this prompt id as not needing validation.
            mkdir -p "$TOOL_DIR/output"
            python3 - "$TOOL_DIR/output/.last-check.json" "$CHECK_PROMPT_ID" "$VALIDATE_START_EPOCH_MS" "$VALIDATION_RUN_ID" <<'PY'
import json, os, sys, time

out_path, prompt_id, start_ms, run_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
start_ms = int(start_ms or 0)
now_ms = int(time.time() * 1000)
duration = max(0, now_ms - start_ms) if start_ms else 0
now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
record = {
    "schemaVersion": "1.3.0",
    "exitCode": 0,
    "failCount": 0,
    "generatedAt": now_iso,
    "mode": "scoped",
    "passCount": 0,
    "phasesRun": [],
    "promptId": prompt_id,
    "scope": "full",
    "status": "passed",
    "validationRunId": run_id,
    "violations": [],
    "warnCount": 0,
    "durationMs": duration,
}
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(record, f, indent=2, sort_keys=True)
    f.write("\n")
PY
            echo "Prompt $CHECK_PROMPT_ID is a no-op per check-prompt-map.json — no validation phases run."
            exit 0
            ;;
        SCOPED|FULLSWEEP)
            PHASES_ONLY_NORM="$(normalize_phase_list "$CHECK_PROMPT_PHASES")"
            PHASES_ONLY_MODE=true
            ;;
        *)
            echo "❌ check-prompt resolution returned unexpected label: $CHECK_PROMPT_MODE_LABEL"
            exit 2
            ;;
    esac

    IFS=',' read -r -a _PHASE_ITEMS <<< "$PHASES_ONLY_NORM"
    for _phase in "${_PHASE_ITEMS[@]}"; do
        if ! phase_is_allowed "$_phase"; then
            echo "❌ invalid phase key resolved for prompt $CHECK_PROMPT_ID: $_phase"
            echo "   Allowed: 0,1,2,3,3b,4,5,5b,6,6b,7,8,8b,9,10,11,12,comments,catalog,report"
            echo "   Fix tooling/check-prompt-map.json so its phases are valid."
            exit 2
        fi
    done
fi

# ========================================
# Pre-flight mode
# ========================================
# Self-contained pre-migration probe (JAVA_HOME, Android SDK, AGP/JDK
# compatibility, gradlew, baseline assembleDebug). Lives in
# lib/preflight.sh because it shares no state with the validation phases
# and the only entry path is --preflight. Sourced (not subshelled) so
# its `exit` calls terminate validate.sh just like the original inline
# block did.
if [ "$PREFLIGHT" = true ]; then
    # shellcheck source=lib/preflight.sh
    . "$SCRIPT_DIR/lib/preflight.sh"
fi

echo "========================================="
echo "BlackBerry Dynamics Migration Validation"
echo "========================================="
echo "Toolkit Version: $TOOL_VERSION"
echo "Project: $PROJECT_DIR"
if [ "$CHECK_PROMPT_MODE" = true ]; then
    echo "Check-prompt mode: id=$CHECK_PROMPT_ID phases=$PHASES_ONLY_NORM"
fi
if [ -n "$VALIDATION_MODE" ]; then
    echo "Validation mode: $VALIDATION_MODE"
fi
echo ""

if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ Directory not found: $PROJECT_DIR"
    if [ "$CHECK_PROMPT_MODE" = true ]; then
        exit 2
    fi
    exit 1
fi

cd "$PROJECT_DIR"

# ========================================
# Incremental / full / final-source / report mode resolution
# ========================================
# Runs from the project root so the changed-file detector can see git and the
# resolver can read changed-file contents for pattern triggers. Sets
# PHASES_ONLY_MODE / PHASES_ONLY_NORM for incremental/final-source/report runs;
# full/final leave
# the full PHASE_ORDER loop untouched (byte-identical to a no-arg run). The
# resolver JSON is captured for the sidecar and for --explain-plan.
if [ -n "$VALIDATION_MODE" ]; then
    case "$VALIDATION_MODE" in
        incremental|full|final|final-source|report) ;;
        *)
            echo "❌ --mode must be one of: incremental, full, final, final-source, report" >&2
            exit 2
            ;;
    esac
    if [ "$CHECK_PROMPT_MODE" = true ]; then
        echo "❌ --mode and --check-prompt are mutually exclusive" >&2
        exit 2
    fi
    if [ "$PREFLIGHT" = true ]; then
        echo "❌ --mode and --preflight are mutually exclusive" >&2
        exit 2
    fi
    if [ "$VALIDATION_MODE" = "final-source" ]; then
        PHASES_ONLY_NORM="0,1,2,3,3b,4,5,5b,6,6b,7,8,8b,9,10,11,12,comments,catalog"
        PHASES_ONLY_MODE=true
        VALIDATION_SCOPE="source"
        SELECTION_REASON="mode=final-source phases=19 split-gate-source"
    elif [ "$VALIDATION_MODE" = "report" ]; then
        PHASES_ONLY_NORM="report"
        PHASES_ONLY_MODE=true
        VALIDATION_SCOPE="report"
        SELECTION_REASON="mode=report phases=1 split-gate-report"
    else
        if [ ! -f "$RESOLVE_DOMAINS_PY" ]; then
            echo "❌ resolver missing: $RESOLVE_DOMAINS_PY" >&2
            echo "   The migration toolkit is incomplete — re-copy dynamics-migration-tool/." >&2
            exit 2
        fi
        case "$SINCE_BASELINE" in
            start|last-checkpoint|last-prompt) ;;
            *)
                echo "❌ --since must be one of: start, last-checkpoint, last-prompt" >&2
                exit 2
                ;;
        esac

        MODE_TMPDIR="$(mktemp -d -t dynamics-validate-mode.XXXXXX)"
        VALIDATION_PLAN_FILE="$MODE_TMPDIR/plan.json"
        _RESOLVE_ARGS=(--registry "$CHECK_PROMPT_MAP" --mode "$VALIDATION_MODE")
        [ -n "$INCR_PROMPT_ID" ] && _RESOLVE_ARGS+=(--prompt "$INCR_PROMPT_ID")
        [ -n "$FORCE_DOMAINS" ] && _RESOLVE_ARGS+=(--domains "$FORCE_DOMAINS")

        if [ "$VALIDATION_MODE" = "incremental" ]; then
            # Obtain the changed-file list: explicit (recorder) or computed via git.
            if [ -z "$CHANGED_FILE" ]; then
                CHANGED_FILE="$MODE_TMPDIR/changed.txt"
                if [ -f "$CHANGED_FILES_SH" ]; then
                    bash "$CHANGED_FILES_SH" since "$SINCE_BASELINE" > "$CHANGED_FILE" 2>/dev/null || echo "UNKNOWN" > "$CHANGED_FILE"
                else
                    echo "UNKNOWN" > "$CHANGED_FILE"
                fi
            fi
            _RESOLVE_ARGS+=(--changed-file "$CHANGED_FILE")
        fi

        _RESOLVE_ERR="$MODE_TMPDIR/resolve.err"
        if ! python3 "$RESOLVE_DOMAINS_PY" "${_RESOLVE_ARGS[@]}" > "$VALIDATION_PLAN_FILE" 2>"$_RESOLVE_ERR"; then
            echo "❌ validation-plan resolution failed" >&2
            if [ -s "$_RESOLVE_ERR" ]; then
                echo "   resolver error:" >&2
                sed 's/^/     /' "$_RESOLVE_ERR" >&2
            fi
            echo "   Likely a malformed validationRegistry entry in $CHECK_PROMPT_MAP" >&2
            echo "   (e.g. an invalid patternTriggers regex). Run \`bash $0 --list-checks\`." >&2
            rm -rf "$MODE_TMPDIR"
            exit 2
        fi

        # Extract the phase CSV and a compact selection reason for the sidecar.
        _PLAN_PHASES="$(PLAN="$VALIDATION_PLAN_FILE" python3 -c 'import json,os; d=json.load(open(os.environ["PLAN"])); print(",".join(d.get("phasesToRun") or []))')"
        SELECTION_REASON="$(PLAN="$VALIDATION_PLAN_FILE" python3 -c '
import json, os
d = json.load(open(os.environ["PLAN"]))
bits = ["mode=%s" % d.get("mode")]
if d.get("fallbackFull"):
    bits.append("fallback=full")
if d.get("crossCutting"):
    bits.append("crossCutting")
cc = d.get("changedFileCount")
if cc is not None:
    bits.append("changedFiles=%d" % cc)
bits.append("phases=%d" % len(d.get("phasesToRun") or []))
print(" ".join(bits))
')"

        if [ "$EXPLAIN_PLAN" = true ]; then
            PLAN="$VALIDATION_PLAN_FILE" python3 - <<'PY'
import json, os
d = json.load(open(os.environ["PLAN"]))
print("=========================================")
print("Validation plan — mode=%s" % d.get("mode"))
print("=========================================")
if d.get("fallbackFull"):
    print("FALLBACK: changed-file detection was UNKNOWN -> running the full sweep.")
cc = d.get("changedFileCount")
if cc is not None:
    print("Changed files: %s   anySource=%s   crossCutting=%s"
          % (cc, d.get("anySource"), d.get("crossCutting")))
for f in d.get("crossCuttingFiles") or []:
    print("  cross-cutting: %s" % f)
print("")
print("WILL RUN (%d phase(s), ~%d ms):" % (len(d.get("phasesToRun") or []),
                                           d.get("estimatedCostMs", 0)))
run = {s["phase"]: s for s in d.get("selection", []) if s.get("run")}
for p in d.get("phasesToRun") or []:
    s = run.get(p, {})
    print("  + phase %-8s %s" % (p, s.get("reason", "")))
print("")
print("SKIPPED:")
for s in d.get("skipped", []):
    print("  - phase %-8s %s" % (s["phase"], s["reason"]))
print("")
print("Final acceptance gate still required: prompt 10 always runs the full")
print("sweep (every phase + Gradle build + report contract) regardless of this plan.")
PY
            rm -rf "$MODE_TMPDIR"
            exit 0
        fi

        if [ "$VALIDATION_MODE" = "incremental" ]; then
            PHASES_ONLY_NORM="$(normalize_phase_list "$_PLAN_PHASES")"
            PHASES_ONLY_MODE=true
        fi
        # full/final: leave PHASES_ONLY_MODE=false so the entire PHASE_ORDER runs.
        rm -rf "$MODE_TMPDIR"
        unset _RESOLVE_ARGS _PLAN_PHASES _RESOLVE_ERR MODE_TMPDIR
    fi
    [ -n "$SELECTION_REASON" ] && echo "Validation plan: $SELECTION_REASON"
fi

# Reset security-blocker log at the start of each validation run so a prior
# failed Phase 4 scan cannot leave stale rows that force a false no-go on
# a later clean run.
SEC_BLOCKERS_LOG="$TOOL_DIR/output/.security-blockers.log"
mkdir -p "$TOOL_DIR/output" 2>/dev/null || true
: > "$SEC_BLOCKERS_LOG" 2>/dev/null || true

# ---------------------------------------------------------------------
# Module map: load once so every grep/check below is module-aware. If a
# bootstrap-emitted output/module-map.json exists, use it; otherwise the
# accessor library synthesizes a fallback for canonical app/-shaped
# projects so single-module behavior is preserved byte-for-byte.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/module-map.sh"

MODULE_MAP_FILE="$TOOL_DIR/output/module-map.json"
if [ -f "$MODULE_MAP_FILE" ]; then
    if ! mm_load "$MODULE_MAP_FILE" 2>/dev/null; then
        echo "❌ output/module-map.json exists but could not be parsed — re-run bootstrap"
        if [ "$CHECK_PROMPT_MODE" = true ]; then
            exit 2
        fi
        exit 1
    fi
elif ! mm_load 2>/dev/null; then
    echo "❌ Not an Android project (no app/build.gradle found and no module map present)"
    echo "   For multi-module projects, run dynamics-migration-tool/tooling/bootstrap.sh first."
    if [ "$CHECK_PROMPT_MODE" = true ]; then
        exit 2
    fi
    exit 1
fi

PRIMARY_PATH="$(mm_primary_path 2>/dev/null || echo app)"
PRIMARY_BUILD_FILE="$(mm_primary_build_file 2>/dev/null || echo app/build.gradle)"
PRIMARY_APK_GLOB="$(mm_primary_apk_glob 2>/dev/null || echo 'app/build/outputs/apk/**/*.apk')"
PRIMARY_CP_FILE="$(mm_convention_plugin_for "$PRIMARY_PATH" 2>/dev/null || echo "")"

if [ ! -f "$PRIMARY_BUILD_FILE" ]; then
    echo "❌ Primary app module build file missing: $PRIMARY_BUILD_FILE"
    if [ "$CHECK_PROMPT_MODE" = true ]; then
        exit 2
    fi
    exit 1
fi

# Newline-separated lists projected to space-separated path strings via
# tr+dedupe. Empty when nothing is in scope; callers must always test for
# non-empty before piping into grep.
__mm_join() { tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }

# Manifests, res dirs, assets dirs scoped to the primary module only —
# used by checks that target manifest hardening / settings.json placement,
# which are app-level concerns and never library-level.
MM_PRIMARY_MANIFESTS="$(mm_primary_manifests 2>/dev/null | __mm_join)"
MM_PRIMARY_RES_DIRS="$(mm_primary_res_dirs 2>/dev/null | __mm_join)"
MM_PRIMARY_ASSETS_DIRS="$(mm_primary_assets_dirs 2>/dev/null | __mm_join)"
MM_SETTINGS_JSON_TARGETS="$(mm_settings_json_targets 2>/dev/null | __mm_join)"

# Source roots and manifests across the full in-scope module set
# (primary + libraries) — used by source-grep checks for migrated APIs.
MM_IN_SCOPE_SOURCE_ROOTS="$(mm_in_scope_source_roots 2>/dev/null | __mm_join)"
MM_IN_SCOPE_MANIFESTS="$(mm_in_scope_manifests 2>/dev/null | __mm_join)"
MM_IN_SCOPE_RES_DIRS="$(mm_in_scope_res_dirs 2>/dev/null | __mm_join)"

# Module roots (primary + libraries) used by native (C/C++/NDK) phases.
# Native discovery is anchored to module roots, not Java/Kotlin source
# roots, because NDK code lives under each module's `src/**/cpp/`,
# `src/**/jni/`, `src/**/jniLibs/` plus module-root CMake/ndk-build
# config — none of which are covered by `mm_in_scope_source_roots`.
# Contract: steering/46-native-ndk-direct-replacement.md (primary
# module + every libraryModulesInScope[] entry).
MM_IN_SCOPE_MODULE_PATHS="$(mm_in_scope_module_paths 2>/dev/null | __mm_join)"

# Build files inspected by Gradle phase: the primary app module's build
# file plus, when applicable, the convention plugin source it consumes.
MM_GRADLE_FILES="$PRIMARY_BUILD_FILE"
if [ -n "$PRIMARY_CP_FILE" ] && [ -f "$PRIMARY_CP_FILE" ]; then
    MM_GRADLE_FILES="$MM_GRADLE_FILES $PRIMARY_CP_FILE"
fi

PASS=0
FAIL=0
WARN=0

# Defaults for cross-phase aggregates when --check-prompt skips producer phases.
ALL_ACTIVITIES=""
STD_FS=0
STD_SQL=0
STD_HTTP=0
STD_SOCK=0
UNSUPPORTED_NET_BLOCKERS=0
UNSUPPORTED_NET_DEP_HINTS=0
STD_POL=0
STD_CLIP=0
COMPOSE_CLIPBOARD_UNMANAGED=0
CLIPBOARD_SERVICE_HITS=0
COMPOSE_ICC_VIEW_CHOOSER=0
DIRECT_FILE_COUNT=0
TEMP_FILE_COUNT=0
EXTERNAL_STORAGE_API_SURFACE=0
OPAQUE_BINARY_DEP_HITS=0
SENSITIVE_PREF_KEYS=0
ROOM_FILE_COUNT=0
BRIDGE_FACTORY_FILES=0
OKHTTP_FILE_COUNT=0
RETROFIT_FILE_COUNT=0
INTERCEPTOR_COUNT=0
TRANSPORT_HARDENING_HITS=0
WEBVIEW_JS_INTERFACE=0
WEBVIEW_UNSAFE_SETTINGS=0
DYNAMICS_TOTAL=0
DLP_NOTIFICATION_SURFACE_HITS=0
DLP_PRINT_SURFACE_HITS=0
DLP_SCREENSHOT_SURFACE_HITS=0
DLP_AUTOFILL_SURFACE_HITS=0
DLP_ACCESSIBILITY_SURFACE_HITS=0
DLP_IME_SURFACE_HITS=0
DLP_EXTERNAL_BROWSER_SURFACE_HITS=0
DLP_RICH_CLIPBOARD_URI_SURFACE_HITS=0
DLP_DRAGDROP_SURFACE_HITS=0
DLP_SURFACE_TOTAL=0

# Source tree root used by grep-based phases. Must be initialized before
# any phase checks so scoped runs (for example --check-prompt 04) never
# fall back to searching "/" when phase 3 is skipped.
#
# Primary-module source root fallback used by phases that are intentionally
# app-only and by compatibility code paths when module-map source roots are
# not available yet.
SRC_DIR_PRIMARY="$PRIMARY_PATH/src/main/java"
if [ ! -d "$SRC_DIR_PRIMARY" ] && [ -d "$PRIMARY_PATH/src/main/kotlin" ]; then
    SRC_DIR_PRIMARY="$PRIMARY_PATH/src/main/kotlin"
fi
if [ ! -d "$SRC_DIR_PRIMARY" ]; then
    SRC_DIR_PRIMARY="$PRIMARY_PATH/src/main"
fi
SRC_DIR="$SRC_DIR_PRIMARY"

# Native (NDK / C / C++) discovery for Phase 4 / Phase 6 native call
# detection. Per `steering/46-native-ndk-direct-replacement.md`, native
# scanning runs across the **full in-scope module set** (primary +
# every entry in `libraryModulesInScope[]`), not just the primary
# module — a native library module can still contain `fopen`, BSD
# socket calls, or prebuilt `.so` artifacts and must be enforced.
#
# Concrete coverage (per module path $MP in $MM_IN_SCOPE_MODULE_PATHS):
#   - source files:   $MP/src/**/*.{c,cc,cpp,cxx,h,hpp}
#   - prebuilt libs:  $MP/src/**/jniLibs/**/*.so
#   - CMake config:   $MP/CMakeLists.txt, $MP/src/main/cpp/CMakeLists.txt
#   - ndk-build:      $MP/src/main/jni/{Android,Application}.mk,
#                     $MP/{Android,Application}.mk
#   - externalNativeBuild { cmake|ndkBuild { ... } } in $MP/build.gradle[.kts]
#
# The legacy single-module path vars below remain to scope a couple of
# "is there in-repo native source at all?" guards that key off the
# primary module (e.g. the "opaque-loadLibrary" warning at the bottom
# of Phase 4). Hit aggregation across modules happens in the Phase 4
# and Phase 6 native blocks themselves.
NATIVE_SRC_DIR="$PRIMARY_PATH/src/main"
NATIVE_JNILIBS_DIR="$PRIMARY_PATH/src/main/jniLibs"
NATIVE_CMAKE_FILE="$PRIMARY_PATH/CMakeLists.txt"
[ ! -f "$NATIVE_CMAKE_FILE" ] && NATIVE_CMAKE_FILE="$PRIMARY_PATH/src/main/cpp/CMakeLists.txt"
# NATIVE_SCAN_PY (the shared C/C++ call-pattern scanner used by Phase 4
# and Phase 6) is materialised once VALIDATE_TMPDIR exists — see below.

check_pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
check_fail() {
    echo "  ❌ $1"
    FAIL=$((FAIL + 1))
    _capture_violation "fail" "$@"
}
check_warn() {
    echo "  ⚠️  $1"
    WARN=$((WARN + 1))
    _capture_violation "warn" "$@"
}

# Structured violation capture for .last-check.json.
# Accumulates violations as newline-delimited JSON objects in a temp file
# so emit_last_check_sidecar can include them alongside catalog violations.
# VIOLATIONS_FILE and DOMAIN_FAIL_COUNTS_FILE are initialized after
# VALIDATE_TMPDIR is created (see below). Until then, _capture_violation
# silently drops entries.
VIOLATIONS_FILE=""
DOMAIN_FAIL_COUNTS_FILE=""

_capture_violation() {
    local severity="$1"
    shift
    local message="$1"
    local domain="${_CURRENT_DOMAIN:-}"
    local phase="${_CURRENT_PHASE:-}"
    local fix="${_CURRENT_FIX:-}"
    local files="${_CURRENT_FILES:-}"
    if [ -n "$VIOLATIONS_FILE" ] && [ -d "$(dirname "$VIOLATIONS_FILE")" ]; then
        python3 -c "
import json, sys
v = {'severity': sys.argv[1], 'phase': sys.argv[2], 'domain': sys.argv[3],
     'message': sys.argv[4]}
if sys.argv[5]: v['fix'] = sys.argv[5]
if sys.argv[6]: v['files'] = sys.argv[6]
print(json.dumps(v))
" "$severity" "$phase" "$domain" "$message" "$fix" "$files" \
            >> "$VIOLATIONS_FILE" 2>/dev/null || true
    fi
    if [ "$severity" = "fail" ] && [ -n "$domain" ] \
       && [ -n "$DOMAIN_FAIL_COUNTS_FILE" ] && [ -d "$(dirname "$DOMAIN_FAIL_COUNTS_FILE")" ]; then
        echo "$domain" >> "$DOMAIN_FAIL_COUNTS_FILE" 2>/dev/null || true
    fi
    _CURRENT_DOMAIN="" _CURRENT_FIX="" _CURRENT_FILES=""
}

# Helpers for annotating the next check_fail/check_warn with context.
# Usage: _set_violation_context "secureFileStorage" "4" \
#            "Replace java.io.File with com.good.gd.file.File" "file1.java:42"
#        check_fail "message"
_set_violation_context() {
    _CURRENT_DOMAIN="${1:-}"
    _CURRENT_PHASE="${2:-}"
    _CURRENT_FIX="${3:-}"
    _CURRENT_FILES="${4:-}"
}

should_run_phase() {
    local phase_key="$1"
    if [ "$PHASES_ONLY_MODE" != true ]; then
        return 0
    fi
    case ",$PHASES_ONLY_NORM," in
        *",$phase_key,"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# strip_audit_noise: filters `grep -rn ...` output, removing source comment
# noise and `[BB_DYNAMICS-MIGRATION]` audit lines before the validator counts
# hits. `[BB_DYNAMICS-MIGRATION]` is the only recognized audit tag; unknown
# variants are not honored here and will additionally be flagged by the
# comment-audit phase.
#
# Implementation note:
#   This helper is invoked inside pipelines (`grep ... | strip_audit_noise`).
#   On macOS bash 3.2, mixing a `python3 - <<'PY'` here-doc with a pipeline
#   stdin causes the pipe stdin to win over the here-doc — python3 then tries
#   to execute the grep output as Python source and silently returns nothing.
#   To stay portable across bash 3.2 / 4.x / 5.x and macOS / Linux, the
#   Python program is materialised once to a temp file at script start and
#   executed via `python3 "$STRIP_AUDIT_NOISE_PY"` so its stdin is unambiguous.
VALIDATE_TMPDIR="$(mktemp -d -t dynamics-validate.XXXXXX)"
VIOLATIONS_FILE="$VALIDATE_TMPDIR/violations.jsonl"
: > "$VIOLATIONS_FILE"
DOMAIN_FAIL_COUNTS_FILE="$VALIDATE_TMPDIR/domain_fail_counts.txt"
: > "$DOMAIN_FAIL_COUNTS_FILE"
# Module-map-wide union source root used by HR-0-1 hardening phases.
# We mirror each in-scope source root under VALIDATE_TMPDIR so legacy
# phase scanners that expect a single root path can traverse a complete
# in-scope tree without changing their grep/python structure.
SRC_DIR_MM="$VALIDATE_TMPDIR/in-scope-source"
SRC_STAGE_START_MS="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)"
mkdir -p "$SRC_DIR_MM"
SRC_DIR_MM_ROOT_COUNT=0
if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ]; then
    # shellcheck disable=SC2086
    for _mm_root in $MM_IN_SCOPE_SOURCE_ROOTS; do
        [ -z "$_mm_root" ] && continue
        [ -d "$_mm_root" ] || continue
        _mm_dst="$SRC_DIR_MM/$_mm_root"
        mkdir -p "$_mm_dst"
        cp -R "$_mm_root"/. "$_mm_dst"/ 2>/dev/null || true
        SRC_DIR_MM_ROOT_COUNT=$((SRC_DIR_MM_ROOT_COUNT + 1))
    done
fi
if [ "$SRC_DIR_MM_ROOT_COUNT" -eq 0 ] && [ -d "$SRC_DIR_PRIMARY" ]; then
    _mm_dst="$SRC_DIR_MM/$SRC_DIR_PRIMARY"
    mkdir -p "$_mm_dst"
    cp -R "$SRC_DIR_PRIMARY"/. "$_mm_dst"/ 2>/dev/null || true
fi
unset _mm_root _mm_dst
observability_event \
    --operation-type source-staging \
    --phase source-staging \
    --start-ms "$SRC_STAGE_START_MS" \
    --metadata-json "{\"sourceRootCount\":$SRC_DIR_MM_ROOT_COUNT,\"scope\":\"module-map\"}"
STRIP_AUDIT_NOISE_PY="$VALIDATE_TMPDIR/strip_audit_noise.py"
# Shared C/C++ call-pattern scanner used by Phase 4 (file I/O) and
# Phase 6 (BSD sockets). Iterated once per in-scope module path so
# library modules covered by `libraryModulesInScope[]` are enforced
# per `steering/46-native-ndk-direct-replacement.md`. Argv:
#   python3 "$NATIVE_SCAN_PY" <module-src-root> <file|sock>
NATIVE_SCAN_PY="$VALIDATE_TMPDIR/native_call_scan.py"
cleanup_validate_tmpdir() { rm -rf "$VALIDATE_TMPDIR"; }
trap cleanup_validate_tmpdir EXIT

cat > "$STRIP_AUDIT_NOISE_PY" <<'PY'
import re
import sys

MIGRATION_TAG = "[BB_DYNAMICS-MIGRATION]"
line_with_number = re.compile(r"^(.*?:\d+:)(.*)$")
line_without_number = re.compile(r"^(.*?:)(.*)$")

for raw in sys.stdin:
    line = raw.rstrip("\n")
    prefix = ""
    body = line

    match = line_with_number.match(line)
    if match:
        prefix, body = match.group(1), match.group(2)
    else:
        match = line_without_number.match(line)
        if match:
            prefix, body = match.group(1), match.group(2)

    stripped = body.lstrip()
    if not stripped:
        continue
    if stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*") or stripped.startswith("<!--"):
        continue

    comment_start = -1
    for marker in ("//", "/*", "<!--"):
        idx = body.find(marker)
        if idx != -1 and (comment_start == -1 or idx < comment_start):
            comment_start = idx

    if comment_start != -1:
        comment_text = body[comment_start:]
        if MIGRATION_TAG in comment_text:
            continue
        body = body[:comment_start]

    if not body.strip():
        continue

    print(f"{prefix}{body.rstrip()}")
PY

strip_audit_noise() {
    python3 "$STRIP_AUDIT_NOISE_PY"
}

# Stricter cousin of strip_audit_noise for SECURITY-BLOCKER scans.
# Filters out lines whose code portion is empty / pure comment, but
# does NOT honor the `[BB_DYNAMICS-MIGRATION]` marker. This stops the
# previously observed workaround where a developer (or the agent)
# silenced an external-storage finding by appending
# `// [BB_DYNAMICS-MIGRATION] export boundary` to the offending line.
# The marker is documented as audit-only; this filter enforces that
# for security-critical surfaces. See AGENTS.md §"Non-Negotiable
# Rules" and steering/40-secure-file-storage.md §9 (external storage
# is non-waivable; audit markers do not suppress security blockers).
STRIP_PURE_COMMENTS_PY="$VALIDATE_TMPDIR/strip_pure_comments.py"
cat > "$STRIP_PURE_COMMENTS_PY" <<'PY'
import re
import sys

line_with_number = re.compile(r"^(.*?:\d+:)(.*)$")
line_without_number = re.compile(r"^(.*?:)(.*)$")

for raw in sys.stdin:
    line = raw.rstrip("\n")
    prefix = ""
    body = line

    match = line_with_number.match(line)
    if match:
        prefix, body = match.group(1), match.group(2)
    else:
        match = line_without_number.match(line)
        if match:
            prefix, body = match.group(1), match.group(2)

    stripped = body.lstrip()
    if not stripped:
        continue
    if stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*") or stripped.startswith("<!--"):
        continue

    # Trim trailing inline comments but do NOT honor any audit marker.
    comment_start = -1
    for marker in ("//", "/*", "<!--"):
        idx = body.find(marker)
        if idx != -1 and (comment_start == -1 or idx < comment_start):
            comment_start = idx
    if comment_start != -1:
        body = body[:comment_start]

    if not body.strip():
        continue
    print(f"{prefix}{body.rstrip()}")
PY

strip_pure_comments() {
    python3 "$STRIP_PURE_COMMENTS_PY"
}

cat > "$NATIVE_SCAN_PY" <<'PY'
import os, re, sys

src = sys.argv[1]
mode = sys.argv[2]
exts = (".c", ".cc", ".cpp", ".cxx", ".h", ".hpp")
if mode == "file":
    calls = (
        "fopen", "fclose", "fread", "fwrite", "fseek", "ftell", "fflush",
        "feof", "ferror", "clearerr", "remove", "rename",
        "open", "close", "read", "write", "lseek",
        "unlink", "mkdir", "rmdir",
        "opendir", "readdir", "closedir",
        "stat", "fstat",
    )
    gd_prefix = re.compile(r"GD_(UNISTD_)?[A-Za-z0-9_]+\s*\(")
elif mode == "sock":
    calls = (
        "socket", "connect", "bind", "listen", "accept",
        "send", "recv", "sendto", "recvfrom", "shutdown",
        "getaddrinfo", "freeaddrinfo", "gethostbyname",
    )
    gd_prefix = re.compile(r"GD_[A-Za-z0-9_]+\s*\(")
else:
    print(0); sys.exit(0)

pattern = re.compile(
    r"(^|[^A-Za-z0-9_>])(" + "|".join(re.escape(c) for c in calls) + r")\s*\("
)
hits = 0
if os.path.isdir(src):
    for dp, _, files in os.walk(src):
        if "/src/test" in dp or "/src/androidTest" in dp:
            continue
        for fn in files:
            if not fn.endswith(exts):
                continue
            path = os.path.join(dp, fn)
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    text = f.read()
            except OSError:
                continue
            for raw in text.splitlines():
                line = raw.lstrip()
                if line.startswith("//") or line.startswith("*") or line.startswith("/*"):
                    continue
                if line.startswith("#"):
                    continue
                stripped = re.sub(gd_prefix, "GD_X(", raw)
                if pattern.search(stripped):
                    hits += 1
print(hits)
PY

# ----------------------------------------------------------------------
# Deferred-domain support (consults bootstrap.json)
# ----------------------------------------------------------------------
#
# Reads dynamics-migration-tool/output/bootstrap.json and exposes:
#   deferredDomains[] — domain-level deferrals authored by the developer
#
# The toolkit does not support line-level exceptions. Non-migrated
# call-sites in an applicable, non-deferred domain are hard failures.
# [BB_DYNAMICS-MIGRATION] is audit-only and does not suppress findings.

BOOTSTRAP_FILE="dynamics-migration-tool/output/bootstrap.json"
CATALOG_CONTRACT_FILE="dynamics-migration-tool/contracts/api-catalog.v1.0.0.json"
DEFERRED_DOMAINS=""

# Non-waivable domains: deferral entries naming these are rejected at
# Phase 0 and `fail_or_defer` will always hard-fail them.
#
# `externalStorage` is the security-critical surface inside
# `secureFileStorage` that covers writes to external/shared storage,
# MediaStore, public Downloads/Pictures/Documents, removable media, SAF
# document trees, and any java.io.File rooted at `/sdcard` or
# `/storage/emulated/`. Allowing those writes to be silently deferred
# would let enterprise data leave the Dynamics secure container
# unencrypted, outside the remote-wipe boundary, and visible to device
# backups / USB / file managers. The whole `secureFileStorage` domain
# remains waivable for legitimate "this app stores nothing sensitive"
# cases, but the `externalStorage` sub-surface must never be waivable.
NON_WAIVABLE_DOMAINS="authorization policyManagement secureClipboard transportHardening externalStorage"

if [ -f "$BOOTSTRAP_FILE" ]; then
    BOOTSTRAP_META="$(python3 - "$BOOTSTRAP_FILE" <<'PY' 2>/dev/null || true
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

from datetime import datetime, timezone

def parse_iso(v):
    if not isinstance(v, str) or not v.strip():
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00"))
    except Exception:
        return None

now = datetime.now(timezone.utc)
non_waivable = {"authorization", "policyManagement", "secureClipboard", "transportHardening", "externalStorage"}

deferred = data.get("deferredDomains", [])
if isinstance(deferred, list):
    for entry in deferred:
        if not isinstance(entry, dict):
            continue
        if entry.get("developerSignedOff") is not True:
            continue
        reason = entry.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            continue
        if entry.get("classification") not in ("plannedInNextRelease", "acceptedResidualRisk"):
            continue
        exp = parse_iso(entry.get("expiresAt"))
        if exp is None or exp <= now:
            continue
        domain = entry.get("domain")
        if isinstance(domain, str) and domain and domain not in non_waivable:
            print("DEFERRED|" + domain)

# Per-candidate deferral captured by prompt 03c (agent may write
# backgroundAuthorize.decisions[] only — not deferredDomains[]).
ba = data.get("backgroundAuthorize") or {}
if isinstance(ba, dict):
    for _d in ba.get("decisions") or []:
        if isinstance(_d, dict) and _d.get("intent") == "deferred":
            print("BA_PER_CANDIDATE_DEFERRED|backgroundAuthorize")
            break
PY
)"

    if [ -n "$BOOTSTRAP_META" ]; then
        DEFERRED_DOMAINS="$(printf '%s\n' "$BOOTSTRAP_META" | grep '^DEFERRED|' | sed 's/^DEFERRED|//')"
        if printf '%s\n' "$BOOTSTRAP_META" | grep -q '^BA_PER_CANDIDATE_DEFERRED|backgroundAuthorize'; then
            BACKGROUND_AUTHORIZE_PER_CANDIDATE_DEFERRED=true
        fi
    fi
fi
BACKGROUND_AUTHORIZE_PER_CANDIDATE_DEFERRED="${BACKGROUND_AUTHORIZE_PER_CANDIDATE_DEFERRED:-false}"

is_domain_nonwaivable() {
    local needle="$1"
    for d in $NON_WAIVABLE_DOMAINS; do
        [ "$d" = "$needle" ] && return 0
    done
    return 1
}

# Returns 0 if $1 is in the deferred set, 1 otherwise. Run this before
# emitting check_fail; on hit, emit check_warn instead with a "deferred"
# annotation so the developer sees the gap is intentional.
is_domain_deferred() {
    local needle="$1"
    is_domain_nonwaivable "$needle" && return 1
    if [ "$needle" = "backgroundAuthorize" ] && [ "$BACKGROUND_AUTHORIZE_PER_CANDIDATE_DEFERRED" = true ]; then
        return 0
    fi
    [ -z "$DEFERRED_DOMAINS" ] && return 1
    while IFS= read -r d; do
        [ "$d" = "$needle" ] && return 0
    done <<EOF
$DEFERRED_DOMAINS
EOF
    return 1
}

# Reads grep -rn style lines from stdin and returns the count of hits.
# The toolkit has no line-level suppression mechanism, so every hit
# counts. Lines carrying unknown audit tag variants are additionally
# flagged by the comment-audit phase below.
count_hits_for_domain() {
    local _domain="$1"  # retained for call-site compatibility; not used
    local line
    local count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        count=$((count + 1))
    done
    echo "$count"
}

# Convenience: emit a fail OR a warn depending on deferral status. Use
# instead of `[ "$N" -gt 0 ] && check_fail "..." || check_pass "..."`
# when the underlying domain may have been developer-deferred.
#
# Args: <domain> <message>
fail_or_defer() {
    local domain="$1"
    local message="$2"
    local fix="${3:-}"
    local files="${4:-}"
    _CURRENT_DOMAIN="$domain"
    _CURRENT_FIX="$fix"
    _CURRENT_FILES="$files"
    if is_domain_deferred "$domain"; then
        check_warn "$message [deferred — domain=$domain marked deferredDomains in bootstrap.json]"
    else
        check_fail "$message"
    fi
}

# Security-critical hard fail. Use for findings that violate the
# Dynamics secure-container contract and must NEVER be silently
# deferred (external storage writes, MediaStore writes to shared
# collections, raw /sdcard paths, etc.). Emits a standard check_fail
# tagged `[SECURITY-BLOCKER]` so:
#   - phase-10 / report generation can surface it under
#     releaseReadiness.blockingItems and (when present) under the
#     report's optional securityBlockers[] array;
#   - migration-report.json's recommendation must be `no-go` while at
#     least one such blocker is open;
#   - validator output is unambiguous to a third-party developer
#     reading the console log.
#
# A persistent record is appended to
# `dynamics-migration-tool/output/.security-blockers.log` (TSV:
# domain<TAB>surface<TAB>count<TAB>message) so prompt 10 / phase-report
# can replay blockers into the final report without re-running the
# scanner.
#
# Args: <domain> <surface-id> <count> <message>
security_blocker() {
    local domain="$1"
    local surface="$2"
    local count="$3"
    local message="$4"
    local fix="${5:-Migrate to com.good.gd.file.* container paths or remove the public-storage feature}"
    local tagged="[SECURITY-BLOCKER][$domain/$surface] $message"
    _CURRENT_DOMAIN="$domain"
    _CURRENT_FIX="$fix"
    # Always fail — bypass fail_or_defer entirely. Defence-in-depth:
    # even if a future caller adds `externalStorage` to the deferred
    # set, this helper never honours it.
    check_fail "$tagged"
    local log_dir="dynamics-migration-tool/output"
    [ -d "$log_dir" ] || mkdir -p "$log_dir" 2>/dev/null || true
    if [ -d "$log_dir" ]; then
        printf '%s\t%s\t%s\t%s\n' "$domain" "$surface" "$count" "$message" \
            >> "$log_dir/.security-blockers.log" 2>/dev/null || true
    fi
}

# BSD / macOS: treat // and leading * lines as comments so migration notes and
# KDoc do not trigger writer/reader heuristics or Room anti-pattern examples.
file_has_noncomment_ere_match() {
    local file="$1"
    local regex="$2"
    [ ! -f "$file" ] && return 1
    grep -nE "$regex" "$file" 2>/dev/null \
        | grep -Ev '^[0-9]+:[[:space:]]*//' \
        | grep -Ev '^[0-9]+:[[:space:]]*\*' \
        | grep -Ev '^[0-9]+:[[:space:]]*/\*' \
        | grep -q .
}

# Count regex hits while filtering comment-only lines and migration
# audit-noise tags. Accepts one or more roots/files after the regex.
# If no roots/files are provided, scans "$SRC_DIR/".
count_noncomment_ere_hits() {
    local regex="$1"
    shift || true
    if [ "$#" -eq 0 ]; then
        set -- "$SRC_DIR/"
    fi
    # shellcheck disable=SC2086
    grep -rnE "$regex" $* 2>/dev/null \
        | strip_audit_noise \
        | grep -Ev '^([^:]+:)?[0-9]+:[[:space:]]*//' \
        | grep -Ev '^([^:]+:)?[0-9]+:[[:space:]]*\*' \
        | grep -Ev '^([^:]+:)?[0-9]+:[[:space:]]*/\*' \
        | count_hits_for_domain "__internal__"
}

# Count files that contain at least one non-comment regex match.
# Accepts a regex and one or more roots/files. If omitted, scans "$SRC_DIR/".
count_files_with_noncomment_ere_match() {
    local regex="$1"
    shift || true
    if [ "$#" -eq 0 ]; then
        set -- "$SRC_DIR/"
    fi

    local files
    # shellcheck disable=SC2086
    files="$(grep -rlE "$regex" $* 2>/dev/null || true)"
    local count=0
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if file_has_noncomment_ere_match "$f" "$regex"; then
            count=$((count + 1))
        fi
    done <<EOF
$files
EOF
    echo "$count"
}

if [ -n "$DEFERRED_DOMAINS" ]; then
    echo "Deferred domains (per bootstrap.json):"
    while IFS= read -r d; do
        [ -n "$d" ] && echo "  - $d"
    done <<EOF
$DEFERRED_DOMAINS
EOF
    echo ""
fi

# ========================================
# Phase loop — sources tooling/phases/phase-<id>.sh in the canonical
# order documented in tooling/check-prompt-map.json. Each phase script
# inherits PASS/FAIL/WARN counters, helpers, and the module-map scope
# vars defined above; phases that are out of scope (because
# --check-prompt narrowed PHASES_ONLY_NORM) are skipped by
# should_run_phase without sourcing the script.
# ========================================
PHASE_ORDER=(0 1 2 3 3b 4 5 5b 6 6b 7 8 8b 9 10 11 12 comments catalog report)
for _phase in "${PHASE_ORDER[@]}"; do
    _phase_script="$SCRIPT_DIR/phases/phase-${_phase}.sh"
    if should_run_phase "$_phase"; then
        if [ ! -f "$_phase_script" ]; then
            echo "❌ Phase script missing: $_phase_script"
            echo "   The migration toolkit is incomplete — re-copy dynamics-migration-tool/."
            if [ "$CHECK_PROMPT_MODE" = true ]; then
                exit 2
            fi
            exit 1
        fi
        # shellcheck source=phases/phase-0.sh
        . "$_phase_script"
    fi
done
unset _phase _phase_script

# HR-0-5: independent evidence artifact + closure cross-check against
# agent-authored inventory. Runs after phase scans so rediscovery reflects
# the same in-scope source tree validators already walked.
INDEPENDENT_EVIDENCE_PY="$SCRIPT_DIR/lib/independent-evidence-scan.py"
EVIDENCE_CLOSURE_PY="$SCRIPT_DIR/lib/evidence-closure-check.py"
INDEPENDENT_EVIDENCE_FILE="$TOOL_DIR/output/.independent-evidence.json"
ANALYSIS_FILE="$TOOL_DIR/output/migration-analysis.json"
PLAN_STATE_FILE="$TOOL_DIR/output/migration-plan-state.json"
REPORT_FILE="$TOOL_DIR/output/migration-report.json"
evidence_domains_for_prompt() {
  case "$1" in
    04) echo "secureSql" ;;
    05a|05b|05c|05z) echo "secureFileStorage" ;;
    06) echo "secureNetworking" ;;
    07) echo "webview" ;;
    08) echo "icc" ;;
    09) echo "secureUiWidgets secureClipboard" ;;
    10) echo "__all__" ;;
    *)
      # Prompts like 03c / 11 do not own a direct evidence-domain closure.
      echo ""
      ;;
  esac
}
if [ "$VALIDATION_SCOPE" != "report" ] && [ -f "$INDEPENDENT_EVIDENCE_PY" ] && [ -d "$SRC_DIR_MM" ]; then
  _GRADLE_SCAN_ARGS=()
  for _gf in $MM_GRADLE_FILES \
      "$PROJECT_DIR/settings.gradle" \
      "$PROJECT_DIR/settings.gradle.kts" \
      "$PROJECT_DIR/gradle/libs.versions.toml" \
      "$PROJECT_DIR/libs.versions.toml"; do
    [ -f "$_gf" ] && _GRADLE_SCAN_ARGS+=(--gradle-file "$_gf")
  done
  python3 "$INDEPENDENT_EVIDENCE_PY" \
    --output "$INDEPENDENT_EVIDENCE_FILE" \
    --source-root "$SRC_DIR_MM" \
    "${_GRADLE_SCAN_ARGS[@]}" 2>/dev/null || true

  if [ -f "$EVIDENCE_CLOSURE_PY" ] && [ -f "$ANALYSIS_FILE" ]; then
  _CURRENT_DOMAIN="independentEvidence"
  _CURRENT_FIX="Re-run prompt 00 to inventory rediscovered surfaces, close dispositions, or record manualTodos[] with evidence before claiming domain closure."
  _EC_MODE="validator"
  _REPORT_ARG=()
  _EC_DOMAIN_ARGS=()
  _EC_SKIP=false
  _EC_PROMPT=""
  if [ "$CHECK_PROMPT_MODE" = true ]; then
    _EC_PROMPT="$CHECK_PROMPT_ID"
  elif [ "$VALIDATION_MODE" = "incremental" ] && [ -n "$INCR_PROMPT_ID" ]; then
    _EC_PROMPT="$INCR_PROMPT_ID"
  fi
  if [ -n "$_EC_PROMPT" ]; then
    _EC_DOMAINS="$(evidence_domains_for_prompt "$_EC_PROMPT")"
    if [ -z "$_EC_DOMAINS" ]; then
      _EC_SKIP=true
    elif [ "$_EC_DOMAINS" != "__all__" ]; then
      for _ec_dom in $_EC_DOMAINS; do
        _EC_DOMAIN_ARGS+=(--domain "$_ec_dom")
      done
    fi
  fi
  if [ "$VALIDATION_SCOPE" = "full" ] && [ -f "$REPORT_FILE" ]; then
    _EC_MODE="report"
    _REPORT_ARG=(--report "$REPORT_FILE")
  fi
  if [ "$_EC_SKIP" = false ]; then
    _EC_OUT="$(
      python3 "$EVIDENCE_CLOSURE_PY" \
        --mode "$_EC_MODE" \
        --evidence "$INDEPENDENT_EVIDENCE_FILE" \
        --analysis "$ANALYSIS_FILE" \
        --plan-state "$PLAN_STATE_FILE" \
        "${_EC_DOMAIN_ARGS[@]}" \
        "${_REPORT_ARG[@]}" 2>&1
    )" || true
    if [ -n "$_EC_OUT" ]; then
      while IFS= read -r _ec_line; do
        [ -z "$_ec_line" ] && continue
        case "$_ec_line" in
          WARN:\ *)
            check_warn "${_ec_line#WARN: }"
            ;;
          ERROR:\ *)
            check_fail "${_ec_line#ERROR: }"
            ;;
          *)
            check_fail "$_ec_line"
            ;;
        esac
      done <<< "$_EC_OUT"
    fi
  fi
  unset _EC_MODE _EC_OUT _REPORT_ARG _EC_DOMAIN_ARGS _EC_SKIP _EC_PROMPT _EC_DOMAINS _ec_dom _gf _GRADLE_SCAN_ARGS
  fi
fi

# ========================================
# Summary
# ========================================
echo "========================================="
echo "Summary"
echo "========================================="
echo "  ✅ Passed:   $PASS"
echo "  ❌ Failed:   $FAIL"
echo "  ⚠️  Warnings: $WARN"
echo ""

TOTAL=$((PASS + FAIL))
if [ $TOTAL -gt 0 ]; then
    PCT=$((PASS * 100 / TOTAL))
    echo "  Success Rate: $PCT%"
    echo ""
fi

# Domain summary: group failures by domain for quick triage.
if [ -s "$DOMAIN_FAIL_COUNTS_FILE" ]; then
    echo "Domain Summary (failures by domain):"
    echo "-----------------------------------------"
    sort "$DOMAIN_FAIL_COUNTS_FILE" | uniq -c | sort -rn | while read -r count domain; do
        echo "  $domain: $count failure(s)"
    done
    echo ""
fi

# Emit the per-run sidecar that record-prompt-execution.sh consumes when it
# invoked us through --check-prompt. We emit it on every full-sweep run too
# so prompt 10's recorder call can read the same structure.
emit_last_check_sidecar() {
    local exit_code="$1"
    local status_label="$2"
    local mode_label="$3"
    local prompt_id="$4"
    local phases="$5"
    local pass_n="$6"
    local fail_n="$7"
    local warn_n="$8"
    local scope_label="$9"
    local primary_out_path="${10}"
    local mirror_out_path="${11}"
    local source_sidecar="${12}"
    local out_dir="$TOOL_DIR/output"
    mkdir -p "$out_dir" 2>/dev/null || true
    EXIT_CODE="$exit_code" STATUS_LABEL="$status_label" MODE_LABEL="$mode_label" \
    PROMPT_ID="$prompt_id" PHASES_CSV="$phases" \
    PASS_N="$pass_n" FAIL_N="$fail_n" WARN_N="$warn_n" \
    START_MS="$VALIDATE_START_EPOCH_MS" OUT_PATH="$primary_out_path" \
    MIRROR_OUT_PATH="$mirror_out_path" \
    SIDECAR_SCOPE="$scope_label" \
    SOURCE_SIDECAR="$source_sidecar" \
    VALIDATION_RUN_ID="$VALIDATION_RUN_ID" \
    SELECTION_REASON="${SELECTION_REASON:-}" \
    CATALOG_VIOLATIONS="${CATALOG_VIOLATIONS_JSON:-}" \
    VIOLATIONS_FILE_PATH="$VIOLATIONS_FILE" \
    DOMAIN_FAIL_COUNTS_PATH="$DOMAIN_FAIL_COUNTS_FILE" \
    CHECK_PROMPT_MAP_PATH="$CHECK_PROMPT_MAP" \
    DIAGNOSTICS_CONTRACT_PY="$TOOL_DIR/tooling/lib/diagnostics-contract.py" \
        python3 - <<'PY'
import importlib.util
import json, os, time
from collections import Counter

start_ms = int(os.environ.get("START_MS") or 0)
now_ms = int(time.time() * 1000)
duration = max(0, now_ms - start_ms) if start_ms else 0
now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

phases_csv = os.environ.get("PHASES_CSV") or ""
phases = [p for p in phases_csv.split(",") if p]

violations = []

vf = os.environ.get("VIOLATIONS_FILE_PATH", "")
if vf and os.path.isfile(vf):
    with open(vf, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                v = json.loads(line)
                violations.append(v)
            except (json.JSONDecodeError, TypeError):
                pass

catalog_raw = os.environ.get("CATALOG_VIOLATIONS", "").strip()
if catalog_raw:
    try:
        catalog_violations = json.loads(catalog_raw)
        if isinstance(catalog_violations, list):
            for cv in catalog_violations:
                violations.append({
                    "phase": "catalog",
                    "category": "api-catalog-cross-check",
                    "severity": "fail",
                    "issue": cv.get("issue", "unknown"),
                    "catalogRow": cv.get("catalogRow"),
                    "originalApi": cv.get("originalApi"),
                    "replacementApi": cv.get("replacementApi"),
                    "files": cv.get("files"),
                    "fix": cv.get("remediation", ""),
                })
    except (json.JSONDecodeError, TypeError):
        pass

diagnostics_py = os.environ.get("DIAGNOSTICS_CONTRACT_PY", "")
if diagnostics_py and os.path.isfile(diagnostics_py):
    spec = importlib.util.spec_from_file_location("diagnostics_contract", diagnostics_py)
    if spec and spec.loader:
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        violations = mod.normalize_diagnostics(
            violations,
            platform="android",
            prompt_id=os.environ.get("PROMPT_ID") or "fullSweep",
            phases=phases,
            check_map=mod.load_json(os.environ.get("CHECK_PROMPT_MAP_PATH", "")),
        )

domain_counts = Counter()
df = os.environ.get("DOMAIN_FAIL_COUNTS_PATH", "")
if df and os.path.isfile(df):
    with open(df, "r") as fh:
        for line in fh:
            d = line.strip()
            if d:
                domain_counts[d] += 1

domain_summary = [{"domain": d, "failCount": c} for d, c in sorted(domain_counts.items())]

record = {
    "schemaVersion": "1.3.0",
    "diagnosticContractVersion": "1.0.0",
    "exitCode": int(os.environ.get("EXIT_CODE", "1")),
    "failCount": int(os.environ.get("FAIL_N", "0")),
    "generatedAt": now_iso,
    "mode": os.environ.get("MODE_LABEL", "fullSweep"),
    "passCount": int(os.environ.get("PASS_N", "0")),
    "phasesRun": phases,
    "promptId": os.environ.get("PROMPT_ID") or "fullSweep",
    "scope": os.environ.get("SIDECAR_SCOPE", "full"),
    "status": os.environ.get("STATUS_LABEL", "failed"),
    "validationRunId": os.environ.get("VALIDATION_RUN_ID") or "",
    "violations": violations,
    "warnCount": int(os.environ.get("WARN_N", "0")),
    "durationMs": duration,
}
if domain_summary:
    record["domainSummary"] = domain_summary
_sel = os.environ.get("SELECTION_REASON", "").strip()
if _sel:
    record["selectionReason"] = _sel
_source = os.environ.get("SOURCE_SIDECAR", "").strip()
if _source and record.get("scope") == "report":
    record["sourceSidecar"] = _source
if record["status"] == "failed":
    record["remediation"] = (
        "Read the human-readable failures printed above, fix the listed call "
        "sites, then re-invoke record-prompt-execution.sh. Do not record "
        "status=completed while violations are unresolved."
    )

def write_json(path):
    if not path:
        return
    with open(path, "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.write("\n")

out_path = os.environ.get("OUT_PATH", "")
mirror_path = os.environ.get("MIRROR_OUT_PATH", "")
write_json(out_path)
if mirror_path and mirror_path != out_path:
    write_json(mirror_path)
PY
}

loop_state_stage_for_scope() {
    local scope_label="$1"
    case "$scope_label" in
        source) echo "source-gate" ;;
        report) echo "report-gate" ;;
        *) echo "validation" ;;
    esac
}

record_loop_state_from_sidecar() {
    local result_label="$1"
    local prompt_id="$2"
    local sidecar_path="$3"
    local stage_label="$4"
    [ -f "$LOOP_STATE_SH" ] || return 0

    local _loop_out=""
    local _loop_rc=0
    set +e
    _loop_out="$(
        bash "$LOOP_STATE_SH" record \
            --prompt-id "$prompt_id" \
            --stage "$stage_label" \
            --result "$result_label" \
            --sidecar "$sidecar_path" \
            --validation-run-id "$VALIDATION_RUN_ID" \
            --owner-prompt "$prompt_id" \
            --safe-next-action "rerun-owner-prompt" 2>/dev/null
    )"
    _loop_rc=$?
    set -e

    if [ "$_loop_rc" -eq 3 ]; then
        echo "ESCALATION REQUIRED: retry budget exhausted for prompt=$prompt_id stage=$stage_label." >&2
        [ -n "$_loop_out" ] && echo "$_loop_out" >&2
        return 3
    fi
    return 0
}

if [ -n "$VALIDATION_MODE" ]; then
    # --mode incremental|full|final|final-source|report.
    SIDECAR_MODE="$VALIDATION_MODE"
    SIDECAR_SCOPE="$VALIDATION_SCOPE"
    SIDECAR_PRIMARY_PATH="$LAST_CHECK_FILE"
    SIDECAR_MIRROR_PATH=""
    SIDECAR_SOURCE_POINTER=""
    if [ "$VALIDATION_MODE" = "incremental" ] \
            && [ -n "$VALIDATION_PLAN_FILE" ] \
            && [ -f "$VALIDATION_PLAN_FILE" ]; then
        _FALLBACK_FULL="$(
            PLAN="$VALIDATION_PLAN_FILE" python3 -c \
                'import json, os; print("yes" if json.load(open(os.environ["PLAN"])).get("fallbackFull") else "no")'
        )"
        if [ "$_FALLBACK_FULL" = "yes" ]; then
            SIDECAR_MODE="full"
        fi
    fi
    if [ "$VALIDATION_MODE" = "final-source" ]; then
        SIDECAR_PRIMARY_PATH="$LAST_SOURCE_CHECK_FILE"
        SIDECAR_MIRROR_PATH="$LAST_CHECK_FILE"
    elif [ "$VALIDATION_MODE" = "report" ]; then
        SIDECAR_PRIMARY_PATH="$LAST_REPORT_CHECK_FILE"
        SIDECAR_MIRROR_PATH="$LAST_CHECK_FILE"
        SIDECAR_SOURCE_POINTER="dynamics-migration-tool/output/.last-source-check.json"
    fi
    if [ -n "$INCR_PROMPT_ID" ]; then
        SIDECAR_PROMPT_ID="$INCR_PROMPT_ID"
    else
        SIDECAR_PROMPT_ID="$VALIDATION_MODE"
    fi
elif [ "$CHECK_PROMPT_MODE" = true ]; then
    if [ "$CHECK_PROMPT_MODE_LABEL" = "SCOPED" ]; then
        SIDECAR_MODE="scoped"
    else
        SIDECAR_MODE="fullSweep"
    fi
    SIDECAR_SCOPE="full"
    SIDECAR_PRIMARY_PATH="$LAST_CHECK_FILE"
    SIDECAR_MIRROR_PATH=""
    SIDECAR_SOURCE_POINTER=""
    SIDECAR_PROMPT_ID="$CHECK_PROMPT_ID"
else
    SIDECAR_MODE="fullSweep"
    SIDECAR_SCOPE="full"
    SIDECAR_PRIMARY_PATH="$LAST_CHECK_FILE"
    SIDECAR_MIRROR_PATH=""
    SIDECAR_SOURCE_POINTER=""
    SIDECAR_PROMPT_ID="fullSweep"
fi
SIDECAR_PHASES_CSV="${PHASES_ONLY_NORM:-0,1,2,3,3b,4,5,5b,6,6b,7,8,8b,9,10,11,12,comments,catalog,report}"
LOOP_STATE_STAGE="$(loop_state_stage_for_scope "$SIDECAR_SCOPE")"

if [ $FAIL -eq 0 ]; then
    emit_last_check_sidecar 0 "passed" "$SIDECAR_MODE" "$SIDECAR_PROMPT_ID" "$SIDECAR_PHASES_CSV" "$PASS" "$FAIL" "$WARN" "$SIDECAR_SCOPE" "$SIDECAR_PRIMARY_PATH" "$SIDECAR_MIRROR_PATH" "$SIDECAR_SOURCE_POINTER"
    observability_event \
        --operation-type validation-run \
        --prompt-id "$SIDECAR_PROMPT_ID" \
        --phase "$SIDECAR_PHASES_CSV" \
        --status passed \
        --start-ms "$VALIDATE_START_EPOCH_MS" \
        --metadata-json "{\"mode\":\"$SIDECAR_MODE\",\"scope\":\"$SIDECAR_SCOPE\",\"passCount\":$PASS,\"failCount\":$FAIL,\"warnCount\":$WARN,\"validationRunId\":\"$VALIDATION_RUN_ID\"}"
    record_loop_state_from_sidecar "passed" "$SIDECAR_PROMPT_ID" "$SIDECAR_PRIMARY_PATH" "$LOOP_STATE_STAGE" || true
    echo "🎉 Migration validation PASSED!"
    echo ""
    echo "Next steps:"
    echo "  1. Review any warnings above"
    echo "  2. Test authorization flow with UEM"
    echo "  3. Verify secure APIs work at runtime"
    exit 0
else
    emit_last_check_sidecar 1 "failed" "$SIDECAR_MODE" "$SIDECAR_PROMPT_ID" "$SIDECAR_PHASES_CSV" "$PASS" "$FAIL" "$WARN" "$SIDECAR_SCOPE" "$SIDECAR_PRIMARY_PATH" "$SIDECAR_MIRROR_PATH" "$SIDECAR_SOURCE_POINTER"
    observability_event \
        --operation-type validation-run \
        --prompt-id "$SIDECAR_PROMPT_ID" \
        --phase "$SIDECAR_PHASES_CSV" \
        --status failed \
        --start-ms "$VALIDATE_START_EPOCH_MS" \
        --metadata-json "{\"mode\":\"$SIDECAR_MODE\",\"scope\":\"$SIDECAR_SCOPE\",\"passCount\":$PASS,\"failCount\":$FAIL,\"warnCount\":$WARN,\"validationRunId\":\"$VALIDATION_RUN_ID\"}"
    if ! record_loop_state_from_sidecar "failed" "$SIDECAR_PROMPT_ID" "$SIDECAR_PRIMARY_PATH" "$LOOP_STATE_STAGE"; then
        exit 3
    fi
    echo "❌ Migration validation FAILED"
    echo ""

    if [ "${FIX_SUGGESTIONS:-}" = true ] && [ -s "$VIOLATIONS_FILE" ]; then
        echo "========================================="
        echo "  FIX SUGGESTIONS"
        echo "========================================="
        python3 - "$VIOLATIONS_FILE" <<'PY'
import json, sys

vf = sys.argv[1]
entries = []
with open(vf) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except (json.JSONDecodeError, TypeError):
            pass

fails = [e for e in entries if e.get("severity") == "fail" and e.get("fix")]
if not fails:
    print("  No actionable fix suggestions available.")
    print("  Review the failure messages above for manual remediation.")
else:
    by_domain = {}
    for e in fails:
        d = e.get("domain") or "general"
        by_domain.setdefault(d, []).append(e)
    idx = 1
    for domain in sorted(by_domain):
        print(f"\n  [{domain}]")
        seen_fixes = set()
        for e in by_domain[domain]:
            fix = e["fix"]
            if fix in seen_fixes:
                continue
            seen_fixes.add(fix)
            msg = e.get("message", "").split(" — ")[0][:80]
            print(f"    {idx}. {msg}")
            print(f"       FIX: {fix}")
            if e.get("files"):
                print(f"       FILES: {e['files']}")
            idx += 1
print()
PY
        echo ""
    fi

    echo "Next steps:"
    echo "  1. Review failed checks above"
    if [ "${FIX_SUGGESTIONS:-}" != true ]; then
        echo "  TIP: Re-run with --fix-suggestions for actionable fix instructions"
    fi
    echo "  2. Re-run the relevant migration prompt with your AI agent against the existing migrated tree"
    echo "     (for secureFileStorage findings, start with prompt 05a; do not restart from 00pre unless required)"
    echo "  3. Check dynamics-migration-tool/steering/95-troubleshooting.md"
    exit 1
fi

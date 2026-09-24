#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TOOL_DIR/.." && pwd)"
OUTPUT_DIR="$TOOL_DIR/output"
RECORDER="$TOOL_DIR/tooling/record-prompt-execution.sh"
HELPER="$TOOL_DIR/tooling/lib/repair-orchestrator.py"
LOOP_STATE_SH="$TOOL_DIR/tooling/loop-state.sh"
LAST_CHECK="$OUTPUT_DIR/.last-check.json"

PROMPT_ID=""
STATUS="completed"
MAX_PROMPT_ATTEMPTS=3
MAX_DIAGNOSTIC_ATTEMPTS=2
RUN_BUDGET=10
MATURITY_LEVEL="maturing"
CONTROLLED_PROMPTS="01,02,03,03b,04,04b,04c,05,06,07,08,09,09b,11"

usage() {
    cat <<'EOF'
Usage: bash dynamics-migration-tool/tooling/repair-orchestrator.sh --prompt-id <id> [options]

Options:
  --prompt-id <id>                 Controlled prompt to record/verify
  --status <status>                Recorder status (default: completed)
  --max-prompt-attempts <n>        Per-prompt repair budget (default: 3)
  --max-diagnostic-attempts <n>    Per-diagnostic repair budget (default: 2)
  --run-budget <n>                 Run-wide repair budget (default: 10)
  --controlled-prompts <csv>       Explicit prompt allow-list (default: implementation/configuration prompts)
  --maturity-level <level>         Maturity marker written to state (default: maturing)
  --help                           Show usage

The orchestrator does not edit source code. It wraps the existing recorder and
validator gates, then writes output/repair-task.json and output/repair-task.md
when a bounded repair task is required.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt-id) PROMPT_ID="${2:-}"; shift 2 ;;
        --status) STATUS="${2:-}"; shift 2 ;;
        --max-prompt-attempts) MAX_PROMPT_ATTEMPTS="${2:-}"; shift 2 ;;
        --max-diagnostic-attempts) MAX_DIAGNOSTIC_ATTEMPTS="${2:-}"; shift 2 ;;
        --run-budget) RUN_BUDGET="${2:-}"; shift 2 ;;
        --controlled-prompts) CONTROLLED_PROMPTS="${2:-}"; shift 2 ;;
        --maturity-level) MATURITY_LEVEL="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$PROMPT_ID" ]]; then
    echo "ERROR: --prompt-id is required" >&2
    usage >&2
    exit 2
fi

case ",$CONTROLLED_PROMPTS," in
    *",$PROMPT_ID,"*) ;;
    *)
        echo "ERROR: prompt '$PROMPT_ID' is outside the controlled Stage 7 subset: $CONTROLLED_PROMPTS" >&2
        exit 2
        ;;
esac

if [[ ! -f "$RECORDER" || ! -f "$HELPER" ]]; then
    echo "ERROR: repair orchestrator dependencies are missing" >&2
    exit 2
fi

set +e
bash "$RECORDER" --prompt-id "$PROMPT_ID" --status "$STATUS"
RECORDER_RC=$?
set -e

if [[ $RECORDER_RC -eq 0 ]]; then
    python3 "$HELPER" \
        --platform ios \
        --event success \
        --prompt-id "$PROMPT_ID" \
        --output-dir "$OUTPUT_DIR" \
        --project-root "$PROJECT_ROOT" \
        --max-prompt-attempts "$MAX_PROMPT_ATTEMPTS" \
        --max-diagnostic-attempts "$MAX_DIAGNOSTIC_ATTEMPTS" \
        --run-budget "$RUN_BUDGET" \
        --maturity-level "$MATURITY_LEVEL" \
        --controlled-prompts "$CONTROLLED_PROMPTS"
    exit 0
fi

python3 "$HELPER" \
    --platform ios \
    --event failure \
    --prompt-id "$PROMPT_ID" \
    --sidecar "$LAST_CHECK" \
    --output-dir "$OUTPUT_DIR" \
    --project-root "$PROJECT_ROOT" \
    --max-prompt-attempts "$MAX_PROMPT_ATTEMPTS" \
    --max-diagnostic-attempts "$MAX_DIAGNOSTIC_ATTEMPTS" \
    --run-budget "$RUN_BUDGET" \
    --maturity-level "$MATURITY_LEVEL" \
    --controlled-prompts "$CONTROLLED_PROMPTS" \
    --loop-state-sh "$LOOP_STATE_SH"
exit $?

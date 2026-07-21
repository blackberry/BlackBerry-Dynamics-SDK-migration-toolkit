#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOOP_STATE_PY="$SCRIPT_DIR/lib/loop-state.py"
LOOP_STATE_FILE="$TOOL_DIR/output/migration-loop-state.json"
BOOTSTRAP_FILE="$TOOL_DIR/output/bootstrap.json"
CHECK_PROMPT_MAP="$TOOL_DIR/tooling/check-prompt-map.json"
# shellcheck source=lib/toolkit-version.sh
. "$SCRIPT_DIR/lib/toolkit-version.sh"
toolkit_version_load "$TOOL_DIR"

usage() {
    cat <<USAGE
Usage: bash dynamics-migration-tool/tooling/loop-state.sh <record|terminal> [options]

Options:
  --prompt-id <id>            Prompt id (required)
  --stage <name>              validation|source-gate|report-gate|closure-gate|recorder-gate (required)
  --result <name>             passed|failed|configuration-error|environment-error (required)
  --sidecar <path>            Optional sidecar path
  --validation-run-id <id>    Optional validator run id (dedup key)
  --gate-id <id>              Optional recorder gate identifier
  --message <text>            Optional failure/escalation message
  --owner-prompt <id>         Optional owner prompt for repair feedback
  --failing-phase <id>        Optional failing phase id
  --failing-domain <name>     Optional failing domain id
  --suggested-command <cmd>   Optional next command hint
  --safe-next-action <value>  Optional action enum (default rerun-owner-prompt)
  --terminal-outcome <value>  For terminal: success|blocked|escalated|cancelled|aborted
  --terminal-reason <text>    Optional terminal reason
  --help                      Show usage
USAGE
}

[ $# -gt 0 ] || { usage >&2; exit 2; }
COMMAND="$1"
shift

case "$COMMAND" in
    record|terminal) ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown command: $COMMAND" >&2; usage >&2; exit 2 ;;
esac

if [ ! -f "$LOOP_STATE_PY" ]; then
    echo "loop-state helper missing: $LOOP_STATE_PY" >&2
    exit 2
fi

exec python3 "$LOOP_STATE_PY" \
    --event "$COMMAND" \
    --platform ios \
    --bootstrap "$BOOTSTRAP_FILE" \
    --check-map "$CHECK_PROMPT_MAP" \
    --loop-file "$LOOP_STATE_FILE" \
    --toolkit-version "$TOOL_VERSION" \
    "$@"

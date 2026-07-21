#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$TOOL_DIR/output"
HELPER="$TOOL_DIR/tooling/lib/runtime-evidence.py"

usage() {
    cat <<'EOF'
Usage: bash dynamics-migration-tool/tooling/runtime-evidence.sh <init-template|validate|summary>

Commands:
  init-template  Create output/runtime-evidence.json template if missing
  validate       Validate output/runtime-evidence.json
  summary        Validate and print compact JSON summary
EOF
}

COMMAND="${1:-}"
case "$COMMAND" in
    init-template) ARGS=(--init-template) ;;
    validate) ARGS=(--validate) ;;
    summary) ARGS=(--summary) ;;
    --help|-h|"") usage; exit 0 ;;
    *) echo "Unknown command: $COMMAND" >&2; usage >&2; exit 2 ;;
esac

if [[ ! -f "$HELPER" ]]; then
    echo "ERROR: runtime evidence helper missing: $HELPER" >&2
    exit 2
fi

python3 "$HELPER" --platform ios --output-dir "$OUTPUT_DIR" "${ARGS[@]}"

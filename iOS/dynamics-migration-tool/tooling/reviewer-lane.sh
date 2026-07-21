#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TOOL_DIR/.." && pwd)"
HELPER="$TOOL_DIR/tooling/lib/reviewer-lane.py"

usage() {
    cat <<'EOF'
Usage: bash dynamics-migration-tool/tooling/reviewer-lane.sh [--help]

Generates read-only risk-based reviewer lane artifacts:
  output/reviewer-lane.json
  output/reviewer-lane.md

Reviewer findings are advisory and never override deterministic validators.
EOF
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

if [[ ! -f "$HELPER" ]]; then
    echo "ERROR: reviewer lane helper missing: $HELPER" >&2
    exit 2
fi

python3 "$HELPER" --platform ios --project-root "$PROJECT_ROOT" --tool-dir "$TOOL_DIR"

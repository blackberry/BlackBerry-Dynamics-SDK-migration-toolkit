#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TOOL_DIR/.." && pwd)"
HELPER="$TOOL_DIR/tooling/lib/improvement-backlog.py"

usage() {
    cat <<'EOF'
Usage: bash dynamics-migration-tool/tooling/improvement-backlog.sh

Generates:
  output/migration-improvement-backlog.json
  output/migration-improvement-backlog.md

The backlog is advisory only. It does not modify prompts, steering, validators,
schemas, or application source.
EOF
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    "") ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

if [[ ! -f "$HELPER" ]]; then
    echo "ERROR: improvement backlog helper missing: $HELPER" >&2
    exit 2
fi

python3 "$HELPER" --platform ios --project-root "$PROJECT_ROOT" --tool-dir "$TOOL_DIR"

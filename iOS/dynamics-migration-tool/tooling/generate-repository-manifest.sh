#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TOOL_DIR/.." && pwd)"
MANIFEST_PY="$TOOL_DIR/tooling/lib/repository-manifest.py"
OUTPUT_FILE="$TOOL_DIR/output/repository-manifest.json"
SUMMARY_FILE="$TOOL_DIR/output/context-summary.md"
RUN_ID=""

usage() {
    cat <<'EOF'
Usage: bash dynamics-migration-tool/tooling/generate-repository-manifest.sh [options]

Options:
  --project-root <path>   Project root to scan (default: parent of dynamics-migration-tool)
  --run-id <id>           Optional migration run id
  --output <path>         Manifest output path
  --summary-output <path> Context summary output path
  --help                  Show this message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-root) PROJECT_ROOT="$(cd "${2:-}" && pwd)"; shift 2 ;;
        --run-id) RUN_ID="${2:-}"; shift 2 ;;
        --output) OUTPUT_FILE="${2:-}"; shift 2 ;;
        --summary-output) SUMMARY_FILE="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; usage; exit 2 ;;
    esac
done

if [[ ! -f "$MANIFEST_PY" ]]; then
    echo "ERROR: repository manifest helper missing: $MANIFEST_PY" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUTPUT_FILE")" "$(dirname "$SUMMARY_FILE")"
python3 "$MANIFEST_PY" \
    --project-root "$PROJECT_ROOT" \
    --tool-dir "$TOOL_DIR" \
    --platform ios \
    --run-id "$RUN_ID" \
    --output "$OUTPUT_FILE" \
    --summary-output "$SUMMARY_FILE"

echo "Repository manifest written: $OUTPUT_FILE"
echo "Context summary written: $SUMMARY_FILE"

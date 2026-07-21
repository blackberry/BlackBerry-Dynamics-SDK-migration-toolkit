#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$TOOL_DIR/tooling/lib/release-assessment.py"
BENCHMARK_DIR=""

usage() {
    cat <<'EOF'
Usage: bash dynamics-migration-tool/tooling/release-assessment.sh [--benchmark-dir <dir>]

Generates:
  output/loop-evolution-benchmark.md
  output/loop-readiness-assessment.json
  output/loop-readiness-assessment.md

Benchmark case JSON files are optional inputs. Without representative Tier A/B
cases, the assessment reports further hardening rather than claiming readiness.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --benchmark-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --benchmark-dir requires a value" >&2
                exit 2
            fi
            BENCHMARK_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! -f "$HELPER" ]]; then
    echo "ERROR: release assessment helper missing: $HELPER" >&2
    exit 2
fi

args=(--platform ios --tool-dir "$TOOL_DIR")
if [[ -n "$BENCHMARK_DIR" ]]; then
    args+=(--benchmark-dir "$BENCHMARK_DIR")
fi

python3 "$HELPER" "${args[@]}"

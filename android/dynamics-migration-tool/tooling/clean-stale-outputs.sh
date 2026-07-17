#!/usr/bin/env bash
# Remove known migration output files from a prior run (never the output/ directory).
#
# Usage (from project root):
#   bash dynamics-migration-tool/tooling/clean-stale-outputs.sh
#
# First run: only bootstrap.json / .gitkeep may exist — this is a no-op.

set -euo pipefail

STALE_OUTPUTS=(
  "dynamics-migration-tool/output/migration-analysis.json"
  "dynamics-migration-tool/output/migration-report.json"
  "dynamics-migration-tool/output/migration-plan-state.json"
  "dynamics-migration-tool/_maintainer/output/tool-analysis-report.json"
  "dynamics-migration-tool/output/architecture-diagrams.md"
  "dynamics-migration-tool/output/.security-blockers.log"
  "dynamics-migration-tool/output/.last-check.json"
  "dynamics-migration-tool/output/.last-source-check.json"
  "dynamics-migration-tool/output/.last-report-check.json"
  "dynamics-migration-tool/output/migration-loop-state.json"
  "dynamics-migration-tool/output/.independent-evidence.json"
  "dynamics-migration-tool/output/.mm-fallback.json"
)

mkdir -p dynamics-migration-tool/output

removed=()
for p in "${STALE_OUTPUTS[@]}"; do
  if [ -e "$p" ]; then
    rm -f "$p"
    removed+=("$p")
  fi
done

if [ "${#removed[@]}" -gt 0 ]; then
  echo "Removed ${#removed[@]} stale migration output(s) from a prior run:"
  printf '  %s\n' "${removed[@]}"
else
  echo "No stale migration outputs to remove (first run or already clean)."
fi

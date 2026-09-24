#!/bin/bash
# BlackBerry Dynamics Migration — List required call-site dispositions
#
# Reads migration-analysis.json and migration-plan-state.json and prints
# every required call-site ID for closure-gated prompts (04, 05z, 06, 08,
# 09) together with the disposition status already recorded (or <missing>).
#
# Usage:
#   bash dynamics-migration-tool/tooling/list-required-dispositions.sh
#   bash dynamics-migration-tool/tooling/list-required-dispositions.sh --domain icc
#   bash dynamics-migration-tool/tooling/list-required-dispositions.sh --domain secureClipboard
#
# Exit codes:
#   0  all required dispositions are present and valid
#   1  one or more dispositions are missing or have an invalid status
#   2  argument / file error
#
# The --domain filter is optional; omit it to list all domains.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$TOOL_DIR/output"
ANALYSIS_FILE="$OUT_DIR/migration-analysis.json"
PLAN_STATE_FILE="$OUT_DIR/migration-plan-state.json"

DOMAIN_FILTER=""

usage() {
    cat <<USAGE
Usage: bash dynamics-migration-tool/tooling/list-required-dispositions.sh [--domain <domain>]

Options:
  --domain <domain>  Filter output to a specific closure-gated domain.
                     Valid values: secureSql, secureFileStorage, secureNetworking,
                                   icc, secureUiWidgets, secureClipboard
  --help             This message

Reads migration-analysis.json and migration-plan-state.json and prints each
required call-site ID together with its recorded disposition status.

Exit 0  — all required dispositions are present and valid.
Exit 1  — one or more dispositions are missing or invalid.
Exit 2  — argument or file error.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)  DOMAIN_FILTER="$2"; shift 2 ;;
        --help)    usage; exit 0 ;;
        *)         echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ ! -f "$ANALYSIS_FILE" ]; then
    echo "❌ migration-analysis.json not found at $ANALYSIS_FILE" >&2
    echo "   Run prompt 00-analyze-app.md first." >&2
    exit 2
fi

DOMAIN_FILTER="$DOMAIN_FILTER" \
ANALYSIS_FILE="$ANALYSIS_FILE" \
PLAN_STATE_FILE="$PLAN_STATE_FILE" \
python3 - <<'PY'
import json
import os
import sys

analysis_path = os.environ["ANALYSIS_FILE"]
plan_state_path = os.environ["PLAN_STATE_FILE"]
domain_filter = os.environ.get("DOMAIN_FILTER", "").strip()

CLOSURE_PROMPTS = frozenset({"04", "05z", "06", "08", "09"})
VALID_DOMAINS = ("secureSql", "secureFileStorage", "secureNetworking",
                 "icc", "secureUiWidgets", "secureClipboard")
ALLOWED_STATUS = frozenset({"migrated", "removed"})

if domain_filter and domain_filter not in VALID_DOMAINS:
    print(
        f"❌ Unknown domain {domain_filter!r}. "
        f"Valid values: {', '.join(VALID_DOMAINS)}",
        file=sys.stderr,
    )
    sys.exit(2)

try:
    with open(analysis_path, encoding="utf-8") as f:
        analysis = json.load(f)
except Exception as exc:
    print(f"❌ {analysis_path}: {exc}", file=sys.stderr)
    sys.exit(2)

plan_state = {}
if os.path.isfile(plan_state_path):
    try:
        with open(plan_state_path, encoding="utf-8") as f:
            plan_state = json.load(f)
    except Exception as exc:
        print(f"❌ {plan_state_path}: {exc}", file=sys.stderr)
        sys.exit(2)

# Build disposition lookup: (domain, callSiteId) -> status
dispositions = plan_state.get("dispositions") or []
by_key = {}
for d in dispositions:
    if isinstance(d, dict):
        by_key[(d.get("domain"), d.get("callSiteId"))] = d.get("status", "<unknown>")

# Collect required rows from executionPlan
rows = []  # (domain, promptId, callSiteId, disposition_status, file, line, kind)
for row in analysis.get("executionPlan") or []:
    if not isinstance(row, dict):
        continue
    if row.get("applicable") is not True:
        continue
    prompt_id = row.get("promptId", "")
    if prompt_id not in CLOSURE_PROMPTS:
        continue
    domain = row.get("domain", "")
    if domain_filter and domain != domain_filter:
        continue
    call_sites = row.get("callSites")
    if call_sites is None:
        print(
            f"⚠️  domain={domain!r} (prompt {prompt_id}): callSites[] key missing — "
            "re-run prompt 00-analyze-app.md (schemaVersion 1.2.0 required).",
        )
        continue
    for cs in call_sites:
        if not isinstance(cs, dict):
            continue
        cid = cs.get("id", "")
        status = by_key.get((domain, cid), "<missing>")
        rows.append((domain, prompt_id, cid, status, cs.get("file", ""), cs.get("line", "?"), cs.get("kind", "")))

if not rows:
    if domain_filter:
        print(f"No applicable call sites found for domain={domain_filter!r}.")
    else:
        print("No applicable call sites found for closure-gated prompts (04/05z/06/08/09).")
    sys.exit(0)

# Sort: domain order first, then by callSiteId
DOMAIN_ORDER = ["secureSql", "secureFileStorage", "secureNetworking",
                "icc", "secureUiWidgets", "secureClipboard"]
rows.sort(key=lambda r: (DOMAIN_ORDER.index(r[0]) if r[0] in DOMAIN_ORDER else 99, r[2]))

# Print table
col_domain  = 22
col_status  = 12
col_id      = 48
header = f"{'DOMAIN':<{col_domain}} {'STATUS':<{col_status}} {'CALL-SITE-ID':<{col_id}} FILE:LINE  (KIND)"
print(header)
print("-" * (len(header) + 4))

all_closed = True
for domain, prompt_id, cid, status, file_, line, kind in rows:
    ok = status in ALLOWED_STATUS
    marker = "✅" if ok else "❌"
    print(
        f"{domain:<{col_domain}} {status:<{col_status}} {cid:<{col_id}} "
        f"{file_}:{line}  ({kind})  {marker}"
    )
    if not ok:
        all_closed = False

print()
if all_closed:
    print("✅ All required call-site dispositions are recorded and valid.")
    sys.exit(0)

# Summary of what is missing
missing = [r for r in rows if r[3] == "<missing>"]
invalid = [r for r in rows if r[3] not in ("<missing>",) | ALLOWED_STATUS]

parts = []
if missing:
    parts.append(f"{len(missing)} missing")
if invalid:
    parts.append(f"{len(invalid)} invalid status")
print(f"⚠️  {', '.join(parts)} — add entries to migration-plan-state.json dispositions[]")
print()
print("Expected disposition shape:")
print('  {')
print('    "callSiteId": "<exact id from the CALL-SITE-ID column above>",')
print('    "domain":     "<exact domain from the DOMAIN column above>",')
print('    "status":     "migrated",   // or "removed"')
print('    "module":     "<module path from module-map.json, e.g. app>",  // optional')
print('    "note":       "<brief description of what changed>"  // optional')
print('  }')
print()
print("CRITICAL — do NOT create custom top-level keys:")
print('  ❌  {"iccDispositions": [...]}')
print('  ❌  {"clipboardDispositions": [...]}')
print('  ✅  {"dispositions": [...]}   ← correct: all domains share this array')
sys.exit(1)
PY

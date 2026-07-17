# BlackBerry Dynamics Migration — validator phase 3b
#
# Sourced by tooling/validate.sh once should_run_phase "3b" passes.
# Inherits PASS/FAIL/WARN counters, helpers (check_pass/check_fail/
# check_warn, fail_or_defer, strip_audit_noise, NATIVE_SCAN_PY, …)
# and the module-map scope vars from the parent shell.
#
# Do not edit the inner body without preserving validation semantics
# (see docs/android-dynamics-migration-tool-production-readiness-review.md
# and the per-domain steering files for what each check enforces).
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2086,SC2046,SC2016

    # ========================================
    # Phase 3b: Background Authorize
    # ========================================
    # Source of truth: bootstrap.json.processModel.backgroundEntryPoints[].
    # For each entry, locate the source file and confirm the canonical
    # canAuthorizeAutonomously -> serviceInit handshake is present and
    # gates secure API access. Also verifies
    # com.blackberry.dynamics.settings.json carries
    # GDEnableBackgroundAuthorize: true when the list is non-empty.
    # Reads bootstrap.backgroundAuthorize.decisions[] and processes
    # each candidate by intent: migrate -> strict structural check,
    # deferred -> fail_or_defer (matching deferredDomains[] entry
    # downgrades to check_warn), not-applicable -> audit pass.
    # Pre-capture state returns PENDING (informational) — prompt 10
    # gates report generation via backgroundAuthorizeDecisionsCaptured.
    echo "Phase 3b: Background Authorize"
    echo "-----------------------------------------"

if [ ! -f "$BOOTSTRAP_FILE" ]; then
    check_warn "bootstrap.json not found — Background Authorize enforcement skipped; run 00pre-bootstrap.md"
else
    export MM_SETTINGS_JSON_TARGETS_P3B="$MM_SETTINGS_JSON_TARGETS"
    export MM_IN_SCOPE_SOURCE_ROOTS_P3B="$MM_IN_SCOPE_SOURCE_ROOTS"
    export SRC_DIR_P3B="$SRC_DIR"
    PHASE3B_RESULT=$(python3 - "$BOOTSTRAP_FILE" <<'PY' 2>/dev/null
import json
import os
import re
import sys

bootstrap_path = sys.argv[1]
project_root = os.getcwd()
settings_targets = [
    t.strip()
    for t in os.environ.get("MM_SETTINGS_JSON_TARGETS_P3B", "").split()
    if t.strip()
]
walk_roots = [
    r.strip()
    for r in os.environ.get("MM_IN_SCOPE_SOURCE_ROOTS_P3B", "").split()
    if r.strip()
]
src_dir_fallback = os.environ.get("SRC_DIR_P3B", "").strip()
if not walk_roots and src_dir_fallback:
    walk_roots = [src_dir_fallback]
if not walk_roots:
    walk_roots = [project_root]

try:
    with open(bootstrap_path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR|cannot read bootstrap.json: {e}")
    sys.exit(0)

pm = data.get("processModel") or {}
bgs = pm.get("backgroundEntryPoints") or []
ba = data.get("backgroundAuthorize") or {}
decisions = ba.get("decisions") or []
# Build a quick lookup from candidate name -> decision dict.
decisions_by_name = {d.get("name"): d for d in decisions if isinstance(d, dict)}

if not bgs:
    print("NA|no background entry points")
    sys.exit(0)

# Until prompt 03c captures decisions, Phase 3b returns PENDING for manual
# scoped diagnostics. Prompt 10's gate enforces capture before report
# generation.
if not decisions_by_name:
    print(f"PENDING|{len(bgs)} candidate(s) await developer intent — run prompt 03c (background-authorize)")
    sys.exit(0)

# Build a (short class name)->[(path, head_text)] index across each
# in-scope source root (mirrors the module-map driven scan used by
# other phases). Skip build outputs and the toolkit own working
# directory.
SKIP_DIRS = {"build", "node_modules", ".gradle", ".git", "out", "intermediates", "dynamics-migration-tool"}
index = {}
for root in walk_roots:
    abs_root = root if os.path.isabs(root) else os.path.join(project_root, root)
    if not os.path.isdir(abs_root):
        continue
    for dp, dns, files in os.walk(abs_root):
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        for fn in files:
            if not fn.endswith((".java", ".kt")):
                continue
            ap = os.path.join(dp, fn)
            try:
                with open(ap, encoding="utf-8", errors="replace") as f:
                    head = f.read(16384)
            except OSError:
                continue
            m = re.search(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)", head)
            if not m:
                continue
            index.setdefault(m.group(1), []).append((ap, head))

def short(fqcn):
    return fqcn.rsplit(".", 1)[-1]

def find_source(fqcn):
    sname = short(fqcn)
    for ap, head in index.get(sname, []):
        pkg_m = re.search(r"^\s*package\s+([\w\.]+)", head, re.MULTILINE)
        pkg = pkg_m.group(1) if pkg_m else ""
        if not pkg or fqcn == f"{pkg}.{sname}":
            try:
                with open(ap, encoding="utf-8", errors="replace") as f:
                    body = f.read()
                return ap, body
            except OSError:
                return None, None
    return None, None

SECURE_TOKENS = (
    "GDFileSystem",
    "com.good.gd.file.",
    "com.good.gd.database.",
    "GDHttpClient",
    "GDSocket",
    "getApplicationPolicy",
)

failures = []        # hard failures on migrate-intent entry points
deferred_notes = []  # informational lines for deferred entry points
not_applicable_notes = []
migrated_ok = 0
unknown_candidates = []

# A handler regex shared across migrate-intent entries.
HANDLER_RE = re.compile(
    r"(?:public\s+void\s+onMessageReceived|public\s+boolean\s+onStartJob|protected\s+void\s+onHandleWork"
    r"|override\s+fun\s+onMessageReceived|override\s+fun\s+onStartJob|override\s+fun\s+onHandleWork"
    r"|override\s+fun\s+doWork|public\s+(?:Result|ListenableFuture[^)]*?)\s+doWork|protected\s+void\s+onReceive|override\s+fun\s+onReceive)"
)

for b in bgs:
    fqcn = b.get("name") or ""
    kind = b.get("kind") or ""
    decision = decisions_by_name.get(fqcn)
    if decision is None:
        unknown_candidates.append(fqcn)
        continue
    intent = decision.get("intent")
    if intent == "not-applicable":
        not_applicable_notes.append(f"{fqcn}: not-applicable per developer ({decision.get('rationale')})")
        continue
    if intent == "deferred":
        deferred_notes.append(f"{fqcn}: deferred per developer ({decision.get('rationale')})")
        continue
    # intent == "migrate" — apply the structural checks.
    ap, body = find_source(fqcn)
    if not body:
        failures.append((fqcn, f"source for {kind} entry point not found in tree (looked for class {short(fqcn)})"))
        continue
    auto = re.search(r"canAuthorizeAutonomously\s*\(\s*this\s*\)", body)
    sinit = re.search(r"serviceInit\s*\(\s*this\s*\)", body)
    if not auto:
        failures.append((fqcn, "missing GDAndroid.getInstance().canAuthorizeAutonomously(this)"))
        continue
    if not sinit:
        failures.append((fqcn, "missing GDAndroid.getInstance().serviceInit(this)"))
        continue
    if sinit.start() < auto.start():
        failures.append((fqcn, "serviceInit(this) precedes canAuthorizeAutonomously(this) — ordering is mandatory"))
        continue
    if not re.search(r"=\s*GDAndroid\.getInstance\(\)\.serviceInit\s*\(\s*this\s*\)", body):
        failures.append((fqcn, "serviceInit(this) result not captured in a field — Phase 3b requires a boolean gate"))
        continue
    if not re.search(r"GDInitializationError", body):
        failures.append((fqcn, "GDInitializationError not handled — wrap canAuthorizeAutonomously/serviceInit in try/catch (see steering/70-background-authorize.md)"))
        continue
    if HANDLER_RE.search(body):
        used_secure = any(tok in body for tok in SECURE_TOKENS)
        has_gate = bool(
            re.search(r"\bdynamicsBackgroundAuthorizeStarted\b", body)
            or re.search(r"=\s*GDAndroid\.getInstance\(\)\.serviceInit\s*\(\s*this\s*\)", body)
        )
        if used_secure and not has_gate:
            failures.append((fqcn, "handler accesses secure APIs without a Background Authorize gate field"))
            continue
    migrated_ok += 1

# Settings flag is required only when at least one decision is 'migrate'.
settings_failures = []
need_settings = any(d.get("intent") == "migrate" for d in decisions if isinstance(d, dict))
if need_settings:
    for tgt in settings_targets:
        companion = os.path.join(os.path.dirname(tgt), "com.blackberry.dynamics.settings.json")
        if not os.path.isfile(companion):
            settings_failures.append(f"missing {companion} (required when at least one decision is migrate)")
            continue
        try:
            with open(companion, encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception as e:
            settings_failures.append(f"{companion} invalid JSON: {e}")
            continue
        if cfg.get("GDEnableBackgroundAuthorize") is not True:
            settings_failures.append(f"{companion} missing GDEnableBackgroundAuthorize: true")

# Tag with summary so the shell wrapper can route through fail_or_defer
# when only deferred-intent entries remain.
if unknown_candidates:
    parts = [f"FAIL|{len(unknown_candidates)} candidate(s) have no decision in backgroundAuthorize.decisions[]"]
    for fqcn in unknown_candidates:
        parts.append(f"  - {fqcn}: re-run prompt 03c so the developer records intent")
    print("\n".join(parts))
elif failures or settings_failures:
    parts = [f"FAIL|{len(failures)} source failure(s) + {len(settings_failures)} settings failure(s)"]
    for fqcn, msg in failures:
        parts.append(f"  - {fqcn}: {msg}")
    for s in settings_failures:
        parts.append(f"  - settings: {s}")
    print("\n".join(parts))
elif deferred_notes:
    # Any deferred candidate routes through fail_or_defer — including
    # when other candidates were migrated in the same prompt 03c run.
    tag = "DEFERRED_PARTIAL" if migrated_ok > 0 else "DEFERRED"
    parts = [
        f"{tag}|{migrated_ok} migrate / {len(deferred_notes)} deferred / {len(not_applicable_notes)} not-applicable"
    ]
    for s in deferred_notes:
        parts.append(f"  - {s}")
    for s in not_applicable_notes:
        parts.append(f"  - {s}")
    print("\n".join(parts))
else:
    parts = [
        f"OK|{migrated_ok} migrate / {len(deferred_notes)} deferred / {len(not_applicable_notes)} not-applicable"
    ]
    for s in not_applicable_notes:
        parts.append(f"  - {s}")
    print("\n".join(parts))
PY
    ) || PHASE3B_RESULT="ERROR|python failure"
    case "${PHASE3B_RESULT%%|*}" in
        OK)
            check_pass "Background Authorize handshake validated: ${PHASE3B_RESULT#OK|}"
            ;;
        NA)
            check_pass "Background Authorize not applicable (no entries in processModel.backgroundEntryPoints[])"
            ;;
        PENDING)
            # Candidates exist but the developer has not yet been
            # prompted (prompt 03c not run). Surface as informational
            # so the recorder does not gate the whole pipeline; prompt
            # 10's final sweep will hard-fail if capture is still
            # missing at report time.
            check_warn "${PHASE3B_RESULT#PENDING|} (informational — capture intent in prompt 03c)"
            ;;
        DEFERRED|DEFERRED_PARTIAL)
            FIRST_LINE="$(printf '%s\n' "$PHASE3B_RESULT" | head -1)"
            DETAIL="$(printf '%s\n' "$PHASE3B_RESULT" | tail -n +2)"
            SUMMARY="${FIRST_LINE#DEFERRED_PARTIAL|}"
            SUMMARY="${SUMMARY#DEFERRED|}"
            # Per-candidate intent: deferred in backgroundAuthorize.decisions[]
            # downgrades via fail_or_defer; optional domain-level
            # deferredDomains[] (developer-authored) does the same.
            fail_or_defer "backgroundAuthorize" "$(printf '%s — deferred candidate(s) recorded in backgroundAuthorize.decisions[] (intent: deferred). Optional: add a developer-signed deferredDomains[] entry before prompt 10 for domain-wide sign-off. Details:\n%s' "$SUMMARY" "$DETAIL")"
            ;;
        FAIL)
            FIRST_LINE="$(printf '%s\n' "$PHASE3B_RESULT" | head -1)"
            DETAIL="$(printf '%s\n' "$PHASE3B_RESULT" | tail -n +2)"
            P3B_MSG="$(printf '%s — re-run prompt 03c (background-authorize). Details:\n%s' "${FIRST_LINE#FAIL|}" "$DETAIL")"
            # backgroundAuthorize is waivable: structural failures on a
            # migrate-intent entry route through fail_or_defer so a
            # developer who chose to defer mid-flight can land cleanly.
            fail_or_defer "backgroundAuthorize" "$P3B_MSG"
            ;;
        ERROR|*)
            check_warn "Phase 3b internal error: $PHASE3B_RESULT — see steering/70-background-authorize.md"
            ;;
    esac
fi
echo ""

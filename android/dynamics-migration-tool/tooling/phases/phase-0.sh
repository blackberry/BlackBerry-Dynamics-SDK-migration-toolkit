# BlackBerry Dynamics Migration — validator phase 0
#
# Sourced by tooling/validate.sh once should_run_phase "0" passes.
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
    # Phase 0: Bootstrap contract (when bootstrap.json exists)
    # ========================================
    echo "Phase 0: Bootstrap contract"
    echo "-----------------------------------------"

if [ -f "$BOOTSTRAP_FILE" ]; then
    if python3 - "$BOOTSTRAP_FILE" "$CATALOG_CONTRACT_FILE" <<'PY'
import json, re, sys

path = sys.argv[1]
catalog_contract_path = sys.argv[2] if len(sys.argv) > 2 else ""
required_top = (
    "agent",
    "attestations",
    "backup",
    "catalogVersion",
    "deferredDomains",
    "environment",
    "executedPrompts",
    "generatedAt",
    "permissions",
    "processModel",
    "provenance",
    "runId",
    "schemaVersion",
    "sdkClassIndex",
    "sdkProbe",
    "toolkit",
    "uem",
    "workingTree",
)

# The `waivers` top-level key is not part of the bootstrap contract.
# Defense-in-depth: this toolkit does not support line-level exceptions,
# and a future agent may pattern-match a waiver mechanism into existence
# from its training data. Reject the key explicitly so the failure is
# loud and actionable.
FORBIDDEN_TOP_LEVEL_KEYS = ("waivers",)

def die(msg: str) -> None:
    print(f"  ❌ {msg}")
    sys.exit(1)

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    die(f"bootstrap.json is not valid JSON: {e}")

if not isinstance(data, dict):
    die("bootstrap.json root must be a JSON object")

from datetime import datetime, timezone

def _parse_iso(v):
    if not isinstance(v, str) or not v.strip():
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00"))
    except Exception:
        return None

now = datetime.now(timezone.utc)
# backgroundAuthorize is waivable from 0.3.0-beta.2 onward — Dynamics
# SDK 14.1+ (including 15.0) made the API generally available but still opt-in at both
# the app and UEM levels. Discovery (processModel.backgroundEntryPoints[])
# produces CANDIDATES; prompt 03c captures per-candidate developer
# intent into bootstrap.backgroundAuthorize.decisions[]. A deferred
# decision is honored by Phase 3b via fail_or_defer "backgroundAuthorize".
non_waivable = {"authorization", "policyManagement", "secureClipboard", "transportHardening"}

for k in required_top:
    if k not in data:
        die(f"missing required top-level key: {k}")

for k in FORBIDDEN_TOP_LEVEL_KEYS:
    if k in data:
        die(
            f"unsupported top-level key '{k}' — this toolkit does not "
            f"support line-level exceptions. Re-run 00pre-bootstrap.md to "
            f"regenerate bootstrap.json without this key, and remove any "
            f"matching audit tags from source. If a domain cannot be "
            f"migrated, record it in deferredDomains[]."
        )

if data.get("schemaVersion") != "1.1.0":
    die("schemaVersion must be the string '1.1.0'")

run_id = data.get("runId")
if not isinstance(run_id, str) or not re.fullmatch(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}",
    run_id,
):
    die("runId must be a UUID string (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)")

generated_at = data.get("generatedAt")
if _parse_iso(generated_at) is None:
    die("generatedAt must be an ISO-8601 UTC timestamp")

catalog_version = data.get("catalogVersion")
if not isinstance(catalog_version, str) or not catalog_version.strip():
    die("catalogVersion must be a non-empty string")

agent = data.get("agent")
if not isinstance(agent, dict):
    die("agent must be an object")
if agent.get("type") not in ("cursor", "kiro", "codex", "generic"):
    die("agent.type must be one of: cursor, kiro, codex, generic")
if agent.get("approvalMode") not in ("auto", "per-command", "unknown"):
    die("agent.approvalMode must be one of: auto, per-command, unknown")
if "version" not in agent or not (agent.get("version") is None or isinstance(agent.get("version"), str)):
    die("agent.version must be a string or null")

att = data.get("attestations")
if isinstance(att, dict) and "cleanWorkingTree" in att:
    die(
        "deprecated attestations.cleanWorkingTree present — re-run "
        "00pre-bootstrap.md; use top-level workingTree instead"
    )

for arr_name in ("executedPrompts", "deferredDomains"):
    if not isinstance(data.get(arr_name), list):
        die(f"{arr_name} must be a JSON array")

uem = data.get("uem")
if not isinstance(uem, dict):
    die("uem must be an object")
gid = uem.get("gdApplicationId")
gver = uem.get("gdApplicationVersion")
src = uem.get("source")
if src != "uem-admin-confirmed":
    die("uem.source must be 'uem-admin-confirmed'")
if (
    not isinstance(gid, str)
    or not re.fullmatch(r"[a-zA-Z0-9._-]+", gid)
    or not (1 <= len(gid) <= 255)
):
    die("uem.gdApplicationId invalid (see bootstrap schema)")
if not isinstance(gver, str) or not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", gver):
    die("uem.gdApplicationVersion must match X.Y.Z.W")

wt = data.get("workingTree")
if not isinstance(wt, dict):
    die("workingTree must be an object")
dirty = wt.get("dirty")
ov = wt.get("override")
if dirty is True:
    if not isinstance(ov, dict) or ov.get("acknowledged") is not True:
        die("workingTree: when dirty is true, override must be an object with acknowledged: true")
elif dirty is False:
    if ov is not None:
        die("workingTree: when dirty is false, override must be null")
else:
    die("workingTree.dirty must be a boolean")

pm = data.get("processModel")
if pm is not None:
    if not isinstance(pm, dict):
        die("processModel must be an object")
    if pm.get("schemaVersion") != "1.0.0":
        die("processModel.schemaVersion must be '1.0.0'")
    comps = pm.get("components")
    if not isinstance(comps, list):
        die("processModel.components must be an array")
    for i, c in enumerate(comps):
        if not isinstance(c, dict):
            die(f"processModel.components[{i}] must be an object")
        for key in ("classification", "kind", "manifest", "name"):
            if key not in c:
                die(f"processModel.components[{i}] missing {key}")
        if c.get("classification") not in ("main", "auxiliary"):
            die(f"processModel.components[{i}].classification invalid")
        if c.get("kind") not in ("activity", "service", "provider"):
            die(f"processModel.components[{i}].kind invalid")
    # backgroundEntryPoints is optional in shape but, when present, must
    # be a list of well-formed objects. Absence means "no background
    # entry points detected" (backgroundAuthorize domain is N/A).
    bgs = pm.get("backgroundEntryPoints")
    if bgs is not None:
        if not isinstance(bgs, list):
            die("processModel.backgroundEntryPoints must be an array")
        allowed_kinds = {"service", "worker", "receiver"}
        for i, b in enumerate(bgs):
            if not isinstance(b, dict):
                die(f"processModel.backgroundEntryPoints[{i}] must be an object")
            for key in ("baseClass", "kind", "module", "name"):
                if key not in b:
                    die(f"processModel.backgroundEntryPoints[{i}] missing {key}")
            if b.get("kind") not in allowed_kinds:
                die(
                    f"processModel.backgroundEntryPoints[{i}].kind invalid "
                    f"(must be one of {sorted(allowed_kinds)})"
                )
            # manifest may be null only for kind=worker (declared in source).
            mani = b.get("manifest")
            if b.get("kind") == "worker":
                if mani is not None and not isinstance(mani, str):
                    die(f"processModel.backgroundEntryPoints[{i}].manifest must be string or null for kind=worker")
            else:
                if not isinstance(mani, str) or not mani:
                    die(f"processModel.backgroundEntryPoints[{i}].manifest must be a non-empty string for kind={b.get('kind')}")
    sm = pm.get("startupModel")
    if sm is not None:
        if not isinstance(sm, dict):
            die("processModel.startupModel must be an object when present")
        if sm.get("schemaVersion") != "1.0.0":
            die("processModel.startupModel.schemaVersion must be '1.0.0'")
        providers = sm.get("manifestProviders")
        if not isinstance(providers, list):
            die("processModel.startupModel.manifestProviders must be an array")
        for i, p in enumerate(providers):
            if not isinstance(p, dict):
                die(f"processModel.startupModel.manifestProviders[{i}] must be an object")
            for key in ("manifest", "module", "name"):
                if key not in p:
                    die(f"processModel.startupModel.manifestProviders[{i}] missing {key}")
        app_inits = sm.get("appStartupInitializers")
        if not isinstance(app_inits, list):
            die("processModel.startupModel.appStartupInitializers must be an array")
        for i, init in enumerate(app_inits):
            if not isinstance(init, dict):
                die(f"processModel.startupModel.appStartupInitializers[{i}] must be an object")
            for key in ("manifest", "module", "name", "provider"):
                if key not in init:
                    die(f"processModel.startupModel.appStartupInitializers[{i}] missing {key}")
        work = sm.get("workManager")
        if not isinstance(work, dict):
            die("processModel.startupModel.workManager must be an object")
        if work.get("defaultInitializer") not in ("enabled", "disabled", "not-detected"):
            die("processModel.startupModel.workManager.defaultInitializer invalid")
        for arr_name in ("initializerMetadataEntries", "configurationProviderClasses", "workerFactoryClasses"):
            arr = work.get(arr_name)
            if not isinstance(arr, list):
                die(f"processModel.startupModel.workManager.{arr_name} must be an array")

toolkit = data.get("toolkit") or {}
tk_ver = toolkit.get("version") if isinstance(toolkit, dict) else ""
if isinstance(tk_ver, str) and tk_ver.startswith("0.3.") and pm is None:
    die("processModel required for toolkit >= 0.3.0 — re-run 00pre-bootstrap.md")

prov = data.get("provenance")
if not isinstance(prov, dict):
    die("provenance must be an object")
if prov.get("runId") != run_id:
    die("provenance.runId must match top-level runId")
if prov.get("catalogVersion") != catalog_version:
    die("provenance.catalogVersion must match top-level catalogVersion")
if prov.get("toolkitVersion") != tk_ver:
    die("provenance.toolkitVersion must match toolkit.version")
if prov.get("generatedAt") != generated_at:
    die("provenance.generatedAt must match generatedAt")
for optional_name in ("gitCommit", "sdkArtifact", "sdkResolvedVersion", "sdkSha256", "catalogSha256"):
    oval = prov.get(optional_name)
    if oval is not None and not isinstance(oval, str):
        die(f"provenance.{optional_name} must be a string or null")

if catalog_contract_path and isinstance(catalog_version, str):
    try:
        with open(catalog_contract_path, "r", encoding="utf-8") as cf:
            cat = json.load(cf)
        contract_catalog_version = cat.get("catalogVersion")
        if isinstance(contract_catalog_version, str) and contract_catalog_version.strip():
            if catalog_version != contract_catalog_version:
                die(
                    f"catalogVersion drift: bootstrap.json has {catalog_version!r} "
                    f"but contracts/api-catalog.v1.0.0.json has {contract_catalog_version!r}"
                )
    except Exception:
        pass

# Optional top-level backgroundAuthorize decisions block (written by
# prompt 03c). Absent on fresh bootstrap. When present, must be
# well-formed and one decisions[] entry per processModel.backgroundEntryPoints[]
# candidate (cross-check enforced by prompt 10 / recorder, not here).
ba = data.get("backgroundAuthorize")
if ba is not None:
    if not isinstance(ba, dict):
        die("backgroundAuthorize must be an object")
    if ba.get("schemaVersion") != "1.0.0":
        die("backgroundAuthorize.schemaVersion must be '1.0.0'")
    decisions = ba.get("decisions")
    if not isinstance(decisions, list):
        die("backgroundAuthorize.decisions must be an array")
    allowed_intents = {"migrate", "deferred", "not-applicable"}
    for i, d in enumerate(decisions):
        if not isinstance(d, dict):
            die(f"backgroundAuthorize.decisions[{i}] must be an object")
        for key in ("intent", "kind", "module", "name", "rationale"):
            if key not in d:
                die(f"backgroundAuthorize.decisions[{i}] missing {key}")
        if d.get("intent") not in allowed_intents:
            die(f"backgroundAuthorize.decisions[{i}].intent invalid (must be one of {sorted(allowed_intents)})")
        rationale = d.get("rationale")
        if not isinstance(rationale, str) or not rationale.strip():
            die(f"backgroundAuthorize.decisions[{i}].rationale must be a non-empty string")

non_waivable = {"authorization", "policyManagement", "secureClipboard", "transportHardening", "externalStorage"}
for i, entry in enumerate(data.get("deferredDomains") or []):
    if not isinstance(entry, dict):
        die(f"deferredDomains[{i}] must be an object")
    dom = entry.get("domain")
    if dom in non_waivable:
        die(
            f"deferredDomains[{i}].domain {dom!r} is non-waivable. "
            f"externalStorage covers writes to /sdcard, public Downloads/Pictures/Documents, "
            f"MediaStore shared collections, getExternalFilesDir / getExternalCacheDir, "
            f"removable media and SAF document trees; these always leave the Dynamics "
            f"secure container and must be migrated to com.good.gd.file.* container paths "
            f"or removed before the migration can be marked complete."
        )
    if entry.get("developerSignedOff") is not True:
        die(
            f"deferredDomains[{i}] requires developerSignedOff: true "
            f"(see steering/02-bootstrap-schema.md for the full developer-owned deferral template)"
        )
    reason = entry.get("reason")
    if not isinstance(reason, str) or not reason.strip() or reason.strip().upper() == "TBD":
        die(f"deferredDomains[{i}].reason must be a non-empty rationale")
    if entry.get("classification") not in ("plannedInNextRelease", "acceptedResidualRisk"):
        die(
            f"deferredDomains[{i}].classification invalid "
            f"(must be plannedInNextRelease or acceptedResidualRisk)"
        )
    exp = _parse_iso(entry.get("expiresAt"))
    if exp is None:
        die(
            f"deferredDomains[{i}].expiresAt must be a future ISO-8601 UTC timestamp "
            f"(see steering/02-bootstrap-schema.md)"
        )
    if exp <= now:
        die(f"deferredDomains[{i}].expiresAt is expired — renew or remove the entry")

sys.exit(0)
PY
    then
        check_pass "bootstrap.json contract OK (schema + UEM + workingTree + provenance)"
    else
        check_fail "bootstrap.json failed contract check — fix bootstrap or re-run 00pre-bootstrap.md"
    fi
else
    check_warn "bootstrap.json not found — deferrals unavailable; run 00pre-bootstrap.md for a full Android migration audit trail"
fi
echo ""

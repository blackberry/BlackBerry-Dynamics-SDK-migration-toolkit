#!/usr/bin/env python3
"""Normalize validator diagnostics into the Stage 5 repair evidence contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple

CONTRACT_VERSION = "1.0.0"

DIAGNOSTIC_KINDS = {
    "tool-defect",
    "migrated-application-defect",
    "unsupported-application-behaviour",
    "missing-developer-decision",
    "environment-or-dependency-failure",
    "runtime-evidence-gap",
}


def load_json(path: str) -> Optional[Dict[str, Any]]:
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def slug(value: Any, fallback: str = "generic") -> str:
    text = str(value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or fallback


def message_prefix(value: Any) -> str:
    text = str(value or "").strip()
    return text.split(" — ", 1)[0][:240]


def phase_metadata(check_map: Optional[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    out: Dict[str, Dict[str, Any]] = {}
    if not isinstance(check_map, dict):
        return out

    registry = check_map.get("validationRegistry")
    if isinstance(registry, dict) and isinstance(registry.get("phases"), dict):
        for phase, meta in registry["phases"].items():
            if isinstance(phase, str) and isinstance(meta, dict):
                out.setdefault(phase, {})["domains"] = [
                    d for d in meta.get("domains", []) if isinstance(d, str)
                ]

    scoped = check_map.get("scopedChecks")
    if isinstance(scoped, dict):
        for prompt_id, cfg in scoped.items():
            if not isinstance(prompt_id, str) or not isinstance(cfg, dict):
                continue
            for phase in cfg.get("phases", []) or []:
                if isinstance(phase, str):
                    out.setdefault(phase, {}).setdefault("prompts", []).append(prompt_id)

    prompts = check_map.get("prompts")
    if isinstance(prompts, list):
        for prompt in prompts:
            if not isinstance(prompt, dict):
                continue
            prompt_id = prompt.get("id")
            if not isinstance(prompt_id, str):
                continue
            validator = prompt.get("validator") or {}
            if isinstance(validator, dict):
                phases = validator.get("requiredPhases") or []
                for phase in phases:
                    if isinstance(phase, str):
                        out.setdefault(phase, {}).setdefault("prompts", []).append(prompt_id)
                        domains = [d for d in prompt.get("ownedDomains", []) if isinstance(d, str)]
                        if domains:
                            out.setdefault(phase, {}).setdefault("domains", domains)
    return out


def first_prompt_for_phase(meta: Dict[str, Dict[str, Any]], phase: str) -> Optional[str]:
    prompts = meta.get(phase, {}).get("prompts")
    if isinstance(prompts, list):
        for prompt in prompts:
            if isinstance(prompt, str) and prompt:
                return prompt
    return None


def parse_file_token(token: Any) -> Tuple[Optional[str], Optional[int]]:
    if not isinstance(token, str):
        return None, None
    text = token.strip()
    if not text:
        return None, None
    match = re.match(r"^(.+?):(\d+)(?::|$)", text)
    if match:
        return match.group(1), int(match.group(2))
    return text, None


def affected_paths(row: Dict[str, Any]) -> Tuple[List[str], Optional[int]]:
    raw: List[Any] = []
    for key in ("file", "files", "affectedFile"):
        value = row.get(key)
        if isinstance(value, list):
            raw.extend(value)
        elif isinstance(value, str):
            raw.extend([part for part in re.split(r"[\n,]", value) if part.strip()])
    paths: List[str] = []
    first_line: Optional[int] = None
    for item in raw:
        path, line = parse_file_token(item)
        if path and path not in paths:
            paths.append(path)
        if first_line is None and isinstance(line, int):
            first_line = line
    line_value = row.get("line")
    if first_line is None and isinstance(line_value, int):
        first_line = line_value
    return paths, first_line


def classify_issue(phase: str, domain: str, message: str) -> str:
    d = slug(domain, "")
    p = slug(phase, "")
    text = message.lower()
    if "tooling" in d or "internal" in text or "malformed validationregistry" in text:
        return "tool-defect"
    if d in {"gradle", "build", "dependency", "framework"} or "build-verification" in p:
        return "environment-or-dependency-failure"
    if d in {"backgroundauthorize", "policymanagement"} or "developer decision" in text or "defer" in text:
        return "missing-developer-decision"
    if d in {"externalstorage", "transporthardening"} or "unsupported" in text:
        return "unsupported-application-behaviour"
    if d in {"reportcontract"} or "report" in p or "evidence" in p:
        return "runtime-evidence-gap"
    return "migrated-application-defect"


def repair_category(kind: str, domain: str) -> str:
    if kind == "environment-or-dependency-failure":
        return "fix-environment"
    if kind == "missing-developer-decision":
        return "developer-decision-required"
    if kind == "unsupported-application-behaviour":
        return "redesign-required"
    if kind == "runtime-evidence-gap":
        return "update-report-evidence"
    if kind == "tool-defect":
        return "manual-review"
    if slug(domain, "") in {"externalstorage", "secureclipboard", "policymanagement"}:
        return "developer-decision-required"
    return "rerun-owner-prompt"


def verification_command(platform: str, prompt_id: str, owner_prompt: str) -> str:
    if owner_prompt and owner_prompt not in {"fullSweep", "full", "final", "final-source", "report"}:
        return f"bash dynamics-migration-tool/tooling/validate.sh --check-prompt {owner_prompt}"
    if platform == "android":
        return "bash dynamics-migration-tool/tooling/validate.sh --mode final-source --prompt 10"
    return "bash dynamics-migration-tool/tooling/validate.sh"


def fingerprint_basis(row: Dict[str, Any], phase: str, domain: str, paths: List[str], prefix: str) -> Dict[str, Any]:
    return {
        "category": row.get("category") or "",
        "detector": row.get("detector") or "",
        "domain": domain,
        "files": paths,
        "issue": row.get("issue") or "",
        "messagePrefix": prefix,
        "phase": phase,
        "severity": row.get("severity") or "",
    }


def normalize_diagnostics(
    rows: Iterable[Dict[str, Any]],
    *,
    platform: str,
    prompt_id: str,
    phases: Iterable[str],
    check_map: Optional[Dict[str, Any]] = None,
) -> List[Dict[str, Any]]:
    meta = phase_metadata(check_map)
    phase_list = [p for p in phases if isinstance(p, str) and p]
    normalized: List[Dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        out = dict(row)
        phase = str(row.get("phase") or (phase_list[0] if phase_list else "unknown"))
        domains = meta.get(phase, {}).get("domains") or []
        domain = str(row.get("domain") or (domains[0] if domains else ""))
        severity = str(row.get("severity") or "fail")
        prefix = message_prefix(row.get("message") or row.get("issue") or row.get("category"))
        paths, line = affected_paths(row)
        owner_prompt = str(row.get("owningPrompt") or prompt_id or first_prompt_for_phase(meta, phase) or "unknown")
        if owner_prompt in {"fullSweep", "full", "final", "final-source", "report", "preflight", "prompt-scoped"}:
            owner_prompt = first_prompt_for_phase(meta, phase) or owner_prompt
        kind = classify_issue(phase, domain, prefix)
        category = repair_category(kind, domain)
        basis = fingerprint_basis(row, phase, domain, paths, prefix)
        fp = hashlib.sha256(json.dumps(basis, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
        code_parts = [
            platform.upper(),
            slug(phase, "phase"),
            slug(row.get("detector") or row.get("category") or row.get("issue") or domain, "diagnostic"),
            fp[:8],
        ]
        human_required = category in {"developer-decision-required", "redesign-required", "manual-review"}
        out.update(
            {
                "diagnosticCode": "-".join(code_parts).upper(),
                "diagnosticContractVersion": CONTRACT_VERSION,
                "platform": platform,
                "severity": severity,
                "validationPhase": phase,
                "owningPrompt": owner_prompt,
                "affectedFile": paths[0] if paths else None,
                "location": {"file": paths[0] if paths else None, "line": line},
                "evidence": {
                    "message": prefix,
                    "files": paths[:10],
                    "detector": row.get("detector") or row.get("category") or row.get("issue") or None,
                },
                "expectedCondition": f"{domain or phase} validation condition is satisfied",
                "observedCondition": f"validator emitted {severity} diagnostic",
                "defectKind": kind,
                "safeRepairCategory": category,
                "suggestedVerificationCommand": verification_command(platform, prompt_id, owner_prompt),
                "rerunPrompt": owner_prompt if owner_prompt not in {"unknown", "fullSweep", "full"} else None,
                "rerunPhase": phase,
                "humanJudgmentRequired": human_required,
                "automaticRepairProhibited": human_required,
                "diagnosticFingerprint": fp,
            }
        )
        normalized.append(out)
    return normalized


def validate_sidecar(payload: Dict[str, Any]) -> List[str]:
    errors: List[str] = []
    violations = payload.get("violations")
    if not isinstance(violations, list):
        return ["violations must be an array"]
    required = {
        "diagnosticCode",
        "diagnosticContractVersion",
        "platform",
        "severity",
        "validationPhase",
        "owningPrompt",
        "evidence",
        "expectedCondition",
        "observedCondition",
        "defectKind",
        "safeRepairCategory",
        "suggestedVerificationCommand",
        "humanJudgmentRequired",
        "automaticRepairProhibited",
        "diagnosticFingerprint",
    }
    for idx, row in enumerate(violations):
        if not isinstance(row, dict):
            errors.append(f"violations[{idx}] must be an object")
            continue
        missing = sorted(required - set(row))
        if missing:
            errors.append(f"violations[{idx}] missing {', '.join(missing)}")
        if row.get("defectKind") not in DIAGNOSTIC_KINDS:
            errors.append(f"violations[{idx}] has invalid defectKind")
    return errors


def prompt_config(check_map: Optional[Dict[str, Any]], platform: str, prompt_id: str) -> Dict[str, Any]:
    if not isinstance(check_map, dict):
        return {"mode": "unknown", "requiredPhases": []}
    if platform == "android":
        if prompt_id in (check_map.get("noOp") or []):
            return {"mode": "none", "requiredPhases": []}
        scoped = check_map.get("scopedChecks") or {}
        if isinstance(scoped, dict) and isinstance(scoped.get(prompt_id), dict):
            return {"mode": "scoped", "requiredPhases": scoped[prompt_id].get("phases") or []}
        full = check_map.get("fullSweep") or {}
        if isinstance(full, dict) and isinstance(full.get(prompt_id), dict):
            return {"mode": "full", "requiredPhases": full[prompt_id].get("phases") or []}
        return {"mode": "unknown", "requiredPhases": []}
    for prompt in check_map.get("prompts", []) or []:
        if isinstance(prompt, dict) and prompt.get("id") == prompt_id:
            validator = prompt.get("validator") if isinstance(prompt.get("validator"), dict) else {}
            return {
                "mode": validator.get("mode") or "none",
                "requiredPhases": validator.get("requiredPhases") or [],
            }
    return {"mode": "unknown", "requiredPhases": []}


def proof_summary(path: str, payload: Dict[str, Any], platform: str) -> Dict[str, Any]:
    try:
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
    except Exception:
        digest = ""
    if platform == "android":
        return {
            "file": os.path.basename(path),
            "fingerprint": digest,
            "validationRunId": payload.get("validationRunId"),
            "mode": payload.get("mode"),
            "scope": payload.get("scope"),
            "status": payload.get("status"),
            "phases": payload.get("phasesRun") or [],
            "diagnosticContractVersion": payload.get("diagnosticContractVersion"),
        }
    return {
        "file": os.path.basename(path),
        "fingerprint": digest,
        "validationRunId": payload.get("validationRunId"),
        "mode": payload.get("validationMode"),
        "scope": payload.get("promptScope"),
        "status": payload.get("result"),
        "phases": payload.get("phasesExecuted") or [],
        "diagnosticContractVersion": payload.get("diagnosticContractVersion"),
    }


def validate_prompt_proof(path: str, payload: Dict[str, Any], platform: str, prompt_id: str, check_map: Optional[Dict[str, Any]]) -> Tuple[List[str], Dict[str, Any]]:
    errors: List[str] = []
    cfg = prompt_config(check_map, platform, prompt_id)
    required_phases = [p for p in cfg.get("requiredPhases") or [] if isinstance(p, str)]
    if cfg.get("mode") in ("none", "unknown"):
        return errors, proof_summary(path, payload, platform)

    if platform == "android":
        phases = set(payload.get("phasesRun") or [])
        if cfg.get("mode") == "scoped":
            if payload.get("mode") != "scoped":
                errors.append(f"expected scoped validation mode for prompt {prompt_id}")
            if payload.get("promptId") != prompt_id:
                errors.append(f"promptId mismatch: expected {prompt_id}, got {payload.get('promptId')!r}")
        if payload.get("status") != "passed":
            errors.append(f"validation proof status must be passed, got {payload.get('status')!r}")
        if int(payload.get("failCount") or 0) != 0:
            errors.append("validation proof has failCount > 0")
        if payload.get("diagnosticContractVersion") != CONTRACT_VERSION:
            errors.append("validation proof missing diagnosticContractVersion 1.0.0")
    else:
        phases = set(payload.get("phasesExecuted") or [])
        mode = cfg.get("mode")
        if mode == "prompt-scoped":
            if payload.get("validationMode") != "prompt-scoped":
                errors.append(f"expected prompt-scoped validation proof for prompt {prompt_id}")
            if payload.get("promptScope") != prompt_id:
                errors.append(f"promptScope mismatch: expected {prompt_id}, got {payload.get('promptScope')!r}")
        elif mode == "preflight" and payload.get("validationMode") != "preflight":
            errors.append("expected preflight validation proof")
        elif mode == "full" and payload.get("validationMode") != "full":
            errors.append("expected full validation proof")
        if payload.get("result") not in ("pass", "warn"):
            errors.append(f"validation proof result must be pass|warn, got {payload.get('result')!r}")
        if payload.get("isStale") is True:
            errors.append("validation proof is stale")
        if payload.get("diagnosticContractVersion") != CONTRACT_VERSION:
            errors.append("validation proof missing diagnosticContractVersion 1.0.0")

    missing = [p for p in required_phases if p not in phases]
    if missing:
        errors.append("validation proof missing required phase(s): " + ", ".join(missing))
    return errors, proof_summary(path, payload, platform)


def main() -> int:
    parser = argparse.ArgumentParser(description="Normalize/validate validator diagnostics.")
    parser.add_argument("sidecar", nargs="?")
    parser.add_argument("--validate-sidecar", action="store_true")
    parser.add_argument("--validate-prompt-proof", action="store_true")
    parser.add_argument("--platform", choices=["android", "ios"], default="android")
    parser.add_argument("--prompt-id", default="")
    parser.add_argument("--check-map", default="")
    args = parser.parse_args()
    if args.validate_sidecar or args.validate_prompt_proof:
        if not args.sidecar:
            print("missing sidecar path", file=sys.stderr)
            return 2
        payload = load_json(args.sidecar)
        if not isinstance(payload, dict):
            print("sidecar is not valid JSON object", file=sys.stderr)
            return 2
        if args.validate_prompt_proof:
            if not args.prompt_id:
                print("missing --prompt-id", file=sys.stderr)
                return 2
            errors, summary = validate_prompt_proof(
                args.sidecar,
                payload,
                args.platform,
                args.prompt_id,
                load_json(args.check_map),
            )
        else:
            errors = validate_sidecar(payload)
            summary = {}
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        if summary:
            print(json.dumps(summary, sort_keys=True))
        return 0
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

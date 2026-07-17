#!/usr/bin/env python3
"""Resolve changed files + flags into the set of validator phases to run.

Consumed by tooling/validate.sh (--mode incremental/full/final, --domains,
--explain-plan) and indirectly by record-prompt-execution.sh. The output is a
single JSON object on stdout describing the plan; the shell extracts
`phasesToRun` and renders `selection` for --explain-plan.

DESIGN / SAFETY (see validationRegistry.comment in check-prompt-map.json):

  * `full` / `final` modes always return every phase in phaseOrder — these are
    the unchanged acceptance gate.
  * `incremental` selects a subset, but NEVER drops a security-critical check:
      - alwaysRun phases (externalStorage/secureNetworking/secureClipboard/
        webview/audit-comments/bootstrap-contract) run whenever any source,
        manifest, or gradle file changed.
      - A change to any crossCutting.fileTriggers entry (Application, base
        Activity, manifest, build files) forces the entire domain set.
      - A phase runs when its fileTriggers glob matches a changed path OR a
        patternTrigger regex matches the content of a changed source file.
      - An UNKNOWN changed-file signal forces a full run.
      - expensiveFullOnly (Gradle build, whole-tree API audit, catalog) and
        reportOnly phases never run incrementally — they are deferred to the
        full/final gate. This is the primary per-prompt speed-up.
  * When --prompt is given, the prompt's own scoped phases are unioned in
    (minus expensiveFullOnly/reportOnly) so incremental coverage is never
    below today's per-prompt behavior for the domain the prompt owns.
"""

import argparse
import json
import os
import re
import sys


def glob_to_regex(glob: str) -> "re.Pattern[str]":
    """Translate a path glob (supporting ** and *) to an anchored regex."""
    out = ["^"]
    i = 0
    n = len(glob)
    while i < n:
        if glob[i : i + 3] == "**/":
            out.append("(?:.*/)?")
            i += 3
        elif glob[i : i + 2] == "**":
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    out.append("$")
    return re.compile("".join(out))


def any_glob_match(path: str, compiled_globs) -> bool:
    return any(rx.match(path) for rx in compiled_globs)


def read_changed(changed_arg: str):
    """Return (paths, unknown). `unknown` forces a full run."""
    if changed_arg is None:
        return [], False
    if changed_arg == "-":
        raw = sys.stdin.read()
    else:
        try:
            with open(changed_arg, encoding="utf-8") as f:
                raw = f.read()
        except OSError:
            return [], True
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    if any(ln == "UNKNOWN" for ln in lines):
        return [], True
    norm = []
    for ln in lines:
        ln = ln[2:] if ln.startswith("./") else ln
        norm.append(ln)
    return sorted(set(norm)), False


def file_matches_patterns(path: str, compiled_patterns) -> bool:
    """True if the changed file's content matches any patternTrigger regex."""
    if not compiled_patterns:
        return False
    if not os.path.isfile(path):
        # Deleted/renamed source still implies its domain may need a re-check;
        # but with no content to scan we rely on fileTriggers/alwaysRun and
        # the cross-cutting + final gate. Treat as no pattern match here.
        return False
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return False
    return any(rx.search(text) for rx in compiled_patterns)


def main() -> int:
    ap = argparse.ArgumentParser(description="Resolve validator phases to run.")
    ap.add_argument("--registry", required=True, help="Path to check-prompt-map.json")
    ap.add_argument("--changed-file", default=None,
                    help="File of newline-separated changed paths, or '-' for stdin")
    ap.add_argument("--prompt", default=None, help="Prompt id to union scoped phases from")
    ap.add_argument("--domains", default=None, help="Comma-separated domains to force")
    ap.add_argument("--mode", default="incremental",
                    choices=["incremental", "full", "final"])
    args = ap.parse_args()

    try:
        with open(args.registry, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as exc:  # noqa: BLE001 - surface as fallback-full
        json.dump({
            "mode": args.mode, "fallbackFull": True, "error": f"registry unreadable: {exc}",
            "phasesToRun": [], "selection": [], "skipped": [],
            "finalGateRequired": True,
        }, sys.stdout)
        return 0

    reg = cfg.get("validationRegistry") or {}
    phase_order = reg.get("phaseOrder") or []
    phases = reg.get("phases") or {}
    global_globs = [glob_to_regex(g) for g in (reg.get("globalSourceGlobs") or [])]
    cross_globs = [glob_to_regex(g) for g in
                   ((reg.get("crossCutting") or {}).get("fileTriggers") or [])]
    expensive = set(reg.get("expensiveFullOnly") or [])
    report_only = set(reg.get("reportOnly") or [])

    # Prompt-owned phases (scopedChecks ∪ fullSweep) — minus expensive/report.
    owned = set()
    if args.prompt:
        for section in ("scopedChecks", "fullSweep"):
            entry = (cfg.get(section) or {}).get(args.prompt)
            if entry:
                for p in entry.get("phases") or []:
                    owned.add(str(p))
    owned_incremental = {p for p in owned if p not in expensive and p not in report_only}

    forced_domains = set()
    if args.domains:
        forced_domains = {d.strip() for d in args.domains.split(",") if d.strip()}

    # ---- full / final: every phase, unchanged acceptance gate ----------------
    if args.mode in ("full", "final"):
        selection = []
        for p in phase_order:
            meta = phases.get(p, {})
            selection.append({
                "phase": p, "run": True,
                "reason": "full sweep" if args.mode == "full" else "final acceptance gate",
                "domains": meta.get("domains", []),
                "severity": meta.get("severity", "unknown"),
                "estimatedCostMs": meta.get("estimatedCostMs", 0),
            })
        total = sum(phases.get(p, {}).get("estimatedCostMs", 0) for p in phase_order)
        json.dump({
            "mode": args.mode, "fallbackFull": False, "changedFileCount": None,
            "anySource": True, "crossCutting": True,
            "promptId": args.prompt, "forcedDomains": sorted(forced_domains) or None,
            "phasesToRun": list(phase_order), "skipped": [],
            "selection": selection, "estimatedCostMs": total,
            "finalGateRequired": True,
        }, sys.stdout)
        return 0

    # ---- incremental ---------------------------------------------------------
    changed, unknown = read_changed(args.changed_file)

    if unknown:
        selection = [{
            "phase": p, "run": True,
            "reason": "fallback: changed-file detection UNKNOWN -> full",
            "domains": phases.get(p, {}).get("domains", []),
            "severity": phases.get(p, {}).get("severity", "unknown"),
            "estimatedCostMs": phases.get(p, {}).get("estimatedCostMs", 0),
        } for p in phase_order]
        json.dump({
            "mode": "incremental", "fallbackFull": True, "changedFileCount": 0,
            "anySource": True, "crossCutting": True,
            "promptId": args.prompt, "forcedDomains": sorted(forced_domains) or None,
            "phasesToRun": list(phase_order), "skipped": [],
            "selection": selection,
            "estimatedCostMs": sum(phases.get(p, {}).get("estimatedCostMs", 0)
                                   for p in phase_order),
            "finalGateRequired": True,
        }, sys.stdout)
        return 0

    any_source = any(any_glob_match(p, global_globs) for p in changed)
    cross_hits = [p for p in changed if any_glob_match(p, cross_globs)]
    cross_cutting = bool(cross_hits)

    selection = []
    skipped = []
    to_run = []

    for p in phase_order:
        meta = phases.get(p, {})
        domains = meta.get("domains", [])
        severity = meta.get("severity", "unknown")
        cost = meta.get("estimatedCostMs", 0)
        always = bool(meta.get("alwaysRun"))
        file_globs = [glob_to_regex(g) for g in (meta.get("fileTriggers") or [])]
        pat_strs = meta.get("patternTriggers") or []
        # Compile defensively: a malformed registry regex must not crash the
        # resolver (which would surface as an opaque "resolution failed" with no
        # plan). On a compile error we run the phase conservatively below.
        compiled_patterns = []
        pat_error = None
        for s in pat_strs:
            try:
                compiled_patterns.append(re.compile(s))
            except re.error as exc:
                pat_error = "%r: %s" % (s, exc)
                break

        def record(run, reason):
            entry = {"phase": p, "run": run, "reason": reason, "domains": domains,
                     "severity": severity, "estimatedCostMs": cost}
            selection.append(entry)
            if run:
                to_run.append(p)
            else:
                skipped.append({"phase": p, "reason": reason})

        # Expensive whole-tree + report phases are deferred to full/final.
        # This is the primary per-prompt speed-up and applies even when the
        # prompt nominally "owns" phase 9/10/report.
        if p in expensive:
            record(False, "expensive whole-tree phase deferred to full/final gate")
            continue
        if p in report_only:
            record(False, "report-only phase runs at the prompt-10 full sweep")
            continue

        # Prompt owns this phase's domain: run unconditionally so incremental
        # coverage never falls below today's per-prompt behavior (checked
        # before alwaysRun so an owned alwaysRun phase still runs in the rare
        # case where the recorder reports no source-like change).
        if p in owned_incremental:
            record(True, f"prompt {args.prompt} owns this phase")
            continue

        # Forced via --domains (maintainer/agent debug). Checked before the
        # alwaysRun branch so a forced domain runs even with no source change
        # (otherwise an alwaysRun phase would be recorded skipped without ever
        # consulting forced_domains).
        if forced_domains and (set(domains) & forced_domains):
            record(True, "forced via --domains")
            continue

        # Always-run phases: run whenever any source/manifest/gradle changed.
        if always:
            if any_source:
                record(True, "always-run (security-critical / cheap audit)")
            else:
                record(False, "always-run but no source/manifest/gradle file changed")
            continue

        # Cross-cutting change forces every domain phase.
        if cross_cutting:
            record(True, "cross-cutting file changed -> broad domain set")
            continue

        # File-trigger glob match.
        matched_file = next((c for c in changed if any_glob_match(c, file_globs)), None)
        if matched_file:
            record(True, f"file trigger matched: {matched_file}")
            continue

        # Malformed patternTriggers regex: cannot evaluate the trigger, so run
        # the phase conservatively rather than silently skip a domain check.
        if pat_error is not None:
            record(True, f"patternTrigger regex invalid ({pat_error}) -> running phase conservatively")
            continue

        # Pattern-trigger match against changed source file content.
        matched_pat = next((c for c in changed
                            if file_matches_patterns(c, compiled_patterns)), None)
        if matched_pat:
            record(True, f"pattern trigger matched in: {matched_pat}")
            continue

        record(False, "no trigger matched for "
                      f"domain(s) {','.join(domains) if domains else '-'}")

    # phasesToRun in canonical order.
    run_set = set(to_run)
    ordered = [p for p in phase_order if p in run_set]

    # Empty incremental selection: rather than run zero phases and record a
    # passing run (which could mask a regression until the prompt-10 gate),
    # fall back to the full sweep. This only fires when nothing else selected
    # a phase (no owned phase, no alwaysRun source change, no trigger), which
    # for a recorder-driven run is unusual — the prompt almost always owns a
    # phase. Safe-by-default: an empty plan becomes a full plan.
    if not ordered:
        selection = [{
            "phase": p, "run": True,
            "reason": "fallback: incremental selection was empty -> full sweep",
            "domains": phases.get(p, {}).get("domains", []),
            "severity": phases.get(p, {}).get("severity", "unknown"),
            "estimatedCostMs": phases.get(p, {}).get("estimatedCostMs", 0),
        } for p in phase_order]
        json.dump({
            "mode": "incremental", "fallbackFull": True,
            "changedFileCount": len(changed), "anySource": any_source,
            "crossCutting": cross_cutting, "crossCuttingFiles": cross_hits,
            "promptId": args.prompt, "forcedDomains": sorted(forced_domains) or None,
            "phasesToRun": list(phase_order), "skipped": [],
            "selection": selection,
            "estimatedCostMs": sum(phases.get(p, {}).get("estimatedCostMs", 0)
                                   for p in phase_order),
            "finalGateRequired": True,
        }, sys.stdout)
        return 0

    total = sum(phases.get(p, {}).get("estimatedCostMs", 0) for p in ordered)

    json.dump({
        "mode": "incremental", "fallbackFull": False,
        "changedFileCount": len(changed), "anySource": any_source,
        "crossCutting": cross_cutting, "crossCuttingFiles": cross_hits,
        "promptId": args.prompt, "forcedDomains": sorted(forced_domains) or None,
        "phasesToRun": ordered, "skipped": skipped, "selection": selection,
        "estimatedCostMs": total, "finalGateRequired": False,
    }, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())

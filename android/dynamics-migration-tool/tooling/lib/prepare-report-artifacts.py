#!/usr/bin/env python3
"""Normalize Prompt-10 report artifacts before report-contract validation.

This helper is intentionally deterministic:
  - derives module ownership from module-map.json for filesModified/modules[]
  - refreshes report validation values from .last-source-check.json when present
  - writes a canonical Dynamics_Migration_Readme.md with required headings

It does not fabricate migration data. If ownership cannot be derived for a
report entry, it fails with an actionable error so the owning prompt can be
fixed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any


def _load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be a JSON object")
    return data


def _write_json(path: Path, data: dict[str, Any]) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def _to_int(value: Any, default: int) -> int:
    try:
        if value is None:
            return default
        return int(value)
    except Exception:
        return default


def _normalize_mode(raw_mode: Any) -> str:
    if raw_mode in ("source", "final-source"):
        return str(raw_mode)
    if raw_mode in ("full", "final", "fullSweep"):
        return "source"
    return "source"


def _normalize_rel(path: Any) -> str:
    if not isinstance(path, str):
        return ""
    candidate = path.strip().replace("\\", "/")
    candidate = re.sub(r"/+", "/", candidate)
    while candidate.startswith("./"):
        candidate = candidate[2:]
    candidate = candidate.lstrip("/")
    if not candidate:
        return ""
    normalized = str(PurePosixPath(candidate))
    return "" if normalized == "." else normalized


_REPORT_SEVERITY_ENUM = frozenset({"P0", "P1", "P2", "P3"})


def _normalize_manual_todo_severity_aliases(report: dict[str, Any]) -> bool:
    """Alias manualTodos[].priority -> severity when priority is already P0-P3.

    Agents commonly emit the analysis-era key `priority` in report todos.
    Schema + report-contract require `severity` with additionalProperties:false,
    so a safe rename avoids opaque contract failures. Non-P0..P3 priority
    values are left untouched for an explicit validator error (no fuzzy remap
    from blocker/high/medium/low).
    """
    changed = False
    todos = report.get("manualTodos")
    if not isinstance(todos, list):
        return changed
    for todo in todos:
        if not isinstance(todo, dict):
            continue
        severity = todo.get("severity")
        priority = todo.get("priority")
        sev_ok = isinstance(severity, str) and severity in _REPORT_SEVERITY_ENUM
        pri_ok = isinstance(priority, str) and priority in _REPORT_SEVERITY_ENUM

        if sev_ok:
            if "priority" in todo:
                if pri_ok and priority != severity:
                    # Conflicting values — leave both for validator visibility.
                    continue
                del todo["priority"]
                changed = True
            continue

        if pri_ok:
            todo["severity"] = priority
            del todo["priority"]
            changed = True
    return changed


@dataclass(frozen=True)
class ModuleRef:
    name: str
    path: str


@dataclass
class ModuleContext:
    primary_name: str
    modules: list[ModuleRef]
    convention_sources: set[str]

    @property
    def valid_names(self) -> set[str]:
        names = {m.name for m in self.modules}
        names.add("<convention-plugin>")
        return names

    @property
    def module_count(self) -> int:
        return len(self.modules)

    def longest_path_matches(self) -> list[ModuleRef]:
        return sorted(self.modules, key=lambda m: len(m.path), reverse=True)


def _build_module_context(module_map: dict[str, Any]) -> ModuleContext:
    modules: list[ModuleRef] = []
    primary = module_map.get("primaryAppModule")
    primary_name = ""
    if isinstance(primary, dict):
        p_name = primary.get("name")
        p_path = _normalize_rel(primary.get("path"))
        if isinstance(p_name, str) and p_name.strip() and p_path:
            primary_name = p_name.strip()
            modules.append(ModuleRef(name=primary_name, path=p_path))

    libs = module_map.get("libraryModulesInScope")
    if isinstance(libs, list):
        for lib in libs:
            if not isinstance(lib, dict):
                continue
            l_name = lib.get("name")
            l_path = _normalize_rel(lib.get("path"))
            if isinstance(l_name, str) and l_name.strip() and l_path:
                modules.append(ModuleRef(name=l_name.strip(), path=l_path))

    # Keep first seen module for each path.
    unique_by_path: dict[str, ModuleRef] = {}
    for mod in modules:
        if mod.path not in unique_by_path:
            unique_by_path[mod.path] = mod
    modules = list(unique_by_path.values())

    if not primary_name and modules:
        primary_name = modules[0].name

    convention_sources: set[str] = set()
    conv = module_map.get("conventionPlugins")
    if isinstance(conv, list):
        for entry in conv:
            if not isinstance(entry, dict):
                continue
            src = _normalize_rel(entry.get("sourceFile"))
            if src:
                convention_sources.add(src)

    return ModuleContext(
        primary_name=primary_name,
        modules=modules,
        convention_sources=convention_sources,
    )


def _infer_module_for_path(rel_path: str, ctx: ModuleContext) -> str | None:
    path = _normalize_rel(rel_path)
    if not path:
        return None

    if path in ctx.convention_sources:
        return "<convention-plugin>"

    for mod in ctx.longest_path_matches():
        if path == mod.path or path.startswith(mod.path + "/"):
            return mod.name

    if path.startswith("dynamics-migration-tool/") and ctx.primary_name:
        return ctx.primary_name

    if ctx.module_count == 1:
        return ctx.modules[0].name

    return None


def _refresh_validation_from_source_check(
    report: dict[str, Any],
    source_check: dict[str, Any] | None,
) -> bool:
    if not isinstance(source_check, dict):
        return False

    mode = _normalize_mode(source_check.get("mode"))
    status = source_check.get("status")
    exit_code = _to_int(source_check.get("exitCode"), 1)
    fail_count = _to_int(source_check.get("failCount"), 0)
    warn_count = _to_int(source_check.get("warnCount"), 0)
    passed = status == "passed" and exit_code == 0 and fail_count == 0

    next_validation = {
        "failures": fail_count,
        "mode": mode,
        "passed": passed,
        "warnings": warn_count,
    }

    changed = False
    if report.get("validation") != next_validation:
        report["validation"] = next_validation
        changed = True

    if passed:
        if report.get("blockingFailuresFromValidate") != []:
            report["blockingFailuresFromValidate"] = []
            changed = True
    else:
        failures: list[str] = []
        violations = source_check.get("violations")
        if isinstance(violations, list):
            for item in violations:
                if not isinstance(item, dict):
                    continue
                if item.get("severity") != "fail":
                    continue
                msg = item.get("message")
                if isinstance(msg, str) and msg.strip():
                    failures.append(msg.strip())
        if not failures:
            failures = ["Source validation reported failures; review output/.last-source-check.json"]
        if report.get("blockingFailuresFromValidate") != failures:
            report["blockingFailuresFromValidate"] = failures
            changed = True
    return changed


def _normalize_files_modified(report: dict[str, Any], ctx: ModuleContext) -> tuple[bool, list[str]]:
    changed = False
    errors: list[str] = []
    files = report.get("filesModified")
    if not isinstance(files, list):
        return changed, errors

    valid_names = ctx.valid_names
    for idx, entry in enumerate(files):
        if isinstance(entry, str):
            rel_path = _normalize_rel(entry)
            inferred = _infer_module_for_path(rel_path, ctx) if rel_path else None
            fallback_module = ctx.primary_name if ctx.module_count == 1 else ""
            files[idx] = {
                "changeType": "modified",
                "description": "Path recorded by migration prompt output.",
                "module": inferred or fallback_module,
                "path": rel_path or entry.strip(),
            }
            entry = files[idx]
            changed = True
        if not isinstance(entry, dict):
            errors.append(f"filesModified[{idx}] must be an object")
            continue
        rel_path = _normalize_rel(entry.get("path"))
        if not rel_path:
            errors.append(f"filesModified[{idx}].path must be a non-empty string")
            continue
        if entry.get("path") != rel_path:
            entry["path"] = rel_path
            changed = True
        change_type = entry.get("changeType")
        if not isinstance(change_type, str) or change_type not in {"modified", "created", "deleted"}:
            entry["changeType"] = "modified"
            changed = True
        description = entry.get("description")
        if not isinstance(description, str) or not description.strip():
            entry["description"] = "Path recorded by migration prompt output."
            changed = True
        inferred = _infer_module_for_path(rel_path, ctx)
        current = entry.get("module")
        current_norm = current.strip() if isinstance(current, str) else ""

        if inferred:
            if current_norm != inferred:
                entry["module"] = inferred
                changed = True
            continue

        if not current_norm:
            errors.append(
                f"filesModified[{idx}] path <{rel_path}> has no module and ownership could not be inferred"
            )
            continue
        if current_norm not in valid_names:
            errors.append(
                f"filesModified[{idx}].module <{current_norm}> is not in module-map.json and ownership could not be inferred"
            )
    return changed, errors


def _normalize_api_modules(report: dict[str, Any], ctx: ModuleContext) -> tuple[bool, list[str]]:
    changed = False
    errors: list[str] = []
    apis = report.get("apisReplaced")
    if not isinstance(apis, list):
        return changed, errors

    valid_names = ctx.valid_names
    for idx, entry in enumerate(apis):
        if not isinstance(entry, dict):
            continue
        if "sourceApi" in entry and not isinstance(entry.get("original"), str):
            src = entry.get("sourceApi")
            if isinstance(src, str) and src.strip():
                entry["original"] = src.strip()
                changed = True
        if "replacementApi" in entry and not isinstance(entry.get("replacement"), str):
            dst = entry.get("replacementApi")
            if isinstance(dst, str) and dst.strip():
                entry["replacement"] = dst.strip()
                changed = True
        if "beforeSnippet" in entry and not isinstance(entry.get("before"), str):
            before = entry.get("beforeSnippet")
            if isinstance(before, str) and before.strip():
                entry["before"] = before.strip()
                changed = True
        if "afterSnippet" in entry and not isinstance(entry.get("after"), str):
            after = entry.get("afterSnippet")
            if isinstance(after, str) and after.strip():
                entry["after"] = after.strip()
                changed = True
        if "occurrences" in entry and not isinstance(entry.get("count"), int):
            occ = entry.get("occurrences")
            if isinstance(occ, int):
                entry["count"] = occ
                changed = True
        if not isinstance(entry.get("before"), str):
            original = entry.get("original")
            if isinstance(original, str) and original.strip():
                entry["before"] = original.strip()
                changed = True
        if not isinstance(entry.get("after"), str):
            replacement = entry.get("replacement")
            if isinstance(replacement, str) and replacement.strip():
                entry["after"] = replacement.strip()
                changed = True
        if not isinstance(entry.get("count"), int):
            files_val = entry.get("files")
            if isinstance(files_val, list):
                entry["count"] = len(files_val)
                changed = True
        if not isinstance(entry.get("riskReason"), str):
            entry["riskReason"] = ""
            changed = True
        files_val = entry.get("files")
        file_paths: list[str] = []
        if isinstance(files_val, list):
            for raw in files_val:
                norm = _normalize_rel(raw)
                if norm:
                    file_paths.append(norm)

        inferred: set[str] = set()
        unresolved_files: list[str] = []
        for rel_path in file_paths:
            owner = _infer_module_for_path(rel_path, ctx)
            if owner:
                inferred.add(owner)
            else:
                unresolved_files.append(rel_path)

        if unresolved_files:
            errors.append(
                f"apisReplaced[{idx}] has file paths that cannot be mapped to a module: "
                + ", ".join(unresolved_files)
            )
            continue

        modules_val = entry.get("modules")
        if file_paths:
            if not inferred:
                errors.append(
                    f"apisReplaced[{idx}] has non-empty files[] but modules[] cannot be inferred"
                )
                continue
            next_modules = sorted(inferred)
            if modules_val != next_modules:
                entry["modules"] = next_modules
                changed = True
            continue

        # files[] empty or missing: keep modules[] if valid, else normalize to [].
        if modules_val is None:
            entry["modules"] = []
            changed = True
            continue
        if not isinstance(modules_val, list):
            entry["modules"] = []
            changed = True
            continue
        cleaned: list[str] = []
        for raw in modules_val:
            if not isinstance(raw, str):
                continue
            mod = raw.strip()
            if mod in valid_names and mod not in cleaned:
                cleaned.append(mod)
        if cleaned != modules_val:
            entry["modules"] = cleaned
            changed = True
    return changed, errors


def _format_min_sdk(project: dict[str, Any]) -> str:
    before = project.get("originalMinSdk")
    after = project.get("migratedMinSdk")
    if isinstance(before, int) and isinstance(after, int):
        if before == after:
            return str(before)
        return f"{before} -> {after}"
    return "unknown"


def _coalesce(*values: Any) -> str:
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _build_readme(report: dict[str, Any]) -> str:
    project = report.get("project") if isinstance(report.get("project"), dict) else {}
    summary = report.get("summary") if isinstance(report.get("summary"), dict) else {}
    toolkit = report.get("toolkit") if isinstance(report.get("toolkit"), dict) else {}
    uem = report.get("uemAdminHandoff") if isinstance(report.get("uemAdminHandoff"), dict) else {}

    app_name = _coalesce(project.get("name"), "Unknown")
    app_id = _coalesce(uem.get("gdApplicationId"), project.get("package"), "unknown")
    language = "mixed"
    min_sdk = _format_min_sdk(project)
    generated_at = _coalesce(report.get("generatedAt"))
    migration_date = generated_at.split("T")[0] if "T" in generated_at else (
        generated_at or datetime.now(timezone.utc).date().isoformat()
    )
    toolkit_version = _coalesce(toolkit.get("version"), "unknown")
    status = _coalesce(summary.get("overallStatus"), "partial").lower()

    apis = report.get("apisReplaced")
    api_lines: list[str] = []
    if isinstance(apis, list) and apis:
        by_cat: dict[str, int] = {}
        for row in apis:
            if not isinstance(row, dict):
                continue
            cat = _coalesce(row.get("category"), "uncategorized")
            by_cat[cat] = by_cat.get(cat, 0) + _to_int(row.get("count"), 0)
        for cat in sorted(by_cat):
            api_lines.append(f"- {cat}: {by_cat[cat]} replacement instance(s).")
    else:
        api_lines.append("- No cataloged API replacements were recorded.")

    unsupported = report.get("unsupportedFeatures")
    unsupported_lines: list[str] = []
    if isinstance(unsupported, list) and unsupported:
        for feat in unsupported:
            if not isinstance(feat, dict):
                continue
            feature = _coalesce(feat.get("feature"), "Unnamed feature")
            reason = _coalesce(feat.get("reason"), "No reason provided.")
            unsupported_lines.append(f"- {feature}: {reason}")
    else:
        unsupported_lines.append("- None detected.")

    todos = report.get("manualTodos")
    todo_lines: list[str] = []
    if isinstance(todos, list) and todos:
        for todo in todos:
            if not isinstance(todo, dict):
                continue
            title = _coalesce(todo.get("title"), todo.get("description"), "Manual follow-up")
            reason = _coalesce(todo.get("reason"))
            severity = _coalesce(todo.get("severity"), todo.get("priority"))
            prefix = f"[{severity}] " if severity else ""
            if reason:
                todo_lines.append(f"- {prefix}{title}: {reason}")
            else:
                todo_lines.append(f"- {prefix}{title}")
    else:
        todo_lines.append("- None.")

    testing = report.get("runtimeTestPlan")
    test_lines: list[str] = []
    if isinstance(testing, list) and testing:
        for scenario in testing:
            if not isinstance(scenario, dict):
                continue
            name = _coalesce(scenario.get("scenario"), "Unnamed scenario")
            expected = _coalesce(scenario.get("expectedResult"), scenario.get("expected"))
            if expected:
                test_lines.append(f"- {name}: {expected}")
            else:
                test_lines.append(f"- {name}")
    else:
        test_lines.append("- Runtime test plan not provided.")

    uem_lines: list[str] = [
        f"- GDApplicationID: `{_coalesce(uem.get('gdApplicationId'), 'unknown')}`",
        f"- GDApplicationVersion: `{_coalesce(uem.get('gdApplicationVersion'), 'unknown')}`",
    ]
    entitlement = _coalesce(uem.get("entitlementSetup"))
    if entitlement:
        uem_lines.append(f"- Entitlement setup: {entitlement}")
    connectivity = _coalesce(uem.get("connectivityProfile"))
    if connectivity:
        uem_lines.append(f"- Connectivity profile: {connectivity}")
    compliance = _coalesce(uem.get("complianceProfile"))
    if compliance:
        uem_lines.append(f"- Compliance profile: {compliance}")

    return "\n".join(
        [
            "# Dynamics Migration Summary",
            "",
            "## Overview",
            f"- App: {app_name}",
            f"- Application ID: {app_id}",
            f"- Language: {language}",
            f"- minSdk: {min_sdk}",
            f"- Migration date: {migration_date}",
            f"- Toolkit Version: {toolkit_version}",
            f"- Status: {status}",
            "",
            "## What Changed",
            *api_lines,
            "",
            "## Unsupported Features",
            *unsupported_lines,
            "",
            "## Manual TODOs",
            *todo_lines,
            "",
            "## UEM Admin Setup",
            *uem_lines,
            "",
            "## Testing",
            *test_lines,
            "",
            "## Finding Migration Changes",
            "All changes are tagged with `[BB_DYNAMICS-MIGRATION]`:",
            "```bash",
            'rg "\\[BB_DYNAMICS-MIGRATION\\]" -g "*.kt" -g "*.java" \\',
            '  -g "*.xml" -g "*.gradle" -g "*.gradle.kts" -n',
            "```",
            "",
        ]
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", required=True, help="Project root path")
    parser.add_argument("--report", required=True, help="Path to migration-report.json")
    parser.add_argument("--module-map", required=True, help="Path to module-map.json")
    parser.add_argument("--source-check", default="", help="Path to .last-source-check.json")
    parser.add_argument("--readme", required=True, help="Path to Dynamics_Migration_Readme.md")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    report_path = Path(args.report)
    module_map_path = Path(args.module_map)
    source_check_path = Path(args.source_check) if args.source_check else None
    readme_path = Path(args.readme)

    if not report_path.is_file():
        print(f"ERROR: migration report is missing: {report_path}", file=sys.stderr)
        return 1
    if not module_map_path.is_file():
        print(
            f"ERROR: module-map.json is required for deterministic module ownership: {module_map_path}",
            file=sys.stderr,
        )
        return 1

    try:
        report = _load_json(report_path)
        module_map = _load_json(module_map_path)
    except Exception as exc:
        print(f"ERROR: could not parse report/module-map: {exc}", file=sys.stderr)
        return 1

    source_check: dict[str, Any] | None = None
    if source_check_path and source_check_path.is_file():
        try:
            source_check = _load_json(source_check_path)
        except Exception as exc:
            print(f"ERROR: invalid source sidecar {source_check_path}: {exc}", file=sys.stderr)
            return 1

    ctx = _build_module_context(module_map)
    if not ctx.modules:
        print(
            "ERROR: module-map.json has no primary/library module entries; cannot infer report ownership",
            file=sys.stderr,
        )
        return 1

    changed = False
    prep_errors: list[str] = []

    files_changed, file_errors = _normalize_files_modified(report, ctx)
    apis_changed, api_errors = _normalize_api_modules(report, ctx)
    severity_changed = _normalize_manual_todo_severity_aliases(report)
    changed = changed or files_changed or apis_changed or severity_changed
    prep_errors.extend(file_errors)
    prep_errors.extend(api_errors)

    if _refresh_validation_from_source_check(report, source_check):
        changed = True

    if prep_errors:
        print("ERROR: report artifact preparation failed:", file=sys.stderr)
        for err in prep_errors:
            print(f"  - {err}", file=sys.stderr)
        print(
            "Fix the owning prompt output so module ownership can be derived from module-map.json.",
            file=sys.stderr,
        )
        return 1

    if changed:
        _write_json(report_path, report)

    readme = _build_readme(report)
    previous_readme = ""
    if readme_path.is_file():
        previous_readme = readme_path.read_text(encoding="utf-8")
    if previous_readme != readme:
        readme_path.write_text(readme, encoding="utf-8")
        changed = True

    if not args.quiet:
        if changed:
            print("OK: prompt-10 artifacts normalized (report + README)")
        else:
            print("OK: prompt-10 artifacts already normalized")
    return 0


if __name__ == "__main__":
    sys.exit(main())

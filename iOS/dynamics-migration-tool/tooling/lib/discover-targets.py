#!/usr/bin/env python3
"""
discover-targets.py — iOS target discovery for the Dynamics migration tool.

This script must be deterministic and offline-friendly. It discovers workspace
and project boundaries, parses PBX targets where possible, and records explicit
ambiguities instead of silently omitting scope.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import time
import uuid as _uuid
from typing import Any, Dict, List, Optional, Tuple

_OBJECT_RE = re.compile(
    r"([0-9A-F]{24})\s*/\*.*?\*/\s*=\s*\{(.*?)\};",
    re.DOTALL | re.IGNORECASE,
)
_KEY_VAL_RE = re.compile(r"(\w+)\s*=\s*((?:\"[^\"]*\"|[^;,\n{]+));")
_LIST_RE = re.compile(r"(\w+)\s*=\s*\((.*?)\);", re.DOTALL)
_BUILD_SETTINGS_RE = re.compile(r"buildSettings\s*=\s*\{(.*?)\};", re.DOTALL)
_WS_FILE_REF_RE = re.compile(r'location\s*=\s*"([^"]+)"')


def _iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _norm_rel(path: pathlib.Path, root: pathlib.Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except Exception:
        return str(path)


def _is_excluded_path(path: pathlib.Path) -> bool:
    excluded = {"Pods", "DerivedData", ".build", ".git", ".cursor", ".kiro"}
    return any(part in excluded for part in path.parts)


def _parse_object_map(pbxproj_text: str) -> Dict[str, Dict[str, Any]]:
    objects: Dict[str, Dict[str, Any]] = {}
    for match in _OBJECT_RE.finditer(pbxproj_text):
        uid = match.group(1)
        body = match.group(2)
        entry: Dict[str, Any] = {}

        for kv in _KEY_VAL_RE.finditer(body):
            key = kv.group(1)
            value = kv.group(2).strip().strip('"')
            entry[key] = value

        for lst in _LIST_RE.finditer(body):
            key = lst.group(1)
            if key in entry:
                continue
            raw_items = [i.strip() for i in lst.group(2).split(",") if i.strip()]
            items = [i.split("/*")[0].strip().strip('"') for i in raw_items]
            entry[key] = items

        bsm = _BUILD_SETTINGS_RE.search(body)
        if bsm:
            bs: Dict[str, str] = {}
            for kv in _KEY_VAL_RE.finditer(bsm.group(1)):
                k = kv.group(1)
                v = kv.group(2).strip().strip('"')
                bs[k] = v
            entry["buildSettings"] = bs

        objects[uid] = entry
    return objects


def _target_type(product_type: str) -> str:
    mapping = {
        "com.apple.product-type.application": "application",
        "com.apple.product-type.framework": "framework",
        "com.apple.product-type.library.static": "library",
        "com.apple.product-type.library.dynamic": "library",
        "com.apple.product-type.app-extension": "extension",
        "com.apple.product-type.extensionkit-extension": "extension",
        "com.apple.product-type.watchkit2-extension": "extension",
        "com.apple.product-type.tv-app-extension": "extension",
        "com.apple.product-type.widget-extension": "widget",
        "com.apple.product-type.application.on-demand-install-capable": "appclip",
        "com.apple.product-type.bundle.unit-test": "tests",
        "com.apple.product-type.bundle.ui-testing": "tests",
    }
    return mapping.get(product_type, "other")


def _unsupported_reason(target_type: str) -> Optional[str]:
    reasons = {
        "extension": "App extensions cannot access the Dynamics secure container",
        "widget": "Widget extensions cannot access the Dynamics secure container",
        "appclip": "App Clips cannot access the Dynamics secure container",
    }
    return reasons.get(target_type)


def _extension_point_identifier(project_root: pathlib.Path, info_plist_rel: Optional[str]) -> Optional[str]:
    if not info_plist_rel:
        return None
    path = (project_root / info_plist_rel).resolve()
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    # Prefer XML plist key; also accept open-step-ish dumps.
    m = re.search(
        r"<key>\s*NSExtensionPointIdentifier\s*</key>\s*<string>\s*([^<]+?)\s*</string>",
        text,
    )
    if m:
        return m.group(1).strip()
    m = re.search(r"NSExtensionPointIdentifier\s*=\s*([^;]+);", text)
    if m:
        return m.group(1).strip().strip('"')
    return None


def _refine_extension_unsupported(
    target_type: str, name: str, extension_point: Optional[str]
) -> Tuple[Optional[str], Optional[str]]:
    """
    Returns (unsupportedReason, extensionPoint) for extension-like targets.
    Share Extensions get an explicit Dynamics-unsupported reason.
    """
    point = (extension_point or "").strip() or None
    lowered = re.sub(r"[^a-z0-9]", "", (name or "").lower())
    is_share = point == "com.apple.share-services" or "shareextension" in lowered or lowered.endswith("share")
    if target_type == "extension" and is_share:
        return (
            "Share Extensions are unsupported by BlackBerry Dynamics — "
            "exclude from Dynamics shipping; do not authorize inside the extension "
            "(see steering/17-app-extensions-and-share-extensions.md)",
            point or "com.apple.share-services",
        )
    if target_type in {"extension", "widget", "appclip"}:
        return (_unsupported_reason(target_type), point)
    return (None, point)


def _parse_workspace_projects(workspace_path: pathlib.Path, root: pathlib.Path) -> Dict[str, Any]:
    refs: List[str] = []
    unresolved: List[str] = []
    ws_data = workspace_path / "contents.xcworkspacedata"
    if not ws_data.exists():
        return {
            "path": _norm_rel(workspace_path, root),
            "referencedProjects": refs,
            "unresolvedReferences": ["contents.xcworkspacedata missing"],
        }

    text = ws_data.read_text(encoding="utf-8", errors="replace")
    for loc in _WS_FILE_REF_RE.findall(text):
        if not (loc.startswith("group:") or loc.startswith("container:")):
            continue
        raw_rel = loc.split(":", 1)[1]
        ref_path = (workspace_path.parent / raw_rel).resolve()
        if ref_path.suffix != ".xcodeproj":
            continue
        if ref_path.exists():
            refs.append(_norm_rel(ref_path, root))
        else:
            unresolved.append(raw_rel)

    return {
        "path": _norm_rel(workspace_path, root),
        "referencedProjects": sorted(set(refs)),
        "unresolvedReferences": sorted(set(unresolved)),
    }


def _discover_candidate_projects(root: pathlib.Path, workspace_refs: List[str]) -> List[pathlib.Path]:
    projects: set[pathlib.Path] = set()
    for p in root.glob("*.xcodeproj"):
        if p.is_dir():
            projects.add(p.resolve())
    for p in root.glob("*/*.xcodeproj"):
        if p.is_dir() and not _is_excluded_path(p):
            projects.add(p.resolve())
    for rel in workspace_refs:
        p = (root / rel).resolve()
        if p.exists():
            projects.add(p)
    return sorted(projects)


def _collect_source_roots(paths: List[str]) -> List[str]:
    roots: List[str] = []
    for p in paths:
        if "/" in p:
            roots.append(p.split("/", 1)[0])
    return sorted(set(roots))


def _scan_fallback_file(project_root: pathlib.Path, suffix: str) -> Optional[str]:
    for path in sorted(project_root.rglob(suffix)):
        if _is_excluded_path(path):
            continue
        return _norm_rel(path, project_root)
    return None


def _extract_target_build_setting(
    objects: Dict[str, Dict[str, Any]], target_obj: Dict[str, Any], setting_key: str
) -> Optional[str]:
    cfg_list_id = target_obj.get("buildConfigurationList")
    if not cfg_list_id:
        return None
    cfg_list = objects.get(cfg_list_id, {})
    for cfg_id in cfg_list.get("buildConfigurations", []):
        cfg = objects.get(cfg_id, {})
        settings = cfg.get("buildSettings")
        if isinstance(settings, dict) and setting_key in settings:
            return str(settings[setting_key])
    return None


def _parse_project_targets(project_root: pathlib.Path, project_path: pathlib.Path) -> Dict[str, Any]:
    rel_project = _norm_rel(project_path, project_root)
    pbx = project_path / "project.pbxproj"
    if not pbx.exists():
        return {"projectPath": rel_project, "parsed": False, "error": "project.pbxproj missing", "targets": []}

    text = pbx.read_text(encoding="utf-8", errors="replace")
    objects = _parse_object_map(text)

    targets: List[Dict[str, Any]] = []
    for uid, obj in objects.items():
        isa = obj.get("isa")
        if isa not in {"PBXNativeTarget", "PBXAggregateTarget"}:
            continue

        name = str(obj.get("name", "")).strip()
        product_type = str(obj.get("productType", "")).strip()
        t_type = _target_type(product_type)
        unsupported_reason = _unsupported_reason(t_type)

        source_files: List[str] = []
        build_phases = obj.get("buildPhases", [])
        if isinstance(build_phases, str):
            build_phases = [build_phases]
        for phase_id in build_phases:
            phase = objects.get(phase_id, {})
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            file_refs = phase.get("files", [])
            if isinstance(file_refs, str):
                file_refs = [file_refs]
            for bf_id in file_refs:
                bf = objects.get(bf_id, {})
                file_uid = bf.get("fileRef")
                if not file_uid:
                    continue
                fobj = objects.get(file_uid, {})
                fpath = fobj.get("path")
                if isinstance(fpath, str) and fpath:
                    source_files.append(fpath)

        source_roots = _collect_source_roots(source_files)
        if not source_roots and name:
            # Conservative fallback to target-name root.
            source_roots = [name]

        info_plist = _extract_target_build_setting(objects, obj, "INFOPLIST_FILE")
        entitlements = _extract_target_build_setting(objects, obj, "CODE_SIGN_ENTITLEMENTS")
        bridging_header = _extract_target_build_setting(objects, obj, "SWIFT_OBJC_BRIDGING_HEADER")

        if not info_plist:
            info_plist = _scan_fallback_file(project_root, "Info.plist")
        if not entitlements:
            entitlements = _scan_fallback_file(project_root, ".entitlements")
        if not bridging_header:
            bridging_header = _scan_fallback_file(project_root, "-Bridging-Header.h")

        extension_point = _extension_point_identifier(project_root, info_plist if isinstance(info_plist, str) else None)
        unsupported_reason, extension_point = _refine_extension_unsupported(t_type, name, extension_point)

        dep_names: List[str] = []
        deps = obj.get("dependencies", [])
        if isinstance(deps, str):
            deps = [deps]
        for dep_id in deps:
            dep_obj = objects.get(dep_id, {})
            target_uid = dep_obj.get("target")
            if not target_uid:
                continue
            dep_target = objects.get(target_uid, {})
            dep_name = dep_target.get("name")
            if isinstance(dep_name, str) and dep_name:
                dep_names.append(dep_name)

        targets.append(
            {
                "id": f"{project_path.stem}:{uid}",
                "name": name,
                "type": t_type,
                "productType": product_type,
                "projectPath": rel_project,
                "sourceRoots": sorted(set(source_roots)),
                "infoPlistPath": info_plist,
                "entitlementsPath": entitlements,
                "bridgingHeaderPath": bridging_header,
                "extensionPointIdentifier": extension_point,
                "dependencies": sorted(set(dep_names)),
                "packageManagerBoundary": "manual",
                "unsupported": unsupported_reason is not None,
                "unsupportedReason": unsupported_reason,
            }
        )

    return {
        "projectPath": rel_project,
        "parsed": True,
        "targetCount": len(targets),
        "targets": targets,
    }


def discover_targets(project_root: pathlib.Path, run_id: str) -> Dict[str, Any]:
    ambiguities: List[str] = []

    workspaces = sorted([p for p in project_root.glob("*.xcworkspace") if p.is_dir()])
    workspace_maps = [_parse_workspace_projects(ws, project_root) for ws in workspaces]
    ws_project_refs = [p for ws in workspace_maps for p in ws["referencedProjects"]]

    package_swift = project_root / "Package.swift"
    package_only_layout = package_swift.exists() and not workspaces and not any(project_root.glob("*.xcodeproj"))

    candidate_projects = _discover_candidate_projects(project_root, ws_project_refs)
    parsed_projects: List[Dict[str, Any]] = []
    targets: List[Dict[str, Any]] = []

    spm_count = 0
    for proj in candidate_projects:
        rel = _norm_rel(proj, project_root)
        if "Pods/" in rel or rel.startswith("Pods/"):
            parsed_projects.append(
                {
                    "projectPath": rel,
                    "parsed": False,
                    "isPodsProject": True,
                    "reason": "CocoaPods boundary project intentionally not expanded",
                }
            )
            continue
        parsed = _parse_project_targets(project_root, proj)
        parsed_projects.append({k: v for k, v in parsed.items() if k != "targets"})
        targets.extend(parsed.get("targets", []))
        pbx = proj / "project.pbxproj"
        if pbx.exists():
            text = pbx.read_text(encoding="utf-8", errors="replace")
            spm_count += len(re.findall(r"XCRemoteSwiftPackageReference|XCLocalSwiftPackageReference", text))

    has_podfile = (project_root / "Podfile").exists()
    has_spm = bool(spm_count > 0 or package_swift.exists())

    build_type = "unresolved"
    build_path: Optional[str] = None
    build_reason = "Could not determine canonical entrypoint"

    if package_only_layout:
        build_reason = "Package-only layout detected (no .xcodeproj/.xcworkspace)"
        ambiguities.append(build_reason)
    elif len(workspaces) == 1:
        build_type = "workspace"
        build_path = _norm_rel(workspaces[0], project_root)
        build_reason = "Single workspace discovered"
        ws_ref_count = len(workspace_maps[0].get("referencedProjects", []))
        if ws_ref_count == 0:
            ambiguities.append("Workspace has no resolvable .xcodeproj references")
        if ws_ref_count > 1:
            ambiguities.append("Workspace references multiple projects; verify canonical app entrypoint")
    elif len(workspaces) > 1:
        build_reason = "Multiple workspaces discovered"
        ambiguities.append(build_reason)
    elif len(candidate_projects) == 1:
        build_type = "project"
        build_path = _norm_rel(candidate_projects[0], project_root)
        build_reason = "Single project discovered"
    elif len(candidate_projects) > 1:
        build_reason = "Multiple projects discovered without a canonical workspace"
        ambiguities.append(build_reason)
    else:
        ambiguities.append("No .xcodeproj or .xcworkspace found")

    if not targets and not package_only_layout:
        ambiguities.append("No PBX targets were discovered from candidate projects")

    has_app_target = any(t.get("type") == "application" for t in targets)
    has_extension_target = any(t.get("type") == "extension" for t in targets)
    has_widget_target = any(t.get("type") == "widget" for t in targets)
    if not has_app_target and not package_only_layout:
        ambiguities.append("No application target discovered; migration scope may be incomplete")

    package_boundary = "mixed" if (has_podfile and has_spm) else ("cocoapods" if has_podfile else ("spm" if has_spm else "manual"))
    for t in targets:
        t["packageManagerBoundary"] = package_boundary if package_boundary != "manual" else "manual"

    return {
        "schemaVersion": "1.0.0",
        "platform": "ios",
        "runId": run_id,
        "generatedAt": _iso_now(),
        "projectRoot": str(project_root),
        "buildEntrypoint": {
            "type": build_type,
            "path": build_path,
            "reason": build_reason,
        },
        "targets": targets,
        "packageManager": {
            "hasPodfile": has_podfile,
            "podfilePath": "Podfile" if has_podfile else None,
            "hasSpmDependencies": has_spm,
            "spmCount": spm_count,
            "hasPackageSwift": package_swift.exists(),
            "packageSwiftPath": "Package.swift" if package_swift.exists() else None,
        },
        "workspaces": workspace_maps,
        "projects": parsed_projects,
        "discoveryStatus": {
            "packageOnlyLayout": package_only_layout,
            "hasApplicationTarget": has_app_target,
            "hasExtensionTarget": has_extension_target,
            "hasWidgetTarget": has_widget_target,
        },
        "ambiguities": sorted(set(ambiguities)),
        "provenance": {
            "discoveryMethod": "pbxproj-parse",
            "requiresXcodebuild": False,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Discover iOS Xcode targets for migration tooling")
    parser.add_argument("--project-root", required=True, help="Path to project root")
    parser.add_argument("--run-id", default=str(_uuid.uuid4()), help="Run id")
    parser.add_argument("--output", required=True, help="Output target-map.json path")
    args = parser.parse_args()

    project_root = pathlib.Path(args.project_root).resolve()
    if not project_root.exists():
        print(f"ERROR: project root not found: {project_root}", file=sys.stderr)
        return 1

    try:
        payload = discover_targets(project_root, args.run_id)
    except Exception as exc:
        print(f"ERROR: target discovery failed: {exc}", file=sys.stderr)
        return 2

    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot write target map: {exc}", file=sys.stderr)
        return 3

    print(
        "OK: target-map.json written — "
        f"{len(payload.get('targets', []))} target(s), "
        f"{len(payload.get('projects', []))} project(s), "
        f"{len(payload.get('ambiguities', []))} ambiguity(ies)"
    )
    for warning in payload.get("ambiguities", []):
        print(f"  WARN: {warning}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

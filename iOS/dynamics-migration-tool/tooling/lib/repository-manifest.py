#!/usr/bin/env python3
"""Generate a content-free repository manifest for migration context reuse.

The manifest is an index, not a cache. Agents can use it to avoid rediscovering
stable toolkit facts and to invalidate prior analysis when file fingerprints
change. Deterministic validators still read and verify the source tree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple


EXCLUDED_DIRS = {
    ".git",
    ".gradle",
    ".idea",
    ".kiro",
    ".pytest_cache",
    "__pycache__",
    "build",
    "DerivedData",
    "node_modules",
    "Pods",
}

EXCLUDED_PREFIXES = {
    "dynamics-migration-tool/output/observability",
}

SECRET_NAMES = {
    ".env",
    "credentials.json",
    "google-services.json",
    "local.properties",
    "secrets.properties",
}

SECRET_SUFFIXES = {
    ".jks",
    ".keystore",
    ".mobileprovision",
    ".p12",
    ".pem",
}

SOURCE_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".cxx",
    ".h",
    ".hpp",
    ".java",
    ".kt",
    ".kts",
    ".m",
    ".mm",
    ".swift",
    ".xml",
}

BUILD_NAMES = {
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "gradle.properties",
    "libs.versions.toml",
    "Podfile",
    "Package.swift",
}

GENERATED_OUTPUT_NAMES = {
    "bootstrap.json",
    "module-map.json",
    "target-map.json",
    "migration-analysis.json",
    "migration-plan-state.json",
    "migration-report.json",
    "architecture-diagrams.md",
    ".last-check.json",
    ".last-source-check.json",
    ".last-report-check.json",
}


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load_json(path: Path) -> Dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        delete=False,
        dir=str(path.parent),
        prefix=f"{path.name}.tmp.",
    ) as tmp:
        tmp.write(text)
        tmp_path = Path(tmp.name)
    os.replace(tmp_path, path)


def rel_path(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def should_skip_dir(path: Path, root: Path) -> bool:
    name = path.name
    if name in EXCLUDED_DIRS:
        return True
    try:
        rel = rel_path(path, root)
    except Exception:
        return True
    return any(rel == prefix or rel.startswith(prefix + "/") for prefix in EXCLUDED_PREFIXES)


def is_secret_like(rel: str, path: Path) -> bool:
    lower_name = path.name.lower()
    lower_rel = rel.lower()
    if lower_name in SECRET_NAMES:
        return True
    if any(lower_name.endswith(suffix) for suffix in SECRET_SUFFIXES):
        return True
    return "secret" in lower_rel or "credential" in lower_rel


def classify(rel: str, path: Path) -> Tuple[str, str, str]:
    if is_secret_like(rel, path):
        return "security-sensitive", "never cache", "hash omitted for secret-like path"
    parts = rel.split("/")
    name = path.name
    suffix = path.suffix

    if rel.startswith("dynamics-migration-tool/steering/") or rel.startswith("dynamics-migration-tool/prompts/"):
        return "toolkit-guidance", "safe reuse", "reuse while contentHash matches"
    if rel.startswith("dynamics-migration-tool/schemas/") or rel.startswith("dynamics-migration-tool/contracts/"):
        return "toolkit-contract", "safe reuse", "reuse while contentHash matches"
    if len(parts) >= 3 and parts[0] == "dynamics-migration-tool" and parts[1] == "output":
        if name in GENERATED_OUTPUT_NAMES:
            return "migration-state", "revalidation required", "generated state changes during migration"
        return "generated-output", "revalidation required", "generated output changes during migration"
    if name in BUILD_NAMES or suffix in {".gradle", ".kts", ".pbxproj", ".xcconfig", ".entitlements", ".plist"}:
        return "build-or-config", "revalidation required", "build and entitlement changes affect scope"
    if suffix in SOURCE_SUFFIXES:
        return "source", "revalidation required", "source changes require reread and validation"
    if suffix in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".pdf", ".jar", ".aar", ".xcframework", ".framework"}:
        return "binary-or-asset", "agent-framework dependent", "agent may not need content unless referenced"
    return "other", "revalidation required", "reuse only while contentHash matches and owner prompt allows it"


def hash_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def iter_files(root: Path) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        dirnames[:] = sorted(
            d for d in dirnames if not should_skip_dir(current / d, root)
        )
        for filename in sorted(filenames):
            path = current / filename
            if path.is_file():
                yield path


def build_manifest(project_root: Path, tool_dir: Path, platform: str, run_id: str) -> Dict[str, Any]:
    entries: List[Dict[str, Any]] = []
    totals: Dict[str, Any] = {
        "fileCount": 0,
        "bytes": 0,
        "hashedFileCount": 0,
        "hashOmittedCount": 0,
        "reuseClassCounts": {},
        "kindCounts": {},
    }

    for path in iter_files(project_root):
        try:
            rel = rel_path(path, project_root)
            stat = path.stat()
        except Exception:
            continue
        kind, reuse_class, invalidation = classify(rel, path)
        entry: Dict[str, Any] = {
            "path": rel,
            "sizeBytes": stat.st_size,
            "modifiedTimeMs": int(stat.st_mtime * 1000),
            "kind": kind,
            "reuseClass": reuse_class,
            "invalidation": invalidation,
        }
        if is_secret_like(rel, path):
            entry["contentHash"] = None
            entry["hashOmittedReason"] = "secret-like path"
            totals["hashOmittedCount"] += 1
        else:
            try:
                entry["contentHash"] = hash_file(path)
                totals["hashedFileCount"] += 1
            except Exception:
                entry["contentHash"] = None
                entry["hashOmittedReason"] = "unreadable"
                totals["hashOmittedCount"] += 1

        totals["fileCount"] += 1
        totals["bytes"] += stat.st_size
        totals["reuseClassCounts"][reuse_class] = totals["reuseClassCounts"].get(reuse_class, 0) + 1
        totals["kindCounts"][kind] = totals["kindCounts"].get(kind, 0) + 1
        entries.append(entry)

    bootstrap = load_json(tool_dir / "output/bootstrap.json")
    if not run_id:
        run_id = str(bootstrap.get("runId") or "")

    return {
        "schemaVersion": "1.0.0",
        "generatedAt": iso_now(),
        "platform": platform,
        "runId": run_id,
        "projectRoot": ".",
        "toolkitRoot": "dynamics-migration-tool",
        "entries": entries,
        "totals": totals,
        "reusePolicy": {
            "safe reuse": "Stable toolkit guidance or contracts may be reused while contentHash matches.",
            "revalidation required": "Application source, build/config, and generated state require reread or validator proof when changed.",
            "never cache": "Secret-like files are indexed only by metadata; content hashes are omitted.",
            "agent-framework dependent": "Reuse depends on whether the agent framework can retain or retrieve non-text assets safely.",
        },
        "excludedDirectories": sorted(EXCLUDED_DIRS),
        "excludedPrefixes": sorted(EXCLUDED_PREFIXES),
    }


def write_summary(manifest: Dict[str, Any], path: Path) -> None:
    totals = manifest.get("totals", {})
    lines = [
        "# Repository Context Summary",
        "",
        f"Generated: {manifest.get('generatedAt', '')}",
        f"Platform: {manifest.get('platform', '')}",
        f"Run ID: {manifest.get('runId', '') or 'not recorded'}",
        "",
        "## Totals",
        "",
        f"- Files indexed: {totals.get('fileCount', 0)}",
        f"- Bytes indexed: {totals.get('bytes', 0)}",
        f"- Files hashed: {totals.get('hashedFileCount', 0)}",
        f"- Hashes omitted: {totals.get('hashOmittedCount', 0)}",
        "",
        "## Reuse Classes",
        "",
    ]
    for key, value in sorted((totals.get("reuseClassCounts") or {}).items()):
        lines.append(f"- {key}: {value}")
    lines.extend(
        [
            "",
            "## Agent Guidance",
            "",
            "- Read `output/repository-manifest.json` before broad source rediscovery.",
            "- Reuse toolkit steering or contract facts only when the recorded `contentHash` still matches.",
            "- Reread and revalidate application source, build/config, and generated migration state when their manifest entries change.",
            "- Never rely on cached contents for entries classified `never cache`; hashes are intentionally omitted.",
            "- Deterministic validators remain authoritative and must still run at their required gates.",
            "",
        ]
    )
    atomic_write(path, "\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate repository manifest for migration context reuse")
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--tool-dir", required=True)
    parser.add_argument("--platform", required=True, choices=("android", "ios"))
    parser.add_argument("--run-id", default="")
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary-output", required=True)
    args = parser.parse_args()

    project_root = Path(args.project_root).resolve()
    tool_dir = Path(args.tool_dir).resolve()
    manifest = build_manifest(project_root, tool_dir, args.platform, args.run_id)
    atomic_write(Path(args.output), json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    write_summary(manifest, Path(args.summary_output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Detect incomplete sqlite3enc migrations that still link system libsqlite3.

Failure mode (UIKit / FMDB / shared SPM SQL packages):
  sqlite3enc_open (Dynamics) + sqlite3_exec from /usr/lib/libsqlite3.dylib
  → SIGSEGV on first post-auth DB open.

This checker is source-level and intentionally scans Modules / SPM packages
even when validate.sh APP_EXCLUDE_ROOTS hides them from unmanaged-SQL greps.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

SKIP_DIR_NAMES = {
    "dynamics-migration-tool",
    ".cursor",
    ".kiro",
    "Pods",
    ".build",
    "DerivedData",
    ".git",
    "Carthage",
    "build",
}
SKIP_SUFFIXES = ("Tests", "UITests", "-macOS", "-watchOS", "-tvOS")

SQLITE3ENC_RE = re.compile(r"\bsqlite3enc_open(?:_v2)?\b|sqlite3enc\.h")
SYSTEM_SQLITE_INCLUDE_RE = re.compile(
    r"""(?x)
    ^\s*\#\s*include\s*<sqlite3\.h>
    |^\s*\#\s*import\s*<sqlite3\.h>
    |^\s*\#\s*include_next\s*<sqlite3\.h>
    """,
    re.MULTILINE,
)
DYNAMICS_SQLITE_INCLUDE_RE = re.compile(
    r"""(?x)
    BlackBerryDynamics/GD_C/sqlite3(?:enc)?\.h
    |@import\s+GD_C\.SecureStore\.SQLite
    |import\s+GD_C\.SecureStore\.SQLite
    |GD_C/sqlite3(?:enc)?\.h
    """
)
LINKED_LIB_SQLITE_RE = re.compile(
    r"""\.linkedLibrary\(\s*["']sqlite3["']\s*\)"""
)
LINKED_LIB_SQLITE_WHEN_RE = re.compile(
    r"""\.linkedLibrary\(\s*["']sqlite3["']\s*,\s*\.when\([^)]*\)\s*\)""",
    re.DOTALL,
)
BB_PRODUCT_DEP_RE = re.compile(
    r"""\.product\(\s*name:\s*["']BlackBerryDynamics["']"""
)
PLATFORM_MACOS_ONLY_RE = re.compile(
    r"""\.when\(\s*platforms:\s*\[[^\]]*\.macOS[^\]]*\]\s*\)"""
)
OPEN_ONLY_BRIDGE_HINT_RE = re.compile(
    r"""(?ix)
    (install\w*encrypted\w*sqlite\w*open
    |sqlite3_open\s*=\s*sqlite3enc_open
    |openfunction\s*=\s*sqlite3enc_open
    |set\w*open\w*function\w*\s*\()
    """
)


def should_skip(path: Path, project_root: Path) -> bool:
    try:
        rel_parts = path.relative_to(project_root).parts
    except ValueError:
        return True
    if any(part in SKIP_DIR_NAMES for part in rel_parts):
        return True
    if any(part.endswith(SKIP_SUFFIXES) for part in rel_parts):
        return True
    return False


def iter_files(project_root: Path, suffixes: Tuple[str, ...]) -> List[Path]:
    files: List[Path] = []
    for path in project_root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix not in suffixes and path.name != "Package.swift":
            continue
        if should_skip(path, project_root):
            continue
        files.append(path)
    return files


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def nearest_package_swift(path: Path, project_root: Path) -> Optional[Path]:
    cur = path if path.is_dir() else path.parent
    while True:
        candidate = cur / "Package.swift"
        if candidate.is_file():
            return candidate
        if cur == project_root or cur.parent == cur:
            return None
        try:
            cur.relative_to(project_root)
        except ValueError:
            return None
        cur = cur.parent


def ios_links_system_sqlite(package_text: str) -> bool:
    """True when Package.swift links system sqlite3 for iOS (not macOS-only)."""
    if not LINKED_LIB_SQLITE_RE.search(package_text):
        return False
    # Conditional macOS-only forms are OK.
    for match in LINKED_LIB_SQLITE_RE.finditer(package_text):
        window_start = max(0, match.start() - 120)
        window_end = min(len(package_text), match.end() + 160)
        window = package_text[window_start:window_end]
        if PLATFORM_MACOS_ONLY_RE.search(window):
            continue
        if LINKED_LIB_SQLITE_WHEN_RE.search(window) and ".macOS" in window and ".iOS" not in window:
            continue
        # Bare .linkedLibrary("sqlite3") without macOS-only when → iOS hazard.
        if ".when(" not in window[window.find(".linkedLibrary") :]:
            return True
        if ".iOS" in window or "platforms:" not in window:
            return True
    return False


def package_has_bb_product(package_text: str) -> bool:
    return bool(BB_PRODUCT_DEP_RE.search(package_text))


def analyze(project_root: Path) -> Dict[str, Any]:
    failures: List[str] = []
    warnings: List[str] = []
    passes: List[str] = []

    source_files = iter_files(project_root, (".swift", ".m", ".mm", ".h", ".c", ".hpp", ".cpp"))
    package_files = [p for p in iter_files(project_root, ()) if p.name == "Package.swift"]

    enc_files = [p for p in source_files if SQLITE3ENC_RE.search(read_text(p))]
    if not enc_files:
        return {
            "status": "skip",
            "passes": ["No sqlite3enc usage detected — SQL linkage check skipped"],
            "warnings": [],
            "failures": [],
        }

    passes.append(f"sqlite3enc usage detected in {len(enc_files)} file(s)")

    # 1) System sqlite includes co-located with sqlite3enc without Dynamics headers.
    for path in enc_files:
        text = read_text(path)
        if SYSTEM_SQLITE_INCLUDE_RE.search(text) and not DYNAMICS_SQLITE_INCLUDE_RE.search(text):
            rel = path.relative_to(project_root).as_posix()
            failures.append(
                f"{rel}: uses sqlite3enc but still includes system <sqlite3.h> "
                "without BlackBerryDynamics/GD_C SQLite headers — encrypted handles "
                "are incompatible with system libsqlite3 (SIGSEGV on sqlite3_exec)"
            )

    # 2) Sibling headers in the same directory that include system sqlite3 while
    #    another file uses sqlite3enc (common FMDB / shared SPM SQL layout).
    enc_dirs: Set[Path] = {p.parent for p in enc_files}
    for directory in enc_dirs:
        has_dynamics_header = False
        system_headers: List[Path] = []
        for sibling in directory.iterdir() if directory.is_dir() else []:
            if not sibling.is_file() or sibling.suffix not in {".h", ".m", ".mm", ".c"}:
                continue
            if should_skip(sibling, project_root):
                continue
            text = read_text(sibling)
            if DYNAMICS_SQLITE_INCLUDE_RE.search(text):
                has_dynamics_header = True
            if SYSTEM_SQLITE_INCLUDE_RE.search(text) and not DYNAMICS_SQLITE_INCLUDE_RE.search(text):
                system_headers.append(sibling)
        if system_headers and not has_dynamics_header:
            for hdr in system_headers:
                rel = hdr.relative_to(project_root).as_posix()
                failures.append(
                    f"{rel}: system <sqlite3.h> in a module that also uses sqlite3enc; "
                    "redirect this header to BlackBerryDynamics/GD_C/sqlite3.h + sqlite3enc.h "
                    "and link BlackBerryDynamics on iOS (do not keep system libsqlite3)"
                )

    # 3) Package.swift linkage / product dependency rules for packages that
    #    contain sqlite3enc sources.
    checked_packages: Set[Path] = set()
    for enc_file in enc_files:
        pkg = nearest_package_swift(enc_file, project_root)
        if pkg is None or pkg in checked_packages:
            continue
        checked_packages.add(pkg)
        text = read_text(pkg)
        rel = pkg.relative_to(project_root).as_posix()

        if ios_links_system_sqlite(text):
            failures.append(
                f"{rel}: links system libsqlite3 for iOS while package sources use "
                "sqlite3enc — use BlackBerryDynamics product dependency on iOS and "
                "keep .linkedLibrary(\"sqlite3\") macOS-only"
            )

        if not package_has_bb_product(text):
            # Open-only bridges inside SPM packages without BB product are a
            # known post-auth SIGSEGV failure mode.
            pkg_sources_have_open_only = False
            for src in enc_files:
                if nearest_package_swift(src, project_root) == pkg and OPEN_ONLY_BRIDGE_HINT_RE.search(
                    read_text(src)
                ):
                    pkg_sources_have_open_only = True
                    break
            # Also scan other files in package for open-only install helpers.
            if not pkg_sources_have_open_only:
                for src in source_files:
                    if nearest_package_swift(src, project_root) != pkg:
                        continue
                    if OPEN_ONLY_BRIDGE_HINT_RE.search(read_text(src)):
                        pkg_sources_have_open_only = True
                        break
            if pkg_sources_have_open_only:
                failures.append(
                    f"{rel}: open-only sqlite3enc bridge detected without "
                    "BlackBerryDynamics product dependency — FMDB/exec/prepare must "
                    "resolve sqlite3_* from Dynamics SQLite, not system libsqlite3"
                )
            else:
                warnings.append(
                    f"{rel}: uses sqlite3enc but has no BlackBerryDynamics product "
                    "dependency; verify iOS linkage resolves all sqlite3_* from Dynamics"
                )
        else:
            passes.append(f"{rel}: BlackBerryDynamics product dependency present")

    # 4) Top-level Package.swift files that still link sqlite3 unconditionally
    #    when any sqlite3enc usage exists in the tree.
    for pkg in package_files:
        if pkg in checked_packages:
            continue
        text = read_text(pkg)
        if ios_links_system_sqlite(text) and SQLITE3ENC_RE.search(
            "\n".join(read_text(p) for p in enc_files)
        ):
            # Only warn for unrelated packages unless they mention sqlite/FMDB.
            if re.search(r"sqlite|FMDB|FMDatabase", text, re.I):
                rel = pkg.relative_to(project_root).as_posix()
                failures.append(
                    f"{rel}: SQLite-related package still links system libsqlite3 on iOS "
                    "while the app uses sqlite3enc"
                )

    # 5) SPM public-header hygiene: Dynamics SQL headers under include/ without
    #    umbrella mention (PCM / umbrella validation failures).
    for path in source_files:
        if path.suffix != ".h":
            continue
        rel = path.relative_to(project_root).as_posix()
        if "/include/" not in rel:
            continue
        text = read_text(path)
        if not DYNAMICS_SQLITE_INCLUDE_RE.search(text) and not SQLITE3ENC_RE.search(text):
            continue
        # Prefer private headers; public Dynamics SQL shims are a footgun.
        warnings.append(
            f"{rel}: Dynamics SQL shim under SPM public include/; prefer a private "
            "header beside FMDB .m sources (or update the umbrella header in the "
            "same change — never leak GD_C into every consumer)"
        )

    status = "fail" if failures else "pass"
    return {
        "status": status,
        "passes": passes,
        "warnings": warnings,
        "failures": failures,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Check sqlite3enc / system SQLite linkage hazards")
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    args = parser.parse_args()

    project_root = Path(args.project_root).resolve()
    if not project_root.is_dir():
        print(f"ERROR: project root not found: {project_root}", file=sys.stderr)
        return 2

    result = analyze(project_root)
    if args.json:
        print(json.dumps(result, indent=2))
        # Always 0 for --json so callers can capture stdout under set -e;
        # status is in the payload.
        return 0
    for msg in result["passes"]:
        print(f"PASS:{msg}")
    for msg in result["warnings"]:
        print(f"WARN:{msg}")
    for msg in result["failures"]:
        print(f"FAIL:{msg}")
    if result["status"] == "skip":
        print("SKIP:no sqlite3enc usage")
    return 1 if result["status"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())

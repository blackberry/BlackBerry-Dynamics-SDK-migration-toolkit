#!/usr/bin/env python3
"""Detect Compose ICC flows still using View-system chooser dialogs.

Usage: compose-icc-chooser-scan.py <source-root> [<source-root> ...]

Prints:
  OK
  UNMANAGED|<count>|<relpath>:<lineno>:<kind>;...

Exits 0 always (caller interprets stdout).
"""
from __future__ import annotations

import os
import re
import sys

ICC_MARKERS = re.compile(
    r"sendFiles\s*\(|showShareChooser\s*\(|getAvailableProviders\s*\(|"
    r"GDServiceClient\.sendTo|GDServiceProvider|com\.good\.gdservice\.transfer-file|"
    r"transfer-file"
)

VIEW_CHOOSER = re.compile(
    r"AlertDialog\.Builder|MaterialAlertDialogBuilder|android\.app\.AlertDialog"
)

ALLOW_LINE = re.compile(r"GDICCProviderShareDialog|ICCProviderOption")


def _strip_line_comment(line: str) -> str:
    return line.split("//", 1)[0]


def _is_comment_line(line: str) -> bool:
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")


def _file_has_composable(path: str) -> bool:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    return "@Composable" in text


def _scan_file(path: str, root: str) -> list[tuple[str, int, str]]:
    if not path.endswith(".kt"):
        return []
    if not _file_has_composable(path):
        return []

    try:
        lines = open(path, encoding="utf-8", errors="replace").readlines()
    except OSError:
        return []

    rel = os.path.relpath(path, root)
    hits: list[tuple[str, int, str]] = []
    file_icc = any(ICC_MARKERS.search(_strip_line_comment(l)) for l in lines if not _is_comment_line(l))

    for idx, raw in enumerate(lines):
        if _is_comment_line(raw):
            continue
        line = _strip_line_comment(raw)
        if re.match(r"^\s*import\s+", line):
            continue
        if ALLOW_LINE.search(line):
            continue
        lineno = idx + 1

        if VIEW_CHOOSER.search(line) and (file_icc or ICC_MARKERS.search(line)):
            hits.append((rel, lineno, "compose-icc-view-chooser"))
            continue

        if re.search(r"\bshowShareChooser\s*\(", line):
            hits.append((rel, lineno, "compose-calls-view-chooser"))

    return hits


def _scan_roots(roots: list[str]) -> list[str]:
    details: list[str] = []
    for root in roots:
        root = root.strip()
        if not root or not os.path.isdir(root):
            continue
        for dirpath, _, files in os.walk(root):
            for name in files:
                path = os.path.join(dirpath, name)
                for rel, lineno, kind in _scan_file(path, root):
                    details.append(f"{rel}:{lineno}:{kind}")
    return sorted(set(details))


def main() -> None:
    roots = [arg for arg in sys.argv[1:] if arg.strip()]
    if not roots:
        print("OK")
        return
    details = _scan_roots(roots)
    if details:
        print(f"UNMANAGED|{len(details)}|{';'.join(details)}")
        return
    print("OK")


if __name__ == "__main__":
    main()

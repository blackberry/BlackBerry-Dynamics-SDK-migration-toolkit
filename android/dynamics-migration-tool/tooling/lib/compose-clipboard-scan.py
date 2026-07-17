#!/usr/bin/env python3
"""Detect unmanaged Jetpack Compose clipboard usage (secureClipboard / prompt 09).

Usage: compose-clipboard-scan.py <source-root> [<source-root> ...]

Prints:
  OK
  UNMANAGED|<count>|<relpath>:<lineno>:<kind>;...

Exits 0 always (caller interprets stdout).
"""
from __future__ import annotations

import os
import re
import sys

# Compose clipboard surfaces that bypass Dynamics DLP when left in app code.
UNMANAGED_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("LocalClipboardManager.current", re.compile(r"\bLocalClipboardManager\.current\b")),
    ("LocalClipboard.current", re.compile(r"\bLocalClipboard\.current\b")),
    (
        "import-LocalClipboardManager",
        re.compile(r"^\s*import\s+androidx\.compose\.ui\.platform\.LocalClipboardManager\b"),
    ),
    (
        "import-LocalClipboard",
        re.compile(r"^\s*import\s+androidx\.compose\.ui\.platform\.LocalClipboard\b"),
    ),
    (
        "import-Compose-ClipboardManager",
        re.compile(
            r"^\s*import\s+androidx\.compose\.ui\.platform\.ClipboardManager\b"
        ),
    ),
    (
        "import-Compose-Clipboard",
        re.compile(r"^\s*import\s+androidx\.compose\.ui\.platform\.Clipboard\b"),
    ),
    (
        "import-ClipEntry",
        re.compile(r"^\s*import\s+androidx\.compose\.ui\.platform\.ClipEntry\b"),
    ),
    ("setClipEntry", re.compile(r"\.setClipEntry\s*\(")),
    ("getClipEntry", re.compile(r"\.getClipEntry\s*\(")),
    ("ClipEntry-constructor", re.compile(r"\bClipEntry\s*\(")),
    (
        "clipboardManager.setText",
        re.compile(r"\bclipboardManager\.setText\s*\("),
    ),
    (
        "clipboardManager.getText",
        re.compile(r"\bclipboardManager\.getText\s*\("),
    ),
    ("clipboard.setClipEntry", re.compile(r"\bclipboard\.setClipEntry\s*\(")),
    ("clipboard.getClipEntry", re.compile(r"\bclipboard\.getClipEntry\s*\(")),
]

# Allowed after migration — adapter + Dynamics clipboard only.
ALLOW_LINE = re.compile(
    r"GDClipboardAdapter|com\.good\.gd\.content\.ClipboardManager"
)


def _strip_line_comment(line: str) -> str:
    return line.split("//", 1)[0]


def _is_comment_line(line: str) -> bool:
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")


def _scan_file(path: str, root: str) -> list[tuple[int, str]]:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError:
        return []

    if not path.endswith(".kt"):
        return []

    rel = os.path.relpath(path, root)
    out: list[tuple[str, int, str]] = []

    for idx, raw in enumerate(lines):
        if _is_comment_line(raw):
            continue
        line = _strip_line_comment(raw)
        if ALLOW_LINE.search(line):
            continue
        lineno = idx + 1
        for kind, pattern in UNMANAGED_PATTERNS:
            if pattern.search(line):
                out.append((rel, lineno, kind))
                break

    return out


def _scan_roots(roots: list[str]) -> list[str]:
    details: list[str] = []
    for root in roots:
        root = root.strip()
        if not root or not os.path.isdir(root):
            continue
        for dirpath, _, files in os.walk(root):
            for name in files:
                if not name.endswith(".kt"):
                    continue
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

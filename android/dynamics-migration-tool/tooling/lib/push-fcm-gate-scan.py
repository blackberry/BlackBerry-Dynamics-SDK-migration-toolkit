#!/usr/bin/env python3
"""Detect ungated FCM push handlers (WI-02 / Phase 12).

Usage: push-fcm-gate-scan.py <source-root> [<source-root> ...]

Prints UNGATED|<relpath>;... when a FirebaseMessagingService subclass
defines onMessageReceived or onNewToken without an authorization guard in
that file. Otherwise prints OK. Exits 0 always (caller interprets stdout).
"""
from __future__ import annotations

import os
import re
import sys

FCM_EXTENDS = re.compile(
    r"extends\s+FirebaseMessagingService|:\s*FirebaseMessagingService\b"
)
AUTH_GUARD = re.compile(
    r"isContainerAuthorized|canAuthorizeAutonomously|serviceInit\s*\(|"
    r"dynamicsBackgroundAuthorizeStarted|runOnAuthorized\s*\("
)
HANDLER_METHOD = re.compile(
    r"\b(?:override\s+)?fun\s+(onMessageReceived|onNewToken)\b|"
    r"\bvoid\s+(onMessageReceived|onNewToken)\s*\("
)


def _strip_comments(text: str) -> str:
    # Remove block comments (naive) then line comments for scanning.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    lines = []
    for line in text.splitlines():
        code = line.split("//", 1)[0]
        lines.append(code)
    return "\n".join(lines)


def _scan_file(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
    except OSError:
        return None
    if not FCM_EXTENDS.search(raw):
        return None
    if not HANDLER_METHOD.search(raw):
        return None
    if AUTH_GUARD.search(_strip_comments(raw)):
        return None
    return path


def _scan_roots(roots: list[str]) -> list[str]:
    hits: list[str] = []
    for root in roots:
        root = root.strip()
        if not root or not os.path.isdir(root):
            continue
        for dirpath, _, files in os.walk(root):
            for name in files:
                if not name.endswith((".java", ".kt")):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root)
                if _scan_file(path):
                    hits.append(rel)
    return sorted(set(hits))


def main() -> None:
    roots = [arg for arg in sys.argv[1:] if arg.strip()]
    if not roots:
        print("OK")
        return
    hits = _scan_roots(roots)
    if hits:
        print("UNGATED|" + ";".join(hits))
        return
    print("OK")


if __name__ == "__main__":
    main()

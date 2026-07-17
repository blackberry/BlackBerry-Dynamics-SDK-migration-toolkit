#!/usr/bin/env python3
"""Detect mixed GDAndroid authorize() + activityInit() entry paths (WI-01).

Usage: auth-mixed-entry-scan.py <source-root> [<source-root> ...]

Prints MIXED|... when direct authorize() and activityInit() both appear in
scope; otherwise prints OK. Exits 0 always (caller interprets stdout).
"""
from __future__ import annotations

import os
import re
import sys

_DIRECT_AUTHORIZE = re.compile(
    r"getInstance\s*\(\s*\)\s*\.\s*authorize\s*\(|GDAndroid\s*\.\s*authorize\s*\("
)
_ACTIVITY_INIT = re.compile(r"\bactivityInit\s*\(")


def _strip_comments_and_strings(text: str) -> str:
    """Strip comment/string bodies while preserving line boundaries."""
    out: list[str] = []
    in_line_comment = False
    in_block_comment = False
    in_string = False
    quote_char = ""
    i = 0

    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue

        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                out.extend((" ", " "))
                i += 2
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
            continue

        if in_string:
            if ch == "\\":
                out.append(" ")
                if nxt:
                    out.append(" ")
                    i += 2
                else:
                    i += 1
                continue
            if ch == quote_char:
                in_string = False
                quote_char = ""
                out.append(" ")
                i += 1
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if ch == "/" and nxt == "/":
            in_line_comment = True
            out.extend((" ", " "))
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = True
            out.extend((" ", " "))
            i += 2
            continue
        if ch in ('"', "'"):
            in_string = True
            quote_char = ch
            out.append(" ")
            i += 1
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def _line_has_direct_authorize(line: str) -> bool:
    if "canAuthorizeAutonomously" in line:
        return False
    return _DIRECT_AUTHORIZE.search(line) is not None


def _scan_file(path: str) -> tuple[bool, bool]:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            sanitized = _strip_comments_and_strings(handle.read())
    except OSError:
        return False, False

    has_init = _ACTIVITY_INIT.search(sanitized) is not None
    has_authorize = any(_line_has_direct_authorize(line) for line in sanitized.splitlines())
    return has_init, has_authorize


def _scan_roots(roots: list[str]) -> tuple[list[str], list[str]]:
    authorize_hits: list[str] = []
    activity_init_hits: list[str] = []
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
                has_init, has_auth = _scan_file(path)
                if has_init:
                    activity_init_hits.append(rel)
                if has_auth:
                    authorize_hits.append(rel)
    return authorize_hits, activity_init_hits


def main() -> None:
    roots = [arg for arg in sys.argv[1:] if arg.strip()]
    if not roots:
        print("OK")
        return
    authorize_hits, init_hits = _scan_roots(roots)
    if authorize_hits and init_hits:
        auth = ";".join(sorted(set(authorize_hits)))
        init = ";".join(sorted(set(init_hits)))
        print(f"MIXED|authorize in: {auth} | activityInit in: {init}")
        return
    print("OK")


if __name__ == "__main__":
    main()

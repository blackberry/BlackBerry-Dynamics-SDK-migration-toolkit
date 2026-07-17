#!/usr/bin/env python3
"""Detect getApplicationConfig/Policy reads outside cache-and-refresh paths (WI-03).

Usage: app-config-policy-scan.py <source-root> [<source-root> ...]

Prints UNCACHED|<relpath>:<lineno>:<method>;... for calls outside allowed methods.
Otherwise prints OK. Exits 0 always (caller interprets stdout).
"""
from __future__ import annotations

import os
import re
import sys

API_CALL = re.compile(
    r"\.getApplicationConfig\s*\(|\.getApplicationPolicy\s*\("
)
KT_FUN = re.compile(
    r"^\s*(?:(?:public|protected|private|internal)\s+)?(?:override\s+)?fun\s+(\w+)\s*\("
)
JAVA_METHOD = re.compile(
    r"^\s*(?:public|protected|private)\s+[\w<>,\s\[\]]+\s+(\w+)\s*\("
)
UI_TYPE = re.compile(
    r"\bclass\s+\w+(?:\s+extends\s+.*(?:Activity|Fragment)|"
    r":\s*.*(?:Activity|Fragment|ViewModel)\b)"
)

ALLOWED_METHODS = frozenset(
    {
        "onUpdateConfig",
        "onUpdatePolicy",
        "onAuthorized",
        "refreshApplicationConfig",
        "refreshApplicationPolicy",
        "cacheApplicationConfig",
        "cacheApplicationPolicy",
        "updateApplicationConfigCache",
        "updateApplicationPolicyCache",
        "loadApplicationConfigCache",
        "loadApplicationPolicyCache",
    }
)


def _strip_line_comment(line: str) -> str:
    return line.split("//", 1)[0]


def _method_name_from_line(line: str) -> str | None:
    for pat in (KT_FUN, JAVA_METHOD):
        m = pat.match(line)
        if m:
            return m.group(1)
    return None


def _method_spans(lines: list[str]) -> list[tuple[int, int, str]]:
    spans: list[tuple[int, int, str]] = []
    stack: list[tuple[str, int, int]] = []
    brace_depth = 0
    pending_name: str | None = None

    for idx, raw in enumerate(lines):
        line = _strip_line_comment(raw)
        lineno = idx + 1

        name = _method_name_from_line(line)
        if name:
            pending_name = name

        opens = line.count("{")
        closes = line.count("}")

        if pending_name and opens > 0:
            stack.append((pending_name, lineno, brace_depth))
            pending_name = None

        brace_depth += opens
        brace_depth -= closes

        while stack and brace_depth <= stack[-1][2]:
            method_name, start, _ = stack.pop()
            spans.append((start, lineno, method_name))

        if brace_depth < 0:
            brace_depth = 0

    return spans


def _method_at(spans: list[tuple[int, int, str]], lineno: int) -> str | None:
    for start, end, name in spans:
        if start <= lineno <= end:
            return name
    return None


def _scan_file(path: str) -> list[tuple[int, str]]:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError:
        return []

    text = "".join(lines)
    if not API_CALL.search(text):
        return []

    is_ui_type = bool(UI_TYPE.search(text))
    spans = _method_spans(lines)
    violations: list[tuple[int, str]] = []

    for idx, raw in enumerate(lines):
        line = _strip_line_comment(raw)
        if not API_CALL.search(line):
            continue
        lineno = idx + 1
        method = _method_at(spans, lineno) or "<unknown>"

        if is_ui_type:
            violations.append((lineno, method))
            continue
        if method not in ALLOWED_METHODS:
            violations.append((lineno, method))

    return violations


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
                for lineno, method in _scan_file(path):
                    hits.append(f"{rel}:{lineno}:{method}")
    return sorted(set(hits))


def main() -> None:
    roots = [arg for arg in sys.argv[1:] if arg.strip()]
    if not roots:
        print("OK")
        return
    hits = _scan_roots(roots)
    if hits:
        print("UNCACHED|" + ";".join(hits))
        return
    print("OK")


if __name__ == "__main__":
    main()

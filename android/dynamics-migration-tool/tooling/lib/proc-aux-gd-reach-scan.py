#!/usr/bin/env python3
"""
PROC-AUX-001 helper scanner.

Usage:
  python3 proc-aux-gd-reach-scan.py <bootstrap.json> <source-root>

Output:
  SKIP|0                    bootstrap/processModel unavailable
  OK|0                      no risky auxiliary reachability found
  FAIL|<hit> <hit> ...      one or more risky call paths found
"""

from __future__ import annotations

import json
import os
import re
import sys
from typing import Dict, List, Set


if len(sys.argv) != 3:
    print("SKIP|0")
    sys.exit(0)

bootstrap_path, src_root = sys.argv[1], sys.argv[2]

if not os.path.isfile(bootstrap_path) or not os.path.isdir(src_root):
    print("SKIP|0")
    sys.exit(0)

try:
    with open(bootstrap_path, encoding="utf-8") as fh:
        bootstrap = json.load(fh)
except Exception:
    print("SKIP|0")
    sys.exit(0)

process_model = bootstrap.get("processModel")
if not isinstance(process_model, dict):
    print("SKIP|0")
    sys.exit(0)

aux_classes: Set[str] = set()
for component in process_model.get("components") or []:
    if not isinstance(component, dict):
        continue
    if component.get("classification") != "auxiliary":
        continue
    raw_name = component.get("name") or ""
    if not isinstance(raw_name, str) or not raw_name.strip():
        continue
    simple_name = raw_name.rsplit(".", 1)[-1]
    if simple_name:
        aux_classes.add(simple_name)

if not aux_classes:
    print("OK|0")
    sys.exit(0)

GD_USAGE_RE = re.compile(
    r"(^\s*import\s+com\.good\.gd\.file\.)"
    r"|(\bcom\.good\.gd\.file\.(?:File|FileInputStream|FileOutputStream)\s*\()"
    r"|(\bGDFileSystem\s*\.)"
    r"|(\bGDFileHelper\s*\.)",
    re.MULTILINE,
)
GUARD_RE = re.compile(r"\bisContainerAuthorized\b|\bisMainProcess\b|\bisMainProcessCheck\b")
CLASS_DECL_RE = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\b")
METHOD_CALL_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")
BRACED_METHOD_RE = re.compile(
    r"(?mx)"
    r"(?:^|\n)\s*"
    r"(?:(?:public|protected|private|internal|open|final|override|abstract|"
    r"suspend|inline|operator|tailrec|static|synchronized)\s+)*"
    r"(?:(?:fun|[A-Za-z_][A-Za-z0-9_<>\[\],?. ]+)\s+)"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*"
    r"\([^;\n{}]*\)\s*"
    r"(?:throws\s+[A-Za-z0-9_., ?]+\s*)?"
    r"(?::\s*[^=\n{]+)?\{"
)
KOTLIN_DEF_TMPL = r"\bfun\s+{name}\s*\("
JAVA_DEF_TMPL = (
    r"\b(?:public|private|protected|internal|static|final|synchronized|native|abstract|"
    r"override|open|inline|suspend)\b[^\n]*\b{name}\s*\("
)
PLAIN_DEF_TMPL = r"\b{name}\s*\("

SKIP_CALL_NAMES = {
    "if",
    "for",
    "while",
    "when",
    "switch",
    "return",
    "throw",
    "catch",
    "try",
    "super",
    "this",
}
# Seed common crash-handler entry helpers only. Nested storage helpers
# are discovered via 2-hop body analysis from these entry points — do not
# treat storage helpers as if every aux component called them directly
# (avoids false positives on unrelated GD helpers).
SEEDED_HELPERS = {
    "log",
    "writeLog",
    "appendLog",
    "report",
    "saveCrash",
    "viewLogs",
    "copyToClipBoard",
    "copyToClipboard",
}

file_cache: Dict[str, str] = {}
class_to_file: Dict[str, str] = {}
all_source_files: List[str] = []


def read_file(path: str) -> str:
    if path in file_cache:
        return file_cache[path]
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            file_cache[path] = fh.read()
    except OSError:
        file_cache[path] = ""
    return file_cache[path]


def is_comment(line: str) -> bool:
    stripped = line.lstrip()
    return (
        not stripped
        or stripped.startswith("//")
        or stripped.startswith("*")
        or stripped.startswith("/*")
    )


def extract_called_methods(text: str) -> Set[str]:
    names: Set[str] = set()
    for line in text.splitlines():
        if is_comment(line):
            continue
        for match in METHOD_CALL_RE.finditer(line):
            candidate = match.group(1)
            if candidate in SKIP_CALL_NAMES:
                continue
            if len(candidate) < 2:
                continue
            names.add(candidate)
    return names


def defines_method(text: str, method_name: str) -> bool:
    escaped = re.escape(method_name)
    kotlin_re = re.compile(KOTLIN_DEF_TMPL.format(name=escaped))
    java_re = re.compile(JAVA_DEF_TMPL.format(name=escaped))
    plain_re = re.compile(PLAIN_DEF_TMPL.format(name=escaped))
    return bool(kotlin_re.search(text) or java_re.search(text) or plain_re.search(text))


def find_matching_brace(text: str, brace_open: int) -> int:
    depth = 1
    i = brace_open + 1
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def extract_method_bodies(text: str, method_name: str) -> List[str]:
    bodies: List[str] = []
    for match in BRACED_METHOD_RE.finditer(text):
        if match.group(1) != method_name:
            continue
        brace_open = text.find("{", match.end() - 1)
        if brace_open == -1:
            continue
        brace_close = find_matching_brace(text, brace_open)
        if brace_close == -1:
            continue
        bodies.append(text[brace_open + 1: brace_close])
    # Top-level Kotlin: fun name(...) { ... }
    top_level = re.compile(
        rf"(?m)^\s*fun\s+{re.escape(method_name)}\s*\([^;\n{{}}]*\)\s*"
        rf"(?::\s*[^=\n{{}}]+)?\s*\{{"
    )
    for match in top_level.finditer(text):
        brace_open = text.find("{", match.end() - 1)
        if brace_open == -1:
            continue
        brace_close = find_matching_brace(text, brace_open)
        if brace_close == -1:
            continue
        body = text[brace_open + 1: brace_close]
        if body not in bodies:
            bodies.append(body)
    return bodies


for dirpath, _, files in os.walk(src_root):
    for filename in files:
        if not filename.endswith((".java", ".kt")):
            continue
        abs_path = os.path.join(dirpath, filename)
        all_source_files.append(abs_path)
        head = read_file(abs_path)[:4096]
        class_match = CLASS_DECL_RE.search(head)
        if class_match:
            class_to_file[class_match.group(1)] = abs_path

hits: List[str] = []
seen_hits: Set[str] = set()


def add_hit(hit: str) -> None:
    if hit not in seen_hits:
        seen_hits.add(hit)
        hits.append(hit)


def file_has_unguarded_gd(path: str, text: str) -> bool:
    return bool(GD_USAGE_RE.search(text) and not GUARD_RE.search(text))


for aux_class in sorted(aux_classes):
    aux_path = class_to_file.get(aux_class)
    if not aux_path:
        continue
    aux_text = read_file(aux_path)

    # Direct GD usage in the auxiliary component file itself.
    if file_has_unguarded_gd(aux_path, aux_text):
        rel = os.path.relpath(aux_path, src_root)
        add_hit(f"{aux_class}->{rel}:<direct>")

    if GUARD_RE.search(aux_text):
        # Guard in the auxiliary component often indicates a deliberate split.
        continue

    called_methods = extract_called_methods(aux_text)
    called_methods.update(SEEDED_HELPERS)

    for other_path in all_source_files:
        if other_path == aux_path:
            continue
        other_text = read_file(other_path)

        matched_method = None
        for method_name in called_methods:
            if defines_method(other_text, method_name):
                matched_method = method_name
                break
        if not matched_method:
            continue

        rel = os.path.relpath(other_path, src_root)

        # Direct helper with GD in the same file (1 hop).
        if file_has_unguarded_gd(other_path, other_text):
            add_hit(f"{aux_class}->{rel}:{matched_method}")
            continue

        # Second hop: aux -> diagnostic helper (no GD) -> nested helper (GD).
        # Covers crash-handler Activities that call shared log helpers which
        # then open container files.
        for body in extract_method_bodies(other_text, matched_method):
            nested_calls = extract_called_methods(body)
            for nested_name in nested_calls:
                for third_path in all_source_files:
                    if third_path in (aux_path, other_path):
                        continue
                    third_text = read_file(third_path)
                    if not defines_method(third_text, nested_name):
                        continue
                    if not file_has_unguarded_gd(third_path, third_text):
                        continue
                    third_rel = os.path.relpath(third_path, src_root)
                    add_hit(
                        f"{aux_class}->{rel}:{matched_method}"
                        f"->{third_rel}:{nested_name}"
                    )

if hits:
    print("FAIL|" + " ".join(sorted(hits)))
else:
    print("OK|0")

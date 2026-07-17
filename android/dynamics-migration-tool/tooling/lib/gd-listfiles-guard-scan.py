#!/usr/bin/env python3
"""Find unguarded com.good.gd.file.File listFiles/list calls."""

from __future__ import annotations

import argparse
import os
import re
import sys

SOURCE_EXTS = (".java", ".kt")
IMPORT_RE = re.compile(
    r"^\s*import\s+([A-Za-z0-9_.*]+)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*;?\s*$",
    re.MULTILINE,
)
LIST_CALL_RE = re.compile(r"(\b[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*(listFiles|list)\s*\(")
EXISTS_GUARD_RE = re.compile(r"\b(exists|isDirectory)\s*\(")
KOTLIN_TYPED_VAR_RE = re.compile(r"\b(?:val|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\b")
JAVA_TYPED_VAR_RE = re.compile(
    r"\b([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|;|,|\))"
)
KOTLIN_ASSIGN_RE = re.compile(r"\b(?:val|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)")
GENERIC_ASSIGN_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)")


def comment_only(line: str) -> bool:
    stripped = line.lstrip()
    return (not stripped) or stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*")


def iter_source_files(root: str):
    cwd = os.getcwd()
    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            if filename in ("SecureFileIO.kt", "SecureFileIO.java") or not filename.endswith(SOURCE_EXTS):
                continue
            path = os.path.normpath(os.path.join(dirpath, filename))
            try:
                rel = os.path.relpath(path, cwd)
            except ValueError:
                rel = path
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
            except OSError:
                continue
            yield rel, text


def parse_imports(text: str) -> dict[str, set[str]]:
    gd_file_names: set[str] = set()
    java_file_names: set[str] = set()
    document_file_names: set[str] = set()

    for match in IMPORT_RE.finditer(text):
        target = match.group(1)
        alias = match.group(2)
        if target == "com.good.gd.file.*":
            gd_file_names.add("File")
            continue
        if target == "java.io.*":
            java_file_names.add("File")
            continue
        if target == "androidx.documentfile.provider.*":
            document_file_names.add("DocumentFile")
            continue
        if target == "com.good.gd.file.File":
            gd_file_names.add(alias or "File")
            continue
        if target == "java.io.File":
            java_file_names.add(alias or "File")
            continue
        if target == "androidx.documentfile.provider.DocumentFile":
            document_file_names.add(alias or "DocumentFile")
            continue

    gd_file_names -= java_file_names
    return {
        "gd_file_names": gd_file_names,
        "document_file_names": document_file_names,
        "java_file_names": java_file_names,
    }


def collect_receiver_sets(lines: list[str], imports: dict[str, set[str]]) -> tuple[set[str], set[str]]:
    gd_receivers: set[str] = set()
    nongd_receivers: set[str] = set()

    gd_ctor_names = set(imports["gd_file_names"])
    if gd_ctor_names:
        gd_ctor_names.add("com.good.gd.file.File")
    nongd_type_names = set(imports["java_file_names"]) | set(imports["document_file_names"])
    nongd_type_names.add("DocumentFile")

    def add_typed_receiver(name: str, type_name: str) -> None:
        if type_name in imports["gd_file_names"] or type_name == "com.good.gd.file.File":
            gd_receivers.add(name)
        elif type_name in nongd_type_names:
            nongd_receivers.add(name)

    def add_assigned_receiver(name: str, expr: str) -> None:
        for gd_name in gd_ctor_names:
            if re.search(rf"(?<![\w.])(?:new\s+)?{re.escape(gd_name)}\s*\(", expr):
                gd_receivers.add(name)
                return
        if "com.good.gd.file.File(" in expr:
            gd_receivers.add(name)
            return
        if "DocumentFile." in expr or re.search(r"(?<![\w.])(?:new\s+)?DocumentFile\s*\(", expr):
            nongd_receivers.add(name)
            return
        for nongd_name in nongd_type_names:
            if re.search(rf"(?<![\w.])(?:new\s+)?{re.escape(nongd_name)}\s*\(", expr):
                nongd_receivers.add(name)
                return

    for line in lines:
        if comment_only(line) or line.lstrip().startswith("import "):
            continue
        for match in KOTLIN_TYPED_VAR_RE.finditer(line):
            add_typed_receiver(match.group(1), match.group(2))
        for match in JAVA_TYPED_VAR_RE.finditer(line):
            add_typed_receiver(match.group(2), match.group(1))
        match = KOTLIN_ASSIGN_RE.search(line)
        if match:
            add_assigned_receiver(match.group(1), match.group(2))
        match = GENERIC_ASSIGN_RE.search(line)
        if match:
            add_assigned_receiver(match.group(1), match.group(2))
    return gd_receivers, nongd_receivers


def line_has_direct_gd_list_call(line: str, imports: dict[str, set[str]]) -> bool:
    gd_ctor_names = set(imports["gd_file_names"])
    if gd_ctor_names:
        gd_ctor_names.add("com.good.gd.file.File")
    for gd_name in gd_ctor_names:
        if re.search(rf"(?<![\w.])(?:new\s+)?{re.escape(gd_name)}\s*\([^)]*\)\s*\.\s*(listFiles|list)\s*\(", line):
            return True
    return "com.good.gd.file.File(" in line and re.search(r"\.\s*(listFiles|list)\s*\(", line) is not None


def is_guarded(lines: list[str], lineno: int, receiver: str) -> bool:
    line = lines[lineno - 1]
    if receiver in line and EXISTS_GUARD_RE.search(line):
        return True
    start = max(0, lineno - 6)
    for prev_line in lines[start:lineno - 1]:
        if receiver in prev_line and EXISTS_GUARD_RE.search(prev_line):
            return True
    return False


def scan(source_root: str) -> tuple[int, list[str]]:
    count = 0
    hits: list[str] = []
    for rel, text in iter_source_files(source_root):
        imports = parse_imports(text)
        if not imports["gd_file_names"] and "com.good.gd.file.File(" not in text:
            continue
        lines = text.splitlines()
        gd_receivers, nongd_receivers = collect_receiver_sets(lines, imports)
        for lineno, line in enumerate(lines, start=1):
            if comment_only(line):
                continue
            if line_has_direct_gd_list_call(line, imports):
                count += 1
                hits.append(f"{rel}:{lineno}")
                continue
            match = LIST_CALL_RE.search(line)
            if not match:
                continue
            receiver = match.group(1)
            if receiver in nongd_receivers or receiver not in gd_receivers:
                continue
            if is_guarded(lines, lineno, receiver):
                continue
            count += 1
            hits.append(f"{rel}:{lineno}")
    return count, hits


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan for unguarded GD File.listFiles/list calls")
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    count, hits = scan(args.source_root)
    print(count)
    print(",".join(hits[:8]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

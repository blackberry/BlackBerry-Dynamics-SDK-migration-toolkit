#!/usr/bin/env python3
"""Import-aware scanner for GD file call-sites in Java/Kotlin sources."""

from __future__ import annotations

import argparse
import os
import re
import sys

SOURCE_EXTS = (".java", ".kt")
REAL_GD_FS_METHODS = ("openFileInput", "openFileOutput", "openRandomAccessFile")
HALLUCINATED_GD_FS_METHODS = (
    "mkdirs",
    "exists",
    "delete",
    "renameTo",
    "list",
    "listFiles",
    "listDir",
)
BAD_ARG_RE = re.compile(
    r'"/data/|getAbsolutePath\s*\(|getCacheDir\s*\(|getFilesDir\s*\(|'
    r'getExternalCacheDir\s*\(|\bexternalCacheDir\b|\bcacheDir\b|\bfilesDir\b'
)
IMPORT_RE = re.compile(
    r"^\s*import\s+([A-Za-z0-9_.*]+)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*;?\s*$",
    re.MULTILINE,
)
STREAM_CALL_RE = r"(?<![\w.])(?:new\s+)?{name}\s*\(([^)]*)\)"
GD_FS_CALL_RE = r"(?<![\w.]){name}\s*\.\s*(?:{methods})\s*\("


def comment_only(line: str) -> bool:
    stripped = line.lstrip()
    return (not stripped) or stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*")


def iter_source_files(root: str):
    cwd = os.getcwd()
    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            if not filename.endswith(SOURCE_EXTS):
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
    gd_input_names: set[str] = set()
    gd_output_names: set[str] = set()
    gd_fs_names: set[str] = set()
    java_input_names: set[str] = set()
    java_output_names: set[str] = set()

    for match in IMPORT_RE.finditer(text):
        target = match.group(1)
        alias = match.group(2)
        if target == "com.good.gd.file.*":
            gd_input_names.add("FileInputStream")
            gd_output_names.add("FileOutputStream")
            gd_fs_names.add("GDFileSystem")
            continue
        if target == "java.io.*":
            java_input_names.add("FileInputStream")
            java_output_names.add("FileOutputStream")
            continue
        if target == "com.good.gd.file.FileInputStream":
            gd_input_names.add(alias or "FileInputStream")
            continue
        if target == "com.good.gd.file.FileOutputStream":
            gd_output_names.add(alias or "FileOutputStream")
            continue
        if target == "com.good.gd.file.GDFileSystem":
            gd_fs_names.add(alias or "GDFileSystem")
            continue
        if target == "java.io.FileInputStream":
            java_input_names.add(alias or "FileInputStream")
            continue
        if target == "java.io.FileOutputStream":
            java_output_names.add(alias or "FileOutputStream")
            continue

    gd_input_names -= java_input_names
    gd_output_names -= java_output_names
    return {
        "gd_input_names": gd_input_names,
        "gd_output_names": gd_output_names,
        "gd_fs_names": gd_fs_names,
    }


def line_has_real_gd_call(line: str, imports: dict[str, set[str]]) -> bool:
    methods = "|".join(REAL_GD_FS_METHODS)
    if re.search(rf"com\.good\.gd\.file\.GDFileSystem\s*\.\s*(?:{methods})\s*\(", line):
        return True
    for name in imports["gd_fs_names"]:
        if re.search(GD_FS_CALL_RE.format(name=re.escape(name), methods=methods), line):
            return True
    if re.search(r"(?:new\s+)?com\.good\.gd\.file\.File(?:Input|Output)Stream\s*\(", line):
        return True
    for name in imports["gd_input_names"] | imports["gd_output_names"]:
        if re.search(STREAM_CALL_RE.format(name=re.escape(name)), line):
            return True
    return False


def line_has_hallucinated_gd_fs_call(line: str, imports: dict[str, set[str]]) -> bool:
    methods = "|".join(HALLUCINATED_GD_FS_METHODS)
    if re.search(rf"com\.good\.gd\.file\.GDFileSystem\s*\.\s*(?:{methods})\s*\(", line):
        return True
    for name in imports["gd_fs_names"]:
        if re.search(GD_FS_CALL_RE.format(name=re.escape(name), methods=methods), line):
            return True
    return False


def iter_gd_stream_args(line: str, imports: dict[str, set[str]]):
    patterns = [r"(?:new\s+)?com\.good\.gd\.file\.File(?:Input|Output)Stream\s*\(([^)]*)\)"]
    for name in imports["gd_input_names"] | imports["gd_output_names"]:
        patterns.append(STREAM_CALL_RE.format(name=re.escape(name)))
    for pattern in patterns:
        for match in re.finditer(pattern, line):
            yield match.group(1)


def line_has_bad_gd_stream_arg(line: str, imports: dict[str, set[str]]) -> bool:
    for arg in iter_gd_stream_args(line, imports):
        if BAD_ARG_RE.search(arg):
            return True
    return False


def scan_real_hits(source_root: str) -> list[str]:
    hits: list[str] = []
    for rel, text in iter_source_files(source_root):
        imports = parse_imports(text)
        for lineno, line in enumerate(text.splitlines(), start=1):
            if comment_only(line) or line.lstrip().startswith("import "):
                continue
            if line_has_real_gd_call(line, imports):
                hits.append(f"{rel}:{lineno}:{line}")
    return hits


def scan_hallucination_hits(source_root: str) -> list[str]:
    hits: list[str] = []
    for rel, text in iter_source_files(source_root):
        imports = parse_imports(text)
        for lineno, line in enumerate(text.splitlines(), start=1):
            if comment_only(line) or line.lstrip().startswith("import "):
                continue
            if line_has_hallucinated_gd_fs_call(line, imports):
                hits.append(f"{rel}:{lineno}:{line}")
    return hits


def scan_bad_arg_hits(source_root: str) -> list[str]:
    hits: list[str] = []
    for rel, text in iter_source_files(source_root):
        imports = parse_imports(text)
        for lineno, line in enumerate(text.splitlines(), start=1):
            if comment_only(line):
                continue
            if line_has_bad_gd_stream_arg(line, imports):
                hits.append(f"{rel}:{lineno}:{line}")
    return hits


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan Java/Kotlin sources for GD file call-sites")
    parser.add_argument("--source-root", required=True)
    parser.add_argument(
        "--mode",
        choices=("real", "files", "hallucination", "abs-paths"),
        required=True,
    )
    args = parser.parse_args()

    if args.mode == "real":
        hits = scan_real_hits(args.source_root)
    elif args.mode == "files":
        hits = sorted({hit.split(":", 1)[0] for hit in scan_real_hits(args.source_root)})
        print("\n".join(hits))
        return 0
    elif args.mode == "hallucination":
        hits = scan_hallucination_hits(args.source_root)
    else:
        hits = scan_bad_arg_hits(args.source_root)

    print("\n".join(hits))
    return 0


if __name__ == "__main__":
    sys.exit(main())

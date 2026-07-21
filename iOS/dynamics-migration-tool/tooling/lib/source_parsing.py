#!/usr/bin/env python3
"""
Shared source parsing helpers for iOS migration tooling.

The helpers are intentionally language-agnostic and operate on stripped text
where comments and string literals are replaced with spaces while preserving
text length and newlines. This keeps downstream index/line math stable.
"""

from __future__ import annotations

import re
from typing import Iterable, List, Match, Tuple


def strip_comments_and_strings(text: str, *, nested_block_comments: bool = True) -> str:
    """
    Return a same-length string with comments/strings replaced by spaces.

    Newlines are preserved to keep line numbers stable.
    """
    out: List[str] = []
    i = 0
    n = len(text)
    state = "code"
    block_depth = 0

    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        tri = text[i : i + 3]

        if state == "code":
            if ch == "/" and nxt == "/":
                out.extend("  ")
                i += 2
                state = "line_comment"
                continue
            if ch == "/" and nxt == "*":
                out.extend("  ")
                i += 2
                state = "block_comment"
                block_depth = 1
                continue
            if tri == '"""':
                out.extend("   ")
                i += 3
                state = "triple_double"
                continue
            if tri == "'''":
                out.extend("   ")
                i += 3
                state = "triple_single"
                continue
            if ch == '"':
                out.append(" ")
                i += 1
                state = "double_quote"
                continue
            if ch == "'":
                out.append(" ")
                i += 1
                state = "single_quote"
                continue
            out.append(ch)
            i += 1
            continue

        if state == "line_comment":
            if ch == "\n":
                out.append("\n")
                state = "code"
            else:
                out.append(" ")
            i += 1
            continue

        if state == "block_comment":
            if nested_block_comments and ch == "/" and nxt == "*":
                out.extend("  ")
                i += 2
                block_depth += 1
                continue
            if ch == "*" and nxt == "/":
                out.extend("  ")
                i += 2
                block_depth -= 1
                if block_depth <= 0:
                    state = "code"
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if state == "single_quote":
            if ch == "\\":
                out.append(" ")
                if i + 1 < n:
                    out.append("\n" if text[i + 1] == "\n" else " ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            if ch == "'":
                state = "code"
            i += 1
            continue

        if state == "double_quote":
            if ch == "\\":
                out.append(" ")
                if i + 1 < n:
                    out.append("\n" if text[i + 1] == "\n" else " ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            if ch == '"':
                state = "code"
            i += 1
            continue

        if state == "triple_double":
            if tri == '"""':
                out.extend("   ")
                i += 3
                state = "code"
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if state == "triple_single":
            if tri == "'''":
                out.extend("   ")
                i += 3
                state = "code"
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

    return "".join(out)


def find_matching_brace(text: str, brace_open: int) -> int:
    depth = 1
    i = brace_open + 1
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def extract_braced_blocks(text: str, regex: re.Pattern[str]) -> List[Tuple[Match[str], int, int, str]]:
    blocks: List[Tuple[Match[str], int, int, str]] = []
    for match in regex.finditer(text):
        brace_open = text.find("{", max(match.start(), match.end() - 1))
        if brace_open == -1:
            continue
        brace_close = find_matching_brace(text, brace_open)
        if brace_close == -1:
            continue
        blocks.append((match, brace_open, brace_close, text[brace_open + 1 : brace_close]))
    return blocks


def compute_line_starts(text: str) -> List[int]:
    starts = [0]
    for idx, ch in enumerate(text):
        if ch == "\n":
            starts.append(idx + 1)
    return starts


def line_for_pos(line_starts: List[int], pos: int) -> int:
    # Small dependency-free bisect for speed in tight loops.
    lo = 0
    hi = len(line_starts)
    while lo < hi:
        mid = (lo + hi) // 2
        if line_starts[mid] <= pos:
            lo = mid + 1
        else:
            hi = mid
    return max(1, lo)


def mask_guarded_regions(text: str, guard_regex: re.Pattern[str]) -> str:
    chars = list(text)
    pos = 0
    while True:
        match = guard_regex.search(text, pos)
        if not match:
            break
        brace_open = text.find("{", match.end())
        if brace_open == -1:
            pos = match.end()
            continue
        brace_close = find_matching_brace(text, brace_open)
        if brace_close == -1:
            break
        for i in range(match.start(), brace_close + 1):
            if chars[i] != "\n":
                chars[i] = " "
        pos = brace_close + 1
    return "".join(chars)


def collect_identifier_tokens(*values: str) -> List[str]:
    seen = set()
    tokens: List[str] = []
    for value in values:
        if not value:
            continue
        for token in re.findall(r"[A-Za-z_][A-Za-z0-9_:.]*", value):
            short = token.split(".")[-1].split(":")[0]
            if len(short) < 3:
                continue
            if short.lower() in {"self", "true", "false", "null", "nil", "void"}:
                continue
            if short not in seen:
                seen.add(short)
                tokens.append(short)
    return tokens

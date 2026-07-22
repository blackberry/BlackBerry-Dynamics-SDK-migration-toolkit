#!/usr/bin/env python3
"""
Deterministic authorization reachability analyzer for iOS migration tooling.

This analyzer links pre-authorization lifecycle roots to sensitive call sites
already inventoried in migration-analysis.json. It remains conservative:
unresolved dynamic edges are preserved as opaque findings instead of being
treated as safe.
"""

from __future__ import annotations

import argparse
import pathlib
import hashlib
import json
import re
import sys
import time
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

if __package__ in {None, ""}:
    sys.path.append(str(pathlib.Path(__file__).resolve().parent))

from source_parsing import (  # type: ignore  # local helper module
    collect_identifier_tokens,
    compute_line_starts,
    find_matching_brace,
    line_for_pos,
    mask_guarded_regions,
    strip_comments_and_strings,
)


SENSITIVE_DOMAINS = {
    "secureFileStorage",
    "secureSql",
    "secureCoreData",
    "secureNetworking",
    "webview",
    "icc",
    "dlpPasteboard",
    "policyManagement",
}

DYNAMIC_EDGE_MARKERS = (
    "performSelector",
    "NSClassFromString",
    "respondsToSelector",
    "objc_msgSend",
    "NotificationCenter.default",
    "delegate?.",
    "Task.detached",
    ".sink(",
    ".assign(",
)

PREAUTH_ROOT_PATTERNS = (
    ("app-didFinishLaunching", re.compile(r"\bdidFinishLaunchingWithOptions\b")),
    ("app-open-url", re.compile(r"\bopenURLContexts?\b|\bopenURL\b")),
    ("app-user-activity", re.compile(r"\bcontinue userActivity\b|\bcontinueUserActivity\b")),
    ("app-remote-notification", re.compile(r"\bdidReceiveRemoteNotification\b")),
    ("app-didBecomeActive", re.compile(r"\bdidBecomeActive\b")),
    ("scene-willConnect", re.compile(r"\bwillConnectTo\b")),
    ("scene-open-url", re.compile(r"\bopenURLContexts\b")),
    ("scene-user-activity", re.compile(r"\bcontinue userActivity\b")),
    ("scene-didBecomeActive", re.compile(r"\bsceneDidBecomeActive\b")),
    ("swiftui-app-init", re.compile(r"\bstruct\s+\w+\s*:\s*App\b|\bclass\s+\w+\s*:\s*App\b")),
    ("objc-load", re.compile(r"^\s*\+\s*\([^)]*\)\s*load\b")),
    ("objc-initialize", re.compile(r"^\s*\+\s*\([^)]*\)\s*initialize\b")),
    # Storyboard / early UIKit attach — Dynamics Launcher may probe these before authorize.
    ("uikit-viewDidLoad", re.compile(r"\bviewDidLoad\b")),
    ("uikit-viewWillAppear", re.compile(r"\bviewWillAppear\b")),
    ("uikit-viewDidAppear", re.compile(r"\bviewDidAppear\b")),
    ("uikit-awakeFromNib", re.compile(r"\bawakeFromNib\b")),
    ("uikit-loadView", re.compile(r"\bloadView\b")),
    ("uikit-init-coder", re.compile(r"\binit\s*\(\s*coder\b|\binitWithCoder\b")),
    ("uikit-prefersStatusBarHidden", re.compile(r"\bprefersStatusBarHidden\b")),
    ("uikit-preferredStatusBarStyle", re.compile(r"\bpreferredStatusBarStyle\b")),
)

SHARED_ACCESS_RE = re.compile(r"\b([A-Za-z_]\w*)\.shared\b")
TRY_BANG_SECURE_RE = re.compile(
    r"try!\s*(?:[^\n]{0,80}?)(?:GDFileManager|GDFileHandle|sqlite3enc_|GDPersistentStoreCoordinator|AccountManager|AppConfig)"
)
STATUS_BAR_PROP_RE = re.compile(
    r"(?ms)\b(?:override\s+)?(?:public\s+|internal\s+|open\s+|private\s+|fileprivate\s+)?(?:var|func)\s+"
    r"(prefersStatusBarHidden|preferredStatusBarStyle)\b[^{]*\{(.*?)\}"
)
FORCE_UNWRAP_COORD_RE = re.compile(
    r"\b(coordinator|sceneCoordinator|rootCoordinator|delegate|splitCoordinator)\s*!"
)
STORED_PROP_SHARED_RE = re.compile(
    r"(?m)^[ \t]*(?:(?:public|internal|private|fileprivate|open)\s+)*(?:(?:lazy|weak|unowned)\s+)*"
    r"(?:let|var)\s+[A-Za-z_]\w*\s*(?::[^=\n]+)?=\s*[^\n]*\.shared\b"
)
CALLABLE_OR_ACCESSOR_START_RE = re.compile(
    r"(?m)^[ \t]*(?:(?:public|internal|private|fileprivate|open|override|final|static|class)\s+)*"
    r"(?:func|init|deinit|subscript)\b"
    r"|^[ \t]*(?:(?:public|internal|private|fileprivate|open|override)\s+)*"
    r"(?:var|let)\s+[A-Za-z_]\w*\s*(?::[^{=\n]+)?\s*\{"
)
UIKIT_TYPE_RE = re.compile(
    r"(?m)^\s*(?:(?:public|internal|private|fileprivate|open)\s+)*(?:final\s+)?"
    r"(?:class|struct)\s+([A-Za-z_]\w*)\s*:[^{]*\b(UIViewController|UIView|UITableViewCell|UICollectionViewCell)\b"
)
SINGLETON_BOOT_LEAF_RE = re.compile(
    r"^(?:init|shared|start\w*|prepare\w*|createFolder\w*|setup\w*|load\w*|open\w*)$",
    re.I,
)

SENSITIVE_API_HINT_RE = re.compile(
    r"\b(?:GDFileManager|GDFileHandle|GDCReadStream|GDCWriteStream|sqlite3enc_|GDPersistentStoreCoordinator|"
    r"GDURLLoadingSystem|GDNativePasteboardAccess|AccountManager|AppConfig)\b"
)

POSTAUTH_PATTERNS = (
    re.compile(r"\bGDAppEventAuthorized\b"),
    re.compile(r"\bcase\s+\.authorized\b"),
    re.compile(r"\bstate\.isAuthorized\b"),
    re.compile(r"\bonAuthorized\b"),
)

SWIFT_TYPE_RE = re.compile(
    r"(?m)^\s*(?:public|internal|private|fileprivate|open)?\s*(?:final\s+)?(?:class|struct|actor|enum)\s+([A-Za-z_]\w*)"
)
SWIFT_FUNC_RE = re.compile(
    r"(?m)^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]*)*(?:[A-Za-z_]+\s+)*func\s+([A-Za-z_]\w*)\s*\("
)
SWIFT_INIT_RE = re.compile(
    r"(?m)^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]*)*(?:[A-Za-z_]+\s+)*init\s*\("
)
SWIFT_TOP_LEVEL_INIT_RE = re.compile(r"^\s*(?:let|var|static\s+let|static\s+var)\s+([A-Za-z_]\w*)\s*=\s*.+")

OBJC_IMPL_RE = re.compile(r"(?m)^[ \t]*@implementation[ \t]+([A-Za-z_]\w*)")
OBJC_END_RE = re.compile(r"(?m)^[ \t]*@end\b")
OBJC_METHOD_RE = re.compile(r"(?m)^[ \t]*([+-])[ \t]*\([^)\n]+\)")

AUTH_GUARD_BLOCK_RE = re.compile(
    r"(?mx)"
    r"(?:\bonAuthorized\b[^{;\n]*\{)"
    r"|(?:\bif\s*\([^)]*(?:isAuthorized|GDAppEventAuthorized|state\.isAuthorized|onAuthorized)[^)]*\)\s*\{)"
    r"|(?:\bif\s+[^\n{]*(?:isAuthorized|GDAppEventAuthorized|state\.isAuthorized|onAuthorized)[^\n{]*\{)"
    r"|(?:\bguard\s+[^\n{]*(?:isAuthorized|GDAppEventAuthorized|state\.isAuthorized)[^\n{]*\{)"
)


@dataclass
class Symbol:
    symbol_id: str
    relative_path: str
    language: str
    symbol: str
    line: int
    end_line: int
    start_pos: int
    end_pos: int
    root_type: Optional[str]
    body_lines: List[str]
    stripped_text: str
    call_tokens: Set[str]
    dynamic_markers: Set[str]
    direct_edges: Set[str]


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(2)


def read_json(path: pathlib.Path, label: str) -> Dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"{label} missing: {path}")
    except json.JSONDecodeError as exc:
        fail(f"{label} invalid JSON: {exc}")
    if not isinstance(data, dict):
        fail(f"{label} must be a JSON object")
    return data


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def file_fingerprint(path: pathlib.Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return ""


def source_fingerprint(files: Iterable[pathlib.Path], root: pathlib.Path) -> str:
    h = hashlib.sha256()
    for path in sorted(set(files)):
        if not path.is_file():
            continue
        rel = str(path.resolve().relative_to(root.resolve()))
        h.update(rel.encode("utf-8"))
        try:
            h.update(path.read_bytes())
        except OSError:
            continue
    return h.hexdigest()


def callsite_index(analysis: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    idx: Dict[str, Dict[str, Any]] = {}
    for domain in analysis.get("executionPlan", []):
        if not isinstance(domain, dict):
            continue
        domain_id = str(domain.get("domainId", ""))
        applicability = str(domain.get("applicability", "applicable"))
        for callsite in domain.get("callSites", []):
            if not isinstance(callsite, dict):
                continue
            callsite_id = str(callsite.get("id", "")).strip()
            if not callsite_id or callsite_id in idx:
                continue
            idx[callsite_id] = {
                "domainId": domain_id,
                "applicability": applicability,
                "callSite": callsite,
            }
    return idx


def detect_root_type(text: str) -> Optional[str]:
    for root_type, pattern in PREAUTH_ROOT_PATTERNS:
        if pattern.search(text):
            return root_type
    return None


def detect_postauth_symbol(symbol: Symbol) -> bool:
    for pat in POSTAUTH_PATTERNS:
        if pat.search(symbol.stripped_text):
            return True
    lower = symbol.symbol.lower()
    return "authorized" in lower and "notauthorized" not in lower


def target_source_files(project_root: pathlib.Path, target_map: Dict[str, Any]) -> List[pathlib.Path]:
    files: List[pathlib.Path] = []
    target_roots: Set[str] = set()
    for target in target_map.get("targets", []):
        if not isinstance(target, dict):
            continue
        for root in target.get("sourceRoots", []):
            if isinstance(root, str) and root:
                target_roots.add(root)

    if not target_roots:
        target_roots.add(".")

    for root in sorted(target_roots):
        root_path = (project_root / root).resolve()
        if not root_path.exists():
            continue
        for ext in ("*.swift", "*.m", "*.mm"):
            files.extend(root_path.rglob(ext))

    filtered: List[pathlib.Path] = []
    for path in files:
        rel_parts = set(path.parts)
        if rel_parts & {"Pods", ".build", "DerivedData", ".git", ".cursor", ".kiro", "dynamics-migration-tool"}:
            continue
        if path.is_file():
            filtered.append(path.resolve())
    return sorted(set(filtered))


def fingerprint_input_files(project_root: pathlib.Path) -> List[pathlib.Path]:
    files: List[pathlib.Path] = []
    for pattern in (
        "*.swift",
        "*.m",
        "*.mm",
        "*.h",
        "*.plist",
        "*.entitlements",
        "*.pbxproj",
        "Podfile",
        "Package.swift",
    ):
        files.extend(project_root.rglob(pattern))

    filtered: List[pathlib.Path] = []
    for path in files:
        rel_parts = set(path.parts)
        if rel_parts & {"Pods", ".build", "DerivedData", ".git", ".cursor", ".kiro", "dynamics-migration-tool"}:
            continue
        if path.is_file():
            filtered.append(path.resolve())
    return sorted(set(filtered))


def collect_call_tokens(language: str, body_text: str) -> Set[str]:
    tokens: Set[str] = set()
    if language == "swift":
        for call in re.findall(r"\b([A-Za-z_]\w*)\s*\(", body_text):
            tokens.add(call)
        for call in re.findall(r"\.\s*([A-Za-z_]\w*)\s*\(", body_text):
            tokens.add(call)
        for type_name in SHARED_ACCESS_RE.findall(body_text):
            tokens.add(type_name)
            tokens.add("shared")
    else:
        for call in re.findall(r"\[\s*[^\]]+\s+([A-Za-z_]\w*)", body_text):
            tokens.add(call)
        for call in re.findall(r"\b([A-Za-z_]\w*)\s*\(", body_text):
            tokens.add(call)
        for type_name in SHARED_ACCESS_RE.findall(body_text):
            tokens.add(type_name)
            tokens.add("shared")
    return tokens


def collect_dynamic_markers(body_text: str) -> Set[str]:
    markers = set()
    for marker in DYNAMIC_EDGE_MARKERS:
        if marker in body_text:
            markers.add(marker)
    return markers


def collect_swift_type_ranges(stripped_text: str) -> List[Tuple[int, int, str]]:
    ranges: List[Tuple[int, int, str]] = []
    for m in SWIFT_TYPE_RE.finditer(stripped_text):
        brace_open = stripped_text.find("{", m.end())
        if brace_open == -1:
            continue
        brace_close = find_matching_brace(stripped_text, brace_open)
        if brace_close == -1:
            continue
        ranges.append((m.start(), brace_close, m.group(1)))
    ranges.sort(key=lambda x: (x[0], -(x[1] - x[0])))
    return ranges


def enclosing_type_name(type_ranges: List[Tuple[int, int, str]], pos: int) -> str:
    name = ""
    span = None
    for start, end, type_name in type_ranges:
        if start <= pos <= end:
            current_span = end - start
            if span is None or current_span < span:
                span = current_span
                name = type_name
    return name


def find_decl_body_open(stripped_text: str, search_start: int, max_span: int = 2500) -> int:
    paren = 0
    angle = 0
    i = search_start
    limit = min(len(stripped_text), search_start + max_span)
    while i < limit:
        ch = stripped_text[i]
        if ch == "(":
            paren += 1
        elif ch == ")":
            if paren > 0:
                paren -= 1
        elif ch == "<":
            angle += 1
        elif ch == ">":
            if angle > 0:
                angle -= 1
        elif ch == "{" and paren == 0:
            return i
        elif ch in {"=", ";"} and paren == 0 and angle == 0:
            return -1
        i += 1
    return -1


def extract_swift_symbols(rel_path: str, raw_text: str, stripped_text: str) -> List[Symbol]:
    symbols: List[Symbol] = []
    raw_lines = raw_text.splitlines()
    line_starts = compute_line_starts(raw_text)
    type_ranges = collect_swift_type_ranges(stripped_text)
    seen_spans: Set[Tuple[int, int]] = set()

    decls: List[Tuple[int, str, str]] = []
    for m in SWIFT_FUNC_RE.finditer(stripped_text):
        decls.append((m.start(), m.group(1), "func"))
    for m in SWIFT_INIT_RE.finditer(stripped_text):
        decls.append((m.start(), "init", "init"))
    decls.sort(key=lambda item: item[0])

    for decl_start, symbol_name, kind in decls:
        body_open = find_decl_body_open(stripped_text, decl_start)
        if body_open == -1:
            continue
        body_close = find_matching_brace(stripped_text, body_open)
        if body_close == -1:
            continue
        if (decl_start, body_close) in seen_spans:
            continue
        seen_spans.add((decl_start, body_close))

        start_line = line_for_pos(line_starts, decl_start)
        end_line = line_for_pos(line_starts, body_close)
        snippet = stripped_text[decl_start : body_close + 1]
        type_name = enclosing_type_name(type_ranges, decl_start)
        full_name = f"{type_name}.{symbol_name}" if type_name else symbol_name
        if kind == "init" and type_name:
            full_name = f"{type_name}.init"

        body_lines = raw_lines[max(0, start_line - 1) : end_line]
        call_tokens = collect_call_tokens("swift", snippet)
        dynamic_markers = collect_dynamic_markers(snippet)
        # Signature may span lines (e.g. attributes); search the whole snippet head.
        root_type = detect_root_type(snippet[: min(len(snippet), 400)])

        symbols.append(
            Symbol(
                symbol_id=f"{rel_path}::{full_name}@{start_line}",
                relative_path=rel_path,
                language="swift",
                symbol=full_name,
                line=start_line,
                end_line=end_line,
                start_pos=decl_start,
                end_pos=body_close,
                root_type=root_type,
                body_lines=body_lines,
                stripped_text=snippet,
                call_tokens=call_tokens,
                dynamic_markers=dynamic_markers,
                direct_edges=set(),
            )
        )

    # Keep top-level initializers for conservative startup coverage.
    for idx, line in enumerate(raw_lines, start=1):
        match = SWIFT_TOP_LEVEL_INIT_RE.match(line)
        if not match:
            continue
        name = match.group(1)
        line_start = line_starts[idx - 1]
        line_end = line_start + len(line)
        symbols.append(
            Symbol(
                symbol_id=f"{rel_path}::top.{name}@{idx}",
                relative_path=rel_path,
                language="swift",
                symbol=f"top.{name}",
                line=idx,
                end_line=idx,
                start_pos=line_start,
                end_pos=line_end,
                root_type="swift-top-level-init",
                body_lines=[line],
                stripped_text=stripped_text[line_start:line_end],
                call_tokens=collect_call_tokens("swift", stripped_text[line_start:line_end]),
                dynamic_markers=collect_dynamic_markers(stripped_text[line_start:line_end]),
                direct_edges=set(),
            )
        )

    return symbols


def collect_objc_impl_ranges(stripped_text: str) -> List[Tuple[int, int, str]]:
    ranges: List[Tuple[int, int, str]] = []
    for impl in OBJC_IMPL_RE.finditer(stripped_text):
        end_match = OBJC_END_RE.search(stripped_text, impl.end())
        if not end_match:
            continue
        ranges.append((impl.start(), end_match.end(), impl.group(1)))
    return ranges


def method_header_terminator(stripped_text: str, start: int, end: int) -> int:
    depth = 0
    i = start
    while i < end:
        ch = stripped_text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            if depth > 0:
                depth -= 1
        elif depth == 0 and ch in {"{", ";"}:
            return i
        i += 1
    return -1


def parse_objc_selector_name(signature_text: str) -> str:
    selector_parts = re.findall(r"\b([A-Za-z_]\w*)\s*:", signature_text)
    if selector_parts:
        return ":".join(selector_parts) + ":"
    fallback = re.search(r"\)\s*([A-Za-z_]\w*)", signature_text)
    if fallback:
        return fallback.group(1)
    return "unknown"


def extract_objc_symbols(rel_path: str, raw_text: str, stripped_text: str) -> List[Symbol]:
    symbols: List[Symbol] = []
    impl_ranges = collect_objc_impl_ranges(stripped_text)
    raw_lines = raw_text.splitlines()
    line_starts = compute_line_starts(raw_text)

    for impl_start, impl_end, class_name in impl_ranges:
        for method in OBJC_METHOD_RE.finditer(stripped_text, impl_start, impl_end):
            terminator = method_header_terminator(stripped_text, method.end(), impl_end)
            if terminator == -1:
                continue
            if stripped_text[terminator] != "{":
                continue
            body_close = find_matching_brace(stripped_text, terminator)
            if body_close == -1:
                continue
            signature = stripped_text[method.start() : terminator]
            method_name = parse_objc_selector_name(signature)
            full_name = f"{class_name}.{method_name}"
            start_line = line_for_pos(line_starts, method.start())
            end_line = line_for_pos(line_starts, body_close)
            snippet = stripped_text[method.start() : body_close + 1]
            body_lines = raw_lines[max(0, start_line - 1) : end_line]

            symbols.append(
                Symbol(
                    symbol_id=f"{rel_path}::{full_name}@{start_line}",
                    relative_path=rel_path,
                    language="objc",
                    symbol=full_name,
                    line=start_line,
                    end_line=end_line,
                    start_pos=method.start(),
                    end_pos=body_close,
                    root_type=detect_root_type(signature),
                    body_lines=body_lines,
                    stripped_text=snippet,
                    call_tokens=collect_call_tokens("objc", snippet),
                    dynamic_markers=collect_dynamic_markers(snippet),
                    direct_edges=set(),
                )
            )
    return symbols


def build_symbol_graph(
    project_root: pathlib.Path, files: List[pathlib.Path]
) -> Tuple[Dict[str, Symbol], Dict[str, Dict[str, Any]]]:
    symbols: Dict[str, Symbol] = {}
    short_name_index: Dict[str, Set[str]] = {}
    file_data: Dict[str, Dict[str, Any]] = {}

    for file_path in files:
        try:
            raw_text = file_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rel = str(file_path.resolve().relative_to(project_root.resolve()))
        nested_block_comments = file_path.suffix in {".swift", ".m", ".mm"}
        stripped_text = strip_comments_and_strings(raw_text, nested_block_comments=nested_block_comments)
        raw_lines = raw_text.splitlines()
        line_starts = compute_line_starts(raw_text)
        file_data[rel] = {
            "raw_text": raw_text,
            "stripped_text": stripped_text,
            "raw_lines": raw_lines,
            "line_starts": line_starts,
        }

        if file_path.suffix == ".swift":
            extracted = extract_swift_symbols(rel, raw_text, stripped_text)
        else:
            extracted = extract_objc_symbols(rel, raw_text, stripped_text)

        for symbol in extracted:
            symbols[symbol.symbol_id] = symbol
            short_name = symbol.symbol.split(".")[-1].replace(":", "")
            short_name_index.setdefault(short_name, set()).add(symbol.symbol_id)

    for symbol in symbols.values():
        edges: Set[str] = set()
        for token in symbol.call_tokens:
            for dest in short_name_index.get(token, set()):
                if dest != symbol.symbol_id:
                    edges.add(dest)
        symbol.direct_edges = edges

    link_shared_singleton_edges(symbols)

    return symbols, file_data


def type_name_from_symbol(symbol: Symbol) -> str:
    if "." in symbol.symbol and not symbol.symbol.startswith("top."):
        return symbol.symbol.split(".", 1)[0]
    return ""


def link_shared_singleton_edges(symbols: Dict[str, Symbol]) -> None:
    """Type.shared access should reach that type's init/shared/start/prepare symbols."""
    by_type: Dict[str, Set[str]] = {}
    for sid, symbol in symbols.items():
        type_name = type_name_from_symbol(symbol)
        if type_name:
            by_type.setdefault(type_name, set()).add(sid)

    for symbol in symbols.values():
        for type_name in SHARED_ACCESS_RE.findall(symbol.stripped_text):
            for dest_id in by_type.get(type_name, set()):
                if dest_id == symbol.symbol_id:
                    continue
                leaf = symbols[dest_id].symbol.split(".")[-1].replace(":", "")
                if SINGLETON_BOOT_LEAF_RE.match(leaf) or SENSITIVE_API_HINT_RE.search(
                    symbols[dest_id].stripped_text
                ):
                    symbol.direct_edges.add(dest_id)


def _is_inside_callable_or_accessor(stripped: str, pos: int) -> bool:
    """True when pos sits inside a func/init/subscript or computed-property body.

    Method-local `let x = Type.shared` must not be treated as a storyboard
    stored-property hazard (false positive on deferred UIKit startups).
    """
    for match in CALLABLE_OR_ACCESSOR_START_RE.finditer(stripped):
        if match.start() >= pos:
            break
        brace_open = stripped.find("{", match.end() - 1)
        if brace_open == -1 or brace_open > pos:
            continue
        brace_close = find_matching_brace(stripped, brace_open)
        if brace_close != -1 and brace_open < pos < brace_close:
            return True
    return False


def collect_structural_hazards(
    file_data: Dict[str, Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """
    UIKit storyboard / early-attach hazards that often bypass call-site inventory edges:
    - UIViewController/UIView stored properties initialized via Type.shared
    - prefersStatusBarHidden / preferredStatusBarStyle force-unwrapping coordinators
    - try! on Dynamics/secure bootstrap APIs outside obvious auth handlers
    """
    hazards: List[Dict[str, Any]] = []

    for rel, blob in sorted(file_data.items()):
        stripped = str(blob.get("stripped_text", ""))
        line_starts = blob.get("line_starts") or [0]
        if not stripped:
            continue

        for match in STATUS_BAR_PROP_RE.finditer(stripped):
            body = match.group(2)
            if not FORCE_UNWRAP_COORD_RE.search(body):
                continue
            line_no = line_for_pos(line_starts, match.start())
            prop = match.group(1)
            hazards.append(
                {
                    "callSiteId": f"hazard:{rel}:{line_no}:{prop}-iuo",
                    "domainId": "authorization",
                    "relativePath": rel,
                    "line": line_no,
                    "symbol": prop,
                    "matchedApi": f"{prop}+forceUnwrap",
                    "classification": "definitely-pre-auth",
                    "confidence": "high",
                    "reason": (
                        f"{prop} force-unwraps a coordinator/delegate; Dynamics Launcher may "
                        "probe the storyboard RVC before post-auth coordinator install"
                    ),
                    "authorizationStateAtRoot": "pre-auth",
                    "reachableFromRootIds": [],
                    "evidence": {
                        "hazardKind": "status-bar-iuo",
                        "guardDetected": False,
                        "enclosingSymbolId": None,
                        "anchorToken": prop,
                    },
                }
            )

        for match in STORED_PROP_SHARED_RE.finditer(stripped):
            if _is_inside_callable_or_accessor(stripped, match.start()):
                continue
            line_no = line_for_pos(line_starts, match.start())
            in_uikit = False
            for tm in UIKIT_TYPE_RE.finditer(stripped):
                brace_open = stripped.find("{", tm.end())
                if brace_open == -1:
                    continue
                brace_close = find_matching_brace(stripped, brace_open)
                if brace_close != -1 and brace_open <= match.start() <= brace_close:
                    in_uikit = True
                    break
            # Flag UIKit stored .shared inits always; non-UIKit only when the
            # line also names a known secure/bootstrap type.
            if not in_uikit and not SENSITIVE_API_HINT_RE.search(match.group(0)):
                continue
            shared_types = SHARED_ACCESS_RE.findall(match.group(0))
            hazards.append(
                {
                    "callSiteId": f"hazard:{rel}:{line_no}:stored-property-shared",
                    "domainId": "authorization",
                    "relativePath": rel,
                    "line": line_no,
                    "symbol": "storedPropertyInit",
                    "matchedApi": (".".join(shared_types) + ".shared") if shared_types else "Type.shared",
                    "classification": "definitely-pre-auth",
                    "confidence": "high",
                    "reason": (
                        "Stored-property initializer references Type.shared; storyboard "
                        "instantiation can run this before GDAppEventAuthorized"
                    ),
                    "authorizationStateAtRoot": "pre-auth",
                    "reachableFromRootIds": [],
                    "evidence": {
                        "hazardKind": "storyboard-shared-init",
                        "guardDetected": False,
                        "enclosingSymbolId": None,
                        "anchorToken": match.group(0).strip()[:120],
                    },
                }
            )

        for match in TRY_BANG_SECURE_RE.finditer(stripped):
            line_no = line_for_pos(line_starts, match.start())
            window_start = max(0, match.start() - 200)
            window = stripped[window_start : match.end() + 80]
            if re.search(r"\bonAuthorized\b|\bGDAppEventAuthorized\b|\bisAuthorized\b", window):
                continue
            hazards.append(
                {
                    "callSiteId": f"hazard:{rel}:{line_no}:try-bang-secure",
                    "domainId": "authorization",
                    "relativePath": rel,
                    "line": line_no,
                    "symbol": "tryBangSecure",
                    "matchedApi": "try!",
                    "classification": "definitely-pre-auth",
                    "confidence": "medium",
                    "reason": (
                        "try! on Dynamics/secure bootstrap API outside an obvious authorization "
                        "guard — storyboard/shared init can crash pre-auth"
                    ),
                    "authorizationStateAtRoot": "pre-auth",
                    "reachableFromRootIds": [],
                    "evidence": {
                        "hazardKind": "try-bang-secure",
                        "guardDetected": False,
                        "enclosingSymbolId": None,
                        "anchorToken": match.group(0)[:120],
                    },
                }
            )

    return hazards


def resolve_callsite_anchor(
    callsite: Dict[str, Any],
    file_blob: Optional[Dict[str, Any]],
) -> Tuple[Optional[int], Optional[int], str]:
    line = callsite.get("line")
    expected_line = int(line) if isinstance(line, int) else None
    if not file_blob:
        return expected_line, None, ""

    stripped_text = str(file_blob.get("stripped_text", ""))
    line_starts = file_blob.get("line_starts") or [0]
    symbol = str(callsite.get("symbol", ""))
    matched_api = str(callsite.get("matchedApi", ""))
    snippet = str(callsite.get("snippet", ""))
    tokens = collect_identifier_tokens(matched_api, symbol, snippet)

    candidates: List[Tuple[int, int, str]] = []
    for token in tokens:
        pattern = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(token)}(?![A-Za-z0-9_])")
        for match in pattern.finditer(stripped_text):
            pos = match.start()
            line_no = line_for_pos(line_starts, pos)
            candidates.append((line_no, pos, token))

    if not candidates:
        if expected_line is None:
            return None, None, ""
        line_idx = max(0, min(expected_line - 1, len(line_starts) - 1))
        return expected_line, line_starts[line_idx], ""

    if expected_line is not None:
        candidates.sort(key=lambda item: abs(item[0] - expected_line))
    else:
        candidates.sort(key=lambda item: item[1])
    line_no, pos, token = candidates[0]
    return line_no, pos, token


def find_symbol_for_callsite(
    symbols: Dict[str, Symbol],
    rel_path: str,
    line: Optional[int],
    pos: Optional[int],
) -> Optional[Symbol]:
    candidates = [s for s in symbols.values() if s.relative_path == rel_path]
    if pos is not None:
        within = [s for s in candidates if s.start_pos <= pos <= s.end_pos]
        if within:
            within.sort(key=lambda s: (s.end_pos - s.start_pos, s.start_pos))
            return within[0]
    if line is not None:
        within_line = [s for s in candidates if s.line <= line <= s.end_line]
        if within_line:
            within_line.sort(key=lambda s: (s.end_line - s.line, s.line))
            return within_line[0]
    return None


def find_symbol_by_hint(symbols: Dict[str, Symbol], rel_path: str, symbol_hint: str) -> Optional[Symbol]:
    hint_tokens = collect_identifier_tokens(symbol_hint)
    if not hint_tokens:
        return None
    for token in hint_tokens:
        matches = [
            s for s in symbols.values()
            if s.relative_path == rel_path and s.symbol.split(".")[-1].replace(":", "") == token
        ]
        if len(matches) == 1:
            return matches[0]
        if matches:
            matches.sort(key=lambda s: (s.end_line - s.line, s.line))
            return matches[0]
    return None


def locate_token_in_symbol(symbol: Symbol, token: str) -> Optional[int]:
    if not token:
        return None
    pattern = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(token)}(?![A-Za-z0-9_])")
    match = pattern.search(symbol.stripped_text)
    if not match:
        return None
    return symbol.start_pos + match.start()


def has_structural_auth_guard(symbol: Symbol, pos: Optional[int]) -> bool:
    if detect_postauth_symbol(symbol):
        return True
    if pos is None:
        return False
    local_pos = pos - symbol.start_pos
    if local_pos < 0 or local_pos >= len(symbol.stripped_text):
        return False
    masked = mask_guarded_regions(symbol.stripped_text, AUTH_GUARD_BLOCK_RE)
    original = symbol.stripped_text[local_pos]
    masked_ch = masked[local_pos]
    return original not in {" ", "\n", "\t"} and masked_ch == " "


def reachable_from_roots(roots: Set[str], symbols: Dict[str, Symbol]) -> Dict[str, Set[str]]:
    reached_by: Dict[str, Set[str]] = {}
    for root_id in roots:
        stack = [root_id]
        seen: Set[str] = set()
        while stack:
            current = stack.pop()
            if current in seen:
                continue
            seen.add(current)
            reached_by.setdefault(current, set()).add(root_id)
            for nxt in symbols[current].direct_edges:
                if nxt not in seen:
                    stack.append(nxt)
    return reached_by


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze iOS pre-authorization reachability")
    parser.add_argument("--bootstrap", required=True, help="Path to output/bootstrap.json")
    parser.add_argument("--target-map", required=True, help="Path to output/target-map.json")
    parser.add_argument("--analysis", required=True, help="Path to output/migration-analysis.json")
    parser.add_argument("--output", required=True, help="Path to output/auth-reachability.json")
    parser.add_argument("--project-root", default="", help="Override project root path")
    args = parser.parse_args()

    bootstrap_path = pathlib.Path(args.bootstrap)
    target_map_path = pathlib.Path(args.target_map)
    analysis_path = pathlib.Path(args.analysis)
    output_path = pathlib.Path(args.output)

    bootstrap = read_json(bootstrap_path, "bootstrap.json")
    target_map = read_json(target_map_path, "target-map.json")
    analysis = read_json(analysis_path, "migration-analysis.json")

    run_id = str(bootstrap.get("runId", "")).strip()
    if not run_id:
        fail("bootstrap.json missing runId")

    for label, payload in (("target-map.json", target_map), ("migration-analysis.json", analysis)):
        payload_run = str(payload.get("runId", "")).strip()
        if payload_run and payload_run != run_id:
            fail(f"{label} runId mismatch (expected {run_id}, got {payload_run})")

    project_root = (
        pathlib.Path(args.project_root).resolve()
        if args.project_root
        else pathlib.Path(target_map.get("projectRoot", "")).resolve()
    )
    if not project_root.exists():
        fail(f"project root not found: {project_root}")

    source_files = target_source_files(project_root, target_map)
    fingerprint_files = fingerprint_input_files(project_root)
    symbols, file_data = build_symbol_graph(project_root, source_files)

    preauth_roots: Set[str] = set()
    postauth_boundaries: Set[str] = set()
    roots_payload: List[Dict[str, Any]] = []
    for symbol in symbols.values():
        if symbol.root_type:
            preauth_roots.add(symbol.symbol_id)
            roots_payload.append(
                {
                    "id": symbol.symbol_id,
                    "targetId": "unknown",
                    "language": symbol.language,
                    "rootType": symbol.root_type,
                    "sourceLocation": {"relativePath": symbol.relative_path, "line": symbol.line},
                    "authorizationState": "pre-auth",
                    "confidence": "high",
                    "reason": "lifecycle/startup pattern match",
                    "callEdges": sorted(symbol.direct_edges),
                    "sensitiveDescendantCallSiteIds": [],
                }
            )
        if detect_postauth_symbol(symbol):
            postauth_boundaries.add(symbol.symbol_id)

    reached_from_preauth = reachable_from_roots(preauth_roots, symbols) if preauth_roots else {}
    reached_from_postauth = reachable_from_roots(postauth_boundaries, symbols) if postauth_boundaries else {}

    callsites = callsite_index(analysis)
    findings: List[Dict[str, Any]] = []
    root_descendants: Dict[str, Set[str]] = {r["id"]: set() for r in roots_payload}

    for callsite_id, payload in sorted(callsites.items()):
        domain_id = payload["domainId"]
        if domain_id not in SENSITIVE_DOMAINS or payload["applicability"] == "not-applicable":
            continue
        callsite = payload["callSite"]
        rel_path = str(callsite.get("relativePath", ""))
        anchor_line, anchor_pos, anchor_token = resolve_callsite_anchor(callsite, file_data.get(rel_path))

        symbol = find_symbol_for_callsite(symbols, rel_path, anchor_line, anchor_pos)
        if symbol is None:
            symbol = find_symbol_by_hint(symbols, rel_path, str(callsite.get("symbol", "")))
        if symbol is not None:
            if anchor_pos is None or not (symbol.start_pos <= anchor_pos <= symbol.end_pos):
                anchor_pos = locate_token_in_symbol(symbol, str(callsite.get("matchedApi", ""))) or symbol.start_pos
                blob = file_data.get(rel_path)
                if blob is not None:
                    anchor_line = line_for_pos(blob.get("line_starts") or [0], anchor_pos)

        classification = "unresolved-opaque"
        confidence = "low"
        reason = "no enclosing symbol could be resolved"
        root_ids: List[str] = []
        guard_detected = False

        if symbol is not None:
            pre_roots = reached_from_preauth.get(symbol.symbol_id, set())
            post_roots = reached_from_postauth.get(symbol.symbol_id, set())
            root_ids = sorted(pre_roots)
            guard_detected = has_structural_auth_guard(symbol, anchor_pos)

            if pre_roots and not guard_detected:
                classification = "definitely-pre-auth"
                confidence = "high"
                reason = "sensitive call site reachable from pre-auth lifecycle root"
            elif pre_roots and guard_detected:
                classification = "conditionally-gated"
                confidence = "medium"
                reason = "reachable from pre-auth root but structural authorization guard detected"
            elif post_roots:
                classification = "definitely-post-auth"
                confidence = "medium"
                reason = "reachable from post-auth authorization boundary"
            else:
                classification = "unresolved-opaque"
                confidence = "low"
                reason = "call site reachability unresolved from known lifecycle roots"

            for marker in symbol.dynamic_markers:
                if classification in {"conditionally-gated", "unresolved-opaque"}:
                    reason = f"{reason}; dynamic edge marker: {marker}"
                elif classification == "definitely-pre-auth":
                    reason = f"{reason}; dynamic edge marker observed: {marker}"

            for root_id in pre_roots:
                root_descendants.setdefault(root_id, set()).add(callsite_id)

        prior = str(callsite.get("lifecycleReachability", "")).strip()
        if prior == "pre-auth" and classification != "definitely-pre-auth":
            classification = "conditionally-gated" if guard_detected else "definitely-pre-auth"
            reason = "prompt-00 lifecycleReachability marked pre-auth"
            confidence = "medium"
        elif prior == "post-auth" and classification == "unresolved-opaque":
            classification = "definitely-post-auth"
            reason = "prompt-00 lifecycleReachability marked post-auth"
            confidence = "low"

        findings.append(
            {
                "callSiteId": callsite_id,
                "domainId": domain_id,
                "relativePath": rel_path,
                "line": anchor_line,
                "symbol": callsite.get("symbol"),
                "matchedApi": callsite.get("matchedApi"),
                "classification": classification,
                "confidence": confidence,
                "reason": reason,
                "authorizationStateAtRoot": "pre-auth",
                "reachableFromRootIds": root_ids,
                "evidence": {
                    "lifecycleReachabilityFromAnalysis": callsite.get("lifecycleReachability"),
                    "guardDetected": guard_detected,
                    "enclosingSymbolId": symbol.symbol_id if symbol else None,
                    "anchorToken": anchor_token or None,
                },
            }
        )

    # Structural hazards (storyboard shared init, status-bar IUO, try! secure)
    # are first-class definite-pre-auth findings even without inventory edges.
    structural = collect_structural_hazards(file_data)
    existing_ids = {f["callSiteId"] for f in findings}
    for hazard in structural:
        if hazard["callSiteId"] in existing_ids:
            continue
        findings.append(hazard)
        existing_ids.add(hazard["callSiteId"])

    for root in roots_payload:
        root["sensitiveDescendantCallSiteIds"] = sorted(root_descendants.get(root["id"], set()))

    blocker_count = sum(
        1 for f in findings if f["classification"] in {"definitely-pre-auth", "unresolved-opaque"}
    )
    structural_count = sum(
        1
        for f in findings
        if isinstance((f.get("evidence") or {}).get("hazardKind"), str)
    )
    result = {
        "schemaVersion": "1.0.0",
        "platform": "ios",
        "runId": run_id,
        "generatedAt": iso_now(),
        "sourceFingerprint": source_fingerprint(fingerprint_files, project_root),
        "analysisFingerprint": file_fingerprint(analysis_path),
        "targetMapFingerprint": file_fingerprint(target_map_path),
        "authorizationBoundary": {
            "selectedIntegrationPattern": analysis.get("lifecycleModel", {}).get("primaryPattern", "unknown")
            if isinstance(analysis.get("lifecycleModel"), dict)
            else "unknown",
            "postAuthBoundarySymbolIds": sorted(postauth_boundaries),
            "allowedPreAuthBehavior": [
                "placeholder-ui-shell",
                "observer-registration",
                "callback-queueing-without-sensitive-payload-processing",
            ],
            "prohibitedPreAuthBehavior": [
                "secure-storage-access",
                "secure-sql-or-core-data-initialization",
                "secure-networking-or-webview-load",
                "icc-or-dlp-sensitive-payload-processing",
                "policy-or-configuration-sensitive-access",
                "storyboard-stored-property-shared-init",
                "status-bar-coordinator-force-unwrap-pre-auth",
            ],
        },
        "lifecycleRoots": roots_payload,
        "reachabilityFindings": findings,
        "summary": {
            "sensitiveCallSiteCount": len(findings),
            "definitelyPreAuthCount": sum(1 for f in findings if f["classification"] == "definitely-pre-auth"),
            "definitelyPostAuthCount": sum(1 for f in findings if f["classification"] == "definitely-post-auth"),
            "conditionallyGatedCount": sum(1 for f in findings if f["classification"] == "conditionally-gated"),
            "unresolvedOpaqueCount": sum(1 for f in findings if f["classification"] == "unresolved-opaque"),
            "structuralHazardCount": structural_count,
            "blockerCount": blocker_count,
        },
        "limits": [
            "This analyzer uses conservative static heuristics, not a compiler-grade call graph.",
            "Dynamic dispatch, reflection, protocol indirection, and opaque third-party binaries may remain unresolved.",
            "Unresolved sensitive startup paths should be blocked or require manual intervention evidence.",
            "Structural hazards cover storyboard Type.shared property inits, status-bar IUOs, and try! secure APIs.",
        ],
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(
        "OK: auth reachability analyzed — "
        f"{len(roots_payload)} roots, {len(findings)} sensitive findings, "
        f"{result['summary']['blockerCount']} blocker(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""
Phase 8 UI surface scanner.

Scans Android source/layout surfaces to validate widget migration in two lanes:
  - appcompat_inflater (GDAppCompatViewInflater installed)
  - explicit_gd_widgets (explicit GD widget tags/classes)

Widget classification is driven by ui-widget-catalog.json.

Output format:
  UI_LANE=PASS|...
  UI_EFFECTIVE_LANE=appcompat_inflater|explicit_gd_widgets
  UI_BIND_001=PASS|...
  UI_CHILD_001=PASS|...
  UI_CUSTOM_001=PASS|...
  UI_PROG_001=PASS|...
  UI_SEARCH_001=PASS|...
  UI_TIN_001=PASS|...
  UI_REMOTE_001=PASS|...
  UI_DRAG_001=PASS|...
"""

from __future__ import annotations

import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

SKIP_DIRS = {
    "build",
    ".git",
    ".gradle",
    "out",
    "intermediates",
    "node_modules",
    "dynamics-migration-tool",
}

ANDROID_NS = "{http://schemas.android.com/apk/res/android}"

COVERED_PARENT_SIMPLE = {
    "TextView",
    "AppCompatTextView",
    "MaterialTextView",
    "GDTextView",
    "GDAppCompatTextView",
    "EditText",
    "AppCompatEditText",
    "GDEditText",
    "GDAppCompatEditText",
    "CheckedTextView",
    "AppCompatCheckedTextView",
    "GDAppCompatCheckedTextView",
    "AutoCompleteTextView",
    "AppCompatAutoCompleteTextView",
    "GDAutoCompleteTextView",
    "GDAppCompatAutoCompleteTextView",
    "MultiAutoCompleteTextView",
    "AppCompatMultiAutoCompleteTextView",
    "GDMultiAutoCompleteTextView",
    "GDAppCompatMultiAutoCompleteTextView",
    "SearchView",
    "AppCompatSearchView",
    "GDSearchView",
    "GDAppCompatSearchView",
    "TextInputEditText",
    "GDTextInputEditText",
}

# Dual-hierarchy classes: inflater produces GDAppCompat*, these GD* types
# do not participate in that hierarchy. Mixing them with the inflater is
# a ClassCastException. GDAppCompat* / GDTextInputEditText are substituted
# by GDAppCompatViewInflater and are valid in the inflater lane.
FALLBACK_MIXED_LANE_TAGS = {
    "GDTextView",
    "GDEditText",
    "GDAutoCompleteTextView",
    "GDMultiAutoCompleteTextView",
    "GDSearchView",
}

CLASS_PARENT_RE = re.compile(
    r"(?m)^\s*(?:(?:public|protected|private|internal|open|abstract|static|final)\s+)*"
    r"class\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\([^)]*\))?\s*(?::|extends)\s*"
    r"([A-Za-z_][A-Za-z0-9_.]*)"
)
CHILDREN_ITER_RE = re.compile(r"\.children\b|\bgetChildAt\s*\(|\bchildCount\b")
UNSAFE_KT_AS_RE = re.compile(r"\bas\s+([A-Z][A-Za-z0-9_]*)\b")
UNSAFE_JAVA_CAST_RE = re.compile(
    r"\(\s*([A-Z][A-Za-z0-9_]*)\s*\)\s*(?:getChildAt\b|[A-Za-z_][A-Za-z0-9_]*\b)"
)
COMMENT_LINE_RE = re.compile(r"^\s*//|^\s*\*|^\s*/\*")

INFLATER_UNSAFE_BIND_TYPES = (
    "GDTextView",
    "GDEditText",
    "GDAutoCompleteTextView",
    "GDMultiAutoCompleteTextView",
    "GDSearchView",
)
_INFLATER_UNSAFE_BIND = "|".join(INFLATER_UNSAFE_BIND_TYPES)
FIND_GD_BIND_RE = re.compile(
    r"findViewById\s*<\s*(?:com\.good\.gd\.widget\.)?(?:" + _INFLATER_UNSAFE_BIND + r")\s*>|"
    r"findViewById\([^)]*\)\s*as\??\s+(?:com\.good\.gd\.widget\.)?(?:" + _INFLATER_UNSAFE_BIND + r")\b|"
    r":\s*(?:com\.good\.gd\.widget\.)?(?:" + _INFLATER_UNSAFE_BIND + r")\s*=|"
    r"\(\s*(?:com\.good\.gd\.widget\.)?(?:" + _INFLATER_UNSAFE_BIND + r")\s*\)\s*findViewById|"
    r"\b(?:" + _INFLATER_UNSAFE_BIND + r")\b\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*.*findViewById"
)
MATERIAL_BIND_RE = re.compile(
    r"import\s+com\.google\.android\.material\.textview\.MaterialTextView|"
    r"\bMaterialTextView\b"
)

START_DRAG_AND_DROP_RE = re.compile(r"\bstartDragAndDrop\s*\(")
VIEW_START_DRAG_RE = re.compile(r"\.startDrag\s*\(")
ITEMTOUCH_START_DRAG_RE = re.compile(
    r"\b(?:itemTouchHelper|touchHelper|helper|callback)\.startDrag\s*\(",
    re.IGNORECASE,
)
CLIPDATA_TOKEN_RE = re.compile(r"\bClipData\b|\bclipData\b|\bclip\b")

UNSUPPORTED_RECEIVE_CONTENT_RE = re.compile(r"\bsetOnReceiveContentListener\s*\(")
REMOTEVIEWS_CTOR_RE = re.compile(r"\bRemoteViews\s*\(")
LAYOUT_REF_RE = re.compile(r"R\.layout\.([A-Za-z_][A-Za-z0-9_]*)")
APPWIDGET_LAYOUT_ATTRS = {
    "initialLayout",
    "previewLayout",
    "initialKeyguardLayout",
    "errorLayout",
}

FALLBACK_CTOR_NAMES = {
    "TextView",
    "EditText",
    "CheckedTextView",
    "AutoCompleteTextView",
    "MultiAutoCompleteTextView",
    "SearchView",
    "AppCompatTextView",
    "AppCompatEditText",
    "AppCompatCheckedTextView",
    "AppCompatAutoCompleteTextView",
    "AppCompatMultiAutoCompleteTextView",
    "AppCompatSearchView",
    "MaterialTextView",
    "TextInputEditText",
}


@dataclass
class CheckResult:
    status: str
    detail: str = ""


def walk_files(roots: list[str], suffixes: tuple[str, ...]):
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, files in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in files:
                if fn.endswith(suffixes):
                    yield os.path.join(dirpath, fn)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    lines = []
    for line in text.splitlines():
        if COMMENT_LINE_RE.match(line):
            lines.append("")
            continue
        lines.append(re.sub(r"//.*", "", line))
    return "\n".join(lines)


def local_tag(tag: str) -> str:
    return tag.split("}", 1)[-1] if "}" in tag else tag


def simple_name(tag: str) -> str:
    tag = local_tag(tag)
    return tag.rsplit(".", 1)[-1] if "." in tag else tag


def parse_xml(path: str):
    try:
        return ET.parse(path)
    except ET.ParseError:
        return None
    except OSError:
        return None


def discover_roots(args: list[str]) -> tuple[list[str], list[str]]:
    roots = [r for r in args if r.strip()]
    if not roots:
        env = os.environ.get("MM_IN_SCOPE_SOURCE_ROOTS", "") or os.environ.get("SRC_DIR_MM", "")
        roots = [r for r in env.split() if r.strip()]

    src_roots = list(roots)
    res_roots: list[str] = []

    for r in os.environ.get("MM_IN_SCOPE_RES_DIRS", "").split():
        if r.strip():
            res_roots.append(r.strip())

    for root in roots:
        if os.path.basename(root) == "res" or os.path.isdir(os.path.join(root, "layout")):
            res_roots.append(root)
        cur = os.path.abspath(root)
        for _ in range(5):
            candidate = os.path.join(cur, "res")
            if os.path.isdir(candidate):
                res_roots.append(candidate)
                break
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            cur = parent

    src_roots = list(dict.fromkeys(src_roots))
    res_roots = list(dict.fromkeys(res_roots))
    return src_roots, res_roots


def load_catalog(script_dir: str) -> dict:
    catalog_path = os.path.join(script_dir, "ui-widget-catalog.json")
    with open(catalog_path, encoding="utf-8") as fh:
        return json.load(fh)


def catalog_mixed_lane_tags(catalog: dict) -> set[str]:
    """XML simple names that are dual-hierarchy vs the inflater substitution."""
    names: set[str] = set()
    for row in catalog.get("replaceRows") or []:
        explicit = row.get("explicitLaneReplacement") or ""
        inflater = row.get("inflaterLaneReplacement") or ""
        if not explicit:
            continue
        exp = simple_name(explicit)
        inf = simple_name(inflater) if inflater else ""
        if exp and exp != inf:
            names.add(exp)
    return names or set(FALLBACK_MIXED_LANE_TAGS)


def catalog_keep_native_simple(catalog: dict) -> set[str]:
    names: set[str] = set()
    for row in catalog.get("keepNativeRows") or []:
        for widget in row.get("widgets") or []:
            names.add(simple_name(widget))
    return names


def catalog_ctor_names(catalog: dict) -> set[str]:
    names: set[str] = set(FALLBACK_CTOR_NAMES)
    prog = catalog.get("programmaticConstructors") or {}
    for lane in prog.values():
        if isinstance(lane, dict):
            names.update(lane.keys())
    for row in catalog.get("replaceRows") or []:
        for kind in row.get("sourceKinds") or []:
            names.add(simple_name(kind))
    keep = catalog_keep_native_simple(catalog)
    return {
        n
        for n in names
        if n and n not in keep and not n.startswith("GD") and n[0].isupper()
    }


def collect_layout_files(res_roots: list[str]) -> list[str]:
    layouts = []
    for res in res_roots:
        for entry in Path(res).glob("layout*"):
            if entry.is_dir():
                for xml in entry.glob("*.xml"):
                    layouts.append(str(xml))
    return list(dict.fromkeys(layouts))


def collect_values_files(res_roots: list[str]) -> list[str]:
    values = []
    for res in res_roots:
        for entry in Path(res).glob("values*"):
            if entry.is_dir():
                for xml in entry.glob("*.xml"):
                    values.append(str(xml))
    return list(dict.fromkeys(values))


def collect_custom_widgets(src_roots: list[str]) -> dict[str, set[str]]:
    customs: dict[str, set[str]] = {}
    for path in walk_files(src_roots, (".kt", ".java")):
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for match in CLASS_PARENT_RE.finditer(text):
            cls, parent = match.group(1), match.group(2)
            parent_simple = simple_name(parent)
            if parent_simple not in COVERED_PARENT_SIMPLE:
                continue
            if cls in COVERED_PARENT_SIMPLE or cls.startswith("GD"):
                continue
            customs.setdefault(cls, set()).add(parent_simple)
    return customs


def build_layout_name_index(layout_files: list[str]) -> dict[str, list[str]]:
    index: dict[str, list[str]] = defaultdict(list)
    for path in layout_files:
        name = os.path.splitext(os.path.basename(path))[0]
        index[name].append(path)
    return index


def resolve_include_file(
    include_tag: ET.Element,
    current_file: str,
    by_name: dict[str, list[str]],
) -> str | None:
    ref = include_tag.attrib.get(f"{ANDROID_NS}layout") or include_tag.attrib.get("layout")
    if not ref or not ref.startswith("@layout/"):
        return None
    name = ref.split("/", 1)[1]
    matches = by_name.get(name) or []
    if not matches:
        return None

    current_dir = os.path.dirname(current_file)
    current_qual = os.path.basename(current_dir)
    for cand in matches:
        if os.path.basename(os.path.dirname(cand)) == current_qual:
            return cand
    return matches[0]


def top_types_for_include(
    include_tag: ET.Element,
    current_file: str,
    by_name: dict[str, list[str]],
    visiting: set[str],
) -> list[str]:
    include_path = resolve_include_file(include_tag, current_file, by_name)
    if not include_path or include_path in visiting:
        return []
    visiting.add(include_path)
    tree = parse_xml(include_path)
    if tree is None:
        visiting.discard(include_path)
        return []

    root = tree.getroot()
    out: list[str] = []
    if simple_name(root.tag) == "merge":
        for child in list(root):
            ctag = local_tag(child.tag)
            if ctag == "include":
                out.extend(top_types_for_include(child, include_path, by_name, visiting))
            else:
                out.append(simple_name(ctag))
    else:
        out.append(simple_name(root.tag))
    visiting.discard(include_path)
    return out


def effective_child_types(
    parent: ET.Element,
    layout_path: str,
    by_name: dict[str, list[str]],
) -> list[str]:
    names: list[str] = []
    for child in list(parent):
        ctag = local_tag(child.tag)
        if ctag == "include":
            names.extend(top_types_for_include(child, layout_path, by_name, set()))
        else:
            names.append(simple_name(ctag))
    return names


def has_gd_widget_name(name: str) -> bool:
    return name.startswith("GD")


def detect_inflater(values_files: list[str]) -> list[str]:
    hits = []
    for path in values_files:
        tree = parse_xml(path)
        if tree is None:
            continue
        for item in tree.iter():
            if local_tag(item.tag) != "item":
                continue
            if item.attrib.get("name") != "viewInflaterClass":
                continue
            value = (item.text or "").strip()
            if value == "com.good.gd.app.GDAppCompatViewInflater":
                hits.append(path)
    return hits


def attr_local_name(attr: str) -> str:
    return attr.split("}", 1)[-1] if "}" in attr else attr


def lane_and_tags(
    layout_files: list[str],
    inflater_hits: list[str],
    mixed_tag_names: set[str],
) -> tuple[str, int, int, dict[str, int], list[str]]:
    mixed_explicit = 0
    any_gd = 0
    tag_counts: dict[str, int] = defaultdict(int)
    unsupported_receive: list[str] = []

    for path in layout_files:
        tree = parse_xml(path)
        if tree is None:
            continue
        text = ""
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            pass
        if UNSUPPORTED_RECEIVE_CONTENT_RE.search(text):
            unsupported_receive.append(os.path.basename(path))

        for elem in tree.iter():
            tag = local_tag(elem.tag)
            simp = simple_name(tag)
            tag_counts[simp] += 1
            if tag.startswith("com.good.gd.widget.") or (
                "." not in tag and simp.startswith("GD")
            ):
                any_gd += 1
            if simp in mixed_tag_names:
                mixed_explicit += 1

    if inflater_hits and mixed_explicit > 0:
        return "mixed", mixed_explicit, any_gd, tag_counts, unsupported_receive
    if inflater_hits:
        return "appcompat_inflater", mixed_explicit, any_gd, tag_counts, unsupported_receive
    return "explicit_gd_widgets", mixed_explicit, any_gd, tag_counts, unsupported_receive


def detect_receive_content_source(src_roots: list[str]) -> list[str]:
    hits = []
    for path in walk_files(src_roots, (".kt", ".java")):
        try:
            text = strip_comments(open(path, encoding="utf-8", errors="replace").read())
        except OSError:
            continue
        if UNSUPPORTED_RECEIVE_CONTENT_RE.search(text):
            hits.append(os.path.basename(path))
    return hits


def detect_child_casts(
    src_roots: list[str],
    custom_names: set[str],
) -> dict[str, set[str]]:
    hits: dict[str, set[str]] = {}
    for path in walk_files(src_roots, (".kt", ".java")):
        try:
            raw = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        text = strip_comments(raw)
        if not CHILDREN_ITER_RE.search(text):
            continue
        unsafe = set()
        for m in UNSAFE_KT_AS_RE.finditer(text):
            name = m.group(1)
            if name in custom_names:
                unsafe.add(name)
        for m in UNSAFE_JAVA_CAST_RE.finditer(text):
            name = m.group(1)
            if name in custom_names:
                unsafe.add(name)
        if unsafe:
            hits[os.path.basename(path)] = unsafe
    return hits


def detect_mixed_siblings(
    layout_files: list[str],
    custom_names: set[str],
) -> dict[str, set[str]]:
    out: dict[str, set[str]] = defaultdict(set)
    by_name = build_layout_name_index(layout_files)

    for path in layout_files:
        tree = parse_xml(path)
        if tree is None:
            continue
        for elem in tree.iter():
            children = list(elem)
            if len(children) < 2:
                continue
            names = effective_child_types(elem, path, by_name)
            if len(names) < 2:
                continue
            has_gd = any(has_gd_widget_name(n) for n in names)
            if not has_gd:
                continue
            for n in names:
                if n in custom_names:
                    out[n].add(os.path.basename(path))
    return out


def detect_custom_layout_refs(layout_files: list[str], custom_names: set[str]) -> dict[str, int]:
    refs: dict[str, int] = defaultdict(int)
    if not custom_names:
        return refs
    for path in layout_files:
        tree = parse_xml(path)
        if tree is None:
            continue
        for elem in tree.iter():
            tag = simple_name(local_tag(elem.tag))
            if tag in custom_names:
                refs[tag] += 1
    return refs


def detect_custom_bind_refs(src_roots: list[str], custom_names: set[str]) -> dict[str, int]:
    """Count findViewById / unsafe-cast bindings, not class parents or constructors."""
    refs: dict[str, int] = defaultdict(int)
    if not custom_names:
        return refs
    names = "|".join(re.escape(n) for n in sorted(custom_names, key=len, reverse=True))
    bind_re = re.compile(
        r"\bas\??\s+(" + names + r")\b|"
        r"findViewById\s*<\s*(" + names + r")\s*>|"
        r"\(\s*(" + names + r")\s*\)\s*findViewById|"
        r":\s*(" + names + r")\s*=\s*.*findViewById|"
        r"\b(" + names + r")\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*.*findViewById"
    )
    for path in walk_files(src_roots, (".kt", ".java")):
        try:
            text = strip_comments(open(path, encoding="utf-8", errors="replace").read())
        except OSError:
            continue
        for match in bind_re.finditer(text):
            name = next((g for g in match.groups() if g), None)
            if name:
                refs[name] += 1
    return refs


def detect_programmatic_constructors(src_roots: list[str], ctor_names: set[str]) -> list[str]:
    if not ctor_names:
        ctor_names = set(FALLBACK_CTOR_NAMES)
    names = "|".join(re.escape(n) for n in sorted(ctor_names, key=len, reverse=True))
    ctor_re = re.compile(r"(?<![\w.])(" + names + r")\s*\(")
    findings = []
    for path in walk_files(src_roots, (".kt", ".java")):
        try:
            raw = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        text = strip_comments(raw)
        hit = False
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("import "):
                continue
            if ctor_re.search(line):
                hit = True
                break
        if not hit and "AndroidView(" in text and ctor_re.search(text):
            hit = True
        if hit:
            findings.append(os.path.basename(path))
    return sorted(set(findings))


def detect_bind_mismatches(
    src_roots: list[str],
    lane: str,
    has_explicit_gd_text: bool,
) -> list[str]:
    bad = []
    for path in walk_files(src_roots, (".kt", ".java")):
        try:
            raw = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        text = strip_comments(raw)
        if lane == "appcompat_inflater" and FIND_GD_BIND_RE.search(text):
            bad.append(
                f"{os.path.basename(path)} binds findViewById to GDTextView/GDEditText in inflater lane"
            )
        if has_explicit_gd_text and MATERIAL_BIND_RE.search(text):
            bad.append(f"{os.path.basename(path)} keeps MaterialTextView binding with GD text widgets")
    return bad


def detect_searchview_lane_issues(layout_files: list[str], lane: str) -> list[str]:
    if lane != "appcompat_inflater":
        return []
    bad = []
    for path in layout_files:
        tree = parse_xml(path)
        if tree is None:
            continue
        for elem in tree.iter():
            tag = local_tag(elem.tag)
            if tag in ("SearchView", "android.widget.SearchView"):
                bad.append(os.path.basename(path))
                break
    return sorted(set(bad))


def detect_textinput_issues(layout_files: list[str], src_roots: list[str], lane: str) -> list[str]:
    material_hits = []
    for path in layout_files:
        tree = parse_xml(path)
        if tree is None:
            continue
        for elem in tree.iter():
            if simple_name(local_tag(elem.tag)) == "TextInputEditText":
                material_hits.append(os.path.basename(path))
                break

    src_material = []
    native_ctor_re = re.compile(r"(?<![\w.])(?:com\.google\.android\.material\.textfield\.)?TextInputEditText\s*\(")
    for path in walk_files(src_roots, (".kt", ".java")):
        try:
            text = strip_comments(open(path, encoding="utf-8", errors="replace").read())
        except OSError:
            continue
        if native_ctor_re.search(text):
            src_material.append(os.path.basename(path))

    if lane == "explicit_gd_widgets" and (material_hits or src_material):
        return sorted(set(material_hits + src_material))[:6]
    return []


def layout_has_gd_widget(path: str) -> bool:
    tree = parse_xml(path)
    if tree is None:
        try:
            return "com.good.gd.widget.GD" in open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            return False
    for elem in tree.iter():
        tag = local_tag(elem.tag)
        simp = simple_name(tag)
        if tag.startswith("com.good.gd.widget.") or (simp.startswith("GD") and "good.gd" in tag):
            return True
    return False


def detect_remoteviews_issues(res_roots: list[str], layout_files: list[str], src_roots: list[str]) -> list[str]:
    by_name = build_layout_name_index(layout_files)
    bad = []

    def consider_layout_name(name: str) -> None:
        for lp in by_name.get(name, []):
            if layout_has_gd_widget(lp):
                bad.append(os.path.basename(lp))

    for res in res_roots:
        xml_dir = os.path.join(res, "xml")
        if not os.path.isdir(xml_dir):
            continue
        for path in walk_files([xml_dir], (".xml",)):
            tree = parse_xml(path)
            if tree is None:
                continue
            root = tree.getroot()
            if local_tag(root.tag) != "appwidget-provider":
                continue
            for attr, value in root.attrib.items():
                if attr_local_name(attr) not in APPWIDGET_LAYOUT_ATTRS:
                    continue
                if not value or not value.startswith("@layout/"):
                    continue
                consider_layout_name(value.split("/", 1)[1])

    for path in walk_files(src_roots, (".kt", ".java")):
        try:
            text = strip_comments(open(path, encoding="utf-8", errors="replace").read())
        except OSError:
            continue
        for match in REMOTEVIEWS_CTOR_RE.finditer(text):
            window = text[match.start() : match.start() + 240]
            for layout_name in LAYOUT_REF_RE.findall(window):
                consider_layout_name(layout_name)

    return sorted(set(bad))


def _call_args_window(text: str, match: re.Match) -> str:
    start = match.end() - 1
    depth = 0
    for i in range(start, min(len(text), start + 400)):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth <= 0:
                return text[start : i + 1]
    return text[start : start + 400]


def detect_drag_issues(src_roots: list[str]) -> list[str]:
    """Fail View.startDragAndDrop / View.startDrag that carry app ClipData
    without Dynamics ClipboardManager. ItemTouchHelper.startDrag is reorder-only.
    """
    bad = []
    for path in walk_files(src_roots, (".kt", ".java")):
        try:
            text = strip_comments(open(path, encoding="utf-8", errors="replace").read())
        except OSError:
            continue
        file_hit = False
        for match in START_DRAG_AND_DROP_RE.finditer(text):
            prefix = text[max(0, match.start() - 200) : match.start()]
            if "ClipboardManager" in prefix:
                continue
            args = _call_args_window(text, match)
            # Reorder-only shadow drag: first argument is null, no ClipData.
            if re.search(r"\(\s*null\s*,", args) and not CLIPDATA_TOKEN_RE.search(args):
                continue
            file_hit = True
            break
        if file_hit:
            bad.append(os.path.basename(path))
            continue
        for match in VIEW_START_DRAG_RE.finditer(text):
            prefix = text[max(0, match.start() - 48) : match.start()]
            if ITEMTOUCH_START_DRAG_RE.search(prefix + ".startDrag("):
                continue
            args = _call_args_window(text, match)
            if CLIPDATA_TOKEN_RE.search(args):
                file_hit = True
                break
        if file_hit:
            bad.append(os.path.basename(path))
    return sorted(set(bad))


def summarize(status: str, detail: str = "") -> str:
    if detail:
        return f"{status}|{detail}"
    return status


def main() -> int:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    try:
        catalog = load_catalog(script_dir)
    except Exception as exc:
        print(f"UI_LANE=ERROR|catalog load failed: {exc}")
        return 0

    mixed_tag_names = catalog_mixed_lane_tags(catalog)
    ctor_names = catalog_ctor_names(catalog)

    src_roots, res_roots = discover_roots(sys.argv[1:])
    layout_files = collect_layout_files(res_roots)
    values_files = collect_values_files(res_roots)
    if not src_roots and not layout_files:
        for key in (
            "UI_LANE",
            "UI_EFFECTIVE_LANE",
            "UI_BIND_001",
            "UI_CHILD_001",
            "UI_CUSTOM_001",
            "UI_PROG_001",
            "UI_SEARCH_001",
            "UI_TIN_001",
            "UI_REMOTE_001",
            "UI_DRAG_001",
        ):
            print(f"{key}=NA")
        return 0

    inflater_hits = detect_inflater(values_files)
    lane, mixed_explicit_count, any_gd_count, tag_counts, unsupported_receive = lane_and_tags(
        layout_files, inflater_hits, mixed_tag_names
    )
    unsupported_receive.extend(detect_receive_content_source(src_roots))

    results: dict[str, CheckResult] = {}
    if lane == "mixed":
        results["UI_LANE"] = CheckResult(
            "FAIL",
            "GDAppCompatViewInflater is configured, but explicit dual-hierarchy "
            f"GD widget XML tags still exist ({mixed_explicit_count}: "
            + ", ".join(sorted(mixed_tag_names))
            + "). Choose one lane.",
        )
        effective_lane = "appcompat_inflater"
    else:
        results["UI_LANE"] = CheckResult("PASS", lane)
        effective_lane = lane

    custom_widgets = collect_custom_widgets(src_roots)
    custom_names = set(custom_widgets.keys())
    mixed = detect_mixed_siblings(layout_files, custom_names)
    unsafe_casts = detect_child_casts(src_roots, custom_names)
    custom_layout_refs = detect_custom_layout_refs(layout_files, custom_names)
    custom_bind_refs = detect_custom_bind_refs(src_roots, custom_names)

    child_findings = []
    for src_file, names in sorted(unsafe_casts.items()):
        for name in sorted(names):
            layouts = sorted(mixed.get(name, set()))
            if not layouts:
                continue
            child_findings.append(
                f"{src_file} casts children as {name} while {','.join(layouts[:4])} mixes {name} with GD siblings"
            )

    if child_findings:
        detail = " ; ".join(child_findings[:8])
        results["UI_CHILD_001"] = CheckResult("FAIL", detail)
    else:
        results["UI_CHILD_001"] = CheckResult("PASS", "no unsafe mixed-sibling child casts")

    rewritten_custom = []
    if any_gd_count > 0:
        for name in sorted(custom_names):
            if custom_layout_refs.get(name, 0) > 0:
                continue
            if custom_bind_refs.get(name, 0) <= 0:
                continue
            rewritten_custom.append(name)

    if child_findings and rewritten_custom:
        results["UI_CUSTOM_001"] = CheckResult(
            "FAIL",
            "Unsafe mixed custom/GD sibling casts and custom widget tags appear absent from layouts: "
            + ", ".join(rewritten_custom[:6]),
        )
    elif child_findings:
        results["UI_CUSTOM_001"] = CheckResult(
            "FAIL",
            "Custom view casting is unsafe in mixed custom/GD groups. Keep custom XML tags and migrate class parents.",
        )
    elif rewritten_custom:
        results["UI_CUSTOM_001"] = CheckResult(
            "FAIL",
            "Custom widget classes are bound in source but absent from layouts while GD widgets are present: "
            + ", ".join(rewritten_custom[:6]),
        )
    else:
        results["UI_CUSTOM_001"] = CheckResult("PASS", "no custom-tag migration mismatch detected")

    prog_findings = detect_programmatic_constructors(src_roots, ctor_names)
    if prog_findings:
        results["UI_PROG_001"] = CheckResult(
            "FAIL",
            f"Standard/widget constructors remain ({len(prog_findings)}): {', '.join(prog_findings[:6])}",
        )
    else:
        results["UI_PROG_001"] = CheckResult("PASS", "no uncovered programmatic constructors")

    has_explicit_gd_text = mixed_explicit_count > 0 or tag_counts.get("GDTextView", 0) > 0
    bind_findings = detect_bind_mismatches(src_roots, effective_lane, has_explicit_gd_text)
    if bind_findings:
        results["UI_BIND_001"] = CheckResult("FAIL", " ; ".join(bind_findings[:8]))
    else:
        results["UI_BIND_001"] = CheckResult("PASS", "no binding/type mismatch detected")

    search_findings = detect_searchview_lane_issues(layout_files, effective_lane)
    if search_findings:
        results["UI_SEARCH_001"] = CheckResult(
            "FAIL",
            f"AppCompat inflater lane has naked SearchView tags: {', '.join(search_findings[:6])}",
        )
    else:
        results["UI_SEARCH_001"] = CheckResult("PASS", "searchview lane usage is consistent")

    tin_findings = detect_textinput_issues(layout_files, src_roots, effective_lane)
    if tin_findings:
        results["UI_TIN_001"] = CheckResult(
            "FAIL",
            f"TextInputEditText remains native in explicit lane: {', '.join(tin_findings)}",
        )
    else:
        results["UI_TIN_001"] = CheckResult("PASS", "textinputedittext handling is consistent")

    remote_findings = detect_remoteviews_issues(res_roots, layout_files, src_roots)
    if remote_findings:
        results["UI_REMOTE_001"] = CheckResult(
            "FAIL",
            f"RemoteViews layout(s) use GD widgets: {', '.join(remote_findings[:6])}",
        )
    else:
        results["UI_REMOTE_001"] = CheckResult("PASS", "no GD widgets in appwidget RemoteViews layouts")

    drag_findings = detect_drag_issues(src_roots)
    if drag_findings:
        results["UI_DRAG_001"] = CheckResult(
            "FAIL",
            f"Potential unmanaged drag/drop start call(s): {', '.join(drag_findings[:6])}",
        )
    else:
        results["UI_DRAG_001"] = CheckResult("PASS", "no unmanaged drag/drop starts detected")

    if unsupported_receive:
        prior = results["UI_BIND_001"]
        detail = (
            "Unsupported setOnReceiveContentListener usage in: "
            + ", ".join(sorted(set(unsupported_receive))[:6])
        )
        if prior.status == "FAIL":
            results["UI_BIND_001"] = CheckResult("FAIL", prior.detail + " ; " + detail)
        else:
            results["UI_BIND_001"] = CheckResult("FAIL", detail)

    print(f"UI_EFFECTIVE_LANE={effective_lane}")
    for key in (
        "UI_LANE",
        "UI_BIND_001",
        "UI_CHILD_001",
        "UI_CUSTOM_001",
        "UI_PROG_001",
        "UI_SEARCH_001",
        "UI_TIN_001",
        "UI_REMOTE_001",
        "UI_DRAG_001",
    ):
        res = results.get(key, CheckResult("NA", ""))
        print(f"{key}={summarize(res.status, res.detail)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

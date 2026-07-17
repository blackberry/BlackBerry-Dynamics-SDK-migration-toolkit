#!/usr/bin/env python3
"""Independent rediscovery scanner for HR-0-5 evidence-based success gating.

Walks in-scope module-map source roots and Gradle metadata without reading
migration-analysis.json. Output is consumed by evidence-closure-check.py,
record-prompt-execution.sh, and phase-report.sh.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from typing import Iterable

SCHEMA_VERSION = "1.1.0"

SOURCE_EXTS = (".java", ".kt", ".kts")
TEST_PATH_MARKERS = ("/src/test/", "/src/androidTest/", "/src/testFixtures/")

# (compiled regex, human label)
DOMAIN_RULES: dict[str, list[tuple[re.Pattern[str], str]]] = {
    "secureNetworking": [
        (re.compile(r"HttpURLConnection|\.openConnection\s*\("), "HttpURLConnection/openConnection"),
        (re.compile(r"java\.net\.Socket|new\s+Socket\s*\("), "java.net.Socket"),
        (re.compile(r"okhttp3\."), "okhttp3"),
        (re.compile(r"retrofit2\."), "retrofit2"),
        (re.compile(r"io\.ktor\.|CIOEngineConfig"), "Ktor"),
        (re.compile(r"org\.chromium\.net\.|CronetEngine|CronetProvider"), "Cronet"),
        (re.compile(r"io\.grpc\.|ManagedChannelBuilder|Grpc\.newChannelBuilder"), "gRPC"),
        (re.compile(r"DownloadManager\.|android\.app\.DownloadManager"), "DownloadManager"),
        (re.compile(r"org\.java_websocket|WebSocketClient\s*\(|newWebSocket\s*\("), "WebSocket library"),
        (re.compile(r"DatagramSocket|SSLSocket"), "DatagramSocket/SSLSocket"),
    ],
    "secureFileStorage": [
        (re.compile(r"context\.openFile|Context\.openFile|getContext\(\)\.openFile"), "Context.openFile*"),
        (re.compile(r"new\s+java\.io\.File\s*\(|new\s+File\s*\([^)]*get(FileDir|CacheDir|External)"), "java.io.File container escape"),
        (re.compile(r"new\s+java\.io\.File(Input|Output)Stream|new\s+File(Input|Output)Stream"), "java.io.File stream"),
        (re.compile(r"Environment\.getExternalStorage|getExternalStorageDirectory"), "external storage path"),
        (re.compile(r"MediaStore\.|ACTION_CREATE_DOCUMENT|ACTION_OPEN_DOCUMENT"), "MediaStore/SAF"),
        (re.compile(r"FileProvider\.getUriForFile"), "FileProvider URI"),
    ],
    "secureSql": [
        (re.compile(r"android\.database\.sqlite|SQLiteDatabase|SQLiteOpenHelper"), "android.database.sqlite"),
        (re.compile(r"androidx\.room|Room\.databaseBuilder|@Database"), "Room/SQLite"),
        (re.compile(r"SQLCipher|net\.sqlcipher"), "SQLCipher"),
    ],
    "secureUiWidgets": [
        (re.compile(r"android\.widget\.EditText|import\s+android\.widget\.EditText"), "android.widget.EditText"),
        (re.compile(r"android\.widget\.TextView|import\s+android\.widget\.TextView"), "android.widget.TextView"),
    ],
    "secureClipboard": [
        (re.compile(r"ClipboardManager|android\.content\.ClipboardManager"), "ClipboardManager"),
        (re.compile(r"LocalClipboard|rememberClipboard|Clipboard\.get"), "Compose clipboard"),
    ],
    "icc": [
        (re.compile(r"Intent\.ACTION_SEND|ACTION_SEND\s*"), "ACTION_SEND share"),
        (re.compile(r"startActivity\s*\([^)]*Intent\.ACTION_"), "implicit share intent"),
    ],
    "webview": [
        (re.compile(r"android\.webkit\.WebView|import\s+android\.webkit\.WebView"), "android.webkit.WebView"),
    ],
}

GRADLE_NET_DEP_HINTS = re.compile(
    r"io\.ktor:|org\.chromium\.net:cronet|io\.grpc:|org\.java-websocket:"
)


def _comment_stripped(line: str) -> str:
    s = line.strip()
    if not s or s.startswith("//") or s.startswith("*") or s.startswith("/*"):
        return ""
    for marker in ("//", "/*"):
        idx = line.find(marker)
        if idx != -1:
            line = line[:idx]
    return line.strip()


def _iter_source_files(root: str) -> Iterable[tuple[str, list[str]]]:
    if not os.path.isdir(root):
        return
    for dirpath, _, filenames in os.walk(root):
        if any(marker in dirpath.replace("\\", "/") for marker in TEST_PATH_MARKERS):
            continue
        for name in filenames:
            if not name.endswith(SOURCE_EXTS):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace("\\", "/")
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    lines = fh.readlines()
            except OSError:
                continue
            yield rel, lines


def _surface_id(domain: str, source_file: str, line_no: int, pattern: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", pattern.lower()).strip("-")[:40]
    return f"{domain}:{source_file}:{line_no}:{slug}"


def _surface_class(domain: str, source_file: str, body: str, pattern: str, file_text: str) -> str:
    normalized_path = source_file.lower()
    if domain == "secureSql":
        if re.search(r"GDRoom|GD.*SQLite|com\.good\.gd\.database\.sqlite", file_text):
            return "bridge"
        if re.search(r"@Dao|@Entity|TypeConverter|RoomDatabase", file_text):
            return "inventory-artifact"
    if domain == "secureClipboard" and pattern == "ClipboardManager":
        # A file that uses the Dynamics secure clipboard API IS the DLP
        # replacement surface (for example a kit-template GDClipboardAdapter),
        # not an unmigrated standard-clipboard data path. Mirror the secureSql
        # bridge classification so the adapter's own secure API usage is not
        # reported as an uncovered security-critical surface. Scoped to the
        # standard ClipboardManager label only; the deterministic clipboard
        # gate (phase-8) remains the authority on any standard
        # android.content.ClipboardManager remnants.
        if re.search(r"com\.good\.gd\.content\.ClipboardManager", file_text):
            return "bridge"
    if domain == "secureUiWidgets":
        if pattern == "android.widget.TextView" and body.startswith("import "):
            return "read-only-ui"
        if pattern == "android.widget.EditText" and body.startswith("import ") and re.search(
            r"(adapter|viewholder|view_holder|vh|binding|extensions?)",
            normalized_path,
        ):
            return "read-only-ui"
    return "data-path"


def scan_source_roots(source_roots: list[str]) -> list[dict]:
    surfaces: list[dict] = []
    seen: set[str] = set()
    for root in source_roots:
        root = os.path.abspath(root)
        for rel, lines in _iter_source_files(root):
            source_file = rel
            if os.path.basename(root) != os.path.basename(os.path.normpath(root)):
                prefix = os.path.basename(root.rstrip(os.sep))
                if not rel.startswith(prefix + "/"):
                    source_file = f"{prefix}/{rel}" if prefix else rel
            file_text = "".join(lines)
            for line_no, raw in enumerate(lines, start=1):
                body = _comment_stripped(raw)
                if not body:
                    continue
                for domain, rules in DOMAIN_RULES.items():
                    for regex, label in rules:
                        if not regex.search(body):
                            continue
                        sid = _surface_id(domain, source_file, line_no, label)
                        if sid in seen:
                            continue
                        seen.add(sid)
                        surface_class = _surface_class(domain, source_file, body, label, file_text)
                        surfaces.append(
                            {
                                "id": sid,
                                "domain": domain,
                                "sourceFile": source_file,
                                "line": line_no,
                                "pattern": label,
                                "securityCritical": surface_class == "data-path",
                                "surfaceClass": surface_class,
                                "evidenceSource": "validator-rediscovery",
                            }
                        )
    return surfaces


def scan_gradle_hints(gradle_paths: list[str]) -> list[dict]:
    surfaces: list[dict] = []
    for path in gradle_paths:
        if not os.path.isfile(path):
            continue
        rel = os.path.basename(path)
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for line_no, raw in enumerate(text.splitlines(), start=1):
            if not GRADLE_NET_DEP_HINTS.search(raw):
                continue
            sid = _surface_id("secureNetworking", rel, line_no, "dependency-owned-network")
            surfaces.append(
                {
                    "id": sid,
                    "domain": "secureNetworking",
                    "sourceFile": rel,
                    "line": line_no,
                    "pattern": "dependency-owned/generated network stack",
                    "securityCritical": True,
                    "surfaceClass": "data-path",
                    "evidenceSource": "validator-rediscovery",
                }
            )
    return surfaces


def build_domain_summary(surfaces: list[dict]) -> dict[str, dict]:
    summary: dict[str, dict] = {}
    for surf in surfaces:
        domain = surf.get("domain")
        if not isinstance(domain, str):
            continue
        bucket = summary.setdefault(
            domain,
            {
                "hitCount": 0,
                "securityCriticalCount": 0,
                "surfaceClasses": {},
            },
        )
        bucket["hitCount"] += 1
        if surf.get("securityCritical") is True:
            bucket["securityCriticalCount"] += 1
        surface_class = surf.get("surfaceClass")
        if isinstance(surface_class, str) and surface_class:
            surface_classes = bucket.setdefault("surfaceClasses", {})
            surface_classes[surface_class] = int(surface_classes.get(surface_class, 0)) + 1
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Independent evidence rediscovery scan")
    parser.add_argument("--output", required=True, help="Write JSON artifact path")
    parser.add_argument("--source-root", action="append", default=[], help="Source root (repeatable)")
    parser.add_argument("--gradle-file", action="append", default=[], help="Gradle/catalog file (repeatable)")
    args = parser.parse_args()

    roots = [os.path.abspath(p) for p in args.source_root if p]
    surfaces = scan_source_roots(roots)
    surfaces.extend(scan_gradle_hints([os.path.abspath(p) for p in args.gradle_file if p]))

    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "surfaces": surfaces,
        "domainSummary": build_domain_summary(surfaces),
    }

    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

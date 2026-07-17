#!/usr/bin/env python3
"""HR-0-2/HR-0-4 report completeness checks for manual interventions."""
from __future__ import annotations

import argparse
import json
import os
import sys


def _load_report(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        obj = json.load(fh)
    if not isinstance(obj, dict):
        raise ValueError("report root must be an object")
    return obj


def _todo_blob(todo: dict) -> str:
    parts = [
        str(todo.get("title", "")),
        str(todo.get("reason", "")),
        str(todo.get("domain", "")),
    ]
    for key in ("evidence", "requiredActions", "acceptanceCriteria"):
        val = todo.get(key)
        if isinstance(val, list):
            parts.extend(str(v) for v in val if isinstance(v, str))
    return " ".join(parts).lower()


def _is_non_blocking_app_todo(todo: dict) -> bool:
    return (
        isinstance(todo, dict)
        and todo.get("blocking") is False
        and todo.get("owner") == "applicationDeveloper"
    )


def _require_manual_todo(
    todos: list[dict],
    *,
    name: str,
    tokens_any: tuple[str, ...],
    errors: list[str],
) -> None:
    for todo in todos:
        blob = _todo_blob(todo)
        if any(tok in blob for tok in tokens_any):
            return
    errors.append(
        f"manualTodos[] missing required non-blocking developer-owned entry for {name}"
    )


def _todo_overlap_nonwaivable(todo: dict) -> bool:
    blob = _todo_blob(todo)
    overlap_tokens = (
        "external storage",
        "externalstorage",
        "mediastore",
        "security blocker",
        "unapproved outbound file sharing",
        "saf uri sharing",
        "fileprovider",
        "non-dynamics transport",
        "unsupported transport",
    )
    return any(tok in blob for tok in overlap_tokens)


def _require_dlp_manual_todo(
    todos: list[dict],
    *,
    name: str,
    tokens_any: tuple[str, ...],
    errors: list[str],
) -> None:
    non_blocking_match = False
    blocking_overlap_match = False
    blocking_non_overlap_match = False
    for todo in todos:
        blob = _todo_blob(todo)
        if not any(tok in blob for tok in tokens_any):
            continue
        if todo.get("blocking") is False:
            non_blocking_match = True
            break
        if todo.get("blocking") is True:
            if _todo_overlap_nonwaivable(todo):
                blocking_overlap_match = True
            else:
                blocking_non_overlap_match = True

    if non_blocking_match:
        return
    if blocking_overlap_match:
        return
    if blocking_non_overlap_match:
        errors.append(
            f"manualTodos[] has blocking=true for {name} without non-waivable overlap evidence; default must be blocking=false"
        )
        return
    errors.append(
        f"manualTodos[] missing required DLP non-blocking entry for {name}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Opaque native and broad DLP/export manualTodo checker"
    )
    parser.add_argument("--report", required=True)
    parser.add_argument("--native-so-hits", type=int, default=0)
    parser.add_argument("--jni-load-hits", type=int, default=0)
    parser.add_argument("--opaque-binary-dep-hits", type=int, default=0)
    parser.add_argument("--dlp-notification-hits", type=int, default=0)
    parser.add_argument("--dlp-print-hits", type=int, default=0)
    parser.add_argument("--dlp-screenshot-hits", type=int, default=0)
    parser.add_argument("--dlp-autofill-hits", type=int, default=0)
    parser.add_argument("--dlp-accessibility-hits", type=int, default=0)
    parser.add_argument("--dlp-ime-hits", type=int, default=0)
    parser.add_argument("--dlp-external-browser-hits", type=int, default=0)
    parser.add_argument("--dlp-rich-clipboard-uri-hits", type=int, default=0)
    parser.add_argument("--dlp-dragdrop-hits", type=int, default=0)
    args = parser.parse_args()

    if not os.path.isfile(args.report):
        print("ERROR:migration-report.json not found", file=sys.stderr)
        return 1

    try:
        report = _load_report(args.report)
    except Exception as exc:  # pragma: no cover - defensive for malformed fixtures
        print(f"ERROR:could not parse migration-report.json: {exc}", file=sys.stderr)
        return 1

    todos_raw = report.get("manualTodos")
    todos_all = [
        t
        for t in (todos_raw or [])
        if isinstance(t, dict) and t.get("owner") == "applicationDeveloper"
    ]
    todos = [t for t in todos_all if _is_non_blocking_app_todo(t)]
    errors: list[str] = []

    if args.native_so_hits > 0:
        _require_manual_todo(
            todos,
            name="prebuilt native .so libraries",
            tokens_any=("jni", ".so", "native binary", "loadlibrary"),
            errors=errors,
        )
    if args.jni_load_hits > 0:
        _require_manual_todo(
            todos,
            name="JNI System.loadLibrary opaque native code",
            tokens_any=("system.loadlibrary", "loadlibrary", "opaque native", "jni"),
            errors=errors,
        )
    if args.opaque_binary_dep_hits > 0:
        _require_manual_todo(
            todos,
            name="opaque binary SDK dependencies (.aar/.jar/fileTree/flatDir)",
            tokens_any=("binary dependency", ".aar", ".jar", "flatdir", "filetree", "closed-source"),
            errors=errors,
        )

    if (args.native_so_hits + args.jni_load_hits + args.opaque_binary_dep_hits) > 0:
        # Report must explicitly call out out-of-scope responsibility.
        if not any(
            "out of automatic migration scope" in _todo_blob(todo)
            or "developer-owned manual intervention" in _todo_blob(todo)
            for todo in todos
        ):
            errors.append(
                "manualTodos[] must state that opaque native/closed-source internals are out of automatic migration scope"
            )

    if args.dlp_notification_hits > 0:
        _require_dlp_manual_todo(
            todos_all,
            name="sensitive notifications",
            tokens_any=("notification", "lock screen", "notificationcompat.builder"),
            errors=errors,
        )
    if args.dlp_print_hits > 0:
        _require_dlp_manual_todo(
            todos_all,
            name="printing surfaces",
            tokens_any=("print", "printmanager", "printdocumentadapter"),
            errors=errors,
        )
    if args.dlp_screenshot_hits > 0:
        _require_dlp_manual_todo(
            todos_all,
            name="screenshots/recent-thumbnails",
            tokens_any=("flag_secure", "screenshot", "thumbnail", "recents"),
            errors=errors,
        )
    if args.dlp_autofill_hits > 0:
        _require_dlp_manual_todo(
            todos_all,
            name="autofill surfaces",
            tokens_any=("autofill",),
            errors=errors,
        )
    if args.dlp_accessibility_hits > 0:
        _require_dlp_manual_todo(
            todos_all,
            name="accessibility surfaces",
            tokens_any=("accessibility",),
            errors=errors,
        )
    if args.dlp_ime_hits > 0:
        _require_dlp_manual_todo(
            todos_all,
            name="IME/keyboard surfaces",
            tokens_any=("ime", "inputmethod", "keyboard"),
            errors=errors,
        )
    if args.dlp_external_browser_hits > 0:
        _require_dlp_manual_todo(
            todos_all,
            name="external browser/custom tabs surfaces",
            tokens_any=("customtabs", "custom tabs", "external browser", "action_view"),
            errors=errors,
        )
    if args.dlp_rich_clipboard_uri_hits > 0:
        _require_dlp_manual_todo(
            todos_all,
            name="rich clipboard URI surfaces",
            tokens_any=("clipdata.newuri", "rich clipboard", "clipboard uri", "clipdata"),
            errors=errors,
        )
    if args.dlp_dragdrop_hits > 0:
        _require_dlp_manual_todo(
            todos_all,
            name="drag/drop surfaces",
            tokens_any=("drag", "dragdrop", "drag and drop"),
            errors=errors,
        )

    if errors:
        for err in errors:
            print(f"ERROR:{err}")
        return 1

    print("OK:opaque native + broad DLP/export manual intervention coverage validated")
    return 0


if __name__ == "__main__":
    sys.exit(main())

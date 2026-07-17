#!/usr/bin/env python3
"""Optional migration observability helpers.

This helper records content-free JSONL events when
`DYNAMICS_MIGRATION_OBSERVABILITY=1` is set. It never logs source contents and
is best-effort: callers should ignore failures so migration behavior is
unchanged when telemetry is disabled or malformed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Iterable, Optional


TRUE_VALUES = {"1", "true", "yes", "on"}
EVENTS_REL = Path("output/observability/migration-observability.jsonl")
SUMMARY_REL = Path("output/observability/migration-observability-summary.json")
STATE_REL = Path("output/observability/.observability-state.json")


def enabled() -> bool:
    return os.environ.get("DYNAMICS_MIGRATION_OBSERVABILITY", "").lower() in TRUE_VALUES


def now_ms() -> int:
    return int(time.time() * 1000)


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def atomic_write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        delete=False,
        dir=str(path.parent),
        prefix=f"{path.name}.tmp.",
    ) as tmp:
        json.dump(payload, tmp, indent=2, sort_keys=True)
        tmp.write("\n")
        tmp_path = Path(tmp.name)
    os.replace(tmp_path, path)


def normalize_path(path_value: str, project_root: Path, tool_dir: Path) -> Dict[str, Any]:
    raw = (path_value or "").strip()
    if not raw:
        return {"normalizedPath": None}

    p = Path(raw)
    if not p.is_absolute():
        p = (project_root / p).resolve()
    else:
        p = p.resolve()

    for base, prefix in ((project_root.resolve(), ""), (tool_dir.resolve(), "dynamics-migration-tool/")):
        try:
            rel = p.relative_to(base)
            return {
                "normalizedPath": f"{prefix}{rel.as_posix()}",
                "pathScope": "project" if not prefix else "toolkit",
            }
        except ValueError:
            continue

    return {
        "normalizedPath": p.name,
        "pathScope": "outside-project",
        "pathOutsideProject": True,
    }


def file_stats(path_value: str, project_root: Path) -> Dict[str, Any]:
    if not path_value:
        return {}
    p = Path(path_value)
    if not p.is_absolute():
        p = project_root / p
    try:
        if not p.is_file():
            return {}
        data = p.read_bytes()
    except Exception:
        return {}
    return {
        "contentHash": hashlib.sha256(data).hexdigest(),
        "bytesProcessed": len(data),
    }


def state_key(event: Dict[str, Any]) -> str:
    return "|".join(
        str(event.get(k) or "")
        for k in ("platform", "operationType", "promptId", "phase", "normalizedPath", "requestedRange")
    )


def update_changed_state(state_path: Path, event: Dict[str, Any]) -> Optional[bool]:
    content_hash = event.get("contentHash")
    if not content_hash:
        return None
    state = load_json(state_path, {"hashes": {}})
    hashes = state.get("hashes")
    if not isinstance(hashes, dict):
        hashes = {}
        state["hashes"] = hashes
    key = state_key(event)
    previous = hashes.get(key)
    hashes[key] = content_hash
    state["updatedAt"] = iso_now()
    atomic_write_json(state_path, state)
    if previous is None:
        return None
    return previous != content_hash


def parse_metadata(raw: str) -> Dict[str, Any]:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            return parsed
    except Exception:
        pass
    return {"metadataParseError": True}


def append_event(events_path: Path, event: Dict[str, Any]) -> None:
    events_path.parent.mkdir(parents=True, exist_ok=True)
    with events_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, sort_keys=True, separators=(",", ":")))
        fh.write("\n")


def iter_events(events_path: Path) -> Iterable[Dict[str, Any]]:
    if not events_path.is_file():
        return
    with events_path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                yield {"__malformed__": True}
                continue
            if isinstance(obj, dict):
                yield obj
            else:
                yield {"__malformed__": True}


def write_summary(tool_dir: Path) -> None:
    events_path = tool_dir / EVENTS_REL
    summary_path = tool_dir / SUMMARY_REL
    operation_counts: Dict[str, int] = {}
    platform_counts: Dict[str, int] = {}
    total_duration = 0
    validation_duration = 0
    build_duration = 0
    bytes_processed = 0
    search_count = 0
    malformed = 0
    event_count = 0

    for event in iter_events(events_path) or []:
        if event.get("__malformed__"):
            malformed += 1
            continue
        event_count += 1
        op = str(event.get("operationType") or "unknown")
        platform = str(event.get("platform") or "unknown")
        operation_counts[op] = operation_counts.get(op, 0) + 1
        platform_counts[platform] = platform_counts.get(platform, 0) + 1
        duration = int(event.get("durationMs") or 0)
        total_duration += duration
        if op in {"validation-run", "validator-search", "source-staging", "script-hash-read"}:
            validation_duration += duration
        if op == "build":
            build_duration += duration
        if op in {"repo-search", "validator-search"}:
            search_count += 1
        bytes_processed += int(event.get("bytesProcessed") or 0)

    atomic_write_json(
        summary_path,
        {
            "schemaVersion": "1.0.0",
            "generatedAt": iso_now(),
            "eventCount": event_count,
            "malformedEventCount": malformed,
            "operationCounts": operation_counts,
            "platformCounts": platform_counts,
            "totalDurationMs": total_duration,
            "validationDurationMs": validation_duration,
            "buildDurationMs": build_duration,
            "repositorySearchCount": search_count,
            "bytesProcessed": bytes_processed,
            "eventsFile": str(EVENTS_REL),
        },
    )


def record_event(args: argparse.Namespace) -> int:
    if not enabled():
        return 0

    tool_dir = Path(args.tool_dir).resolve()
    project_root = Path(args.project_root or tool_dir.parent).resolve()
    event: Dict[str, Any] = {
        "schemaVersion": "1.0.0",
        "timestamp": iso_now(),
        "runId": args.run_id or "",
        "platform": args.platform,
        "promptId": args.prompt_id or None,
        "phase": args.phase or None,
        "operationType": args.operation_type,
        "status": args.status or None,
        "requestedRange": args.requested_range or None,
        "cacheStatus": args.cache_status or "not-applicable",
    }

    if args.path:
        event.update(normalize_path(args.path, project_root, tool_dir))
        if not args.content_hash:
            event.update(file_stats(args.path, project_root))
    if args.content_hash:
        event["contentHash"] = args.content_hash
    if args.bytes_processed is not None:
        event["bytesProcessed"] = max(0, args.bytes_processed)

    start_ms = args.start_ms or 0
    end_ms = args.end_ms or now_ms()
    if args.duration_ms is not None:
        duration = max(0, args.duration_ms)
    elif start_ms:
        duration = max(0, end_ms - start_ms)
    else:
        duration = 0
    event["startTimeMs"] = start_ms or None
    event["durationMs"] = duration

    metadata = parse_metadata(args.metadata_json or "")
    if metadata:
        event["metadata"] = metadata

    changed = update_changed_state(tool_dir / STATE_REL, event)
    event["fileChangedSincePreviousRead"] = changed

    append_event(tool_dir / EVENTS_REL, event)
    write_summary(tool_dir)
    return 0


def hash_file(args: argparse.Namespace) -> int:
    project_root = Path(args.project_root).resolve()
    stats = file_stats(args.path, project_root)
    normalized = normalize_path(args.path, project_root, Path(args.tool_dir or project_root / "dynamics-migration-tool"))
    payload = {**normalized, **stats}
    print(json.dumps(payload, sort_keys=True))
    return 0


def summarize(args: argparse.Namespace) -> int:
    if not enabled():
        return 0
    write_summary(Path(args.tool_dir).resolve())
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Dynamics migration observability")
    sub = parser.add_subparsers(dest="cmd", required=True)

    event = sub.add_parser("event")
    event.add_argument("--tool-dir", required=True)
    event.add_argument("--project-root", default="")
    event.add_argument("--platform", required=True)
    event.add_argument("--run-id", default="")
    event.add_argument("--prompt-id", default="")
    event.add_argument("--phase", default="")
    event.add_argument("--operation-type", required=True)
    event.add_argument("--path", default="")
    event.add_argument("--content-hash", default="")
    event.add_argument("--requested-range", default="")
    event.add_argument("--bytes-processed", type=int)
    event.add_argument("--start-ms", type=int, default=0)
    event.add_argument("--end-ms", type=int, default=0)
    event.add_argument("--duration-ms", type=int)
    event.add_argument("--cache-status", default="not-applicable")
    event.add_argument("--status", default="")
    event.add_argument("--metadata-json", default="")
    event.set_defaults(func=record_event)

    h = sub.add_parser("hash-file")
    h.add_argument("--project-root", required=True)
    h.add_argument("--tool-dir", default="")
    h.add_argument("--path", required=True)
    h.set_defaults(func=hash_file)

    summary = sub.add_parser("summary")
    summary.add_argument("--tool-dir", required=True)
    summary.set_defaults(func=summarize)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

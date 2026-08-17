#!/usr/bin/env python3
"""One-time migration: legacy JSON cache files -> SQLite (cache/danbooru_tags.db).

Imports:
    cache/successful_tags.json      -> sync_status (status='success')
    cache/failed_tags.json          -> sync_status (status='failed')
    cache/do_not_retry_tags.json    -> sync_status (status='blocked')
    cache/tag_api_cursor.json       -> api_cursor
    cache/sync_metadata.json        -> sync_metadata (if present)
    cache/tags_checkpoint.json      -> checkpoint
    .danbooru_cache/{tag}.json      -> tags (if present)
    assets/danbooru_completion/*.json -> tags (if present)

By default the successfully-imported JSON files are deleted afterwards
("只存数据库"); pass --keep to retain them as a safety net.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.tag_db import db, now_iso

CACHE_DIR = ROOT / "cache"
DOT_CACHE_DIR = ROOT / ".danbooru_cache"
ASSET_DIR = ROOT / "assets" / "danbooru_completion"


def load_json(path: Path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"  [WARN] cannot parse {path}: {exc}")
        return default


def migrate_sync_status() -> dict[str, int]:
    counts = {"success": 0, "failed": 0, "blocked": 0}
    rows: list[tuple] = []

    successful = load_json(CACHE_DIR / "successful_tags.json", [])
    if isinstance(successful, list):
        for tag in successful:
            if isinstance(tag, str) and tag:
                rows.append((tag, "success", None, 0, now_iso(), None))
                counts["success"] += 1
        print(f"  parsed successful_tags.json -> {counts['success']} 'success' rows")

    failed = load_json(CACHE_DIR / "failed_tags.json", {})
    if isinstance(failed, dict):
        for tag, entry in failed.items():
            if not isinstance(entry, dict):
                entry = {}
            rows.append(
                (
                    tag,
                    "failed",
                    str(entry.get("reason") or "unknown"),
                    int(entry.get("failures") or 1),
                    None,
                    entry.get("last_failed_at"),
                )
            )
            counts["failed"] += 1
        print(f"  parsed failed_tags.json -> {counts['failed']} 'failed' rows")

    blocked = load_json(CACHE_DIR / "do_not_retry_tags.json", {})
    if isinstance(blocked, dict):
        for tag, entry in blocked.items():
            if not isinstance(entry, dict):
                entry = {}
            rows.append(
                (
                    tag,
                    "blocked",
                    str(entry.get("reason") or "unknown"),
                    int(entry.get("failures") or 1),
                    None,
                    entry.get("last_failed_at"),
                )
            )
            counts["blocked"] += 1
        print(f"  parsed do_not_retry_tags.json -> {counts['blocked']} 'blocked' rows")

    db.upsert_sync_status_many(rows)
    print(f"  wrote {len(rows)} sync_status rows (single transaction)")
    return counts


def migrate_cursor() -> int:
    raw = load_json(CACHE_DIR / "tag_api_cursor.json", {})
    if not isinstance(raw, dict):
        return 0
    mid = raw.get("min_id")
    mad = raw.get("max_id")
    if isinstance(mid, int) and isinstance(mad, int):
        db.save_cursor({"min_id": mid, "max_id": mad})
        print(f"  imported tag_api_cursor.json -> min={mid} max={mad}")
        return 1
    print("  [SKIP] tag_api_cursor.json has no valid min/max id")
    return 0


def migrate_metadata() -> int:
    raw = load_json(CACHE_DIR / "sync_metadata.json", {})
    if not isinstance(raw, dict) or not raw:
        print("  [SKIP] sync_metadata.json missing or empty")
        return 0
    db.save_metadata(raw)
    print(f"  imported sync_metadata.json -> {len(raw)} rows")
    return len(raw)


def migrate_checkpoint() -> int:
    raw = load_json(CACHE_DIR / "tags_checkpoint.json", None)
    if not isinstance(raw, dict):
        print("  [SKIP] tags_checkpoint.json missing or invalid")
        return 0
    db.save_checkpoint(raw)
    print(f"  imported tags_checkpoint.json -> {raw}")
    return 1


def migrate_tags() -> tuple[int, list[Path]]:
    """Import per-tag detail payloads; returns (imported_count, source_paths)."""
    sources: list[Path] = []
    if DOT_CACHE_DIR.is_dir():
        sources += sorted(DOT_CACHE_DIR.glob("*.json"))
    if ASSET_DIR.is_dir():
        sources += sorted(ASSET_DIR.glob("*.json"))

    imported = 0
    seen = set()
    payloads = []
    for path in sources:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"  [WARN] skip invalid {path}: {exc}")
            continue
        if not isinstance(payload, dict) or not payload.get("tag"):
            print(f"  [WARN] skip payload without 'tag': {path.name}")
            continue
        tag = payload["tag"]
        # .danbooru_cache wins over the mirrored asset copy
        if tag in seen:
            continue
        seen.add(tag)
        payloads.append(payload)

    try:
        db.upsert_tags_many(payloads)
        imported = len(payloads)
    except Exception as exc:
        print(f"  [ERROR] bulk import failed: {exc}")
        imported = 0

    print(f"  imported per-tag payloads -> {imported} rows (from {len(sources)} files)")
    return imported, sources


def delete_sources(paths: list[Path]):
    removed = 0
    for path in sorted(set(paths)):
        try:
            path.unlink()
            removed += 1
        except FileNotFoundError:
            pass
        except OSError as exc:
            print(f"  [WARN] cannot delete {path}: {exc}")
    return removed


def main():
    parser = argparse.ArgumentParser(
        description="Migrate legacy JSON tag caches into cache/danbooru_tags.db"
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="Keep the source JSON files after a successful migration.",
    )
    args = parser.parse_args()

    print("Migrating sync status...")
    status_counts = migrate_sync_status()

    print("Migrating API cursor...")
    migrate_cursor()

    print("Migrating sync metadata...")
    migrate_metadata()

    print("Migrating checkpoint...")
    migrate_checkpoint()

    print("Migrating per-tag payloads...")
    tag_count, tag_sources = migrate_tags()

    status_rows = sum(status_counts.values())
    total_tags = db.count_tags()
    print()
    print("=" * 60)
    print("Migration summary")
    print(f"  sync_status rows : {status_rows} "
          f"(success={status_counts['success']}, failed={status_counts['failed']}, blocked={status_counts['blocked']})")
    print(f"  tags rows        : {total_tags}")
    print(f"  db path          : {db.path}")
    print("=" * 60)

    state_files = [
        CACHE_DIR / "successful_tags.json",
        CACHE_DIR / "failed_tags.json",
        CACHE_DIR / "do_not_retry_tags.json",
        CACHE_DIR / "tag_api_cursor.json",
        CACHE_DIR / "sync_metadata.json",
        CACHE_DIR / "tags_checkpoint.json",
    ]
    removable = [p for p in state_files if p.exists()] + tag_sources

    if args.keep:
        print("Keeping source JSON files (--keep).")
        return 0

    if not removable:
        print("Nothing to delete.")
        return 0

    print(f"\nDeleting {len(removable)} migrated JSON file(s)...")
    removed = delete_sources(removable)
    print(f"Deleted {removed} file(s). JSON is now fully migrated to the database.")

    # Best-effort remove empty dirs left behind.
    for d in (DOT_CACHE_DIR, ASSET_DIR):
        try:
            if d.is_dir() and not any(d.iterdir()):
                d.rmdir()
        except OSError:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

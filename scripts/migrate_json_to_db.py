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

Cleanup first claims each source in a private directory on the same filesystem
and only unlinks that verified snapshot. A newly published original path is
never removed. Failed cleanup restores the name without overwriting a new file,
or prints the retained snapshot's recovery path. Stop older/external writers
before migrating: an already-open descriptor can still modify a renamed inode.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.tag_db import db, now_iso

CACHE_DIR = ROOT / "cache"
DOT_CACHE_DIR = ROOT / ".danbooru_cache"
ASSET_DIR = ROOT / "assets" / "danbooru_completion"


class MigrationError(ValueError):
    """A source was not safely imported; it must be retained."""


def load_json(path: Path, default, imported_sources: dict[Path, str] | None = None):
    if not path.exists():
        return default
    try:
        source_bytes = path.read_bytes()
        payload = json.loads(source_bytes.decode("utf-8"))
    except (OSError, ValueError) as exc:
        raise MigrationError(f"cannot read {path}: {exc}") from exc
    if imported_sources is not None:
        imported_sources[path] = hashlib.sha256(source_bytes).hexdigest()
    return payload


def require_type(value, expected, source: str):
    if not isinstance(value, expected):
        raise MigrationError(f"{source} must contain {expected.__name__}")
    return value


def migrate_sync_status(imported_sources: dict[Path, str] | None = None) -> dict[str, int]:
    counts = {"success": 0, "failed": 0, "blocked": 0}
    rows: list[tuple] = []

    successful = load_json(CACHE_DIR / "successful_tags.json", [], imported_sources)
    require_type(successful, list, "successful_tags.json")
    if isinstance(successful, list):
        for tag in successful:
            if not isinstance(tag, str) or not tag:
                raise MigrationError("successful_tags.json contains an invalid tag")
            rows.append((tag, "success", None, 0, now_iso(), None))
            counts["success"] += 1
        print(f"  parsed successful_tags.json -> {counts['success']} 'success' rows")

    failed = load_json(CACHE_DIR / "failed_tags.json", {}, imported_sources)
    require_type(failed, dict, "failed_tags.json")
    if isinstance(failed, dict):
        for tag, entry in failed.items():
            if not tag or not isinstance(entry, dict):
                raise MigrationError("failed_tags.json contains an invalid entry")
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

    blocked = load_json(CACHE_DIR / "do_not_retry_tags.json", {}, imported_sources)
    require_type(blocked, dict, "do_not_retry_tags.json")
    if isinstance(blocked, dict):
        for tag, entry in blocked.items():
            if not tag or not isinstance(entry, dict):
                raise MigrationError("do_not_retry_tags.json contains an invalid entry")
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


def migrate_cursor(imported_sources: dict[Path, str] | None = None) -> int:
    raw = load_json(CACHE_DIR / "tag_api_cursor.json", {}, imported_sources)
    require_type(raw, dict, "tag_api_cursor.json")
    if not raw:
        return 0
    mid = raw.get("min_id")
    mad = raw.get("max_id")
    if isinstance(mid, int) and isinstance(mad, int):
        db.save_cursor({"min_id": mid, "max_id": mad})
        print(f"  imported tag_api_cursor.json -> min={mid} max={mad}")
        return 1
    raise MigrationError("tag_api_cursor.json has no valid min/max id")


def migrate_metadata(imported_sources: dict[Path, str] | None = None) -> int:
    metadata = {}
    for directory in (CACHE_DIR, DOT_CACHE_DIR):
        path = directory / "sync_metadata.json"
        raw = require_type(load_json(path, {}, imported_sources), dict, str(path))
        if any(not slug or not isinstance(entry, dict) for slug, entry in raw.items()):
            raise MigrationError(f"{path} contains an invalid metadata entry")
        for slug, entry in raw.items():
            if slug in metadata and metadata[slug] != entry:
                raise MigrationError(f"conflicting metadata for {slug}; retaining both sources")
            metadata[slug] = entry
    db.save_metadata(metadata)
    print(f"  imported sync_metadata.json -> {len(metadata)} rows")
    return len(metadata)


def migrate_checkpoint(imported_sources: dict[Path, str] | None = None) -> int:
    raw = load_json(CACHE_DIR / "tags_checkpoint.json", None, imported_sources)
    if raw is None and not (CACHE_DIR / "tags_checkpoint.json").exists():
        return 0
    require_type(raw, dict, "tags_checkpoint.json")
    db.save_checkpoint(raw)
    print(f"  imported tags_checkpoint.json -> {raw}")
    return 1


def migrate_tags(imported_sources: dict[Path, str] | None = None) -> tuple[int, list[Path]]:
    """Import per-tag detail payloads; returns (imported_count, source_paths)."""
    sources: list[Path] = []
    if DOT_CACHE_DIR.is_dir():
        sources += sorted(path for path in DOT_CACHE_DIR.glob("*.json")
                          if path.name != "sync_metadata.json")
    if ASSET_DIR.is_dir():
        sources += sorted(ASSET_DIR.glob("*.json"))

    imported = 0
    seen = {}
    payloads = []
    for path in sources:
        payload = load_json(path, None, imported_sources)
        if (not isinstance(payload, dict)
                or not isinstance(payload.get("tag"), str)
                or not payload["tag"]):
            raise MigrationError(f"payload without a valid tag: {path}")
        tag = payload["tag"]
        if tag in seen:
            if seen[tag] != payload:
                raise MigrationError(f"conflicting payloads for {tag}; retaining both sources")
            continue
        seen[tag] = payload
        payloads.append(payload)

    db.import_tags(payloads)
    imported = len(payloads)

    print(f"  imported per-tag payloads -> {imported} rows (from {len(sources)} files)")
    return imported, sources


def _retain_claim(source: Path, claimed: Path) -> list[Path]:
    """Restore without clobbering a concurrently published source path."""
    try:
        # Unlike rename on POSIX, link never replaces an existing destination.
        # The original snapshot remains available if links are unsupported
        # (for example on a Windows volume without hard-link support).
        os.link(claimed, source)
    except FileExistsError:
        print(f"  [WARN] source path was recreated; retained {source} and snapshot {claimed}")
        return [source, claimed]
    except OSError as exc:
        print(f"  [WARN] cannot restore {source}; recovery snapshot retained at {claimed}: {exc}")
        return [claimed]

    try:
        claimed.unlink()
    except OSError as exc:
        print(f"  [WARN] source restored at {source}; duplicate snapshot retained at {claimed}: {exc}")
        return [source, claimed]
    print(f"  [WARN] source retained at {source}")
    return [source]


def delete_sources(imported_sources: dict[Path, str]) -> tuple[int, list[Path]]:
    """Claim before checking bytes; never unlink the shared source pathname.

    This covers writers that publish a complete temporary file with replace,
    including current view.py. It cannot isolate writes through descriptors
    opened by older or external in-place writers before the rename.
    """
    removed = 0
    retained = []
    for path, expected_hash in sorted(imported_sources.items()):
        directory = None
        claimed = None
        owns_claim = False
        try:
            # A private sibling directory provides an unused destination on
            # the same filesystem. Never auto-delete its contents on errors.
            directory = Path(tempfile.mkdtemp(prefix=".migration-cleanup-", dir=path.parent))
            claimed = directory / path.name
            path.rename(claimed)
            owns_claim = True
            current_hash = hashlib.sha256(claimed.read_bytes()).hexdigest()
            if current_hash != expected_hash:
                print(f"  [WARN] source changed after import: {path}")
                continue
            claimed.unlink()
            owns_claim = False
            removed += 1
            if path.exists():
                print(f"  [WARN] new source published during cleanup; retained {path}")
                retained.append(path)
        except FileNotFoundError as exc:
            # A source already removed by another process needs no deletion.
            if owns_claim:
                print(f"  [WARN] cannot verify claimed snapshot at {claimed}: {exc}")
                retained.append(claimed)
        except Exception as exc:
            print(f"  [WARN] cannot safely clean up {path}: {exc}")
            if not owns_claim:
                retained.append(path)
        finally:
            # Also retain an owned snapshot when interrupted. Restore using a
            # no-overwrite operation, or leave it at the printed recovery path.
            if claimed is not None:
                try:
                    if owns_claim or claimed.exists():
                        retained.extend(_retain_claim(path, claimed))
                except Exception as exc:
                    print(f"  [WARN] recovery could not finish; check snapshot at {claimed}: {exc}")
                    retained.append(claimed)
            if directory is not None:
                try:
                    directory.rmdir()  # Empty only; never recursively remove.
                except OSError:
                    pass
    return removed, retained


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

    imported_sources: dict[Path, str] = {}
    try:
        print("Migrating sync status...")
        status_counts = migrate_sync_status(imported_sources)
        print("Migrating API cursor...")
        migrate_cursor(imported_sources)
        print("Migrating sync metadata...")
        migrate_metadata(imported_sources)
        print("Migrating checkpoint...")
        migrate_checkpoint(imported_sources)
        print("Migrating per-tag payloads...")
        migrate_tags(imported_sources)
    except Exception as exc:
        print(f"[ERROR] Migration incomplete; all source files retained: {exc}")
        return 1

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

    if args.keep:
        print("Keeping source JSON files (--keep).")
        return 0

    if not imported_sources:
        print("Nothing to delete.")
        return 0

    print(f"\nDeleting {len(imported_sources)} migrated JSON file(s)...")
    removed, retained = delete_sources(imported_sources)
    if retained:
        print(f"[ERROR] Imported data was committed, but cleanup is incomplete: "
              f"deleted {removed}, retained {len(retained)} source file(s).")
        return 1
    print(f"Deleted {removed} verified imported JSON snapshot(s). "
          "Any later publications require a separate migration.")

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

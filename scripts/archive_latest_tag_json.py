#!/usr/bin/env python3
"""Archive the newest synced Danbooru tag JSON files."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import view
from scripts.batch_sync_tags import (
    create_session,
    fetch_tags_from_api_page,
    load_tag_cursor,
)

CACHE_DIR = ROOT / ".danbooru_cache"
OUTPUT_FILE = ROOT / "assets" / "danbooru_latest_10000_raw_json.zip"
MANIFEST_FILE = OUTPUT_FILE.with_suffix(".manifest.json")
ZIP_MANIFEST_NAME = "manifest.json"
JSON_PREFIX = "json"


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def iter_latest_tag_records(limit: int, page_size: int, retries: int, delay: float):
    cursor = load_tag_cursor()
    max_id = cursor.get("max_id")
    if not isinstance(max_id, int):
        raise SystemExit("cache/tag_api_cursor.json must contain an integer max_id")

    session = create_session()
    cursor_id: int | None = max_id + 1
    yielded = 0

    while yielded < limit:
        records = fetch_tags_from_api_page(
            session,
            order="id_desc",
            cursor_id=cursor_id,
            limit=min(page_size, limit - yielded),
            max_retries=retries,
        )
        if not records:
            break

        for record in records:
            if record.tag_id is None:
                continue
            if record.tag_id > max_id:
                continue
            yield record
            yielded += 1
            if yielded >= limit:
                break

        ids = [record.tag_id for record in records if record.tag_id is not None]
        if not ids:
            break
        cursor_id = min(ids)
        time.sleep(delay)


def build_archive(limit: int, page_size: int, retries: int, delay: float, output: Path):
    output.parent.mkdir(parents=True, exist_ok=True)
    temp_output = output.with_name(f".{output.name}.tmp")
    entries = []
    missing = []

    with ZipFile(temp_output, "w", ZIP_DEFLATED, compresslevel=6) as archive:
        for record in iter_latest_tag_records(limit, page_size, retries, delay):
            slug = view.slugify_tag(record.name)
            source = CACHE_DIR / f"{slug}.json"
            if not source.is_file():
                missing.append(record.name)
                continue

            payload = source.read_bytes()
            archive_name = f"{JSON_PREFIX}/{slug}.json"
            archive.writestr(archive_name, payload)
            entries.append(
                {
                    "tag": record.name,
                    "tag_id": record.tag_id,
                    "slug": slug,
                    "file": archive_name,
                    "sha256": sha256_bytes(payload),
                    "size": len(payload),
                }
            )

        manifest = {
            "format": "danbooru-raw-json-archive-v1",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "requested_limit": limit,
            "items": len(entries),
            "missing_items": len(missing),
            "missing_tags": missing[:100],
            "source": "cache/tag_api_cursor.json max_id descending",
            "entries": entries,
        }
        archive.writestr(
            ZIP_MANIFEST_NAME,
            json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8"),
        )

    temp_output.replace(output)

    manifest_path = output.with_suffix(".manifest.json")
    manifest_path.write_text(
        json.dumps(
            {
                "format": "danbooru-raw-json-archive-v1",
                "archive": output.name,
                "archive_size": output.stat().st_size,
                "archive_sha256": sha256_bytes(output.read_bytes()),
                "items": len(entries),
                "missing_items": len(missing),
                "updated_at": datetime.now(timezone.utc).isoformat(),
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    print(
        f"Archived {len(entries)} raw JSON files to {output} "
        f"({len(missing)} missing)."
    )
    if len(entries) < limit:
        raise SystemExit(1)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Archive newest synced raw Danbooru tag JSON files."
    )
    parser.add_argument("--limit", type=int, default=10000)
    parser.add_argument("--page-size", type=int, default=500)
    parser.add_argument("--retries", type=int, default=5)
    parser.add_argument("--delay", type=float, default=1.0)
    parser.add_argument("--output", type=Path, default=OUTPUT_FILE)
    return parser.parse_args()


def main():
    args = parse_args()
    build_archive(
        limit=args.limit,
        page_size=args.page_size,
        retries=args.retries,
        delay=args.delay,
        output=args.output,
    )


if __name__ == "__main__":
    main()

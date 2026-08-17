#!/usr/bin/env python3
"""Restore raw Danbooru tag JSON files from the latest-tag archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.tag_db import db

DEFAULT_ARCHIVE = ROOT / "assets" / "danbooru_latest_10000_raw_json.zip"
CACHE_DIR = ROOT / ".danbooru_cache"
ASSET_DIR = ROOT / "assets" / "danbooru_completion"
ZIP_MANIFEST_NAME = "manifest.json"


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def restore_archive(
    archive_path: Path,
    cache_dir: Path,
    asset_dir: Path | None,
    dry_run: bool,
):
    with ZipFile(archive_path, "r") as archive:
        manifest = json.loads(
            archive.read(ZIP_MANIFEST_NAME).decode("utf-8")
        )
        entries = manifest.get("entries")
        if not isinstance(entries, list):
            raise SystemExit("archive manifest does not contain entries")

        restored = 0
        for entry in entries:
            if not isinstance(entry, dict):
                continue

            archive_name = entry.get("file")
            slug = entry.get("slug")
            expected_hash = entry.get("sha256")
            if not all(isinstance(value, str) for value in (archive_name, slug, expected_hash)):
                continue

            payload_bytes = archive.read(archive_name)
            actual_hash = sha256_bytes(payload_bytes)
            if actual_hash != expected_hash:
                raise SystemExit(
                    f"sha256 mismatch for {archive_name}: "
                    f"expected {expected_hash}, got {actual_hash}"
                )

            if not dry_run:
                try:
                    payload = json.loads(payload_bytes.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    print(f"  [WARN] skip invalid payload {archive_name}: {exc}")
                    continue
                if not isinstance(payload, dict) or not payload.get("tag"):
                    print(f"  [WARN] skip payload without 'tag': {archive_name}")
                    continue
                db.upsert_tag(payload)

            restored += 1

    print(
        f"Restored {restored} tag payloads from {archive_path} into the database"
        f"{' (dry run)' if dry_run else ''}."
    )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Restore raw JSON files from assets/danbooru_latest_10000_raw_json.zip."
    )
    parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    parser.add_argument("--cache-dir", type=Path, default=CACHE_DIR)
    parser.add_argument("--asset-dir", type=Path, default=ASSET_DIR)
    parser.add_argument(
        "--cache-only",
        action="store_true",
        help="Restore only to .danbooru_cache, not assets/danbooru_completion.",
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    restore_archive(
        archive_path=args.archive,
        cache_dir=args.cache_dir,
        asset_dir=None if args.cache_only else args.asset_dir,
        dry_run=args.dry_run,
    )


if __name__ == "__main__":
    main()

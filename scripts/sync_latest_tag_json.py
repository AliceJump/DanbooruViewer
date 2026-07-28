#!/usr/bin/env python3
"""Force sync the newest Danbooru tags for the weekly raw JSON archive."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import view
from scripts.batch_sync_tags import (
    DO_NOT_RETRY_CACHE_PATH,
    FAILED_CACHE_PATH,
    SUCCESS_CACHE_PATH,
    TagRecord,
    create_session,
    fetch_tags_from_api_page,
    load_do_not_retry_cache,
    load_failed_cache,
    load_json_set,
    load_tag_cursor,
    metadata_lock,
    save_tag_cursor,
    sync_single_tag,
    update_cursor_boundary,
)


def build_sync_args(force: bool):
    return SimpleNamespace(
        force=force,
        max_age=0,
        all_from_api=True,
    )


def sync_record_with_retries(
    record: TagRecord,
    sync_args,
    metadata: dict,
    successful_tags: set[str],
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
    attempts: int,
    retry_delay: float,
) -> str:
    last_status = "failed"

    for attempt in range(1, attempts + 1):
        status, _ = sync_single_tag(
            record,
            sync_args,
            metadata,
            successful_tags,
            failed_tags,
            do_not_retry_tags,
        )
        last_status = status

        if status in {"synced", "skipped"}:
            return status

        if attempt >= attempts:
            break

        wait_time = retry_delay * attempt
        print(
            f"[TAG RETRY] {record.name} failed with status={status}; "
            f"retrying in {wait_time:.1f}s ({attempt}/{attempts})..."
        )
        time.sleep(wait_time)

    return last_status


def sync_latest_tags(
    limit: int,
    page_size: int,
    attempts: int,
    page_delay: float,
    retry_delay: float,
    force: bool,
) -> int:
    session = create_session()
    view.session = session

    metadata = view.load_sync_metadata()
    successful_tags = load_json_set(SUCCESS_CACHE_PATH)
    failed_tags = load_failed_cache(FAILED_CACHE_PATH)
    do_not_retry_tags = load_do_not_retry_cache(DO_NOT_RETRY_CACHE_PATH)
    api_cursor = load_tag_cursor()
    sync_args = build_sync_args(force)

    cursor_id: int | None = None
    synced = 0
    cursor_changed = False

    while synced < limit:
        records = fetch_tags_from_api_page(
            session,
            order="id_desc",
            cursor_id=cursor_id,
            limit=min(page_size, limit - synced),
            max_retries=attempts,
        )
        if not records:
            break

        for record in records:
            if synced >= limit:
                break

            status = sync_record_with_retries(
                record,
                sync_args,
                metadata,
                successful_tags,
                failed_tags,
                do_not_retry_tags,
                attempts=attempts,
                retry_delay=retry_delay,
            )

            if status not in {"synced", "skipped"}:
                raise SystemExit(
                    f"Failed to sync {record.name} after {attempts} attempts"
                )

            with metadata_lock:
                cursor_changed = (
                    update_cursor_boundary(api_cursor, record, "both")
                    or cursor_changed
                )

            synced += 1

        if cursor_changed:
            save_tag_cursor(api_cursor)
            cursor_changed = False

        ids = [record.tag_id for record in records if record.tag_id is not None]
        if not ids:
            break

        cursor_id = min(ids)
        time.sleep(page_delay)

    with metadata_lock:
        view.save_sync_metadata(metadata)

    if synced < limit:
        raise SystemExit(f"Only synced {synced}/{limit} latest tags")

    print(f"Synced latest {synced} tags.")
    return synced


def parse_args():
    parser = argparse.ArgumentParser(
        description="Force sync the newest Danbooru tags from current API order."
    )
    parser.add_argument("--limit", type=int, default=10000)
    parser.add_argument("--page-size", type=int, default=500)
    parser.add_argument("--attempts", type=int, default=5)
    parser.add_argument("--page-delay", type=float, default=2.0)
    parser.add_argument("--retry-delay", type=float, default=300.0)
    parser.add_argument(
        "--no-force",
        action="store_true",
        help="Do not force resync when local cache says the tag is fresh.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    sync_latest_tags(
        limit=args.limit,
        page_size=args.page_size,
        attempts=args.attempts,
        page_delay=args.page_delay,
        retry_delay=args.retry_delay,
        force=not args.no_force,
    )


if __name__ == "__main__":
    main()

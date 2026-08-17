#!/usr/bin/env python3
"""Backfill tag categories into the database without per-tag name searches.

Uses the Danbooru tags API grouped by category:
    GET /tags.json?search[category]=X&limit=1000&search[id_lt]=cursor

Every tag is enumerated once per category (0=general, 1=artist, 3=copyright,
4=character, 5=meta) and its (name, tag_id, category, post_count) is upserted
into the `tags` table. Existing completion data is preserved.

Usage:
    python scripts/sync_tag_categories.py                 # all categories
    python scripts/sync_tag_categories.py --categories 4  # only characters
    python scripts/sync_tag_categories.py --limit 5000    # cap total tags
"""

from __future__ import annotations

import argparse
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.tag_db import db

BASE = "https://danbooru.donmai.us"
CATEGORIES = [0, 1, 3, 4, 5]  # general, artist, copyright, character, meta
CATEGORY_NAMES = {0: "general", 1: "artist", 3: "copyright", 4: "character", 5: "meta"}
PAGE_SIZE = 1000  # Danbooru API hard limit (verified: limit=2000 still returns 1000)

request_semaphore = threading.Semaphore(3)  # max concurrent HTTP requests


def create_session(verify_ssl: bool = True) -> requests.Session:
    session = requests.Session()
    session.headers.update({"User-Agent": "DanbooruTagInspector/1.0"})
    session.verify = verify_ssl
    proxy = "http://127.0.0.1:10808"
    if proxy:
        session.proxies.update({"http": proxy, "https": proxy})
    return session


def fetch_page(
    session: requests.Session,
    category: int,
    cursor_id: int | None,
    max_retries: int = 5,
) -> list[dict]:
    params = {"search[category]": category, "limit": PAGE_SIZE}
    if cursor_id is not None:
        params["search[id_lt]"] = cursor_id

    for retry in range(max_retries):
        try:
            with request_semaphore:
                resp = session.get(f"{BASE}/tags.json", params=params, timeout=30)
            if resp.status_code == 429:
                wait = int(resp.headers.get("Retry-After", 0)) or 2 ** (retry + 1)
                print(f"[429] Rate limited. Sleeping {wait}s...")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            return resp.json()
        except requests.RequestException:
            if retry >= max_retries - 1:
                raise
            wait = 2 ** (retry + 1)
            print(f"[RETRY] category={category} cursor={cursor_id} in {wait}s...")
            time.sleep(wait)
    return []


def sync_category(
    session: requests.Session,
    category: int,
    delay: float,
    limit: int,
) -> int:
    cursor: int | None = None
    total = 0
    rows: list[tuple] = []

    def flush():
        nonlocal rows
        if rows:
            db.upsert_tag_categories(rows)
            rows = []

    while True:
        if limit > 0 and total >= limit:
            break
        tags = fetch_page(session, category, cursor)
        if not tags:
            break

        for tag in tags:
            name = tag.get("name")
            if not name:
                continue
            rows.append(
                (
                    name,
                    tag.get("id") if isinstance(tag.get("id"), int) else None,
                    tag.get("category") if isinstance(tag.get("category"), int) else category,
                    tag.get("post_count") if isinstance(tag.get("post_count"), int) else 0,
                )
            )
        total += len(tags)

        ids = [t.get("id") for t in tags if isinstance(t.get("id"), int)]
        if not ids:
            break
        cursor = min(ids)

        if len(rows) >= 5000:
            flush()

        if len(tags) < PAGE_SIZE:
            break
        time.sleep(delay)

    flush()
    return total


def main():
    parser = argparse.ArgumentParser(
        description="Backfill tag categories from the Danbooru tags API (grouped by category)."
    )
    parser.add_argument(
        "--categories",
        type=int,
        nargs="+",
        default=CATEGORIES,
        help="Categories to fetch (0=general, 1=artist, 3=copyright, 4=character, 5=meta). Default: all.",
    )
    parser.add_argument("--delay", type=float, default=0.2, help="Delay between pages (default 0.2s).")
    parser.add_argument("--limit", type=int, default=0, help="Cap total tags per category (0 = unlimited).")
    parser.add_argument("--workers", type=int, default=3, help="Max concurrent HTTP requests (default 3).")
    parser.add_argument("--no-verify-ssl", action="store_true", help="Disable SSL verification.")
    args = parser.parse_args()

    if args.no_verify_ssl:
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    session = create_session(not args.no_verify_ssl)
    grand_total = 0
    results = {}

    print(f"Fetching {len(args.categories)} categories with up to {args.workers} concurrent requests...")
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(sync_category, session, category, args.delay, args.limit): category
            for category in args.categories
        }
        for future in as_completed(futures):
            category = futures[future]
            name = CATEGORY_NAMES.get(category, str(category))
            try:
                count = future.result()
                results[category] = count
                grand_total += count
                print(f"  ✓ {name}: {count} tags")
            except Exception as exc:
                print(f"  ✗ {name} failed: {exc}")

    print(f"\nDone. Total tags upserted: {grand_total:,}")
    print(f"tags table now has {db.count_tags():,} rows.")


if __name__ == "__main__":
    main()
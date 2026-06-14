#!/usr/bin/env python3
"""
Danbooru 标签多维度信息抓取（同步 + 搜索补全版）

Python:
    3.12+

依赖:
    pip install requests
"""

from __future__ import annotations

from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from pprint import pprint
import argparse
import json
import time

import requests


BASE = "https://danbooru.donmai.us"
DEFAULT_TAG = "oguri_cap_(umamusume)"
POST_LIMIT = 50
CACHE_DIR = Path(__file__).resolve().parent / ".danbooru_cache"
ASSET_DIR = Path(__file__).resolve().parent / "assets" / "danbooru_completion"

session = requests.Session()
session.headers.update({"User-Agent": "DanbooruTagInspector/1.0"})


def get_json(path: str, **params):
    max_retries = params.pop("max_retries", 5)

    for retry in range(max_retries):
        response = session.get(
            f"{BASE}{path}",
            params=params,
            timeout=30,
        )

        if response.status_code == 429 and retry < max_retries - 1:
            retry_after = response.headers.get("Retry-After")
            wait_time = int(retry_after) if retry_after else 2 ** (retry + 1)
            print(f"[429] Rate limited. Sleeping {wait_time}s...")
            time.sleep(wait_time)
            continue

        response.raise_for_status()
        return response.json()

    raise RuntimeError("get_json failed")


def title(name: str):
    print()
    print("=" * 12, name, "=" * 12)


def top(counter: Counter, n=10):
    return counter.most_common(n)


def slugify_tag(tag: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in tag).strip("_")


def cache_path(tag: str) -> Path:
    return CACHE_DIR / f"{slugify_tag(tag)}.json"


def load_sync_data(tag: str):
    path = cache_path(tag)
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def save_sync_data(tag: str, payload: dict):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    ASSET_DIR.mkdir(parents=True, exist_ok=True)

    path = cache_path(tag)
    payload_text = json.dumps(payload, ensure_ascii=False, indent=2)
    path.write_text(payload_text, encoding="utf-8")

    asset_path = ASSET_DIR / f"{slugify_tag(tag)}.json"
    asset_path.write_text(payload_text, encoding="utf-8")

    return path


def get_sync_metadata_path() -> Path:
    """Get path to sync metadata file."""
    return CACHE_DIR / "sync_metadata.json"


def load_sync_metadata() -> dict:
    """Load sync metadata (timestamps, versions)."""
    path = get_sync_metadata_path()
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_sync_metadata(metadata: dict):
    """Save sync metadata."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = get_sync_metadata_path()
    path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")


def check_needs_sync(tag: str, max_age_hours: int = 24) -> bool:
    """Check if a tag needs to be re-synced.
    
    Args:
        tag: Tag name
        max_age_hours: Max age in hours before considering sync needed (default 24)
    
    Returns:
        True if tag doesn't exist locally or is too old
    """
    metadata = load_sync_metadata()
    tag_slug = slugify_tag(tag)
    
    # 检查本地资源是否存在
    asset_path = ASSET_DIR / f"{tag_slug}.json"
    if not asset_path.exists():
        return True
    
    # 检查同步时间戳
    if tag_slug not in metadata:
        return True
    
    last_sync_time = metadata[tag_slug].get("last_sync_time")
    if not last_sync_time:
        return True
    
    try:
        last_sync = datetime.fromisoformat(last_sync_time)
        age = datetime.now(timezone.utc) - last_sync.replace(tzinfo=timezone.utc)
        return age.total_seconds() > max_age_hours * 3600
    except Exception:
        return True


def incremental_sync(tags: list[str], max_age_hours: int = 24):
    """Incrementally sync tags (only sync if needed).
    
    Args:
        tags: List of tags to check/sync
        max_age_hours: Max age in hours before re-syncing
    
    Returns:
        (synced_count, total_count, errors)
    """
    metadata = load_sync_metadata()
    synced_count = 0
    errors = []
    
    for tag in tags:
        if not check_needs_sync(tag, max_age_hours):
            continue
        
        try:
            print(f"Syncing: {tag}")
            payload = sync_data(tag)
            
            # Update metadata
            tag_slug = slugify_tag(tag)
            metadata[tag_slug] = {
                "last_sync_time": datetime.now(timezone.utc).isoformat(),
                "version": 1,
                "tag": tag,
            }
            synced_count += 1
            print(f"  ✓ Synced")
            
        except Exception as exc:
            print(f"  ✗ Failed: {exc}")
            errors.append((tag, str(exc)))
    
    # Save updated metadata
    if synced_count > 0:
        save_sync_metadata(metadata)
    
    return synced_count, len(tags), errors


def build_completion_candidates(
    tag: str,
    tag_info: dict,
    wiki: dict | None,
    aliases: list[dict],
):
    candidates = []
    seen = set()

    def add_candidate(display_value: str, insert_value: str, source: str, score: int):
        normalized_display = display_value.strip()
        normalized_insert = insert_value.strip()
        if not normalized_display or not normalized_insert:
            return
        if normalized_display in seen:
            return
        seen.add(normalized_display)
        candidates.append(
            {
                "value": normalized_display,
                "insert_value": normalized_insert,
                "source": source,
                "score": score,
            }
        )

    add_candidate(tag, tag, "tag", 100)

    if wiki:
        for index, name in enumerate(wiki.get("other_names", []) or []):
            add_candidate(name, tag, "wiki_other_name", 90 - index)

    for index, alias in enumerate(aliases):
        add_candidate(alias.get("antecedent_name", ""), tag, "alias", 85 - index)

    return candidates


def sync_data(tag: str = DEFAULT_TAG):
    tags = get_json(
        "/tags.json",
        **{"search[name]": tag},
    )

    if not tags:
        raise RuntimeError("Tag not found")

    tag_info = tags[0]

    try:
        wiki = get_json(f"/wiki_pages/{tag}.json")
    except requests.HTTPError:
        wiki = None

    aliases = get_json(
        "/tag_aliases.json",
        **{
            "search[consequent_name]": tag,
            "limit": 10,
        },
    )

    implications = get_json(
        "/tag_implications.json",
        **{
            "search[antecedent_name]": tag,
            "limit": 10,
        },
    )

    posts = get_json(
        "/posts.json",
        tags=tag,
        limit=POST_LIMIT,
    )

    character_counter = Counter()
    general_counter = Counter()
    artist_counter = Counter()

    for post in posts:
        for candidate in post.get("tag_string_character", "").split():
            if candidate != tag:
                character_counter[candidate] += 1

        for candidate in post.get("tag_string_general", "").split():
            general_counter[candidate] += 1

        for candidate in post.get("tag_string_artist", "").split():
            artist_counter[candidate] += 1

    completion_candidates = build_completion_candidates(
        tag,
        tag_info,
        wiki,
        aliases,
    )

    # Minimal payload: only include fields needed for completion and identification
    payload = {
        "tag": tag,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "tag_info": {
            "id": tag_info["id"],
            "name": tag_info["name"],
            "category": tag_info["category"],
            "post_count": tag_info["post_count"],
        },
        # Keep only other_names from wiki (if present)
        "wiki": None if wiki is None else {"other_names": wiki.get("other_names") or []},
        # Aliases as simple strings (antecedent names)
        "aliases": [item.get("antecedent_name") for item in aliases[:5] if item.get("antecedent_name")],
        "completion_candidates": completion_candidates,
    }

    save_sync_data(tag, payload)
    return payload


def print_sync_report(payload: dict):
    title("TAG")
    pprint(payload.get("tag_info"))

    title("WIKI (other_names)")
    wiki = payload.get("wiki")
    if not wiki:
        print("Wiki not found or no other names")
    else:
        pprint(wiki.get("other_names"))

    title("ALIASES")
    pprint(payload.get("aliases", []))

    title("SEARCH COMPLETION (sample)")
    pprint(payload.get("completion_candidates", [])[:20])


def main(tag: str = DEFAULT_TAG):
    try:
        payload = sync_data(tag)
    except Exception as exc:
        cached = load_sync_data(tag)
        if cached is None:
            raise
        print(f"Sync failed, using cached data: {exc}")
        payload = cached

    print_sync_report(payload)


def parse_args():
    parser = argparse.ArgumentParser(description="Danbooru tag sync and search completion generator")
    parser.add_argument("--tag", default=DEFAULT_TAG, help="Tag to sync")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    main(args.tag)

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
import sys
import time

import requests

# Ensure print() output uses UTF-8 regardless of the console code page
# (Windows cmd often uses GBK, which breaks non-ASCII chars like ✓ / ✗).
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


BASE = "https://danbooru.donmai.us"
DEFAULT_TAG = "oguri_cap_(umamusume)"
POST_LIMIT = 50
CACHE_DIR = Path(__file__).resolve().parent / ".danbooru_cache"
ASSET_DIR = Path(__file__).resolve().parent / "assets" / "danbooru_completion"

session = requests.Session()
session.headers.update({"User-Agent": "DanbooruTagInspector/1.0"})

# File + console logging. All [REQ]/[TAG]/[OK] diagnostics go through log() so
# they appear on the terminal AND in crawl.log for later inspection.
import os as _os
_LOG_PATH = _os.environ.get(
    "DANBOORU_LOG",
    str(Path(__file__).resolve().parent / "crawl.log"),
)
_log_file = None


def _get_log_file():
    global _log_file
    if _log_file is None:
        try:
            _log_file = open(_LOG_PATH, "a", encoding="utf-8", buffering=1)
        except Exception:
            _log_file = None
    return _log_file


def log(msg: str = ""):
    print(msg, flush=True)
    lf = _get_log_file()
    if lf is not None:
        try:
            lf.write(msg + "\n")
            lf.flush()
        except Exception:
            pass


def log_to_file(msg: str):
    """Append to crawl.log only (no console output)."""
    lf = _get_log_file()
    if lf is not None:
        try:
            lf.write(msg + "\n")
            lf.flush()
        except Exception:
            pass


# Global request RATE limiter (tokens per second), not just concurrency.
# Danbooru starts returning 429 once sustained request rate exceeds ~8/s
# (measured). Keep a conservative cap well below that. All HTTP requests go
# through `rate_limiter.wait()` so the global rate stays bounded regardless of
# how many worker threads are running.
import threading as _threading
import time as _time


class _RateLimiter:
    """Serializes all HTTP requests globally with a rate cap.

    A single lock ensures only ONE request is in flight at a time (no bursts),
    and a spacing interval enforces the requests/second cap. This is what
    actually prevents Danbooru's 429 rate limiting under high worker counts.
    """

    def __init__(self, rate_per_sec):
        self.min_interval = 1.0 / rate_per_sec
        self._sema = _threading.Semaphore(1)  # one request in flight globally
        self._lock = _threading.Lock()
        self._next = 0.0

    def wait(self):
        self._sema.acquire()
        try:
            with self._lock:
                now = _time.monotonic()
                if now < self._next:
                    delay = self._next - now
                    self._next += self.min_interval
                else:
                    delay = 0.0
                    self._next = now + self.min_interval
            if delay > 0:
                _time.sleep(delay)
        except Exception:
            self._sema.release()
            raise
        return self

    def release(self):
        self._sema.release()

    # Support `with request_semaphore:` used by batch_sync_tags.safe_get.
    def __enter__(self):
        self.wait()
        return self

    def __exit__(self, *exc):
        self.release()
        return False


# Global request rate cap in requests/second.
request_limiter = _RateLimiter(7.0)
# Backwards-compat alias: any code that used request_semaphore now shares the
# same global limiter so concurrency AND rate are both bounded.
request_semaphore = request_limiter


def set_request_rate(rate_per_sec: float):
    """Adjust the global request rate cap (requests per second)."""
    global request_limiter, request_semaphore
    request_limiter = _RateLimiter(rate_per_sec)
    request_semaphore = request_limiter


def get_json(path: str, **params):
    max_retries = params.pop("max_retries", 5)

    for retry in range(max_retries):
        with request_limiter:
            t0 = _time.monotonic()
            try:
                response = session.get(
                    f"{BASE}{path}",
                    params=params,
                    timeout=30,
                )
            except Exception as exc:
                log(f"  [REQ] GET {path} -> EXC {type(exc).__name__} ({_time.monotonic()-t0:.2f}s)")
                if retry >= max_retries - 1:
                    raise
                wait = 2 ** (retry + 1)
                log(f"  [REQ] retry in {wait}s...")
                _time.sleep(wait)
                continue
            dt = _time.monotonic() - t0

            if response.status_code == 429 and retry < max_retries - 1:
                retry_after = response.headers.get("Retry-After")
                wait_time = int(retry_after) if retry_after else 2 ** (retry + 1)
                log(f"  [REQ] GET {path} -> 429 (retry {retry+1}/{max_retries}, sleep {wait_time}s, {dt:.2f}s)")
                time.sleep(wait_time)
                continue

            log(f"  [REQ] GET {path} -> {response.status_code} ({dt:.2f}s)")
            response.raise_for_status()
            content_type = response.headers.get("Content-Type", "")
            # Some endpoints (e.g. /wiki_pages/<tag>.json) return an HTML page
            # instead of JSON when the tag name contains special characters. Treat
            # that as an HTTP error so callers (sync_data) can fall back gracefully.
            if "application/json" not in content_type:
                raise requests.HTTPError(
                    f"Expected JSON, got {content_type or 'no content-type'} for {path}",
                    response=response,
                )
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


def compact_sync_payload(payload: dict) -> dict:
    candidates = payload.get("completion_candidates")
    if not isinstance(candidates, list):
        candidates = []

    return {
        "tag": payload.get("tag"),
        "updated_at": payload.get("updated_at"),
        "completion_candidates": candidates,
    }


def save_sync_data(tag: str, payload: dict):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    ASSET_DIR.mkdir(parents=True, exist_ok=True)

    path = cache_path(tag)
    payload_text = json.dumps(compact_sync_payload(payload), ensure_ascii=False, indent=2)
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
    log(f"  [TAG] syncing {tag!r}")
    tags = get_json(
        "/tags.json",
        **{"search[name]": tag},
    )

    if not tags:
        raise RuntimeError("Tag not found")

    tag_info = tags[0]
    log(f"  [TAG] id={tag_info.get('id')} category={tag_info.get('category')} posts={tag_info.get('post_count')}")

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


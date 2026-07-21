#!/usr/bin/env python3
"""Update wiki aliases for tags that have already been synced locally."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import threading
import time
from pathlib import Path
from urllib.parse import quote

import requests

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import view


CACHE_DIR = ROOT / ".danbooru_cache"
ASSET_DIR = ROOT / "assets" / "danbooru_completion"
WIKI_ENDPOINT = "https://danbooru.donmai.us/wiki_pages"
request_semaphore = threading.Semaphore(3)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Update wiki aliases for locally synced Danbooru tags"
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Maximum number of tags to process (default: all)",
    )
    parser.add_argument(
        "--min-id",
        type=int,
        default=0,
        help="Only process tags whose id is at least this value",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.2,
        help="Delay between requests in seconds (default: 0.2)",
    )
    parser.add_argument(
        "--retries",
        type=int,
        default=3,
        help="Maximum request attempts (default: 3)",
    )
    parser.add_argument(
        "--no-verify-ssl",
        action="store_true",
        help="Disable SSL certificate verification",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=3,
        help="Concurrent workers (default: 3; requests are globally capped at 3)",
    )
    return parser.parse_args()


def load_local_tags() -> list[tuple[int, Path, dict]]:
    tags = []
    paths = [path for path in CACHE_DIR.glob("*.json") if path.name != "sync_metadata.json"]
    print(f"Scanning {len(paths)} local cache file(s)...")
    for index, path in enumerate(paths, start=1):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            tag_info = payload.get("tag_info")
            tag_id = tag_info.get("id") if isinstance(tag_info, dict) else None
            tag_name = tag_info.get("name") if isinstance(tag_info, dict) else None
            if isinstance(tag_id, int) and tag_name:
                tags.append((tag_id, path, payload))
        except (OSError, json.JSONDecodeError, AttributeError):
            print(f"[SKIP] Invalid cache: {path.name}")

        if index % 10000 == 0 or index == len(paths):
            print(f"  Scanned {index}/{len(paths)} cache file(s)")

    return sorted(tags, key=lambda item: item[0], reverse=True)


def create_session(verify_ssl: bool) -> requests.Session:
    session = requests.Session()
    session.headers.update({"User-Agent": "DanbooruTagInspector/1.0"})
    session.verify = verify_ssl
    session.proxies.update(
        {
            "http": "http://127.0.0.1:10808",
            "https": "http://127.0.0.1:10808",
        }
    )
    return session


def safe_get(
    session: requests.Session,
    url: str,
    *,
    max_retries: int,
    **kwargs,
) -> requests.Response:
    for attempt in range(max_retries):
        try:
            with request_semaphore:
                response = session.get(url, **kwargs)

            if response.status_code == 404:
                return response

            if response.status_code == 429:
                retry_after = response.headers.get("Retry-After")
                try:
                    wait = int(retry_after) if retry_after else 2 ** (attempt + 1)
                except ValueError:
                    wait = 2 ** (attempt + 1)
                print(f"[429] Rate limited. Sleeping {wait}s...")
                time.sleep(wait)
                continue

            response.raise_for_status()
            return response
        except requests.RequestException:
            if attempt + 1 >= max_retries:
                raise
            wait = 2 ** (attempt + 1)
            print(f"[RETRY] {url} in {wait}s...")
            time.sleep(wait)

    raise RuntimeError(f"GET failed after {max_retries} attempts: {url}")


def verify_network(session: requests.Session, retries: int) -> bool:
    try:
        response = safe_get(
            session,
            "https://danbooru.donmai.us/tags.json",
            max_retries=retries,
            params={"limit": 1},
            timeout=15,
        )
        response.raise_for_status()
        print("[OK] Network verification succeeded.")
        return True
    except requests.exceptions.SSLError as exc:
        print(f"[SSL ERROR] {exc}")
    except Exception as exc:
        print(f"[NETWORK ERROR] {exc}")
    return False


def fetch_wiki(
    session: requests.Session,
    tag: str,
    retries: int,
) -> dict | None:
    url = f"{WIKI_ENDPOINT}/{quote(tag, safe='')}.json"
    response = safe_get(
        session,
        url,
        max_retries=retries,
        timeout=30,
    )
    if response.status_code == 404:
        return None
    data = response.json()
    return data if isinstance(data, dict) else None


def completion_aliases(payload: dict) -> list[dict]:
    aliases = payload.get("aliases", [])
    if not isinstance(aliases, list):
        return []
    return [
        {"antecedent_name": alias}
        if isinstance(alias, str)
        else alias
        for alias in aliases
        if isinstance(alias, (str, dict))
    ]


def update_payload(payload: dict, wiki: dict | None) -> dict:
    tag = payload["tag_info"]["name"]
    other_names = wiki.get("other_names") or [] if wiki else []
    payload["wiki"] = {"other_names": other_names}

    payload["completion_candidates"] = view.build_completion_candidates(
        tag,
        payload["tag_info"],
        payload["wiki"],
        completion_aliases(payload),
    )
    return payload


def atomic_write(path: Path, payload: dict):
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def save_payload(cache_path: Path, payload: dict):
    atomic_write(cache_path, payload)
    asset_path = ASSET_DIR / cache_path.name
    if asset_path.exists():
        atomic_write(asset_path, payload)


thread_local = threading.local()


def process_tag(item, args):
    tag_id, cache_path, payload = item
    session = getattr(thread_local, "session", None)
    if session is None:
        session = create_session(not args.no_verify_ssl)
        thread_local.session = session

    tag = payload["tag_info"]["name"]
    wiki = fetch_wiki(session, tag, args.retries)
    update_payload(payload, wiki)
    payload["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    save_payload(cache_path, payload)
    return tag_id, tag, len(payload["wiki"]["other_names"])


def main() -> int:
    args = parse_args()
    if args.limit < 0 or args.retries < 1 or args.delay < 0 or args.workers < 1:
        print("[ERROR] --limit, --delay and --workers must be non-negative; retries and workers must be positive")
        return 2

    if args.no_verify_ssl:
        import urllib3

        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    print("Initializing network session...")
    verification_session = create_session(not args.no_verify_ssl)
    if not verify_network(verification_session, args.retries):
        if args.no_verify_ssl:
            return 1

        print("[WARN] Network verification failed with SSL verification enabled.")
        print("[INFO] Retrying with SSL verification disabled...")
        args.no_verify_ssl = True
        import urllib3

        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
        verification_session = create_session(False)
        if not verify_network(verification_session, args.retries):
            return 1

    tags = [item for item in load_local_tags() if item[0] >= args.min_id]
    if args.limit:
        tags = tags[: args.limit]

    print(f"Found {len(tags)} locally synced tag(s), processing by id descending.")
    print(f"Starting up to {args.workers} wiki requests concurrently.")
    updated = 0
    failed = 0
    completed = 0

    # Submit in descending id order. A bounded in-flight window keeps the
    # highest ids prioritized without creating one Future per cache file.
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        pending = set()
        next_index = 0
        while next_index < len(tags) and len(pending) < args.workers:
            pending.add(executor.submit(process_tag, tags[next_index], args))
            next_index += 1

        while pending:
            done, pending = concurrent.futures.wait(
                pending,
                return_when=concurrent.futures.FIRST_COMPLETED,
            )
            for future in done:
                completed += 1
                try:
                    tag_id, tag, alias_count = future.result()
                    print(f"[{completed}/{len(tags)}] [OK] id={tag_id} {tag}: {alias_count} wiki alias(es)")
                    updated += 1
                except Exception as exc:
                    print(f"[{completed}/{len(tags)}] [FAIL] {exc}")
                    failed += 1

                if next_index < len(tags):
                    pending.add(executor.submit(process_tag, tags[next_index], args))
                    next_index += 1
                if args.delay:
                    time.sleep(args.delay)

    print(f"Updated: {updated}, failed: {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

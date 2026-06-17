#!/usr/bin/env python3
"""Batch sync multiple Danbooru tags for completion suggestions."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

import requests

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import view


# =========================================================
# Config
# =========================================================

DEFAULT_TAGS = [
    "oguri_cap_(umamusume)",
    "special_week_(umamusume)",
    "silence_suzuka_(umamusume)",
    "tamamo_cross_(umamusume)",
    "mejiro_mcqueen_(umamusume)",
    "tokai_teio_(umamusume)",
    "gold_ship_(umamusume)",
    "daiwa_scarlet_(umamusume)",
    "rice_shower_(umamusume)",
    "super_creek_(umamusume)",
]

metadata_lock = threading.Lock()

CACHE_DIR = ROOT / "cache"

SUCCESS_CACHE_PATH = (
    CACHE_DIR / "successful_tags.json"
)

FAILED_CACHE_PATH = (
    CACHE_DIR / "failed_tags.json"
)

CACHE_DIR.mkdir(
    parents=True,
    exist_ok=True,
)


# =========================================================
# Cache Utils
# =========================================================

def load_json_set(path: Path) -> set[str]:
    if not path.exists():
        return set()

    try:
        data = json.loads(
            path.read_text(encoding="utf-8")
        )

        if isinstance(data, list):
            return set(data)

    except Exception:
        pass

    return set()


def save_json_set(
    path: Path,
    values: set[str],
):
    payload = json.dumps(
        sorted(values),
        ensure_ascii=False,
        indent=2,
    )

    temp_path = path.with_name(
        f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp"
    )

    try:
        temp_path.write_text(
            payload,
            encoding="utf-8",
        )

        for attempt in range(6):
            try:
                temp_path.replace(path)
                return
            except PermissionError:
                if attempt == 5:
                    raise

                time.sleep(0.1 * (attempt + 1))
    finally:
        try:
            temp_path.unlink(missing_ok=True)
        except PermissionError:
            pass


# =========================================================
# Network
# =========================================================

request_semaphore = threading.Semaphore(3)


def create_session(
    verify_ssl: bool = True,
) -> requests.Session:
    session = requests.Session()

    session.headers.update(
        {
            "User-Agent": "DanbooruTagInspector/1.0",
        }
    )

    session.verify = verify_ssl
    proxies = {
        "http": "http://127.0.0.1:10808",
        "https": "http://127.0.0.1:10808",
    }

    session.proxies.update(proxies)
    return session


def safe_get(
    session: requests.Session,
    url: str,
    *,
    max_retries: int = 5,
    **kwargs,
):
    retry = 0

    while retry < max_retries:
        try:
            with request_semaphore:
                response = session.get(
                    url,
                    **kwargs,
                )

            if response.status_code == 429:
                retry_after = (
                    response.headers.get(
                        "Retry-After"
                    )
                )

                wait_time = (
                    int(retry_after)
                    if retry_after
                    else 2 ** (retry + 1)
                )

                print(
                    f"[429] Rate limited. "
                    f"Sleeping {wait_time}s..."
                )

                time.sleep(wait_time)

                retry += 1
                continue

            response.raise_for_status()

            return response

        except requests.exceptions.RequestException:
            retry += 1

            if retry >= max_retries:
                raise

            wait_time = 2 ** retry

            print(
                f"[RETRY] "
                f"{url} "
                f"in {wait_time}s..."
            )

            time.sleep(wait_time)

    raise RuntimeError("safe_get failed")


def verify_network(
    session: requests.Session,
) -> bool:
    try:
        response = safe_get(
            session,
            "https://danbooru.donmai.us/tags.json",
            params={"limit": 1},
            timeout=15,
        )

        response.raise_for_status()

        print(
            "[OK] Network verification succeeded."
        )

        return True

    except requests.exceptions.SSLError as exc:
        print(f"[SSL ERROR] {exc}")
        return False

    except Exception as exc:
        print(f"[NETWORK ERROR] {exc}")
        return False


# =========================================================
# Tag Iterator
# =========================================================

def iter_all_tags_from_api(
    limit: int = 500,
    verify_ssl: bool = True,
    max_retries: int = 3,
    delay: float = 0.2,
) -> Iterator[str]:
    """
    Stream all Danbooru tags using cursor pagination.
    """

    limit = min(limit, 1000)

    session = create_session(verify_ssl)

    if not verify_ssl:
        import urllib3

        urllib3.disable_warnings(
            urllib3.exceptions.InsecureRequestWarning
        )

    last_id: int | None = None
    total = 0

    while True:
        params = {
            "limit": limit,
            "search[order]": "id_desc",
        }

        if last_id is not None:
            params["search[id_lt]"] = last_id

        retry = 0

        while retry < max_retries:
            try:
                print(
                    f"Fetching batch "
                    f"(last_id={last_id}, total={total})..."
                )

                response = safe_get(
                    session,
                    "https://danbooru.donmai.us/tags.json",
                    params=params,
                    timeout=30,
                )

                tags = response.json()

                if not tags:
                    print("No more tags.")
                    return

                ids = []

                for tag in tags:
                    tag_id = tag.get("id")
                    tag_name = tag.get("name")

                    if tag_id is not None:
                        ids.append(tag_id)

                    if tag_name:
                        total += 1
                        yield tag_name

                if not ids:
                    return

                last_id = min(ids)

                print(
                    f"Got {len(tags)} tags "
                    f"(total streamed: {total})"
                )

                time.sleep(delay)

                break

            except requests.exceptions.RequestException as exc:
                retry += 1

                if retry < max_retries:
                    wait_time = 2 ** retry

                    print(
                        f"Retry "
                        f"{retry}/{max_retries} "
                        f"after {wait_time}s: {exc}"
                    )

                    time.sleep(wait_time)

                else:
                    print(
                        f"Error after "
                        f"{max_retries} retries: {exc}"
                    )
                    return


# =========================================================
# Args
# =========================================================

def parse_args():
    parser = argparse.ArgumentParser(
        description="Batch sync multiple Danbooru tags"
    )

    parser.add_argument(
        "--tags",
        nargs="+",
        help="Tags to sync",
    )

    parser.add_argument(
        "--file",
        type=Path,
        help="File with one tag per line",
    )

    parser.add_argument(
        "--default",
        action="store_true",
        help="Use default preset tags",
    )

    parser.add_argument(
        "--all-from-api",
        action="store_true",
        help="Fetch all tags from API",
    )

    parser.add_argument(
        "--retry-failed",
        action="store_true",
        help="Retry only failed tags",
    )

    parser.add_argument(
        "--api-limit",
        type=int,
        default=500,
        help="Tags per API request",
    )

    parser.add_argument(
        "--no-verify-ssl",
        action="store_true",
        help="Disable SSL verification",
    )

    parser.add_argument(
        "--retries",
        type=int,
        default=3,
        help="Max retries",
    )

    parser.add_argument(
        "--delay",
        type=float,
        default=0.2,
        help="Delay between API requests",
    )

    parser.add_argument(
        "--force",
        action="store_true",
        help="Force resync",
    )

    parser.add_argument(
        "--max-age",
        type=int,
        default=24,
        help="Max cache age",
    )

    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Maximum processed tags",
    )

    parser.add_argument(
        "--workers",
        type=int,
        default=3,
        help="Concurrent workers",
    )

    return parser.parse_args()


# =========================================================
# Tag Sources
# =========================================================

def load_tags_from_file(
    path: Path,
) -> list[str]:
    return [
        line.strip()
        for line in path.read_text(
            encoding="utf-8"
        ).splitlines()
        if line.strip()
    ]


def get_tags_iterator(args):
    if args.retry_failed:
        print("Retrying failed tags...")

        failed_tags = load_json_set(
            FAILED_CACHE_PATH
        )

        return iter(sorted(failed_tags))

    if args.tags:
        return iter(args.tags)

    if args.file:
        return iter(
            load_tags_from_file(args.file)
        )

    if args.default:
        return iter(DEFAULT_TAGS)

    if args.all_from_api:
        print(
            "Fetching all tags from Danbooru API..."
        )

        return iter_all_tags_from_api(
            limit=args.api_limit,
            verify_ssl=(
                not args.no_verify_ssl
            ),
            max_retries=args.retries,
            delay=args.delay,
        )

    return iter([view.DEFAULT_TAG])


# =========================================================
# Worker
# =========================================================

def sync_single_tag(
    tag: str,
    args,
    metadata: dict,
    successful_tags: set[str],
    failed_tags: set[str],
) -> tuple[str, str]:
    try:
        if (
            tag in successful_tags and
            not args.force
        ):
            print(f"[CACHE SKIP] {tag}")
            return ("skipped", tag)

        if not args.force:
            try:
                needs = (
                    view.check_needs_sync(
                        tag,
                        max_age_hours=args.max_age,
                        metadata=metadata,
                    )
                )

            except TypeError:
                needs = (
                    view.check_needs_sync(
                        tag,
                        max_age_hours=args.max_age,
                    )
                )

            if not needs:
                print(f"[SKIP] {tag}")

                with metadata_lock:
                    successful_tags.add(tag)

                return ("skipped", tag)

        print(f"[SYNC] {tag}")

        view.sync_data(tag)

        asset_path = (
            view.ASSET_DIR /
            f"{view.slugify_tag(tag)}.json"
        )

        print(f"  ✓ {asset_path}")

        tag_slug = view.slugify_tag(tag)

        with metadata_lock:
            metadata[tag_slug] = {
                "last_sync_time": datetime.now(
                    timezone.utc
                ).isoformat(),
                "version": metadata.get(
                    tag_slug,
                    {},
                ).get("version", 1),
                "tag": tag,
            }

            successful_tags.add(tag)

            if tag in failed_tags:
                failed_tags.remove(tag)

            save_json_set(
                SUCCESS_CACHE_PATH,
                successful_tags,
            )

            save_json_set(
                FAILED_CACHE_PATH,
                failed_tags,
            )

        return ("synced", tag)

    except Exception as exc:
        with metadata_lock:
            failed_tags.add(tag)

            save_json_set(
                FAILED_CACHE_PATH,
                failed_tags,
            )

        print(f"[FAIL] {tag}: {exc}")

        return ("failed", tag)


# =========================================================
# Main
# =========================================================

def main():
    args = parse_args()

    verify_ssl = (
        not args.no_verify_ssl
    )

    print("Initializing network session...")

    session = create_session(
        verify_ssl
    )

    if not verify_network(session):
        if verify_ssl:
            print(
                "[WARN] SSL verification failed."
            )

            print(
                "[INFO] Retrying with SSL disabled..."
            )

            session = create_session(False)

            if not verify_network(session):
                sys.exit(1)

            args.no_verify_ssl = True

        else:
            sys.exit(1)

    view.session = session

    print()
    print("Loading metadata...")

    try:
        metadata = (
            view.load_sync_metadata()
        )

    except Exception as exc:
        print(
            f"[WARN] Failed to load "
            f"metadata: {exc}"
        )

        metadata = {}

    print()
    print("Loading success cache...")

    successful_tags = load_json_set(
        SUCCESS_CACHE_PATH
    )

    print(
        f"Loaded "
        f"{len(successful_tags)} "
        f"successful tags"
    )

    print()
    print("Loading failed cache...")

    failed_tags = load_json_set(
        FAILED_CACHE_PATH
    )

    print(
        f"Loaded "
        f"{len(failed_tags)} "
        f"failed tags"
    )

    tags = get_tags_iterator(args)

    synced = 0
    skipped = 0
    failed = 0
    processed = 0

    print()
    print("Configuration:")
    print(
        f"  all_from_api : "
        f"{args.all_from_api}"
    )
    print(
        f"  retry_failed : "
        f"{args.retry_failed}"
    )
    print(
        f"  workers       : "
        f"{args.workers}"
    )
    print(
        f"  limit         : "
        f"{args.limit}"
    )
    print(
        f"  force         : "
        f"{args.force}"
    )
    print()

    print(
        f"Starting sync "
        f"(workers={args.workers})..."
    )

    futures = set()

    try:
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=args.workers
        ) as executor:

            for tag in tags:
                if (
                    args.limit > 0 and
                    processed >= args.limit
                ):
                    print(
                        "Reached processing limit."
                    )
                    break

                future = executor.submit(
                    sync_single_tag,
                    tag,
                    args,
                    metadata,
                    successful_tags,
                    failed_tags,
                )

                futures.add(future)

                processed += 1

                if (
                    len(futures) >=
                    args.workers * 4
                ):
                    done, futures = (
                        concurrent.futures.wait(
                            futures,
                            return_when=(
                                concurrent.futures
                                .FIRST_COMPLETED
                            ),
                        )
                    )

                    for future in done:
                        status, _ = future.result()

                        if status == "synced":
                            synced += 1
                        elif status == "skipped":
                            skipped += 1
                        else:
                            failed += 1

            for future in (
                concurrent.futures.as_completed(
                    futures
                )
            ):
                status, _ = future.result()

                if status == "synced":
                    synced += 1
                elif status == "skipped":
                    skipped += 1
                else:
                    failed += 1

    except KeyboardInterrupt:
        print()
        print("Interrupted by user.")

    print()
    print("Saving metadata...")

    try:
        with metadata_lock:
            view.save_sync_metadata(
                metadata
            )

    except Exception as exc:
        print(
            f"[WARN] Failed to save "
            f"metadata: {exc}"
        )

    print()
    print("=" * 60)
    print("Summary")
    print("=" * 60)

    print(f"Processed : {processed}")
    print(f"Synced    : {synced}")
    print(f"Skipped   : {skipped}")
    print(f"Failed    : {failed}")

    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()

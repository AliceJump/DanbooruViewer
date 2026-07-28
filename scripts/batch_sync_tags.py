#!/usr/bin/env python3
"""Batch sync multiple Danbooru tags for completion suggestions."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, NamedTuple

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

DO_NOT_RETRY_CACHE_PATH = (
    CACHE_DIR / "do_not_retry_tags.json"
)

TAG_CURSOR_PATH = (
    CACHE_DIR / "tag_api_cursor.json"
)

MAX_FAILED_ATTEMPTS = 5
MAX_TAG_NAME_LENGTH = 200
INVALID_TAG_CHARACTERS = frozenset({
    "?",
    "#",
    "/",
    "\\",
    "<",
    ">",
    '"',
    "`",
    ";",
    "+",
    "&",
    "=",
    "%",
})
INVALID_TAG_TRANSLATION = str.maketrans(
    {character: "_" for character in INVALID_TAG_CHARACTERS}
)
INVALID_TAG_PREFIXES = (
    "http://",
    "https://",
    "pools:",
)
INVALID_TAG_REASON = "非法字符"
SEARCH_METATAG_PATTERN = re.compile(r"^[a-z_]+:\S+$")

CACHE_DIR.mkdir(
    parents=True,
    exist_ok=True,
)


class TagRecord(NamedTuple):
    name: str
    tag_id: int | None = None


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

    _atomic_write(path, payload)


def normalize_failed_entry(entry) -> dict:
    if isinstance(entry, dict):
        failures = entry.get("failures")

        return {
            "reason": str(entry.get("reason", "unknown")),
            "failures": failures if isinstance(failures, int) else 1,
            "last_failed_at": entry.get("last_failed_at"),
        }

    return {
        "reason": str(entry),
        "failures": 1,
        "last_failed_at": None,
    }


def load_failed_cache(path: Path) -> dict[str, dict]:
    """加载失败缓存，返回 {tag: {reason, failures, last_failed_at}} 字典。

    兼容旧版数组和 {tag: reason} 字典格式。
    """
    if not path.exists():
        return {}

    try:
        data = json.loads(
            path.read_text(encoding="utf-8")
        )

        if isinstance(data, dict):
            return {
                tag: normalize_failed_entry(entry)
                for tag, entry in data.items()
            }

        # 旧版数组格式 → 升级为字典
        if isinstance(data, list):
            upgraded = {
                tag: normalize_failed_entry("unknown")
                for tag in data
            }
            save_failed_cache(path, upgraded)
            return upgraded

    except Exception:
        pass

    return {}


def save_failed_cache(
    path: Path,
    values: dict[str, dict],
):
    """保存失败缓存。"""
    payload = json.dumps(
        dict(sorted(values.items())),
        ensure_ascii=False,
        indent=2,
    )

    _atomic_write(path, payload)


def load_do_not_retry_cache(path: Path = DO_NOT_RETRY_CACHE_PATH) -> dict[str, dict]:
    if not path.exists():
        return {}

    try:
        data = json.loads(
            path.read_text(encoding="utf-8")
        )

        if isinstance(data, dict):
            return {
                tag: normalize_failed_entry(entry)
                for tag, entry in data.items()
            }
    except Exception:
        pass

    return {}


def save_do_not_retry_cache(
    path: Path,
    values: dict[str, dict],
):
    payload = json.dumps(
        dict(sorted(values.items())),
        ensure_ascii=False,
        indent=2,
    )

    _atomic_write(path, payload)


def quarantine_exhausted_failures(
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
) -> int:
    moved = 0

    for tag, entry in list(failed_tags.items()):
        failures = entry.get("failures", 1)

        if isinstance(failures, int) and failures >= MAX_FAILED_ATTEMPTS:
            do_not_retry_tags[tag] = entry
            failed_tags.pop(tag, None)
            moved += 1

    return moved


def has_invalid_tag_characters(tag: str) -> bool:
    if not tag or tag.strip() != tag:
        return True

    if len(tag) > MAX_TAG_NAME_LENGTH:
        return True

    if tag.translate(INVALID_TAG_TRANSLATION) != tag:
        return True

    if any(character.isspace() for character in tag):
        return True

    normalized = tag.lower()

    if normalized.startswith(INVALID_TAG_PREFIXES):
        return True

    if "://" in normalized or ".." in normalized:
        return True

    if SEARCH_METATAG_PATTERN.match(normalized):
        return True

    return False


def quarantine_invalid_failed_tags(
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
) -> int:
    moved = 0
    now = datetime.now(timezone.utc).isoformat()

    for tag in list(failed_tags.keys()):
        if not has_invalid_tag_characters(tag):
            continue

        do_not_retry_tags[tag] = {
            "reason": INVALID_TAG_REASON,
            "failures": MAX_FAILED_ATTEMPTS,
            "last_failed_at": now,
        }
        failed_tags.pop(tag, None)
        moved += 1

    return moved


def record_do_not_retry_tag(
    tag: str,
    reason: str,
    do_not_retry_tags: dict[str, dict],
):
    do_not_retry_tags[tag] = {
        "reason": reason,
        "failures": MAX_FAILED_ATTEMPTS,
        "last_failed_at": datetime.now(timezone.utc).isoformat(),
    }


def record_failed_tag(
    tag: str,
    reason: str,
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
):
    existing_entry = failed_tags.get(tag)
    entry = (
        normalize_failed_entry(existing_entry)
        if existing_entry is not None
        else {
            "reason": "unknown",
            "failures": 0,
            "last_failed_at": None,
        }
    )
    entry["reason"] = reason
    entry["failures"] = entry.get("failures", 0) + 1
    entry["last_failed_at"] = datetime.now(timezone.utc).isoformat()

    if entry["failures"] >= MAX_FAILED_ATTEMPTS:
        failed_tags.pop(tag, None)
        do_not_retry_tags[tag] = entry
        save_do_not_retry_cache(
            DO_NOT_RETRY_CACHE_PATH,
            do_not_retry_tags,
        )
    else:
        failed_tags[tag] = entry

    save_failed_cache(
        FAILED_CACHE_PATH,
        failed_tags,
    )


def load_tag_cursor(path: Path | None = None) -> dict:
    path = path or TAG_CURSOR_PATH

    if not path.exists():
        return {}

    try:
        data = json.loads(
            path.read_text(encoding="utf-8")
        )
    except Exception:
        return {}

    if not isinstance(data, dict):
        return {}

    min_id = data.get("min_id")
    max_id = data.get("max_id")

    return {
        "min_id": min_id if isinstance(min_id, int) else None,
        "max_id": max_id if isinstance(max_id, int) else None,
        "updated_at": data.get("updated_at"),
    }


def save_tag_cursor(cursor: dict, path: Path | None = None):
    path = path or TAG_CURSOR_PATH

    min_id = cursor.get("min_id")
    max_id = cursor.get("max_id")

    if not isinstance(min_id, int) or not isinstance(max_id, int):
        return

    payload = json.dumps(
        {
            "min_id": min_id,
            "max_id": max_id,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        },
        ensure_ascii=False,
        indent=2,
    )

    _atomic_write(path, payload)


def _atomic_write(path: Path, payload: str):
    """原子写入文件（写入临时文件后 rename）。"""
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

    proxy = os.environ.get("DANBOORU_PROXY")
    if proxy is None and os.environ.get("GITHUB_ACTIONS") != "true":
        proxy = "http://127.0.0.1:10808"

    if proxy:
        session.proxies.update(
            {
                "http": proxy,
                "https": proxy,
            }
        )

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

def iter_tags_from_api_range(
    *,
    order: str,
    id_gt: int | None = None,
    id_lt: int | None = None,
    limit: int = 500,
    verify_ssl: bool = True,
    max_retries: int = 3,
    delay: float = 0.2,
) -> Iterator[TagRecord]:
    """
    Stream Danbooru tags with cursor pagination.
    """
    limit = min(limit, 1000)
    session = create_session(verify_ssl)

    if not verify_ssl:
        import urllib3

        urllib3.disable_warnings(
            urllib3.exceptions.InsecureRequestWarning
        )

    cursor_id: int | None = id_lt if order == "id_desc" else id_gt
    total = 0

    while True:
        retry = 0

        while retry < max_retries:
            try:
                records = fetch_tags_from_api_page(
                    session,
                    order=order,
                    cursor_id=cursor_id,
                    id_gt=id_gt,
                    id_lt=id_lt,
                    limit=limit,
                )

                if not records:
                    print("No more tags.")
                    return

                ids = [
                    record.tag_id
                    for record in records
                    if record.tag_id is not None
                ]

                for record in records:
                    total += 1
                    yield record

                if not ids:
                    return

                cursor_id = min(ids) if order == "id_desc" else max(ids)

                print(
                    f"Got {len(records)} tags "
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


def fetch_tags_from_api_page(
    session: requests.Session,
    *,
    order: str,
    cursor_id: int | None = None,
    id_gt: int | None = None,
    id_lt: int | None = None,
    limit: int = 500,
    max_retries: int = 5,
) -> list[TagRecord]:
    limit = min(limit, 1000)

    params = {
        "limit": limit,
        "search[order]": order,
    }

    if order == "id_desc":
        if cursor_id is not None:
            params["search[id_lt]"] = cursor_id
        elif id_lt is not None:
            params["search[id_lt]"] = id_lt

        if id_gt is not None:
            params["search[id_gt]"] = id_gt
    else:
        if cursor_id is not None:
            params["search[id_gt]"] = cursor_id
        elif id_gt is not None:
            params["search[id_gt]"] = id_gt

        if id_lt is not None:
            params["search[id_lt]"] = id_lt

    print(
        f"Fetching batch "
        f"(order={order}, cursor_id={cursor_id}, "
        f"id_gt={id_gt}, id_lt={id_lt})..."
    )

    response = safe_get(
        session,
        "https://danbooru.donmai.us/tags.json",
        max_retries=max_retries,
        params=params,
        timeout=30,
    )

    tags = response.json()
    records: list[TagRecord] = []

    for tag in tags:
        tag_id = tag.get("id")
        tag_name = tag.get("name")

        if tag_name:
            records.append(
                TagRecord(
                    tag_name,
                    tag_id if isinstance(tag_id, int) else None,
                )
            )

    print(f"Got {len(records)} tags in current batch")

    return records


def iter_all_tags_from_api(
    limit: int = 500,
    verify_ssl: bool = True,
    max_retries: int = 3,
    delay: float = 0.2,
) -> Iterator[TagRecord]:
    return iter_tags_from_api_range(
        order="id_desc",
        limit=limit,
        verify_ssl=verify_ssl,
        max_retries=max_retries,
        delay=delay,
    )


def iter_incremental_tags_from_api(
    cursor: dict,
    limit: int = 500,
    verify_ssl: bool = True,
    max_retries: int = 3,
    delay: float = 0.2,
) -> Iterator[TagRecord]:
    min_id = cursor.get("min_id")
    max_id = cursor.get("max_id")

    if not isinstance(min_id, int) or not isinstance(max_id, int):
        print("No API cursor found. Fetching full tag range...")
        yield from iter_all_tags_from_api(
            limit=limit,
            verify_ssl=verify_ssl,
            max_retries=max_retries,
            delay=delay,
        )
        return

    print(f"Fetching new tags with id > {max_id}...")
    yield from iter_tags_from_api_range(
        order="id_asc",
        id_gt=max_id,
        limit=limit,
        verify_ssl=verify_ssl,
        max_retries=max_retries,
        delay=delay,
    )

    print(f"Fetching older tags with id < {min_id}...")
    yield from iter_tags_from_api_range(
        order="id_desc",
        id_lt=min_id,
        limit=limit,
        verify_ssl=verify_ssl,
        max_retries=max_retries,
        delay=delay,
    )


def iter_failed_then_api_tags(
    api_cursor: dict,
    *,
    limit: int = 500,
    verify_ssl: bool = True,
    max_retries: int = 3,
    delay: float = 0.2,
) -> Iterator[TagRecord]:
    seen: set[str] = set()
    failed_tags = load_failed_cache(FAILED_CACHE_PATH)
    do_not_retry_tags = load_do_not_retry_cache(DO_NOT_RETRY_CACHE_PATH)
    invalid_failures = quarantine_invalid_failed_tags(
        failed_tags,
        do_not_retry_tags,
    )
    quarantine_exhausted_failures(
        failed_tags,
        do_not_retry_tags,
    )
    if invalid_failures:
        save_failed_cache(
            FAILED_CACHE_PATH,
            failed_tags,
        )
        save_do_not_retry_cache(
            DO_NOT_RETRY_CACHE_PATH,
            do_not_retry_tags,
        )
        print(
            f"Moved {invalid_failures} failed tags "
            f"with invalid characters to do-not-retry cache"
        )

    if failed_tags:
        print(f"Retrying {len(failed_tags)} failed tags first...")

    for tag in sorted(failed_tags.keys()):
        if tag in do_not_retry_tags:
            continue

        seen.add(tag)
        yield TagRecord(tag)

    for record in iter_incremental_tags_from_api(
        api_cursor,
        limit=limit,
        verify_ssl=verify_ssl,
        max_retries=max_retries,
        delay=delay,
    ):
        if record.name in seen:
            continue

        seen.add(record.name)
        yield record


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
        help="Fetch tags from API. Uses saved min/max id cursor unless --reset-api-cursor is set.",
    )

    parser.add_argument(
        "--reset-api-cursor",
        action="store_true",
        help="Ignore saved API min/max id cursor and fetch the full tag range.",
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


def get_tags_iterator(args, api_cursor: dict | None = None):
    if args.retry_failed:
        print("Retrying failed tags...")

        failed_tags = load_failed_cache(
            FAILED_CACHE_PATH
        )
        do_not_retry_tags = load_do_not_retry_cache(
            DO_NOT_RETRY_CACHE_PATH
        )
        invalid_failures = quarantine_invalid_failed_tags(
            failed_tags,
            do_not_retry_tags,
        )
        moved_failures = quarantine_exhausted_failures(
            failed_tags,
            do_not_retry_tags,
        )

        if invalid_failures or moved_failures:
            save_failed_cache(
                FAILED_CACHE_PATH,
                failed_tags,
            )
            save_do_not_retry_cache(
                DO_NOT_RETRY_CACHE_PATH,
                do_not_retry_tags,
            )

        if invalid_failures:
            print(
                f"Moved {invalid_failures} failed tags "
                f"with invalid characters to do-not-retry cache"
            )

        return iter(
            TagRecord(tag)
            for tag in sorted(failed_tags.keys())
            if tag not in do_not_retry_tags
        )

    if args.tags:
        return iter(TagRecord(tag) for tag in args.tags)

    if args.file:
        return iter(
            TagRecord(tag)
            for tag in load_tags_from_file(args.file)
        )

    if args.default:
        return iter(TagRecord(tag) for tag in DEFAULT_TAGS)

    if args.all_from_api:
        print(
            "Fetching all tags from Danbooru API..."
        )
        return iter(())

    return iter([TagRecord(view.DEFAULT_TAG)])


# =========================================================
# Worker
# =========================================================

def sync_single_tag(
    record: TagRecord,
    args,
    metadata: dict,
    successful_tags: set[str],
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
) -> tuple[str, TagRecord]:
    tag = record.name

    try:
        if (
            tag in successful_tags and
            not args.force
        ):
            print(f"[CACHE SKIP] {tag}")
            return ("skipped", record)

        if has_invalid_tag_characters(tag):
            print(f"[INVALID TAG] {tag}: {INVALID_TAG_REASON}")

            with metadata_lock:
                removed_failed = failed_tags.pop(tag, None) is not None
                record_do_not_retry_tag(
                    tag,
                    INVALID_TAG_REASON,
                    do_not_retry_tags,
                )

                if removed_failed:
                    save_failed_cache(
                        FAILED_CACHE_PATH,
                        failed_tags,
                    )

                save_do_not_retry_cache(
                    DO_NOT_RETRY_CACHE_PATH,
                    do_not_retry_tags,
                )

            return ("blocked", record)

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
                    added_success = tag not in successful_tags
                    successful_tags.add(tag)
                    removed_failed = failed_tags.pop(tag, None) is not None
                    removed_blocked = do_not_retry_tags.pop(tag, None) is not None

                    if added_success:
                        save_json_set(
                            SUCCESS_CACHE_PATH,
                            successful_tags,
                        )

                    if removed_failed:
                        save_failed_cache(
                            FAILED_CACHE_PATH,
                            failed_tags,
                        )

                    if removed_blocked:
                        save_do_not_retry_cache(
                            DO_NOT_RETRY_CACHE_PATH,
                            do_not_retry_tags,
                        )

                return ("skipped", record)

        if tag in do_not_retry_tags:
            print(f"[DO NOT RETRY] {tag}")
            return ("blocked", record)

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

            failed_tags.pop(tag, None)
            do_not_retry_tags.pop(tag, None)

            save_json_set(
                SUCCESS_CACHE_PATH,
                successful_tags,
            )

            save_failed_cache(
                FAILED_CACHE_PATH,
                failed_tags,
            )

            save_do_not_retry_cache(
                DO_NOT_RETRY_CACHE_PATH,
                do_not_retry_tags,
            )

        return ("synced", record)

    except Exception as exc:
        with metadata_lock:
            record_failed_tag(
                tag,
                str(exc),
                failed_tags,
                do_not_retry_tags,
            )

        print(f"[FAIL] {tag}: {exc}")

        return ("failed", record)


def update_cursor_from_record(cursor: dict, record: TagRecord):
    if record.tag_id is None:
        return False

    current_min = cursor.get("min_id")
    current_max = cursor.get("max_id")

    if not isinstance(current_min, int) or record.tag_id < current_min:
        cursor["min_id"] = record.tag_id

    if not isinstance(current_max, int) or record.tag_id > current_max:
        cursor["max_id"] = record.tag_id

    return True


def count_completed_future(
    future,
    args,
    api_cursor: dict,
) -> str:
    status, record = future.result()

    if (
        args.all_from_api and
        should_advance_api_cursor(status) and
        update_cursor_from_record(api_cursor, record)
    ):
        save_tag_cursor(api_cursor)

    return status


def count_status(
    status: str,
    counts: dict[str, int],
):
    if status == "synced":
        counts["synced"] += 1
    elif status == "skipped":
        counts["skipped"] += 1
    elif status == "blocked":
        counts["blocked"] += 1
    else:
        counts["failed"] += 1


def should_advance_api_cursor(status: str) -> bool:
    return status in {"synced", "skipped", "blocked"}


def update_cursor_boundary(
    cursor: dict,
    record: TagRecord,
    mode: str,
) -> bool:
    if record.tag_id is None:
        return False

    if mode == "max":
        current_max = cursor.get("max_id")

        if not isinstance(current_max, int) or record.tag_id > current_max:
            cursor["max_id"] = record.tag_id
            return True

    if mode == "min":
        current_min = cursor.get("min_id")

        if not isinstance(current_min, int) or record.tag_id < current_min:
            cursor["min_id"] = record.tag_id
            return True

    if mode == "both":
        return update_cursor_from_record(cursor, record)

    return False


def process_api_record(
    record: TagRecord,
    args,
    metadata: dict,
    successful_tags: set[str],
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
    api_cursor: dict,
    counts: dict[str, int],
    advance_cursor: bool = True,
    cursor_mode: str = "both",
) -> tuple[str, bool]:
    status, synced_record = sync_single_tag(
        record,
        args,
        metadata,
        successful_tags,
        failed_tags,
        do_not_retry_tags,
    )

    counts["processed"] += 1
    count_status(status, counts)

    cursor_changed = False

    if advance_cursor and should_advance_api_cursor(status):
        with metadata_lock:
            cursor_changed = update_cursor_boundary(
                api_cursor,
                synced_record,
                cursor_mode,
            )

    return status, cursor_changed


def process_failed_tags_first(
    args,
    metadata: dict,
    successful_tags: set[str],
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
    api_cursor: dict,
    counts: dict[str, int],
):
    retry_tags = [
        tag
        for tag in sorted(failed_tags.keys())
        if tag not in do_not_retry_tags
    ]

    if retry_tags:
        print(f"Retrying {len(retry_tags)} failed tags first...")

    for tag in retry_tags:
        if (
            args.limit > 0 and
            counts["processed"] >= args.limit
        ):
            print("Reached processing limit.")
            return

        process_api_record(
            TagRecord(tag),
            args,
            metadata,
            successful_tags,
            failed_tags,
            do_not_retry_tags,
            api_cursor,
            counts,
            advance_cursor=False,
        )


def process_api_page(
    records: list[TagRecord],
    args,
    metadata: dict,
    successful_tags: set[str],
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
    api_cursor: dict,
    counts: dict[str, int],
    cursor_mode: str,
) -> tuple[bool, int | None]:
    if args.limit > 0:
        remaining = args.limit - counts["processed"]
        if remaining <= 0:
            print("Reached processing limit.")
            return False, None

        records = records[:remaining]

    if not records:
        return False, None

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=args.workers
    ) as executor:
        futures = [
            executor.submit(
                sync_single_tag,
                record,
                args,
                metadata,
                successful_tags,
                failed_tags,
                do_not_retry_tags,
            )
            for record in records
        ]

        for future in concurrent.futures.as_completed(futures):
            status, _ = future.result()
            counts["processed"] += 1
            count_status(status, counts)

    page_cursor = next(
        (
            record.tag_id
            for record in reversed(records)
            if record.tag_id is not None
        ),
        None,
    )

    cursor_changed = False
    if page_cursor is not None:
        with metadata_lock:
            cursor_changed = update_cursor_boundary(
                api_cursor,
                TagRecord("", page_cursor),
                cursor_mode,
            )

    if cursor_changed:
        save_tag_cursor(api_cursor)

    if args.limit > 0 and counts["processed"] >= args.limit:
        print("Reached processing limit.")
        return False, page_cursor

    return True, page_cursor


def run_api_page_loop(
    *,
    order: str,
    start_cursor: int | None,
    id_gt: int | None,
    id_lt: int | None,
    args,
    session: requests.Session,
    metadata: dict,
    successful_tags: set[str],
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
    api_cursor: dict,
    counts: dict[str, int],
    cursor_mode: str,
):
    cursor_id = start_cursor

    while True:
        if (
            args.limit > 0 and
            counts["processed"] >= args.limit
        ):
            print("Reached processing limit.")
            return

        records = fetch_tags_from_api_page(
            session,
            order=order,
            cursor_id=cursor_id,
            id_gt=id_gt,
            id_lt=id_lt,
            limit=args.api_limit,
            max_retries=args.retries,
        )

        if not records:
            print("No more tags.")
            return

        should_continue, page_cursor = process_api_page(
            records,
            args,
            metadata,
            successful_tags,
            failed_tags,
            do_not_retry_tags,
            api_cursor,
            counts,
            cursor_mode,
        )

        if not should_continue:
            print(
                "[API BLOCK] Current batch finished; "
                "stop before fetching next batch."
            )
            return

        if page_cursor is None:
            return

        cursor_id = page_cursor

        time.sleep(args.delay)


def run_sync_jobs(
    tags,
    args,
    metadata: dict,
    successful_tags: set[str],
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
    api_cursor: dict,
) -> dict[str, int]:
    counts = {
        "synced": 0,
        "skipped": 0,
        "blocked": 0,
        "failed": 0,
        "processed": 0,
    }

    futures = set()

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=args.workers
    ) as executor:

        for tag in tags:
            if (
                args.limit > 0 and
                counts["processed"] >= args.limit
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
                do_not_retry_tags,
            )

            futures.add(future)
            counts["processed"] += 1

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
                    status = count_completed_future(
                        future,
                        args,
                        api_cursor,
                    )
                    count_status(status, counts)

        for future in (
            concurrent.futures.as_completed(
                futures
            )
        ):
            status = count_completed_future(
                future,
                args,
                api_cursor,
            )
            count_status(status, counts)

    return counts


def run_api_sync_jobs(
    tags,
    args,
    metadata: dict,
    successful_tags: set[str],
    failed_tags: dict[str, dict],
    do_not_retry_tags: dict[str, dict],
    api_cursor: dict,
) -> dict[str, int]:
    counts = {
        "synced": 0,
        "skipped": 0,
        "blocked": 0,
        "failed": 0,
        "processed": 0,
    }

    process_failed_tags_first(
        args,
        metadata,
        successful_tags,
        failed_tags,
        do_not_retry_tags,
        api_cursor,
        counts,
    )

    if args.limit > 0 and counts["processed"] >= args.limit:
        return counts

    min_id = api_cursor.get("min_id")
    max_id = api_cursor.get("max_id")
    session = create_session(not args.no_verify_ssl)

    if args.no_verify_ssl:
        import urllib3

        urllib3.disable_warnings(
            urllib3.exceptions.InsecureRequestWarning
        )

    if not isinstance(min_id, int) or not isinstance(max_id, int):
        print("No API cursor found. Fetching full tag range...")
        run_api_page_loop(
            order="id_desc",
            start_cursor=None,
            id_gt=None,
            id_lt=None,
            args=args,
            session=session,
            metadata=metadata,
            successful_tags=successful_tags,
            failed_tags=failed_tags,
            do_not_retry_tags=do_not_retry_tags,
            api_cursor=api_cursor,
            counts=counts,
            cursor_mode="both",
        )
        return counts

    print(f"Fetching newest tags down to id > {max_id}...")
    run_api_page_loop(
        order="id_desc",
        start_cursor=None,
        id_gt=max_id,
        id_lt=None,
        args=args,
        session=session,
        metadata=metadata,
        successful_tags=successful_tags,
        failed_tags=failed_tags,
        do_not_retry_tags=do_not_retry_tags,
        api_cursor=api_cursor,
        counts=counts,
        cursor_mode="max",
    )

    if args.limit > 0 and counts["processed"] >= args.limit:
        return counts

    min_id = api_cursor.get("min_id")
    if not isinstance(min_id, int):
        return counts

    print(f"Fetching older tags with id < {min_id}...")
    run_api_page_loop(
        order="id_desc",
        start_cursor=min_id,
        id_gt=None,
        id_lt=min_id,
        args=args,
        session=session,
        metadata=metadata,
        successful_tags=successful_tags,
        failed_tags=failed_tags,
        do_not_retry_tags=do_not_retry_tags,
        api_cursor=api_cursor,
        counts=counts,
        cursor_mode="min",
    )

    return counts


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

    failed_tags = load_failed_cache(
        FAILED_CACHE_PATH
    )

    do_not_retry_tags = load_do_not_retry_cache(
        DO_NOT_RETRY_CACHE_PATH
    )

    invalid_failures = quarantine_invalid_failed_tags(
        failed_tags,
        do_not_retry_tags,
    )

    moved_failures = quarantine_exhausted_failures(
        failed_tags,
        do_not_retry_tags,
    )

    if invalid_failures or moved_failures:
        save_failed_cache(
            FAILED_CACHE_PATH,
            failed_tags,
        )
        save_do_not_retry_cache(
            DO_NOT_RETRY_CACHE_PATH,
            do_not_retry_tags,
        )

    if invalid_failures:
        print(
            f"Moved {invalid_failures} failed tags "
            f"with invalid characters to do-not-retry cache"
        )

    print(
        f"Loaded "
        f"{len(failed_tags)} "
        f"failed tags"
    )

    print(
        f"Loaded "
        f"{len(do_not_retry_tags)} "
        f"do-not-retry tags"
    )

    if moved_failures:
        print(
            f"Moved {moved_failures} tags "
            f"with more than {MAX_FAILED_ATTEMPTS} failures "
            f"to do-not-retry cache"
        )

    api_cursor = {} if args.reset_api_cursor else load_tag_cursor()
    tags = get_tags_iterator(args, api_cursor)

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
    if args.all_from_api:
        print(
            f"  api cursor    : "
            f"min={api_cursor.get('min_id')} "
            f"max={api_cursor.get('max_id')}"
        )
    print()

    print(
        f"Starting sync "
        f"(workers={args.workers})..."
    )

    try:
        if args.all_from_api:
            counts = run_api_sync_jobs(
                tags,
                args,
                metadata,
                successful_tags,
                failed_tags,
                do_not_retry_tags,
                api_cursor,
            )
        else:
            counts = run_sync_jobs(
                tags,
                args,
                metadata,
                successful_tags,
                failed_tags,
                do_not_retry_tags,
                api_cursor,
            )

    except KeyboardInterrupt:
        print()
        print("Interrupted by user.")
        counts = {
            "synced": 0,
            "skipped": 0,
            "blocked": 0,
            "failed": 1,
            "processed": 0,
        }

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

    print(f"Processed : {counts['processed']}")
    print(f"Synced    : {counts['synced']}")
    print(f"Skipped   : {counts['skipped']}")
    print(f"Blocked   : {counts['blocked']}")
    print(f"Failed    : {counts['failed']}")

    if counts["failed"] > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()

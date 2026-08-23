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
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, NamedTuple

import requests

# Ensure print() output uses UTF-8 regardless of the console code page.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import view

from scripts.tag_db import db


# === Config ===

def log(msg: str = ""):
    """Print (with a local HH:MM:SS timestamp prefix) to console AND crawl.log."""
    from datetime import datetime as _dt
    line = f"{_dt.now().strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    view.log_to_file(line)  # append to the shared crawl.log file


DEFAULT_TAGS = [
    "oguri_cap_(umamusume)", "special_week_(umamusume)", "silence_suzuka_(umamusume)",
    "tamamo_cross_(umamusume)", "mejiro_mcqueen_(umamusume)", "tokai_teio_(umamusume)",
    "gold_ship_(umamusume)", "daiwa_scarlet_(umamusume)", "rice_shower_(umamusume)",
    "super_creek_(umamusume)",
]

MAX_FAILED_ATTEMPTS = 5

CACHE_DIR = ROOT / "cache"
CACHE = {
    "success": CACHE_DIR / "successful_tags.json",
    "failed": CACHE_DIR / "failed_tags.json",
    "blocked": CACHE_DIR / "do_not_retry_tags.json",
    "cursor": CACHE_DIR / "tag_api_cursor.json",
}
CACHE_DIR.mkdir(parents=True, exist_ok=True)

metadata_lock = threading.Lock()
# Shared with view.request_semaphore so ALL HTTP requests (both sync_data and
# list-page fetches) are throttled by a single global concurrency cap of 3.
# Two independent Semaphore(3)s let concurrency reach 6 and trigger 429s.
request_semaphore = view.request_semaphore


class TagRecord(NamedTuple):
    name: str
    tag_id: int | None = None
    created_at: str | None = None


@dataclass
class SyncContext:
    args: argparse.Namespace
    metadata: dict
    success: set[str]
    failed: dict[str, dict]
    blocked: dict[str, dict]
    cursor: dict
    counts: dict = field(default_factory=lambda: {"synced": 0, "skipped": 0, "blocked": 0, "failed": 0, "processed": 0})
    lock: threading.Lock = None

    def __post_init__(self):
        if self.lock is None:
            self.lock = threading.Lock()


# === Cache ===

def _atomic_write(path: Path, payload: str):
    temp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    try:
        temp.write_text(payload, encoding="utf-8")
        for attempt in range(6):
            try:
                temp.replace(path)
                return
            except PermissionError:
                if attempt == 5:
                    raise
                time.sleep(0.1 * (attempt + 1))
    finally:
        try:
            temp.unlink(missing_ok=True)
        except PermissionError:
            pass


def load_json(path: Path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def save_json(path: Path, data):
    _atomic_write(path, json.dumps(data, ensure_ascii=False, indent=2))


def normalize_failed(entry: dict) -> dict:
    failures = entry.get("failures")
    return {
        "reason": str(entry.get("reason", "unknown")),
        "failures": failures if isinstance(failures, int) else 1,
        "last_failed_at": entry.get("last_failed_at"),
    }


def load_caches(ctx: SyncContext):
    status_map = db.list_sync_status()
    ctx.success = {t for t, e in status_map.items() if e["status"] == "success"}
    ctx.failed = {t: normalize_failed(e) for t, e in status_map.items() if e["status"] == "failed"}
    ctx.blocked = {t: normalize_failed(e) for t, e in status_map.items() if e["status"] == "blocked"}
    ctx.cursor = db.load_cursor()


def save_caches(ctx: SyncContext):
    now = datetime.now(timezone.utc).isoformat()
    rows = []

    for tag in sorted(ctx.success):
        meta = ctx.metadata.get(view.slugify_tag(tag), {})
        if not isinstance(meta, dict):
            meta = {}
        rows.append((tag, "success", None, 0, meta.get("last_sync_time") or now, None))

    for tag in sorted(ctx.failed):
        entry = ctx.failed[tag]
        if not isinstance(entry, dict):
            entry = {}
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

    for tag in sorted(ctx.blocked):
        entry = ctx.blocked[tag]
        if not isinstance(entry, dict):
            entry = {}
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

    db.upsert_sync_status_many(rows)
    db.save_cursor(ctx.cursor)


def quarantine_exhausted_failures(ctx: SyncContext) -> int:
    exh = 0
    for tag in list(ctx.failed.keys()):
        if ctx.failed[tag].get("failures", 1) >= MAX_FAILED_ATTEMPTS:
            ctx.blocked[tag] = ctx.failed[tag]
            ctx.failed.pop(tag, None)
            exh += 1
    return exh


# === Network ===

def create_session(verify_ssl: bool = True) -> requests.Session:
    session = requests.Session()
    session.headers.update({"User-Agent": "DanbooruTagInspector/1.0"})
    session.verify = verify_ssl
    # Optional authentication via HTTP Basic auth (login = username, password =
    # api key). If both env vars are set, all requests are authenticated, which
    # lifts the anonymous limit (max 1000/page) and relaxes rate limiting.
    login = os.environ.get("DANBOORU_LOGIN")
    api_key = os.environ.get("DANBOORU_API_KEY")
    if login and api_key:
        session.auth = (login, api_key)
    proxy = os.environ.get("DANBOORU_PROXY")
    if proxy is None and os.environ.get("GITHUB_ACTIONS") != "true":
        proxy = "http://127.0.0.1:10808"
    if proxy:
        session.proxies.update({"http": proxy, "https": proxy})
    return session


def safe_get(session: requests.Session, url: str, *, max_retries: int = 5, **kwargs):
    for retry in range(max_retries):
        try:
            with request_semaphore:
                resp = session.get(url, **kwargs)
            if resp.status_code == 429:
                wait = int(resp.headers.get("Retry-After", 0)) or 2 ** (retry + 1)
                log(f"[429] Rate limited. Sleeping {wait}s...")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            return resp
        except requests.exceptions.RequestException:
            if retry >= max_retries - 1:
                raise
            wait = 2 ** (retry + 1)
            log(f"[RETRY] {url} in {wait}s...")
            time.sleep(wait)
    raise RuntimeError("safe_get failed")


def verify_network(session: requests.Session) -> bool:
    try:
        safe_get(session, "https://danbooru.donmai.us/tags.json", params={"limit": 1}, timeout=15)
        print("[OK] Network verification succeeded.")
        return True
    except requests.exceptions.SSLError as exc:
        print(f"[SSL ERROR] {exc}")
        return False
    except Exception as exc:
        print(f"[NETWORK ERROR] {exc}")
        return False


# === API ===

def fetch_tags_from_api_page(session: requests.Session, *, order: str, cursor_id: int | None = None,
                              id_gt: int | None = None, id_lt: int | None = None,
                              limit: int = 500, max_retries: int = 5) -> list[TagRecord]:
    limit = min(limit, 1000)
    params = {"limit": limit, "search[order]": order}
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
    log(f"Fetching batch (order={order}, cursor_id={cursor_id}, id_gt={id_gt}, id_lt={id_lt})...")
    resp = safe_get(session, "https://danbooru.donmai.us/tags.json", max_retries=max_retries, params=params, timeout=30)
    records = []
    for tag in resp.json():
        tid = tag.get("id")
        name = tag.get("name")
        if name:
            records.append(
                TagRecord(
                    name,
                    tid if isinstance(tid, int) else None,
                    tag.get("created_at") if isinstance(tag.get("created_at"), str) else None,
                )
            )
    log(f"Got {len(records)} tags in current batch")
    return records


def iter_api_tags(*, order: str = "id_desc", cursor_id: int | None = None,
                  id_gt: int | None = None, id_lt: int | None = None,
                  limit: int = 500, verify_ssl: bool = True,
                  max_retries: int = 3, delay: float = 0.2) -> Iterator[TagRecord]:
    session = create_session(verify_ssl)
    if not verify_ssl:
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    cur = cursor_id
    total = 0
    while True:
        for retry in range(max_retries):
            try:
                records = fetch_tags_from_api_page(session, order=order, cursor_id=cur,
                                                   id_gt=id_gt, id_lt=id_lt, limit=limit, max_retries=max_retries)
                if not records:
                    print("No more tags.")
                    return
                ids = [r.tag_id for r in records if r.tag_id is not None]
                for r in records:
                    total += 1
                    yield r
                if not ids:
                    return
                cur = min(ids) if order == "id_desc" else max(ids)
                print(f"Got {len(records)} tags (total streamed: {total})")
                time.sleep(delay)
                break
            except requests.exceptions.RequestException as exc:
                if retry < max_retries - 1:
                    wait = 2 ** (retry + 1)
                    print(f"Retry {retry + 1}/{max_retries} after {wait}s: {exc}")
                    time.sleep(wait)
                else:
                    print(f"Error after {max_retries} retries: {exc}")
                    return


def iter_incremental_tags(cursor: dict, **kw) -> Iterator[TagRecord]:
    mid = cursor.get("min_id")
    mad = cursor.get("max_id")
    if not isinstance(mid, int) or not isinstance(mad, int):
        print("No API cursor found. Fetching full tag range...")
        yield from iter_api_tags(order="id_desc", **kw)
        return
    print(f"Fetching new tags with id > {mad}...")
    yield from iter_api_tags(order="id_asc", id_gt=mad, **kw)
    print(f"Fetching older tags with id < {mid}...")
    yield from iter_api_tags(order="id_desc", id_lt=mid, **kw)


# === Sync ===

def sync_tag(record: TagRecord, ctx: SyncContext) -> tuple[str, TagRecord]:
    tag = record.name
    try:
        if tag in ctx.success and not ctx.args.force:
            log(f"[CACHE SKIP] {tag}")
            return "skipped", record

        if not ctx.args.force:
            needs = view.check_needs_sync(tag, max_age_hours=ctx.args.max_age)
            if not needs:
                log(f"[SKIP] {tag}")
                with ctx.lock:
                    ctx.success.add(tag)
                    ctx.failed.pop(tag, None)
                    ctx.blocked.pop(tag, None)
                    db.set_sync_status(
                        tag,
                        "success",
                        last_sync_time=datetime.now(timezone.utc).isoformat(),
                    )
                return "skipped", record

        if tag in ctx.blocked:
            log(f"[DO NOT RETRY] {tag}")
            return "blocked", record

        log(f"[SYNC] {tag}")
        payload = view.sync_data(tag)
        # Write the FULL record (completion_candidates + tag_id/category/
        # post_count + wiki other_names + aliases) straight into the tags
        # table so no post-hoc JSON backfill pass is ever needed.
        try:
            db.upsert_tag(payload)
        except Exception as db_exc:
            log(f"  [WARN] upsert_tag failed for {tag}: {db_exc}")
        slug = view.slugify_tag(tag)
        log(f"  [OK] stored in db: {tag}")

        with ctx.lock:
            ctx.metadata[slug] = {
                "last_sync_time": datetime.now(timezone.utc).isoformat(),
                "version": ctx.metadata.get(slug, {}).get("version", 1),
                "tag": tag,
            }
            ctx.success.add(tag)
            ctx.failed.pop(tag, None)
            ctx.blocked.pop(tag, None)
            db.set_sync_status(
                tag,
                "success",
                last_sync_time=ctx.metadata[slug]["last_sync_time"],
            )
        return "synced", record

    except Exception as exc:
        with ctx.lock:
            existing = ctx.failed.get(tag)
            entry = normalize_failed(existing) if existing else {"reason": "unknown", "failures": 0, "last_failed_at": None}
            entry["reason"] = str(exc)
            entry["failures"] = entry.get("failures", 0) + 1
            entry["last_failed_at"] = datetime.now(timezone.utc).isoformat()
            if entry["failures"] >= MAX_FAILED_ATTEMPTS:
                ctx.failed.pop(tag, None)
                ctx.blocked[tag] = entry
                db.set_sync_status(
                    tag,
                    "blocked",
                    reason=entry["reason"],
                    failures=entry["failures"],
                    last_failed_at=entry["last_failed_at"],
                )
            else:
                ctx.failed[tag] = entry
                db.set_sync_status(
                    tag,
                    "failed",
                    reason=entry["reason"],
                    failures=entry["failures"],
                    last_failed_at=entry["last_failed_at"],
                )
        log(f"[FAIL] {tag}: {exc}")
        return "failed", record


def update_cursor(cursor: dict, record: TagRecord, mode: str = "both") -> bool:
    if record.tag_id is None:
        return False
    changed = False
    if mode in ("max", "both"):
        cur = cursor.get("max_id")
        if not isinstance(cur, int) or record.tag_id > cur:
            cursor["max_id"] = record.tag_id
            changed = True
    if mode in ("min", "both"):
        cur = cursor.get("min_id")
        if not isinstance(cur, int) or record.tag_id < cur:
            cursor["min_id"] = record.tag_id
            changed = True
    return changed


def finish_task(ctx: SyncContext, status: str, record: TagRecord, advance: bool = True, mode: str = "both"):
    ctx.counts["processed"] += 1
    if status in ctx.counts:
        ctx.counts[status] += 1
    else:
        ctx.counts["failed"] += 1
    if advance and status in ("synced", "skipped", "blocked"):
        with ctx.lock:
            # Only update the in-memory cursor here; persistence is done in
            # batches (see save_caches calls in the run_* loops) to avoid
            # rewriting the whole success set on every single tag.
            update_cursor(ctx.cursor, record, mode)


# === Args ===

def parse_args():
    p = argparse.ArgumentParser(description="Batch sync multiple Danbooru tags")
    p.add_argument("--tags", nargs="+", help="Tags to sync")
    p.add_argument("--file", type=Path, help="File with one tag per line")
    p.add_argument("--default", action="store_true", help="Use default preset tags")
    p.add_argument("--all-from-api", action="store_true", help="Fetch tags from API. Uses saved min/max id cursor unless --reset-api-cursor is set.")
    p.add_argument("--reset-api-cursor", action="store_true", help="Ignore saved API min/max id cursor and fetch the full tag range.")
    p.add_argument("--retry-failed", action="store_true", help="Retry only failed tags")
    p.add_argument("--api-limit", type=int, default=500, help="Tags per API request")
    p.add_argument("--no-verify-ssl", action="store_true", help="Disable SSL verification")
    p.add_argument("--retries", type=int, default=3, help="Max retries")
    p.add_argument("--delay", type=float, default=0.2, help="Delay between API requests")
    p.add_argument("--force", action="store_true", help="Force resync")
    p.add_argument("--max-age", type=int, default=24, help="Max cache age")
    p.add_argument("--limit", type=int, default=0, help="Maximum processed tags")
    p.add_argument("--workers", type=int, default=3, help="Concurrent workers")
    p.add_argument(
        "--rate",
        type=float,
        default=7.0,
        help="Global request rate cap in requests/second (default 7). "
             "Danbooru starts returning 429 beyond ~8 req/s.",
    )
    p.add_argument(
        "--resync-months",
        type=int,
        default=0,
        help="Force overwrite-sync tags created within the last N months. "
             "Walks tags from newest (id_desc), reads each tag's created_at, and "
             "stops as soon as a tag is older than N months.",
    )
    p.add_argument(
        "--fill-gaps",
        action="store_true",
        help="Walk the full Danbooru tag list from the API and sync only tags "
             "missing from the local database. Existing tags are skipped.",
    )
    p.add_argument(
        "--from-id",
        type=int,
        default=None,
        help="Resume from a specific tag id (id_desc direction). Useful with --resync-months.",
    )
    return p.parse_args()


def get_tag_source(args) -> Iterator[TagRecord]:
    if args.tags:
        return (TagRecord(t) for t in args.tags)
    if args.file:
        lines = args.file.read_text(encoding="utf-8").splitlines()
        return (TagRecord(t.strip()) for t in lines if t.strip())
    if args.default:
        return (TagRecord(t) for t in DEFAULT_TAGS)
    if args.all_from_api:
        return iter(())
    return iter([TagRecord(view.DEFAULT_TAG)])


# === Workers ===

def run_pool(ctx: SyncContext, tags, advance: bool = True, mode: str = "both"):
    """Smooth concurrency: keep at most `workers` syncs running at once.

    Uses a bounded semaphore so a new tag is submitted the moment a worker
    frees up, instead of batching up to `workers*4` tasks and releasing them
    in bursts. This keeps API request load steady and reduces 429 spikes.
    """
    workers = max(1, ctx.args.workers)
    sem = threading.BoundedSemaphore(workers)
    it = iter(tags)

    def worker():
        while True:
            sem.acquire()
            try:
                try:
                    rec = next(it)
                except StopIteration:
                    return
                if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
                    return
                st, done_rec = sync_tag(rec, ctx)
                finish_task(ctx, st, done_rec, advance, mode)
            finally:
                sem.release()

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


def run_failed_first(ctx: SyncContext):
    retry = sorted(t for t in ctx.failed if t not in ctx.blocked)
    if retry:
        print(f"Retrying {len(retry)} failed tags first...")
    for tag in retry:
        if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
            print("Reached processing limit.")
            return
        st, rec = sync_tag(TagRecord(tag), ctx)
        finish_task(ctx, st, rec, advance=False)


def run_api_loop(ctx: SyncContext, *, order: str, start: int | None = None,
                 id_gt: int | None = None, id_lt: int | None = None, mode: str = "both"):
    session = create_session(not ctx.args.no_verify_ssl)
    if ctx.args.no_verify_ssl:
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    # Background flusher: periodically persist the full cache so the expensive
    # full rewrite (save_caches walks the whole success set) never blocks the
    # network-request loop.
    stop_flag = threading.Event()

    def flusher():
        while not stop_flag.is_set():
            stop_flag.wait(60.0)
            if stop_flag.is_set():
                break
            try:
                with ctx.lock:
                    save_caches(ctx)
            except Exception as exc:
                print(f"[FLUSH] save_caches error: {exc}")
                continue
            print(f"[FLUSH] saved cache ({len(ctx.success)} success)", flush=True)

    fthread = threading.Thread(target=flusher, daemon=True)
    fthread.start()

    cur = start
    try:
        while True:
            if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
                print("Reached processing limit.")
                return
            records = fetch_tags_from_api_page(session, order=order, cursor_id=cur,
                                               id_gt=id_gt, id_lt=id_lt, limit=ctx.args.api_limit,
                                               max_retries=ctx.args.retries)
            if not records:
                print("No more tags.")
                return
            rem = ctx.args.limit - ctx.counts["processed"] if ctx.args.limit > 0 else len(records)
            batch = records[:rem] if ctx.args.limit > 0 else records
            run_pool(ctx, batch, advance=True, mode=mode)
            # Persist cursor (cheap). Full-cache persistence is handled by the
            # background flusher thread so network requests are not blocked.
            with ctx.lock:
                db.save_cursor(ctx.cursor)
            if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
                print("Reached processing limit.")
                return
            cur = next((r.tag_id for r in reversed(batch) if r.tag_id is not None), None)
            if cur is None:
                return
            time.sleep(ctx.args.delay)
    finally:
        stop_flag.set()
        fthread.join(timeout=2)
        # Final flush so the last batch's changes are persisted.
        with ctx.lock:
            save_caches(ctx)


def run_api_sync(ctx: SyncContext):
    run_failed_first(ctx)
    if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
        return
    mid = ctx.cursor.get("min_id")
    mad = ctx.cursor.get("max_id")
    if not isinstance(mid, int) or not isinstance(mad, int):
        print("No API cursor found. Fetching full tag range...")
        run_api_loop(ctx, order="id_desc", mode="both")
        return
    print(f"Fetching newest tags down to id > {mad}...")
    run_api_loop(ctx, order="id_desc", id_gt=mad, mode="max")
    if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
        return
    if isinstance(ctx.cursor.get("min_id"), int):
        mid = ctx.cursor["min_id"]
        print(f"Fetching older tags with id < {mid}...")
        run_api_loop(ctx, order="id_desc", start=mid, id_lt=mid, mode="min")


def run_resync_months(ctx: SyncContext, months: int):
    """Force overwrite-sync tags created within the last `months` months.

    Walks tags from newest (id_desc), reading each tag's created_at, and stops
    as soon as a tag is older than `months` months. Since ids increase over
    time, walking id_desc means the remaining tags are only older, so we can
    stop immediately.
    """
    from datetime import datetime, timedelta, timezone

    cutoff = datetime.now(timezone.utc) - timedelta(days=months * 30)
    session = create_session(not ctx.args.no_verify_ssl)
    if ctx.args.no_verify_ssl:
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    def parse_ts(value: str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except Exception:
            return None

    cur: int | None = ctx.args.from_id or None
    print(f"\n[RESYNC] Overwrite-syncing tags created within last {months} month(s) "
          f"(cutoff: {cutoff.isoformat()})"
          f"{' from id ' + str(cur) if cur else ''}...")

    scanned = 0
    while True:
        if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
            print("Reached processing limit.")
            return
        records = fetch_tags_from_api_page(
            session,
            order="id_desc",
            cursor_id=cur,
            limit=ctx.args.api_limit,
            max_retries=ctx.args.retries,
        )
        if not records:
            print("No more tags.")
            return

        # Since we walk newest->oldest, stop as soon as we hit a tag older than cutoff.
        stop = False
        for rec in records:
            scanned += 1
            if rec.created_at:
                ts = parse_ts(rec.created_at)
                if ts is not None and ts < cutoff:
                    print(f"[RESYNC] Reached cutoff at {rec.name} (created {rec.created_at}); stopping.")
                    stop = True
                    break
            # Force overwrite regardless of cache freshness.
            ctx.args.force = True
            status, done_rec = sync_tag(rec, ctx)
            finish_task(ctx, status, done_rec, advance=True, mode="both")
            if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
                print("Reached processing limit.")
                return

        if stop:
            return

        cur = next((r.tag_id for r in reversed(records) if r.tag_id is not None), None)
        if cur is None:
            return
        time.sleep(ctx.args.delay)

    print(f"[RESYNC] Scanned {scanned} tags total.")


def run_fill_gaps(ctx: SyncContext):
    """Walk the full Danbooru tag list from the API and sync only tags missing
    from the local database.

    Walks tags from newest (id_desc) page by page (max 1000/page). For each page
    it checks which tag_ids are already in the DB and skips them, syncing only
    the missing ones. This covers the whole range including any gaps in the
    middle (min_id..max_id) that `--all-from-api` does not visit.
    """
    session = create_session(not ctx.args.no_verify_ssl)
    if ctx.args.no_verify_ssl:
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    print("\n[FILL-GAPS] Walking full Danbooru tag list, syncing only missing tags...")

    cur: int | None = None
    scanned = 0
    missing_total = 0
    while True:
        if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
            print("Reached processing limit.")
            return
        records = fetch_tags_from_api_page(
            session,
            order="id_desc",
            cursor_id=cur,
            limit=ctx.args.api_limit,
            max_retries=ctx.args.retries,
        )
        if not records:
            print("No more tags.")
            break

        scanned += len(records)
        ids = [r.tag_id for r in records if r.tag_id is not None]
        existing = db.existing_tag_ids(ids) if ids else set()
        for rec in records:
            if rec.tag_id is not None and rec.tag_id in existing:
                continue
            # Only sync tags that are missing from the DB (or lack a tag_id).
            missing_total += 1
            status, done_rec = sync_tag(rec, ctx)
            finish_task(ctx, status, done_rec, advance=False, mode="none")
            if ctx.args.limit > 0 and ctx.counts["processed"] >= ctx.args.limit:
                print("Reached processing limit.")
                return
        save_caches(ctx)

        cur = next((r.tag_id for r in reversed(records) if r.tag_id is not None), None)
        if cur is None:
            return
        time.sleep(ctx.args.delay)

    print(f"[FILL-GAPS] Scanned {scanned} tags, synced {missing_total} missing.")


# === Main ===

def main():
    args = parse_args()
    session = create_session(not args.no_verify_ssl)
    if not verify_network(session):
        if not args.no_verify_ssl:
            print("[WARN] SSL verification failed.\n[INFO] Retrying with SSL disabled...")
            session = create_session(False)
            if not verify_network(session):
                sys.exit(1)
            args.no_verify_ssl = True
        else:
            sys.exit(1)
    view.session = session
    view.set_request_rate(args.rate)
    print(f"Global request rate: {args.rate} req/s")

    print("\nLoading metadata...")
    try:
        metadata = view.load_sync_metadata()
    except Exception as exc:
        print(f"[WARN] Failed to load metadata: {exc}")
        metadata = {}

    ctx = SyncContext(args=args, metadata=metadata, success=set(), failed={}, blocked={}, cursor={})
    load_caches(ctx)
    exh = quarantine_exhausted_failures(ctx)
    if exh:
        save_caches(ctx)
        print(f"Moved {exh} tags with more than {MAX_FAILED_ATTEMPTS} failures to do-not-retry cache")
    print(f"Loaded {len(ctx.success)} successful tags")
    print(f"Loaded {len(ctx.failed)} failed tags")
    print(f"Loaded {len(ctx.blocked)} do-not-retry tags")

    if args.reset_api_cursor:
        ctx.cursor = {}
        db.clear_cursor()

    if args.retry_failed:
        tags = (TagRecord(t) for t in sorted(ctx.failed.keys()) if t not in ctx.blocked)
        print(f"Retrying failed tags...")
    else:
        tags = get_tag_source(args)

    print(f"\nConfiguration:\n  all_from_api : {args.all_from_api}\n  retry_failed : {args.retry_failed}\n  workers       : {args.workers}\n  limit         : {args.limit}\n  force         : {args.force}")
    if args.all_from_api:
        print(f"  api cursor    : min={ctx.cursor.get('min_id')} max={ctx.cursor.get('max_id')}")

    print(f"\nStarting sync (workers={args.workers})...")
    try:
        if args.resync_months > 0:
            run_resync_months(ctx, args.resync_months)
        elif args.fill_gaps:
            run_fill_gaps(ctx)
        elif args.all_from_api:
            run_api_sync(ctx)
        else:
            run_pool(ctx, tags)
    except KeyboardInterrupt:
        print("\nInterrupted by user.")
        ctx.counts = {"synced": 0, "skipped": 0, "blocked": 0, "failed": 1, "processed": 0}

    print("\nSaving metadata...")
    try:
        with ctx.lock:
            view.save_sync_metadata(ctx.metadata)
    except Exception as exc:
        print(f"[WARN] Failed to save metadata: {exc}")

    save_caches(ctx)

    print(f"\n{'=' * 60}\nSummary\n{'=' * 60}")
    print(f"Processed : {ctx.counts['processed']}")
    print(f"Synced    : {ctx.counts['synced']}")
    print(f"Skipped   : {ctx.counts['skipped']}")
    print(f"Blocked   : {ctx.counts['blocked']}")
    print(f"Failed    : {ctx.counts['failed']}")
    if ctx.counts["failed"] > 0:
        sys.exit(1)


# === Backward compatibility aliases ===

DO_NOT_RETRY_CACHE_PATH = CACHE["blocked"]
FAILED_CACHE_PATH = CACHE["failed"]
SUCCESS_CACHE_PATH = CACHE["success"]


def load_json_set(path: Path | None = None) -> set[str]:
    """Backward-compat: successful tag names now come from the database."""
    return set(db.list_successful_tags())


def load_failed_cache(path: Path | None = None) -> dict[str, dict]:
    return {
        t: normalize_failed(e)
        for t, e in db.list_sync_status("failed").items()
    }


def load_do_not_retry_cache(path: Path | None = None) -> dict[str, dict]:
    return {
        t: normalize_failed(e)
        for t, e in db.list_sync_status("blocked").items()
    }


def load_tag_cursor(path: Path | None = None) -> dict:
    return db.load_cursor()


def save_tag_cursor(cursor: dict, path: Path | None = None):
    db.save_cursor(cursor)


def update_cursor_boundary(cursor: dict, record: TagRecord, mode: str) -> bool:
    return update_cursor(cursor, record, mode)


def sync_single_tag(record: TagRecord, args, metadata: dict, successful_tags: set[str],
                    failed_tags: dict[str, dict], do_not_retry_tags: dict[str, dict]) -> tuple[str, TagRecord]:
    ctx = SyncContext(args=args, metadata=metadata, success=successful_tags,
                      failed=failed_tags, blocked=do_not_retry_tags,
                      cursor={}, lock=metadata_lock)
    result = sync_tag(record, ctx)
    save_caches(ctx)
    return result


if __name__ == "__main__":
    main()

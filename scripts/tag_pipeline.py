#!/usr/bin/env python3
"""Producer/consumer pipeline for Danbooru tag sync.

Splits the previous monolithic sync into two independent processes so the
"fetch the tag list" step never blocks the "sync a tag" step and vice versa.

  Process A (producer, `list`): walks the /tags.json list pages and enqueues
      each tag into the shared sync_queue table. Only does list requests.
  Process B (consumer, `sync`): claims queued tags, runs the 3-request sync
      (tags/wiki/aliases) and writes results. Never fetches list pages.

Shared state lives in cache/danbooru_tags.db:
  - sync_queue : cross-process work queue (producer writes, consumer claims)
  - api_cursor : list cursor the producer advances (min_id/max_id)
  - tags/sync_status : final results the consumer writes

Rate limiting is per-process (the global _RateLimiter is in-process). To keep
the TOTAL request rate across both processes under Danbooru's ~8 req/s cap,
run the producer with a low rate (e.g. --rate 2) and the consumer with
--rate 5, for a combined ~7 req/s. Auth (DANBOORU_LOGIN/API_KEY) still helps.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

import requests

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import view

from scripts.tag_db import db
from scripts.batch_sync_tags import (
    create_session,
    fetch_tags_from_api_page,
    normalize_failed,
    TagRecord,
)

MAX_FAILED_ATTEMPTS = 5
MAX_AGE_HOURS = 24


def log(msg: str = ""):
    from datetime import datetime as _dt
    line = f"{_dt.now().strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    view.log_to_file(line)


# === Producer (list crawler) ===

def enqueue_page_records(records: list[TagRecord], *, created_after=None) -> int:
    """Insert a page of TagRecords into sync_queue. Returns newly enqueued count."""
    rows = []
    for rec in records:
        if rec.tag_id is None or not rec.name:
            continue
        if created_after is not None and rec.created_at:
            ts = parse_ts(rec.created_at)
            if ts is not None and ts < created_after:
                continue
        rows.append((rec.tag_id, rec.name, rec.created_at))
    return db.enqueue_many(rows)


def parse_ts(value: str):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


def run_list_incremental(args):
    cursor = db.load_cursor()
    mid = cursor.get("min_id")
    mad = cursor.get("max_id")
    session = create_session(not args.no_verify_ssl)
    if not isinstance(mid, int) or not isinstance(mad, int):
        log("[LIST] No cursor; walking full range id_desc...")
        run_list_full_desc(args, session)
        return
    # New tags (id > max)
    log(f"[LIST] Enqueuing tags with id > {mad}...")
    cur = None
    while True:
        records = fetch_tags_from_api_page(
            session, order="id_asc", cursor_id=cur, limit=args.api_limit,
            max_retries=args.retries,
        )
        if not records:
            break
        added = enqueue_page_records(records)
        log(f"[LIST] id>max page: +{added} enqueued")
        cur = next((r.tag_id for r in reversed(records) if r.tag_id is not None), None)
        if cur is None:
            break
        time.sleep(args.delay)
    # Older tags (id < min)
    log(f"[LIST] Enqueuing tags with id < {mid}...")
    cur = None
    while True:
        records = fetch_tags_from_api_page(
            session, order="id_desc", cursor_id=cur, id_lt=mid, limit=args.api_limit,
            max_retries=args.retries,
        )
        if not records:
            break
        added = enqueue_page_records(records)
        log(f"[LIST] id<min page: +{added} enqueued")
        cur = next((r.tag_id for r in reversed(records) if r.tag_id is not None), None)
        if cur is None:
            break
        time.sleep(args.delay)
    log("[LIST] Incremental walk complete.")


def run_list_resync_months(args, months: int):
    cutoff = datetime.now(timezone.utc) - __import__("datetime").timedelta(days=months * 30)
    cur = getattr(args, "from_id", None)
    log(f"[LIST] Resync-months={months}, cutoff={cutoff.isoformat()}, walking id_desc"
        f"{' from id ' + str(cur) if cur else ' from newest'}...")
    session = create_session(not args.no_verify_ssl)
    scanned = 0
    while True:
        records = fetch_tags_from_api_page(
            session, order="id_desc", cursor_id=cur, limit=args.api_limit,
            max_retries=args.retries,
        )
        if not records:
            log("[LIST] No more tags.")
            break
        stop = False
        rows = []
        for rec in records:
            scanned += 1
            if rec.created_at:
                ts = parse_ts(rec.created_at)
                if ts is not None and ts < cutoff:
                    log(f"[LIST] Reached cutoff at id={rec.tag_id} ({rec.name}); stopping.")
                    stop = True
                    break
            if rec.tag_id is not None and rec.name:
                rows.append((rec.tag_id, rec.name, rec.created_at))
        added = db.enqueue_many(rows)
        log(f"[LIST] resync page: +{added} enqueued (scanned {scanned})")
        if stop:
            break
        cur = next((r.tag_id for r in reversed(records) if r.tag_id is not None), None)
        if cur is None:
            break
        time.sleep(args.delay)
    log(f"[LIST] Resync-months walk complete. Scanned {scanned}.")


def run_list_full_desc(args, session=None):
    """Walk entire tag list newest->oldest, enqueueing everything not yet in tags table."""
    if session is None:
        session = create_session(not args.no_verify_ssl)
    cur = getattr(args, "from_id", None)
    log(f"[LIST] Full id_desc walk (fill-gaps): enqueueing only missing tags"
        f"{' from id ' + str(cur) if cur else ''}...")
    scanned = 0
    while True:
        records = fetch_tags_from_api_page(
            session, order="id_desc", cursor_id=cur, limit=args.api_limit,
            max_retries=args.retries,
        )
        if not records:
            break
        ids = [r.tag_id for r in records if r.tag_id is not None]
        existing = db.existing_tag_ids(ids) if ids else set()
        rows = [
            (r.tag_id, r.name, r.created_at)
            for r in records
            if r.tag_id is not None and r.name and r.tag_id not in existing
        ]
        added = db.enqueue_many(rows)
        scanned += len(records)
        log(f"[LIST] fill page: +{added} enqueued ({len(existing)} already exist, scanned {scanned})")
        cur = next((r.tag_id for r in reversed(records) if r.tag_id is not None), None)
        if cur is None:
            break
        time.sleep(args.delay)
    log(f"[LIST] Full walk complete. Scanned {scanned}.")


# === Consumer (syncer) ===

def _load_success() -> set[str]:
    return set(db.list_successful_tags())


def sync_queue_tag(rec: tuple, *, force: bool) -> tuple[str, int]:
    """rec: (tag_id, name, created_at). Returns (status, tag_id)."""
    tag_id, name, _created = rec
    tag = name
    try:
        if not force and tag in db.list_sync_status("success"):
            return "skipped", tag_id
        if not force and not view.check_needs_sync(tag, MAX_AGE_HOURS):
            db.set_sync_status(
                tag, "success", last_sync_time=datetime.now(timezone.utc).isoformat()
            )
            return "skipped", tag_id
        view.sync_data(tag)
        slug = view.slugify_tag(tag)
        db.set_sync_status(
            tag, "success",
            last_sync_time=datetime.now(timezone.utc).isoformat(),
        )
        return "synced", tag_id
    except Exception as exc:
        existing = db.get_sync_status(tag)
        if existing:
            entry = normalize_failed(existing)
        else:
            entry = {"reason": "unknown", "failures": 0, "last_failed_at": None}
        entry["reason"] = str(exc)
        entry["failures"] = entry.get("failures", 0) + 1
        entry["last_failed_at"] = datetime.now(timezone.utc).isoformat()
        if entry["failures"] >= MAX_FAILED_ATTEMPTS:
            db.set_sync_status(
                tag, "blocked", reason=entry["reason"],
                failures=entry["failures"], last_failed_at=entry["last_failed_at"],
            )
        else:
            db.set_sync_status(
                tag, "failed", reason=entry["reason"],
                failures=entry["failures"], last_failed_at=entry["last_failed_at"],
            )
        log(f"[FAIL] {tag}: {exc}")
        return "failed", tag_id


def run_sync(args):
    view.set_request_rate(args.rate)
    session = create_session(not args.no_verify_ssl)
    view.session = session
    log(f"[SYNC] Consumer started. rate={args.rate} req/s, workers={args.workers}, "
        f"queue pending={db.queue_count('pending')}, claimed={db.queue_count('claimed')}")
    counts = {"synced": 0, "skipped": 0, "failed": 0, "processed": 0}
    idle_rounds = 0
    stop = threading.Event()

    while True:
        if args.limit > 0 and counts["processed"] >= args.limit:
            log(f"[SYNC] Reached processing limit {args.limit}.")
            break
        batch = db.claim_batch(limit=args.workers, claimer=f"pid{os.getpid()}", claim_seconds=600)
        if not batch:
            idle_rounds += 1
            if idle_rounds >= args.idle_stop:
                log(f"[SYNC] Queue empty for {idle_rounds} rounds; stopping.")
                break
            time.sleep(args.poll)
            continue
        idle_rounds = 0

        # Process claimed batch with a small pool
        results = []
        lock = threading.Lock()
        pending = list(batch)

        def worker():
            while True:
                with lock:
                    if not pending:
                        return
                    rec = pending.pop(0)
                st, tid = sync_queue_tag(rec, force=args.force)
                with lock:
                    counts["processed"] += 1
                    counts[st if st in counts else "failed"] += 1
                db.mark_done(tid, st)
                results.append((tid, st))
                log(f"[SYNC] {rec[1]} -> {st}")

        threads = [threading.Thread(target=worker, daemon=True) for _ in range(max(1, args.workers))]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        log(f"[SYNC] batch done: processed={counts['processed']} "
            f"synced={counts['synced']} skipped={counts['skipped']} failed={counts['failed']} "
            f"queue pending={db.queue_count('pending')}")

    # Flush metadata
    try:
        view.save_sync_metadata({})
    except Exception:
        pass
    log(f"[SYNC] Done. processed={counts['processed']} synced={counts['synced']} "
        f"skipped={counts['skipped']} failed={counts['failed']}")


def run_status(args):
    counts = db.queue_status_counts()
    pending = counts.get("pending", 0)
    claimed = counts.get("claimed", 0)
    done = sum(v for k, v in counts.items() if k not in ("pending", "claimed"))
    print(f"queue: pending={pending} claimed={claimed} done={done} total={db.queue_count()}")
    for k in ("synced", "skipped", "failed", "blocked", "done"):
        if k in counts:
            print(f"  {k}: {counts[k]}")


# === CLI ===

def parse_args():
    p = argparse.ArgumentParser(description="Producer/consumer Danbooru tag pipeline")
    sub = p.add_subparsers(dest="cmd", required=True)

    pl = sub.add_parser("list", help="Producer: crawl list pages into sync_queue")
    pl.add_argument("--incremental", action="store_true", help="Walk by saved cursor (new+older)")
    pl.add_argument("--resync-months", type=int, default=0, help="Walk newest N months, force re-sync")
    pl.add_argument("--from-id", type=int, default=None, help="Start id (resume). id_desc: skip ids >= this")
    pl.add_argument("--fill-gaps", action="store_true", help="Walk full range, enqueue only missing")
    pl.add_argument("--api-limit", type=int, default=1000)
    pl.add_argument("--no-verify-ssl", action="store_true")
    pl.add_argument("--retries", type=int, default=3)
    pl.add_argument("--delay", type=float, default=0.2)
    pl.add_argument("--rate", type=float, default=2.0, help="Producer request rate (keep low)")
    pl.set_defaults(func=run_list)

    ps = sub.add_parser("sync", help="Consumer: claim queue and sync tags")
    ps.add_argument("--workers", type=int, default=5)
    ps.add_argument("--rate", type=float, default=5.0)
    ps.add_argument("--force", action="store_true", help="Force resync all queued")
    ps.add_argument("--limit", type=int, default=0)
    ps.add_argument("--poll", type=float, default=2.0, help="Seconds between empty polls")
    ps.add_argument("--idle-stop", type=int, default=30, help="Stop after N empty polls")
    ps.add_argument("--no-verify-ssl", action="store_true")
    ps.set_defaults(func=run_sync)

    ps2 = sub.add_parser("status", help="Show queue status")
    ps2.set_defaults(func=run_status)

    return p.parse_args()


def run_list(args):
    view.set_request_rate(args.rate)
    if args.incremental:
        run_list_incremental(args)
    elif args.resync_months > 0:
        run_list_resync_months(args, args.resync_months)
    elif args.fill_gaps:
        run_list_full_desc(args)
    else:
        print("list: specify --incremental, --resync-months N, or --fill-gaps")
        sys.exit(1)


def main():
    args = parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Unified SQLite storage for all Danbooru tag sync data.

Replaces the previous JSON-file based storage:
    cache/successful_tags.json
    cache/failed_tags.json
    cache/do_not_retry_tags.json
    cache/tag_api_cursor.json
    cache/sync_metadata.json
    cache/tags_checkpoint.json
    .danbooru_cache/{tag}.json
    assets/danbooru_completion/{tag}.json

All data lives in a single SQLite database: cache/danbooru_tags.db
"""

from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import NamedTuple
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "cache" / "danbooru_tags.db"

_write_lock = threading.RLock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS tags (
    name                 TEXT PRIMARY KEY,
    tag_id               INTEGER,
    slug                 TEXT NOT NULL,
    category             INTEGER,
    post_count           INTEGER,
    updated_at           TEXT NOT NULL,
    wiki_other_names     TEXT,
    aliases              TEXT,
    completion_candidates TEXT NOT NULL,
    completion_authoritative INTEGER NOT NULL DEFAULT 0,
    version              INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_tags_tag_id ON tags(tag_id);
CREATE INDEX IF NOT EXISTS idx_tags_slug   ON tags(slug);

CREATE TABLE IF NOT EXISTS sync_status (
    tag             TEXT PRIMARY KEY,
    status          TEXT NOT NULL,
    reason          TEXT,
    failures        INTEGER NOT NULL DEFAULT 0,
    last_sync_time  TEXT,
    last_failed_at  TEXT,
    version         INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_sync_status_status ON sync_status(status);

CREATE TABLE IF NOT EXISTS api_cursor (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    min_id     INTEGER,
    max_id     INTEGER,
    updated_at TEXT
);

CREATE TABLE IF NOT EXISTS sync_metadata (
    slug           TEXT PRIMARY KEY,
    tag            TEXT,
    last_sync_time TEXT,
    version        INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS checkpoint (
    id   INTEGER PRIMARY KEY CHECK (id = 1),
    data TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_queue (
    tag_id      INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    created_at  TEXT,
    status      TEXT NOT NULL DEFAULT 'pending',
    enqueued_at TEXT NOT NULL,
    claimed_by  TEXT,
    claimed_at  REAL,
    claim_token TEXT,
    done_at     TEXT
);
CREATE INDEX IF NOT EXISTS idx_sync_queue_status ON sync_queue(status);
"""


def slugify_tag(tag: str) -> str:
    """Match view.slugify_tag: keep alnum, replace the rest with '_'."""
    return "".join(ch if ch.isalnum() else "_" for ch in tag).strip("_")


def _dumps(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def _loads(value: str | None):
    if value is None:
        return None
    try:
        return json.loads(value)
    except (ValueError, TypeError):
        return None


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def legacy_completion_authoritative(candidates_json, status, last_sync_time) -> bool:
    """Infer only what an old schema actually recorded about a complete sync."""
    candidates = _loads(candidates_json)
    if not isinstance(candidates, list):
        return False
    valid_candidate = any(
        isinstance(item, dict)
        and isinstance(item.get("value"), str) and item["value"]
        and isinstance(item.get("insert_value", item["value"]), str)
        and item.get("insert_value", item["value"])
        for item in candidates
    )
    return bool(valid_candidate or status == "success" or last_sync_time)


class QueueClaim(NamedTuple):
    tag_id: int
    name: str
    created_at: str | None
    token: str


def merge_import_payload(stored: dict | None, incoming: dict) -> dict:
    """Import only supplied fields; compact backups must not erase metadata."""
    if (not isinstance(incoming, dict)
            or not isinstance(incoming.get("tag"), str) or not incoming["tag"]):
        raise ValueError("import payload requires a non-empty tag")
    for field in ("completion_candidates", "aliases"):
        if field in incoming and not isinstance(incoming[field], list):
            raise ValueError(f"{field} must be a list")
    for candidate in incoming.get("completion_candidates", []):
        if not isinstance(candidate, dict):
            raise ValueError("completion_candidates must contain candidate objects")
        value = candidate.get("value")
        insert_value = candidate.get("insert_value", value)
        if (not isinstance(value, str) or not value
                or not isinstance(insert_value, str) or not insert_value):
            raise ValueError("completion_candidates require non-empty string value and insert_value")
    if "wiki" in incoming and incoming["wiki"] is not None and not isinstance(incoming["wiki"], dict):
        raise ValueError("wiki must be an object or null")
    supplied_info = incoming.get("tag_info", {})
    if not isinstance(supplied_info, dict):
        raise ValueError("tag_info must be an object")
    if supplied_info.get("name", incoming["tag"]) != incoming["tag"]:
        raise ValueError("tag_info name does not match tag")
    stored_info = (stored or {}).get("tag_info") or {}
    supplied_id = supplied_info.get("id")
    if supplied_id is not None:
        if type(supplied_id) is not int or supplied_id <= 0:
            raise ValueError("tag id must be a positive integer")
        if stored_info.get("id") not in (None, supplied_id):
            raise ValueError("import tag id conflicts with the stored tag")
    merged = {**(stored or {}), **incoming}
    merged["tag_info"] = {
        **stored_info,
        **{key: value for key, value in supplied_info.items() if value is not None},
        "name": incoming["tag"],
    }
    # The merged stored list is not evidence that this import supplied a full
    # list. Preserve the database's existing authority flag in that case.
    merged["_preserve_completion_authority"] = "completion_candidates" not in incoming
    return merged


_UPSERT_TAG = """INSERT INTO tags
    (name, tag_id, slug, category, post_count, updated_at, wiki_other_names,
     aliases, completion_candidates, completion_authoritative, version)
    VALUES (:name, :tag_id, :slug, :category, :post_count, :updated_at, :wiki,
            :aliases, :candidates, COALESCE(:authority, 0), 1)
    ON CONFLICT(name) DO UPDATE SET
        tag_id=excluded.tag_id, slug=excluded.slug, category=excluded.category,
        post_count=excluded.post_count, updated_at=excluded.updated_at,
        wiki_other_names=excluded.wiki_other_names, aliases=excluded.aliases,
        completion_candidates=excluded.completion_candidates,
        completion_authoritative=COALESCE(:authority, tags.completion_authoritative),
        version=tags.version+1"""

_UPSERT_SYNC_STATUS = """INSERT INTO sync_status
    (tag, status, reason, failures, last_sync_time, last_failed_at, version)
    VALUES (?, ?, ?, ?, ?, ?, 1)
    ON CONFLICT(tag) DO UPDATE SET
        status=excluded.status, reason=excluded.reason, failures=excluded.failures,
        last_sync_time=excluded.last_sync_time, last_failed_at=excluded.last_failed_at,
        version=sync_status.version+1"""


def _tag_values(payload: dict) -> dict:
    tag = payload.get("tag")
    if not tag:
        raise ValueError("payload missing 'tag'")
    info = payload.get("tag_info") or {}
    wiki = payload.get("wiki") or {}
    wiki_names = wiki.get("other_names") if isinstance(wiki, dict) else None
    authority = None
    if "completion_candidates" in payload and not payload.get("_preserve_completion_authority"):
        authority = int(isinstance(payload["completion_candidates"], list))
    return {
        "name": tag,
        "tag_id": info.get("id") if isinstance(info, dict) else None,
        "slug": slugify_tag(tag),
        "category": info.get("category") if isinstance(info, dict) else None,
        "post_count": info.get("post_count") if isinstance(info, dict) else None,
        "updated_at": payload.get("updated_at") or now_iso(),
        "wiki": _dumps(wiki_names) if wiki_names else None,
        "aliases": _dumps(payload.get("aliases") or []),
        "candidates": _dumps(payload.get("completion_candidates") or []),
        "authority": authority,
    }


class TagDB:
    """Thread-safe facade over the SQLite tag database.

    Concurrency notes: batch_sync_tags.py syncs with a thread pool, so the
    underlying connection is opened with check_same_thread=False and all
    writes are serialized through a global lock plus WAL journaling.
    """

    def __init__(self, path: Path = DB_PATH):
        self.path = Path(path)
        self._conn: sqlite3.Connection | None = None

    @property
    def conn(self) -> sqlite3.Connection:
        with _write_lock:
            if self._conn is None:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                conn = sqlite3.connect(str(self.path), check_same_thread=False)
                try:
                    conn.execute("PRAGMA journal_mode=WAL")
                    conn.execute("PRAGMA synchronous=NORMAL")
                    conn.executescript(SCHEMA)
                    # Serialize the check-and-alter across processes too.
                    conn.execute("BEGIN IMMEDIATE")
                    columns = {row[1] for row in conn.execute("PRAGMA table_info(tags)")}
                    if "completion_authoritative" not in columns:
                        conn.execute("ALTER TABLE tags ADD COLUMN completion_authoritative INTEGER NOT NULL DEFAULT 0")
                        rows = conn.execute(
                            "SELECT tags.name, tags.completion_candidates, sync_status.status, "
                            "sync_status.last_sync_time FROM tags LEFT JOIN sync_status "
                            "ON sync_status.tag=tags.name"
                        )
                        for name, candidates, status, last_sync_time in rows:
                            if legacy_completion_authoritative(candidates, status, last_sync_time):
                                conn.execute("UPDATE tags SET completion_authoritative=1 WHERE name=?", (name,))
                    columns = {row[1] for row in conn.execute("PRAGMA table_info(sync_queue)")}
                    if "claim_token" not in columns:
                        conn.execute("ALTER TABLE sync_queue ADD COLUMN claim_token TEXT")
                    conn.commit()
                except BaseException:
                    conn.rollback()
                    conn.close()
                    raise
                self._conn = conn
        return self._conn

    def close(self):
        if self._conn is not None:
            with _write_lock:
                self._conn.close()
                self._conn = None

    # ------------------------------------------------------------------
    # tags
    # ------------------------------------------------------------------
    def upsert_tag(self, payload: dict):
        """Insert or update a complete sync payload, including empty lists."""
        values = _tag_values(payload)
        with _write_lock, self.conn:
            self.conn.execute(_UPSERT_TAG, values)

    def upsert_tags_many(self, payloads: list[dict]):
        """Bulk import all supplied payloads in one transaction."""
        rows = [_tag_values(payload) for payload in payloads if payload.get("tag")]
        if not rows:
            return
        with _write_lock, self.conn:
            self.conn.executemany(_UPSERT_TAG, rows)

    def import_tags(self, payloads: list[dict]):
        """Merge partial imports against current records under one write lock.

        BEGIN IMMEDIATE fences other SQLite connections before the first read;
        the process-local lock alone cannot protect against another sync process.
        Any validation or database failure rolls back the entire batch.
        """
        if not payloads:
            return
        with _write_lock:
            conn = self.conn
            conn.execute("BEGIN IMMEDIATE")
            try:
                for incoming in payloads:
                    tag = incoming.get("tag") if isinstance(incoming, dict) else None
                    stored = self.get_tag(tag) if isinstance(tag, str) and tag else None
                    merged = merge_import_payload(stored, incoming)
                    conn.execute(_UPSERT_TAG, _tag_values(merged))
                conn.commit()
            except BaseException:
                conn.rollback()
                raise

    def upsert_tag_categories(self, rows: list[tuple]):
        """Bulk upsert (name, tag_id, category, post_count) into the tags table.

        Only updates the category-related columns; existing completion data
        (completion_candidates / wiki / aliases / updated_at) is preserved.
        New rows are inserted as minimal placeholders with empty candidates.
        """
        if not rows:
            return
        with _write_lock, self.conn:
            self.conn.executemany(
                """INSERT INTO tags
                       (name, tag_id, slug, category, post_count, updated_at,
                        wiki_other_names, aliases, completion_candidates, version)
                   VALUES (?, ?, ?, ?, ?, ?, NULL, '[]', '[]', 1)
                   ON CONFLICT(name) DO UPDATE SET
                       tag_id = excluded.tag_id,
                       category = excluded.category,
                       post_count = excluded.post_count""",
                [
                    (name, tag_id, slugify_tag(name), category, post_count, now_iso())
                    for name, tag_id, category, post_count in rows
                ],
            )
            self.conn.commit()

    @staticmethod
    def _row_to_payload(row) -> dict | None:
        if row is None:
            return None
        (
            name, tag_id, _slug, category, post_count,
            updated_at, wiki_names, aliases, candidates, _version,
        ) = row
        wiki_names_parsed = _loads(wiki_names)
        return {
            "tag": name,
            "updated_at": updated_at,
            "tag_info": {
                "id": tag_id,
                "name": name,
                "category": category,
                "post_count": post_count,
            },
            "wiki": {"other_names": wiki_names_parsed or []}
            if wiki_names_parsed is not None
            else None,
            "aliases": _loads(aliases) or [],
            "completion_candidates": _loads(candidates) or [],
        }

    def get_tag(self, name: str) -> dict | None:
        row = self.conn.execute(
            "SELECT name, tag_id, slug, category, post_count, updated_at, "
            "wiki_other_names, aliases, completion_candidates, version "
            "FROM tags WHERE name = ?",
            (name,),
        ).fetchone()
        return self._row_to_payload(row)

    def has_tag(self, name: str) -> bool:
        return self.conn.execute(
            "SELECT 1 FROM tags WHERE name = ?", (name,)
        ).fetchone() is not None

    def get_tag_by_slug(self, slug: str) -> dict | None:
        row = self.conn.execute(
            "SELECT name, tag_id, slug, category, post_count, updated_at, "
            "wiki_other_names, aliases, completion_candidates, version "
            "FROM tags WHERE slug = ?",
            (slug,),
        ).fetchone()
        return self._row_to_payload(row)

    def list_tags(self) -> list[dict]:
        rows = self.conn.execute(
            "SELECT name, tag_id, slug, category, post_count, updated_at, "
            "wiki_other_names, aliases, completion_candidates, version "
            "FROM tags ORDER BY name"
        ).fetchall()
        return [p for r in rows if (p := self._row_to_payload(r)) is not None]

    def list_successful_tags(self) -> list[str]:
        rows = self.conn.execute(
            "SELECT tag FROM sync_status WHERE status = 'success' ORDER BY tag"
        ).fetchall()
        return [r[0] for r in rows]

    def count_tags(self) -> int:
        return self.conn.execute("SELECT COUNT(*) FROM tags").fetchone()[0]

    def existing_tag_ids(self, tag_ids: list[int]) -> set[int]:
        """Return the subset of `tag_ids` that already exist in the tags table."""
        if not tag_ids:
            return set()
        placeholders = ",".join("?" * len(tag_ids))
        rows = self.conn.execute(
            f"SELECT tag_id FROM tags WHERE tag_id IN ({placeholders})",
            tag_ids,
        ).fetchall()
        return {r[0] for r in rows}


    def delete_tag(self, name: str):
        with _write_lock:
            self.conn.execute("DELETE FROM tags WHERE name = ?", (name,))
            self.conn.commit()

    # ------------------------------------------------------------------
    # sync_status
    # ------------------------------------------------------------------
    def set_sync_status(
        self,
        tag: str,
        status: str,
        reason: str | None = None,
        failures: int | None = None,
        last_sync_time: str | None = None,
        last_failed_at: str | None = None,
    ):
        with _write_lock, self.conn:
            self.conn.execute(
                _UPSERT_SYNC_STATUS,
                (tag, status, reason, failures or 0, last_sync_time, last_failed_at),
            )

    def upsert_sync_status_many(
        self,
        rows: list[tuple],
    ):
        """Bulk insert/update sync_status rows in a single transaction.

        rows: iterable of (tag, status, reason, failures, last_sync_time, last_failed_at)
        """
        if not rows:
            return
        with _write_lock, self.conn:
            self.conn.executemany(
                """INSERT INTO sync_status
                       (tag, status, reason, failures, last_sync_time, last_failed_at, version)
                   VALUES (?, ?, ?, ?, ?, ?, 1)
                   ON CONFLICT(tag) DO UPDATE SET
                       status = excluded.status,
                       reason = excluded.reason,
                       failures = excluded.failures,
                       last_sync_time = excluded.last_sync_time,
                       last_failed_at = excluded.last_failed_at,
                       version = sync_status.version + 1""",
                rows,
            )
            self.conn.commit()

    def get_sync_status(self, tag: str) -> dict | None:
        row = self.conn.execute(
            "SELECT tag, status, reason, failures, last_sync_time, last_failed_at, version "
            "FROM sync_status WHERE tag = ?",
            (tag,),
        ).fetchone()
        if row is None:
            return None
        return {
            "tag": row[0],
            "status": row[1],
            "reason": row[2],
            "failures": row[3],
            "last_sync_time": row[4],
            "last_failed_at": row[5],
            "version": row[6],
        }

    def list_sync_status(self, status: str | None = None) -> dict[str, dict]:
        columns = (
            "tag, status, reason, failures, last_sync_time, last_failed_at, version"
        )
        if status is None:
            rows = self.conn.execute(
                f"SELECT {columns} FROM sync_status"
            ).fetchall()
        else:
            rows = self.conn.execute(
                f"SELECT {columns} FROM sync_status WHERE status = ?",
                (status,),
            ).fetchall()
        return {
            r[0]: {
                "tag": r[0],
                "status": r[1],
                "reason": r[2],
                "failures": r[3],
                "last_sync_time": r[4],
                "last_failed_at": r[5],
                "version": r[6],
            }
            for r in rows
        }

    def remove_sync_status(self, tag: str):
        with _write_lock:
            self.conn.execute("DELETE FROM sync_status WHERE tag = ?", (tag,))
            self.conn.commit()

    # ------------------------------------------------------------------
    # api cursor
    # ------------------------------------------------------------------
    def load_cursor(self) -> dict:
        row = self.conn.execute(
            "SELECT min_id, max_id, updated_at FROM api_cursor WHERE id = 1"
        ).fetchone()
        if row is None:
            return {}
        mid, mad, updated_at = row
        return {
            "min_id": mid if isinstance(mid, int) else None,
            "max_id": mad if isinstance(mad, int) else None,
            "updated_at": updated_at,
        }

    def clear_cursor(self):
        with _write_lock:
            self.conn.execute("DELETE FROM api_cursor WHERE id = 1")
            self.conn.commit()

    def save_cursor(self, cursor: dict):
        mid = cursor.get("min_id")
        mad = cursor.get("max_id")
        if not isinstance(mid, int) or not isinstance(mad, int):
            return
        with _write_lock:
            self.conn.execute(
                """INSERT INTO api_cursor (id, min_id, max_id, updated_at)
                   VALUES (1, ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET
                       min_id = excluded.min_id,
                       max_id = excluded.max_id,
                       updated_at = excluded.updated_at""",
                (mid, mad, now_iso()),
            )
            self.conn.commit()

    # ------------------------------------------------------------------
    # sync metadata (keyed by slug, matches view.load_sync_metadata format)
    # ------------------------------------------------------------------
    def load_metadata(self) -> dict:
        rows = self.conn.execute(
            "SELECT slug, tag, last_sync_time, version FROM sync_metadata"
        ).fetchall()
        return {
            slug: {"tag": tag, "last_sync_time": last_sync_time, "version": version}
            for slug, tag, last_sync_time, version in rows
            if slug
        }

    def save_metadata(self, metadata: dict):
        """metadata: {slug: {"tag": str, "last_sync_time": str, "version": int}}"""
        with _write_lock, self.conn:
            self.conn.executemany(
                """INSERT INTO sync_metadata (slug, tag, last_sync_time, version)
                   VALUES (?, ?, ?, ?)
                   ON CONFLICT(slug) DO UPDATE SET
                       tag = excluded.tag,
                       last_sync_time = excluded.last_sync_time,
                       version = excluded.version""",
                [
                    (
                        slug,
                        (entry.get("tag") if isinstance(entry, dict) else None) or slug,
                        entry.get("last_sync_time") if isinstance(entry, dict) else None,
                        entry.get("version") if isinstance(entry, dict) else 1,
                    )
                    for slug, entry in metadata.items()
                ],
            )
            self.conn.commit()

    # ------------------------------------------------------------------
    # sync_queue (producer/consumer pipeline)
    # ------------------------------------------------------------------
    def enqueue_many(self, rows: list[tuple]):
        """rows: (tag_id, name, created_at). INSERT OR IGNORE by tag_id."""
        if not rows:
            return 0
        with _write_lock:
            cur = self.conn.executemany(
                """INSERT OR IGNORE INTO sync_queue
                       (tag_id, name, created_at, status, enqueued_at)
                   VALUES (?, ?, ?, 'pending', ?)""",
                [
                    (tid, name, created_at, now_iso())
                    for tid, name, created_at in rows
                    if tid is not None
                ],
            )
            self.conn.commit()
            return cur.rowcount

    def requeue_many(self, rows: list[tuple], *, claim_seconds: int = 600) -> int:
        """Explicitly resync completed tags, preserving unexpired claims.

        The stored payload remains intact. Marking the last attempt as pending
        makes the consumer refresh it without requiring a separate --force flag.
        """
        import time

        rows = [(tid, name, created) for tid, name, created in rows
                if tid is not None and name]
        if not rows:
            return 0
        now = time.time()
        with _write_lock, self.conn:
            cursor = self.conn.executemany(
                """INSERT INTO sync_queue
                       (tag_id, name, created_at, status, enqueued_at)
                   VALUES (?, ?, ?, 'pending', ?)
                   ON CONFLICT(tag_id) DO UPDATE SET
                       name=excluded.name, created_at=excluded.created_at,
                       status='pending', enqueued_at=excluded.enqueued_at,
                       claimed_by=NULL, claimed_at=NULL, claim_token=NULL, done_at=NULL
                   WHERE sync_queue.status != 'claimed'
                      OR sync_queue.claimed_at IS NULL
                      OR ? - sync_queue.claimed_at > ?""",
                [(tid, name, created, now_iso(), now, claim_seconds)
                 for tid, name, created in rows],
            )
            count = cursor.rowcount
            self.conn.executemany(
                """UPDATE sync_status
                   SET status='pending', reason=NULL, failures=0,
                       last_failed_at=NULL, version=version+1
                   WHERE tag=? AND EXISTS (
                       SELECT 1 FROM sync_queue
                       WHERE tag_id=? AND name=? AND status='pending'
                   )""",
                [(name, tid, name) for tid, name, _ in rows],
            )
            return count

    def requeue_failed(self) -> int:
        """Retry failed queue items on the next sync run, unless blocked."""
        with _write_lock:
            cur = self.conn.execute(
                """UPDATE sync_queue
                   SET status='pending', claimed_by=NULL, claimed_at=NULL, claim_token=NULL, done_at=NULL
                   WHERE status='failed' AND NOT EXISTS (
                       SELECT 1 FROM sync_status
                       WHERE sync_status.tag=sync_queue.name
                         AND sync_status.status='blocked'
                   )"""
            )
            self.conn.commit()
            return cur.rowcount

    def claim_batch(self, limit: int = 10, claimer: str = "syncer",
                    claim_seconds: int = 600) -> list[QueueClaim]:
        """Atomically claim up to `limit` pending queue rows.

        Uses BEGIN IMMEDIATE so only one process/thread claims a given row.
        Rows claimed longer than `claim_seconds` ago are treated as abandoned
        (crashed consumer) and reclaimed.
        """
        import time as _t
        now = _t.time()
        token = uuid4().hex
        with _write_lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                self.conn.execute(
                    "UPDATE sync_queue SET status='claimed', claimed_by=?, claimed_at=?, claim_token=?, done_at=NULL "
                    "WHERE tag_id IN (SELECT tag_id FROM sync_queue "
                    "  WHERE status='pending' "
                    "     OR (status='claimed' AND claimed_at IS NOT NULL AND ? - claimed_at > ?) "
                    "  ORDER BY tag_id LIMIT ?)",
                    (claimer, now, token, now, claim_seconds, limit),
                )
                rows = self.conn.execute(
                    "SELECT tag_id, name, created_at, claim_token FROM sync_queue "
                    "WHERE status='claimed' AND claim_token=? "
                    "ORDER BY tag_id LIMIT ?",
                    (token, limit),
                ).fetchall()
                self.conn.commit()
            except Exception:
                self.conn.rollback()
                raise
            return [QueueClaim(*row) for row in rows]

    def complete_claim(self, claim: QueueClaim, status: str, *, payload: dict | None = None,
                       error: str | None = None, max_failures: int = 5) -> str:
        """Fence all result writes with the current lease in one transaction.

        Expiry makes a lease reclaimable; its token becomes invalid as soon as
        another producer or consumer replaces it. A late success, failure, or
        blocked result then has no effect on any table.
        """
        if not isinstance(claim, QueueClaim) or not claim.token:
            raise ValueError("completion requires the claim returned by claim_batch")
        if status not in ("synced", "failed", "skipped", "blocked"):
            raise ValueError(f"invalid completion status: {status}")
        with _write_lock:
            conn = self.conn
            conn.execute("BEGIN IMMEDIATE")
            try:
                owned = conn.execute(
                    "SELECT 1 FROM sync_queue WHERE tag_id=? AND name=? "
                    "AND status='claimed' AND claim_token=?",
                    (claim.tag_id, claim.name, claim.token),
                ).fetchone()
                if owned is None:
                    conn.rollback()
                    return "stale"

                timestamp = now_iso()
                if status == "synced":
                    if payload is None or payload.get("tag") != claim.name:
                        raise ValueError("sync payload does not match the claimed tag")
                    conn.execute(_UPSERT_TAG, _tag_values(payload))
                    conn.execute(_UPSERT_SYNC_STATUS,
                                 (claim.name, "success", None, 0, timestamp, None))
                elif status == "failed":
                    previous = conn.execute(
                        "SELECT failures, last_sync_time FROM sync_status WHERE tag=?",
                        (claim.name,),
                    ).fetchone()
                    failures = (previous[0] if previous else 0) + 1
                    status = "blocked" if failures >= max_failures else "failed"
                    conn.execute(_UPSERT_SYNC_STATUS,
                                 (claim.name, status, error, failures,
                                  previous[1] if previous else None, timestamp))

                conn.execute(
                    "UPDATE sync_queue SET status=?, done_at=? WHERE tag_id=? AND claim_token=?",
                    (status, timestamp, claim.tag_id, claim.token),
                )
                conn.commit()
                return status
            except BaseException:
                conn.rollback()
                raise

    def mark_done(self, tag_id: int, status: str):
        """Legacy unclaimed-row update; active workers must use complete_claim."""
        with _write_lock:
            self.conn.execute(
                "UPDATE sync_queue SET status=?, done_at=? WHERE tag_id=? AND status!='claimed'",
                (status, now_iso(), tag_id),
            )
            self.conn.commit()

    def queue_count(self, status: str | None = None) -> int:
        if status is None:
            n = self.conn.execute("SELECT COUNT(*) FROM sync_queue").fetchone()[0]
        else:
            n = self.conn.execute(
                "SELECT COUNT(*) FROM sync_queue WHERE status=?", (status,)
            ).fetchone()[0]
        return n

    def queue_status_counts(self) -> dict:
        rows = self.conn.execute(
            "SELECT status, COUNT(*) FROM sync_queue GROUP BY status"
        ).fetchall()
        return {r[0]: r[1] for r in rows}

    def queue_pending_ids(self) -> set[int]:
        rows = self.conn.execute(
            "SELECT tag_id FROM sync_queue WHERE status='pending'"
        ).fetchall()
        return {r[0] for r in rows}

    def drop_queue(self):
        with _write_lock:
            self.conn.execute("DELETE FROM sync_queue")
            self.conn.commit()

    # ------------------------------------------------------------------
    # checkpoint
    # ------------------------------------------------------------------
    def load_checkpoint(self) -> dict | None:
        row = self.conn.execute(
            "SELECT data FROM checkpoint WHERE id = 1"
        ).fetchone()
        if row is None:
            return None
        return _loads(row[0])

    def save_checkpoint(self, data: dict):
        with _write_lock:
            self.conn.execute(
                """INSERT INTO checkpoint (id, data) VALUES (1, ?)
                   ON CONFLICT(id) DO UPDATE SET data = excluded.data""",
                (_dumps(data),),
            )
            self.conn.commit()


# Module-level singleton so all scripts share one connection/thread-safety.
db = TagDB()

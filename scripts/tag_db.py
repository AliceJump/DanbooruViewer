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
        if self._conn is None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(str(self.path), check_same_thread=False)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            conn.executescript(SCHEMA)
            conn.commit()
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
        """Insert or update a tag row from a sync payload (view.sync_data)."""
        tag = payload.get("tag")
        if not tag:
            raise ValueError("payload missing 'tag'")
        tag_info = payload.get("tag_info") or {}
        wiki = payload.get("wiki") or {}
        wiki_names = wiki.get("other_names") if isinstance(wiki, dict) else None

        with _write_lock:
            self.conn.execute(
                """INSERT INTO tags
                       (name, tag_id, slug, category, post_count, updated_at,
                        wiki_other_names, aliases, completion_candidates, version)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                   ON CONFLICT(name) DO UPDATE SET
                       tag_id = excluded.tag_id,
                       slug = excluded.slug,
                       category = excluded.category,
                       post_count = excluded.post_count,
                       updated_at = excluded.updated_at,
                       wiki_other_names = excluded.wiki_other_names,
                       aliases = excluded.aliases,
                       completion_candidates = excluded.completion_candidates,
                       version = tags.version + 1""",
                (
                    tag,
                    tag_info.get("id") if isinstance(tag_info, dict) else None,
                    slugify_tag(tag),
                    tag_info.get("category") if isinstance(tag_info, dict) else None,
                    tag_info.get("post_count") if isinstance(tag_info, dict) else None,
                    payload.get("updated_at") or now_iso(),
                    _dumps(wiki_names) if wiki_names else None,
                    _dumps(payload.get("aliases") or []),
                    _dumps(payload.get("completion_candidates") or []),
                ),
            )
            self.conn.commit()

    def upsert_tags_many(self, payloads: list[dict]):
        """Bulk insert/update tags from payload dicts in a single transaction."""
        if not payloads:
            return
        rows = []
        for payload in payloads:
            tag = payload.get("tag")
            if not tag:
                continue
            tag_info = payload.get("tag_info") or {}
            wiki = payload.get("wiki") or {}
            wiki_names = wiki.get("other_names") if isinstance(wiki, dict) else None
            rows.append(
                (
                    tag,
                    tag_info.get("id") if isinstance(tag_info, dict) else None,
                    slugify_tag(tag),
                    tag_info.get("category") if isinstance(tag_info, dict) else None,
                    tag_info.get("post_count") if isinstance(tag_info, dict) else None,
                    payload.get("updated_at") or now_iso(),
                    _dumps(wiki_names) if wiki_names else None,
                    _dumps(payload.get("aliases") or []),
                    _dumps(payload.get("completion_candidates") or []),
                )
            )
        if not rows:
            return
        with _write_lock:
            self.conn.executemany(
                """INSERT INTO tags
                       (name, tag_id, slug, category, post_count, updated_at,
                        wiki_other_names, aliases, completion_candidates, version)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                   ON CONFLICT(name) DO UPDATE SET
                       tag_id = excluded.tag_id,
                       slug = excluded.slug,
                       category = excluded.category,
                       post_count = excluded.post_count,
                       updated_at = excluded.updated_at,
                       wiki_other_names = excluded.wiki_other_names,
                       aliases = excluded.aliases,
                       completion_candidates = excluded.completion_candidates,
                       version = tags.version + 1""",
                rows,
            )
            self.conn.commit()

    def upsert_tag_categories(self, rows: list[tuple]):
        """Bulk upsert (name, tag_id, category, post_count) into the tags table.

        Only updates the category-related columns; existing completion data
        (completion_candidates / wiki / aliases / updated_at) is preserved.
        New rows are inserted as minimal placeholders with empty candidates.
        """
        if not rows:
            return
        with _write_lock:
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
        with _write_lock:
            self.conn.execute(
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
                (tag, status, reason, failures or 0, last_sync_time, last_failed_at),
            )
            self.conn.commit()

    def upsert_sync_status_many(
        self,
        rows: list[tuple],
    ):
        """Bulk insert/update sync_status rows in a single transaction.

        rows: iterable of (tag, status, reason, failures, last_sync_time, last_failed_at)
        """
        if not rows:
            return
        with _write_lock:
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
        with _write_lock:
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

    def claim_batch(self, limit: int = 10, claimer: str = "syncer",
                    claim_seconds: int = 600) -> list[tuple]:
        """Atomically claim up to `limit` pending queue rows.

        Uses BEGIN IMMEDIATE so only one process/thread claims a given row.
        Rows claimed longer than `claim_seconds` ago are treated as abandoned
        (crashed consumer) and reclaimed.
        """
        import time as _t
        now = _t.time()
        with _write_lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                self.conn.execute(
                    "UPDATE sync_queue SET status='claimed', claimed_by=?, claimed_at=?, done_at=NULL "
                    "WHERE tag_id IN (SELECT tag_id FROM sync_queue "
                    "  WHERE status='pending' "
                    "     OR (status='claimed' AND claimed_at IS NOT NULL AND ? - claimed_at > ?) "
                    "  ORDER BY tag_id LIMIT ?)",
                    (claimer, now, now, claim_seconds, limit),
                )
                rows = self.conn.execute(
                    "SELECT tag_id, name, created_at FROM sync_queue "
                    "WHERE status='claimed' AND claimed_by=? AND claimed_at>=? "
                    "ORDER BY tag_id LIMIT ?",
                    (claimer, now - 1, limit),
                ).fetchall()
                self.conn.commit()
            except Exception:
                self.conn.rollback()
                raise
            return [(r[0], r[1], r[2]) for r in rows]

    def mark_done(self, tag_id: int, status: str):
        with _write_lock:
            self.conn.execute(
                "UPDATE sync_queue SET status=?, done_at=? WHERE tag_id=?",
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

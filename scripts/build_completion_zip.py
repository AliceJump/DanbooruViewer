#!/usr/bin/env python3
"""Build the compact Danbooru completion zip shipped inside the app.

Data sources, in order of authority for each tag:
  1. crawler SQLite db (cache/danbooru_tags.db) -- completion_candidates column
  2. previously shipped seed db (assets/danbooru_completion.db)
  3. previously shipped legacy zip (assets/danbooru_completion.zip)

Crawler tags with valid candidates, or a committed explicit empty candidate
list, replace the whole legacy candidate group for that tag. Category
placeholders and tags absent from the crawler DB retain legacy fallback data.

The compact JSON entries carry the tag category (`c`) so the app can group
completion suggestions by category without a database.
"""
import argparse
from contextlib import ExitStack
import hashlib
import json
import sqlite3
import sys
import time
import os
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

if __package__:
    from .build_completion_index import (
        FORMAT_VERSION as INDEX_FORMAT_VERSION,
        build_index,
        file_sha256,
    )
    from .completion_normalization import normalize_completion_key
    from .tag_db import legacy_completion_authoritative
else:
    from build_completion_index import (
        FORMAT_VERSION as INDEX_FORMAT_VERSION,
        build_index,
        file_sha256,
    )
    from completion_normalization import normalize_completion_key
    from tag_db import legacy_completion_authoritative

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# ========================
# JSON backend (orjson优先)
# ========================
try:
    import orjson

    def json_load(path: Path):
        return orjson.loads(path.read_bytes())

    def json_dump(obj):
        return orjson.dumps(obj, option=orjson.OPT_NON_STR_KEYS)

except ImportError:
    def json_load(path: Path):
        return json.loads(path.read_bytes().decode("utf-8"))

    def json_dump(obj):
        return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


# ========================
# tqdm optional
# ========================
try:
    from tqdm import tqdm
    HAVE_TQDM = True
except ImportError:
    HAVE_TQDM = False


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_FILE = ROOT / "assets" / "danbooru_completion.zip"
TEMP_OUTPUT_FILE = OUTPUT_FILE.with_suffix(".zip.tmp")
MANIFEST_FILE = OUTPUT_FILE.with_suffix(".manifest.json")
INDEX_FILE = ROOT / "assets" / "danbooru_completion.index.zip"
BOOTSTRAP_FILE = ROOT / "assets" / "danbooru_completion.bootstrap.json"
COMPACT_FILE = "completion_candidates.json"

# Crawler-side SQLite database (kept; the source of tag + category data).
TAG_DB = ROOT / "cache" / "danbooru_tags.db"
# Legacy seed database that used to be shipped inside the app.
SEED_DB = ROOT / "assets" / "danbooru_completion.db"


def chunked(values: list, size: int):
    for index in range(0, len(values), size):
        yield values[index:index + size]


def _loads_json(value):
    if not value:
        return None
    try:
        return json.loads(value)
    except Exception:
        return None


class _ExportSnapshot(ExitStack):
    """Share read-only transactions until fingerprinting and merging finish."""

    def __init__(self):
        super().__init__()
        self._connections = {}

    def connection(self, path):
        # Open lazily so an unchanged export need not reload candidate data.
        if path not in self._connections:
            conn = None
            if path.exists():
                conn = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
                self.callback(conn.close)
                # Deferred/read-only: WAL writers can still commit. Subsequent
                # SELECTs see the same snapshot as this connection's first read.
                conn.execute("BEGIN")
            self._connections[path] = conn
        return self._connections[path]


# ========================
# candidate sources
# ========================
def load_candidates_from_db(snapshot=None) -> list[tuple]:
    """Candidates from the crawler SQLite db (tags.completion_candidates).

    Each candidate is a 5-tuple (value, insert_value, source, score, category).
    """
    if snapshot is None:
        with _ExportSnapshot() as snapshot:
            return load_candidates_from_db(snapshot)
    conn = snapshot.connection(TAG_DB)
    if conn is None:
        return []
    rows = conn.execute(
        "SELECT completion_candidates, category FROM tags "
        "WHERE completion_candidates IS NOT NULL"
    ).fetchall()

    result = []
    for payload_json, category in rows:
        candidates = _loads_json(payload_json)
        if not isinstance(candidates, list) or not candidates:
            continue
        for c in candidates:
            if not isinstance(c, dict):
                continue
            v = c.get("value")
            i = c.get("insert_value", v)
            if not isinstance(v, str) or not isinstance(i, str):
                continue
            if not v or not i:
                continue
            result.append((
                sys.intern(v),
                sys.intern(i),
                c.get("source") if isinstance(c.get("source"), str) else "",
                c.get("score") if isinstance(c.get("score"), int) else 0,
                category if isinstance(category, int) else None,
            ))
    return result


def _seed_rows(conn):
    """Use the same row representation for legacy suggestions and their hash."""
    try:
        rows = conn.execute(
            "SELECT value, insert_value, source, score, category "
            "FROM completion_candidates"
        )
    except sqlite3.OperationalError:
        rows = conn.execute(
            "SELECT value, insert_value, source, score, NULL "
            "FROM completion_candidates"
        )
    for v, i, s, r, c in rows:
        if isinstance(v, str) and isinstance(i, str) and v and i:
            yield (
                sys.intern(v),
                sys.intern(i),
                s if isinstance(s, str) else "",
                r if isinstance(r, int) else 0,
                c if isinstance(c, int) else None,
            )


def load_candidates_from_seed_db(snapshot=None) -> list[tuple]:
    """Candidates from the legacy seed database (kept until migrated)."""
    if snapshot is None:
        with _ExportSnapshot() as snapshot:
            return load_candidates_from_seed_db(snapshot)
    conn = snapshot.connection(SEED_DB)
    if conn is None:
        return []
    return list(_seed_rows(conn))


def load_candidates_from_legacy_zip() -> list[tuple]:
    """Candidates from the previously shipped zip (no category)."""
    if not OUTPUT_FILE.exists():
        return []
    try:
        with ZipFile(OUTPUT_FILE, "r") as archive:
            raw = archive.read(COMPACT_FILE)
    except Exception:
        return []
    compact = _loads_json(raw)
    if not isinstance(compact, list):
        return []
    result = []
    for item in compact:
        if not isinstance(item, dict):
            continue
        v = item.get("v") or item.get("value")
        i = item.get("i") or item.get("insert_value") or v
        if not isinstance(v, str) or not isinstance(i, str):
            continue
        if not v or not i:
            continue
        result.append((
            sys.intern(v),
            sys.intern(i),
            item.get("s") if isinstance(item.get("s"), str) else "",
            item.get("r") if isinstance(item.get("r"), int) else 0,
            item.get("c") if isinstance(item.get("c"), int) else None,
        ))
    return result


def load_category_map(snapshot=None) -> dict[str, int]:
    """name -> category map from the crawler SQLite db."""
    if snapshot is None:
        with _ExportSnapshot() as snapshot:
            return load_category_map(snapshot)
    conn = snapshot.connection(TAG_DB)
    if conn is None:
        return {}
    rows = conn.execute(
        "SELECT name, category FROM tags WHERE category IS NOT NULL"
    ).fetchall()
    return {name: cat for name, cat in rows}


def _authority_rows(conn):
    """Read old databases without migrating or modifying an export input."""
    columns = {row[1] for row in conn.execute("PRAGMA table_info(tags)")}
    if "completion_authoritative" in columns:
        yield from conn.execute(
            "SELECT name, category, completion_candidates, completion_authoritative "
            "FROM tags ORDER BY name"
        )
    else:
        rows = conn.execute(
            "SELECT tags.name, tags.category, tags.completion_candidates, "
            "sync_status.status, sync_status.last_sync_time FROM tags "
            "LEFT JOIN sync_status ON sync_status.tag=tags.name ORDER BY tags.name"
        )
        for name, category, candidates, status, last_sync_time in rows:
            yield name, category, candidates, int(
                legacy_completion_authoritative(candidates, status, last_sync_time)
            )


def load_authoritative_tag_names(snapshot=None) -> set[str]:
    """Committed empty lists stay authoritative through later retries."""
    if snapshot is None:
        with _ExportSnapshot() as snapshot:
            return load_authoritative_tag_names(snapshot)
    conn = snapshot.connection(TAG_DB)
    if conn is None:
        return set()
    return {
        normalize_completion_key(name)
        for name, _category, candidates, authoritative in _authority_rows(conn)
        if authoritative and isinstance(_loads_json(candidates), list)
    }


def build_suggestions(snapshot=None) -> dict:
    """Prefer each tag's current candidate group, falling back only for gaps."""
    if snapshot is None:
        with _ExportSnapshot() as snapshot:
            return build_suggestions(snapshot)
    sources = []
    db_candidates = load_candidates_from_db(snapshot)
    if db_candidates:
        sources.append(("crawler database", db_candidates))
    seed_candidates = load_candidates_from_seed_db(snapshot)
    if seed_candidates:
        sources.append(("legacy seed db", seed_candidates))
    zip_candidates = load_candidates_from_legacy_zip()
    if zip_candidates:
        sources.append(("legacy zip", zip_candidates))
    authoritative = load_authoritative_tag_names(snapshot)
    if not sources and not authoritative:
        raise SystemExit(
            "no completion data found (crawler db / seed db / legacy zip all empty)"
        )

    for name, cands in sources:
        print(f"📂 source {name}: {len(cands):,} candidates")
    category_map = load_category_map(snapshot)
    suggestions = {}
    for source_name, candidates in sources:
        source_tags = set()
        for v, i, s, r, cat in candidates:
            tag_key = normalize_completion_key(i)
            if source_name != "crawler database" and tag_key in authoritative:
                continue
            source_tags.add(tag_key)
            key = (normalize_completion_key(v), tag_key)
            old = suggestions.get(key)
            if old is None or r > old[3]:
                cat = category_map.get(i, category_map.get(tag_key, cat))
                suggestions[key] = (v, i, s, r, cat)
        authoritative.update(source_tags)
    return suggestions


# ========================
# signature / manifest
# ========================
def _rows_digest(rows):
    digest = hashlib.sha256()
    for row in rows:
        digest.update(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def db_fingerprint(snapshot=None) -> dict:
    """Hash actual export inputs, including changes that preserve row counts.

    The legacy ZIP is both a fallback input and an output. After replacing it,
    main records its new hash without changing the captured DB input identity.
    """
    if snapshot is None:
        with _ExportSnapshot() as snapshot:
            return db_fingerprint(snapshot)
    crawler = snapshot.connection(TAG_DB)
    seed = snapshot.connection(SEED_DB)
    return {
        "version": 4,
        "seed_db": {
            # Hash the rows this transaction reads, not changing DB/WAL files.
            "sha256": _rows_digest(_seed_rows(seed)) if seed is not None else None,
        },
        "legacy_zip_sha256": file_sha256(OUTPUT_FILE) if OUTPUT_FILE.exists() else None,
        "crawler_sha256": _rows_digest(_authority_rows(crawler)) if crawler is not None else None,
    }


def load_manifest() -> dict | None:
    if not MANIFEST_FILE.exists():
        return None
    try:
        payload = json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def write_manifest(signature: dict, item_count: int, output_size: int):
    MANIFEST_FILE.write_text(
        json.dumps(
            {
                "signature": signature,
                "items": item_count,
                "output_size": output_size,
                "updated_at": int(time.time()),
                "index_version": INDEX_FORMAT_VERSION,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


def _progress_bar(total: int, desc: str):
    if HAVE_TQDM:
        return tqdm(total=total, desc=desc, unit="item")
    return _SimpleProgress(total, desc)


class _SimpleProgress:
    def __init__(self, total: int, desc: str):
        self.total = total
        self.desc = desc
        self.n = 0
        self.start = time.time()
        self.last = 0

    def update(self, x=1):
        self.n += x
        now = time.time()

        if now - self.last < 0.1 and self.n < self.total:
            return

        self.last = now
        pct = self.n / self.total * 100
        elapsed = now - self.start
        eta = (elapsed / self.n * (self.total - self.n)) if self.n else 0

        bar_len = 30
        fill = int(bar_len * self.n / self.total)
        bar = "█" * fill + "░" * (bar_len - fill)

        sys.stderr.write(
            f"\r{self.desc}: |{bar}| {self.n}/{self.total} "
            f"({pct:5.1f}%) [{_fmt(elapsed)}<{_fmt(eta)}]"
        )

        if self.n >= self.total:
            sys.stderr.write("\n")

    def close(self):
        if self.n < self.total:
            self.update(self.total - self.n)


def _fmt(s):
    m, s = divmod(int(s), 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build the compact Danbooru completion zip."
    )
    parser.add_argument(
        "--compresslevel",
        type=int,
        default=3,
        choices=range(0, 10),
        metavar="0-9",
        help="Zip compression level. Default 3 is much faster than 9.",
    )
    parser.add_argument(
        "--store",
        action="store_true",
        help="Store JSON in the zip without deflate compression. Fastest and best for frequent local builds.",
    )
    parser.add_argument(
        "--best",
        action="store_true",
        help="Use maximum compression level 9.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Rebuild even if the input signature did not change.",
    )
    parser.add_argument(
        "--clean-legacy",
        action="store_true",
        help="Delete the legacy seed database (.db) and legacy zip after building.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    compression = "stored" if args.store else "deflated"
    compresslevel = None if args.store else (9 if args.best else args.compresslevel)

    with _ExportSnapshot() as snapshot:
        signature = db_fingerprint(snapshot)
        manifest = load_manifest()
        unchanged = (
            not args.force
            and OUTPUT_FILE.exists()
            and manifest is not None
            and manifest.get("signature") == signature
        )
        if not unchanged:
            print(f"📂 building (compression={compression}{'' if compresslevel is None else f':{compresslevel}'})")
            suggestions = build_suggestions(snapshot)
    # Release the read transactions before ZIP/index compression and output I/O.
    if unchanged:
        print(
            f"✅ unchanged: {OUTPUT_FILE} "
            f"({manifest.get('items', 0):,} items, {manifest.get('output_size', 0):,} bytes)"
        )
        # A legacy JSON ZIP can be unchanged while its new index is absent,
        # stale, or from an older format. The index builder checks its version,
        # source hash, and generated-file identity before skipping work.
        build_index(OUTPUT_FILE, INDEX_FILE, BOOTSTRAP_FILE)
        if manifest.get("index_version") != INDEX_FORMAT_VERSION:
            write_manifest(signature, manifest.get("items", 0), OUTPUT_FILE.stat().st_size)
        if args.clean_legacy:
            _clean_legacy()
        return

    print(f"⚙️ merge {len(suggestions)}")
    sorted_list = sorted(
        suggestions.values(),
        key=lambda x: (-x[3], x[0]),
    )

    compact = [
        {"v": v, "i": i, "s": s, "r": r}
        | ({"c": c} if c is not None else {})
        for v, i, s, r, c in sorted_list
    ]

    print("🗜 writing zip...")
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)

    compact_json = json_dump(compact)

    compression_type = ZIP_STORED if args.store else ZIP_DEFLATED
    zip_kwargs = {}
    if not args.store:
        zip_kwargs["compresslevel"] = compresslevel

    with ZipFile(TEMP_OUTPUT_FILE, "w", compression_type, **zip_kwargs) as z:
        z.writestr(COMPACT_FILE, compact_json)

    TEMP_OUTPUT_FILE.replace(OUTPUT_FILE)

    size = OUTPUT_FILE.stat().st_size
    signature["legacy_zip_sha256"] = file_sha256(OUTPUT_FILE)
    write_manifest(signature, len(compact), size)
    build_index(
        OUTPUT_FILE, INDEX_FILE, BOOTSTRAP_FILE,
        candidates=sorted_list, force=True,
    )

    print(f"✅ done: {len(compact)} items with categories, {size:,} bytes -> {OUTPUT_FILE}")

    if args.clean_legacy:
        _clean_legacy()


def _clean_legacy():
    removed = 0
    try:
        SEED_DB.unlink()
        removed += 1
    except FileNotFoundError:
        pass
    except OSError as exc:
        print(f"  [WARN] cannot delete {SEED_DB}: {exc}")
    if removed:
        print(f"🗑 removed legacy seed database: {SEED_DB}")


if __name__ == "__main__":
    main()

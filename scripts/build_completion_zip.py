#!/usr/bin/env python3
"""Build the compact Danbooru completion zip shipped inside the app.

Data sources (first non-empty wins):
  1. crawler SQLite db (cache/danbooru_tags.db) -- completion_candidates column
  2. previously shipped seed db (assets/danbooru_completion.db)
  3. previously shipped legacy zip (assets/danbooru_completion.zip)

The compact JSON entries carry the tag category (`c`) so the app can group
completion suggestions by category without a database.
"""
import argparse
import hashlib
import json
import sqlite3
import sys
import time
import os
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

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


# ========================
# candidate sources
# ========================
def load_candidates_from_db() -> list[tuple]:
    """Candidates from the crawler SQLite db (tags.completion_candidates).

    Each candidate is a 5-tuple (value, insert_value, source, score, category).
    """
    if not TAG_DB.exists():
        return []
    try:
        conn = sqlite3.connect(f"file:{TAG_DB}?mode=ro", uri=True)
    except Exception:
        conn = sqlite3.connect(str(TAG_DB))
    try:
        rows = conn.execute(
            "SELECT completion_candidates, category FROM tags "
            "WHERE completion_candidates IS NOT NULL"
        ).fetchall()
    finally:
        conn.close()

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


def load_candidates_from_seed_db() -> list[tuple]:
    """Candidates from the legacy seed database (kept until migrated)."""
    if not SEED_DB.exists():
        return []
    try:
        conn = sqlite3.connect(f"file:{SEED_DB}?mode=ro", uri=True)
    except Exception:
        conn = sqlite3.connect(str(SEED_DB))
    try:
        try:
            rows = conn.execute(
                "SELECT value, insert_value, source, score, category "
                "FROM completion_candidates"
            ).fetchall()
        except sqlite3.OperationalError:
            rows = conn.execute(
                "SELECT value, insert_value, source, score, NULL "
                "FROM completion_candidates"
            ).fetchall()
    finally:
        conn.close()
    return [
        (
            sys.intern(v),
            sys.intern(i),
            s if isinstance(s, str) else "",
            r if isinstance(r, int) else 0,
            c if isinstance(c, int) else None,
        )
        for v, i, s, r, c in rows
        if isinstance(v, str) and isinstance(i, str) and v and i
    ]


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


def load_category_map() -> dict[str, int]:
    """name -> category map from the crawler SQLite db."""
    if not TAG_DB.exists():
        return {}
    try:
        conn = sqlite3.connect(f"file:{TAG_DB}?mode=ro", uri=True)
    except Exception:
        conn = sqlite3.connect(str(TAG_DB))
    try:
        rows = conn.execute(
            "SELECT name, category FROM tags WHERE category IS NOT NULL"
        ).fetchall()
    finally:
        conn.close()
    return {name: cat for name, cat in rows}


def build_suggestions() -> dict:
    """Merge candidates, keep best score per (value, insert_value)."""
    candidates = load_candidates_from_db()
    source = "crawler database"
    if not candidates:
        candidates = load_candidates_from_seed_db()
        source = "legacy seed db"
    if not candidates:
        candidates = load_candidates_from_legacy_zip()
        source = "legacy zip"
    if not candidates:
        raise SystemExit(
            "no completion data found (crawler db / seed db / legacy zip all empty)"
        )

    print(f"📂 sources: {source} ({len(candidates):,} candidates)")
    category_map = load_category_map()

    suggestions = {}
    for v, i, s, r, cat in candidates:
        key = (v.lower(), i.lower())
        old = suggestions.get(key)
        if old is None or r > old[3]:
            if cat is None:
                cat = category_map.get(i.lower()) or category_map.get(i)
            suggestions[key] = (v, i, s, r, cat)
    return suggestions


# ========================
# signature / manifest
# ========================
def db_fingerprint() -> dict:
    fingerprint = {
        "output": True,
        "seed_db": {
            "exists": SEED_DB.exists(),
            "mtime_ns": SEED_DB.stat().st_mtime_ns if SEED_DB.exists() else 0,
            "size": SEED_DB.stat().st_size if SEED_DB.exists() else 0,
        },
    }
    if TAG_DB.exists():
        try:
            conn = sqlite3.connect(str(TAG_DB))
            try:
                success = conn.execute(
                    "SELECT COUNT(*) FROM sync_status WHERE status = 'success'"
                ).fetchone()[0]
                tags = conn.execute("SELECT COUNT(*) FROM tags").fetchone()[0]
                max_updated = conn.execute("SELECT MAX(updated_at) FROM tags").fetchone()[0]
            finally:
                conn.close()
            fingerprint.update({
                "success_count": success,
                "tags_count": tags,
                "max_updated": max_updated,
            })
        except Exception:
            pass
    return fingerprint


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

    signature = db_fingerprint()
    manifest = load_manifest()
    if (
        not args.force
        and OUTPUT_FILE.exists()
        and manifest is not None
        and manifest.get("signature") == signature
    ):
        print(
            f"✅ unchanged: {OUTPUT_FILE} "
            f"({manifest.get('items', 0):,} items, {manifest.get('output_size', 0):,} bytes)"
        )
        if args.clean_legacy:
            _clean_legacy()
        return

    print(f"📂 building (compression={compression}{'' if compresslevel is None else f':{compresslevel}'})")
    suggestions = build_suggestions()

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
    write_manifest(signature, len(compact), size)

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
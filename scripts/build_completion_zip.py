#!/usr/bin/env python3
import argparse
import hashlib
import json
import sqlite3
import sys
import time
import os
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile
from concurrent.futures import ThreadPoolExecutor, as_completed

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
SOURCE_DIR = ROOT / "assets" / "danbooru_completion"
CACHE_DIR = ROOT / ".danbooru_cache"
TAG_CACHE_DIR = ROOT / "cache"
SUCCESS_CACHE_FILE = TAG_CACHE_DIR / "successful_tags.json"
OUTPUT_FILE = ROOT / "assets" / "danbooru_completion.zip"
TEMP_OUTPUT_FILE = OUTPUT_FILE.with_suffix(".zip.tmp")
MANIFEST_FILE = OUTPUT_FILE.with_suffix(".manifest.json")
COMPACT_FILE = "completion_candidates.json"
INDEX_FILE = CACHE_DIR / "completion_index.sqlite3"


def slugify_tag(tag: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in tag).strip("_")


def load_successful_tags() -> set[str]:
    if not SUCCESS_CACHE_FILE.exists():
        return set()

    try:
        payload = json.loads(SUCCESS_CACHE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return set()

    if not isinstance(payload, list):
        return set()

    return {t for t in payload if isinstance(t, str)}


def load_successful_tag_list() -> list[str]:
    if not SUCCESS_CACHE_FILE.exists():
        return []

    try:
        payload = json.loads(SUCCESS_CACHE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []

    if not isinstance(payload, list):
        return []

    seen = set()
    tags = []
    for tag in payload:
        if isinstance(tag, str) and tag not in seen:
            seen.add(tag)
            tags.append(tag)
    return tags


def iter_payload_files(source: str):
    files = {}

    def add_dir(path: Path, recursive: bool):
        if not path.is_dir():
            return
        iterator = path.rglob("*.json") if recursive else path.glob("*.json")
        for item in iterator:
            if item.is_file():
                files[item.stem] = item

    if source in {"successful", "cache", "both"}:
        for tag in load_successful_tags():
            path = CACHE_DIR / f"{slugify_tag(tag)}.json"
            if path.is_file():
                files.setdefault(path.stem, path)

    if source in {"cache", "both"}:
        add_dir(CACHE_DIR, recursive=False)

    if source in {"assets", "both"} or not files:
        add_dir(SOURCE_DIR, recursive=True)

    return list(files.values())


def directory_fingerprint(path: Path, recursive: bool) -> dict:
    if not path.is_dir():
        return {"exists": False, "count": 0, "mtime_ns": 0}

    count = 0
    latest_mtime_ns = path.stat().st_mtime_ns
    iterator = path.rglob("*.json") if recursive else path.glob("*.json")
    for item in iterator:
        if not item.is_file():
            continue
        count += 1
        latest_mtime_ns = max(latest_mtime_ns, item.stat().st_mtime_ns)

    return {"exists": True, "count": count, "mtime_ns": latest_mtime_ns}


def build_signature(source: str, compresslevel: int) -> dict:
    signature = {
        "source": source,
        "compresslevel": compresslevel,
        "assets": directory_fingerprint(SOURCE_DIR, recursive=True)
        if source in {"assets", "both"}
        else None,
        "cache": directory_fingerprint(CACHE_DIR, recursive=False)
        if source in {"cache", "both"}
        else None,
        "cache_dir": {
            "exists": CACHE_DIR.exists(),
            "mtime_ns": CACHE_DIR.stat().st_mtime_ns if CACHE_DIR.exists() else 0,
        }
        if source == "successful"
        else None,
        "successful_tags": {
            "exists": SUCCESS_CACHE_FILE.exists(),
            "mtime_ns": SUCCESS_CACHE_FILE.stat().st_mtime_ns
            if SUCCESS_CACHE_FILE.exists()
            else 0,
            "size": SUCCESS_CACHE_FILE.stat().st_size
            if SUCCESS_CACHE_FILE.exists()
            else 0,
        },
    }
    encoded = json.dumps(signature, sort_keys=True, separators=(",", ":")).encode()
    signature["hash"] = hashlib.sha256(encoded).hexdigest()
    return signature


def successful_tags_signature() -> dict:
    return {
        "exists": SUCCESS_CACHE_FILE.exists(),
        "mtime_ns": SUCCESS_CACHE_FILE.stat().st_mtime_ns
        if SUCCESS_CACHE_FILE.exists()
        else 0,
        "size": SUCCESS_CACHE_FILE.stat().st_size
        if SUCCESS_CACHE_FILE.exists()
        else 0,
    }


def output_signature(source: str, compression: str, compresslevel: int | None) -> dict:
    signature = {
        "source": source,
        "compression": compression,
        "compresslevel": compresslevel,
        "successful_tags": successful_tags_signature(),
    }
    encoded = json.dumps(signature, sort_keys=True, separators=(",", ":")).encode()
    signature["hash"] = hashlib.sha256(encoded).hexdigest()
    return signature


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


def open_index() -> sqlite3.Connection:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(INDEX_FILE)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute(
        "CREATE TABLE IF NOT EXISTS tag_index ("
        "tag TEXT PRIMARY KEY, "
        "slug TEXT NOT NULL, "
        "file_mtime_ns INTEGER NOT NULL, "
        "file_size INTEGER NOT NULL, "
        "candidates_json TEXT NOT NULL"
        ")"
    )
    return conn


def chunked(values: list[str], size: int):
    for index in range(0, len(values), size):
        yield values[index:index + size]


def fetch_indexed_tags(conn: sqlite3.Connection, tags: list[str]) -> set[str]:
    indexed = set()
    for chunk in chunked(tags, 900):
        placeholders = ",".join("?" for _ in chunk)
        rows = conn.execute(
            f"SELECT tag FROM tag_index WHERE tag IN ({placeholders})",
            chunk,
        )
        indexed.update(row[0] for row in rows)
    return indexed


def find_tags_to_index(
    conn: sqlite3.Connection,
    tags: list[str],
    rescan_existing: bool,
) -> list[tuple[str, str, Path, int, int]]:
    indexed = fetch_indexed_tags(conn, tags)
    pending = []

    if not rescan_existing:
        candidates = [tag for tag in tags if tag not in indexed]
        for tag in candidates:
            slug = slugify_tag(tag)
            path = CACHE_DIR / f"{slug}.json"
            try:
                stat = path.stat()
            except OSError:
                continue
            pending.append((tag, slug, path, stat.st_mtime_ns, stat.st_size))
        return pending

    for tag in tags:
        slug = slugify_tag(tag)
        path = CACHE_DIR / f"{slug}.json"
        try:
            stat = path.stat()
        except OSError:
            continue

        row = conn.execute(
            "SELECT file_mtime_ns, file_size FROM tag_index WHERE tag = ?",
            (tag,),
        ).fetchone()
        if row is None or row[0] != stat.st_mtime_ns or row[1] != stat.st_size:
            pending.append((tag, slug, path, stat.st_mtime_ns, stat.st_size))

    return pending


def load_index_entry(entry: tuple[str, str, Path, int, int]):
    tag, slug, path, mtime_ns, size = entry
    candidates = load_candidates(path) or []
    return tag, slug, mtime_ns, size, json.dumps(candidates, ensure_ascii=False, separators=(",", ":"))


def update_successful_index(conn: sqlite3.Connection, tags: list[str], workers: int, rescan_existing: bool):
    pending = find_tags_to_index(conn, tags, rescan_existing)
    if not pending:
        print(f"📇 index ready: {len(tags):,} tags")
        return

    print(f"📇 indexing {len(pending):,}/{len(tags):,} tags")
    pbar = _progress_bar(len(pending), "indexing")
    rows = []

    with ThreadPoolExecutor(max_workers=workers) as ex:
        futures = {ex.submit(load_index_entry, item) for item in pending[: workers * 4]}
        next_index = len(futures)

        while futures:
            for fut in as_completed(futures):
                futures.remove(fut)
                if next_index < len(pending):
                    futures.add(ex.submit(load_index_entry, pending[next_index]))
                    next_index += 1
                break

            rows.append(fut.result())
            pbar.update(1)

            if len(rows) >= 5000:
                conn.executemany(
                    "INSERT OR REPLACE INTO tag_index "
                    "(tag, slug, file_mtime_ns, file_size, candidates_json) "
                    "VALUES (?, ?, ?, ?, ?)",
                    rows,
                )
                conn.commit()
                rows.clear()

    if rows:
        conn.executemany(
            "INSERT OR REPLACE INTO tag_index "
            "(tag, slug, file_mtime_ns, file_size, candidates_json) "
            "VALUES (?, ?, ?, ?, ?)",
            rows,
        )
        conn.commit()

    pbar.close()


def build_suggestions_from_index(conn: sqlite3.Connection, tags: list[str]) -> dict:
    suggestions = {}
    pbar = _progress_bar(len(tags), "merging")

    for chunk in chunked(tags, 900):
        placeholders = ",".join("?" for _ in chunk)
        rows = conn.execute(
            f"SELECT candidates_json FROM tag_index WHERE tag IN ({placeholders})",
            chunk,
        )
        for (payload,) in rows:
            for v, i, s, r in json.loads(payload):
                key = (v.lower(), i.lower())
                old = suggestions.get(key)
                if old is None or r > old[3]:
                    suggestions[key] = (v, i, s, r)
        pbar.update(len(chunk))

    pbar.close()
    return suggestions


def build_successful_suggestions(workers: int, rescan_existing: bool) -> dict:
    tags = load_successful_tag_list()
    if not tags:
        return {}

    conn = open_index()
    try:
        update_successful_index(conn, tags, workers, rescan_existing)
        return build_suggestions_from_index(conn, tags)
    finally:
        conn.close()


def _progress_bar(total: int, desc: str):
    if HAVE_TQDM:
        return tqdm(total=total, desc=desc, unit="file")
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


# ========================
# worker
# ========================
def load_candidates(path: Path):
    try:
        payload = json_load(path)
    except Exception:
        return None

    cands = payload.get("completion_candidates")
    if not isinstance(cands, list):
        return None

    result = []
    for c in cands:
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
            c.get("score") if isinstance(c.get("score"), int) else 0
        ))

    return result


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build the compact Danbooru completion zip."
    )
    parser.add_argument(
        "--source",
        choices=("successful", "cache", "assets", "both"),
        default="successful",
        help=(
            "Input source. Default uses cache/successful_tags.json to pick files "
            "from .danbooru_cache without scanning the whole directory; use 'both' "
            "for legacy behavior."
        ),
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
        "--workers",
        type=int,
        default=min(32, (os.cpu_count() or 8) * 4),
        help="JSON loading worker threads.",
    )
    parser.add_argument(
        "--rescan-existing",
        action="store_true",
        help="For --source successful, stat indexed cache files and refresh changed entries. Slower with huge caches.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    compression = "stored" if args.store else "deflated"
    compresslevel = None if args.store else (9 if args.best else args.compresslevel)

    if not SOURCE_DIR.is_dir():
        raise SystemExit(f"not found: {SOURCE_DIR}")

    if args.source == "successful":
        signature = output_signature(args.source, compression, compresslevel)
    else:
        signature = build_signature(args.source, compresslevel or 0)
    manifest = load_manifest()
    if (
        not args.force
        and OUTPUT_FILE.exists()
        and manifest is not None
        and manifest.get("signature", {}).get("hash") == signature["hash"]
    ):
        print(
            f"✅ unchanged: {OUTPUT_FILE} "
            f"({manifest.get('items', 0):,} items, {manifest.get('output_size', 0):,} bytes)"
        )
        return

    if args.source == "successful":
        print(f"📂 successful tags (compression={compression}{'' if compresslevel is None else f':{compresslevel}'})")
        suggestions = build_successful_suggestions(args.workers, args.rescan_existing)
    else:
        files = iter_payload_files(args.source)
        total = len(files)

        print(f"📂 {total} files ({args.source}, compression={compression}{'' if compresslevel is None else f':{compresslevel}'})")

        pbar = _progress_bar(total, "loading")

        suggestions = {}

        with ThreadPoolExecutor(max_workers=args.workers) as ex:
            futures = {ex.submit(load_candidates, f) for f in files[: args.workers * 4]}
            next_index = len(futures)

            while futures:
                for fut in as_completed(futures):
                    futures.remove(fut)
                    if next_index < total:
                        futures.add(ex.submit(load_candidates, files[next_index]))
                        next_index += 1
                    break

                pbar.update(1)
                data = fut.result()

                if not data:
                    continue

                for v, i, s, r in data:
                    key = (v.lower(), i.lower())

                    old = suggestions.get(key)
                    if old is None or r > old[3]:
                        suggestions[key] = (v, i, s, r)

        pbar.close()

    print(f"⚙️ merge {len(suggestions)}")

    sorted_list = sorted(
        suggestions.values(),
        key=lambda x: (-x[3], x[0])
    )

    compact = [
        {"v": v, "i": i, "s": s, "r": r}
        for v, i, s, r in sorted_list
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

    print(f"✅ done: {len(compact)} items, {size:,} bytes")


if __name__ == "__main__":
    main()
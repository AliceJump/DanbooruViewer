#!/usr/bin/env python3
import json
import sys
import time
import os
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
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
COMPACT_FILE = "completion_candidates.json"


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


def iter_payload_files():
    files = {}

    for path in SOURCE_DIR.rglob("*.json"):
        if path.is_file():
            files[path.stem] = path

    if CACHE_DIR.is_dir():
        for path in CACHE_DIR.glob("*.json"):
            if path.is_file():
                files.setdefault(path.stem, path)

    for tag in load_successful_tags():
        path = CACHE_DIR / f"{slugify_tag(tag)}.json"
        if path.is_file():
            files.setdefault(path.stem, path)

    return list(files.values())


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


def main():
    if not SOURCE_DIR.is_dir():
        raise SystemExit(f"not found: {SOURCE_DIR}")

    files = iter_payload_files()
    total = len(files)

    print(f"📂 {total} files")

    max_workers = min(32, (os.cpu_count() or 8) * 4)

    pbar = _progress_bar(total, "loading")

    suggestions = {}
    skipped = 0

    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        futures = [ex.submit(load_candidates, f) for f in files]

        for fut in as_completed(futures):
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

    with ZipFile(TEMP_OUTPUT_FILE, "w", ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr(COMPACT_FILE, json.dumps(compact, ensure_ascii=False, separators=(",", ":")))

    TEMP_OUTPUT_FILE.replace(OUTPUT_FILE)

    size = OUTPUT_FILE.stat().st_size

    print(f"✅ done: {len(compact)} items, {size:,} bytes")


if __name__ == "__main__":
    main()
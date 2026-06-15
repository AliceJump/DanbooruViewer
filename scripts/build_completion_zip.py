#!/usr/bin/env python3
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "assets" / "danbooru_completion"
OUTPUT_FILE = ROOT / "assets" / "danbooru_completion.zip"
TEMP_OUTPUT_FILE = OUTPUT_FILE.with_suffix(".zip.tmp")
COMPACT_FILE = "completion_candidates.json"


def main() -> None:
    if not SOURCE_DIR.is_dir():
        raise SystemExit(f"Completion source directory not found: {SOURCE_DIR}")

    json_files = sorted(path for path in SOURCE_DIR.rglob("*.json") if path.is_file())
    suggestions_by_key: dict[tuple[str, str], dict[str, object]] = {}

    for path in json_files:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"Skipped {path.relative_to(SOURCE_DIR)}: {error}")
            continue

        candidates = payload.get("completion_candidates")
        if not isinstance(candidates, list):
            continue

        for candidate in candidates:
            if not isinstance(candidate, dict):
                continue

            value = candidate.get("value")
            insert_value = candidate.get("insert_value", value)
            if not isinstance(value, str) or not isinstance(insert_value, str):
                continue
            if not value.strip() or not insert_value.strip():
                continue

            source = candidate.get("source")
            score = candidate.get("score")
            compact_candidate = {
                "v": value,
                "i": insert_value,
                "s": source if isinstance(source, str) else "",
                "r": score if isinstance(score, int) else 0,
            }
            key = (value.lower(), insert_value.lower())
            existing = suggestions_by_key.get(key)
            if existing is None or compact_candidate["r"] > existing["r"]:
                suggestions_by_key[key] = compact_candidate

    suggestions = sorted(
        suggestions_by_key.values(),
        key=lambda candidate: (-int(candidate["r"]), str(candidate["v"])),
    )
    compact_json = json.dumps(suggestions, ensure_ascii=False, separators=(",", ":"))

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(TEMP_OUTPUT_FILE, "w", ZIP_DEFLATED, compresslevel=9) as archive:
        archive.writestr(COMPACT_FILE, compact_json)
    TEMP_OUTPUT_FILE.replace(OUTPUT_FILE)

    print(
        f"Wrote {OUTPUT_FILE} with {len(suggestions)} completion candidates "
        f"from {len(json_files)} JSON files ({OUTPUT_FILE.stat().st_size:,} bytes)"
    )


if __name__ == "__main__":
    main()

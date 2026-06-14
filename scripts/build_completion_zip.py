#!/usr/bin/env python3
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "assets" / "danbooru_completion"
OUTPUT_FILE = ROOT / "assets" / "danbooru_completion.zip"


def main() -> None:
    if not SOURCE_DIR.is_dir():
        raise SystemExit(f"Completion source directory not found: {SOURCE_DIR}")

    json_files = sorted(
        path for path in SOURCE_DIR.rglob("*.json") if path.is_file()
    )

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(OUTPUT_FILE, "w", ZIP_DEFLATED) as archive:
        for path in json_files:
            archive.write(path, path.relative_to(SOURCE_DIR).as_posix())

    print(f"Wrote {OUTPUT_FILE} with {len(json_files)} JSON files")


if __name__ == "__main__":
    main()

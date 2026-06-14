#!/usr/bin/env python3
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "assets" / "danbooru_completion"
OUTPUT_FILE = ROOT / "assets" / "danbooru_completion.7z"


def build_with_py7zr(json_files: list[Path]) -> bool:
    try:
        import py7zr
    except ImportError:
        return False

    with py7zr.SevenZipFile(OUTPUT_FILE, "w", filters=[{"id": py7zr.FILTER_LZMA2, "preset": 9}]) as archive:
        for path in json_files:
            archive.write(path, path.relative_to(SOURCE_DIR).as_posix())

    return True


def build_with_7z() -> bool:
    executable = next((name for name in ("7z", "7zz", "7za") if shutil.which(name)), None)
    if executable is None:
        return False

    subprocess.run(
        [executable, "a", "-t7z", "-mx=9", "-m0=lzma2", str(OUTPUT_FILE), "*.json"],
        cwd=SOURCE_DIR,
        check=True,
    )
    return True


def main() -> None:
    if not SOURCE_DIR.is_dir():
        raise SystemExit(f"Completion source directory not found: {SOURCE_DIR}")

    json_files = sorted(
        path for path in SOURCE_DIR.rglob("*.json") if path.is_file()
    )

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    if OUTPUT_FILE.exists():
        OUTPUT_FILE.unlink()

    if not build_with_py7zr(json_files) and not build_with_7z():
        raise SystemExit(
            "7z builder not found. Install py7zr with `pip install -r requirements.txt` "
            "or install the 7z command line tool."
        )

    print(f"Wrote {OUTPUT_FILE} with {len(json_files)} JSON files")


if __name__ == "__main__":
    main()

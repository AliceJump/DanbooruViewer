#!/usr/bin/env python3
"""Auto-sync tags on app startup (incremental mode).

This script is designed to be called by Flutter app on startup.
It checks which tags need updating and syncs them in the background.

Usage:
    python startup_auto_sync.py                    # Default tags
    python startup_auto_sync.py --tags tag1 tag2   # Specific tags
    python startup_auto_sync.py --file tags.txt    # From file
    python startup_auto_sync.py --max-age 48       # 48-hour cache
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import view


DEFAULT_TAGS = [
    "oguri_cap_(umamusume)",
    "special_week_(umamusume)",
    "silence_suzuka_(umamusume)",
    "tamamo_cross_(umamusume)",
    "mejiro_mcqueen_(umamusume)",
    "tokai_teio_(umamusume)",
    "gold_ship_(umamusume)",
    "daiwa_scarlet_(umamusume)",
    "rice_shower_(umamusume)",
    "super_creek_(umamusume)",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Incremental startup sync for tag completion",
        epilog="Call this from Flutter app on startup or from scheduled task",
    )
    parser.add_argument(
        "--tags",
        nargs="+",
        help="Specific tags to check/sync",
    )
    parser.add_argument(
        "--file",
        type=Path,
        help="File with one tag per line",
    )
    parser.add_argument(
        "--default",
        action="store_true",
        help="Use default preset tags",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Check all locally cached tags",
    )
    parser.add_argument(
        "--max-age",
        type=int,
        default=24,
        help="Max age in hours before re-syncing (default 24)",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Minimal output (silent on success, errors only)",
    )
    return parser.parse_args()


def load_tags_from_file(path: Path) -> list[str]:
    """Load tags from a file (one per line)."""
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def get_cached_tags() -> list[str]:
    """Get list of all cached tags from cache directory."""
    cache_dir = view.CACHE_DIR
    if not cache_dir.exists():
        return []
    
    tags = []
    for json_file in cache_dir.glob("*.json"):
        if json_file.name == "sync_metadata.json":
            continue
        tag_slug = json_file.stem
        tags.append(tag_slug)
    return tags


def get_tags_to_sync(args) -> list[str]:
    """Determine which tags to sync based on arguments."""
    if args.tags:
        return args.tags
    if args.file:
        return load_tags_from_file(args.file)
    if args.all:
        return get_cached_tags()
    if args.default:
        return DEFAULT_TAGS
    return DEFAULT_TAGS  # Default to default tags


def main():
    args = parse_args()
    tags = get_tags_to_sync(args)
    
    if not tags:
        if not args.quiet:
            print("No tags to sync.")
        return 0
    
    if not args.quiet:
        print(f"Checking {len(tags)} tag(s) for updates (max age: {args.max_age}h)...")
    
    synced, total, errors = view.incremental_sync(tags, max_age_hours=args.max_age)
    
    if not args.quiet:
        print()
        print("=" * 60)
        print(f"Updated: {synced}/{total} tags")
        if errors:
            print(f"Errors: {len(errors)}")
            for tag, error in errors:
                print(f"  - {tag}: {error}")
        print("=" * 60)
    
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

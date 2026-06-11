#!/usr/bin/env python3
"""Initialize the local Danbooru completion sync cache."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import view


def parse_args():
    parser = argparse.ArgumentParser(description="Initialize Danbooru sync data")
    parser.add_argument("--tag", default=view.DEFAULT_TAG, help="Tag to sync")
    return parser.parse_args()


def main():
    args = parse_args()
    payload = view.sync_data(args.tag)
    path = view.cache_path(args.tag)
    print(f"Synced {payload['tag']} -> {path}")


if __name__ == "__main__":
    main()

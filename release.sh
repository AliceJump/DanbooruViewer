#!/usr/bin/env bash
# Read-only compatibility entry point; publication is documented in RELEASE_GUIDE.md.
set -euo pipefail
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -X utf8 "$script_dir/scripts/prepare_release.py" --guide

# Read-only compatibility entry point; publication is documented in RELEASE_GUIDE.md.
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
& python -X utf8 (Join-Path $PSScriptRoot "scripts/prepare_release.py") --guide
exit $LASTEXITCODE

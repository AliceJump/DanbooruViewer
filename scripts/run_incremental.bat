@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0.."
if errorlevel 1 exit /b 1
set "sync_python=python"
if exist ".venv\Scripts\python.exe" set "sync_python=.venv\Scripts\python.exe"
echo Incremental sync
"%sync_python%" -X utf8 scripts\batch_sync_tags.py --all-from-api --retry-failed --delay 0.1 --workers 10 --rate 7 --api-limit 1000
if errorlevel 1 exit /b 1
echo All done.
exit /b 0

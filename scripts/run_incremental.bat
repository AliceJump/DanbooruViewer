@echo off
chcp 65001 >nul
cd /d "D:\items\project\android_project\DanbooruViewer-new"
echo ===== Incremental sync (new side + resume old side from cursor min_id) =====
.venv\Scripts\python.exe -X utf8 scripts\batch_sync_tags.py --all-from-api --retry-failed --delay 0.1 --workers 10 --rate 7 --api-limit 2000
echo.
echo ===== All done =====
pause
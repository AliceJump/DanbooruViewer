@echo off
chcp 65001 >nul
cd /d "D:\items\project\android_project\DanbooruViewer-new"
echo ===== [1/2] Resync last 2 months (from id 2672621) =====
.venv\Scripts\python.exe -X utf8 scripts\batch_sync_tags.py --resync-months 2 --from-id 2672621 --rate 7 --workers 10 --api-limit 2000
echo.
echo ===== [2/2] Resync done, starting incremental full sync =====
.venv\Scripts\python.exe -X utf8 scripts\batch_sync_tags.py --all-from-api --retry-failed --delay 0.1 --workers 10 --rate 7 --api-limit 2000
echo.
echo ===== All done =====
pause
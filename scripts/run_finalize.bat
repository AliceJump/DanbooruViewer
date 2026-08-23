@echo off
chcp 65001 >nul
cd /d "D:\items\project\android_project\DanbooruViewer-new"
echo ===== [1/3] Catch up new tags + retry failed =====
.venv\Scripts\python.exe -X utf8 scripts\batch_sync_tags.py --all-from-api --retry-failed --delay 0.1 --workers 10 --rate 7 --api-limit 2000
echo.
echo ===== [2/3] Sync tag categories (all categories) =====
.venv\Scripts\python.exe -X utf8 scripts\sync_tag_categories.py --delay 0.2 --workers 3
echo.
echo ===== [3/3] Build completion zip (merge all sources) =====
.venv\Scripts\python.exe -X utf8 scripts\build_completion_zip.py
echo.
echo ===== All done =====
pause
@echo off
setlocal
python -X utf8 "%~dp0scripts\prepare_release.py" --guide
exit /b %errorlevel%

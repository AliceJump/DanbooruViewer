@echo off
REM Danbooru Viewer - Release Helper Script (Windows)
REM 功能: 自动获取 GitHub URL、自动生成100进制版本号、检测最新 commit 是否已有 tag、
REM       智能处理自动 commit/tag、支持 Release/Alpha/Beta/RC、查看 Tags/Git 日志、
REM       显示标签间的提交日志（过滤 Bump commit）
REM 参考: release.ps1 / release.sh

setlocal enabledelayedexpansion

chcp 65001 >nul

echo.
echo ╔════════════════════════════════════════╗
echo ║ Danbooru Viewer Release Helper Script  ║
echo ╚════════════════════════════════════════╝
echo.

REM ── 工具函数 ─────────────────────────────────────────

:check_git
where git >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [31m? 错误: 未找到 git 命令[0m
    exit /b 1
)
git rev-parse --git-dir >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [31m? 错误: 不在 git 仓库中[0m
    exit /b 1
)
goto :eof

:get_remote_url
for /f "usebackq tokens=*" %%i in (`git remote get-url origin 2^>nul`) do set "raw_url=%%i"
REM 去掉末尾的 .git
set "repo_url=!raw_url:.git=!"
goto :eof

:get_current_version
for /f "tokens=2" %%A in ('findstr "^version:" pubspec.yaml') do set "raw_cv=%%A"
REM 只取 X.Y.Z 部分
for /f "tokens=1 delims=+" %%A in ("!raw_cv!") do set "cv=%%A"
goto :eof

:get_next_version_100
call :get_current_version
for /f "tokens=1-3 delims=." %%a in ("!cv!") do (
    set /a patch=%%c+1
    set "major=%%a"
    set "minor=%%b"
)
if !patch! GEQ 100 (
    set patch=0
    set /a minor+=1
)
if !minor! GEQ 100 (
    set minor=0
    set /a major+=1
)
set "next_version=!major!.!minor!.!patch!"
goto :eof

:get_prev_version_100
call :get_current_version
for /f "tokens=1-3 delims=." %%a in ("!cv!") do (
    set "major=%%a"
    set "minor=%%b"
    set "patch=%%c"
)
set /a patch-=1
if !patch! LSS 0 (
    set patch=99
    set /a minor-=1
    if !minor! LSS 0 (
        set minor=99
        if !major! GTR 0 (
            set /a major-=1
        ) else (
            set minor=0
            set patch=0
        )
    )
)
set "prev_version=!major!.!minor!.!patch!"
goto :eof

:update_pubspec_version
set "new_ver=%~1"
set "pubspec_content="
for /f "usebackq delims=" %%a in (`type pubspec.yaml`) do (
    set "line=%%a"
    setlocal enabledelayedexpansion
    echo(!line!|findstr /b "version:" >nul
    if !errorlevel! equ 0 (
        echo version: !new_ver!
    ) else (
        echo(!line!
    )
    endlocal
) > pubspec.yaml.new
move /y pubspec.yaml.new pubspec.yaml >nul
echo [32m? pubspec.yaml 已更新为版本 !new_ver![0m
goto :eof

:commit_changes
set "ver_c=%~1"
git diff --quiet
if %ERRORLEVEL% EQU 0 (
    echo [33m? 没有未提交的改动，跳过 commit[0m
) else (
    git add pubspec.yaml
    git commit -m "Bump version to !ver_c!"
    echo [32m? 自动提交完成[0m
)
goto :eof

:create_tag
set "tag_name=%~1"
set "commit_hash=%~2"
git tag !tag_name! !commit_hash!
echo [32m? Tag !tag_name! 已创建 (指向 commit !commit_hash!)[0m
goto :eof

:push_changes
for /f "usebackq tokens=*" %%i in (`git branch --show-current`) do set "branch=%%i"
echo [33m? 推送 Tag 和提交到分支 '!branch!'...[0m
git push origin !branch! --tags
if %ERRORLEVEL% NEQ 0 (
    echo [31m? 推送失败，请检查网络或权限[0m
    exit /b 1
)
echo [32m? 推送成功[0m
goto :eof

:get_changelog_between_tags
REM 获取最新两个标签，生成之间的提交日志（过滤 Bump version 消息）
set "prev_tag=%~1"
set "curr_tag=%~2"
REM 如果没有 prev_tag，取第一个父提交
if "!prev_tag!"=="" (
    set log_range=!curr_tag!
) else (
    set log_range=!prev_tag!..!curr_tag!
)
echo.
echo [36m========== 自上一标签以来的提交日志 ==========[0m
git log !log_range! --oneline --no-decorate | findstr /v "Bump version to" | findstr /v "update download stats"
echo [36m============================================[0m
goto :eof

REM ── 主程序 ─────────────────────────────────────────────

call :check_git

REM 拉取远程最新代码
echo [33m? 拉取远程最新代码...[0m
git pull --ff-only
echo.

call :get_remote_url
echo [34m当前远程仓库: !repo_url![0m
echo.

call :get_prev_version_100
echo [32m当前版本: !prev_version![0m
echo.

echo 选择要执行的操作:
echo 1) 发布新 Release 版本
echo 2) 发布 Alpha/Beta/RC 测试版本
echo 3) 查看最近的 Tags
echo 4) 查看 Git 日志
echo.
set /p choice="请选择 (1-4): "

if "%choice%"=="1" goto release
if "%choice%"=="2" goto prerelease
if "%choice%"=="3" goto tags
if "%choice%"=="4" goto log
echo [31m? 无效选择[0m
exit /b 1

REM ────── Release ──────
:release
cls
echo.
echo === 发布新 Release 版本 ===
echo.

for /f "usebackq tokens=*" %%i in (`git rev-parse HEAD`) do set "latest_commit=%%i"
for /f "usebackq tokens=*" %%i in (`git tag --points-at !latest_commit!`) do set "existing_tag=%%i"

if "!existing_tag!"=="" (
    call :get_current_version
    call :get_next_version_100
    echo [36m最新 commit 无 tag，自动生成版本号: !cv![0m

    REM 显示 changelog
    set "last_tag="
    for /f "usebackq tokens=*" %%i in (`git tag -l "v*" --sort=-version:refname ^| findstr /r "v[0-9]"`) do if not defined last_tag set "last_tag=%%i"
    if not "!last_tag!"=="" (
        call :get_changelog_between_tags "!last_tag!" "!latest_commit!"
    )

    git diff --quiet
    if !ERRORLEVEL! NEQ 0 (
        call :update_pubspec_version !next_version!
        call :commit_changes !next_version!
    )
    set "TAG=v!cv!"
    for /f "usebackq tokens=*" %%i in (`git rev-parse HEAD`) do set "latest_commit=%%i"
    call :create_tag "!TAG!" "!latest_commit!"
) else (
    call :get_current_version
    call :get_next_version_100
    echo [33m最新 commit 已有 tag (!existing_tag!)，创建 Bump commit 并打新 tag[0m

    REM 显示 changelog
    set "last_tag="
    for /f "usebackq tokens=*" %%i in (`git tag -l "v*" --sort=-version:refname ^| findstr /r "v[0-9]"`) do if not defined last_tag set "last_tag=%%i"
    if not "!last_tag!"=="" (
        call :get_changelog_between_tags "!last_tag!" "!latest_commit!"
    )

    call :update_pubspec_version !next_version!
    call :commit_changes !next_version!
    for /f "usebackq tokens=*" %%i in (`git rev-parse HEAD`) do set "latest_commit=%%i"
    set "TAG=v!cv!"
    call :create_tag "!TAG!" "!latest_commit!"
)

call :push_changes

echo.
echo [32m? 发布完成![0m
echo 监控进度: !repo_url!/actions
echo 查看发布: !repo_url!/releases
goto end

REM ────── Pre-release ──────
:prerelease
cls
echo.
echo === 发布测试版本 ===
echo.
echo 选择版本类型:
echo 1) Alpha
echo 2) Beta
echo 3) RC
echo.
set /p type_choice="请选择 (1-3): "

if "%type_choice%"=="1" set pre_type=alpha
if "%type_choice%"=="2" set pre_type=beta
if "%type_choice%"=="3" set pre_type=rc

if not defined pre_type (
    echo [31m? 无效选择[0m
    exit /b 1
)

set /p test_version="输入测试版本号 (例: 1.1.0-%pre_type%.1): "
set "TAG=v%test_version%"

echo.
echo 准备发布:
echo   版本号: %test_version%
echo   Git Tag: !TAG!
echo.

REM 显示 changelog
for /f "usebackq tokens=*" %%i in (`git rev-parse HEAD`) do set "latest_commit=%%i"
set "last_tag="
for /f "usebackq tokens=*" %%i in (`git tag -l "v*" --sort=-version:refname ^| findstr /r "v[0-9]"`) do if not defined last_tag set "last_tag=%%i"
if not "!last_tag!"=="" (
    call :get_changelog_between_tags "!last_tag!" "!latest_commit!"
)

set /p confirm="继续? (y/n): "
if /i not "!confirm!"=="y" (
    echo 已取消
    exit /b 0
)

for /f "usebackq tokens=*" %%i in (`git rev-parse HEAD`) do set "latest_commit=%%i"
call :create_tag "!TAG!" "!latest_commit!"
call :push_changes

echo.
echo [32m? 成功! 这个测试版本会被标记为 prerelease[0m
echo 监控进度: !repo_url!/actions
goto end

REM ────── Tags ──────
:tags
cls
echo.
echo === 最近的 Tags ===
echo.
git tag -l "v*" --sort=-version:refname
echo.
REM 显示两个最新 tag 之间的日志
echo [36m--- 最新两个 Tag 间的提交日志 ---[0m
set "tag1="
set "tag2="
for /f "usebackq tokens=*" %%i in (`git tag -l "v*" --sort=-version:refname ^| findstr /r "v[0-9]"`) do (
    if not defined tag1 (
        set "tag1=%%i"
    ) else if not defined tag2 (
        set "tag2=%%i"
    )
)
if not "!tag2!"=="" (
    git log !tag2!..!tag1! --oneline --no-decorate | findstr /v "Bump version to" | findstr /v "update download stats"
) else if not "!tag1!"=="" (
    git log !tag1! --oneline --no-decorate | findstr /v "Bump version to" | findstr /v "update download stats"
)
goto end

REM ────── Log ──────
:log
cls
echo.
echo === Git 日志 (最后 20 条提交) ===
echo.
git log --oneline -20
echo.
echo [36m--- 过滤 Bump version 后的日志 ---[0m
echo.
git log --oneline -20 --no-decorate | findstr /v "Bump version to" | findstr /v "update download stats"
goto end

:end
echo.
echo ════════════════════════════════════════
echo.
pause

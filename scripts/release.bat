@echo off
REM Danbooru Viewer - Release Helper Script (Windows)
REM 此脚本帮助快速发布新版本

setlocal enabledelayedexpansion

echo.
echo ╔════════════════════════════════════════╗
echo ║ Danbooru Viewer Release Helper Script  ║
echo ╚════════════════════════════════════════╝
echo.

REM 检查 git
where git >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo ? 错误: 未找到 git 命令
    exit /b 1
)

REM 获取当前版本
for /f "tokens=2" %%A in ('findstr "^version:" pubspec.yaml') do (
    set CURRENT_VERSION=%%A
    goto :found_version
)
:found_version

echo 当前版本: %CURRENT_VERSION%
echo.

echo 选择要执行的操作:
echo 1) 发布新 Release 版本
echo 2) 发布 Alpha/Beta 测试版本
echo 3) 查看最近的 Tags
echo 4) 查看 Git 日志
echo.
set /p choice="请选择 (1-4): "

if "%choice%"=="1" goto release
if "%choice%"=="2" goto prerelease
if "%choice%"=="3" goto tags
if "%choice%"=="4" goto log
goto invalid

:release
cls
echo.
echo === 发布新 Release 版本 ===
echo.
set /p new_version="输入新版本号 (不需要 'v' 前缀, 例: 1.1.0): "

REM 简单的版本号验证 - 使用更简单的方法
for /f "tokens=1,2,3 delims=." %%a in ("%new_version%") do (
    if "%%a"=="" goto version_error
    if "%%b"=="" goto version_error
    if "%%c"=="" goto version_error
)

REM 检查是否全是数字
for %%a in (%new_version:.= %) do (
    for /f "delims=0123456789" %%i in ("%%a") do (
        if not "%%i"=="" goto version_error
    )
)

goto version_ok

:version_error
echo ? 错误: 版本号格式无效 (应为 X.Y.Z，例如 1.0.0)
exit /b 1

:version_ok

set tag=v%new_version%

echo.
echo 准备发布:
echo   版本号: %new_version%
echo   Git Tag: %tag%
echo.
set /p confirm="继续? (y/n): "

if /i not "%confirm%"=="y" (
    echo 已取消
    exit /b 0
)

echo.
echo ? 创建 Tag...
git tag %tag%
if %ERRORLEVEL% NEQ 0 (
    echo ? 错误: 创建 Tag 失败
    exit /b 1
)

echo ? 推送 Tag...
git push origin %tag%
if %ERRORLEVEL% NEQ 0 (
    echo ? 错误: 推送 Tag 失败
    exit /b 1
)

echo.
echo ? 成功!
echo.
echo GitHub Actions 现在会自动构建你的应用。
echo 监控进度: https://github.com/YOUR_USERNAME/danbooru-viewer/actions
echo.
echo 构建完成后查看发布: https://github.com/YOUR_USERNAME/danbooru-viewer/releases
goto end

:prerelease
cls
echo.
echo === 发布测试版本 ===
echo.
echo 选择版本类型:
echo 1) Alpha
echo 2) Beta
echo 3) RC (Release Candidate)
echo.
set /p type_choice="请选择 (1-3): "

if "%type_choice%"=="1" set pre_type=alpha
if "%type_choice%"=="2" set pre_type=beta
if "%type_choice%"=="3" set pre_type=rc

if not defined pre_type (
    echo ? 无效选择
    exit /b 1
)

set /p test_version="输入测试版本号 (例: 1.1.0-%pre_type%.1): "

set tag=v%test_version%

echo.
echo 准备发布:
echo   版本号: %test_version%
echo   Git Tag: %tag%
echo.
set /p confirm="继续? (y/n): "

if /i not "%confirm%"=="y" (
    echo 已取消
    exit /b 0
)

echo.
echo ? 创建 Tag...
git tag %tag%

echo ? 推送 Tag...
git push origin %tag%

echo.
echo ? 成功!
echo.
echo 这个测试版本会被标记为 prerelease
echo 监控进度: https://github.com/YOUR_USERNAME/danbooru-viewer/actions
goto end

:tags
cls
echo.
echo === 最近的 Tags ===
echo.
git tag -l "v*" --sort=-version:refname
goto end

:log
cls
echo.
echo === Git 日志 (最后 10 条提交) ===
echo.
git log --oneline -10
goto end

:invalid
echo ? 无效选择
exit /b 1

:end
echo.
echo ════════════════════════════════════════
echo.
pause

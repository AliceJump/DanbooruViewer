<#
.SYNOPSIS
Danbooru Viewer Release Helper Script (PowerShell 7)

功能:
- 自动获取 GitHub URL
- 自动 100 进制递增版本号
- 更新 pubspec.yaml 版本号
- 提交版本号更新
- 创建 Tag 并推送
- 支持 Release / Alpha / Beta / RC
- 查看 Tags / Git 日志
#>

# 清屏
Clear-Host

function Check-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "❌ 错误: 未找到 git 命令" -ForegroundColor Red
        exit 1
    }
}

function Get-RemoteUrl {
    $url = git remote get-url origin
    return $url -replace '\.git$',''
}

function Get-CurrentVersion {
    $pubspec = Get-Content pubspec.yaml
    $line = $pubspec | Where-Object { $_ -match '^version:' }
    return ($line -split ' ')[1]
}

function Update-PubspecVersion($newVersion) {
    $pubspec = Get-Content pubspec.yaml
    $currentVersion = Get-CurrentVersion

    # 读取旧 build number
    $oldBuild = $null
    if ($currentVersion -match '\+(\d+)$') {
        $oldBuild = $Matches[1]
    }

    # 更新版本号
    $pubspecNew = $pubspec | ForEach-Object {
        if ($_ -match '^version:') {
            if ($oldBuild) { "version: $newVersion+$oldBuild" } else { "version: $newVersion" }
        } else { $_ }
    }

    $pubspecNew | Set-Content pubspec.yaml -Encoding UTF8 -Force
    return $pubspecNew
}

function Commit-Pubspec {
    git add pubspec.yaml
    if (-not (git diff --cached --quiet)) {
        git commit -m "Bump version to $new_version"
        Write-Host "✅ pubspec.yaml 已提交"
    } else {
        Write-Host "⚠ 没有检测到 pubspec.yaml 改动，跳过提交" -ForegroundColor Yellow
    }
}

function Create-Tag($tag) {
    if (git tag -l $tag) {
        Write-Host "⚠ Tag $tag 已存在，跳过创建 Tag" -ForegroundColor Yellow
    } else {
        git tag $tag
        Write-Host "✅ Tag $tag 已创建"
    }
}

function Push-Changes {
    $branch = git branch --show-current
    Write-Host "⏳ 推送 Tag 和提交到分支 '$branch'..."
    git push origin $branch --tags
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ 推送失败，请检查网络或权限" -ForegroundColor Red
        exit 1
    }
    Write-Host "✅ 推送成功"
}

# 100进制版本号递增函数
function Get-NextVersion100 {
    $currentVer = Get-CurrentVersion

    if ($currentVer -match '^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $patch = [int]$Matches[3]
        $build = if ($Matches[4]) { [int]$Matches[4] } else { 0 }

        # patch +1
        $patch += 1

        # 100进制进位
        if ($patch -ge 100) {
            $patch = 0
            $minor += 1
        }
        if ($minor -ge 100) {
            $minor = 0
            $major += 1
        }

        return "$major.$minor.$patch"
    } else {
        Write-Host "❌ 当前版本号格式不正确: $currentVer" -ForegroundColor Red
        exit 1
    }
}

# 主程序
Check-Git
$REPO_URL = Get-RemoteUrl
Write-Host "当前远程仓库: $REPO_URL"
Write-Host ""

$CURRENT_VERSION = Get-CurrentVersion
Write-Host "当前版本: $CURRENT_VERSION"
Write-Host ""

Write-Host "选择要执行的操作:"
Write-Host "1) 发布新 Release 版本（自动 patch+1, 100进制）"
Write-Host "2) 发布 Alpha/Beta/RC 测试版本"
Write-Host "3) 查看最近的 Tags"
Write-Host "4) 查看 Git 日志"
$choice = Read-Host "请选择 (1-4)"

switch ($choice) {
    "1" {
        # 自动递增 Release
        Clear-Host
        Write-Host "=== 发布新 Release 版本 ==="

        $new_version = Get-NextVersion100
        Write-Host "自动生成新版本号: $new_version"

        Update-PubspecVersion $new_version

        # 显示 pubspec.yaml 版本确认
        $pubspec = Get-Content pubspec.yaml
        $versionLine = $pubspec | Where-Object { $_ -match '^version:' }
        $newVersionInFile = ($versionLine -split ' ')[1]
        Write-Host "pubspec.yaml 当前版本号: $newVersionInFile"

        Commit-Pubspec

        $tag = "v$new_version"
        Write-Host ""
        Write-Host "准备发布:"
        Write-Host "  版本号: $new_version"
        Write-Host "  Git Tag: $tag"
        $confirm = Read-Host "继续? (y/n)"
        if ($confirm -ne 'y') { Write-Host "已取消"; exit 0 }

        Create-Tag $tag
        Push-Changes

        Write-Host "✅ 发布完成!"
        Write-Host "监控进度: $REPO_URL/actions"
        Write-Host "查看发布: $REPO_URL/releases"
    }
    "2" {
        # Prerelease
        Clear-Host
        Write-Host "=== 发布测试版本 ==="
        Write-Host "选择版本类型:"
        Write-Host "1) Alpha"
        Write-Host "2) Beta"
        Write-Host "3) RC"
        $type_choice = Read-Host "请选择 (1-3)"
        switch ($type_choice) {
            "1" { $pre_type = "alpha" }
            "2" { $pre_type = "beta" }
            "3" { $pre_type = "rc" }
            default { Write-Host "❌ 无效选择" -ForegroundColor Red; exit 1 }
        }
        $test_version = Read-Host "输入测试版本号 (例: 1.1.0-$pre_type.1)"
        $tag = "v$test_version"

        Write-Host ""
        Write-Host "准备发布:"
        Write-Host "  版本号: $test_version"
        Write-Host "  Git Tag: $tag"
        $confirm = Read-Host "继续? (y/n)"
        if ($confirm -ne 'y') { Write-Host "已取消"; exit 0 }

        Create-Tag $tag
        Push-Changes

        Write-Host "✅ 成功! 这个测试版本会被标记为 prerelease"
        Write-Host "监控进度: $REPO_URL/actions"
    }
    "3" {
        # Tags
        Clear-Host
        Write-Host "=== 最近的 Tags ==="
        git tag -l "v*" --sort=-version:refname
    }
    "4" {
        # Git log
        Clear-Host
        Write-Host "=== Git 日志 (最后 10 条提交) ==="
        git log --oneline -10
    }
    default {
        Write-Host "❌ 无效选择" -ForegroundColor Red
    }
}

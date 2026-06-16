<#
.SYNOPSIS
Danbooru Viewer Release Helper Script (PowerShell 7)

功能:
- 自动获取 GitHub URL
- 自动生成 100 进制版本号
- 检测最新 commit 是否已有 tag
- 智能处理自动 commit / tag
- 支持 Release / Alpha/Beta/RC
- 查看 Tags / Git 日志
- 显示标签间的提交日志（过滤 Bump version 消息）
#>

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
    $currentVersion = ($line -split ' ')[1]

    # 解析 base 版本（去掉 +build）
    if ($currentVersion -match '^(\d+\.\d+\.\d+)') {
        $baseVersion = $Matches[1]
    } else {
        $baseVersion = $currentVersion
    }

    return $baseVersion
}

function Get-NextVersion100 {
    $currentVersion = Get-CurrentVersion

    # 分割 base 版本号
    $versionParts = $currentVersion.Split('.')
    $major = [int]$versionParts[0]
    $minor = [int]$versionParts[1]
    $patch = [int]$versionParts[2]

    # 100 进制递增
    $patch++
    if ($patch -ge 100) { $patch = 0; $minor++ }
    if ($minor -ge 100) { $minor = 0; $major++ }

    return "$major.$minor.$patch"
}

function Get-PrevVersion100 {
    $currentVersion = Get-CurrentVersion

    # 分割 base 版本号
    $versionParts = $currentVersion.Split('.')
    $major = [int]$versionParts[0]
    $minor = [int]$versionParts[1]
    $patch = [int]$versionParts[2]

    # 100 进制递减
    $patch--
    if ($patch -lt 0) {
        $patch = 99
        $minor--
        if ($minor -lt 0) {
            $minor = 99
            if ($major -gt 0) {
                $major--
            } else {
                # 已经到 0.0.0，不允许再减
                $minor = 0
                $patch = 0
            }
        }
    }

    return "$major.$minor.$patch"
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
    Write-Host "✅ pubspec.yaml 已更新为版本 $newVersion"
}

function Commit-Changes {
    param([string]$new_version)
    if (git diff --quiet) {
        Write-Host "⚠ 没有未提交的改动，跳过 commit" -ForegroundColor Yellow
    } else {
        git add pubspec.yaml
        git commit -m "Bump version to $new_version"
        Write-Host "✅ 自动提交完成"
    }
}

# 显示两个版本间的提交日志，过滤 Bump version 消息
function Show-Changelog {
    param([string]$prev_tag, [string]$curr_ref)
    Write-Host ""
    Write-Host "========== 自上一标签以来的提交日志 ==========" -ForegroundColor Cyan
    if ([string]::IsNullOrEmpty($prev_tag)) {
        git log $curr_ref --oneline --no-decorate | Select-String -NotMatch "Bump version to"
    } else {
        git log "$prev_tag..$curr_ref" --oneline --no-decorate | Select-String -NotMatch "Bump version to"
    }
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
}

# 获取最新的非当前版本标签
function Get-PreviousTag {
    param([string]$current_tag)
    $tags = git tag -l "v*" --sort=-version:refname
    $tags | Where-Object { $_ -ne $current_tag } | Select-Object -First 1
}

# 生成标签间 changelog 文件
function Generate-ChangelogFile {
    param([string]$prev_tag, [string]$curr_tag)
    $lines = @()
    $lines += "## 变更日志 ($curr_tag)"
    $lines += ""
    if ([string]::IsNullOrEmpty($prev_tag)) {
        $logLines = git log $curr_tag --oneline --no-decorate | Select-String -NotMatch "Bump version to"
    } else {
        $logLines = git log "$prev_tag..$curr_tag" --oneline --no-decorate | Select-String -NotMatch "Bump version to"
    }
    $lines += $logLines
    $lines += ""
    $lines | Set-Content "RELEASE_CHANGELOG.md" -Encoding UTF8 -Force
    Write-Host "✅ 变更日志已写入 RELEASE_CHANGELOG.md"
}

function Create-Tag {
    param([string]$tag, [string]$commit)
    git tag $tag $commit
    Write-Host "✅ Tag $tag 已创建 (指向 commit $commit)"
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

# ------------------ 主程序 ------------------
Check-Git
$REPO_URL = Get-RemoteUrl
Write-Host "当前远程仓库: $REPO_URL"
Write-Host ""

$CURRENT_VERSION = Get-PrevVersion100
Write-Host "当前版本: $CURRENT_VERSION"
Write-Host ""

Write-Host "选择要执行的操作:"
Write-Host "1) 发布新 Release 版本"
Write-Host "2) 发布 Alpha/Beta/RC 测试版本"
Write-Host "3) 查看最近的 Tags"
Write-Host "4) 查看 Git 日志"
$choice = Read-Host "请选择 (1-4)"

switch ($choice) {
    "1" {
        Clear-Host
        Write-Host "=== 发布新 Release 版本 ==="

        # 获取最新 commit 和上一个 tag
        $latestCommit = git rev-parse HEAD
        $existingTag = git tag --points-at $latestCommit
        $lastTag = Get-PreviousTag -current_tag ""

        if (-not $existingTag) {
            # 最新 commit 无 tag → 自动生成版本号
            $currentVersion = Get-CurrentVersion
            $new_version = Get-NextVersion100
            Write-Host "最新 commit 无 tag，自动生成版本号: $currentVersion"

            # 显示 changelog
            Show-Changelog -prev_tag $lastTag -curr_ref "HEAD"

            # 如果 pubspec.yaml 有改动，则更新并 commit
            if (-not (git diff --quiet)) {
                Update-PubspecVersion $new_version
                Commit-Changes -new_version $new_version
            }
            # 为最新 commit 打 tag
            $tag = "v$currentVersion"
            $newTag = $tag
            Create-Tag -tag $tag -commit $latestCommit
        } else {
            # 最新 commit 已有 tag → 按之前逻辑创建 Bump commit
            $currentVersion = Get-CurrentVersion
            $new_version = Get-NextVersion100
            Write-Host "最新 commit 已有 tag ($existingTag)，创建 Bump commit 并打新 tag" -ForegroundColor Yellow

            # 显示 changelog
            Show-Changelog -prev_tag $lastTag -curr_ref "HEAD"

            Update-PubspecVersion $new_version
            Commit-Changes -new_version $new_version
            $latestCommit = git rev-parse HEAD
            $tag = "v$currentVersion"
            $newTag = $tag
            Create-Tag -tag $tag -commit $latestCommit
        }

        # 生成 changelog 文件
        Generate-ChangelogFile -prev_tag $lastTag -curr_tag $newTag
        Push-Changes

        Write-Host "✅ 发布完成!"
        Write-Host "监控进度: $REPO_URL/actions"
        Write-Host "查看发布: $REPO_URL/releases"
    }
    "2" {
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

        # 显示 changelog
        $lastTag = Get-PreviousTag -current_tag ""
        Show-Changelog -prev_tag $lastTag -curr_ref "HEAD"

        $confirm = Read-Host "继续? (y/n)"
        if ($confirm -ne 'y') { Write-Host "已取消"; exit 0 }

        Create-Tag -tag $tag -commit (git rev-parse HEAD)
        Push-Changes

        Write-Host "✅ 成功! 这个测试版本会被标记为 prerelease"
        Write-Host "监控进度: $REPO_URL/actions"
    }
    "3" {
        Clear-Host
        Write-Host "=== 最近的 Tags ==="
        git tag -l "v*" --sort=-version:refname
        Write-Host ""
        Write-Host "--- 最新两个 Tag 间的提交日志 ---" -ForegroundColor Cyan
        $tags = git tag -l "v*" --sort=-version:refname | Select-Object -First 2
        if ($tags.Count -ge 2) {
            git log "$($tags[1])..$($tags[0])" --oneline --no-decorate | Select-String -NotMatch "Bump version to"
        } elseif ($tags.Count -eq 1) {
            git log "$($tags[0])" --oneline --no-decorate | Select-String -NotMatch "Bump version to"
        }
    }
    "4" {
        Clear-Host
        Write-Host "=== Git 日志 (最后 20 条提交) ==="
        git log --oneline -20
        Write-Host ""
        Write-Host "--- 过滤 Bump version 后的日志 ---" -ForegroundColor Cyan
        git log --oneline -20 --no-decorate | Select-String -NotMatch "Bump version to"
    }
    default {
        Write-Host "❌ 无效选择" -ForegroundColor Red
    }
}

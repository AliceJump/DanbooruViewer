#!/bin/bash
# Danbooru Viewer - Release Helper Script
# 功能: 自动获取 GitHub URL、自动生成100进制版本号、检测最新 commit 是否已有 tag、
#       智能处理自动 commit/tag、支持 Release/Alpha/Beta/RC、查看 Tags/Git 日志
# 参考: release.ps1

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── 工具函数 ──────────────────────────────────────────────────

check_git() {
    if ! command -v git &> /dev/null; then
        echo -e "${RED}❌ 错误: 未找到 git 命令${NC}"
        exit 1
    fi
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        echo -e "${RED}❌ 错误: 不在 git 仓库中${NC}"
        exit 1
    fi
}

get_remote_url() {
    local url
    url=$(git remote get-url origin 2>/dev/null)
    # 去掉末尾的 .git
    echo "$url" | sed 's/\.git$//'
}

get_current_version() {
    # 解析 base 版本（去掉 +build）
    local line
    line=$(grep "^version:" pubspec.yaml | head -1)
    local cv
    cv=$(echo "$line" | awk '{print $2}')
    echo "$cv" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

# 100 进制递增版本号
get_next_version_100() {
    local cv
    cv=$(get_current_version)
    local major minor patch
    IFS='.' read -r major minor patch <<< "$cv"
    # 去除前导零
    major=$((10#$major))
    minor=$((10#$minor))
    patch=$((10#$patch))
    patch=$((patch + 1))
    if [ "$patch" -ge 100 ]; then
        patch=0
        minor=$((minor + 1))
    fi
    if [ "$minor" -ge 100 ]; then
        minor=0
        major=$((major + 1))
    fi
    echo "$major.$minor.$patch"
}

# 100 进制递减版本号（用于显示当前版本）
get_prev_version_100() {
    local cv
    cv=$(get_current_version)
    local major minor patch
    IFS='.' read -r major minor patch <<< "$cv"
    major=$((10#$major))
    minor=$((10#$minor))
    patch=$((10#$patch))
    patch=$((patch - 1))
    if [ "$patch" -lt 0 ]; then
        patch=99
        minor=$((minor - 1))
        if [ "$minor" -lt 0 ]; then
            minor=99
            if [ "$major" -gt 0 ]; then
                major=$((major - 1))
            else
                minor=0
                patch=0
            fi
        fi
    fi
    echo "$major.$minor.$patch"
}

update_pubspec_version() {
    local new_version="$1"
    local pubspec
    pubspec=$(cat pubspec.yaml)
    local old_build
    old_build=$(grep "^version:" pubspec.yaml | head -1 | sed -n 's/.*+\([0-9]*\)$/\1/p')

    if [ -n "$old_build" ]; then
        sed -i "s/^version: .*/version: $new_version+$old_build/" pubspec.yaml
    else
        sed -i "s/^version: .*/version: $new_version/" pubspec.yaml
    fi
    echo -e "${GREEN}✅ pubspec.yaml 已更新为版本 $new_version${NC}"
}

commit_changes() {
    local new_version="$1"
    if git diff --quiet; then
        echo -e "${YELLOW}⚠ 没有未提交的改动，跳过 commit${NC}"
    else
        git add pubspec.yaml
        git commit -m "Bump version to $new_version"
        echo -e "${GREEN}✅ 自动提交完成${NC}"
    fi
}

create_tag() {
    local tag="$1"
    local commit="$2"
    git tag "$tag" "$commit"
    echo -e "${GREEN}✅ Tag $tag 已创建 (指向 commit $commit)${NC}"
}

push_changes() {
    local branch
    branch=$(git branch --show-current)
    echo -e "${YELLOW}⏳ 推送 Tag 和提交到分支 '$branch'...${NC}"
    if ! git push origin "$branch" --tags; then
        echo -e "${RED}❌ 推送失败，请检查网络或权限${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 推送成功${NC}"
}

# 显示两个版本间的提交日志，过滤 Bump version 消息
show_changelog() {
    local prev_tag="$1"
    local curr_ref="$2"
    echo ""
    echo -e "${CYAN}========== 自上一标签以来的提交日志 ==========${NC}"
    if [ -z "$prev_tag" ]; then
        git log "$curr_ref" --oneline --no-decorate | grep -v "Bump version to"
    else
        git log "$prev_tag..$curr_ref" --oneline --no-decorate | grep -v "Bump version to"
    fi
    echo -e "${CYAN}============================================${NC}"
    echo ""
}

# 获取最新的非当前版本标签（用于 changelog 比对）
get_previous_tag() {
    local current_tag="$1"
    git tag -l 'v*' --sort=-version:refname | grep -v "^$current_tag$" | head -1
}

# 生成标签间 changelog（纯文本，不含颜色，用于写入文件）
generate_changelog_text() {
    local prev_tag="$1"
    local curr_tag="$2"
    local output_file="$3"
    echo "## 变更日志 ($curr_tag)" > "$output_file"
    echo "" >> "$output_file"
    if [ -z "$prev_tag" ]; then
        git log "$curr_tag" --oneline --no-decorate | grep -v "Bump version to" >> "$output_file"
    else
        git log "$prev_tag..$curr_tag" --oneline --no-decorate | grep -v "Bump version to" >> "$output_file"
    fi
    echo "" >> "$output_file"
}

# ── 主程序 ─────────────────────────────────────────────────────

check_git
REPO_URL=$(get_remote_url)
echo -e "${BLUE}当前远程仓库: $REPO_URL${NC}"
echo ""

CURRENT_VERSION=$(get_prev_version_100)
echo -e "${GREEN}当前版本: $CURRENT_VERSION${NC}"
echo ""

echo "选择要执行的操作:"
echo "1) 发布新 Release 版本"
echo "2) 发布 Alpha/Beta/RC 测试版本"
echo "3) 查看最近的 Tags"
echo "4) 查看 Git 日志"
echo ""
read -p "请选择 (1-4): " choice

case $choice in
    1)
        echo ""
        echo "=== 发布新 Release 版本 ==="
        echo ""

        LATEST_COMMIT=$(git rev-parse HEAD)
        EXISTING_TAG=$(git tag --points-at "$LATEST_COMMIT")

        # 获取上一个 tag 用于显示 changelog
        LAST_TAG=$(get_previous_tag "")

        if [ -z "$EXISTING_TAG" ]; then
            # 最新 commit 无 tag → 自动生成版本号
            CURRENT_BASE=$(get_current_version)
            NEW_VERSION=$(get_next_version_100)
            echo -e "${CYAN}最新 commit 无 tag，自动生成版本号: $CURRENT_BASE${NC}"

            # 显示 changelog
            show_changelog "$LAST_TAG" "HEAD"

            # 如果 pubspec.yaml 有改动，则更新并 commit
            if ! git diff --quiet; then
                update_pubspec_version "$NEW_VERSION"
                commit_changes "$NEW_VERSION"
            fi

            # 为最新 commit 打 tag（使用旧版本号，与 PS1 一致）
            TAG="v$CURRENT_BASE"
            NEW_TAG="$TAG"
            create_tag "$TAG" "$LATEST_COMMIT"
        else
            # 最新 commit 已有 tag → 按之前逻辑创建 Bump commit
            CURRENT_BASE=$(get_current_version)
            NEW_VERSION=$(get_next_version_100)
            echo -e "${YELLOW}最新 commit 已有 tag ($EXISTING_TAG)，创建 Bump commit 并打新 tag${NC}"

            # 显示 changelog
            show_changelog "$LAST_TAG" "HEAD"

            update_pubspec_version "$NEW_VERSION"
            commit_changes "$NEW_VERSION"
            LATEST_COMMIT=$(git rev-parse HEAD)
            TAG="v$CURRENT_BASE"
            NEW_TAG="$TAG"
            create_tag "$TAG" "$LATEST_COMMIT"
        fi

        # 生成 changelog 文件供后续使用
        generate_changelog_text "$LAST_TAG" "$NEW_TAG" "RELEASE_CHANGELOG.md"
        echo -e "${GREEN}✅ 变更日志已写入 RELEASE_CHANGELOG.md${NC}"

        push_changes

        echo ""
        echo -e "${GREEN}✅ 发布完成!${NC}"
        echo "监控进度: $REPO_URL/actions"
        echo "查看发布: $REPO_URL/releases"
        ;;

    2)
        echo ""
        echo "=== 发布测试版本 ==="
        echo ""
        echo "选择版本类型:"
        echo "1) Alpha"
        echo "2) Beta"
        echo "3) RC"
        echo ""
        read -p "请选择 (1-3): " type_choice

        case $type_choice in
            1) pre_type="alpha" ;;
            2) pre_type="beta" ;;
            3) pre_type="rc" ;;
            *) echo -e "${RED}❌ 无效选择${NC}"; exit 1 ;;
        esac

        read -p "输入测试版本号 (例: 1.1.0-$pre_type.1): " test_version
        TAG="v$test_version"

        echo ""
        echo "准备发布:"
        echo "  版本号: $test_version"
        echo "  Git Tag: $TAG"
        echo ""

        # 显示 changelog
        LAST_TAG=$(get_previous_tag "")
        show_changelog "$LAST_TAG" "HEAD"

        read -p "继续? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo "已取消"
            exit 0
        fi

        create_tag "$TAG" "$(git rev-parse HEAD)"
        push_changes

        echo ""
        echo -e "${GREEN}✅ 成功! 这个测试版本会被标记为 prerelease${NC}"
        echo "监控进度: $REPO_URL/actions"
        ;;

    3)
        echo ""
        echo "=== 最近的 Tags ==="
        echo ""
        git tag -l 'v*' --sort=-version:refname
        echo ""
        echo -e "${CYAN}--- 最新两个 Tag 间的提交日志 ---${NC}"
        tags=($(git tag -l 'v*' --sort=-version:refname | head -2))
        if [ ${#tags[@]} -ge 2 ]; then
            git log "${tags[1]}..${tags[0]}" --oneline --no-decorate | grep -v "Bump version to"
        elif [ ${#tags[@]} -eq 1 ]; then
            git log "${tags[0]}" --oneline --no-decorate | grep -v "Bump version to"
        fi
        ;;

    4)
        echo ""
        echo "=== Git 日志 (最后 20 条提交) ==="
        echo ""
        git log --oneline -20
        echo ""
        echo -e "${CYAN}--- 过滤 Bump version 后的日志 ---${NC}"
        git log --oneline -20 --no-decorate | grep -v "Bump version to"
        ;;

    *)
        echo -e "${RED}❌ 无效选择${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"

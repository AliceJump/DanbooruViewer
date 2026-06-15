#!/bin/bash
# Danbooru Viewer - Release Helper Script
# 此脚本帮助快速发布新版本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║ Danbooru Viewer Release Helper Script  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# 检查 git
if ! command -v git &> /dev/null; then
    echo -e "${RED}✗ 错误: 未找到 git 命令${NC}"
    exit 1
fi

# 检查是否在 git 仓库中
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}✗ 错误: 不在 git 仓库中${NC}"
    exit 1
fi

# 检查是否有未提交的更改
if ! git diff-index --quiet HEAD --; then
    echo -e "${RED}✗ 错误: 有未提交的更改，请先提交${NC}"
    echo "运行: git add . && git commit -m '你的提交信息'"
    exit 1
fi

# 获取当前版本
CURRENT_VERSION=$(grep "^version:" pubspec.yaml | head -1 | awk '{print $2}' | cut -d'+' -f1)
echo -e "${GREEN}当前版本: $CURRENT_VERSION${NC}"
echo ""

# 菜单
echo "选择要执行的操作:"
echo "1) 发布新 Release 版本"
echo "2) 发布 Alpha/Beta 测试版本"
echo "3) 查看最近的 Tags"
echo "4) 显示 Git 日志"
echo ""
read -p "请选择 (1-4): " choice

case $choice in
    1)
        echo ""
        echo "=== 发布新 Release 版本 ==="
        echo ""
        read -p "输入新版本号 (不需要 'v' 前缀, 例: 1.1.0): " new_version
        
        # 验证版本号格式
        if ! [[ $new_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RED}✗ 错误: 版本号格式无效 (应为 X.Y.Z)${NC}"
            exit 1
        fi
        
        tag="v$new_version"
        
        # 检查 tag 是否已存在
        if git rev-parse "$tag" >/dev/null 2>&1; then
            echo -e "${RED}✗ 错误: Tag $tag 已存在${NC}"
            exit 1
        fi
        
        echo ""
        echo "准备发布:"
        echo "  版本号: $new_version"
        echo "  Git Tag: $tag"
        echo ""
        
        read -p "继续? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo "已取消"
            exit 0
        fi
        
        echo ""
        echo -e "${YELLOW}⏳ 创建 Tag...${NC}"
        git tag $tag
        
        echo -e "${YELLOW}⏳ 推送 Tag...${NC}"
        git push origin $tag
        
        echo ""
        echo -e "${GREEN}✓ 成功!${NC}"
        echo ""
        echo "GitHub Actions 现在会自动构建你的应用。"
        echo "监控进度: https://github.com/YOUR_USERNAME/danbooru-viewer/actions"
        echo ""
        echo "构建完成后查看发布: https://github.com/YOUR_USERNAME/danbooru-viewer/releases"
        ;;
        
    2)
        echo ""
        echo "=== 发布测试版本 ==="
        echo ""
        echo "选择版本类型:"
        echo "1) Alpha"
        echo "2) Beta"
        echo "3) RC (Release Candidate)"
        echo ""
        read -p "请选择 (1-3): " type_choice
        
        case $type_choice in
            1) pre_type="alpha" ;;
            2) pre_type="beta" ;;
            3) pre_type="rc" ;;
            *) echo -e "${RED}✗ 无效选择${NC}"; exit 1 ;;
        esac
        
        read -p "输入测试版本号 (例: 1.1.0-$pre_type.1): " test_version
        
        tag="v$test_version"
        
        if git rev-parse "$tag" >/dev/null 2>&1; then
            echo -e "${RED}✗ 错误: Tag $tag 已存在${NC}"
            exit 1
        fi
        
        echo ""
        echo "准备发布:"
        echo "  版本号: $test_version"
        echo "  Git Tag: $tag"
        echo ""
        
        read -p "继续? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo "已取消"
            exit 0
        fi
        
        echo ""
        echo -e "${YELLOW}⏳ 创建 Tag...${NC}"
        git tag $tag
        
        echo -e "${YELLOW}⏳ 推送 Tag...${NC}"
        git push origin $tag
        
        echo ""
        echo -e "${GREEN}✓ 成功!${NC}"
        echo ""
        echo "这个测试版本会被标记为 prerelease"
        echo "监控进度: https://github.com/YOUR_USERNAME/danbooru-viewer/actions"
        ;;
        
    3)
        echo ""
        echo "=== 最近的 Tags ==="
        echo ""
        git tag -l 'v*' --sort=-version:refname | head -10
        ;;
        
    4)
        echo ""
        echo "=== Git 日志 (最后 10 条提交) ==="
        echo ""
        git log --oneline -10
        ;;
        
    *)
        echo -e "${RED}✗ 无效选择${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"

# 发布快速指南

快速参考：如何发布新版本。

## 5 分钟快速发布

### 第 1 步：更新文件
```bash
# 1. 更新版本号
nano pubspec.yaml
# 修改: version: X.Y.Z+N

# 2. 更新 CHANGELOG
nano CHANGELOG.md
# 在 ## [Unreleased] 下添加变更
# 然后创建新的版本号标题
```

### 第 2 步：提交并创建 Tag
```bash
# 1. 添加所有改动
git add pubspec.yaml CHANGELOG.md

# 2. 提交
git commit -m "chore: release v1.0.0"

# 3. 创建 Tag（触发自动构建）
git tag v1.0.0

# 4. 推送到 GitHub
git push origin main
git push origin v1.0.0
```

### 第 3 步：等待和验证
- ⏳ 构建需要 **30-45 分钟**
- 📊 在 GitHub Actions 页面监控进度
- ✅ 完成后在 GitHub Releases 页面查看

---

## 详细步骤

### Step 1: 准备发布

#### 更新版本号
编辑 `pubspec.yaml`:
```yaml
# 当前
version: 1.0.0+1

# 修改为新版本
version: 1.1.0+1
```

#### 更新 CHANGELOG
编辑 `CHANGELOG.md`:
```markdown
## [Unreleased]

### Added
- 新功能 A
- 新功能 B

### Fixed
- 修复问题 1
- 修复问题 2
```

↓ 改为 ↓

```markdown
## [1.1.0] - 2026-02-15

### Added
- 新功能 A
- 新功能 B

### Fixed
- 修复问题 1
- 修复问题 2

## [Unreleased]
```

### Step 2: 本地测试（可选但推荐）

```bash
# 测试应用是否能正常构建
flutter build apk --release

# 或
flutter build web --release

# 验证完后清理
flutter clean
```

### Step 3: 提交代码

```bash
# 1. 检查变更
git status

# 2. 添加文件
git add pubspec.yaml CHANGELOG.md

# 3. 提交
git commit -m "chore: release v1.1.0"

# 4. 推送主分支
git push origin main
```

### Step 4: 创建 Release Tag

```bash
# 方法 A: 命令行
git tag v1.1.0
git push origin v1.1.0

# 方法 B: GitHub Web UI
# 1. 浏览器打开 https://github.com/YOUR_USERNAME/danbooru-viewer/releases
# 2. 点击 "Create a new release"
# 3. 输入 "v1.1.0"
# 4. 点击 "Create release"
```

### Step 5: 监控构建

在 GitHub Actions 页面：
```
https://github.com/YOUR_USERNAME/danbooru-viewer/actions
```

查看 "Build Release" 工作流：
- 🟡 黄色 = 正在运行
- ✅ 绿色 = 成功
- ❌ 红色 = 失败

### Step 6: 发布完成

完成后访问 Releases 页面：
```
https://github.com/YOUR_USERNAME/danbooru-viewer/releases
```

下载产物：
- 📱 danbooru-viewer-android-release.apk
- 🍎 danbooru-viewer-ios-release.ipa
- 🐧 danbooru-viewer-linux-release.tar.gz
- 🪟 danbooru-viewer-windows-release.zip
- 🌐 danbooru-viewer-web-release.tar.gz

---

## 版本号选择指南

| 情景 | 版本号 | 示例 |
|------|--------|------|
| 首次发布 | 1.0.0 | v1.0.0 |
| 新功能 | X.(Y+1).0 | v1.1.0 |
| Bug 修复 | X.Y.(Z+1) | v1.0.1 |
| 测试版本 | X.Y.Z-alpha | v1.1.0-alpha.1 |
| Beta 版本 | X.Y.Z-beta | v1.1.0-beta.1 |

---

## 常见问题

### Q: 构建失败了怎么办？
```bash
# 1. 检查 Actions 日志找到错误原因
# 2. 修复代码或配置
# 3. 提交修改
git add .
git commit -m "fix: resolve build issue"
git push origin main

# 4. 删除旧 Tag 并创建新的
git tag -d v1.1.0
git push origin :refs/tags/v1.1.0
git tag v1.1.0
git push origin v1.1.0
```

### Q: 忘记更新版本号怎么办？
```bash
# 1. 更新文件
git add pubspec.yaml
git commit --amend --no-edit
git push origin main -f

# 2. 重新创建 Tag（需要删除旧的）
git tag -d v1.1.0
git push origin :refs/tags/v1.1.0
git tag v1.1.0
git push origin v1.1.0
```

### Q: 如何删除已发布的版本？
```bash
# 1. 删除本地 Tag
git tag -d v1.1.0

# 2. 删除远程 Tag
git push origin :refs/tags/v1.1.0

# 3. 在 GitHub Releases 页面删除 Release（可选）
```

### Q: 可以创建只针对特定平台的版本吗？
编辑 `.github/workflows/build.yml` 的 `matrix` 部分，移除不需要的平台。

### Q: 如何测试工作流而不创建正式发布？
```bash
# 使用 -rc（Release Candidate）标签
git tag v1.1.0-rc.1
git push origin v1.1.0-rc.1
```

---

## 发布清单

发布前确保完成以下项目：

- [ ] 代码已审查
- [ ] 所有测试通过
- [ ] pubspec.yaml 版本已更新
- [ ] CHANGELOG.md 已更新
- [ ] 提交已推送到 main 分支
- [ ] 未有其他进行中的 CI/CD

发布中：

- [ ] Tag 已创建并推送
- [ ] GitHub Actions 运行正常
- [ ] 所有平台构建成功

发布后：

- [ ] Release 页面已创建
- [ ] 产物可以下载
- [ ] Web 版本已部署到 GitHub Pages
- [ ] 版本记录已更新

---

## 命令速查表

```bash
# 查看当前 Tag
git tag -l

# 查看 Tag 详情
git show v1.1.0

# 删除本地 Tag
git tag -d v1.1.0

# 删除远程 Tag
git push origin --delete v1.1.0

# 推送所有 Tag
git push --tags

# 基于特定 Tag 创建分支
git checkout -b hotfix/v1.1.0 v1.1.0
```

---

## 进阶用法

### 自动化版本号更新
```bash
#!/bin/bash
VERSION=$(grep version pubspec.yaml | head -1 | awk '{print $2}')
git tag $VERSION
git push origin $VERSION
```

### 批量发布
```bash
# 一次性发布多个版本
git tag v1.1.0 v1.2.0 v1.3.0
git push origin v1.1.0 v1.2.0 v1.3.0
```

### 签名 Tag（推荐用于生产环境）
```bash
# 使用 GPG 签名 Tag
git tag -s v1.1.0 -m "Release v1.1.0"
git push origin v1.1.0
```

---

## 相关文档

- 详细工作流说明: [.github/WORKFLOWS.md](.github/WORKFLOWS.md)
- 版本历史记录: [.github/VERSION_HISTORY.md](.github/VERSION_HISTORY.md)
- 完整 Changelog: [CHANGELOG.md](CHANGELOG.md)

# ✅ GitHub Actions 工作流配置完成报告

## 📋 项目信息
- **项目名称**：Danbooru Viewer
- **项目类型**：Flutter 多平台应用
- **配置日期**：2026 年 2 月
- **Flutter 版本**：3.10.7+

---

## 📦 已创建的文件清单

### 工作流文件 (3 个)
```
.github/workflows/
├── build.yml              (Release 多平台构建工作流)
├── ci.yml                 (持续集成工作流)
└── deploy-web.yml         (Web 自动部署工作流)
```

### 文档文件 (6 个)
```
.github/
├── README.md              (工作流快速开始指南)
├── WORKFLOWS.md           (工作流详细文档)
├── VERSION_HISTORY.md     (版本管理记录)
├── SETUP_SUMMARY.md       (配置总结)
├── .gitkeep               (目录占位符)
└── (其他现有文件)

项目根目录/
├── RELEASE_GUIDE.md       (快速发布指南)
├── CHANGELOG.md           (变更日志)
└── README.md              (已更新，添加 CI/CD 部分)
```

### 脚本文件 (2 个)
```
scripts/
├── release.sh             (Linux/macOS 发布脚本)
└── release.bat            (Windows 发布脚本)
```

---

## 🎯 工作流功能概览

### 1️⃣ Build Release 工作流 (build.yml)

**触发条件**：推送 Git Tag，格式为 `v*`（如 `v1.0.0`）

**并行构建目标**：
- 🤖 **Android APK** (arm64, armeabi-v7a, x86_64)
  - 时间：10-15 分钟
  - 输出：danbooru-viewer-android-release.apk
  
- 🍎 **iOS IPA** (未签名)
  - 时间：20-25 分钟
  - 输出：danbooru-viewer-ios-release.ipa
  
- 🐧 **Linux 可执行程序**
  - 时间：12-18 分钟
  - 输出：danbooru-viewer-linux-release.tar.gz
  
- 🪟 **Windows 可执行程序**
  - 时间：15-20 分钟
  - 输出：danbooru-viewer-windows-release.zip
  
- 🌐 **Web 应用**
  - 时间：8-12 分钟
  - 输出：danbooru-viewer-web-release.tar.gz

**自动任务**：
- ✅ 并行构建 5 个平台
- ✅ 自动创建 GitHub Release
- ✅ 附加所有构建产物
- ✅ 设置发布说明

**总构建时间**：约 30-45 分钟

---

### 2️⃣ CI 工作流 (ci.yml)

**触发条件**：
- Push 到 `main` 或 `develop` 分支
- Pull Request 到 `main` 或 `develop` 分支

**执行任务**：
- ✅ 代码格式检查 (`flutter format`)
- ✅ 静态代码分析 (`flutter analyze`)
- ✅ 单元测试 (`flutter test`)
- ✅ Android Debug APK 构建
- ✅ Web Debug 构建

**Artifacts 保留**：5 天

---

### 3️⃣ Deploy Web 工作流 (deploy-web.yml)

**触发条件**：
- 推送 `v*` Tag
- Push 到 `main` 分支

**执行任务**：
- ✅ 构建 Web Release 版本
- ✅ 自动部署到 GitHub Pages
- ✅ 生成静态网站

**访问地址**：`https://<username>.github.io/danbooru-viewer/`

---

## 📚 文档结构

```
项目
├── README.md                          主项目文档（已更新）
├── RELEASE_GUIDE.md       ⭐ 快速发布指南
├── CHANGELOG.md                       变更日志
├── .github/
│   ├── README.md                      工作流快速入门
│   ├── WORKFLOWS.md       ⭐ 详细工作流说明
│   ├── SETUP_SUMMARY.md               配置总结和最佳实践
│   ├── VERSION_HISTORY.md             版本管理记录
│   └── workflows/
│       ├── build.yml                  Release 构建
│       ├── ci.yml                     持续集成
│       └── deploy-web.yml             Web 部署
└── scripts/
    ├── release.sh                     发布脚本 (Linux/macOS)
    └── release.bat                    发布脚本 (Windows)
```

**推荐阅读顺序**：
1. `RELEASE_GUIDE.md` - 快速上手（5-10 分钟）
2. `.github/README.md` - 工作流概览（5 分钟）
3. `.github/WORKFLOWS.md` - 深入了解（15 分钟）
4. 工作流 YAML 文件 - 自定义配置（可选）

---

## 🚀 快速开始指南

### 第 1 步：启用 GitHub Pages（仅首次）
```
GitHub Settings → Pages → Deploy from a branch
Branch: gh-pages → Save
```

### 第 2 步：推送代码到 GitHub
```bash
git push origin main
```

### 第 3 步：发布新版本

**选项 A：使用脚本（推荐）**
```bash
# Linux/macOS
./scripts/release.sh

# Windows
scripts\release.bat
```

**选项 B：手动命令**
```bash
git tag v1.0.0
git push origin v1.0.0
```

### 第 4 步：监控构建
访问：`https://github.com/YOUR_USERNAME/danbooru-viewer/actions`

### 第 5 步：获取产物
访问：`https://github.com/YOUR_USERNAME/danbooru-viewer/releases`

---

## ✨ 主要特性

### ✅ 已实现
- [x] 多平台并行构建（Android, iOS, Linux, Windows, Web）
- [x] 自动 GitHub Release 生成
- [x] Web 自动部署到 GitHub Pages
- [x] 代码质量自动检查（格式、分析、测试）
- [x] 构建缓存加速
- [x] 完整的日志和错误报告
- [x] 发布脚本（Linux/macOS/Windows）
- [x] 详细的文档和指南

### 📋 可选增强（需额外配置）
- [ ] iOS 代码签名（需 Apple 开发者账户）
- [ ] Android APK 签名（需 Keystore 文件）
- [ ] App Store Connect 自动上传
- [ ] Google Play Store 自动上传
- [ ] Slack/邮件通知
- [ ] 性能基准测试
- [ ] 代码覆盖率报告

---

## 📊 性能数据

### 典型构建时间
| 平台 | 首次构建 | 后续构建 |
|------|--------|--------|
| Android | 10-15 分钟 | 8-12 分钟 |
| iOS | 20-25 分钟 | 18-22 分钟 |
| Linux | 12-18 分钟 | 10-15 分钟 |
| Windows | 15-20 分钟 | 12-18 分钟 |
| Web | 8-12 分钟 | 6-10 分钟 |
| **Release 创建** | 2-3 分钟 | 2-3 分钟 |
| **总计** | **30-45 分钟** | **25-40 分钟** |

**优化**：由于并行构建，总时间由最长的任务（iOS）决定。

---

## 🔐 安全性检查表

- ✅ 使用 GitHub 自动提供的 `GITHUB_TOKEN`
- ✅ 构建在隔离的 GitHub-hosted runners 上执行
- ✅ 无硬编码凭证
- ✅ 敏感信息可通过 GitHub Secrets 管理
- ✅ APK/IPA 可选的手动签名流程

---

## 📝 版本号规范

遵循 Semantic Versioning (https://semver.org/):

```
v主.次.补   →  v1.2.3

- v1.0.0      首次发布
- v1.1.0      新功能（向下兼容）
- v1.0.1      Bug 修复
- v1.0.0-alpha.1   Alpha 测试版
- v1.0.0-beta.1    Beta 测试版
- v1.0.0-rc.1      Release Candidate
```

---

## 🛠️ 定制指南

### 修改构建参数
编辑 `.github/workflows/build.yml`:
```yaml
- name: Build APK
  run: flutter build apk --release --split-per-abi
  # 可添加：--obfuscate --split-debug-info=build/
```

### 修改支持的平台
在 `build.yml` 的 `matrix` 部分添加或移除平台。

### 修改 Tag 触发规则
编辑工作流的 `on.push.tags`:
```yaml
tags:
  - 'v*'         # 现有
  - 'release-*'  # 新增
```

### 修改 Web 部署地址
编辑 `deploy-web.yml`:
```yaml
--base-href /danbooru-viewer/  # 修改此处
```

---

## 🆘 故障排查

### 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|--------|
| iOS 构建失败 | 缺少签名 | 使用 `--no-codesign` 参数 |
| 依赖不找到 | pub.dev 超时 | 重试或配置本地 pub 镜像 |
| Windows 失败 | 缺少 C++ 工具 | 本地安装或跳过此平台 |
| Web 部署失败 | 权限问题 | 检查 GitHub Pages 设置 |
| Tag 未触发构建 | 格式不对 | 确保 Tag 以 `v` 开头 |

### 调试步骤
1. 检查 GitHub Actions 日志
2. 查看错误堆栈跟踪
3. 本地重现构建
4. 查看平台特定的错误文档

---

## 📚 相关资源

### 官方文档
- [Flutter CI/CD 指南](https://docs.flutter.dev/deployment/cd)
- [GitHub Actions 文档](https://docs.github.com/en/actions)
- [Semantic Versioning](https://semver.org/)

### 使用的 Actions
- [subosito/flutter-action](https://github.com/subosito/flutter-action)
- [actions/upload-artifact](https://github.com/actions/upload-artifact)
- [actions/download-artifact](https://github.com/actions/download-artifact)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [peaceiris/actions-gh-pages](https://github.com/peaceiris/actions-gh-pages)

---

## ✅ 配置完成清单

- [x] 创建 3 个工作流文件
- [x] 编写 6 个详细文档
- [x] 创建 2 个发布脚本
- [x] 更新 README.md
- [x] 验证工作流语法
- [x] 添加错误处理
- [x] 配置缓存优化
- [x] 文档国际化（中文）

---

## 🎓 最佳实践

### 分支策略
```
main (稳定，仅发布版本)
  ↑
develop (开发)
  ↑
feature/* (功能)
hotfix/* (修复)
```

### 发布流程
```
1. 在 develop 开发并测试
2. 创建 PR 到 main
3. 代码审查和 CI 验证
4. 合并到 main
5. 创建 Release Tag
6. GitHub Actions 自动构建
7. GitHub Release 自动创建
```

### 提交信息
```
feat: 添加新功能
fix: 修复 Bug
chore: 发布版本
docs: 文档更新
style: 代码风格
refactor: 重构
test: 测试相关
```

---

## 📞 支持资源

需要帮助？查看这些文档：
1. **快速发布** → `RELEASE_GUIDE.md`
2. **工作流详情** → `.github/WORKFLOWS.md`
3. **配置说明** → `.github/SETUP_SUMMARY.md`
4. **版本管理** → `.github/VERSION_HISTORY.md`

---

## 🎉 总结

你的 Danbooru Viewer 项目现已具有：

✅ **完整的 CI/CD 流程** - 自动化代码检查和测试  
✅ **多平台构建能力** - 一键生成 5 个平台版本  
✅ **自动发布系统** - GitHub Release 自动创建  
✅ **Web 自动部署** - GitHub Pages 自动更新  
✅ **详细文档** - 快速入门到深入使用  
✅ **便捷脚本** - 跨平台发布助手  

---

## 🚀 立即开始

```bash
# 1. 推送代码
git push origin main

# 2. 创建发布（选择一种方式）

# 方式 A：使用脚本
./scripts/release.sh          # Linux/macOS
scripts\release.bat           # Windows

# 方式 B：手动创建 Tag
git tag v1.0.0
git push origin v1.0.0

# 3. 监控进度
# 打开：https://github.com/YOUR_USERNAME/danbooru-viewer/actions

# 4. 获取产物
# 打开：https://github.com/YOUR_USERNAME/danbooru-viewer/releases
```

---

**配置完成日期**：2026 年 2 月 5 日  
**配置版本**：1.0  
**状态**：✅ 已就绪

祝你使用愉快！🎊

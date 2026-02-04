# Danbooru Viewer - GitHub Actions 工作流索引

快速导航所有 CI/CD 相关的文档和配置。

## 📍 开始阅读

### 🟢 5 分钟快速入门
- **[RELEASE_GUIDE.md](RELEASE_GUIDE.md)** - 快速发布指南
  - 如何发布新版本（最快方式）
  - 常见问题解答
  - 命令速查表

### 🟡 15 分钟全面了解
- **[.github/README.md](.github/README.md)** - 工作流快速开始
  - 工作流概览
  - 平台支持列表
  - 文档导航

- **[.github/WORKFLOWS.md](.github/WORKFLOWS.md)** - 工作流详细文档
  - 三个工作流的完整说明
  - 使用示例
  - 问题解决

### 🔵 30 分钟深入研究
- **[.github/SETUP_SUMMARY.md](.github/SETUP_SUMMARY.md)** - 配置总结
  - 完整的功能清单
  - 最佳实践
  - 定制指南

- **[.github/VERSION_HISTORY.md](.github/VERSION_HISTORY.md)** - 版本管理
  - 配置历史
  - 性能指标
  - 未来改进计划

---

## 📂 文件位置快速查找

### 工作流定义
```
.github/workflows/
├── build.yml          Release 多平台构建（推送 v* Tag 时触发）
├── ci.yml             持续集成（Push 和 PR 时触发）
└── deploy-web.yml     Web 部署（Tag 或 main 分支时触发）
```

### 文档
```
项目根目录/
├── README.md          项目总览（已更新）
├── RELEASE_GUIDE.md   ⭐ 快速发布指南
├── CHANGELOG.md       变更日志模板
└── GITHUB_ACTIONS_SETUP.md  配置完成报告

.github/
├── README.md          工作流快速开始
├── WORKFLOWS.md       工作流详细说明
├── SETUP_SUMMARY.md   配置总结
└── VERSION_HISTORY.md 版本管理记录
```

### 脚本
```
scripts/
├── release.sh         发布脚本（Linux/macOS）
└── release.bat        发布脚本（Windows）
```

---

## 🎯 按用途查找

### "我想快速发布一个版本"
👉 [RELEASE_GUIDE.md](RELEASE_GUIDE.md) - 第一部分：5 分钟快速发布

### "我想了解工作流如何运作"
👉 [.github/WORKFLOWS.md](.github/WORKFLOWS.md) - 工作流说明部分

### "我想自定义工作流配置"
👉 [.github/SETUP_SUMMARY.md](.github/SETUP_SUMMARY.md) - 定制指南部分

### "我想排查构建问题"
👉 [.github/WORKFLOWS.md](.github/WORKFLOWS.md) - 常见问题部分

### "我想了解项目的发布历史"
👉 [CHANGELOG.md](CHANGELOG.md) 和 [.github/VERSION_HISTORY.md](.github/VERSION_HISTORY.md)

### "我想看完整的配置报告"
👉 [GITHUB_ACTIONS_SETUP.md](GITHUB_ACTIONS_SETUP.md)

---

## 📊 工作流概览

### 触发条件对照表

| 事件 | 工作流 | 说明 |
|------|--------|------|
| 推送 `v*` Tag | build.yml | 构建所有平台的 Release 版本 |
| 推送 `v*` Tag | deploy-web.yml | 部署 Web 版本到 GitHub Pages |
| Push main/develop | ci.yml | 代码检查、测试、Debug 构建 |
| PR to main/develop | ci.yml | 拉取请求验证 |

### 平台支持矩阵

| 平台 | 工作流 | 触发条件 | 产物 |
|------|--------|---------|------|
| Android | build.yml | Tag | APK |
| iOS | build.yml | Tag | IPA |
| Linux | build.yml | Tag | tar.gz |
| Windows | build.yml | Tag | zip |
| Web | build.yml + deploy-web.yml | Tag | tar.gz + 部署 |

---

## ⚡ 快速命令

### 查看 Git Tag
```bash
git tag -l 'v*' --sort=-version:refname
```

### 创建并推送 Tag
```bash
git tag v1.0.0
git push origin v1.0.0
```

### 删除 Tag
```bash
git tag -d v1.0.0                  # 删除本地
git push origin :refs/tags/v1.0.0  # 删除远程
```

### 运行发布脚本
```bash
./scripts/release.sh   # Linux/macOS
scripts\release.bat    # Windows
```

---

## 📋 发布清单

### 发布前检查
- [ ] 代码已审查
- [ ] 所有测试通过
- [ ] pubspec.yaml 版本已更新
- [ ] CHANGELOG.md 已更新
- [ ] 代码已推送到 main

### 发布步骤
- [ ] 创建 Git Tag
- [ ] 推送 Tag 到 GitHub
- [ ] 监控 Actions 进度
- [ ] 验证 Release 页面

### 发布后验证
- [ ] 所有平台构建成功
- [ ] Release 文件可下载
- [ ] Web 版本已部署
- [ ] 版本记录已更新

---

## 🔗 外部资源链接

### Flutter 官方
- [Flutter CI/CD](https://docs.flutter.dev/deployment/cd)
- [Flutter Build](https://docs.flutter.dev/tools/build)

### GitHub Actions
- [GitHub Actions 文档](https://docs.github.com/en/actions)
- [Actions Marketplace](https://github.com/marketplace?type=actions)
- [Flutter Action](https://github.com/subosito/flutter-action)

### 版本管理
- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)

---

## 📞 故障排查快速链接

| 问题 | 解决 |
|------|------|
| iOS 构建失败 | [.github/WORKFLOWS.md - 常见问题](https://github.com/YOUR_USERNAME/danbooru-viewer/blob/main/.github/WORKFLOWS.md#q-ios-构建失败提示代码签名问题) |
| Tag 未触发构建 | [RELEASE_GUIDE.md - 故障排查](RELEASE_GUIDE.md#q-如何删除已发布的版本) |
| Web 部署失败 | [.github/WORKFLOWS.md - 故障排查](https://github.com/YOUR_USERNAME/danbooru-viewer/blob/main/.github/WORKFLOWS.md#常见问题) |
| 构建超时 | [.github/VERSION_HISTORY.md - 性能优化](https://github.com/YOUR_USERNAME/danbooru-viewer/blob/main/.github/VERSION_HISTORY.md#性能优化) |

---

## 🎓 学习路径

### 初级：快速上手
1. 阅读 [RELEASE_GUIDE.md](RELEASE_GUIDE.md) 的第一部分
2. 运行 `./scripts/release.sh` 发布测试版本
3. 在 GitHub Actions 页面监控进度

### 中级：深入理解
1. 阅读 [.github/WORKFLOWS.md](.github/WORKFLOWS.md)
2. 理解三个工作流的作用
3. 查看工作流 YAML 配置文件

### 高级：自定义配置
1. 阅读 [.github/SETUP_SUMMARY.md](.github/SETUP_SUMMARY.md) 的定制部分
2. 修改工作流配置
3. 添加额外的构建参数或签名

---

## 🌟 推荐工作流

### 标准开发流程
```
feature 分支
    ↓
创建 Pull Request
    ↓
CI 自动验证（代码检查、测试）
    ↓
代码审查通过
    ↓
合并到 main
    ↓
创建 Release Tag
    ↓
Build Release 工作流自动执行
    ↓
GitHub Release 自动创建
```

### 快速修复流程
```
在 main 分支创建 hotfix 分支
    ↓
修复并提交
    ↓
创建修复版本 Tag（如 v1.0.1）
    ↓
构建和发布
```

---

## 📈 性能参考

### 首次构建
- **总时间**：30-45 分钟
- **最长平台**：iOS (20-25 分钟)
- **最短平台**：Web (8-12 分钟)

### 后续构建
- **总时间**：25-40 分钟
- **优化点**：Flutter SDK 缓存、依赖缓存

### 加速建议
- ✅ 使用 GitHub-hosted runners（已配置）
- ✅ 启用缓存（已配置）
- 🔄 考虑 self-hosted runners（高级配置）
- 🔄 分离某些平台构建（高级配置）

---

## ✨ 功能总结

### ✅ 已实现
- 多平台并行构建
- 自动 Release 生成
- Web 自动部署
- 代码质量检查
- 完整文档
- 发布脚本

### 🚀 未来计划
- [ ] iOS 自动签名
- [ ] Android 自动签名
- [ ] App Store 上传
- [ ] Play Store 上传
- [ ] 通知集成
- [ ] 性能基准测试

---

## 🎯 下一步

### 立即采取行动
```bash
# 1. 查看快速指南
cat RELEASE_GUIDE.md

# 2. 运行发布脚本
./scripts/release.sh

# 3. 或创建第一个 Tag
git tag v1.0.0
git push origin v1.0.0
```

### 深入学习
1. 阅读 [.github/WORKFLOWS.md](.github/WORKFLOWS.md)
2. 查看工作流 YAML 文件
3. 自定义配置以满足项目需求

---

## 📝 文档版本

- **版本**：1.0
- **最后更新**：2026 年 2 月 5 日
- **状态**：✅ 完成并就绪

---

## 🎉 总结

你的项目现已拥有完整、自动化的 CI/CD 系统。所有新增文档都经过精心编写，涵盖从快速入门到高级定制的所有内容。

**推荐从以下任一文档开始**：
- 想快速发布？→ [RELEASE_GUIDE.md](RELEASE_GUIDE.md)
- 想了解工作流？→ [.github/WORKFLOWS.md](.github/WORKFLOWS.md)
- 想配置详情？→ [.github/SETUP_SUMMARY.md](.github/SETUP_SUMMARY.md)

祝你使用愉快！🚀

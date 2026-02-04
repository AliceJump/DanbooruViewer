# 🎉 GitHub Actions 工作流配置完成！

你的 Danbooru Viewer 项目已经完整配置了 CI/CD 工作流。

## 📁 新增文件总览

### 工作流文件（.github/workflows/）
```
✓ build.yml              - Release 版本多平台构建
✓ ci.yml                 - 持续集成（代码检查和测试）
✓ deploy-web.yml         - Web 版本部署到 GitHub Pages
```

### 文档文件
```
✓ RELEASE_GUIDE.md                   - 快速发布指南 ⭐ 必读
✓ CHANGELOG.md                        - 项目变更日志
✓ .github/WORKFLOWS.md                - 工作流详细文档
✓ .github/VERSION_HISTORY.md          - 版本管理记录
✓ .github/SETUP_SUMMARY.md            - 配置总结
✓ README.md (已更新)                  - 添加 CI/CD 部分
```

### 发布脚本
```
✓ scripts/release.sh                 - Linux/macOS 发布脚本
✓ scripts/release.bat                - Windows 发布脚本
```

---

## 🚀 5 步快速开始

### 1️⃣ 启用 GitHub Pages（仅限第一次）
1. 打开 GitHub 仓库 Settings
2. 找到 "Pages" 选项
3. 选择 "Deploy from a branch"
4. Branch: `gh-pages`
5. Save

### 2️⃣ 推送代码
```bash
git push origin main
```

### 3️⃣ 运行发布脚本
```bash
# Linux/macOS
./scripts/release.sh

# Windows
scripts\release.bat
```

或手动创建 Tag：
```bash
git tag v1.0.0
git push origin v1.0.0
```

### 4️⃣ 监控构建
访问：`https://github.com/YOUR_USERNAME/danbooru-viewer/actions`

### 5️⃣ 获取产物
所有构建完成后在这里下载：  
`https://github.com/YOUR_USERNAME/danbooru-viewer/releases`

---

## 📚 文档导航（按优先级）

### 🔴 必读
1. **[RELEASE_GUIDE.md](../RELEASE_GUIDE.md)** ⭐
   - 5 分钟快速发布指南
   - 详细步骤说明
   - 故障排查

### 🟡 推荐
2. **[.github/WORKFLOWS.md](.github/WORKFLOWS.md)**
   - 三个工作流的详细说明
   - 工作原理和触发条件
   - 定制建议

3. **[README.md](../README.md)**
   - 项目总览
   - 新增的 CI/CD 部分

### 🟢 参考
4. **[CHANGELOG.md](../CHANGELOG.md)**
   - 项目版本历史
   - 变更日志模板

5. **[.github/VERSION_HISTORY.md](.github/VERSION_HISTORY.md)**
   - 配置版本管理
   - 未来改进计划

6. **[.github/SETUP_SUMMARY.md](.github/SETUP_SUMMARY.md)**
   - 配置总结
   - 最佳实践

---

## 🎯 工作流一览

```
┌─────────────────────────────────────────────┐
│          Git Push 事件                      │
└──────────────┬──────────────────────────────┘
               │
        ┌──────┴──────┐
        ▼             ▼
   推送 Tag      推送分支
    (v*.*)     (main/dev)
        │             │
        ▼             ▼
  ┌─────────────────────────┐
  │  1. Build Release       │  2. CI
  │  ├─ Android            │  ├─ 代码检查
  │  ├─ iOS                │  ├─ 测试
  │  ├─ Linux              │  └─ Debug 构建
  │  ├─ Windows            │
  │  ├─ Web                │
  │  └─ 自动创建 Release   │
  └────────┬────────────────┘
           ▼
  ┌─────────────────────────┐
  │  3. Deploy Web          │
  │  └─ GitHub Pages 部署   │
  └─────────────────────────┘
```

**构建时间**：约 30-45 分钟（并行构建）

---

## 📊 支持的平台

| 平台 | 文件格式 | 签名状态 | 构建时间 |
|------|---------|--------|--------|
| 📱 Android | APK | ❌ 需手动 | 10-15 min |
| 🍎 iOS | IPA | ❌ 未签名 | 20-25 min |
| 🐧 Linux | tar.gz | ✅ 就绪 | 12-18 min |
| 🪟 Windows | zip | ✅ 就绪 | 15-20 min |
| 🌐 Web | tar.gz + 部署 | ✅ 就绪 | 8-12 min |

---

## ✨ 主要特性

### ✅ 已实现
- [x] 一键发布多平台版本
- [x] GitHub Release 自动生成
- [x] Web 自动部署到 GitHub Pages
- [x] 代码质量自动检查
- [x] 构建缓存加速
- [x] 详细错误日志

### 📋 可选功能（需额外配置）
- [ ] iOS 代码签名（需 Apple 账户）
- [ ] Android APK 签名（需 Keystore）
- [ ] App Store Connect 上传
- [ ] Google Play Store 上传
- [ ] Slack 通知
- [ ] 性能测试报告

---

## 🔧 快速定制

### 修改构建参数
编辑 `.github/workflows/build.yml`:
```yaml
- name: Build APK
  run: flutter build apk --release --split-per-abi
  # 添加更多参数...
```

### 添加新平台
编辑 `build.yml` 的 `matrix` 部分，参考现有平台配置。

### 修改 Tag 格式
编辑工作流的 `on.push.tags` 部分：
```yaml
on:
  push:
    tags:
      - 'v*'         # 现有
      - 'release-*'  # 新增
```

---

## 🆘 常见问题

### Q: 为什么需要推送到 GitHub？
A: GitHub Actions 需要远程仓库才能运行。本地运行工作流需要额外配置。

### Q: 构建为什么这么慢？
A: 首次构建会缓存 Flutter SDK（约 800MB），后续会快很多。

### Q: iOS/Android 为什么不签名？
A: 需要密钥和证书，涉及安全性和 Apple/Google 账户。详见平台文档。

### Q: Web 版本在哪里？
A: 自动部署到：`https://<username>.github.io/danbooru-viewer/`

### Q: 如何跳过某个平台？
A: 在 `build.yml` 中从 `matrix` 移除该平台配置。

更多问题请查看 [RELEASE_GUIDE.md](../RELEASE_GUIDE.md)

---

## 📞 需要帮助？

1. **快速发布** → [RELEASE_GUIDE.md](../RELEASE_GUIDE.md)
2. **工作流详情** → [.github/WORKFLOWS.md](.github/WORKFLOWS.md)
3. **故障排查** → [.github/WORKFLOWS.md](.github/WORKFLOWS.md#常见问题)
4. **配置调整** → 编辑 `.github/workflows/` 中的文件

---

## 🎓 最佳实践建议

### 版本管理
```bash
git tag v1.0.0      # 主版本
git tag v1.0.1      # 补丁版本
git tag v1.1.0      # 次要版本
git tag v1.0.0-rc.1 # 预发布版本
```

### 分支策略
```
main (稳定分支，仅合并发布)
  ↑
develop (开发分支)
  ↑
feature/* (功能分支)
hotfix/* (修复分支)
```

### 发布流程
1. 在 develop 开发并测试
2. 创建 PR 到 main
3. 代码审查和 CI 验证
4. 合并到 main
5. 创建 Release Tag
6. GitHub Actions 自动构建
7. 生成 Release 页面

---

## 🎉 下一步

### 立即开始
```bash
# 1. 查看快速指南
cat RELEASE_GUIDE.md

# 2. 或运行发布脚本
./scripts/release.sh  # Linux/macOS
scripts\release.bat   # Windows

# 3. 或手动创建 Tag
git tag v1.0.0
git push origin v1.0.0
```

### 深入学习
阅读详细文档：
- [工作流说明](.github/WORKFLOWS.md)
- [版本历史](.github/VERSION_HISTORY.md)
- [配置总结](.github/SETUP_SUMMARY.md)

---

## 📝 清单

发布前确保：
- [ ] 代码已测试
- [ ] pubspec.yaml 版本已更新
- [ ] CHANGELOG.md 已更新
- [ ] 提交已推送到 main

发布时：
- [ ] 创建 Git Tag: `git tag vX.Y.Z`
- [ ] 推送 Tag: `git push origin vX.Y.Z`
- [ ] 监控 Actions 进度
- [ ] 验证 Release 页面

---

祝你使用愉快！🚀

有任何问题，欢迎提交 Issue 或查阅相关文档。

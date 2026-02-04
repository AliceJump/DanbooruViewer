# GitHub Actions 工作流版本历史

本文件记录了 GitHub Actions 工作流的版本历史和变更。

## 最新版本 (v1.0)

### 工作流文件
- `.github/workflows/build.yml` - Release 版本多平台构建
- `.github/workflows/ci.yml` - 持续集成（代码检查和 Debug 构建）
- `.github/workflows/deploy-web.yml` - Web 版本部署到 GitHub Pages

### 支持的平台
- ✅ Android (APK, 多架构)
- ✅ iOS (IPA, 未签名)
- ✅ Linux (可执行程序)
- ✅ Windows (可执行程序)
- ✅ Web (静态网站)

### 特性
- 并行多平台构建
- 自动生成 GitHub Release
- Web 自动部署到 GitHub Pages
- 缓存 Flutter 依赖加速构建
- 完整的日志和错误报告

## 使用记录

### 首次配置日期
2026 年 2 月

### Tag 命名规范
使用 Semantic Versioning：
- `v1.0.0` - 主版本发布
- `v1.1.0` - 次要版本（新功能）
- `v1.0.1` - 补丁版本（Bug 修复）
- `v1.0.0-beta.1` - 测试版本

### 建议的版本流程

#### 开发阶段
1. 在 `develop` 分支开发
2. 创建 Pull Request 到 `main` 分支
3. CI 工作流验证代码质量

#### 发布阶段
1. 更新 `pubspec.yaml` 中的版本号
2. 更新 CHANGELOG
3. 将 `develop` 分支合并到 `main`
4. 创建 Release Tag：`git tag vX.Y.Z && git push origin vX.Y.Z`
5. Build Release 工作流自动触发
6. GitHub Release 自动创建

---

## 故障排查

### 常见问题解决

#### iOS 构建失败
- 原因：缺少开发者签名
- 解决：工作流使用 `--no-codesign` 生成未签名 IPA，仅用于测试

#### Linux 依赖缺失
- 原因：首次构建需要安装系统依赖
- 解决：工作流已包含 `apt-get install` 步骤

#### 网络超时
- 原因：GitHub servers 连接不稳定或 pub.dev 访问缓慢
- 解决：重试或手动触发工作流

#### Artifact 下载失败
- 原因：Artifact 保留期已过期
- 解决：从 GitHub Releases 下载，或重新创建 Tag 触发构建

---

## 性能指标

### 典型构建时间
- Android APK: ~10-15 分钟
- iOS IPA: ~20-25 分钟
- Linux: ~12-18 分钟
- Windows: ~15-20 分钟
- Web: ~8-12 分钟

### 总计时间
- 所有平台并行构建：~25-30 分钟
- + GitHub Release 创建：~2-3 分钟
- **总计：约 30-45 分钟**

---

## 安全性检查清单

- ✅ 使用 `GITHUB_TOKEN` 管理权限（GitHub 自动提供）
- ✅ 构建在隔离的 GitHub-hosted runners 上执行
- ✅ 无硬编码凭证（敏感信息使用 Secrets）
- ✅ APK 和 IPA 未签名（生产环境需手动配置签名）

---

## 部署清单

### 生产环境部署前
- [ ] 更新版本号 in pubspec.yaml
- [ ] 更新 CHANGELOG.md
- [ ] 本地测试构建成功
- [ ] 代码审查通过
- [ ] 所有 CI 检查通过
- [ ] 创建 Release Note

### 发布流程
- [ ] 合并 PR 到 main 分支
- [ ] 创建 Git Tag: `git tag vX.Y.Z && git push origin vX.Y.Z`
- [ ] 等待 GitHub Actions 完成
- [ ] 验证 GitHub Releases 页面
- [ ] 下载并测试各平台产物
- [ ] 如需，在应用商店发布 APK/IPA

---

## 未来改进计划

### 计划的新增功能
- [ ] App Store Connect 自动上传 (iOS)
- [ ] Google Play Store 自动上传 (Android)
- [ ] 自动生成 Changelog
- [ ] Slack/Email 通知
- [ ] 性能基准测试
- [ ] 代码覆盖率报告

### 优化计划
- [ ] 使用 self-hosted runners 加速构建
- [ ] 增量构建支持
- [ ] 构建产物自动标签和版本管理
- [ ] 条件性跳过某些平台构建

---

## 参考资源

- Flutter 官方 CI/CD 指南: https://docs.flutter.dev/deployment/cd
- GitHub Actions 市场: https://github.com/marketplace?type=actions
- Flutter Action: https://github.com/subosito/flutter-action
- Upload Artifact: https://github.com/actions/upload-artifact
- GitHub Release: https://github.com/softprops/action-gh-release
- GitHub Pages 部署: https://github.com/peaceiris/actions-gh-pages

---

## 许可和支持

本工作流配置遵循 MIT 许可证。

如有问题，请在 GitHub Issues 中报告。

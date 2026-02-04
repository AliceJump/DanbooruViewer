# Changelog

所有重要的项目变更都记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)，
项目遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)。

## [Unreleased]

### Added
- 添加新的视频播放支持
- 下拉刷新功能

### Changed
- 优化图片加载性能

### Fixed
- 修复多选模式返回按钮问题

---

## [1.0.0] - 2026-02-05

### Added
- 初始版本发布
- Danbooru API 集成
- 图片网格浏览
- 高分辨率图片查看
- 视频播放支持
- 图片/视频下载功能
- 批量多选操作
- 内容等级筛选
- 标签分类系统
- 下拉刷新
- GitHub Actions 工作流配置
  - 自动多平台构建 (Android, iOS, Linux, Windows, Web)
  - GitHub Releases 自动发布
  - GitHub Pages 自动部署 (Web)

### Features by Platform
#### 🤖 Android
- APK 构建（多架构支持）
- 直接安装和运行

#### 🍎 iOS
- IPA 构建（未签名）
- 可用于测试和签名

#### 🐧 Linux
- 完整的桌面应用
- 单一可执行文件

#### 🪟 Windows
- 原生 Windows 应用
- 完整的图形界面

#### 🌐 Web
- 响应式 Web 应用
- 自动部署到 GitHub Pages
- 无需安装即可使用

---

## 版本发布历史

### 发布计划

#### 近期 (v1.1.0)
- [ ] 搜索历史记录
- [ ] 收藏夹功能
- [ ] 本地缓存支持

#### 中期 (v1.2.0)
- [ ] 高级搜索界面
- [ ] 暗色主题完整支持
- [ ] 离线模式

#### 远期 (v2.0.0)
- [ ] 用户账户系统
- [ ] 同步云端收藏
- [ ] 智能推荐系统

---

## 贡献指南

欢迎提交 Issue 和 Pull Request！

### 提交变更前
1. 确保代码通过 `flutter analyze`
2. 运行 `flutter format` 格式化代码
3. 通过所有单元测试

### 版本号规则

遵循 Semantic Versioning：
- **MAJOR** (X.0.0): 重大功能或不兼容变更
- **MINOR** (1.X.0): 新功能（向下兼容）
- **PATCH** (1.0.X): Bug 修复和小改进

---

## 已知问题

### v1.0.0
- iOS IPA 未签名（生产环境需手动配置）
- 无本地缓存机制
- 内存中 URL 缓存可能导致大量浏览时占用增加

---

## 鸣谢

感谢所有贡献者和使用者的支持！

- Flutter 团队
- Danbooru 社区
- GitHub Actions 文档

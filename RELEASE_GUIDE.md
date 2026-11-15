# 发布指南

本仓库从已审查、已合并且 CI 成功的 `master` 提交发布稳定版本。
发布版本使用 `vX.Y.Z`，并与 `pubspec.yaml` 中的 `X.Y.Z+正整数构建号` 对应。

## 1. 准备版本并合并 PR

在工作分支更新 `pubspec.yaml` 和 `CHANGELOG.md`。应用版本与构建号都应高于
已发布版本；例如本次为 `1.0.67+67`。执行相关回归测试，并提交 PR。
全新检出需先生成补全资源：

```bash
python scripts/build_completion_index.py
flutter pub get
flutter analyze --no-fatal-infos
flutter test
python -m unittest discover -s tests
```

完成审查和 PR 的 CI 后，使用 **squash** 合并到 `master`。随后等待合并产生的
**完整提交 SHA** 的 `CI` push 运行成功；PR 分支的成功记录不能代替这次检查。
合并后的 master CI 运行 Flutter/Python/JavaScript 回归与 Web release 构建。
由仓库所有者发起的同仓库 PR 阶段另构建并校验签名 Android APK。

## 2. 从已验证的 SHA 触发发布

以下两种入口选择一种。示例中的 SHA 必须替换为上一步已通过 CI 的完整提交值。

### 方式 A：发布分支

```bash
release_tag="v1.0.67"
release_sha="<已通过 CI 的 master 完整提交 SHA>"
git fetch origin master
git branch "release/$release_tag" "$release_sha"
git push origin "refs/heads/release/$release_tag"
```

在 GitHub 网页或通过 Git refs API 从该 SHA 创建 `release/v1.0.67` 也会触发
`Build Release`。分支创建使用 `create` 事件；后续分支更新使用 `push` 事件。

### 方式 B：直接创建版本 tag

```bash
release_tag="v1.0.67"
release_sha="<已通过 CI 的 master 完整提交 SHA>"
git fetch origin master
git tag "$release_tag" "$release_sha"
git push origin "refs/tags/$release_tag"
```

这里只推送新 tag。代码变更通过 PR 合入 `master`，不在发布步骤直接推送主分支。
已有 tag 必须指向同一提交；工作流不会移动或覆盖它。

手动运行 `Build Release` 时，也应选择相应的 `vX.Y.Z` tag 或
`release/vX.Y.Z` 分支。选择普通分支（包括 `master`）会被发布校验拒绝。
当前入口只支持稳定版本；`-alpha`、`-beta` 和 `-rc` 不在支持范围内。

## 3. 工作流校验与构建

`prepare` 会检查版本与正整数构建号、固定 checkout SHA、提交已进入 `master`、
该 SHA 最新的 `CI` push 运行成功，以及已有 tag 指向同一提交。随后 Android、
Linux、Web、iOS 和 Windows 并行构建。

五个平台全部成功且七个发布文件均非空后，发布作业才创建缺失的 tag，再次检查
CI、tag 和已有 Release，然后发布。每个构建和发布步骤都使用同一完整 SHA。

已有 Release 的检查分页读取 `/releases` 列表，并按 `tag_name` 精确匹配。
GitHub 只向有 push 权限的调用方显示草稿；准备作业保留 `contents: read`，
发布作业使用其原有的 `contents: write` 令牌在发布前检查包括草稿在内的列表。
任何同 tag 的可见 Release 都会阻止发布；列表异常或超过分页上限也会停止。
工作流没有更新、替换或自动删除已有 Release 的路径。

在 [GitHub Actions](https://github.com/AliceJump/DanbooruViewer/actions) 查看
`Build Release` 的各平台任务及最终发布任务。构建时长取决于平台和依赖缓存。

## 4. 下载文件与发布验收

在 [Releases](https://github.com/AliceJump/DanbooruViewer/releases) 确认新版本已公开，
tag 解析到上述发布 SHA，且以下七个文件均已上传且大小非零。

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android ARM64 | `danbooru-viewer-android-arm64-v8a.apk` | 大多数现代 Android 手机和平板 |
| Android ARMv7 | `danbooru-viewer-android-armeabi-v7a.apk` | 较旧的 32 位设备 |
| Android x86_64 | `danbooru-viewer-android-x86_64.apk` | 模拟器或 x86_64 设备 |
| Windows | `danbooru-viewer-windows-release.zip` | 解压后运行 `danbooru_viewer.exe` |
| Linux | `danbooru-viewer-linux-release.tar.gz` | 解压后运行应用程序 |
| iOS | `app.ipa` | 未签名，需要自行签名或侧载 |
| Web | `danbooru-viewer-web-release.tar.gz` | 静态网页构建产物 |

Android CI 会核对签名证书与已发布 APK 的一致性，并检查内部 `versionCode`
递增。Web 压缩包上传不等于 GitHub Pages 部署；Pages 应另行查看对应部署工作流。

## 5. 失败后恢复

### 构建失败，或发布尚未创建 Release

先查看失败任务的日志。若只是临时网络或构建环境故障，排除原因后在 Actions
选择 **Re-run failed jobs**，保留原发布 SHA 和 tag。需要修改代码或配置时，
先通过新的 PR 和 CI；如果原版本 tag 已创建，使用新的版本号，保持旧 tag 不动。

### 上传失败，留下未发布草稿

带附件的 `gh release create` 会分步创建草稿、上传文件、再发布；上传中断可能
留下草稿。草稿会阻止后续发布校验，不能只反复重跑。

1. 以有仓库写权限的账户打开 Releases，找到这次失败留下的草稿。核对 tag、
   创建时间、发布说明里的 SHA、失败运行的 SHA，以及实际 tag 指向。若归属或
   SHA 不一致，先查清原因，保留现状。
2. 核对草稿中的文件名、大小和已上传内容，与该次运行的 Actions 制品对应；
   保存仍需保留的说明或文件。确认这是本次失败留下的未发布草稿后，删除
   **该草稿 Release**，保留已有 tag、发布分支和对应 SHA，不删除 tag。
3. 在原失败运行选择 **Re-run failed jobs**。发布作业会重新下载同次运行的
   构建制品、验证七个文件及原 tag/SHA，再重新创建 Release。

以上恢复只处理确认归属的未发布草稿。若 Release 已公开，先按上一节核对
七个文件和 tag；已完成的发布不需要重新创建。已公开版本有问题时，通过新的
PR、版本号和构建发布修正版，保留原版本与制品记录。

### 忘记更新版本或选错提交

准备阶段会因版本、SHA 或 CI 不匹配而失败。通过 PR 修正版本和变更日志，
等待新的 master 提交 CI 成功，再以正确的新版本和 SHA 发布。不要强推主分支
或通过删除、重建旧 tag 改写已记录的版本。

## 相关资料

- [发布工作流](.github/workflows/build.yml)
- [发布校验脚本](scripts/prepare_release.py)
- [版本变更记录](CHANGELOG.md)
- [GitHub Release 列表及草稿可见性](https://docs.github.com/en/rest/releases/releases#list-releases)
- [GitHub CLI 创建 Release 与附件上传](https://cli.github.com/manual/gh_release_create)

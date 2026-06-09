# 启动时自动增量同步流程

## 功能说明

当 app 启动时，需要**自动检查并增量同步**补全数据，确保：
- ✅ 本地缓存的标签数据是最新的
- ✅ 不需要每次手动运行批量脚本
- ✅ 后台静默更新，不影响用户体验

## 整体架构

```
App 启动
  ↓
检查本地补全资源
  ├─ 资源不存在？ → 触发增量同步
  ├─ 资源过期（>24h）？ → 触发增量同步
  └─ 资源新鲜 → 直接加载
     ↓
启动增量同步（后台）
  ├─ 检查每个标签的同步时间戳
  ├─ 只同步需要更新的标签
  └─ 更新本地缓存 + 资源
     ↓
App 完全初始化
```

## 实现方式

### 1️⃣ Python 后端支持

已添加到 `view.py`：

```python
# 检查标签是否需要同步（基于时间戳 + 文件存在性）
check_needs_sync(tag, max_age_hours=24)

# 增量同步一批标签
incremental_sync(tags, max_age_hours=24)
  ↓ 返回 (synced_count, total_count, errors)

# 同步元数据记录
load_sync_metadata()  # 读取 .danbooru_cache/sync_metadata.json
save_sync_metadata()  # 保存同步时间戳
```

### 2️⃣ 启动同步脚本

新增 `scripts/startup_auto_sync.py`，在以下场景调用：

**方式 A: 手动运行（开发/测试）**
```powershell
# 检查预设的 10 个标签，只同步需要更新的
cd D:\items\project\android_project\DanbooruViewer
python scripts/startup_auto_sync.py --default

# 查看什么需要更新
python scripts/startup_auto_sync.py --default --quiet  # 仅显示错误
```

**方式 B: 定时任务调用（生产环境）**
```powershell
# Windows 任务计划（每天凌晨 3 点运行）
# PowerShell:
$action = New-ScheduledTaskAction -Execute 'python' `
  -Argument 'D:\items\project\android_project\DanbooruViewer\scripts\startup_auto_sync.py --default --quiet'
$trigger = New-ScheduledTaskTrigger -Daily -At 3am
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "DanbooruAutoSync"
```

**方式 C: CI/CD 流程调用**
```yaml
# GitHub Actions / CI
- name: Auto sync tags
  run: |
    python scripts/startup_auto_sync.py --default --quiet
```

**方式 D: development build 启动前自动运行**
```powershell
# 在 Flutter build 前
python scripts/startup_auto_sync.py --default
flutter build apk  # 或 flutter run
```

### 3️⃣ Flutter 检测与反馈

修改 `lib/main.dart` 中 `_loadCompletionSuggestions()` 来检查补全数据的新鲜度：

```dart
Future<void> _checkCompletionFreshness() async {
  // 检查 assets/danbooru_completion/ 中的文件
  // 如果没有或太旧，建议用户更新
  // （移动应用无法直接调用 Python，需通知用户）
}
```

当检测到过期时的可选操作：
- 🔔 显示通知："补全数据已过期，请运行：`python startup_auto_sync.py --default`"
- 📝 记录日志："Last sync: 2 days ago"
- ⚙️ 在调试控制台打印提示

## 使用流程总结

### 【开发阶段】

1. **初次设置**：批量生成所有标签
   ```powershell
   python scripts/batch_sync_tags.py --default
   flutter pub get
   flutter run
   ```

2. **每次启动前**（可选自动化）：增量同步最新数据
   ```powershell
   python scripts/startup_auto_sync.py --default
   flutter run
   ```

3. **添加新标签**：编辑 `scripts/tags.txt`，然后新增
   ```powershell
   python scripts/startup_auto_sync.py --tags "new_tag_1" "new_tag_2"
   ```

### 【生产环境】

1. **首次部署**：构建时预生成所有资源
   ```powershell
   python scripts/batch_sync_tags.py --default
   flutter pub get
   flutter build apk --release
   ```

2. **定期更新**：设置定时任务（每天/每周）
   ```powershell
   # Windows 任务计划或 Linux cron
   python scripts/startup_auto_sync.py --default --quiet
   ```

3. **上线新版本**：重新同步后再发布
   ```powershell
   python scripts/startup_auto_sync.py --default
   flutter build apk --release
   ```

## 核心文件说明

| 文件 | 作用 |
|------|------|
| `view.py` | 核心同步逻辑 + 元数据追踪 |
| `scripts/startup_auto_sync.py` | **启动时增量同步入口** |
| `scripts/batch_sync_tags.py` | 批量初始化脚本 |
| `.danbooru_cache/sync_metadata.json` | 同步元数据（时间戳、版本） |
| `assets/danbooru_completion/` | 打包的 Flutter 资源 |

## API 参考

### Python: `view.incremental_sync()`

```python
synced_count, total_count, errors = view.incremental_sync(
    tags=["tag1", "tag2"],        # 要检查的标签列表
    max_age_hours=24               # 超过这个小时数就重新同步
)

# 返回值：
# - synced_count: 实际同步了多少个
# - total_count: 检查了多少个
# - errors: 失败的列表 [(tag, error_msg), ...]
```

### Python: `view.check_needs_sync()`

```python
needs_sync = view.check_needs_sync(
    tag="oguri_cap_(umamusume)",
    max_age_hours=24
)
# 返回 True = 需要重新同步
# 返回 False = 本地资源新鲜，无需同步
```

## 配置调优

### 调整同步间隔

**更激进（每 6 小时检查一次）：**
```powershell
python scripts/startup_auto_sync.py --default --max-age 6
```

**更保守（每 7 天检查一次）：**
```powershell
python scripts/startup_auto_sync.py --default --max-age 168  # 7 * 24
```

### 仅检查所有本地缓存的标签

```powershell
# 检查所有本地已缓存的标签是否需要更新
python scripts/startup_auto_sync.py --all --max-age 24
```

### 静默模式（只显示错误）

```powershell
# 定时任务或后台执行时使用
python scripts/startup_auto_sync.py --default --quiet
```

## 故障排除

**问题：同步元数据文件不存在**
```
解决方案：首次运行时会自动创建 .danbooru_cache/sync_metadata.json
```

**问题：某个标签同步失败**
```
查看输出日志，运行 with --quiet 去掉 quiet 重新看详细错误信息
python scripts/startup_auto_sync.py --tags "problem_tag" --max-age 0 --retry
```

**问题：想强制重新同步所有标签**
```
删除元数据文件：
rm .danbooru_cache/sync_metadata.json

然后运行：
python scripts/startup_auto_sync.py --all --max-age 0
```

## 建议

- 🎯 **开发期间**：每次 `flutter run` 前自动运行一遍
- 📦 **发版前**：集成到 CI/CD，确保资源最新
- ⏰ **生产环境**：每晚定时运行，保持数据新鲜
- 💾 **版本控制**：`.danbooru_cache/` 纳入 .gitignore，不提交本地缓存

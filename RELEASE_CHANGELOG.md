## 变更日志 (v1.0.60)

- 去数据库化：App 端恢复 zip 补全资源（条目带分类字段），移除 sqflite 依赖
- 抓取端保留 SQLite（cache/danbooru_tags.db），build_completion_zip.py 只输出 zip
- 保留功能：补全/收藏按分类分组、旧收藏分类一次性迁移、后台 isolate 补全加载优化
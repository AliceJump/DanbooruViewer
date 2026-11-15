# 看图、代理与标签数据完整审阅

审阅日期：2026-11-16（Asia/Shanghai）。初始代码：
[`30508ea25877a5a40a646782b30613e4a49dbbbe`](https://github.com/AliceJump/DanbooruViewer/tree/30508ea25877a5a40a646782b30613e4a49dbbbe)，即 v1.0.67。
本文记录修改前的问题与实施范围；验证结果以各 PR 的最终 HEAD 为准。

## 覆盖范围与基线

- 阅读全部应用 Dart 业务代码、现有 Flutter 测试、Android 自定义拖拽桥接，以及各平台权限与插件配置。
- 阅读全部 16 个 `scripts/*.py`、根目录 `view.py`、发布脚本、维护批处理和相关 Actions。
- 检查根 `AGENTS.md`、前端设计约束；没有 `.agents/skills` 或 `.coderabbit.yaml`。
- 使用仓库指定的 UI/UX Pro Max v2.15.0，保留 Flutter 3.38.9、现有 Material 3 主题、补全索引和请求代次保护。
- 修改前 Flutter 测试 76 项通过；分析没有 error/warning，存在 4 条信息提示。安装 `requirements.txt` 后 Python 测试 49 项通过。
- 未运行真实标签爬虫、未修改真实 SQLite/JSON/ZIP 输入。数据丢失、重同步、旧别名、分类签名、compact 恢复问题均使用临时 fixture 复现。

这不是所有依赖与生成式平台脚手架的逐行安全审计，也不代表 Android/iOS/macOS 真机、真实代理或相册权限已经验证。缺陷成立和平台运行验证分开记录。

## 已有实现值得保留的部分

1. 标签补全已使用索引与有界元数据缓存；索引格式、源身份和残缺产物重建有测试覆盖。
2. 首页已有查询代次隔离、已提交查询快照、刷新失败保留原结果、分页失败重试同一页。
3. 收藏写入使用串行队列，旧标签分类迁移会保留并发更新。
4. 现有 `prepare_release.py` 已校验稳定版本、精确 SHA、master 合并状态、CI、已有标签及包括 draft 的 Release。
5. 图片网格、搜索面板和错误控件已共用；键盘、小窗口及大字号已有回归基础。

## 应用问题

优先级含义：P1 是可能丢失数据、破坏核心路径或使安全设置失效的问题；P2 是可靠性与基础交互问题。缺失功能另列，不把所有需求都称为 bug。

| 编号 | 优先级 | 修改前行为及后果 | 代码入口 | 实施范围 |
| --- | --- | --- | --- | --- |
| N1 | 核心能力缺口 | API、缓存、原图、视频和下载分用 http、HttpClient、Dio、NetworkImage、原生播放器；没有应用代理配置 | `main.dart`、`media_utils.dart`、`post_detail_page.dart`、全屏与保存路径 | 单一网络策略、缓存入口；HTTP/SOCKS5/直连/进程环境；Web 说明浏览器限制 |
| N2 | P2 | 收藏标签预览无超时且串行；分享等待可选简介 | `favorites_page.dart`、`post_detail_page.dart` | 有限截止时间、取消、预览有界并发、简介失败退回帖子链接 |
| N3 | P2 | 图片预热 Future 失败无人处理；同一原图磁盘缓存与 NetworkImage 重复请求 | `media_utils.dart`、详情预加载 | 接住预热错误，显示复用缓存，设置变化后重新请求 |
| N4 | P2 | Future.timeout 和代次判断无法取消底层旧请求 | `main.dart` | 真正中止旧请求，保留代次保护；有限重试与错误分类 |
| N5 | P2 | 来源链接只检查 hasScheme，可把任意 scheme 交给外部应用 | `post_detail_page.dart` | 远程来源仅打开有效 HTTP/HTTPS；其他文本仍可复制 |
| M1 | P1 | 离开页面未暂停旧视频，进入全屏创建第二播放器，控制器长期累积 | 详情与全屏播放器 | 翻页、路由、后台暂停；限制持有控制器；防止迟到初始化重新播放 |
| M2 | P1 | 缺少 preview 时提前返回，挡住仍有效的 file/large URL | 详情媒体分支 | 缩略图/显示图/原图独立回退 |
| M3 | P1 | 批量将普通视频传给 putImage；单项用字符串末尾识别 MP4，误判带 query 的 URL 和其他容器 | `main.dart`、`media_utils.dart` | 统一类型识别、单项与批量保存服务，逐项失败、取消、重试 |
| M4 | P1 | Web 路径调用 Image.file/FileImage；Windows/Linux 没有内置 video_player 后端 | 图片与全屏、插件列表 | Web 使用可用图片提供器；桌面视频提供明确的本地文件外部播放路径 |
| M5 | P1/P2 | Apple 相册用途描述缺失、macOS release 缺 network.client、Android 旧版本相册权限不完整 | 平台配置 | 根据当前插件要求补配置，并标明尚需真机验证 |
| M6 | P2 | 全屏缺显式关闭/Escape；高清缓存小缩略图无解码尺寸约束 | 全屏、网格 | 可见关闭/键盘操作；按显示尺寸解码，减少不必要原图预热 |
| M7 | P2 | Android 忽略 startDragAndDrop 返回值；其他平台也展示不可用拖拽行为 | `DragHelper.dart`、Kotlin 桥接 | 传回实际结果，按平台提供保存/分享替代 |
| C1 | P2 | 从详情正常返回不刷新收藏，取消收藏后仍显示旧卡片 | `favorites_page.dart` | 返回刷新且保留过滤状态 |
| C2 | P2 | 收藏标签筛选使用 contains，cat 匹配 cat_ears | `favorites_page.dart` | 已提交标签精确匹配；未提交文本仍可搜索标签建议 |
| C3 | P2 | JSON 类型未校验，读取错误缺 finally，可能一直显示加载 | `favorites_manager.dart`、收藏页 | 校验、错误与重试、原始备份，失败不清空数据 |
| C4 | 维护问题 | `Post` 重复定义，字段序列化能力不同 | `main.dart`、`post.dart` | 单一领域模型，保留旧 import 的兼容 export |

`ReusableImageView` 当前没有活跃调用，因此它的独立网络路径不作为当前已发生故障计数。大图和 Ugoira 的内存风险来自资源路径分析，没有伪称已复现 OOM。

## 新增标签屏蔽的行为约定

- 保存原始 Danbooru 标签的规范形式，完整 token 精确匹配；任一标签命中即隐藏。中文补全显示名不作为规则。
- 第一版不解释 AND、负标签或通配符语法，避免把半套搜索语法做成隐性规则。
- 首页、搜索、收藏、历史、收藏标签预览、详情翻页、选择与批量保存都使用同一份规则。
- 屏蔽只影响显示与操作候选，不删除收藏和历史。解除屏蔽后恢复。
- 原始页和显示页分离。服务器返回非空而本地全被过滤时，不把它判定为最后一页；自动补页必须有上限，并保留继续加载入口。
- 提供管理、启停、命中计数、临时显示、详情标签菜单添加与撤销。临时显示不跨进程持久化。
- 当前页被屏蔽时，详情切换到剩余可见项或退回明确的空状态；不能继续播放已隐藏媒体。
- 本地配置或收藏损坏时保留原文，显式提示并允许备份，不能悄悄写回空列表。

## 数据管线与发布入口

| 编号 | 优先级 | 已复现或确认的问题 | 修复要求 |
| --- | --- | --- | --- |
| D1 | P1 | `migrate_json_to_db.py` 对解析失败/SQLite 写入失败仍返回全部源路径，默认清理删除源文件且 exit 0 | 只有已提交成功的来源可删除；失败回滚、保源、非零退出 |
| D2 | P1 | batch 同步与 wiki 别名脚本在网络校验失败后自动 verify=False；batch 可能携带 API 凭据 | 删除自动 TLS 降级，保留验证失败原因 |
| D3 | P2 | `--resync-months` 使用 INSERT OR IGNORE，已完成项不会再次 pending | 显式重入队，保留有效 claim；普通增量仍幂等 |
| D4 | P2 | 分类更新不改变 count/MAX(updated_at)，补全导出误判 unchanged | 签名覆盖实际导出输入或完整持久化修订，测试分类/删除/导入 |
| D5 | P2 | 当前 DB 与旧 seed/ZIP 无条件并集，删除/改向的别名重新出现 | 当前完整数据权威；占位或缺失数据才补旧来源 |
| D6 | P2 | compact 归档缺 tag_info，恢复清空现有 ID、category、post_count | 按字段是否存在更新，校验 manifest 与 payload 身份 |
| D7 | P2 | wiki 401/403/429/500 被当作没有 wiki，标签同步仍成功且覆盖旧别名 | 只把 404 当不存在；其他错误保留旧完整记录；quote 标签路径 |
| D8 | P2 | 消费者与分类同步失败仍 exit 0；429 耗尽返回空页 | 失败非零，保留可重试状态，不把请求失败伪装成同步完成 |
| R1 | P2 | 旧 release.bat 提前退出；PowerShell 丢 build；三入口仍有旧 bump/push/tag 流程 | 收敛到已存在的精确 SHA/CI 发布流程，修正文档路径 |
| R2 | P2 | Pages workflow 只监听 main，实际默认分支 master | 与实际分支及 Web 运行能力一致后修复 |

次级一致性修复：成功缓存不能绕过 max-age；维护入口使用统一代理配置；批处理从自身位置定位仓库并传播失败；下载统计图应写明按“发布月份”归集累计值，不能称下载发生月份。

## 同类仓库对照

只研究公开源码与说明，没有安装并抓包这些客户端。以下固定 commit 便于复核；采用行为原则并自行实现，不复制 GPL/AGPL 代码。

| 仓库与快照 | 可采用的设计 | 本项目选择 |
| --- | --- | --- |
| [Boorusama](https://github.com/khoadng/Boorusama/tree/bfc30e792952ec5fbdbe16e7bb76a09491bde938) | `core/posts/listing/.../post_grid_controller.dart` 同时保留原始/过滤列表，hasMore 来自原始结果；规则变化重新过滤 | 原始分页与本地屏蔽分离，规则变化即时作用于已加载作品 |
| [LoliSnatcher](https://github.com/NO-ob/LoliSnatcher_Droid/tree/58fe28a12bf19b9999673a07faa27e389a16315f) | BooruHandler 的 fetched/filteredFetched；下载失败/取消队列；完成前临时文件和完整性检查 | 明确前台保存状态，部分文件不伪装成成功；不声称具备重启恢复队列 |
| [Aves](https://github.com/deckerst/aves/tree/b6a817897dcca13baef2a44274737ee6105bf7d9) | 缩放与翻页边界协调，region image provider | 先修关闭/键盘/显示尺寸解码；超大图分块解码单列后续工程 |
| [Flexbooru](https://github.com/flexbooru/flexbooru/tree/2b6c47cd292d2d5e1a7128b3a6bf8d8fbdf0e11a) | 工作队列与缓存后保存，图片/视频网络栈分离的经验 | 参考结构，不将已归档 Android 项目当现成 Flutter 依赖 |

### 代理方案不能照搬的部分

- Boorusama 的一条代理路径使用 `badCertificateCallback => true`，且代理类型的字符串表示包含凭据；本项目不采用。
- LoliSnatcher 的一条代理字符串带 `; DIRECT`，失败可能直连；本项目手动代理失败必须显式失败。
- 原生 ExoPlayer/AVPlayer 不因 Dart HttpOverrides 自动遵守同一代理。应用应先经统一网络缓存视频再播放本地文件，或使用确实接入同一策略的后端。
- Dart 默认的进程代理环境变量不等同于系统 PAC、Android Wi-Fi 或 Windows 系统代理设置；界面必须写清模式含义。
- Web 受浏览器代理和 CORS 约束；不能展示看似能控制浏览器网络的无效应用代理选项。

平台保存配置以 [Gal 官方说明](https://github.com/natsuk4ze/gal/blob/main/README.md) 为依据；实际支持仍以本项目锁定依赖与构建平台为准。

## 交付拆分与验收

1. 网络与媒体：统一 transport/cache、配置 UI、取消/超时/有限重试、视频生命周期、可见全屏退出、保存与平台配置。测试包括假 HTTP/SOCKS 服务、失败不得直连、媒体状态和前台队列。
2. 标签屏蔽与收藏：持久化精确规则、全部显示入口、原始分页、临时显示与撤销、收藏恢复和数据验证。测试全页屏蔽后继续分页、规则更改后选择失效、收藏保留、损坏数据不覆盖以及小屏/大字/深浅主题。
3. 脚本完整性：不改真实数据；临时 SQLite/JSON/ZIP 回归覆盖失败保源、TLS、重同步、导出新鲜度和恢复。停止旧发布入口的自动推送行为。

各组都应通过对应测试、当前 HEAD 的代码审阅和独立 CI；最终发布需再次满足 RELEASE_GUIDE 的精确提交要求。

## 明确的后续能力边界

本轮优先完成基础浏览、代理、保存和过滤闭环。以下仍是可独立演进的产品功能：安全存储的站点账号/API key、需要认证的远程代理、PAC 自动解析、跨重启后台下载队列、超大图分块解码和离线图库管理。匿名权限限制不能通过代理修复；错误提示应区分认证/权限、网络、TLS 和限流。

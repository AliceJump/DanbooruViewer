# 前端视觉验收：模拟数据

本目录记录 `1.0.67` 前端重构的 Flutter 界面截图。**所有作品、图片、
补全词条和计数均为模拟数据**，不代表 Danbooru 的真实内容或接口响应。
12 张本地几何风景 PNG 构成 24 条全年龄作品，用于检查图片布局。

截图由临时 widget-test harness 直接渲染产品的 `MyHomePage`、搜索面板、
图库及 `PostThumbnailTile`。图片经实际缓存与 Flutter `Image` 渲染，
没有使用 HTML 复刻页面，也没有向产品加入演示数据或新的依赖。

| 场景 | 逻辑尺寸 | 字号比例 | 截图 |
| --- | --- | --- | --- |
| 桌面浅色、六列图库 | 1440 × 900 | 100% | [desktop-light-mock-data.png](desktop-light-mock-data.png) |
| 桌面深色、搜索建议展开 | 1440 × 900 | 100% | [desktop-dark-search-mock-data.png](desktop-dark-search-mock-data.png) |
| 手机浅色、两列图库 | 375 × 812 | 100% | [mobile-light-mock-data.png](mobile-light-mock-data.png) |
| 极短窗口、较大文字 | 320 × 300 | 200% | [short-window-text-200-mock-data.png](short-window-text-200-mock-data.png) |
| 极短窗口、刷新失败并保留作品 | 320 × 300 | 200% | [short-window-error-text-200-mock-data.png](short-window-error-text-200-mock-data.png) |

## 渲染与检查方式

每个场景都选择全年龄筛选。深色桌面场景输入“山”以展开三条模拟搜索
建议。错误场景在首次成功显示作品后让刷新请求返回 HTTP 503，保留已有
图片并显示应用自身的错误反馈。

测试使用设备像素比 1，通过 `RenderRepaintBoundary.toImage` 导出真实
控件树。为避免 Flutter widget test 默认 Ahem 字体将中文显示为方块，
临时 harness 加载本地 Roboto、Noto Sans CJK 及 Material Icons；这个测试
字体配置不进入产品主题。

导出前交替等待真实 I/O 与 Flutter 帧，断言所有已构建作品卡片都包含
已解码的 `RawImage.image`，并检查没有布局异常。`pumpAndSettle` 本身不会
等待所有文件读取和图片解码，因此不单独用它判断图片加载完成。
截图另经人工目视检查，覆盖明暗主题、手机布局、搜索建议与短窗口大字
状态。这些截图用于界面验收；真实网络、下载及平台集成仍由各自的测试
和构建验证。

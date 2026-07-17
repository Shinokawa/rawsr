# rawsr — 前端任务书 v1(M2 · Flutter 桌面 GUI)

> 前置:后端任务书 v1 的 T0–T6 已完成,`rawsr-core` 可用。
> 适用对象:Claude Fable / GPT-5.6-sol。执行纪律同后端任务书:一任务一会话、验收命令必跑必贴、禁止跨任务改接口。
> 目标平台:macOS + Windows(桌面先行,移动端不在本书内)。

---

## 0. 设计方向(已定稿,agent 不得自由发挥)

### 0.1 概念:暗房灯箱(Darkroom / Lightbox)

这是一个照片修复工具,UI 的第一职责是**不干扰用户对照片色彩与细节的判断**。因此:

- **界面 chrome 全部使用纯中性灰**(R=G=B,无任何色温倾向)。任何带色相的界面底色都会污染用户对照片白平衡的感知,这是功能约束,不是审美偏好。
- 全应用只有**一个彩色强调色**:安全灯琥珀(暗房红灯/琥珀灯,主题来源于摄影暗房),仅用于交互态(选中、焦点、进度、主按钮),永不大面积铺色。
- **签名交互:「试片」(Test Strip)**。暗房时代放大照片前先裁一小条相纸做曝光试条,本产品的核心工作流(在裁切区域上跑多个模型再决定全图导出)与之完全同构。UI 直接采用这个隐喻:用户框选区域 → 选 2–4 个模型 → 生成并排的竖向"试片条"同步缩放对比 → 点选"定片"(champion)→ 入队全图冲洗。
- **动效只有一处**:试片渲染完成时,从低对比度灰片淡入至完整影像(300ms,ease-out),模拟相纸在显影液中浮现。其余一律瞬时切换。系统开启"减少动态效果"时禁用。

### 0.2 设计 tokens(实现为 Flutter ThemeExtension,唯一色彩来源)

```dart
// 中性灰阶 —— 严格 R=G=B
chrome0   #161616   // 窗口底、侧栏
chrome1   #1F1F1F   // 面板、卡片
chrome2   #2A2A2A   // 输入框、hover
line      #383838   // 1px 分隔线
textHi    #E6E6E6   // 主文字
textLo    #9A9A9A   // 次要文字、标签
canvas    #202020   // 图像画布底色(默认)
canvasGray #808080  // 画布底色可切换的中灰(判色模式)

// 唯一强调色
safelight     #E5953B   // 选中、焦点环、进度、主按钮
safelightDim  #E5953B @ 24% alpha  // 选区遮罩、hover 提示

// 状态色(去饱和,仅图标+文字用,不铺底)
danger  #C4574E
```

### 0.3 字体与排版

| 角色 | 字体 | 用途 |
|---|---|---|
| UI 正文/标签 | 思源黑体 Source Han Sans SC(打包 400/500/700) | 全部界面文字,中文优先 |
| 数据 | IBM Plex Mono(打包 400/500,tabular figures) | EXIF、尺寸、耗时、内存、进度百分比——所有数字一律等宽 |

不引入第三种字体。层级靠字重和 `textLo` 灰阶,不靠字号膨胀:正文 13px,标签 11px,面板标题 13px/700。行高 1.5。间距基数 4px(常用 8/12/16/24),控件圆角 6px,面板圆角 10px,分隔线 1px `line`。

### 0.4 文案基调

中文优先、句式短、动词开头:「生成试片」「定片」「加入队列」「在访达中显示」。错误信息必须说明原因和下一步(「模型加载失败:CoreML 不支持算子 GridSample,已回退 CPU,速度会显著变慢」),禁止「出错了,请重试」。空状态是行动指引:首屏空库显示「拖入 RAW 或 JPEG 开始」+ 快捷键提示。

## 1. 信息架构与布局

```
┌────────────────────────────────────────────────────────┐
│ 标题栏(原生)                                            │
├──────┬─────────────────────────────────┬───────────────┤
│      │                                 │  检查器        │
│ 胶片  │           画  布                │  · EXIF(mono) │
│ 库    │   (缩放/平移/裁切框选)           │  · 显影参数    │
│ (缩略 │                                 │  · 模型选择    │
│  图列)│                                 │  [生成试片]    │
├──────┴─────────────────────────────────┴───────────────┤
│ 队列栏(折叠态一行:N 个任务 · 当前进度;展开为任务列表)     │
└────────────────────────────────────────────────────────┘
```

- 试片对比是画布区的一个**模式**(非弹窗):进入后画布切换为 2–4 条竖向试片,同步 pan/zoom,底部每条标注模型名 + 耗时(mono);点击条目上的「定片」徽标返回画布模式并锁定该模型。
- 判色模式:画布底色 #202020 ⇄ #808080 中灰一键切换(快捷键 L)。

## 2. 钉死的技术决策

| 项 | 决定 | 备注 |
|---|---|---|
| 框架 | Flutter 3.x stable,桌面 target macOS/Windows | 复用 NipaPlay 技术栈 |
| Rust 桥 | flutter_rust_bridge **v2**(版本在 F0 锁死写入文档) | codegen 命令写进 justfile |
| 状态管理 | Riverpod 2(hooks_riverpod) | |
| 大图显示 | 预览走降采样金字塔(见 F3),**不把 42MP 全分辨率位图交给 Flutter 纹理** | 桌面 GPU 纹理上限与内存 |
| 缩略图 | rawler 提取 ARW 内嵌 JPEG,不做完整解码 | core 侧新增 API |
| 进度 | Rust → Dart 用 FRB StreamSink | |
| 国际化 | zh 为源语言,intl 骨架搭好,en 后补 | |

### 2.1 core 侧需要新增的桥接 API(F0 一并交付,Rust 侧实现放 rawsr-core)

```rust
pub fn extract_thumb(path: String) -> Result<ThumbData>;            // 内嵌 JPEG + 基础 EXIF
pub fn open_image(path: String) -> Result<ImageHandle>;             // 解码+显影,缓存 sRGB f32
pub fn render_preview(h: ImageHandle, max_edge: u32) -> Result<RgbaBytes>;   // 降采样预览
pub fn render_region(h: ImageHandle, rect: Rect, max_edge: u32) -> Result<RgbaBytes>; // 放大时按需取区域
pub fn run_test_strip(h: ImageHandle, rect: Rect, models: Vec<String>,
                      sink: StreamSink<StripEvent>) -> Result<()>;  // 并发跑模型,逐条回推结果
pub fn enqueue_export(job: ExportJob, sink: StreamSink<JobEvent>) -> Result<JobId>;
pub fn list_models() -> Result<Vec<ManifestEntry>>;
```

## 3. 任务分解

### F0 · 桥接脚手架(1 天,全书最高风险项)
Flutter 桌面工程 + FRB v2 codegen 打通 rawsr-core + §2.1 API 骨架(可先 stub 数据)+ justfile(`just gen` / `just run-mac` / `just run-win`)+ CI 双平台构建。
**验收:** `flutter test integration_test/bridge_test.dart` — 调 `extract_thumb(sample.ARW)` 返回非空缩略图与正确尺寸;macOS 与 Windows CI 均绿。
**驱动者注意:** FRB 的 codegen/链接问题是 agent 最容易空转的地方,卡 30 分钟立即人工介入;版本一旦跑通立刻锁死并写入本节。

### F1 · 主题与组件库(1 天)
§0.2/0.3 落成 ThemeExtension + 基础组件:按钮(主/次/文字)、输入、滑杆、面板、分隔线、徽标、进度条、快捷键提示。每个组件一个 golden test。
**验收:** `flutter test --update-goldens` 后 `flutter test` 全绿;goldens 目录入库;任何硬编码颜色(theme 之外的十六进制)在 lint 中报错(自定义 lint 或 grep 检查脚本)。

### F2 · 胶片库 + 检查器(1 天)
拖放/文件选择导入 → 缩略图列表(虚拟滚动)→ 选中项 EXIF 面板(机身、镜头、ISO、快门、光圈、尺寸,全部 mono 字体)→ 显影参数区(曝光 EV 滑杆、base curve 二选一)。
**验收:** widget test:导入 mock 的 20 个文件列表滚动不掉帧断言(帧预算测试);EXIF 面板 golden;拖入非支持格式显示指引性错误文案。

### F3 · 画布(1.5 天)
缩放/平移(自实现手势层,不用 InteractiveViewer 的默认惯性)、降采样金字塔显示(打开时 `render_preview(2048)`,放大超过 1:2 时按视口调 `render_region`)、裁切框选(safelightDim 遮罩 + 8 控制点 + 尺寸标注 mono)、判色模式切换(L)。
**验收:** integration test:打开 sample.ARW → 框选 → 断言 Rect 像素坐标换算正确(视口坐标 ↔ 原图坐标往返误差 ≤1px);缩放到 400% 时触发 region 渲染的调用断言。

### F4 · 试片对比(1.5 天,签名交互)
模型多选(2–4)→ `run_test_strip` → 条目按完成顺序流式出现(显影淡入动效,reduce-motion 时直出)→ 同步 pan/zoom(单一控制器广播)→ 每条底部模型名+耗时 → 「定片」选择 → 返回画布模式。
**验收:** integration test:mock 三模型流式返回,断言三条按序渲染、pan 同步(三条 offset 相等)、定片后状态写入;动效 golden 用 `Animation` 定帧截图两张(0% / 100%)。

### F5 · 队列与导出(1 天)
定片后「加入队列」→ ExportJob(全图或选区、降噪+超分组合、输出路径)→ 队列栏:折叠一行摘要 / 展开列表(每项:缩略图、模型链、进度条、剩余估时 mono、取消)→ 完成态:系统通知 + 「在访达/资源管理器中显示」。
**验收:** integration test:mock JobEvent 流驱动进度 0→100,断言 UI 状态机(排队/运行/完成/失败/取消)五态各自渲染正确;失败态文案包含原因字段。

### F6 · 设置与模型管理(0.5 天)
模型列表(manifest 只读展示:名称、类型、倍率、体积)、导入 .onnx(复制进 models/ 并追加 manifest)、当前推理设备与 EP 显示(来自 core 日志接口)、语言切换骨架。
**验收:** widget test:导入 mock onnx 后列表刷新;EP 显示字段渲染。

## 4. 已知的坑

1. **FRB 生成代码不入 git 之外的手改**——所有桥接改动必须改 Rust 签名后 `just gen`,agent 手补生成文件是常见错误。
2. Flutter 桌面单纹理有尺寸上限(常见 8192px),42MP 原图 7952px 已贴边,4x 输出必然爆——所以预览必须走金字塔,任何"直接显示全图"的实现直接打回。
3. `render_region` 返回 RGBA u8;从 core 的 f32 转 u8 的量化在 Rust 侧做,不要把 f32 buffer 传过桥(拷贝量 ×4)。
4. Windows 拖放中文路径编码问题,测试用例必须包含中文文件名。
5. golden test 在 macOS/Windows 字体渲染有差异,goldens 只在 CI 的 Linux 容器生成或按平台分目录,F1 里先定好策略。
6. 试片并发跑多个模型时显存会叠加,core 侧 `run_test_strip` 串行执行、流式返回即可,UI 不假设并行。

## 5. Definition of Done(M2 整体)

- [ ] macOS + Windows 可打包运行(`flutter build macos` / `flutter build windows`)
- [ ] 端到端人工验收脚本:导入 A7R II 原片 → 框选 → 三模型试片 → 定片 → 队列导出 → 打开成品 TIFF,全程无崩溃、无主线程卡顿超过 100ms(DevTools 检查)
- [ ] 所有 golden/widget/integration test 绿;主题外硬编码颜色为零
- [ ] 键盘可达:导入、模式切换、定片、入队均有快捷键并在 UI 上标注

## 6. 给驱动者的操作建议

- F0 必须你在场陪跑,其余任务可放手;F1 的 goldens 第一次生成后人工过目一遍再入库。
- F3/F4 涉及坐标换算与手势,agent 写完后你亲手操作两分钟比任何测试都快暴露手感问题——手感(缩放阻尼、框选吸附)不写进验收,留给你现场调参。
- 预估:agent 串行 6–7 天,F1/F2 与 F3 可双 agent 并行压到 4–5 天。加上后端,整个 M0–M2 两周内是现实的。

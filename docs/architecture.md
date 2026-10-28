# 整体架构

本页是整体架构入口：组件边界、线程/所有权、数据流和发布状态。
App 侧细节见 [app-architecture.md](app-architecture.md)，Emacs OHOS 侧细节见
[emacs-architecture.md](emacs-architecture.md)，能力边界见
[capabilities.md](capabilities.md)。

> 当前基线：分支 `feat/per-frame-renderer`，Emacs 基线 tag `emacs-31.1`。
> Host ABI：`OHOS_GUI_ABI_VERSION = 13`（typed host API）。
> 产品路径：单主窗口；多窗口实现保留为实验特性（⛔ BLOCKED）。

## 1. 一句话定位

```text
Emacs   决定显示什么（frame / window / glyph / face / font / redisplay）
renderer 决定怎么变成像素（surface / bitmap / canvas / present）
UI      决定窗口、输入和生命周期（XComponent / NativeWindow / IME / menu）
```

Emacs 不是“每个窗口一个应用实例”。整个应用只有：

```text
一个进程
一个 Emacs 线程 / 一个 Lisp 状态
一个 UIAbility + WindowStage
一个 UI 线程
```

多 frame 只是同一个 Emacs 的多个输出窗口；单个窗口内的 split 仍由 Emacs
window 管理，不创建新的 XComponent。

## 2. 组件图

```text
┌──────────────────────────────────────────────────────────────────┐
│ UI 线程 / ArkTS                                                   │
│                                                                  │
│  EntryAbility                                                     │
│    └── WindowStage                                               │
│          ├── main window → pages/Gui → XComponent emacs_gui      │
│          └── (实验) FrameWindowManager → pages/Frame             │
│                                                → emacs_frame_N  │
│                                                                  │
│  libentry.so                                                      │
│    ├── NAPI 导出 / HostEvent mailbox                              │
│    ├── XComponent 注册 / SurfaceRegistry                          │
│    └── 输入、IME、窗口命令、菜单结果桥接                          │
└──────────────────────────────┬───────────────────────────────────┘
                               │ typed C ABI 13
┌──────────────────────────────▼───────────────────────────────────┐
│ Emacs 线程 / libemacs_gui.so                                      │
│                                                                  │
│  ohos.c         输入环、TSFN/结果管道、frame 注册                  │
│  ohosgui.c      RIF/redisplay hooks、frame/surface 路由、present   │
│  ohosfns.c      frame 参数、make-frame/delete-frame、chrome       │
│  ohosmenu.c     menu bar / popup / dialog                         │
│  ohosselect.c   clipboard / request                               │
│  ohosfont.c     font/fontset 与 glyph 栅格化                      │
│                                                                  │
│  libohos_render.a（静态链接）                                     │
│    surface 状态、bitmap/canvas、字体/图像缓存、present             │
└──────────────────────────────────────────────────────────────────┘
```

`libentry.so` **不链接也不包含 renderer 类型**；renderer 只在 Emacs 线程内使用。

## 3. 线程与所有权

### UI 线程

负责：

- XComponent / NativeWindow / Surface 生命周期；
- 键盘、鼠标、触摸、IME；
- ArkUI 菜单栏/菜单面板、窗口命令；
- 把 surface/input 事件投递给 Emacs。

禁止：

- 创建/访问 renderer bitmap/canvas；
- 直接修改 Emacs frame 或 Lisp 对象；
- 在 surface 回调里同步等待 Emacs。

### Emacs 线程

负责：

- frame 创建、删除、选择、参数变更；
- redisplay 与 RIF 回调；
- renderer 状态迁移、绘制、present；
- 消费 surface/input 事件。

### Surface 生命周期

`Surface` 由 `SurfaceRegistry` 以 `shared_ptr` 持有；所有跨回调访问都通过
`AcquireSurfaceByFrame` / `AcquireSurfaceByComponent` / `AcquireCurrentSurface`
取得强引用。`RemoveSurface` 只从 registry 删除，不释放仍被 handler 使用的对象。
这是 `guiState()` 滚动崩溃（UAF）后的固定约束。

## 4. 数据流

### 4.1 启动

```text
EntryAbility
  → loadContent('pages/Gui')
  → XComponent onLoad
  → libentry.so 注册 XComponent / Surface
  → dlopen(libemacs_gui.so)
  → Emacs 线程启动
  → 创建 boot frame（frame_id = 1）
  → surface_created → frame size → redisplay → present
```

### 4.2 输入

```text
XComponent callback
  → libentry.so 生成 typed input record（带 frame_id）
  → Emacs 输入环 / TSFN
  → kbd_buffer_store_event
  → Emacs command loop
```

键盘/IME 只投递给 focused frame。鼠标 motion 必须发送 **frame 像素
坐标**，不能只发送正文 cell 坐标：mode line 和 echo area 不在正文
`s.rows` 内，但仍然是 Emacs 的 frame 区域。OHOS 没有原生 tooltip
后端，`help-echo` 由 `tooltip-mode` 关闭后落到 Emacs echo area。

### 4.3 redisplay / present

```text
Emacs redisplay
  → RIF update_begin(frame)
  → glyph/face/font → renderer draw calls
  → update_end(frame)
  → present(frame)
```

present 只在 surface READY 且 frame content 完整时提交。失败时保留 last-good
frame，并请求下一次 redisplay。

### 4.4 Host 事件

```text
Emacs 线程
  → typed ohos_host_api（create/destroy/raise/…/menu/request）
  → libentry.so HostEvent mailbox（带 frame_id）
  → UI 线程遍历事件
  → ArkUI / WindowStage / 系统服务
```

UI → Emacs 的菜单/请求结果通过 typed `menu_result` / `request_result` 回调返回。
JSON 只作为菜单/剪贴板等变长 payload，不再承载“字符串命令”。

### 4.5 Surface 事件

```text
UI 线程
  → SurfaceRegistry / surface event queue
  → ohos_input_resize / expose / destroyed（带 frame_id + generation）
  → Emacs 线程按 frame 路由
  → renderer 状态迁移
```

旧 generation 的事件在 frame/surface 已删除后丢弃。

## 5. 身份与注册表

```text
frame_id : uint32_t

Emacs 侧：FrameRegistry     frame_id → ohos_output/renderer
UI 侧：   SurfaceRegistry   frame_id → Surface/XComponent/NativeWindow
```

约束：

- `frame_id` 是唯一跨线程键；
- 不跨 ABI 传 `struct frame *`、Lisp 对象或 renderer 指针；
- 主窗口固定 `frame_id = 1`，XComponent id 为 `emacs_gui`；
- 后续实验窗口的 XComponent id 为 `emacs_frame_<id>`。

## 6. ABI 边界

```text
Emacs → UI : ohos_host_api
UI → Emacs : ohos_emacs_api
```

ABI 13 的边界规则：

- frame 生命周期、几何、title、chrome、focus、close 全部 typed；
- 菜单、剪贴板、通知等变长内容仍用字符串/JSON payload；
- 结果使用 request/menu id 与 typed result 回调，不使用单槽字符串队列；
- 任何跨线程 handoff 都必须保留 frame 身份，不能依赖全局 selected frame。

详见 [Emacs OHOS 侧架构](emacs-architecture.md) 和 [能力边界](capabilities.md#21-多窗口--每-frame-renderer-contextblocked)。

## 7. 几何权威

```text
surface 提供可用像素尺寸
  → Emacs pixelwise resize / 布局
  → FRAME_PIXEL_WIDTH × FRAME_PIXEL_HEIGHT（content rect）
  → renderer 只按 content rect 生成像素
```

规则：

- surface 驱动 frame 尺寸，但 frame 是内容几何的唯一权威；
- backend 不按字符格取整来缩减 frame；
- `frame > surface` 时进入 `RESIZING`，不绘制、不提交；
- renderer 不决定窗口尺寸和布局。


## 8. 架构文档地图

| 文档 | 角色 |
| --- | --- |
| 本页 | 整体入口：组件、线程、数据流、发布状态 |
| [app-architecture.md](app-architecture.md) | ArkTS、HostBridge、Surface、启动流程 |
| [emacs-architecture.md](emacs-architecture.md) | Emacs OHOS 后端、renderer、RIF 集成 |
| [capabilities.md](capabilities.md) | 当前支持范围、限制、已知阻塞 |
| [development-standards.md](development-standards.md) | ArkTS/C++/Emacs 规范和检查 |
| [manual-feature-matrix.md](testing/manual-feature-matrix.md) | 人工测试用例与状态 |
| [build-deploy.md](build-deploy.md) | 构建、部署、日志与故障定位 |

维护约定：

- 系统级结论放本页，模块细节放对应文档；
- 同一设计只保留一个权威版本，其它文档用链接；
- 文档状态必须和当前分支/tag/ABI 对齐；
- 设计稿与已实现内容分开标注，不把目标写成现状。

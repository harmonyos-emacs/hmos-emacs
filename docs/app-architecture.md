# App 侧架构

本页只描述 HarmonyOS 应用侧：ArkTS UI、`libentry.so`、宿主服务和 Surface。
Emacs 内部 redisplay、renderer 像素实现分别见
[Emacs OHOS 侧架构](emacs-architecture.md) 和 [整体架构](architecture.md)。

## 1. 分层

```text
ArkTS / UI 线程
  EntryAbility
    └─ Gui.ets / Frame.ets
         ├─ FrameWindowManager.ets
         └─ HostBridge.ets

Native app 侧
  libentry.so
    ├─ NAPI 适配（host/napi/）
    ├─ HostContext / EmacsHost
    ├─ RuntimeInstaller
    ├─ ImeService / SystemBridge
    └─ gui/Surface + present 桥

Emacs
  libemacs_gui.so
    └─ typed host ABI（ohos_emacs_api / ohos_host_api）
```

UI 线程负责窗口、XComponent、输入和生命周期；Emacs 线程负责
frame/window/glyph/Lisp。renderer 只按 frame 输出像素，不拥有窗口。

## 2. 启动流程

```text
EntryAbility.onCreate
  → 准备 runtime（首次安装 / 更新时解包）
  → 创建主窗口 / WindowStage
  → 加载 pages/Gui
  → 创建 XComponent
  → surface ready
  → 启动进程内 Emacs 线程
  → Emacs 创建首个 frame
  → renderer 绑定该 frame 的 surface
```

`libemacs_gui.so` 与 ArkTS 不直接共享对象；跨边界只使用：

```text
frame_id
typed host API 结构体
request/menu id
字符串或 JSON payload（仅变长内容）
```

## 3. 主要文件

| 路径 | 职责 |
| --- | --- |
| `app/entry/src/main/ets/entryability/EntryAbility.ets` | UIAbility 生命周期、窗口创建 |
| `app/entry/src/main/ets/pages/Gui.ets` | 主页面、XComponent、菜单/输入桥接 |
| `app/entry/src/main/ets/pages/Frame.ets` | 子窗口页面（实验路径） |
| `app/entry/src/main/ets/common/FrameWindowManager.ets` | subWindow 生命周期 |
| `app/entry/src/main/ets/common/HostBridge.ets` | ArkTS ↔ native typed 调用 |
| `app/entry/src/main/cpp/host/emacs_host.cpp` | Emacs 线程、启动和 host 回调 |
| `app/entry/src/main/cpp/host/napi/` | 薄 NAPI 适配，不写业务 |
| `app/entry/src/main/cpp/gui/` | Surface、输入、present 桥 |
| `renderer/` | per-frame bitmap/绘制/present 实现 |

## 4. 所有权与线程

- `HostContext` 拥有 `EmacsHost`、`RuntimeInstaller`、`ImeService`、
  `SystemBridge`；NAPI 适配层不持有长期业务状态。
- `Surface` 的锁只保护 surface 自身状态；锁内不做文件、NAPI 或绘制 I/O。
- Emacs 线程是唯一 Lisp/redisplay 线程；UI 线程不直接调用 Emacs 内部函数。
- 每个 `frame_id` 对应一个 surface/renderer context；事件必须带 `frame_id`。
- ArkUI 页面不保存 renderer 指针或 Lisp 对象。

## 5. 修改边界

- 新增 host 能力：先加 typed API 字段/回调，再改 `app/` 与 `emacs/` 两侧；
- 新增窗口：走 `FrameWindowManager`/`create_window`，不要绕过 Emacs frame；
- 新增文本效果：在 Emacs/RIF 或 renderer 实现，不要为每段文本创建 ArkUI 组件；
- surface 尺寸变化只更新 surface，frame 内容几何仍由 Emacs 决定。

多窗口当前是实验特性且产品状态 BLOCKED，能力边界见
[capabilities.md](capabilities.md#21-多窗口--每-frame-renderer-contextblocked)。

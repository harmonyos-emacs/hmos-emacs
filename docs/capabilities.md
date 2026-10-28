# 当前应用的产品能力边界

本页描述当前实现的**支持范围**和由架构决定的能力边界。系统结构见
[整体架构](architecture.md)。

状态含义：

| 标记 | 含义 |
| --- | --- |
| ✅ | 产品路径支持 |
| ◐ | 有实现，但存在明确边界或未纳入产品路径 |
| ⛔ | 当前架构/构建不支持 |

能力会随构建选项变化（尤其 `WITH_IMAGES`、`--with-dumping`、ABI），引用时需同时
注明基线 commit 和构建参数。

## 1. 支持范围

| 能力 | 状态 | 实现边界 |
| --- | --- | --- |
| HAP 启动与页面路由 | ✅ | `EntryAbility` 固定加载 `pages/Gui` |
| 应用进程内运行 Emacs | ✅ | `startInProcess` + `dlopen(libemacs_gui.so)` + pthread |
| `window-system = ohos` | ✅ | `ohos_term_init` 设置 `Vwindow_system=Qohos`、`Fprovide(Qohos)` |
| 单 OHOS frame | ✅ | `ohos_create_frame` 删除 bootstrap tty frame；一个 surface 对应一个 frame |
| 启动画面/真实几何 | ✅ | surface 尺寸在 frame 创建前报告，`change_frame_size` 采用 |
| 文本 redisplay | ✅ | glyph → `TEXT` → RGBA bitmap → OHNativeWindow |
| 绘制/传输 | ✅ | NativeWindow buffer + 整帧 bitmap present；damage 优化仍在演进 |
| CJK / fontset | ✅ | OH_Drawing mono + CJK 双字体；显式 CJK charset 映射 |
| 光标 | ✅ | `CURSOR` op + box/hollow/bar/hbar + blink |
| 鼠标/触摸/指针形状 | ✅ | motion、press/release、触摸去重、`pointer.setPointerStyleSync` |
| 触摸选择/双击选词 | ◐ | 由 Emacs mouse 事件处理，待人工验收 |
| 外部菜单栏 | ✅ | ArkUI `Row` + `menubar` 发布；F10 打开第 0 项 |
| 菜单面板/子菜单/对话框 | ✅ | `menu-open` JSON + `guiMenuResult`；`x-popup-menu`/dialog 复用 |
| 滚动条 | ◐ | 绘制/命中/拖动代码完整；默认显示和全边界交互未纳入产品契约 |
| 图片 PNG/SVG | ✅ | libpng + vendored nanosvg；`:file`/`:data` |
| 其他图片格式 | ◐ | `image-types` 含 `xbm/pbm/canvas`；JPEG/GIF/WebP 未链接 |
| 系统剪贴板 | ✅ | Pasteboard + base64；`READ_PASTEBOARD` 由 Profile ACL 预授权并在启动时申请；PRIMARY 映射到同一剪贴板 |
| 通知 | ✅ | `HostBridge`；依赖系统服务可用性 |
| 滚轮 | ✅ | `guiWheel` 进入 Emacs `WHEEL_EVENT` |
| 拖放文件 | ✅ | `onDrop` 支持 File/Image/Video 及携带 `file://` 的 PlainText/Hyperlink；单文件 |
| 用户目录直接访问 | ✅ | Desktop/Documents/Download 经 `Environment` 映射，直接读写原文件 |
| 多文件/文件夹拖拽 | ◐ | 只取第一个文件；`general.folder` 暂不支持 |
| 窗口 resize/move/fullscreen/maximize/minimize | ✅/◐ | 主窗口完整；subwindow 有系统 maximize，minimize 用窗内 `—`；父窗口无法 raise 到子窗口之上 |
| 窗口 alpha/lower/真正 hide | ⛔ | HarmonyOS 无对应应用窗口 API |
| 系统 IME 直连 surface | ✅ | 点击/触摸 XComponent 均 attach + show；无页内键盘按钮 |
| 滚动后 mode line 异常 | ✅ |  |
| 多 frame / child frame | ⛔ BLOCKED | 实现可运行并完成 MW 验证，但 API 24 子窗口无法 raise 父窗口、缺少系统最小化；不作为产品特性 |
| 工具条 | ⛔ | `HAVE_EXT_TOOL_BAR` 未定义 |
| tab bar | ◐ | `tab-bar-lines`/高度 hook 存在，未作为产品特性 |
| fringe | ◐ | `draw_fringe_bitmap` 已实现；默认宽度/启用取决于参数 |
| 原生滚动条 widget | ⛔ | 滚动条由 `FILL` 自绘，不是系统控件 |
| 无障碍/读屏 | ⛔ | 未实现 ArkUI accessibility 映射 |
| 多显示器/DPI 变化 | ⛔ | 单 display，固定 96 dpi |
| 崩溃隔离 | ⛔ | Emacs 与 UI 同进程；Emacs 崩溃会带崩应用 |

## 2. 架构限制

### 2.1 多窗口 / 每 frame renderer context（BLOCKED）

> **产品状态：⛔ BLOCKED。** 以下为实验实现，不是发布承诺。
> 原因：API 24 子窗口始终在父窗口之上，无法实现 Emacs 的独立 raise；
> 子窗口系统装饰无最小化。解除条件见 [已知阻塞](#4-已知阻塞)。

UI 侧采用一个 `UIAbility` + `WindowStage` + 多个 subWindow：

```text
main window  → frame 1 (emacs_gui)
subwindow N  → frame N (emacs_frame_N)
```

每个 frame 有独立 `ohos_renderer`、surface 绑定、bitmap、字体缓存和
begin/end/present 事务；surface 与输入事件都带 `frame_id` 路由，不依赖全局
selected frame。

`make-frame` 通过 typed `create_window` 请求 ArkTS 创建 subwindow；
`delete-frame` / 关闭按钮通过 `close_request` → `DELETE_WINDOW_EVENT` →
`delete-frame` → `destroy_window` 回收窗口。实验路径不改变其 BLOCKED 状态。

仍待完善：

- 子窗口已有基础 menubar/menu 面板；支持子菜单、Esc/上下键/Enter 导航；
  超长菜单的滚动细节仍需验证；
- `window_create_failed` 降级路径已通过临时注入验证，非 2in1 设备仍建议实机确认；
- cursor/hourglass/bell/fullscreen/visible 已带 frame 路由；alpha/lower 仍无
  HarmonyOS 应用窗口 API；
- IME 文本/按键按 focused frame 路由；IME 代理句柄为进程级，同一时刻只服务
  focused frame；
- child frame 已通过 parent Window 的 createSubWindowWithOptions 创建并相对定位，
  设备验证 `subwindow created frame=2 parent=1`；层级/关闭顺序仍需验证；
- 删除 main window 对应的 frame 1 且仍有子窗口时，主窗口会保留旧画面；
  `Window.minimize()` 会连子窗口一起隐藏，不可用，后续考虑子窗口迁移。

### 2.2 Emacs 构建依赖


| 能力 | 依赖 | 运行时表现 |
| --- | --- | --- |
| `HAVE_GNUTLS` | `build/deps` 的 GnuTLS 3.8.9 静态库 | `gnutls-available-p` 非 nil；`url-retrieve`/Eww 的 https 不再加载已废弃的 `tls.el` |
| `HAVE_LIBXML2` | libxml2 2.12.10（`third_party/src`，MIT） | `libxml-parse-html-region` 可用，Eww 能解析 HTML |
| `HAVE_SQLITE3` | SQLite 3.54.1 amalgamation（`third_party/src`，Public Domain） | `sqlite-available-p` 为 t，`sqlite-open/-execute/-select` 可用 |

约束与边界：

- GnuTLS 仅信任 HAP 内的 `home/etc/ssl/ca-bundle.crt`（`gnutls-trustfiles`），
  沙箱没有系统证书库，不关闭 `gnutls-verify-error`；
- SQLite 以 `SQLITE_OMIT_LOAD_EXTENSION` 编译，`sqlite-load-extension` 不存在
  （本构建没有动态 Emacs modules，不允许加载任意 `.so`）；
- 三项仍以静态库链接进 `libemacs_gui.so`，版本、来源和 `sha256` 记录在
  `build-manifest.json` 与 [`third_party/versions.json`](../third_party/versions.json)；
- 仍未启用 native-compilation、modules；沙箱没有 node/python/ffmpeg/mpv/bash
  等外部程序。依赖这些能力的包只能显示错误态。

### 2.3 Emacs 外部命令支持 

- 约束
  
  App 沙箱只允许执行系统镜像和签名 HAP 代码，当前只利用默认受限 /system/bin/* 提供基本工具支持

- 可拓展
  
  打包外部命令为签名代码，fork 后，配合自定义 ELF loader 模拟 exec 过程，创建子进程执行环境。
  让 Emacs 的典型功能有**可预期**的外部命令支持：`grep-find`/`rgrep`、`dired`、`shell-command`/`M-x shell`、`compile`、 基础 VC、可选 LSP；


### 2.4 IME/输入细节

- 系统 IME 直连 surface，没有页内键盘按钮；
- 点击和触摸 XComponent 走同一条路径：先恢复该 frame 焦点，再
  `guiShowIme(frame_id)`；
- IME 文本/按键/提交按 focused frame 路由；preedit 由系统 IME 管理；
- `combining_capability` 返回 nil，复杂组合字符排版能力有限。

### 2.5 拖拽与用户目录

拖入的数据按 UDMF 记录类型处理，不按扩展名/MIME 白名单过滤：

| 记录类型 | 处理 |
| --- | --- |
| `general.file`（`File`） | 读取 `uri` |
| `general.image`（`Image`） | 优先 `imageUri`，其次 `uri`；PNG/JPEG 等由 Emacs 图片支持决定显示 |
| `general.video`（`Video`） | 优先 `videoUri`，其次 `uri` |
| `PlainText` / `Hyperlink` | 仅内容为 `file://` URI 时按文件处理 |

路径与可写性：

- `file://docs/storage/Users/currentUser/{Desktop,Documents,Download}/...`
  经 `Environment.getUser*Dir()` 映射为 `/storage/Users/currentUser/...`，
  直接把原始路径交给 Emacs，保存写回原文件；
- 其他目录的文件通过拖拽临时 URI 授权复制到
  `cacheDir/drop-*`，Emacs 打开副本，保存不回原文件；
- 文件夹（`general.folder`）、多文件（只取第一个）、无 URI 的纯文本/HTTP
  链接不在支持范围；其他目录的文件夹会提示不支持。

权限与 Profile：

- `READ_WRITE_DOCUMENTS_DIRECTORY`、`READ_WRITE_DOWNLOAD_DIRECTORY` 为
  normal `user_grant`；`READ_WRITE_DESKTOP_DIRECTORY` 为 `system_basic`，
  需要 ACL；
- 三项目录权限由 `refs/debug/emacs-hmos3Debug.p7b` 的 ACL 允许申请，启动时
  一次 `requestPermissionsFromUser`，用户同意后原生 Emacs 可读写对应目录；
- `READ_PASTEBOARD` 同在该 ACL 中，系统按预授权处理，不弹窗；目录权限仍会
  弹一次用户确认；
- 不带上述 ACL 的 Profile 安装会报 `9568289 grant request permissions failed`。


## 3. 相关文档

- 整体架构：[`architecture.md`](architecture.md)
- Emacs OHOS 侧：[`emacs-architecture.md`](emacs-architecture.md)
- 构建/部署：[`build-deploy.md`](build-deploy.md)
- 人工测试：[`testing/manual-feature-matrix.md`](testing/manual-feature-matrix.md)

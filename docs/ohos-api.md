# OHOS Lisp/C API

本页记录 HarmonyOS 端口新增的 Lisp-visible 接口及其边界，不重复
[整体架构](architecture.md) 和 [Emacs OHOS 侧架构](emacs-architecture.md)。

## 1. 分层约定

| 层 | 命名 | 用途 | 兼容承诺 |
| --- | --- | --- | --- |
| 公共命令 | `ohos-*`，`interactive`，有文档 | 用户可直接 `M-x` 调用 | 发布后保持兼容 |
| 公共底层 API | `ohos-*`，C primitive 或稳定 Lisp API | host bridge、selection、menu、frame | 变更需同步 ArkTS/C |
| 内部实现 | 文件内函数或 `ohos--*` | 菜单 helper、selection helper | 可随时改 |

## 2. C primitives

| 接口 | 作用 | 调用方 | 结论 |
| --- | --- | --- | --- |
| `ohos-create-frame` | 创建原生 OHOS frame | `frame-creation-function` | 保留 |
| `ohos-get-selection` | 读系统剪贴板 | selection backend | 保留 |
| `ohos-set-selection` | 写系统剪贴板，UTF-8 + base64 | selection backend | 保留 |
| `ohos-selection-owner-p` | 剪贴板归属判断 | selection backend | 保留 |
| `ohos-selection-exists-p` | 剪贴板存在判断 | selection backend | 保留 |
| `ohos-menu-bar-item` | 取菜单项定义 | 菜单打开逻辑 | 保留 |
| `ohos-menu-bar-refresh` | 刷新 native 菜单 | 5 秒定时器 | 保留 |
| `ohos-menu-bar-take-request` | 取 host 菜单请求 | 0.5 秒轮询 | 保留 |
| `ohos-mouse-absolute-pixel-position` | 指针绝对坐标 | `mouse-drag-line` | 保留 |
| `ohos-notify` | 发系统通知 | `ohos-post-notification` | 保留（若通知是产品能力） |

已删除：

- `ohos-set-title`：原生标题由 `implicit_set_name_hook` 驱动，
  `.emacs` 只需设置 `frame-title-format`。
- `ohos-set-clipboard`：与 `ohos-set-selection` 重复；`.emacs` 的复制行
  改为 `gui-set-selection`。
- `ohos-host-user-directory`：用户目录选择功能整体移除。
- `ohos-make-child-frame`：child frame 仍 BLOCKED，不再暴露测试入口。
- `ohos-debug-rif`：纯调试接口，已删除。
- `ohos-dev-*`：开发 overlay 已删除。
- `ohos-libxml-parse-html-region`：x86_64 不是目标，libxml2 fallback 已删除。

## 3. Lisp 接口

| 接口 | 作用 | 调用方 | 结论 |
| --- | --- | --- | --- |
| `ohos-selection-bounds` | 选区转 buffer 范围 | 内部 | 保留（internal） |
| `ohos-encode-select-string` | 选区转字符串 | 内部 | 保留（internal） |
| `ohos-menu-bar-command` | 菜单事件转 command | 内部 | 保留（internal） |
| `ohos-menu-bar-open-index` | 打开第 N 个菜单项 | F10 / poll | 保留 |
| `ohos-menu-bar-open` | 打开菜单栏 | 交互/F10 | 保留 |
| `ohos-menu-bar-poll` | 处理 host 菜单请求 | 0.5 秒定时器 | 保留 |
| `ohos-post-notification` | 通知交互包装 | 无调用 | **待定**：补入口/文档或删除 |
| `ohos-init-frame-faces` | no-dump 下初始化 face | frame hook | 保留 |
| `ohos-refresh-frame-faces` | init 后刷新 face | `window-setup-hook` | 保留 |
| `ohos-widget-button-press` | 修复 Custom Themes 点击 | custom theme keymap | 保留 |
| `ohos-browse-url` | Eww 打开链接 | `.emacs` / `browse-url` | 保留 |

## 4. `~/.emacs` 中的接口

| 接口 | 作用 | 结论 |
| --- | --- | --- |
| `yank`（标准绑定） | 经 selection backend 读取系统剪贴板 | 使用标准 Emacs 实现 |
| `ohos-gui-copy-line` | `C-c l` 复制当前行；`copy-region-as-kill` 自动同步剪贴板 | 可选便利功能 |
| `frame-title-format` | 原生标题由 `implicit_set_name_hook` 更新 | 标准 Emacs 配置，无 OHOS 专用接口 |

## 5. Host request ABI

`emacs/src/ohos_host_abi.h` 的请求值必须与 ArkTS 的
`Gui.ets` host event (`op=21`, `event.a`) 保持一致：

| 值 | 请求 |
| --- | --- |
| 0 | `OHOS_REQUEST_CLIPBOARD_GET` |
| 1 | 已退役（原 battery），**不要复用** |
| 2 | 已退役（原 user-directory picker），**不要复用** |
| 3 | `OHOS_REQUEST_NOTIFY` |

规则：

- 只追加新值，不重排旧值；
- 删除请求时保留数值空洞，避免旧 host/新 Emacs 或反向组合错路由；
- 修改枚举时同步更新本页和 `Gui.ets`。

## 6. 菜单栏交互

菜单栏不是 Emacs 自己绘制的，而是 host 与 Emacs 的双向请求：

```text
1. Emacs 刷新菜单定义
   ohos-menu-bar-refresh (C)
     -> set_frame_menubar
     -> ohos_publish_menu_bar
     -> host event op=18 {bar:[{index,label},...]}
     -> ArkTS Gui.menubar 渲染顶部菜单文字

2. 用户点击 ArkUI 菜单文字
   Gui.onMenuBarClick(index)
     -> entry.guiMenuBarClick(index)  (NAPI)
     -> C ohos_menu_bar_request(index) 只保存 pending index

3. Lisp 定时器取请求
   ohos-menu-bar-poll                 (每 0.5s)
     -> ohos-menu-bar-take-request     (C, 取走 pending index)
     -> ohos-menu-bar-open-index       (Lisp)
        -> ohos-menu-bar-item          (C, 返回该菜单项的 keymap)
        -> x-popup-menu                (标准 Emacs 菜单机制)

4. x-popup-menu 的显示/选择
   C menu_show_hook
     -> host event op=19 {id,json}
     -> ArkTS MenuPanel 渲染菜单项
     -> 用户选择 -> guiMenuResult(id,index) (NAPI)
     -> C ResolveMenu -> x-popup-menu 返回选中事件

5. 执行命令
   ohos-menu-bar-command (Lisp)
     -> lookup-key 得到 command
     -> call-interactively 执行
     -> restoreFrameFocus 把键盘焦点还给 XComponent
```

重要约束：

- ArkUI 线程只存 index，不直接执行 Emacs command；
- 菜单弹出必须回到 Lisp 上下文执行，否则 `x-popup-menu` 会破坏状态；
- 菜单栏刷新目前是 5 秒轮询，host 只发布变化的 item 列表；
- 这一路径只用于主窗口；子窗口菜单仍走各自的 host 事件。

## 7. 平台默认值

app 不再向 `~/.emacs` 安装或覆盖任何内容。OHOS 平台默认值由
`emacs/lisp/term/ohos-win.el` 提供：

- `frame-title-format "Homacs — %b"`；
- `gnutls-trustfiles` 指向 runtime 的 `etc/ssl/ca-bundle.crt`；
- `mouse-wheel-mode` / `xterm-mouse-mode`；
- Eww 的 `browse-url-browser-function`；
- 首次 frame 与 face 初始化 hook。

`~/.emacs` 归用户所有；没有 marker，也没有 `home-init.tar.gz`。

## 8. 待清理项

| 项目 | 处理 |
| --- | --- |
| `ohos-post-notification` | 决定通知是否属于产品能力；否则连同 `ohos-notify` 评估删除 |

## 9. libxml2

aarch64 是唯一产品目标，固定使用 `--with-xml2` 和 Emacs 内置
`libxml-parse-html-region`。x86_64 不是发布目标，因此不再保留
`.emacs` 或 `ohos-win.el` 中的 HTML 解析 fallback。

## 10. 新增/删除接口规则

1. 能用标准 Emacs 接口（`gui-backend-*`、selection、menu、frame）表达的，
   不新增 `ohos-*`；
2. 新增公共接口必须同时更新本页、`docs/capabilities.md`（如涉及能力）；
3. C primitive 变更必须同步 `index.d.ts`、`check-napi.sh` 和 ArkTS 调用；
4. host request 值只追加、不重排；
5. 开发/调试接口默认不进入 release 路径；
6. 接口只保留一份实现，不在 `.emacs` 与 `ohos-win.el` 之间复制。

## 11. 相关文档

- [整体架构](architecture.md)
- [Emacs OHOS 侧架构](emacs-architecture.md)
- [当前能力边界](capabilities.md)
- [人工测试矩阵](testing/manual-feature-matrix.md)

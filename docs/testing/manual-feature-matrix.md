# Emacs on HarmonyOS 当前功能特性与手动测试用例

> 此文档维护功能特性和手动用例，对程序的问题需要提炼为指定的功能+手动用例到此文件。

## 1. 状态说明

| 标记 | 含义 |
| --- | --- |
| ✅ | 当前产品路径可用，手动用例应通过 |
| ◐ | 有实现，但有明确边界或未完成全量人工验证 |
| ⛔ | 当前架构/构建不支持 |

本表只描述**当前可用能力**，不是目标态清单；未列出的能力默认不承诺。

## 2. 功能特性表

| ID | 能力 | 状态 | 入口 | 备注 |
| --- | --- | --- | --- | --- |
| F-01 | HAP 启动与单 frame | ✅ | 桌面图标 / `aa start` | 启动后删除 bootstrap tty frame |
| F-02 | 原生文本 redisplay | ✅ | 任意 buffer | glyph → CPU bitmap → NativeWindow |
| F-03 | 中文/CJK 显示 | ✅ | 新建 buffer 输入中文 | OH_Drawing mono + CJK 双字体 |
| F-04 | 光标显示/闪烁 | ✅ | 移动光标 / 等待闪烁 | box/hollow/bar/hbar 由 redisplay 选择 |
| F-05 | 硬件键盘输入 | ✅ | 直接键入、`C-x`、`M-x` | key event → Emacs kbd buffer |
| F-06 | 系统输入法/硬件键盘 | ◐ | 系统 IME 或硬件键盘 | 页内键盘组件已删除；系统 IME 由平台处理 |
| F-07 | 鼠标点击/移动/指针形状 | ✅ | 点击文本、链接、mode-line | `mouse-1`、`mouse-face`、pointer style |
| F-08 | 触摸点击/双击选词 | ◐ | 点按、双击词 | 选择已交回 Emacs mouse 事件，待人工确认 |
| F-09 | 触摸拖拽选择 | ◐ | 水平拖拽 | 由 Emacs 处理选区；复制走 kill-ring |
| F-10 | 鼠标滚轮滚动 | ✅ | 教程页滚动 | 仅鼠标/触摸板 AxisEvent；触摸滚动不是产品特性 |
| F-11 | Ctrl+滚轮 text-scale | ◐ | 按住 Ctrl 滚动 | 已传 `ctrl_modifier`；需按 F-11 人工确认 |
| F-12 | `text-scale-*` 命令 | ✅ | `C-x C-+` / `C-x C--` / `C-x C-0` | 字体和 frame grid 同步 |
| F-13 | 多窗口 split / 切换 | ✅ | `C-x 2`、`C-x 3`、`C-x o` | 单 OHOS frame 内多 window |
| F-14 | 文件打开/保存 | ✅ | `C-x C-f`、`C-x C-s` | 受沙箱可访问路径限制 |
| F-15 | 缓冲区切换/撤销/重做 | ✅ | `C-x b`、`C-/`、`C-x u` | 标准 Emacs 行为 |
| F-16 | 增量搜索 | ✅ | `C-s`、`C-r` | 标准 isearch |
| F-17 | 菜单栏/菜单面板 | ✅ | 顶部菜单、`F10` | 外部 ArkUI 菜单栏；F10 只打开第 0 项 |
| F-18 | 普通对话框 / 选择框 | ✅ | 菜单/命令触发 | 通过 host 菜单结果通道 |
| F-19 | 系统剪贴板 | ✅ | `M-w`、`C-y`、粘贴按钮 | Pasteboard + base64 |
| F-20 | PNG/SVG 图片显示 | ✅ | 打开图片、图片 buffer | libpng + nanosvg |
| F-21 | Custom Themes 选择 | ◐ | `M-x customize-themes` |  |
| F-22 | 窗口 resize / fullscreen / maximize | ✅ | 拖拽窗口、窗口按钮 | 双向防 resize 回环 |
| F-23 | 拖放文件打开 | ✅ | 从桌面拖文件到窗口 | 走 `C-x C-f path RET` |
| F-24 | 通知/电池状态 | ✅ | 宿主集成命令 | 依赖系统服务可用性 |
| F-25 | 滚动条 | ⛔ | — | 当前版本明确不支持滚动条；右侧不提供自绘或原生滚动条 |
| F-26 | 多 frame / child frame | ⛔ BLOCKED | 实验：`M-x make-frame` | API 24 无法 raise 父窗口、无系统最小化；不作为产品特性 |
| F-27 | 工具条 / tab bar | ⛔ / ◐ | — | 工具条未启用；tab bar 未作为产品特性 |
| F-28 | 系统 IME 直连 | ✅ | 点击/触摸 XComponent | 统一 `guiShowIme(frame_id)`；无页内键盘按钮 |
| F-29 | 原生滚动条 widget / 无障碍 | ⛔ | — | 不是系统控件，未做 accessibility 映射 |
| F-30 | 多显示器 / DPI 变化 | ⛔ | — | 单 display，固定 96 dpi |
| F-31 | 内部 Eww 链接 | ✅ | `eww-open-file` / 页面链接 | `TAB`+`RET` 已验证打开下一页 |
| F-33 | 滚动后 mode line 完整性 |✅ | 鼠标/触控板滚动 |  |
| F-34 | Eww HTML 解析 | ✅ | `eww-open-file` / `eww` | libxml2 2.12.10；`libxml-parse-html-region` 可用 |
| F-35 | HTTPS（GnuTLS） | ✅ | `eww "https://..."`、`url-retrieve` | GnuTLS 3.8.9；不加载 `tls.el`；只信任 HAP 内 CA bundle |
| F-36 | SQLite | ✅ | `M-:` eval `sqlite-*` | SQLite 3.54.1；`sqlite-load-extension` 不可用（策略关闭） |

## 3. 手动测试用例

### 测试前置

1. 设备已安装并启动当前 HAP：

   ```bash
   ARCH=aarch64 scripts/build-debug-app.sh
   TARGET=192.168.102.58:37103 ARCH=aarch64 scripts/deploy.sh
   ```

2. 直接启动 `EntryAbility`，不需要额外 backend 参数。
3. 每个用例开始前确认应用在前台、窗口未最小化。

### F-01 启动与单 frame

**步骤**

1. 点击桌面方式启动 Emacs。
2. 观察窗口标题和内容区。
3. 执行 `M-x list-frames`（或 `C-x 5 2` 观察行为）。

**预期**

- 正常出现一个 OHOS 原生窗口；
- 不出现 tty frame 或第二个可交互 frame；
- 启动画面和菜单栏可见。

### F-02 文本 redisplay / 光标

**步骤**

1. 打开任意文本文件。
2. 使用方向键移动光标，输入字符。
3. 删除字符、移动窗口、滚动。

**预期**

- 字符显示正确，无大块残留或错位；
- 光标随位置移动，闪烁正常；
- mode-line 保持可见，不被内容覆盖。

### F-03 中文/CJK

**步骤**

1. `C-x b *cjk-test* RET` 新建 buffer。
2. 检查中文、ASCII、混排行。
3. 上下移动光标。

**预期**

- 中文无乱码、无方块；
- 中英文宽度比例正确；
- 光标和行高稳定。

### F-05/F-06 键盘与系统输入法

**步骤**

1. 按 `C-x C-f`，确认 minibuffer 出现。
2. 按 `C-g` 取消。
3. 使用系统输入法或硬件键盘输入中文。

**预期**

- 控制键、Meta 键、取消操作正常；
- 中文整段进入 buffer，不丢字；
- 不再出现页内「⌨ 键盘」组件。

### F-07 鼠标/触摸

**步骤**

1. 点击文本中的不同位置。
2. 将鼠标移动到链接/模式行，观察指针形状。
3. 把鼠标从文本区移到顶部菜单栏，再移回文本区。
4. 打开 Dired，悬停文件名和目录路径。
5. 悬停 mode line 的 buffer name / minor modes 等可点击字段。
6. 双击一个英文单词。

**预期**

- 点击移动 point；
- 链接/mode-line 有 mouse-face，指针形状变化；
- Dired 文件名/目录路径显示 `highlight`，指针为 hand，echo area 显示 help-echo；
- mode line 可点击字段显示 `mode-line-highlight`，指针为 hand，echo area 显示 help-echo；
- 离开 surface 进入菜单栏时指针恢复系统默认，回到文本区恢复 Emacs cursor；
- 双击选中单词（Emacs 自身的 double-click 处理）。

### F-09 触摸拖拽选择

**步骤**

1. 在文本上水平拖动。
2. 松开后执行粘贴。
3. 再纵向拖动一段距离。

**预期**

- 水平拖动由 Emacs 选中区域；
- 复制通过 Emacs 的 kill-ring/系统剪贴板（工具栏“复制”）；
- 不出现 `~5`/`~6` 等字符。

### F-10 鼠标滚轮

**步骤**

1. 打开 `C-h t` 中文教程或一个长文件。
2. 使用鼠标滚轮向下、向上滚动。

**预期**

- 页面滚动，point/窗口位置按预期变化；
- 不插入 `~5`、`~6`、`M-[` 等字符；
- 触摸不是本特性的测试项。

### F-11 Ctrl+滚轮

**步骤**

1. 打开一个可滚动 buffer。
2. 按住 Ctrl，向上/向下滚轮。
3. 观察字号和 frame 行数变化。

**预期**

- 字体变大/变小；
- 不退出应用，不出现文本重叠；
- 松开 Ctrl 后恢复普通滚动。

> 若此用例失败，优先抓 `key evt` 的 ctrl 字段和 `WHEEL_EVENT` 的 `ctrl_modifier`。

### F-12 text-scale 命令

**步骤**

1. 执行 `(text-scale-increase 2)`。
2. 执行 `(text-scale-set 0)`。
3. 执行 `C-x C-+`、`C-x C--`。

**预期**

- 字体和 frame grid 同步变化；
- 恢复 0 后回到原始网格；
- 不崩溃、不重叠。

### F-13 多窗口

**步骤**

1. `C-x 2` 上下分屏。
2. `C-x o` 切换窗口。
3. 在任一窗口移动光标、滚动。

**预期**

- 两个 window 的 mode-line 都完整；
- 光标只影响当前 window；
- 分屏和切换不破坏 frame 边界。

### F-14 文件打开/保存

**步骤**

1. `C-x C-f` 打开沙箱内可写文件。
2. 输入几个字符。
3. `C-x C-s` 保存。
4. 关闭并重新打开。

**预期**

- 文件可读写；
- 保存后内容一致；
- 不出现路径权限错误（沙箱外路径除外）。

### F-15/F-16 缓冲区、撤销、搜索

**步骤**

1. 在 scratch 输入文本，执行 `C-/` 撤销。
2. `C-x b` 切换 buffer。
3. `C-s` 搜索文本，重复 `C-s`。
4. `C-g` 退出搜索。

**预期**

- 撤销/重做正确；
- buffer 切换不丢内容；
- 搜索高亮和跳转正常。

### F-17/F-18 菜单与对话框

**步骤**

1. 点击顶部 `File`、`Edit`、`Options`。
2. 按 `F10` 打开菜单。
3. 打开一个带确认框的命令（例如 `M-x customize-themes`）。
4. 在文本区拖拽选择，拖到菜单栏上方后释放，再晃动鼠标。

**预期**

- 菜单项可点击；
- 子菜单/对话框可关闭；
- 关闭后焦点回到 Emacs frame；
- 拖拽选择结束在菜单栏时不会误打开菜单。

### F-19 剪贴板

**步骤**

1. 在 Emacs 中选中文本，`M-w`。
2. 在系统其他应用粘贴。
3. 从系统其他应用复制文本，在 Emacs `C-y`。
4. 使用底部「粘贴」按钮。

**预期**

- 双向剪贴板可用；
- 中文不损坏；
- 粘贴后焦点回到 frame。

### F-20 图片

**步骤**

1. 打开一张 PNG。
2. 打开一个 SVG。
3. 滚动、切换 buffer。

**预期**

- 图片正常显示；
- 滚动后不残留旧像素；
- 不触发整帧卡死。

### F-21 Custom Themes

**步骤**

1. `M-x customize-themes`。
2. 点击一个主题行/复选框。
3. 观察背景、前景和 mode-line。
4. 再次点击关闭主题。

**预期**

- 点击后主题立即生效；
- 不需要重启；
- 关闭后恢复原主题。

### F-22 窗口 resize / fullscreen

**步骤**

1. 拖动窗口边缘改变大小。
2. 最大化/还原。
3. 进入/退出全屏。

**预期**

- Emacs frame 跟随 surface；
- 文字不压缩、不拉伸、不丢 mode-line；
- 不出现 resize 回环或白屏。

### F-23 拖放文件

**步骤**

1. 从桌面拖动一个文本文件到 Emacs 窗口。
2. 等待加载。

**预期**

- 文件被打开；
- 路径正确；
- 不要求手动输入路径。

### F-24 通知/电池

**步骤**

1. 执行宿主通知命令。
2. 观察系统通知。
3. 查看电池状态返回值。

**预期**

- 通知发送成功；
- 电池信息可读取；
- 系统服务不可用时返回明确错误，不崩溃。

### F-25 滚动条（当前不支持）

**状态：⛔ 不支持**

当前 OHOS 构建使用非工具包滚动条配置，但非 X11 平台没有完整的非工具包滚动条事件实现。现有自绘实现不能可靠完成拖动、上下翻页和多窗口滚动，因此本阶段明确关闭并移除该特性。

**验收**

- 右侧不应出现黑色滚动条；
- 不注册 `ohos-enable-scroll-bars`；
- 不启用 `vertical-scroll-bars`；
- 文本光标、IME 和正文坐标不受滚动条影响。

后续若实现，必须使用 ArkUI 原生 ScrollBar 或完整移植非工具包事件模型，不在当前阶段做临时补丁。

### F-34 Eww 本地 HTML（libxml2）

**步骤**

1. 准备一个本地 HTML 文件（例如 `~/ohos-test.html`）。
2. `M-x eww-open-file RET ~/ohos-test.html RET`。

**预期**

- 标题、段落、链接按 HTML 结构渲染；
- 不出现 `Symbol's function definition is void: libxml-parse-html-region`；
- `M-: (fboundp 'libxml-parse-html-region) RET` 返回 `t`；
- `M-: (system-configuration-features) RET` 包含 `LIBXML2`（同时应含 `GNUTLS`、`SQLITE3`）。

### F-35 HTTPS（GnuTLS）

**步骤**

1. `M-: (eww "https://example.com/") RET`。
2. 打开 `*Messages*` 查看 TLS 提示。
3. `M-: (featurep 'tls) RET`、`M-: (gnutls-available-p) RET`。

**预期**

- 页面正常渲染，链接可继续打开；
- 不出现 `Package tls is deprecated`，不加载 `tls.el`，不调用外部 `gnutls-cli`；
- `(featurep 'tls)` 为 `nil`，`(gnutls-available-p)` 返回包含 `gnutls3` 的列表；
- `gnutls-trustfiles` 指向 HAP 内的 `runtime102/etc/ssl/ca-bundle.crt` 且文件存在；
- url.el 的 HTTPS 校验走 `nsm-verify-connection`：证书不受信任时 NSM 拦截连接，
  不会静默成功；不允许通过设置 `gnutls-verify-error` 为 `nil` 或
  `nsm-noninteractive` 绕过用户确认；
- 设备 DNS 不可用时可临时给测试绑定 `url-proxy-services`
  （`("https" . "<host>:<port>")`）走 CONNECT 隧道，TLS 仍端到端到目标站点。

### F-36 SQLite

**步骤**

```elisp
M-: (sqlite-available-p) RET
M-: (setq db (sqlite-open (expand-file-name "t.db" (getenv "HOME")))) RET
M-: (sqlite-execute db "create table t (x integer)") RET
M-: (sqlite-execute db "insert into t values (42)") RET
M-: (sqlite-select db "select x from t") RET
M-: (sqlite-select db "select sqlite_version()") RET
```

**预期**

- `sqlite-available-p` 为 `t`；
- `sqlite-select` 返回 `((42))`，版本为 `3.54.1`；
- `M-: (fboundp 'sqlite-load-extension) RET` 为 `nil`（`SQLITE_OMIT_LOAD_EXTENSION`）；
- 数据库文件落在沙箱可写目录（`$HOME`），关闭 Emacs 后可重新打开。

### MW-01 ~ MW-14 多窗口用例

> **产品状态：⛔ BLOCKED。** 下表是实验实现的验证结果，不是产品支持承诺。
> 默认 `ohos-multi-window-enabled=nil`，`make-frame` 被 gate；smoke 会 skipped。
> 解除条件见 [capabilities.md](../capabilities.md#4-已知阻塞)。

完整步骤和预期见
[多窗口能力边界](../capabilities.md#21-多窗口--每-frame-renderer-contextblocked)。
执行状态：

| ID | 用例 | 状态 | 证据 |
| --- | --- | --- | --- |
| MW-01 | 创建/关闭第二个窗口 | ✅ 自动 | `subwindow created frame=2` / `subwindow destroyed` |
| MW-02 | 独立渲染 | ✅ 自动 | `present content=736x404` |
| MW-03 | 焦点/键盘路由 | ✅ 自动 | `xcomponent focus frame=2` |
| MW-04 | 每窗口 IME | ✅ 手工 | `IME attach err=0` / `IME show err=0` |
| MW-05 | 独立 resize | ✅ 自动 | `frame-metrics id=2 9xx` |
| MW-06/07 | 关闭按钮 / 取消关闭 | ✅ 自动（关闭路径） | `subwindow destroyed` |
| MW-08 | `delete-frame` | ✅ 自动 | `subwindow destroyed` |
| MW-09 | 关闭主窗口 | ✅ 自动 | 进程退出 |
| MW-10 | 快速 create/delete | ✅ 自动 | 进程存活 |
| MW-11 | 删除后其它窗口继续 | ✅ 自动 | 主 frame 继续 present |
| MW-12 | 每窗口菜单 | ✅ 自动 | `frame menubar click` / `typed menubar frame=2` / `typed menu frame=2` |
| MW-13 | child frame | ✅ 手工 | `subwindow created frame=2 parent=1` |
| MW-14 | 非 2in1 降级 | ✅/◐ | 注入失败验证 `window create failed`；真机待确认 |

自动执行入口：

```bash
TARGET=192.168.102.58:37103 scripts/per-frame-smoke.sh
```

### F-26–F-30 其它不支持/受限项

**步骤**

1. 尝试打开工具条/tab bar。
2. 尝试依赖系统滚动条 widget、无障碍、多显示器/DPI 切换。

**预期**

- 未实现的能力不应崩溃；
- 多 frame 已支持，不再按“单 frame 限制”记录；
- 失败应记录为“不支持/受限”，不要写成回归 bug。


# 鸿蒙真机 Emacs 包兼容性索引（Top 100）

> 用 `emacs-hmos` 在 HarmonyOS NEXT 真机上批量验证 100 个常用包：安装、字节编译、加载，以及已知限制。
> 索引的目标不是给每个包打分，而是回答一个更实际的问题：**在鸿蒙上的 Emacs 里，哪些包能直接拿来用，哪些需要额外条件。**

生成时间：2026-10-28 08:52:33 +0800  
数据：`100` 个包，`100` 个已跑完  
机器可读版本：[`index.json`](../tools/package-index/index.json) · [`index.csv`](../tools/package-index/index.csv)  
复现脚本：[`run-device.sh`](../tools/package-index/run-device.sh) · [`runner.el`](../tools/package-index/runner.el) · [`build-index.py`](../tools/package-index/build-index.py)

## 测试环境

| 项目 | 值 |
| --- | --- |
| 设备 | HM740-061（HarmonyOS NEXT，API 24，Kirin X90，2880×1920） |
| Emacs | `32.0.50`，`aarch64-unknown-linux-ohos` |
| 前端 | 应用内 tty（xterm.js + pty），`window-system=nil`，无 GUI frame |
| 构建能力 | gnutls ✅ · json ✅ · sqlite ❌ · native-comp ❌ · threads ❌ · modules ❌ |
| 外部命令 | git ❌ · rg ❌ · python3 ❌ · node ❌ · sqlite3 ❌ · make ❌ · gcc ❌ · cmake ❌ · pdflatex ❌ · R ❌ · java ❌ |

## 结论速览

- **安装成功**：100/100
- **字节编译无错误**：100/100（其中 52 个有警告，0 个有错误）
- **加载成功**：95/100
- **三项全过**：95/100；部分可用 5；不可用/安装失败 0；未测试 0
- **加载未通过**：`magit`（缺 git 二进制）；`lsp-mode`（构建无线程支持）；`lsp-ui`（构建无线程支持）；`dap-mode`（构建无线程支持）；`vterm`（构建无 module 支持）

> “通过”只表示安装、字节编译、`load` 三步没有致命错误；不表示包的每个命令都在 tty 下可用。带外部依赖的包请看“限制”列。

> 数据说明：`auctex` 的归档包在设备网络上多次超时，最终使用同一版本的官方 tar 本地缓存安装；安装/编译/加载结果仍由真机上的 Emacs 产生。

**开箱即用的代表**：`avy`、`yasnippet`、`use-package`、`which-key`、`hydra`、`evil`、`ace-window`、`smartparens`、`ivy`、`rainbow-delimiters`、`expand-region`、`web-mode`、`goto-chg`、`anzu`

**能加载、但要注意限制的代表**：`helm`、`company`、`markdown-mode`、`projectile`、`treemacs`、`counsel`、`cider`、`git-timemachine`、`haskell-mode`、`rust-mode`、`diff-hl`、`pyvenv`、`forge`、`go-mode`

## 分类索引

### Git 与版本控制

| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| `magit` | A Git porcelain inside Emacs | ⚠️ 部分可用 | ✅ | ⚠️ 2 警告 | ❌ | git / GUI |
| `forge` | Access Git forges from Magit | ✅ 通过 | ✅ | ⚠️ 9 警告 | ✅ | git |
| `git-timemachine` | Walk through git revisions of a file | ✅ 通过 | ✅ | ⚠️ 8 警告 | ✅ | git |
| `git-link` | Get the GitHub/Bitbucket/GitLab URL for a buffer loca… | ✅ 通过 | ✅ | ⚠️ 1 警告 | ✅ | — |
| `diff-hl` | Highlight uncommitted changes using VC | ✅ 通过 | ✅ | ⚠️ 1 警告 | ✅ | git / GUI |

### 补全、搜索与导航

| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| `helm` | Helm is an Emacs incremental and narrowing framework | ✅ 通过 | ✅ | ⚠️ 18 警告 | ✅ | 缺 git / 缺 rg / GUI |
| `company` | Modular text completion framework | ✅ 通过 | ✅ | ✅ | ✅ | 缺 clang / 缺 cmake / GUI |
| `ivy` | Incremental Vertical completYon | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `counsel` | Various completion functions using Ivy | ✅ 通过 | ✅ | ⚠️ 1 警告 | ✅ | 缺 git |
| `swiper` | Isearch with an overview. Oh, man! | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `consult` | Search and navigate via completing-read | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `vertico` | VERTical Interactive COmpletion | ✅ 通过 | ✅ | ✅ | ✅ | 见详情 |
| `marginalia` | Enrich existing commands with completion annotations | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `orderless` | Completion style for matching regexps in any order | ✅ 通过 | ✅ | ✅ | ✅ | 见详情 |
| `corfu` | COmpletion in Region FUnction | ✅ 通过 | ✅ | ⚠️ 1 警告 | ✅ | GUI |
| `cape` | Completion At Point Extensions | ✅ 通过 | ✅ | ✅ | ✅ | 见详情 |
| `embark` | Conveniently act on minibuffer completions | ✅ 通过 | ✅ | ✅ | ✅ | 见详情 |
| `helm-projectile` | Helm integration for Projectile | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `helm-descbinds` | A convenient `describe-bindings' with `helm' | ✅ 通过 | ✅ | ✅ | ✅ | — |

### 项目与文件管理

| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| `projectile` | Manage and navigate projects in Emacs easily | ✅ 通过 | ✅ | ✅ | ✅ | 缺 git / 缺 rg |
| `treemacs` | A tree style file explorer package | ✅ 通过 | ✅ | ⚠️ 36 警告 | ✅ | 缺 git / 缺 python3 / GUI |
| `treemacs-projectile` | Projectile integration for treemacs | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `treemacs-icons-dired` | Treemacs icons for dired | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `imenu-list` | Show imenu entries in a separate buffer | ✅ 通过 | ✅ | ⚠️ 7 警告 | ✅ | — |

### LSP 与调试

| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| `lsp-mode` | LSP mode | ⚠️ 部分可用 | ✅ | ⚠️ 194 警告 | ❌ | language server / 缺 cargo / 缺 go / 缺 java … |
| `lsp-ui` | UI modules for lsp-mode | ⚠️ 部分可用 | ✅ | ⚠️ 6 警告 | ❌ | language server / GUI |
| `dap-mode` | Debug Adapter Protocol mode | ⚠️ 部分可用 | ✅ | ⚠️ 37 警告 | ❌ | debug adapter / GUI |
| `eglot` | The Emacs Client for LSP servers | ✅ 通过 | ✅ | 内置 | ✅ | language server |

### 编辑增强

| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| `avy` | Jump to arbitrary positions in visible text and selec… | ✅ 通过 | ✅ | ⚠️ 4 警告 | ✅ | GUI |
| `expand-region` | Increase selected region by semantic units. | ✅ 通过 | ✅ | ⚠️ 9 警告 | ✅ | — |
| `multiple-cursors` | Multiple cursors for Emacs | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `iedit` | Edit multiple regions in the same way simultaneously | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `smartparens` | Automatic insertion, wrapping and paredit-like naviga… | ✅ 通过 | ✅ | ⚠️ 42 警告 | ✅ | — |
| `paredit` | Minor mode for editing parentheses | ✅ 通过 | ✅ | ⚠️ 47 警告 | ✅ | — |
| `aggressive-indent` | Minor mode to aggressively keep your code always inde… | ✅ 通过 | ✅ | ⚠️ 4 警告 | ✅ | — |
| `ws-butler` | Unobtrusively remove trailing whitespace | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `rainbow-delimiters` | Highlight brackets according to their depth | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `goto-chg` | Go to last change | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `anzu` | Show number of matches in mode-line while searching | ✅ 通过 | ✅ | ⚠️ 1 警告 | ✅ | — |
| `hl-todo` | Highlight TODO and similar keywords | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `symbol-overlay` | Highlight symbols with keymap-enabled overlays | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `ace-window` | Quickly switch windows. | ✅ 通过 | ✅ | ⚠️ 17 警告 | ✅ | — |

### 语言模式与 IDE

| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| `markdown-mode` | Major mode for Markdown-formatted text | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `web-mode` | Major mode for editing web templates | ✅ 通过 | ✅ | ⚠️ 14 警告 | ✅ | GUI |
| `yaml-mode` | Major mode for editing YAML files | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `js2-mode` | Improved JavaScript editing mode | ✅ 通过 | ✅ | ⚠️ 22 警告 | ✅ | — |
| `json-mode` | Major mode for editing JSON files | ✅ 通过 | ✅ | ⚠️ 5 警告 | ✅ | — |
| `rust-mode` | A major-mode for editing Rust source code | ✅ 通过 | ✅ | ⚠️ 3 警告 | ✅ | rustfmt / cargo |
| `go-mode` | Major mode for the Go programming language | ✅ 通过 | ✅ | ⚠️ 16 警告 | ✅ | gofmt / gopls |
| `php-mode` | Major mode for editing PHP code | ✅ 通过 | ✅ | ✅ | ✅ | php |
| `typescript-mode` | Major mode for editing typescript | ✅ 通过 | ✅ | ⚠️ 30 警告 | ✅ | node / npm / tsc |
| `clojure-mode` | Major mode for Clojure code | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `cider` | Clojure Interactive Development Environment that Rocks | ✅ 通过 | ✅ | ⚠️ 6 警告 | ✅ | clojure / JVM / 缺 node / GUI |
| `haskell-mode` | A Haskell editing mode | ✅ 通过 | ✅ | ⚠️ 9 警告 | ✅ | ghc / cabal / GUI |
| `ess` | Emacs Speaks Statistics | ✅ 通过 | ✅ | ⚠️ 134 警告 | ✅ | R / GUI |
| `elpy` | Emacs Python Development Environment | ✅ 通过 | ✅ | ⚠️ 149 警告 | ✅ | python3 / jedi / flake8 |
| `pyvenv` | Python virtual environment interface | ✅ 通过 | ✅ | ⚠️ 7 警告 | ✅ | python3 |
| `lua-mode` | A major-mode for editing Lua scripts | ✅ 通过 | ✅ | 内置 | ✅ | lua |
| `dockerfile-mode` | Major mode for editing Docker's Dockerfiles | ✅ 通过 | ✅ | ✅ | ✅ | docker |
| `cmake-mode` | Major-mode for editing CMake sources | ✅ 通过 | ✅ | ✅ | ✅ | cmake |
| `auctex` | Integrated environment for *TeX* | ✅ 通过 | ✅ | ⚠️ 5 警告 | ✅ | TeX distribution / GUI |

### Org、文档与阅读

| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| `toc-org` | Add table of contents to org-mode files (formerly, or… | ✅ 通过 | ✅ | ⚠️ 1 警告 | ✅ | — |
| `org-download` | Image drag-and-drop for Org-mode | ✅ 通过 | ✅ | ⚠️ 4 警告 | ✅ | 见详情 |
| `org-pomodoro` | Pomodoro implementation for org-mode | ✅ 通过 | ✅ | ⚠️ 9 警告 | ✅ | 见详情 |
| `org-superstar` | Prettify headings and plain lists in Org mode | ✅ 通过 | ✅ | ⚠️ 3 警告 | ✅ | GUI |
| `org-roam` | A database abstraction layer for Org-mode | ✅ 通过 | ✅ | ⚠️ 4 警告 | ✅ | sqlite / 缺 rg |
| `pdf-tools` | Support library for PDF documents | ✅ 通过 | ✅ | ⚠️ 6 警告 | ✅ | C compiler / make / libpng / zlib … |
| `nov` | Featureful EPUB reader mode | ✅ 通过 | ✅ | ⚠️ 3 警告 | ✅ | zip / unzip / GUI |
| `htmlize` | Convert buffer text and decorations to HTML | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `writeroom-mode` | Minor mode for distraction-free writing | ✅ 通过 | ✅ | ✅ | ✅ | 见详情 |
| `olivetti` | Minor mode to automatically balance window margins | ✅ 通过 | ✅ | ⚠️ 2 警告 | ✅ | GUI |
| `devdocs` | Emacs viewer for DevDocs | ✅ 通过 | ✅ | ⚠️ 1 警告 | ✅ | — |

### 终端

| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| `vterm` | Fully-featured terminal emulator | ⚠️ 部分可用 | ✅ | ⚠️ 4 警告 | ❌ | module support / cmake / C compiler |

### 工作流、外观与杂项

| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| `which-key` | Display available keybindings in popup | ✅ 通过 | ✅ | 内置 | ✅ | 见详情 |
| `hydra` | Make bindings that stick around. | ✅ 通过 | ✅ | ⚠️ 29 警告 | ✅ | 见详情 |
| `use-package` | A configuration macro for simplifying your .emacs | ✅ 通过 | ✅ | 内置 | ✅ | 见详情 |
| `evil` | Extensible vi layer | ✅ 通过 | ✅ | ⚠️ 1 警告 | ✅ | GUI |
| `evil-collection` | A set of keybindings for Evil mode | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `exec-path-from-shell` | Get environment variables such as $PATH from the shell | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `editorconfig` | EditorConfig Emacs Plugin | ✅ 通过 | ✅ | 内置 | ✅ | — |
| `yasnippet` | Yet another snippet extension for Emacs | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `yasnippet-snippets` | Collection of yasnippet snippets | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `package-lint` | A linting library for elisp package authors | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `dumb-jump` | Jump to definition for 60+ languages without configur… | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `doom-modeline` | A minimal and modern mode-line | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `doom-themes` | An opinionated pack of modern color-themes | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `zenburn-theme` | A low contrast color theme | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `solarized-theme` | The Solarized color theme | ✅ 通过 | ✅ | ⚠️ 19 警告 | ✅ | GUI |
| `modus-themes` | Elegant, highly legible and customizable themes | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `ef-themes` | Colorful and legible themes | ✅ 通过 | ✅ | ⚠️ 2 警告 | ✅ | 见详情 |
| `all-the-icons` | A library for inserting Developer icons | ✅ 通过 | ✅ | ✅ | ✅ | 见详情 |
| `page-break-lines` | Display ^L page breaks as tidy horizontal lines | ✅ 通过 | ✅ | ✅ | ✅ | — |
| `dashboard` | A startup screen extracted from Spacemacs | ✅ 通过 | ✅ | ✅ | ✅ | GUI |
| `elfeed` | An Atom/RSS feed reader | ✅ 通过 | ✅ | ⚠️ 2 警告 | ✅ | 见详情 |
| `elfeed-org` | Configure elfeed with one or more org-mode files | ✅ 通过 | ✅ | ⚠️ 7 警告 | ✅ | 见详情 |
| `gptel` | Interact with ChatGPT or other LLMs | ✅ 通过 | ✅ | ⚠️ 5 警告 | ✅ | API key / network / 缺 git / GUI |
| `helpful` | A better *help* buffer | ✅ 通过 | ✅ | ⚠️ 9 警告 | ✅ | — |
| `restclient` | An interactive HTTP client for Emacs | ✅ 通过 | ✅ | ✅ | ✅ | 见详情 |
| `paradox` | A modern Packages Menu. Colored, with package ratings… | ✅ 通过 | ✅ | ⚠️ 28 警告 | ✅ | — |
| `undo-tree` | Treat undo history as a tree | ✅ 通过 | ✅ | ⚠️ 12 警告 | ✅ | — |

### 限制详情

下表是自动检测与人工说明合并后的完整限制；没有列出的包没有检测到外部命令/GUI/构建期能力依赖。

- **`magit`**：通过 git CLI 操作仓库；设备未安装 git 时无法提交、拉取或推送。 源码引用外部命令 git、git-absorb、git-autofixup、git-when-merged、gitk；设备上未找到 git。 引用 GUI 能力（display-graphic-p、window-system）；当前为 tty，相关交互不可用。
- **`forge`**：需要 git、forge API token 与网络。
- **`git-timemachine`**：需要 git 仓库与 git CLI。
- **`diff-hl`**：需要 git/VC 后端；tty 下 fringe 不可见，标记效果受限。 引用 GUI 能力（display-graphic-p、window-system）；当前为 tty，相关交互不可用。
- **`helm`**：tty 下可用；GUI 工具提示/图标不可用。 源码引用外部命令 ag、fd、fdfind、git、pdfgrep、rg、rsync、tldr、updatedb、w3m；设备上未找到 git、rg。 引用 GUI 能力（display-graphic-p、image-type-available-p）；当前为 tty，相关交互不可用。
- **`company`**：tty 下可用；GUI 文档弹窗不可用。 源码引用外部命令 clang、cmake、global；设备上未找到 clang、cmake。 引用 GUI 能力（display-graphic-p、image-type-available-p、window-system）；当前为 tty，相关交互不可用。
- **`ivy`**：引用 GUI 能力（display-graphic-p）；当前为 tty，相关交互不可用。
- **`counsel`**：源码引用外部命令 ack-grep、es.exe、git；设备上未找到 git。 源码涉及 json-parse、libxml。
- **`swiper`**：引用 GUI 能力（display-graphic-p）；当前为 tty，相关交互不可用。
- **`consult`**：tty 下可用；部分预览命令依赖外部工具。 源码引用外部命令 fdfind。 引用 GUI 能力（xwidget）；当前为 tty，相关交互不可用。
- **`vertico`**：tty 下可用。
- **`marginalia`**：tty 下可用。 引用 GUI 能力（xwidget）；当前为 tty，相关交互不可用。
- **`orderless`**：tty 下可用。
- **`corfu`**：tty 下可用；child-frame 弹窗不可用时会回退到 minibuffer。 引用 GUI 能力（child-frame、display-graphic-p、tool-bar-mode）；当前为 tty，相关交互不可用。
- **`cape`**：依赖 completion-at-point；tty 下可用。
- **`embark`**：tty 下可用。
- **`helm-projectile`**：源码引用外部命令 ack、ack-grep。
- **`projectile`**：源码引用外部命令 ack、ag、fd、fdfind、git、jj、rg、sh；设备上未找到 git、rg。 源码涉及 json-parse。
- **`treemacs`**：文件树可用；图标需要 all-the-icons 与字体。 源码引用外部命令 git、python3；设备上未找到 git、python3。 引用 GUI 能力（child-frame、image-type-available-p、window-system）；当前为 tty，相关交互不可用。
- **`treemacs-icons-dired`**：需要 all-the-icons 与图标字体。 引用 GUI 能力（display-graphic-p）；当前为 tty，相关交互不可用。
- **`lsp-mode`**：需要外部语言服务器；本构建缺少 make-mutex/线程支持，lsp-mode 加载时会直接报错。 依赖：language server。 源码引用外部命令 asm-lsp、autotools-language-server、cargo、clojure-lsp、composer、csharp-ls、curl、earthlyls、fennel-ls、fsa…
- **`lsp-ui`**：依赖 lsp-mode 与外部语言服务器；lsp-mode 在当前无 make-mutex 的构建上无法加载。 依赖：language server。 引用 GUI 能力（child-frame、display-graphic-p、image-type-available-p、xwidget）；当前为 tty，相关交互不可用。
- **`dap-mode`**：需要外部 debug adapter；若运行路径使用 make-mutex，在当前无线程构建上会失败。 源码引用外部命令 dlv、lldb-dap、lldb-vscode、netcoredbg、powershell、ps、pyenv、unzip。 引用 GUI 能力（window-system）；当前为 tty，相关交互不可用。 源码涉及 json-par…
- **`eglot`**：Emacs 内置 LSP 客户端；需要外部语言服务器。 依赖：language server。
- **`avy`**：引用 GUI 能力（display-graphic-p）；当前为 tty，相关交互不可用。
- **`markdown-mode`**：引用 GUI 能力（image-type-available-p、window-system）；当前为 tty，相关交互不可用。
- **`web-mode`**：源码引用外部命令 jshint。 引用 GUI 能力（display-graphic-p、menu-bar-mode、tool-bar-mode、window-system）；当前为 tty，相关交互不可用。 源码涉及 libxml。
- **`rust-mode`**：编辑可用；格式化/编译需要 Rust 工具链。 依赖：rustfmt、cargo。
- **`go-mode`**：编辑可用；格式化/补全需要 Go 工具链。 依赖：gofmt、gopls。
- **`php-mode`**：编辑可用；运行/补全需要 PHP。 源码引用外部命令 php、php-parse；设备上未找到 php。 源码涉及 libxml。
- **`typescript-mode`**：编辑可用；补全/编译需要 Node/TypeScript。 依赖：npm、tsc。
- **`cider`**：需要 Clojure/Leiningen 与 JVM。 源码引用外部命令 clojure、lsof、node、ssh、taskkill；设备上未找到 node。 引用 GUI 能力（window-system）；当前为 tty，相关交互不可用。 源码涉及 libxml。
- **`haskell-mode`**：编辑可用；REPL/补全需要 GHC。 依赖：cabal。 源码引用外部命令 cabal、ghc、hoogle、stack。 引用 GUI 能力（image-type-available-p）；当前为 tty，相关交互不可用。
- **`ess`**：需要 R 解释器；设备未安装。 源码引用外部命令 Rterm、dd、evince、ghostview、gv、julia-basic、recode、xpdf。 引用 GUI 能力（display-graphic-p、window-system）；当前为 tty，相关交互不可用。
- **`elpy`**：需要 Python 工具链；设备未安装 python3。 依赖：jedi、flake8。 源码引用外部命令 easy_install、py、python、pythonw、uv、virtualenv。
- **`pyvenv`**：需要 python3 管理虚拟环境。 源码引用外部命令 bash、py、python、python3、pythonw、sh、virtualenv；设备上未找到 python3。
- **`lua-mode`**：编辑可用；运行需要 Lua。
- **`dockerfile-mode`**：编辑可用；构建需要 docker。
- **`cmake-mode`**：编辑可用；配置/构建需要 cmake。
- **`auctex`**：编辑 .tex 可用；编译/预览需要 latex、dvips 等 TeX 工具。GNU ELPA tar 较大，设备网络下载曾超时，本次用官方 tar 本地缓存安装。 依赖：TeX distribution。 源码引用外部命令 GSWIN32C.EXE、chktex、gs、mgs、pbibtex、pxdvi、rungs、texdoc、upmendex。 引…
- **`org-download`**：下载图片需要网络；tty 下不能预览图片。 源码引用外部命令 magick、pngpaste、wl-paste、xclip。
- **`org-pomodoro`**：通知可能依赖 alert/系统通知；tty 下可能只在 echo area 提示。 源码引用外部命令 afplay、aplay。
- **`org-superstar`**：引用 GUI 能力（display-graphic-p）；当前为 tty，相关交互不可用。
- **`org-roam`**：需要 sqlite 支持；本构建 sqlite=false，可能只能使用基础文件功能。 源码引用外部命令 firefox、rg；设备上未找到 rg。 需要构建期能力 sqlite，当前构建未启用。
- **`pdf-tools`**：Elisp 部分可加载；实际打开 PDF 需要编译 epdfinfo 服务端，设备没有构建工具时只能安装不能渲染。 依赖：C compiler、make、libpng、zlib。 源码引用外部命令 convert、sh。 引用 GUI 能力（image-type-available-p、x-create-frame）；当前为 tty，相关交互不可用。
- **`nov`**：EPUB 解析通常需要 zip/unzip；设备未预装。 源码引用外部命令 unzip。 引用 GUI 能力（display-graphic-p、image-type-available-p）；当前为 tty，相关交互不可用。 源码涉及 libxml。
- **`writeroom-mode`**：窗口布局类功能；tty 下部分生效。
- **`olivetti`**：窗口边距类功能；tty 下效果有限。 引用 GUI 能力（window-system）；当前为 tty，相关交互不可用。
- **`devdocs`**：源码涉及 json-parse、libxml。
- **`vterm`**：Emacs 未启用 --with-modules，vterm 加载时直接报 “VTerm needs module support”；有编译器也无法加载模块。 依赖：cmake、C compiler。 源码引用外部命令 cmake；设备上未找到 cmake。
- **`which-key`**：tty 下可用；弹出方式受终端限制。
- **`hydra`**：tty 下可用；着色/提示受终端限制。
- **`use-package`**：纯 Elisp 配置宏；Emacs 30+ 内置，ELPA 版本可独立升级。
- **`evil`**：纯 Elisp，tty 下可用。 引用 GUI 能力（gui-get-selection）；当前为 tty，相关交互不可用。
- **`evil-collection`**：纯 Elisp 键位集合，tty 下可用。 引用 GUI 能力（xwidget）；当前为 tty，相关交互不可用。
- **`exec-path-from-shell`**：源码引用外部命令 printf。 引用 GUI 能力（window-system）；当前为 tty，相关交互不可用。
- **`yasnippet`**：引用 GUI 能力（window-system）；当前为 tty，相关交互不可用。
- **`doom-modeline`**：tty 下可用，但图标/字体与 GUI 效果不同。 源码引用外部命令 direnv、pipenv、pyenv。 引用 GUI 能力（display-graphic-p、image-type-available-p、xwidget）；当前为 tty，相关交互不可用。
- **`doom-themes`**：主题可在 tty 下加载；颜色受终端 256 色限制。 引用 GUI 能力（display-graphic-p）；当前为 tty，相关交互不可用。
- **`zenburn-theme`**：tty 下可用；颜色受终端限制。 引用 GUI 能力（tool-bar-mode）；当前为 tty，相关交互不可用。
- **`solarized-theme`**：tty 下可用；颜色受终端限制。 引用 GUI 能力（tool-bar-mode）；当前为 tty，相关交互不可用。
- **`modus-themes`**：Emacs 内置主题的 ELPA 版本；tty 下可用。 引用 GUI 能力（child-frame、tool-bar-mode）；当前为 tty，相关交互不可用。
- **`ef-themes`**：主题可在 tty 下加载；颜色受终端限制。 源码涉及 native-compile。
- **`all-the-icons`**：需要 Nerd Font/图标字体；tty 下通常显示为占位符。
- **`dashboard`**：文本模式可用；图标/图片在 tty 下不可用。 引用 GUI 能力（display-graphic-p、image-type-available-p）；当前为 tty，相关交互不可用。
- **`elfeed`**：需要网络；RSS 抓取使用 url.el，不依赖 curl。 源码引用外部命令 gzip。 源码涉及 json-parse、libxml。
- **`elfeed-org`**：依赖 elfeed；需要网络。
- **`gptel`**：核心功能需要 LLM API key 与网络；部分扩展命令会调用 aws/curl/git，属可选路径。 依赖：network。 源码引用外部命令 aws、curl、git；设备上未找到 git。 引用 GUI 能力（display-graphic-p）；当前为 tty，相关交互不可用。 源码涉及 json-parse。
- **`helpful`**：源码涉及 native-compile。
- **`restclient`**：需要网络；HTTP 请求由 url.el 发出。

## 已知限制怎么读

- **外部命令**：包的源码里出现 `executable-find` 等调用；设备上没有对应二进制时，相关命令会失败或降级。
- **GUI 能力**：包引用了 `display-graphic-p`、`gui-get-selection`、child-frame 等；当前是 tty，相关交互不可用或回退。
- **构建期能力**：如 sqlite、libxml、native-comp；这一版 Emacs 构建没有启用时，依赖它们的包只能部分工作。
- **`load` 成功 ≠ 功能完整**：很多包在 tty 下能加载，但菜单、图标、图片、PDF 渲染、语言服务器等仍需要额外条件。

## 选择方法

1. 以 MELPA 官方 `download_counts.json`（2026-10-27 快照）为热度基线。
2. 从下载量排名出发，剔除纯依赖库（如 `dash`、`s`、`f`、`popup`）、已内置/已废弃的包，保留用户会直接调用的 100 个包。
3. 对 GNU ELPA 独有且常用的包（如 `auctex`、`ef-themes`）按同类热度补入。
4. 每个包单独启动一个 `emacs --batch -Q -l runner.el` 进程，避免包之间的全局状态污染；单包超时 300 秒。

> 下载量不是用户数：CI、包管理器和依赖安装都会放大计数，所以这里只把它当作“热度代理指标”，不宣称严格排名。

## 复现

```bash
# 1) 在已安装 emacs-hmos 的真机上跑 100 个包
TARGET=192.168.102.170:39681 tools/package-index/run-device.sh

# 2) 把设备结果拉回并生成索引
python3 tools/package-index/build-index.py
```

测试脚本只把结果写到应用沙箱的 `runtime/package-index/`，不会修改 Emacs 运行时或用户配置。

## 结果文件

- [`index.json`](../tools/package-index/index.json)：合并后的机器可读索引（含每个包的安装/编译/加载结果和限制）。
- [`index.csv`](../tools/package-index/index.csv)：表格软件可直接打开的扁平版本。
- [`results/`](../tools/package-index/results/)：每个包一份原始 JSON 与日志，便于复查。

# 鸿蒙真机 Emacs 包兼容性索引

这个目录生成 [`docs/PACKAGE-INDEX.md`](../../docs/PACKAGE-INDEX.md)：在 HarmonyOS NEXT 真机上用 `emacs-hmos` 批量验证 100 个常用包的安装、字节编译、加载和已知限制。

## 文件

| 文件 | 说明 |
| --- | --- |
| `packages.json` | 选定的 100 个包，含分类、MELPA 下载量、版本与依赖。 |
| `runner.el` | 单包探针：安装 → 字节编译顶层 `.el` → `load` 主文件 → 汇总限制。 |
| `run-device.sh` | 把队列和探针送进应用沙箱，重启 app，轮询并回收结果。 |
| `build-index.py` | 合并 `results/*.json` 与人工限制说明，生成 Markdown/JSON/CSV。 |
| `limitations.json` | 人工整理的“需要外部二进制 / GUI / 构建能力”说明，会与自动检测结果合并。 |
| `results/` | 设备上每个包一份原始 JSON 与日志（由脚本回收）。 |
| `index.json` / `index.csv` | 机器可读索引。 |
| `INDEX.md` | 面向人的索引（同时复制到 `docs/PACKAGE-INDEX.md`）。 |

## 选择方法

1. 以 MELPA 官方 [`download_counts.json`](https://melpa.org/download_counts.json)（2026-10-27 快照）作为热度基线。
2. 从下载量排名出发，剔除纯依赖库（`dash`、`s`、`f`、`popup` 等）、已内置/已废弃的包，保留用户会直接调用的 100 个包。
3. GNU ELPA 独有且常用的包（`auctex`、`ef-themes`）按同类热度补入。
4. 每个包单独启动一个 `emacs --batch -Q -l runner.el PKG DIR RESULT` 进程，避免包之间的全局状态污染；单包超时 300 秒。

下载量不是用户数：CI、包管理器和依赖安装都会放大计数，所以它只是“热度代理指标”，不是严格排名。

## 复现

前提：已安装并启动过 `emacs-hmos`，`hdc list targets -v` 能看到真机，宿主机有 `python3` 和签名工具链（脚本默认使用仓库里的 `scripts/deploy.sh` 同一套路径）。

```bash
# 跑完整队列；默认 target 是 192.168.102.170:39681
TARGET=192.168.102.170:39681 tools/package-index/run-device.sh

# 结果会实时回收到 tools/package-index/results/
python3 tools/package-index/build-index.py
```

`run-device.sh` 做三件事：

1. 用 `hdc file send -b emacs.hmos.org` 把 `runner.el` 和 `queue.txt` 送进应用沙箱的 `runtime/package-index/`；目录不存在时 HDC 会创建。
2. `aa force-stop` / `aa start` 重启 app。`Index.ets` 检测到 `queue.txt` 后进入探针模式：每个包启动一个 batch Emacs 进程，读取退出状态，超时则 `stopEmacs` 并继续下一个。
3. 轮询 `status.txt`，按文件逐个 `hdc file recv` 回收 `results/*.json` 与 `*.log`；看到 `done` 后退出。

不想跑设备时，也可以直接修改 `packages.json`，用 `runner.el` 在任意 Emacs 30+ 上验证：

```bash
emacs --batch -Q -l tools/package-index/runner.el magit /tmp/bench /tmp/bench/magit.json
```

### 超大包 / 网络超时

`runner.el` 会优先使用 `runtime/package-index/local-packages/<name>-*.tar`：
如果某个官方 tar 在设备网络上反复超时，可以先用宿主机下载同一个 tar，再把目录送进去，
runner 会走 `package-install-file`，结果仍由真机 Emacs 产生。索引里的 `auctex` 就是这样装上的
（GNU ELPA 的 6.5 MB tar，设备直连下载会超过 300 秒超时）。

## 结果语义

- `install`：`package-install` 是否成功；`already_installed` 表示队列重跑时复用了共享的 `elpa/`。
- `byte_compile`：对包目录顶层 `.el` 逐个 `byte-compile-file`；`warnings` 是警告数，`errors` 是真正的编译错误。`status=warnings` 仍算编译成功。
- `load`：`load` 主库文件；`feature` 表示包名本身是否被 `provide`。`load` 成功只代表可以加载，不代表所有交互命令在 tty 下都可用。
- `limitations`：自动扫描源码中的 `executable-find`、GUI 符号、sqlite/libxml 等提示，再合并 `limitations.json` 的人工说明。
- `verdict`：`ok`（安装/编译/加载都过）、`partial`（能安装，但编译或加载失败）、`blocked`（安装失败或 fatal）、`missing`（未跑完/超时）。

## 已知边界

- 测试环境是 **tty**：`window-system=nil`、`display-graphic-p=nil`。GUI 专用包/功能只能记录“加载是否成功”，不能证明菜单、图标、child-frame、图片、PDF 渲染可用。
- 设备上没有 `git`、`rg`、`python3`、`node`、`cmake`、编译器、TeX、R 等常用外部工具；依赖它们的包会加载失败或功能降级，这是索引重点记录的内容。
- 这一版 Emacs 构建 `sqlite=false`、`native-comp=false`；依赖这些能力的包需要额外构建。
- 单包 180 秒超时；网络慢或包很大时可能被记为 `missing`，可以在网络更好时单独重跑。
- 探针会写 `runtime/package-index/`，不修改 Emacs runtime 或用户 `.emacs`。

## 恢复普通模式

探针模式只由非空的 `runtime/package-index/queue.txt` 触发。控制器跑完队列后会自己把 `queue.txt` 清空，所以重新启动 app 就回到普通终端；也可以手动发送一个空文件过去覆盖队列。

# 构建、部署与运维 runbook

本页是“在一台设备上把当前分支跑起来”的操作手册。架构背景见
[`architecture.md`](architecture.md)；renderer / ABI 细节见
[`emacs-architecture.md`](emacs-architecture.md)。

## 1. 前置条件

| 项 | 要求 |
| --- | --- |
| 主机 | Linux x86_64；见下方 host 工具 |
| 命令行工具 | `commandline-tools-linux-x64-*`（`CT` 或自动发现） |
| 设备 | HarmonyOS NEXT 真机；已开启开发者模式/HDC |
| 签名 | keystore、证书、profile；通过环境变量提供，不入库 |
| Java | 17（打包/签名） |

Host 工具链（构建依赖和 host `bootstrap-emacs` 都靠它，缺失时
`scripts/preflight.sh` 会直接报错）：

```text
cc + libc 头、make、autoconf、m4、pkg-config、makeinfo(texinfo)、
python3、tar、gzip、xz、unzip、patch、sha256sum、git、libtinfo 头
```

不再需要 `HOST_SYSROOT`、`OHOS_DEPS`、`RUNTIME_STAGE`。所有构建输出都在
仓库的 `build/` 下（见 §2.1），依赖归档固定在 `third_party/src`。

统一环境入口：

```bash
cp .env.example .env.local
$EDITOR .env.local
```

`.env.local` 被 `.gitignore` 忽略，常用值：

```bash
CT=/path/to/commandline-tools-linux-.../command-line-tools
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
TARGET=<hdc-target>
# BUILD_ROOT=$PWD/build          # 可选，默认就是仓库下的 build/
```

先运行：

```bash
scripts/preflight.sh --build-only
```

签名（按实际材料填写，只有构建安装包时使用；`deploy.sh` 不需要）：

```bash
# debug（scripts/build-debug-app.sh）：路径默认指向 refs/debug/
export DEBUG_KEYSTORE=/path/to/demo.p12
export DEBUG_KEYSTORE_PWD=...
export DEBUG_KEY_ALIAS=demo_key
export DEBUG_KEY_PWD=...
export DEBUG_APP_CERT=$PWD/refs/debug/cert1.cer
export DEBUG_PROFILE=$PWD/refs/debug/emacs-hmos3Debug.p7b

# release（scripts/build-release-app.sh）：默认使用 refs/release/，
# 口令从 refs/release/CREDENTIALS.txt 读取，可用 RELEASE_* 覆盖
```

### 1.1 签名材料（debug / release 对齐）

两条构建路径共用 `scripts/lib/signing.sh`，同一套解析、校验和签后验证：

```text
解析顺序   <MODE>_* 环境变量 → refs/<mode>/CREDENTIALS.txt → 仓库默认路径 → 报错
配置文件   refs/debug/CREDENTIALS.txt、refs/release/CREDENTIALS.txt
           字段 store_password= / key_password=，权限必须 0600
profile    校验 bundle-name、debug/release 类型、ACL 全集（READ_PASTEBOARD
           等四项，见 app/entry/src/main/module.json5）；debug 必须绑定 device-ids
签名后     verify-app 校验；产物旁边写 <hap>.json 元数据
```

旧的裸 `KEYSTORE / KEYSTORE_PWD / KEY_ALIAS / KEY_PWD / APP_CERT / PROFILE`
不再读取，`.env.local` 需改成 `DEBUG_*`（release 用 `RELEASE_*`）。

## 2. 构建

### 2.1 构建入口与输出布局

```bash
ARCH=aarch64 scripts/clean-build.sh
```

`clean-build.sh` 是唯一受支持的**完整构建**入口；`scripts/build-*.sh` 是它
调用的内部步骤（单独运行只用于调试）。安装包由 `build-debug-app.sh` /
`build-release-app.sh` 基于这些产物打包（见 §2.2）。所有构建输出都在一个
可删的根目录下：

```text
build/
  deps/<abi>/        目标依赖前缀（GnuTLS 链 + libpng + libxml2 + SQLite）
  host/              x86_64 bootstrap-emacs / pdmp / make-docfile
  target/<arch>/     Emacs 配置/编译树（config.h、src/temacs、*.o）
  runtime/<arch>/    组装好的 lisp/leim/etc，用于打 runtime 包
  cache/             可选：pack-runtime 的 hard-link 视图
```

打包输入仍在 app 内（hvigor 约定）：

```text
app/entry/libs/<abi>/                         libemacs_gui.so、libohos_render.a
app/entry/src/main/resources/rawfile/*.tar.gz runtime
app/entry/build/、.cxx/、.hvigor/、oh_modules/ hvigor/CMake 自有
```

内部步骤与顺序：

```text
preflight --build-only
  → build-host-tools.sh          build/host
  → build-ohos-deps.sh           build/deps/<abi>（gmp → nettle → tasn1
                                 → unistring → ncurses → gnutls）
  → build-ohos-imaging.sh        libpng
  → build-ohos-libxml2.sh        libxml2
  → build-ohos-sqlite3.sh        SQLite
  → preflight --deps
  → build-ohos-render.sh         app/entry/libs/<abi>/libohos_render.a
  → build-emacs-ohos.sh          build/target/<arch>（temacs + .elc）
  → build-libemacs-gui.sh        app/entry/libs/<abi>/libemacs_gui.so
  → build-runtime-stage.sh       build/runtime/<arch>
  → pack-runtime.sh
  → write-build-manifest.sh      build/target/<arch>/build-manifest.json
```

所有依赖都来自 `third_party/src` 中已跟踪的归档，sha256 记录在
[`third_party/versions.json`](../third_party/versions.json)；构建过程不联网。

`clean-build.sh` 只产出 Emacs 和 runtime；安装包由两个独立入口基于这些
产物打包（不安装、不碰设备）：

```bash
# debug HAP（构建 + 签名）
ARCH=aarch64 scripts/build-debug-app.sh
# AppGallery 发布包（release 证书 + release ACL profile）
ARCH=aarch64 scripts/build-release-app.sh
```

两者共用 `scripts/lib/app-package.sh`：按 ARCH 临时改写 `abiFilters`
（退出时还原 `build-profile.json5`）、按需重建 runtime（源码比 tarball 新
或 `--force-runtime`）、清 hvigor 中间产物、跑 `assembleHap`。产物：

```text
dist/Homacs-<versionName>-debug-<abi>.hap       debug 安装包
dist/Homacs-<versionName>-debug-<abi>.json      构建元数据，deploy 用来判陈旧
dist/Homacs-<versionName>-release.hap
dist/Homacs-<versionName>-release.app           上架包
```

release 签名默认用 `refs/release/release-profile3Release.p7b`
（`app-distribution-type=app_gallery`）。若用 `RELEASE_PROFILE` 指向 AGC 的
内测 profile（`type=release`、`app-distribution-type=internaltesting`、带
`debug-info.device-ids`），脚本同样接受，但会提示 device-bound：这种包只能
安装到注册过的设备，不能上传 AppGallery。

### 2.2 干净构建 + 部署（可选）

```bash
ARCH=aarch64 TARGET=<hdc-target> scripts/clean-build.sh --deploy
```

`--deploy` 等价于 `clean-build.sh` → `build-debug-app.sh` → `deploy.sh`，
不再由 `deploy.sh` 内部构建 HAP。`clean-build.sh` 每次都会重新组装
runtime，不复用旧源码的 rawfile。
构建完成后写：

```text
build/target/aarch64/build-manifest.json
```

记录源码、SDK、工具链、依赖、runtime 和产物 hash，并包含：

```json
{
  "features": {
    "HAVE_GNUTLS": true,
    "HAVE_LIBXML2": true,
    "HAVE_SQLITE3": true
  },
  "dependencies": {
    "gnutls":  { "version": "3.8.9",   "sha256": "...", "installed_sha256": "..." },
    "libxml2": { "version": "2.12.10", "sha256": "...", "installed_sha256": "..." },
    "sqlite3": { "version": "3.54.1",  "sha256": "...", "installed_sha256": "..." }
  }
}
```

`features` 直接解析 `build/target/<arch>/src/config.h`；`dependencies`
的版本/来源/归档 hash 来自 `versions.json`，`installed_sha256` 是实际链接的
静态库。

aarch64 构建显式打开三项特性：

```text
--with-gnutls   → HAVE_GNUTLS   （build/deps 中的 GnuTLS 3.8.9）
--with-xml2     → HAVE_LIBXML2  （libxml2 2.12.10）
--with-sqlite3  → HAVE_SQLITE3  （SQLite 3.54.1）
```

这三项不受 `--without-all` 影响：configure 之后脚本会检查
`src/config.h` 的三个 `#define` 和 `src/Makefile` 的
`LIBGNUTLS_*` / `LIBXML2_*` / `SQLITE3_*`，任一为空即失败。

GnuTLS/libxml2/SQLite 的编译参数通过 `LIBGNUTLS_CFLAGS/LIBS`、
`LIBXML2_CFLAGS/LIBS`、`SQLITE3_CFLAGS/LIBS` 直接传给 configure；
`PKG_CONFIG_LIBDIR` 限制在 `build/deps/<abi>/lib/pkgconfig`，避免误用宿主库。

### 2.3 增量

```bash
# 只改 C：在构建树里 make 目标对象，再重链并重新打 HAP
cd build/target/aarch64/src
make -o gl-stamp ohosgui.o
cd -
ARCH=aarch64 scripts/build-libemacs-gui.sh
ARCH=aarch64 scripts/build-debug-app.sh

# 只改 Lisp：重新组装并打包 runtime，再重新打 HAP
ARCH=aarch64 scripts/build-runtime-stage.sh
ARCH=aarch64 scripts/pack-runtime.sh
ARCH=aarch64 scripts/build-debug-app.sh
```

> `build-debug-app.sh` 会清 hvigor 的 `entry/libs` 中间产物并 touch
> `.so`/`host/napi_module.cpp`，否则可能打包旧的 native 库。

## 3. 部署

`deploy.sh` 只做三件事：定位 HAP、校验它是否还对应当前构建、安装/卸载。
它不构建、不签名，也不需要任何密钥口令。

```bash
# 安装默认 debug HAP（dist/Homacs-<version>-debug-<abi>.hap）
TARGET=<hdc-target> ARCH=aarch64 scripts/deploy.sh

# 安装指定的已签名 HAP
TARGET=<hdc-target> scripts/deploy.sh --hap dist/Homacs-1.0.4-release.hap

# 彻底删除应用（默认连数据一起删；--keep-data 保留数据）
TARGET=<hdc-target> scripts/deploy.sh --uninstall
TARGET=<hdc-target> scripts/deploy.sh --uninstall --keep-data

# 只安装不启动
TARGET=<hdc-target> scripts/deploy.sh --no-start
```

部署前先运行 `scripts/build-debug-app.sh`。deploy 会读取 HAP 同名的 `.json`
sidecar：若 `libemacs_gui.so` 在该 HAP 之后变过，或 HAP 的 `git_rev` 不是
当前 HEAD，就拒绝安装（`--force` 放行）；同时用设备
`const.product.cpu.abilist` 校验 ABI。这样不会再出现“改完 C 直接部署、
实际装的还是旧包”。

若从旧版本升级，`versionCode` 必须递增（`app/AppScope/app.json5`），否则
覆盖安装可能失败。release `.app` 不能通过 hdc 安装
（`9568322 not trusted app source`），只能走 AppGallery 渠道。

设备上已安装 release 签名的包时，debug HAP 无法覆盖安装（`9568286 install
provision type not same`），反之亦然。deploy 会先读设备的
`appProvisionType`，不一致时直接提示而不是等安装失败。切换方式：

```bash
# --keep-data 保留 runtime/home（runtime.stamp 命中时不会重新解包）
TARGET=<hdc-target> scripts/deploy.sh --uninstall --keep-data
TARGET=<hdc-target> scripts/deploy.sh
```

切回 release 包同样需要先卸载（release `.app` 走 AppGallery 渠道）。

只启动/重启而不重新安装：

```bash
$HDC -t $TARGET shell aa force-stop emacs.hmos.org
$HDC -t $TARGET shell aa start -b emacs.hmos.org -a EntryAbility
```

## 4. 首次启动与 runtime

首次启动会：

1. 解包 `rawfile/emacs-runtime.tar.gz` 到 `files/runtime102`；
2. 写 `runtime.stamp`（`buildId:libemacsVersion:tarLength`）；
3. `startInProcess()`，Emacs 线程启动。

不再向用户 HOME 安装 `.emacs`；平台默认值在 `ohos-win.el`，CA bundle 在
runtime 的 `etc/ssl/`。

runtime 包由 `scripts/build-runtime-stage.sh` 从**本仓库**
`emacs/{lisp,leim,etc}` 组装（`.elc` 在 Emacs 编译阶段生成在源树里），
不再依赖机器上安装过一份 Emacs。

> runtime 安装器会先把 `lisp/leim/etc` 整体删除再解包（防止旧 `.elc`
> 残留），所以 **`etc/ssl/ca-bundle.crt` 必须打在 runtime 包里**：
> `scripts/pack-runtime.sh` 会从 `app/certs/ca-bundle.crt` 复制到
> runtime 的 `etc/ssl/`。

设备侧路径（GUI）：

```text
/data/app/el2/100/base/emacs.hmos.org/haps/entry/files/runtime102/
  lisp/ leim/ etc/
  home/.emacs
  runtime.stamp
  emacs-stderr.txt
```

强制重建 runtime 并重新打 HAP（源码比 tarball 新时本来也会自动重建）：

```bash
ARCH=$ARCH FORCE_RUNTIME=1 scripts/build-debug-app.sh
TARGET=$TARGET ARCH=$ARCH scripts/deploy.sh
```

> 设备上 `TERM=dumb`，且只有 GUI terminal（没有 tty terminal），因此 runtime
> 不再分发 terminfo；`TERMINFO` 环境变量仍指向 `runtime/terminfo`，但当前
> 启动路径不会读取它。

## 5. 日志与诊断

### 5.1 常用命令

```bash
# tag 第一段是层：arkui / native / emacs
# 例如 ArkTS 页面、native renderer、Emacs RIF
$HDC -t $TARGET shell hilog -x -T native.render -L D
$HDC -t $TARGET shell hilog -x -T emacs.render -L D
$HDC -t $TARGET shell hilog -x -T arkui.gui -L I

# 示例：打开 native renderer 的 DEBUG
$HDC -t $TARGET shell hilog -b D -T native.render
# 恢复安静模式
$HDC -t $TARGET shell hilog -b I

# 清日志并抓全部应用日志
$HDC -t $TARGET shell hilog -r
$HDC -t $TARGET shell hilog -x | grep -aE 'emacs-(gui|hmos|term)|EmacsDump'

# 截图 / 布局
$HDC -t $TARGET shell uitest screenCap -p /data/local/tmp/s.png
$HDC -t $TARGET file recv /data/local/tmp/s.png ./s.png
$HDC -t $TARGET shell uitest dumpLayout -p /data/local/tmp/l.json -a
$HDC -t $TARGET file recv /data/local/tmp/l.json ./l.json

# 前台/进程/崩溃
$HDC -t $TARGET shell aa dump -l
$HDC -t $TARGET shell pidof emacs.hmos.org

# faultlog 通过 HiviewService 读取；普通 shell 直接 ls 会被拒绝
$HDC -t $TARGET shell "hidumper -s 1201 -a '-p Faultlogger -LogSuffixWithMs'"
$HDC -t $TARGET shell "hidumper -s 1201 -a '-p Faultlogger -f <cppcrash-file>'"
```

### 5.2 关键日志

| 日志 | 含义 |
| --- | --- |
| `native.render` / `renderer present content=...` | 该 frame 提交的 content/buffer 尺寸与 generation |
| `emacs.render` / `update-begin ... open=...` | Emacs RIF 是否接受本次 redisplay |
| `native.render` / `renderer surface created/resized/destroyed` | per-frame renderer 收到 surface 事件 |
| `native.render` / `frame ... exceeds surface ...` | frame > surface，进入 RESIZING |
| `native.input` / `onkey code=...` | XComponent 收到的键 |
| `emacs.lifecycle` / `inproc main enter/returned` | Emacs 线程启动/退出 |
| `native.napi` / `NAPI <name>` | NAPI 入口（DEBUG） |
| `arkui.gui` / `arkui.frame` | ArkTS 页面日志 |

### 5.3 故障定位顺序

1. **应用是否起来**：`aa dump -l`、`pidof`；看 `status/error` 页面。
2. **runtime 是否就绪**：`runtime102/lisp/loadup.el`、`runtime.stamp`。
3. **Emacs 是否启动**：`emacs-stderr.txt` 尾部、`hilog` 的
   `inproc main enter`、`ohos_term_init`、`ohos_create_frame`。
4. **surface 是否创建**：`surface created`；没有则看 XComponent `onLoad`/
   `OnSurfaceCreated`。
5. **是否在画**：`frame metrics`、`present diag`；`presents` 不增长则检查
   `pending_paint`/`surface_stale`/`flushfail`。
6. **输入是否到达**：`key evt` → `motion/mouse` → probe 文件；分别定位
   XComponent、输入环、`read_socket_hook`、命令绑定。
7. **是否崩溃**：用 `hidumper -s 1201 -a '-p Faultlogger ...'` 读取 cppcrash；
   再结合 `emacs-stderr.txt`。GUI 是单进程，Emacs 崩溃会带崩 UI。

### 5.4 常见问题

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| 启动页一直“正在安装运行时” | rawfile 缺失/解包失败 | 检查 HAP 内 `rawfile/emacs-runtime.tar.gz`、`installState` |
| 启动后黑屏/无首帧 | surface 未创建或 present 失败 | 看 `OHOSDBG surface created`、`OHOSDBG renderer present`、`OHOSDBG update-begin` |
| 文字挤在左上角 | frame 尺寸单位错/未采用 surface 尺寸 | 检查 pixelwise frame resize、`OHOSDBG frame-metrics enter` |
| 窗口 resize 后冻结/黑区 | bitmap 重建后未全量重绘，或 surface 尺寸小于 frame | 看 `OHOSDBG renderer backing store`、`OHOSDBG renderer request full repaint`、`exceeds surface` |
| 按键无反应 | 焦点不在 XComponent / 菜单未关 | `key evt` 是否存在；`xcomponent focus`；菜单 `guiMenuOpen` |
| 菜单点完不执行 | 菜单 binding 未 `call-interactively` | 检查 `ohos-menu-bar-open-index`、`menu result` |
| 粘贴为空 | Pasteboard 无文本/权限 | `clipboard-get` 日志、用 `PasteButton` 验证 |
| 装完还是旧界面 | hvigor/native 缓存，或只改了 Emacs 对象未重链 | 先 `build-debug-app.sh`（会清缓存），deploy 也会拒绝陈旧 HAP |
| `9568286 install provision type not same` | 设备上是 release 签名包，当前 HAP 是 debug（或反之） | `deploy.sh --uninstall [--keep-data]` 后再安装 |
| 设备启动 exit 254 | ABI 不匹配 | `abiFilters` 与设备 ABI 对齐 |
| `dlopen` 失败 | 缺依赖/符号/ABI | `readelf -d`、`--no-undefined`、manifest |

## 6. 相关文档

- 系统架构：[`architecture.md`](architecture.md)
- renderer/ABI：[`emacs-architecture.md`](emacs-architecture.md)
- 多窗口实验：[`capabilities.md#21-多窗口--每-frame-renderer-contextblocked`](capabilities.md#21-多窗口--每-frame-renderer-contextblocked)
- 能力边界：[`capabilities.md`](capabilities.md)
- 依赖统一/构建目录：[`tasks/build-unified.md`](tasks/build-unified.md)

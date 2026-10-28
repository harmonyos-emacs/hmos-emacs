# AGENTS.md

本文件是本仓库唯一的项目入口。先读本页，再按任务只读对应文档，不要一次加载全部文档。

## 1. 项目定位

把 GNU Emacs 移植到 HarmonyOS NEXT（aarch64-linux-ohos），以**原生 GUI frame**
（`window-system=ohos`）运行：Emacs 作为 `libemacs_gui.so` 在应用进程内启动，
ArkUI/XComponent 负责 surface、窗口、菜单和输入。

运行模型：

```text
ArkTS/UI 线程      窗口、XComponent、输入、生命周期
Emacs 线程         frame/window/glyph/redisplay/Lisp
renderer           按 frame 把 glyph 变成像素
```

## 2. 仓库结构

```text
emacs/        GNU Emacs 源码（git submodule，基于 emacs-31.1 的 OHOS 移植）
app/          Homacs HAP 工程（bundle: emacs.hmos.org）
  entry/src/main/cpp/           libentry.so：NAPI、XComponent、surface/输入桥
  entry/src/main/ets/           ArkTS：GUI 页面、启动/runtime 安装
  certs/                       CA bundle 源文件
renderer/     per-frame 原生 renderer（静态链接进 libemacs_gui.so）
scripts/      交叉编译、链接、runtime 打包、打包/签名公共层、部署、检查
third_party/  固定版本依赖配方（归档入库，产物输出到 build/deps）
docs/         架构、规范、构建部署和人工测试文档
refs/         本机签名材料（私钥/profile 不入库）
```

## 3. 文档路由

docs 顶层保持平铺；`testing/` 保留固定路径。

| 任务 | 必读 |
| --- | --- |
| 看整体边界、线程、数据流、ABI | [docs/architecture.md](docs/architecture.md) |
| 改 ArkTS、NAPI、HostBridge、Surface 生命周期 | [docs/app-architecture.md](docs/app-architecture.md) |
| 改 Emacs OHOS 后端、renderer、RIF、frame 几何 | [docs/emacs-architecture.md](docs/emacs-architecture.md) |
| 查/改 OHOS 专属 Lisp/C 接口、host request ABI | [docs/ohos-api.md](docs/ohos-api.md) |
| 判断当前能做什么、哪些是 BLOCKED | [docs/capabilities.md](docs/capabilities.md) |
| 写 ArkTS/C++/Emacs 代码、跑检查 | [docs/development-standards.md](docs/development-standards.md) |
| 构建、打包 runtime、部署、看日志 | [docs/build-deploy.md](docs/build-deploy.md) |
| 人工验收、回归测试 | [docs/testing/manual-feature-matrix.md](docs/testing/manual-feature-matrix.md) |

## 4. 修改规则

- 先确认改动属于哪一侧：UI/Host（app）、Emacs/redisplay（emacs）、像素输出（renderer）；
- 跨 ABI 的改动必须同时更新 `app/` 与 `emacs/` 两侧，并保持 typed API；
- 不要在 ArkUI 中为每段文本创建组件；文本绘制归 renderer；
- 不要在 renderer 中决定窗口尺寸、布局或 frame 生命周期；
- OHOS 后端的全局状态、锁和所有权必须写进对应架构文档；
- 文档只维护一份权威内容，其它位置用链接，不复制设计。

## 5. 构建与验证

```bash
# 环境检查（先执行）
scripts/preflight.sh --build-only

# C++ 格式/静态检查
scripts/check-app-cpp.sh --fix

# NAPI 导出与 index.d.ts 一致性
scripts/check-napi.sh

# ABI / 导出符号
scripts/check-abi.sh

# per-frame 约束
scripts/check-per-frame.sh

# 干净构建（推荐）
ARCH=aarch64 scripts/clean-build.sh

# 增量重链并重新打 debug HAP
ARCH=aarch64 BUILD=$PWD/build/target/aarch64 scripts/build-libemacs-gui.sh
ARCH=aarch64 scripts/build-debug-app.sh

# 安装/卸载到设备（deploy 只安装，不构建）
ARCH=aarch64 TARGET=<hdc-target> scripts/deploy.sh
ARCH=aarch64 TARGET=<hdc-target> scripts/deploy.sh --uninstall
```

外部路径统一放在 `.env.local`（模板 `.env.example`），不要写进脚本：

```text
CT / JAVA_HOME / TARGET / DEBUG_* / RELEASE_*
```

依赖归档固定在 `third_party/src`，构建输出固定在 `build/`（`BUILD_ROOT`
可覆盖）；不再需要 HOST_SYSROOT / OHOS_DEPS / RUNTIME_STAGE。

详细步骤（x86_64、增量构建、`--force-runtime`、模拟器、日志和故障定位）见
[docs/build-deploy.md](docs/build-deploy.md)。

## 6. 签名与图标

签名材料不入库，按 profile 分命名空间，由 `scripts/lib/signing.sh` 统一解析：

```text
debug:   DEBUG_KEYSTORE / DEBUG_KEYSTORE_PWD / DEBUG_KEY_ALIAS /
         DEBUG_KEY_PWD / DEBUG_APP_CERT / DEBUG_PROFILE
release: RELEASE_KEYSTORE / RELEASE_KEYSTORE_PWD / RELEASE_KEY_ALIAS /
         RELEASE_KEY_PWD / RELEASE_APP_CERT / RELEASE_PROFILE
```

口令也可以放在 `refs/<mode>/CREDENTIALS.txt`（0600）。两条构建路径都会校验
profile（bundle、类型、ACL）并 `verify-app`；debug 必须设备绑定，release
允许 `internaltesting` 的设备绑定 profile（构建会提示不能上架）。初始化和迁移说明见
[docs/build-deploy.md](docs/build-deploy.md#11-签名材料debug--release-对齐)。

应用图标 `app/AppScope/resources/base/media/app_icon.png` 是 Homacs 自有图标
（1024×1024 PNG），源文件为 `docs/assets/homacs-icon.svg`，不使用 Emacs 官方
天鹅图标；图标本身没有第三方版权。

## 7. 仓库约定

- 不提交 DevEco 构建产物（`entry/build`、`.cxx`、`oh_modules`、HAP）、
  `dist/` 下的安装包与签名输出、生成的原生库 `libemacs_gui.so`、
  runtime/init 压缩包、Emacs 构建树（`build/`、`app/entry/build`、`.cxx`
  等）以及签名私钥/profile。
- `app/certs/ca-bundle.crt` 是 runtime 的 CA bundle 源文件，由
  `scripts/pack-runtime.sh` 打进 `etc/ssl/`；不要把它写进用户 HOME。
- 修改启动顺序、桥接协议、frame 生命周期或队列容量时，同步更新 `docs/`
  中对应模块；`docs/` 以当前代码为准，不保留过期设计稿。
- `.agents/skills/` 为按 `skills-lock.json` 安装的第三方技能，不入库。

## 8. 文档维护

```text
docs/
  architecture.md              整体架构
  app-architecture.md          app 侧架构
  emacs-architecture.md        Emacs OHOS 侧架构
  ohos-api.md                  OHOS Lisp/C 接口与 host ABI
  capabilities.md              当前应用的能力边界
  development-standards.md     编码规范和检查
  build-deploy.md              构建部署
  testing/manual-feature-matrix.md  手动测试
```

新增文档前先判断能否并入以上文件；不要新增 `docs/architecture/`、
`docs/modules/` 等层级。文档状态必须与当前分支、ABI 和阻塞项一致。

# Emacs on HarmonyOS NEXT

把 GNU Emacs 移植到 HarmonyOS NEXT（aarch64-linux-ohos），以终端（TTY）形态运行：
原生 pty 后端 + ArkWeb/xterm.js 终端前端 + HAP 打包签名。

当前状态、补丁说明与已知问题见 [docs/PORTING-STATUS.md](docs/PORTING-STATUS.md)。

## 目录结构

```
emacs/        GNU Emacs 源码（git submodule，分支 ohos）
app/          HarmonyOS HAP 工程（bundle: emacs.hmos.org）
  entry/src/main/cpp/           NAPI：pty/fork/exec、runtime 安装、resize
  entry/src/main/ets/           ArkTS：WebView 终端页面、启动/dump 流程
  entry/src/main/resources/rawfile/web/   xterm.js 终端前端
  home-init/                    首次启动写入 runtime 的 ~/.emacs 与 CA bundle 源文件
scripts/      build-emacs-ohos.sh / build-libemacs.sh / pack-*.sh / deploy.sh
patch/        Emacs 侧 HarmonyOS 补丁（0001-0003）
docs/         状态文档与截图
refs/         签名说明（证书/私钥/profile 不入库，见 refs/DEPLOY-README.md）
tools/        package-index 等辅助工具
```

## 构建

前置：DevEco commandline-tools、交叉编译的 ncurses/gmp/GnuTLS 等依赖
（`/home/song/opt/ohos-deps`）。详见 docs/PORTING-STATUS.md。

```bash
# 1. Emacs 交叉编译（产物：build-ohos/src/temacs、libemacs.so）
scripts/build-emacs-ohos.sh --reconfigure
scripts/build-libemacs.sh

# 2. 生成 HAP 内嵌资源（均不入库）
scripts/pack-runtime.sh            # rawfile/emacs-runtime.tar.gz
scripts/pack-home-init.sh          # rawfile/home-init.tar.gz

# 3. 构建、签名、安装、启动
scripts/deploy.sh
```

签名材料不入库；通过 `KEYSTORE` / `KEYSTORE_PWD` / `KEY_ALIAS` / `KEY_PWD`
环境变量或 refs/DEPLOY-README.md 的说明提供。

## 仓库约定

- 不提交 DevEco 构建产物（`entry/build`、`.cxx`、`oh_modules`、HAP）、
  生成的原生库 `libemacs.so`、runtime/init 压缩包、Emacs 构建树（`build-ohos`、
  `build-host`）以及签名私钥/profile。
- `app/home-init/` 是 `~/.emacs` 与 CA bundle 的**源文件**；修改后运行
  `scripts/pack-home-init.sh` 重新生成 rawfile 压缩包。
- `.agents/skills/` 为按 `skills-lock.json` 安装的第三方技能，不入库。

# HarmonyOS HAP 工程

`app/` 是 Homacs（基于 GNU Emacs）的 Stage 模型工程。

- `entry/src/main/ets/`：ArkTS 页面（`pages/Gui`）、Ability、HostBridge。
- `entry/src/main/cpp/`：`libentry.so` 的 native 实现（`host/`、`gui/`）。
- `entry/src/main/resources/rawfile/`：runtime/init tarball。
- `entry/libs/<abi>/`：交叉编译的 `libemacs_gui.so`（构建产物，不入库）。

构建与签名见 `scripts/build-debug-app.sh` / `scripts/build-release-app.sh`，
安装与卸载见 `scripts/deploy.sh`；完整说明见 `docs/build-deploy.md`。

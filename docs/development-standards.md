# 开发规范

本页定义 ArkTS、App C++ 和 Emacs OHOS 侧的最低编码约束，以及提交前必须通过的检查。
详细架构见 [app 侧](app-architecture.md)、[Emacs 侧](emacs-architecture.md)。

## 1. 通用规则

- 代码、注释、日志使用英文；用户文档可以使用中文。
- 一个文件只做一件事：UI 不画字，renderer 不管理窗口，NAPI 不写业务。
- 跨 ABI/线程只传 `frame_id`、typed struct、request/menu id 或 JSON payload；
  不传指针、Lisp 对象或 renderer 内部对象。
- 新行为必须有对应的日志标签、失败路径和人工验收用例。
- 不提交构建产物、设备截图、测试结果；这些放 `artifacts/`（已忽略）。

## 2. ArkTS 规范（`app/entry/src/main/ets`）

### 命名与类型

| 类别 | 规则 | 示例 |
| --- | --- | --- |
| 类/接口/枚举 | UpperCamelCase | `FrameWindowManager` |
| 方法/变量 | lowerCamelCase | `createFrame`、`surfaceId` |
| 常量 | UPPER_SNAKE_CASE | `MAX_FRAME_COUNT` |
| 私有成员 | `private` + lowerCamelCase | `private windowStage` |

- 使用显式类型；禁止 `any` 和隐式 `any` 回调参数。
- 可空值必须显式处理；不要用 `!` 掩盖生命周期问题。
- 新 API 必须更新 `app/entry/src/main/cpp/types/libentry/index.d.ts`。

### UI 与线程

- ArkTS 只在 UI 线程操作窗口、XComponent、菜单和 IME。
- 不在 UI 线程做文件解包、长循环或同步等待 Emacs。
- native 调用统一经过 `HostBridge.ets`，页面不直接持有 NAPI 模块。
- `aboutToDisappear`/窗口销毁必须释放监听器、定时器和 XComponent 回调。
- 不为每段文本、每个 glyph 或每个 help-echo 创建 ArkUI 组件。

### 检查

```bash
scripts/check-napi.sh          # NAPI 导出 ↔ index.d.ts
scripts/check-app-cpp.sh       # 同时覆盖 app 侧 C++ 格式/静态检查
```

ArkTS 类型检查由 Hvigor 构建承担：

```bash
hvigorw --mode module -p module=entry@default assembleHap --no-daemon
```

## 3. App C++ 规范（`app/entry/src/main/cpp`）

### 目录与职责

- `common/`：无业务、无 NAPI 依赖的工具（日志、常量、字符串、文件、base64）。
- `host/`：`HostContext` 拥有 `EmacsHost`/`RuntimeInstaller`/`ImeService`/
  `SystemBridge`；`host/napi/` 只放薄 NAPI 适配。
- `gui/`：Surface、绘制、输入、present；通过 `ohos_gui.h` 的 C 钩子与 host 通信。

### 命名与头文件

| 类别 | 规则 | 示例 |
| --- | --- | --- |
| 类型 | UpperCamel | `Surface`、`Presenter` |
| 函数 | UpperCamel | `NativeClear`、`ApplyFrameMetrics` |
| C ABI | `ohos_` / `ohosgui_` 小写下划线 | `ohos_gui_draw_text` |
| 常量 | `k` + UpperCamel | `kFontW`、`kNativeLineH` |
| 成员/局部 | snake_case | `frame_mode`、`cell_w` |
| NAPI 导出名 | 小写驼峰，与 `index.d.ts` 一致 | `guiTick` |

- 头文件自包含；只放声明与 inline 小函数。
- include 路径从 `cpp/` 根开始：`#include "host/host_api.h"`。
- 公共头不 include 实现文件；聚合头逐步拆分。

### NAPI、日志与资源

- 每个导出函数：取参 → 调用服务 → 返回，≤ 20 行。
- 检查 `napi_status`；失败返回默认值并 `LOGW`，不抛异常。
- 不在适配层放 `static` 状态；状态属于服务/模块。
- 统一用 `gui_log.h` 的 `LOGI/LOGW/LOGE`，不重复定义宏。
- `Surface::lock` 只保护 Surface 状态；锁内不做文件/NAPI/绘制 I/O。
- fd、NativeWindow buffer、OH_Drawing 对象用 RAII 或成对释放。

### 检查

```bash
scripts/check-app-cpp.sh          # clang-format dry-run + clang-tidy
scripts/check-app-cpp.sh --fix    # 应用 clang-format
scripts/check-abi.sh              # 导出符号断言
scripts/check-napi.sh             # NAPI 导出表 ↔ index.d.ts
```

格式基线：`app/entry/src/main/cpp/.clang-format`；静态检查：`.clang-tidy`。

## 4. Emacs OHOS 规范（`emacs/src/ohos*`、`emacs/lisp/term/ohos-win.el`）

- 只修改 OHOS 相关文件；通用 Emacs 行为改动必须说明原因并单独列出。
- C 代码遵循 Emacs GNU 风格；新增 OHOS 文件使用 `ohos_`/`ohosgui_` 前缀。
- Lisp 使用 `lexical-binding: t`，符号加 `ohos-` 前缀，不硬编码设备路径。
- OHOS 后端不得依赖 X11/GTK/Android 的对象或头文件。
- 跨线程只通过 typed host ABI；frame 身份用 `frame_id`，不使用全局 selected frame。
- mouse/help-echo 走 Emacs 机制；不在 ArkUI 为每段文本创建组件，不新增 per-text ABI。
- 新 frame 资源必须绑定生命周期；surface 重建、删除 frame、present 失败都要有日志。
- 修改 Lisp 后必须重新打 runtime；只重链 `.so` 不够。

### 检查

```bash
git -C emacs diff --check
# 先编译改动对象，再重链；完整构建
ARCH=aarch64 BUILD=$PWD/build/target/aarch64 scripts/build-emacs-ohos.sh
ARCH=aarch64 BUILD=$PWD/build/target/aarch64 scripts/build-libemacs-gui.sh
```

ABI/NAPI 变更同时运行：

```bash
scripts/check-abi.sh
scripts/check-napi.sh
scripts/check-per-frame.sh
```

## 5. 提交前检查清单

- [ ] 改动范围属于 app / emacs / renderer 中的哪一层，已在提交说明中写清；
- [ ] 没有提交 `build-*`、`artifacts/`、测试结果或设备截图；
- [ ] `scripts/check-app-cpp.sh` 通过；
- [ ] NAPI/ABI 有改动时 `check-napi.sh`、`check-abi.sh` 通过；
- [ ] 改动 Lisp 时 runtime 已重打并部署；
- [ ] 对应架构/能力文档和人工测试用例已同步。

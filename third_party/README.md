# third_party — 固定版本依赖（OHOS 交叉构建）

本目录保存**构建配方**和**固定版本的源码归档**（`src/*.tar.*`、`src/*.zip`，
入库以保证离线可重建）。解包目录在 `build/`（gitignore），安装产物在
`build/deps/<abi>/{include,lib,pkgconfig}`，由 `scripts/clean-build.sh` 统一消费。

## 维护规则

1. **版本固定**：所有库的版本、下载地址、`sha256` 写在 [versions.json](versions.json)，
   不得使用 "latest" 或分支名。升级时同时更新 `version`、`url`、`sha256`，
   并记录到 `CHANGELOG.md`。
2. **来源可信**：只从上游官方发布地址下载；不使用未固定版本的 git 仓库快照。
3. **补丁显式**：任何修改都放进 `third_party/<lib>/patches/*.patch`，按序号命名，
   禁止"下载后手改源码"。补丁要有注释说明原因与可移除条件。
4. **许可证留档**：每个库保留其许可证文件，并在 `versions.json` 里写 `license`。
5. **产物不入库**：`build/`、解包目录一律进 `.gitignore`；只有 `src/` 下的
   固定版本归档入库。构建可复现靠"版本 + sha256 + 脚本"。
6. **审计可跑**：构建脚本在解包前用 `versions.json` 的 `sha256` 校验归档；
   `scripts/preflight.sh` 在每次构建前复查所有归档。

## 目录结构

```text
third_party/
  README.md            # 本文件
  CHANGELOG.md         # 升级记录（版本、时间、原因）
  versions.json        # 版本/地址/sha256/许可/configure
  src/<archive>        # 固定版本归档（入库）
  build/<lib-ver>/     # 解包源码（gitignore）
```

## 构建

`scripts/clean-build.sh` 是唯一入口，它按顺序调用：

```bash
scripts/build-ohos-deps.sh <abi>      # gmp → nettle → tasn1 → unistring
                                      # → ncurses → gnutls
scripts/build-ohos-imaging.sh libpng <abi>
scripts/build-ohos-libxml2.sh <abi>
scripts/build-ohos-sqlite3.sh <abi>
scripts/preflight.sh --deps
```

单独调试某个库时可以直接运行对应脚本；它们都是 `clean-build.sh` 的内部步骤。

## 与 OpenHarmony 既有适配的关系

- OpenHarmony 有官方三方库移植项目 **tpc_c_cplusplus**（每个库带
  `docs/hap_integrate.md`），以及 `openharmony/third_party_libpng` 等仓库；
  HarmonyOS PC 侧还有 **build_in_harmonyos** 项目。
- 本目录**不直接依赖**这些仓库的构建产物，而只借鉴其"版本 + 补丁 + 交叉编译参数"的经验，
  保证我们自己的构建可复现、可审计；若某库在 tpc_c_cplusplus 有成熟补丁，应尽量复用其补丁
  （放进 `patches/` 并注明来源）。

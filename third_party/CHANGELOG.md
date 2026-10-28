# third_party 变更记录

## 2026-11-19（BUILD-UNIFIED）
- 依赖统一：新增 **gmp 6.3.0、nettle 3.9.1（含 hogweed）、libtasn1 4.19.0、
  libunistring 1.2、ncurses 6.5、GnuTLS 3.8.9**，归档入库；
  `scripts/build-ohos-deps.sh` 按 gmp → nettle → tasn1 → unistring →
  ncurses → gnutls 顺序离线构建到 `build/deps/<abi>`；
- 所有依赖安装前缀从 `third_party/ohos/<abi>` 迁到 `build/deps/<abi>`；
- 解包源码从 `third_party/src` 迁到 `third_party/build/`（gitignore）；
- 删除 `HOST_SYSROOT`、`OHOS_DEPS`、`RUNTIME_STAGE` 三个机器级输入；
  runtime 改由 `scripts/build-runtime-stage.sh` 从本仓库组装。

## 2026-11-18
- 新增 **libxml2 2.12.10**（MIT，`libxml-parse-html-region` / Eww HTML 解析）；
  归档 `third_party/src/libxml2-2.12.10.tar.xz` 入库，版本/URL/sha256 见
  `versions.json`，由 `scripts/build-ohos-libxml2.sh` 离线交叉编译；
- 新增 **SQLite 3.54.1 amalgamation**（Public Domain，`sqlite-open` /
  `sqlite-execute` / `sqlite-select`）；归档
  `third_party/src/sqlite-amalgamation-3540100.zip` 入库，编译宏固定为
  THREADSAFE/COLUMN_METADATA/FTS5/RTREE + `SQLITE_OMIT_LOAD_EXTENSION`；
- `scripts/build-ohos-imaging.sh all` 会把 libxml2/sqlite3 委托给各自脚本。

## 2026-11-04
- 初始建立：libpng 1.6.44（png），NDK 交叉编译通过；
- 去掉 libXpm（依赖 Xlib，sysroot 无 X11 头文件）——按项目决定不再支持 XPM；
- SVG 选型定为 **nanosvg**（单头文件、zlib 许可、无外部依赖），已按内容哈希固定并入库；
  放弃 librsvg（需要 GLib/Pango/Cairo/GDK-Pixbuf + meson）与 resvg（需要 rustc）。

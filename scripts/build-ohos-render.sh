#!/bin/bash
# Build the per-frame renderer static archive.  Only libemacs_gui.so links
# it; libentry.so never includes renderer headers or symbols.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
N=$CT/sdk/default/openharmony/native
ARCH=${ARCH:-aarch64}
case "$ARCH" in
  aarch64) ABI=arm64-v8a; TARGET=aarch64-linux-ohos ;;
  x86_64)  ABI=x86_64;    TARGET=x86_64-linux-ohos ;;
  *) echo "unsupported ARCH: $ARCH" >&2; exit 2 ;;
esac
OUT=$REPO/app/entry/libs/$ABI
mkdir -p "$OUT"
INCLUDES=(-I"$REPO/renderer" -I"$REPO/emacs/src"
          -I"$REPO/app/entry/src/main/cpp/common")

CXX=("$N/llvm/bin/clang++" --target="$TARGET" --sysroot="$N/sysroot"
     -std=c++17 -O2 -fPIC -Wall -Wextra -Wno-unused-parameter)

OBJECTS=()
for src in renderer surface present; do
  obj=$OUT/renderer-$src.o
  "${CXX[@]}" -c "${INCLUDES[@]}" "$REPO/renderer/$src.cpp" -o "$obj"
  OBJECTS+=("$obj")
done
rm -f "$OUT"/gpu_direct.o "$OUT"/ohos_render.o
"$N/llvm/bin/llvm-ar" rcs "$OUT/libohos_render.a" "${OBJECTS[@]}"
rm -f "$OUT/libohos_render.so"
echo "libohos_render.a: $OUT/libohos_render.a"

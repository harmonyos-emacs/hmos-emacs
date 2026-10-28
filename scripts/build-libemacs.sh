#!/bin/bash
# Link the Emacs object files into libemacs.so, which the HarmonyOS app
# loads into a child process.  Keep this in sync with scripts/build-emacs-ohos.sh.
set -e

CT=${CT:-/home/song/Desktop/commandline-tools-linux-x64-26.0.0.851/command-line-tools}
N=$CT/sdk/default/openharmony/native
DEPS=${OHOS_DEPS:-/home/song/opt/ohos-deps}
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=$REPO/build-ohos/src

cd "$SRC"
OBJS=$(ls *.o | tr '\n' ' ')
"$N/llvm/bin/clang" --target=aarch64-linux-ohos --sysroot="$N/sysroot" \
  -shared -o libemacs.so -Wl,-soname,libemacs.so \
  -L"$DEPS/lib" $OBJS ../lib/libgnu.a -lgnutls -lunistring -lhogweed -lgmp -lnettle -ltasn1 -lncurses -lz -lm -ldl -lpthread

mkdir -p "$REPO/app/entry/libs/arm64-v8a"
cp libemacs.so "$REPO/app/entry/libs/arm64-v8a/"
echo "libemacs.so: $SRC/libemacs.so -> app/entry/libs/arm64-v8a/"

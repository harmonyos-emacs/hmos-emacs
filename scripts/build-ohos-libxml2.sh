#!/bin/bash
# Cross-build the static libxml2 that Emacs uses for `libxml-parse-html-region'
# (the Eww HTML parser).
#
# Source pinning lives in third_party/versions.json (version + url + sha256)
# and the archive is tracked under third_party/src.  This script is offline:
# a missing archive is an error, never a download.
#
#   scripts/build-ohos-libxml2.sh [abi]
#   ABI=arm64-v8a scripts/build-ohos-libxml2.sh
#
# Output: build/deps/<abi>/{include/libxml2,lib/libxml2.a,lib/pkgconfig}
# which is where clean-build.sh configures Emacs and build-libemacs-gui.sh
# looks for -lxml2.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"
TP=$ROOT/third_party
SDK=${OHOS_SDK:-$CT/sdk/default/openharmony}
LLVM=$SDK/native/llvm/bin
SYSROOT=$SDK/native/sysroot

ABI=${1:-${ABI:-arm64-v8a}}
case $ABI in
  arm64-v8a) TRIPLE=aarch64-linux-ohos ;;
  x86_64)    TRIPLE=x86_64-linux-ohos ;;
  *) echo "unsupported abi: $ABI" >&2; exit 2 ;;
esac
PREFIX=${DEPS_PREFIX:-$BUILD_ROOT/deps/$ABI}
SRC=$TP/src
WORK=$TP/build

meta () { python3 - "$TP/versions.json" "$1" "$2" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])
PY
}

URL=$(meta libxml2 url)
SHA=$(meta libxml2 sha256)
VER=$(meta libxml2 version)
ARCHIVE=$SRC/${URL##*/}
DIR=$WORK/libxml2-$VER

[ -f "$ARCHIVE" ] || {
  echo "missing tracked libxml2 archive $ARCHIVE" >&2
  echo "this build is offline: restore it from git (third_party/src)" >&2
  exit 1
}
echo "$SHA  $ARCHIVE" | sha256sum -c - >/dev/null || {
  echo "libxml2: checksum mismatch for ${URL##*/} (want $SHA)" >&2
  exit 1
}

if [ ! -d "$DIR" ]; then
  echo "== unpack ${URL##*/}"
  mkdir -p "$DIR"
  tar -xf "$ARCHIVE" -C "$DIR" --strip-components=1
fi

# libxml2 2.12 still ships a config.sub that predates the OHOS triple.
# Take the one from this checkout's Emacs sources (a normal cross-build
# workaround, applied to the unpacked tree only).
if ! "$DIR/config.sub" "$TRIPLE" >/dev/null 2>&1; then
  echo "== refresh config.sub/config.guess"
  cp "$ROOT/emacs/build-aux/config.sub" "$DIR/config.sub"
  cp "$ROOT/emacs/build-aux/config.guess" "$DIR/config.guess"
fi

mkdir -p "$PREFIX" "$WORK"
cd "$DIR"
make distclean >/dev/null 2>&1 || true

# iconv is available from the OHOS libc, so the parser can convert the
# encodings HTML pages declare.  zlib/lzma/python are not needed by Eww;
# leaving them out keeps the HAP smaller and the build hermetic.
echo "== configure libxml2 $VER for $TRIPLE"
CC="$LLVM/clang --target=$TRIPLE --sysroot=$SYSROOT" \
AR=$LLVM/llvm-ar RANLIB=$LLVM/llvm-ranlib STRIP=$LLVM/llvm-strip \
CFLAGS="-O2 -fPIC" \
LDFLAGS="--target=$TRIPLE --sysroot=$SYSROOT" \
./configure \
  --host="$TRIPLE" --build=x86_64-pc-linux-gnu \
  --prefix="$PREFIX" \
  --disable-shared --enable-static \
  --without-python --without-lzma --without-zlib

make -j"$(nproc)"
make install

echo "libxml2 $VER installed to $PREFIX"
ls -l "$PREFIX/lib/libxml2.a" "$PREFIX/include/libxml2/libxml/HTMLparser.h"

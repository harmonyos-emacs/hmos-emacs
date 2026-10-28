#!/usr/bin/env bash
# Cross-compile one of the image libraries (or all of them) for OpenHarmony.
#
#   scripts/build-ohos-imaging.sh libpng arm64-v8a
#   scripts/build-ohos-imaging.sh all arm64-v8a
#
# Sources are pinned in third_party/versions.json (version + url + sha256),
# unpacked under third_party/build, and installed into
# build/deps/<abi>/{include,lib}.  Nothing generated here is committed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"
TP=$ROOT/third_party
SDK=${OHOS_SDK:-$CT/sdk/default/openharmony}
LLVM=$SDK/native/llvm/bin
SYSROOT=$SDK/native/sysroot

LIB=${1:?usage: $0 <lib|all> <abi>}
ABI=${2:-arm64-v8a}
case $ABI in
  arm64-v8a) TRIPLE=aarch64-unknown-linux-ohos ;;
  x86_64)    TRIPLE=x86_64-unknown-linux-ohos ;;
  *) echo "unsupported abi: $ABI" >&2; exit 2 ;;
esac

CC=$LLVM/${TRIPLE}-clang
CXX=$LLVM/${TRIPLE}-clang++
AR=$LLVM/llvm-ar
RANLIB=$LLVM/llvm-ranlib
STRIP=$LLVM/llvm-strip
PREFIX=${DEPS_PREFIX:-$BUILD_ROOT/deps/$ABI}
SRC=$TP/src
WORK=$TP/build

mkdir -p "$SRC" "$WORK" "$PREFIX"

meta () { python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open('third_party/versions.json'))[sys.argv[1]]
print(d[sys.argv[2]])
PY
}

fetch () {
  local lib=$1 url sha name dir
  url=$(meta "$lib" url); sha=$(meta "$lib" sha256)
  [ "$url" = "TBD" ] && { echo "$lib: no pinned source yet" >&2; return 1; }
  name=${url##*/}
  if [ ! -f "$SRC/$name" ]; then
    echo "$lib: missing tracked source archive $SRC/$name" >&2
    return 1
  fi
  echo "$sha  $SRC/$name" | sha256sum -c - >/dev/null || {
    echo "$lib: checksum mismatch for $name" >&2; return 1; }
  dir=$WORK/${name%.tar.*}
  if [ ! -d "$dir" ]; then
    echo "== unpack $name" >&2
    mkdir -p "$dir"
    tar -xf "$SRC/$name" -C "$dir" --strip-components=1 || return 1
  fi
  echo "$dir"
}

# Old autotools releases do not know the "ohos" triple; take config.sub and
# config.guess from this checkout's Emacs sources (normal cross-build
# workaround, applied to the unpacked tree only).
refresh_config_scripts () {
  local dir=$1
  if ! "$dir/config.sub" "$TRIPLE" >/dev/null 2>&1; then
    echo "== refresh config.sub in $dir" >&2
    cp "$ROOT/emacs/build-aux/config.sub" "$dir/config.sub"
    cp "$ROOT/emacs/build-aux/config.guess" "$dir/config.guess"
  fi
}

apply_patches () {
  local lib=$1 dir=$2 p
  for p in "$TP/$lib"/patches/*.patch; do
    [ -e "$p" ] || continue
    echo "== patch $(basename "$p")" >&2
    ( cd "$dir" && patch -p1 --forward < "$p" )
  done
}

build_autotools () {
  local dir=$1 extra=$2
  ( cd "$dir" &&
    CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB STRIP=$STRIP \
    CFLAGS="-O2 -fPIC" CPPFLAGS="-I$PREFIX/include -I$SYSROOT/usr/include" \
    LDFLAGS="-L$PREFIX/lib -L$SYSROOT/usr/lib/$TRIPLE" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    ./configure --host=$TRIPLE --prefix="$PREFIX" \
      --enable-static --disable-shared $extra &&
    make -j"$(nproc)" && make install )
}

build_libpng () {
  local dir; dir=$(fetch libpng) || return 1
  apply_patches libpng "$dir"
  refresh_config_scripts "$dir"
  build_autotools "$dir" "--disable-tools"
}

build_libxpm () {
  local dir; dir=$(fetch libXpm) || return 1
  apply_patches libXpm "$dir"
  # libXpm needs the X headers/protocol package; it has no --disable-tools.
  refresh_config_scripts "$dir"
  build_autotools "$dir" ""
}

run_one () {
  case $1 in
    libpng) build_libpng ;;
    libXpm) build_libxpm ;;
    svg) echo "svg: not buildable yet (see third_party/versions.json)" >&2; return 1 ;;
    *) echo "unknown image lib: $1" >&2; return 1 ;;
  esac
}

if [ "$LIB" = all ]; then
  run_one libpng
else
  run_one "$LIB"
fi

echo "== installed into $PREFIX"
ls "$PREFIX/lib" 2>/dev/null | head

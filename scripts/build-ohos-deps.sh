#!/bin/bash
# Internal build step (clean-build.sh is the only supported entry point).
#
# Cross-build the pinned target dependency chain used by the Emacs OHOS port:
#
#   gmp -> nettle(+hogweed) -> libtasn1 -> libunistring -> ncurses -> gnutls
#
# Sources are pinned in third_party/versions.json and tracked under
# third_party/src; unpacked trees live under third_party/build and the install
# prefix is build/deps/<abi>.  This script never downloads: a missing or
# corrupted archive is an error.
#
#   scripts/build-ohos-deps.sh [abi]
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
JOBS=${JOBS:-$(nproc)}
mkdir -p "$PREFIX" "$WORK"

die () { echo "$*" >&2; exit 1; }

json_get () { python3 - "$TP/versions.json" "$1" "$2" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]]
print("\n".join(v) if isinstance(v, list) else v)
PY
}

archive () {
  local url; url=$(json_get "$1" url)
  echo "$SRC/${url##*/}"
}

fetch () {
  local name=$1 url sha ver dir arch
  url=$(json_get "$name" url)
  sha=$(json_get "$name" sha256)
  ver=$(json_get "$name" version)
  arch=$(archive "$name")
  [ -f "$arch" ] || die "missing pinned archive $arch (restore it from git)"
  echo "$sha  $arch" | sha256sum -c - >/dev/null \
    || die "$name: checksum mismatch for ${url##*/}"
  dir=$WORK/$name-$ver
  if [ ! -d "$dir" ]; then
    echo "== unpack ${url##*/}" >&2
    mkdir -p "$dir"
    tar -xf "$arch" -C "$dir" --strip-components=1
  fi
  echo "$dir"
}

extract_to () {
  local arch=$1 dir=$2
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xf "$arch" -C "$dir" --strip-components=1
}

# Several upstream config.sub files predate the OHOS triple.  Take the ones
# from this checkout's Emacs sources (normal cross-build workaround).
refresh_config () {
  local dir=$1 f g
  while IFS= read -r -d '' f; do
    if ! "$f" "$TRIPLE" >/dev/null 2>&1; then
      echo "== refresh ${f#"$dir"/}" >&2
      cp "$ROOT/emacs/build-aux/config.sub" "$f"
      g=${f%config.sub}config.guess
      [ -f "$g" ] && cp "$ROOT/emacs/build-aux/config.guess" "$g"
    fi
  done < <(find "$dir" -maxdepth 4 -name config.sub -type f -print0)
}

configure_and_make () {
  local name=$1 dir=$2 key=${3:-configure}
  local -a args
  local ver
  mapfile -t args < <(json_get "$name" "$key")
  ver=$(json_get "$name" version)
  echo "== build $name $ver ($key)"
  (
    cd "$dir"
    CC="$LLVM/clang --target=$TRIPLE --sysroot=$SYSROOT" \
    CFLAGS="-O2 -fPIC" \
    CPPFLAGS="-I$PREFIX/include" \
    LDFLAGS="--sysroot=$SYSROOT -L$PREFIX/lib" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
    BUILD_CC=${BUILD_CC:-cc} \
      ./configure --host="$TRIPLE" --build=x86_64-pc-linux-gnu \
        --prefix="$PREFIX" "${args[@]}"
    make -j"$JOBS"
    make install
  )
}

# gnutls resolves zlib through pkg-config, but the OHOS sysroot ships no
# zlib.pc.  Describe the sysroot zlib for the dependency builds.
write_zlib_pc () {
  local hdr=$SYSROOT/usr/include/zlib.h ver
  [ -f "$hdr" ] || die "missing zlib headers in the OHOS sysroot"
  ver=$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$hdr" | head -1)
  mkdir -p "$PREFIX/lib/pkgconfig"
  cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
prefix=$SYSROOT/usr
exec_prefix=\${prefix}
libdir=$SYSROOT/usr/lib/$TRIPLE
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library (OHOS sysroot)
Version: $ver
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
}

echo "== target dependencies for $ABI -> $PREFIX"

dir=$(fetch gmp)
refresh_config "$dir"
configure_and_make gmp "$dir"

dir=$(fetch nettle)
refresh_config "$dir"
configure_and_make nettle "$dir"

dir=$(fetch libtasn1)
refresh_config "$dir"
configure_and_make libtasn1 "$dir"

dir=$(fetch libunistring)
refresh_config "$dir"
configure_and_make libunistring "$dir"

# ncurses is built twice into the same prefix: the wide build provides
# libncursesw/libtinfo, the narrow build provides the libncurses that the
# final link uses.
ncurses_archive=$(archive ncurses)
wide=$WORK/ncurses-$(json_get ncurses version)-wide
narrow=$WORK/ncurses-$(json_get ncurses version)-narrow
extract_to "$ncurses_archive" "$wide"
refresh_config "$wide"
configure_and_make ncurses "$wide" configure_wide
extract_to "$ncurses_archive" "$narrow"
refresh_config "$narrow"
configure_and_make ncurses "$narrow" configure_narrow

write_zlib_pc
dir=$(fetch gnutls)
refresh_config "$dir"
configure_and_make gnutls "$dir"

missing=""
for f in lib/libgmp.a lib/libnettle.a lib/libhogweed.a lib/libtasn1.a \
         lib/libunistring.a lib/libncurses.a lib/libgnutls.a \
         lib/pkgconfig/gnutls.pc include/gnutls/gnutls.h; do
  [ -e "$PREFIX/$f" ] || missing="$missing $f"
done
[ -z "$missing" ] || die "dependency build incomplete:$missing"

echo "dependencies installed to $PREFIX"
sed -n 's/^Version: /  /p' "$PREFIX/lib/pkgconfig/gnutls.pc" | head -1

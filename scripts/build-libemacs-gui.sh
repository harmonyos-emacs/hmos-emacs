#!/bin/bash
# Link the Emacs objects into the native GUI shared library shipped in the
# HAP.  This is the app-side half of the G0 artifact.
#
# Internal build step (clean-build.sh links the GUI library).
#
# Usage:
#   ARCH=x86_64  scripts/build-libemacs-gui.sh
#   ARCH=aarch64 scripts/build-libemacs-gui.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
N=$CT/sdk/default/openharmony/native
ARCH=${ARCH:-x86_64}
BUILD=${BUILD:-$BUILD_ROOT/target/$ARCH}
SRC=$BUILD/src

case "$ARCH" in
  aarch64) ABI=arm64-v8a; TARGET=aarch64-linux-ohos ;;
  x86_64)  ABI=x86_64;    TARGET=x86_64-linux-ohos ;;
  *) echo "unsupported ARCH: $ARCH" >&2; exit 2 ;;
esac
TP=${DEPS_PREFIX:-$BUILD_ROOT/deps/$ABI}

ARCH=$ARCH "$REPO/scripts/build-ohos-render.sh" >/dev/null

cd "$SRC"
# All target dependencies (images, GnuTLS, libxml2, SQLite) share one prefix.
IMAGING=${IMAGING:-$TP}
IMAGING_LIBS=""
IMAGING_CFLAGS=""
if [ -f "$IMAGING/lib/libpng16.a" ]; then
  IMAGING_LIBS="-L$IMAGING/lib -lpng16 -lz"
  # The image headers are part of the build configuration, not a per-file
  # afterthought: CPATH makes them visible to every translation unit (the
  # Emacs build compiles image.c/ohosimage.c where they are needed).
  IMAGING_CFLAGS="-I$IMAGING/include -I$REPO/third_party/nanosvg"
  export CPATH="$IMAGING/include:$REPO/third_party/nanosvg${CPATH:+:$CPATH}"
fi
OBJS=$(ls *.o | tr '\n' ' ')
OUT=$REPO/app/entry/libs/$ABI/libemacs_gui.so
mkdir -p "$(dirname "$OUT")"

if [ "$ARCH" = x86_64 ]; then
  LINK_LIBS="-ltinfo -lnative_drawing -lnative_window -lnative_buffer -lhilog_ndk.z -lz -lm -ldl -lpthread -lohos_render -lc++_shared"
  LINK_DIRS="-L$BUILD/stubs -L$N/sysroot/usr/lib/$TARGET -L$REPO/app/entry/libs/$ABI -L$N/llvm/lib/$TARGET"
else
  # GnuTLS, libxml2 and SQLite are static archives; the group marker keeps
  # the mutual references between GnuTLS/nettle/hogweed/gmp resolvable
  # regardless of command-line order.  -lxml2 needs no zlib (built
  # --without-zlib), -lsqlite3 needs libc/libpthread only.
  LINK_LIBS="-Wl,--start-group -lgnutls -lunistring -lhogweed -lgmp -lnettle -ltasn1 -lxml2 -lsqlite3 -Wl,--end-group -lncurses -lnative_drawing -lnative_window -lnative_buffer -lhilog_ndk.z -lz -lm -ldl -lpthread -lohos_render -lc++_shared"
  LINK_DIRS="-L$TP/lib -L$IMAGING/lib -L$N/sysroot/usr/lib/$TARGET -L$REPO/app/entry/libs/$ABI -L$N/llvm/lib/$TARGET"
fi

"$N/llvm/bin/clang" --target="$TARGET" --sysroot="$N/sysroot" \
  -shared -fPIC -Wl,-soname,libemacs_gui.so -Wl,--no-undefined \
  -Wl,--version-script="$REPO/app/entry/src/main/cpp/libemacs_gui.map" \
  -Wl,--exclude-libs,ALL -Wl,-rpath,\$ORIGIN \
  -o "$OUT" $LINK_DIRS $OBJS ../lib/libgnu.a $IMAGING_LIBS $LINK_LIBS

# --no-undefined already forces a complete static closure; this check names
# the three features explicitly so a silently dropped -lxml2/-lsqlite3 or a
# GnuTLS dependency gap fails the build instead of the device.
UNDEF=$("$N/llvm/bin/llvm-nm" -u "$OUT" | awk '{print $2}' \
        | grep -E '^(xml|html|sqlite3_|gnutls_|nettle_|hogweed_|_gmp|__gmp|asn1_)' || true)
if [ -n "$UNDEF" ]; then
  echo "unresolved gnutls/libxml2/sqlite3 symbols in $OUT:" >&2
  echo "$UNDEF" >&2
  exit 1
fi

SHA=$(sha256sum "$OUT" | awk '{print $1}')
COMMIT=$(git -C "$REPO/emacs" rev-parse HEAD)
cat > "$(dirname "$OUT")/libemacs_gui.manifest.json" <<EOF
{
  "arch": "$ARCH",
  "abi": "$ABI",
  "source_commit": "$COMMIT",
  "build_tree": "$SRC",
  "object_count": $(ls "$SRC"/*.o | wc -l | tr -d ' '),
  "sha256": "$SHA"
}
EOF

echo "libemacs_gui.so: $OUT"
echo "manifest: $(dirname "$OUT")/libemacs_gui.manifest.json"

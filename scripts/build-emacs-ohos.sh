#!/bin/bash
# Cross-build GNU Emacs for HarmonyOS NEXT.
#
# Usage:
#   ARCH=aarch64 scripts/build-emacs-ohos.sh [--reconfigure]
#   ARCH=x86_64  scripts/build-emacs-ohos.sh [--reconfigure]
#
# Environment:
#   ARCH        aarch64 (default) or x86_64
#   BUILD       build tree; defaults to build/target/$ARCH
#   HOSTBUILD   native host-tools tree; defaults to build/host
#   BUILD_ROOT  build output root (see scripts/env.sh)
#   CT          command-line-tools root
#
# --reconfigure removes the build tree first.  build-manifest.json records
# the source commit, ABI, compiler and artifact hash needed by G0.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
N=$CT/sdk/default/openharmony/native
ARCH=${ARCH:-aarch64}
BUILD=${BUILD:-$BUILD_ROOT/target/$ARCH}
HOSTBUILD=${HOSTBUILD:-$BUILD_ROOT/host}
if [ ! -x "$HOSTBUILD/lib-src/make-docfile" ]; then
  echo "host tools incomplete in $HOSTBUILD (need make-docfile)" >&2
  exit 1
fi

case "$ARCH" in
  aarch64|x86_64) ;;
  *) echo "unsupported ARCH: $ARCH (use aarch64 or x86_64)" >&2; exit 2 ;;
esac

TARGET=$ARCH-linux-ohos
SYSROOT=$N/sysroot
case "$ARCH" in
  aarch64) ABI=arm64-v8a ;;
  x86_64)  ABI=x86_64 ;;
esac
BUILD_ID=$(date -u +%Y%m%dT%H%M%SZ)
SOURCE_COMMIT=$(git -C "$REPO/emacs" rev-parse HEAD)
SOURCE_DIRTY=$(git -C "$REPO/emacs" status --porcelain | wc -l | tr -d ' ')
CC="$N/llvm/bin/clang --target=$TARGET"
CFLAGS="--sysroot=$SYSROOT -O2 -fPIC"
TP=${DEPS_PREFIX:-$BUILD_ROOT/deps/$ABI}
CPPFLAGS="-I$TP/include -I$REPO/third_party/nanosvg"
LDFLAGS="--sysroot=$SYSROOT -L$TP/lib -L$REPO/app/entry/libs/$ABI -L$N/llvm/lib/$TARGET"
# The GUI backend draws glyphs through OH_Drawing; temacs must link the same
# system library as libemacs_gui.so (scripts/build-libemacs-gui.sh).
LIBS="-lnative_drawing -lnative_window -lnative_buffer -lhilog_ndk.z -lgnutls -lxml2 -lsqlite3 -lunistring -lhogweed -lgmp -lnettle -ltasn1 -lz -lm -lohos_render -lc++_shared"
CONFIGURE_ARGS=(
  --host="$TARGET" --build=x86_64-pc-linux-gnu
  --without-all --without-x --with-x-toolkit=no
  --without-toolkit-scroll-bars --without-tree-sitter
  --without-native-compilation --with-dumping=none
)

# Optional features that --without-all switches off but this port needs:
# GnuTLS (https without the deprecated tls.el), libxml2 (Eww HTML parsing)
# and SQLite (sqlite-open & friends).  libxml2/SQLite are built from the
# pinned archives in third_party/src by scripts/build-ohos-{libxml2,sqlite3}.sh.
if [ "$ARCH" = aarch64 ]; then
  for f in lib/libgnutls.a lib/libnettle.a lib/libhogweed.a lib/libgmp.a \
           lib/libtasn1.a lib/libunistring.a lib/libncurses.a \
           lib/libxml2.a lib/libsqlite3.a include/sqlite3.h \
           include/libxml2/libxml/HTMLparser.h; do
    [ -f "$TP/$f" ] || {
      echo "missing target dependency build/deps/$ABI/$f" >&2
      echo "run: scripts/clean-build.sh (it builds the dependency prefix first)" >&2
      exit 1
    }
  done
  CONFIGURE_ARGS+=(--with-gnutls --with-xml2 --with-sqlite3)

  # Give configure the target flags directly instead of asking the host
  # pkg-config.  pkg-config's `--exists gnutls' also resolves
  # Requires.private (nettle, hogweed, libtasn1, zlib), and the OHOS
  # sysroot ships no zlib.pc, so the module check would fail even though
  # the static library is present and libz is in the sysroot.  Passing
  # LIBGNUTLS_/LIBXML2_/SQLITE3_CFLAGS+LIBS is the supported pkg.m4
  # override for cross builds.
  GNUTLS_VER=$(sed -n 's/^Version: //p' "$TP/lib/pkgconfig/gnutls.pc" | head -1)
  python3 - "$GNUTLS_VER" <<'PY' || {
import sys
want = (2, 12, 2)
got = tuple(int(p) for p in (sys.argv[1].split('.') + ['0', '0'])[:3])
sys.exit(0 if got >= want else 1)
PY
    echo "GnuTLS $GNUTLS_VER is older than 2.12.2 (Emacs requirement)" >&2
    exit 1
  }
  export LIBGNUTLS_CFLAGS="-I$TP/include"
  export LIBGNUTLS_LIBS="-L$TP/lib -lgnutls"
  export LIBXML2_CFLAGS="-I$TP/include/libxml2"
  export LIBXML2_LIBS="-L$TP/lib -lxml2"
  export SQLITE3_CFLAGS="-I$TP/include"
  export SQLITE3_LIBS="-L$TP/lib -lsqlite3"
fi

if [ "$ARCH" = x86_64 ]; then
  # The x86_64 emulator PoC has no cross gnutls/gmp tree.  Use the
  # bundled terminfo stubs and skip optional TLS/modules/XML/SQLite.
  CONFIGURE_ARGS+=(--without-gnutls --without-modules --without-xml2 --without-sqlite3)
  LDFLAGS="--sysroot=$SYSROOT -L$BUILD/stubs"
  LIBS="-ltinfo -lnative_drawing -lnative_window -lnative_buffer -lhilog_ndk.z -lohos_render -lc++_shared"
  CPPFLAGS=""
fi

# Image decoders.  The sysroot only carries zlib, so PNG comes from the
# static libpng built by scripts/build-ohos-imaging.sh.  SVG is decoded by
# the vendored nanosvg in ohosimage.c and needs no configure switch; its
# header must still be on the include path for that translation unit.
if [ "${WITH_IMAGES:-0}" = 1 ]; then
  case "$ARCH" in
    aarch64) ABI=arm64-v8a ;;
    x86_64)  ABI=x86_64 ;;
  esac
  IMAGING=$TP
  if [ ! -f "$IMAGING/lib/libpng16.a" ] || [ ! -f "$IMAGING/include/png.h" ]; then
    echo "missing $IMAGING/lib/libpng16.a; run scripts/build-ohos-imaging.sh libpng $ABI" >&2
    exit 1
  fi
  CPPFLAGS="$CPPFLAGS -I$IMAGING/include -I$REPO/third_party/nanosvg"
  LDFLAGS="$LDFLAGS -L$IMAGING/lib"
  LIBS="$LIBS -lpng16 -lz"
  CONFIGURE_ARGS+=(--with-png --with-zlib)
fi

mkdir -p "$BUILD"
if [ "${1:-}" = "--reconfigure" ] || [ ! -f "$BUILD/config.status" ]; then
  rm -rf "${BUILD:?}"/*
  mkdir -p "$BUILD"
  if [ "$ARCH" = x86_64 ]; then
    mkdir -p "$BUILD/stubs"
    cat > "$BUILD/stubs/tinfo.c" <<'EOF'
#include <stdarg.h>
int tputs(const char *s, int n, int (*f)(int)) { (void)s;(void)n;(void)f; return 0; }
int tgetent(char *bp, const char *name) { (void)bp;(void)name; return 0; }
int tgetflag(const char *id) { (void)id; return 0; }
int tgetnum(const char *id) { (void)id; return 0; }
char *tgetstr(const char *id, char **area) { (void)id;(void)area; return 0; }
char *tgoto(const char *cap, int col, int row) { (void)cap;(void)col;(void)row; return 0; }
int tigetflag(const char *cap) { (void)cap; return -1; }
int tigetnum(const char *cap) { (void)cap; return -1; }
char *tigetstr(const char *cap) { (void)cap; return 0; }
char *tparm(const char *cap, ...) { (void)cap; return 0; }
char *UP;
char *BC;
char *PC;
EOF
    $CC --sysroot="$SYSROOT" -c "$BUILD/stubs/tinfo.c" -o "$BUILD/stubs/tinfo.o"
    $N/llvm/bin/llvm-ar rcs "$BUILD/stubs/libtinfo.a" "$BUILD/stubs/tinfo.o"
    cp "$BUILD/stubs/libtinfo.a" "$BUILD/stubs/libncurses.a"
  fi
  cd "$BUILD"
  export CC CFLAGS CPPFLAGS LDFLAGS LIBS
  # Target pkg-config prefixes only.  Without PKG_CONFIG_LIBDIR the host's
  # /usr/lib/*/pkgconfig would answer the gnutls/libxml2 checks, and the
  # cross link would then fail on host x86_64 paths.
  export PKG_CONFIG_PATH="$TP/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
  emacs_cv_terminfo_defines_BC=yes \
    "$REPO/emacs/configure" "${CONFIGURE_ARGS[@]}"

  # Contract check: --with-* must override --without-all, and the LIB*
  # variables must be non-empty.  Probe the configure output rather than
  # trusting the arguments.
  if [ "$ARCH" = aarch64 ]; then
    missing=""
    for define in HAVE_GNUTLS HAVE_LIBXML2 HAVE_SQLITE3; do
      grep -qE "^#define $define 1$" src/config.h || missing="$missing $define"
    done
    for var in LIBGNUTLS_LIBS LIBXML2_CFLAGS LIBXML2_LIBS SQLITE3_LIBS; do
      grep -qE "^$var = .+" src/Makefile || missing="$missing $var"
    done
    if [ -n "$missing" ]; then
      echo "configure did not enable:$missing" >&2
      grep -nE 'gnutls|libxml2|sqlite3' config.log | tail -30 >&2 || true
      exit 1
    fi
  fi
else
  cd "$BUILD"
fi
export CC CFLAGS CPPFLAGS LDFLAGS LIBS

# src/Makefile.in deliberately leaves LIBS out of LIBES, assuming configure
# moved every needed library into a LIB* variable.  This cross build passes
# the platform libraries (OH_Drawing, NativeWindow, GnuTLS, GMP, ...) through
# LIBS, and configure does not always mirror them.  Include LIBS explicitly
# for temacs so the target build links with the same set as libemacs_gui.so.
if ! grep -q '^LIBES = $(LIBS)' "$BUILD/src/Makefile"; then
  sed -i 's/^LIBES = /LIBES = $(LIBS) /' "$BUILD/src/Makefile"
fi

# configure only fills SQLITE3_CFLAGS for Android (ndk_SEARCH_MODULE); on a
# plain cross build the probe resets it to empty even though the header lives
# in the third-party prefix.  Record the include dir it was compiled against
# so src/Makefile and the manifest describe the real target flags.
if [ "$ARCH" = aarch64 ] && ! grep -qE '^SQLITE3_CFLAGS = .+' "$BUILD/src/Makefile"; then
  sed -i "s|^SQLITE3_CFLAGS = .*|SQLITE3_CFLAGS = -isystem $TP/include|" \
    "$BUILD/src/Makefile"
fi

if [ ! -x "$HOSTBUILD/lib-src/make-docfile" ]; then
  echo "missing host tools in $HOSTBUILD/lib-src; build build-host first" >&2
  exit 1
fi

make -C lib -j8
cp "$HOSTBUILD/lib-src/make-docfile" "$HOSTBUILD/lib-src/make-fingerprint" \
  "$BUILD/lib-src/"
touch "$BUILD/lib-src/make-docfile" "$BUILD/lib-src/make-fingerprint"

# Build the target temacs first.  Then replace bootstrap-emacs with the
# native host binary: Lisp compilation runs on the build machine, and the
# target binary cannot be executed there.
#
# configure sees -lgmp in LIBS, concludes the library is already linked,
# and leaves LIBGMP empty; src/Makefile then omits it from LIBES.  Pass
# LIBGMP explicitly so bignum.c links.  x86_64 uses gnulib mini-gmp.
MAKE_GMP=
[ "$ARCH" = aarch64 ] && MAKE_GMP="LIBGMP=-lgmp"
make -C src -j8 temacs $MAKE_GMP LIBS="$LIBS"
cp "$HOSTBUILD/src/bootstrap-emacs" "$BUILD/src/bootstrap-emacs"
chmod +x "$BUILD/src/bootstrap-emacs"
touch "$BUILD/src/bootstrap-emacs"
# The lisp Makefile invokes ../src/emacs for byte compilation.  On a
# dump-less cross build the target emacs is not produced until after
# Lisp is compiled, so seed that path with the host bootstrap binary.
cp -f "$HOSTBUILD/src/bootstrap-emacs" "$BUILD/src/emacs"
chmod +x "$BUILD/src/emacs"
touch "$BUILD/src/emacs"
if [ -f "$HOSTBUILD/src/bootstrap-emacs.pdmp" ]; then
  cp -f "$HOSTBUILD/src/bootstrap-emacs.pdmp" "$BUILD/src/bootstrap-emacs.pdmp"
  cp -f "$HOSTBUILD/src/bootstrap-emacs.pdmp" "$BUILD/src/emacs.pdmp"
  touch "$BUILD/src/bootstrap-emacs.pdmp" "$BUILD/src/emacs.pdmp"
fi
make -C src -j8 $MAKE_GMP LIBS="$LIBS"

TEMACS=$BUILD/src/temacs
if [ ! -f "$TEMACS" ]; then
  echo "temacs missing: $TEMACS" >&2
  exit 1
fi
TEMACS_SHA=$(sha256sum "$TEMACS" | awk '{print $1}')
CONFIGURE_JSON=$(printf '%s\n' "${CONFIGURE_ARGS[@]}" | sed 's/.*/"&",/' | tr -d '\n' | sed 's/,$//')

cat > "$BUILD/build-manifest.json" <<EOF
{
  "arch": "$ARCH",
  "target": "$TARGET",
  "build_id": "$BUILD_ID",
  "source_commit": "$SOURCE_COMMIT",
  "source_dirty_files": $SOURCE_DIRTY,
  "configure_args": [$CONFIGURE_JSON],
  "compiler": "$CC",
  "temacs_sha256": "$TEMACS_SHA"
}
EOF

echo "temacs: $TEMACS"
echo "manifest: $BUILD/build-manifest.json"

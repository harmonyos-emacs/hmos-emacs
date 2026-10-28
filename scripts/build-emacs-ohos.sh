#!/bin/bash
# Cross-build GNU Emacs for HarmonyOS NEXT (aarch64-linux-ohos).
#
# Layout:
#   emacs/            Emacs git checkout
#   build-ohos/       cross build tree (target)
#   build-host/       native x86_64 build tree, supplies host tools
#   /home/song/opt/ohos-deps   ncurses/gmp cross-built for OHOS
set -e

CT=${CT:-/home/song/Desktop/commandline-tools-linux-x64-26.0.0.851/command-line-tools}
N=$CT/sdk/default/openharmony/native
REPO=$(cd "$(dirname "$0")/.." && pwd)
DEPS=${OHOS_DEPS:-/home/song/opt/ohos-deps}
BUILD=$REPO/build-ohos
HOSTBUILD=$REPO/build-host

export PATH=/home/song/opt/texinfo/bin:/home/song/opt/autoconf/bin:$PATH
export CC="$N/llvm/bin/clang --target=aarch64-linux-ohos"
export CFLAGS="--sysroot=$N/sysroot -O2 -fPIC"
export LDFLAGS="--sysroot=$N/sysroot -L$DEPS/lib"
export CPPFLAGS="-I$DEPS/include"
export LIBS="-lgnutls -lunistring -lhogweed -lgmp -lnettle -ltasn1 -lz"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$PKG_CONFIG_PATH"

mkdir -p "$BUILD"
cd "$BUILD"

if [ ! -f config.status ] || [ "$1" = "--reconfigure" ]; then
  rm -rf "$BUILD"/*
  emacs_cv_terminfo_defines_BC=yes \
  "$REPO/emacs/configure" --host=aarch64-linux-ohos --build=x86_64-pc-linux-gnu \
    --without-all --without-x --with-x-toolkit=no --with-gnutls \
    --without-xml2 --without-tree-sitter --without-native-compilation \
    > /tmp/ohos-conf.log 2>&1
fi

# Host tools must run on the build machine, not the device.  Copy them
# after lib/libgnu.a is final so make does not rebuild them with the
# cross compiler.
make -C lib -j8
cp "$HOSTBUILD/lib-src/make-docfile" "$HOSTBUILD/lib-src/make-fingerprint" \
  "$BUILD/lib-src/"
touch "$BUILD/lib-src/make-docfile" "$BUILD/lib-src/make-fingerprint"

make -C src -j8

echo "temacs: $BUILD/src/temacs"

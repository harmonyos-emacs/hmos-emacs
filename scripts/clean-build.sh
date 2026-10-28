#!/bin/bash
# The single entry point for building the HarmonyOS Emacs port.
#
# Usage:
#   ARCH=aarch64 scripts/clean-build.sh
#   ARCH=aarch64 TARGET=<hdc-target> scripts/clean-build.sh --deploy
#
# Everything the build produces lives under build/ (see scripts/env.sh):
#
#   build/deps/<abi>      pinned target dependencies
#   build/host            native bootstrap tools
#   build/target/<arch>   Emacs configure/build tree
#   build/runtime/<arch>  assembled runtime stage
#
# The steps under scripts/build-*.sh are internal; run them through this
# script so the layout and ordering stay consistent.  Sources are pinned in
# third_party/versions.json and tracked under third_party/src: this build
# never downloads anything.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
ARCH=${ARCH:-aarch64}
BUILD=${BUILD:-$BUILD_ROOT/target/$ARCH}
HOSTBUILD=${HOSTBUILD:-$BUILD_ROOT/host}
RUNTIME_BUILD=${RUNTIME_BUILD:-$BUILD_ROOT/runtime/$ARCH}
TARGET=${TARGET:-}
DO_DEPLOY=0

case "${1:-}" in
  --deploy) DO_DEPLOY=1 ;;
  --build-only|"") ;;
  *) echo "usage: $0 [--deploy|--build-only]" >&2; exit 2 ;;
esac

case "$ARCH" in
  aarch64) ABI=arm64-v8a ;;
  x86_64)  ABI=x86_64 ;;
  *) echo "unsupported ARCH: $ARCH" >&2; exit 2 ;;
esac

cd "$REPO"

# The worktree must carry the Emacs submodule.  Git worktrees may have an
# empty submodule directory until it is initialized.
[ -e emacs/configure ] || [ -f emacs/autogen.sh ] \
  || { echo "missing emacs submodule; run git submodule update --init" >&2; exit 1; }

if [ ! -x "$REPO/emacs/configure" ] \
   || [ "$REPO/emacs/configure.ac" -nt "$REPO/emacs/configure" ] \
   || find "$REPO/emacs/m4" -newer "$REPO/emacs/configure" -print -quit | grep -q .; then
  echo "== generate emacs/configure"
  ( cd emacs && ./autogen.sh )
fi

# Generated Lisp artifacts are ignored by git but can carry absolute load
# paths from another worktree.  A clean build must not reuse them.
echo "== clean generated Lisp artifacts"
find "$REPO/emacs/lisp" -name '*.elc' -delete
rm -f "$REPO/emacs/lisp/loaddefs.el"

scripts/preflight.sh --build-only

echo "== build host tools ($HOSTBUILD)"
HOSTBUILD="$HOSTBUILD" scripts/build-host-tools.sh --reconfigure

# Target dependencies: GnuTLS chain + PNG + libxml2 + SQLite, all from the
# pinned archives and installed into build/deps/<abi>.  The x86_64 emulator
# PoC uses stubs and only needs libpng.
echo "== build target dependencies"
if [ "$ARCH" = aarch64 ]; then
  ARCH="$ARCH" scripts/build-ohos-deps.sh "$ABI"
  ARCH="$ARCH" scripts/build-ohos-libxml2.sh "$ABI"
  ARCH="$ARCH" scripts/build-ohos-sqlite3.sh "$ABI"
fi
ARCH="$ARCH" scripts/build-ohos-imaging.sh libpng "$ABI"
scripts/preflight.sh --deps

# The renderer archive must exist before configure: build-emacs-ohos.sh puts
# -lohos_render on the compiler command line.
echo "== build renderer"
ARCH="$ARCH" scripts/build-ohos-render.sh

echo "== configure and build Emacs ($BUILD)"
HOSTBUILD="$HOSTBUILD" ARCH="$ARCH" BUILD="$BUILD" WITH_IMAGES=1 \
  scripts/build-emacs-ohos.sh --reconfigure

echo "== link libemacs_gui.so"
ARCH="$ARCH" BUILD="$BUILD" scripts/build-libemacs-gui.sh

# The runtime is assembled from this checkout; no externally installed Emacs
# tree is required.  Do not reuse a tarball from another source revision: its
# Lisp may not match the freshly built libemacs_gui.so.
echo "== assemble runtime ($RUNTIME_BUILD)"
ARCH="$ARCH" scripts/build-runtime-stage.sh "$ARCH"
echo "== pack runtime"
ARCH="$ARCH" scripts/pack-runtime.sh "$RUNTIME_BUILD"
echo "== write build manifest"
ARCH="$ARCH" BUILD="$BUILD" scripts/write-build-manifest.sh "$BUILD"

if [ "$DO_DEPLOY" = 1 ]; then
  [ -n "$TARGET" ] || { echo "TARGET is required for --deploy" >&2; exit 1; }
  echo "== build debug app"
  ARCH="$ARCH" "$REPO/scripts/build-debug-app.sh"
  echo "== deploy"
  ARCH="$ARCH" TARGET="$TARGET" "$REPO/scripts/deploy.sh"
fi

echo "clean build complete: $BUILD"

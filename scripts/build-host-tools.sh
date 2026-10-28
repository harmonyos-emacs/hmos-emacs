#!/bin/bash
# Build the native host tools (bootstrap-emacs, make-docfile,
# make-fingerprint) from the current Emacs source tree.  Cross builds must
# not reuse tools built from a different checkout.
#
# Usage: scripts/build-host-tools.sh
#   HOSTBUILD defaults to build/host (see scripts/env.sh).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
HOSTBUILD=${HOSTBUILD:-$BUILD_ROOT/host}
RECONFIGURE=0
case "${1:-}" in
  --reconfigure) RECONFIGURE=1 ;;
  "" ) ;;
  *) echo "usage: $0 [--reconfigure]" >&2; exit 2 ;;
esac

# A clean build must not use a configure generated from older m4 sources.
if [ ! -x "$REPO/emacs/configure" ] \
   || [ "$REPO/emacs/configure.ac" -nt "$REPO/emacs/configure" ] \
   || find "$REPO/emacs/m4" -newer "$REPO/emacs/configure" -print -quit | grep -q .; then
  ( cd "$REPO/emacs" && ./autogen.sh )
fi

if [ "$RECONFIGURE" = 1 ]; then
  rm -rf "$HOSTBUILD"
fi
mkdir -p "$HOSTBUILD"
cd "$HOSTBUILD"
if [ ! -f config.status ]; then
  "$REPO/emacs/configure" --without-all --without-x \
    --with-x-toolkit=no --without-gnutls --without-xml2 \
    --without-tree-sitter --without-native-compilation
fi
make -C lib -j8
make -C src -j8 bootstrap-emacs
make -C src -j8 bootstrap-emacs.pdmp
make -C lib-src -j8 make-docfile make-fingerprint
echo "host tools: $HOSTBUILD"

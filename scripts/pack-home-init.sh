#!/bin/bash
# Pack the shipped HOME configuration (init file + CA bundle) into the rawfile
# asset installed on first launch.  The tarball itself is a build artifact and
# is not tracked by git; edit app/home-init/ and re-run this script.
set -e

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=$REPO/app/home-init
OUT=$REPO/app/entry/src/main/resources/rawfile/home-init.tar.gz

for f in home/.emacs etc/ssl/ca-bundle.crt; do
  if [ ! -f "$SRC/$f" ]; then
    echo "missing $SRC/$f" >&2
    exit 1
  fi
done

tar czf "$OUT" -C "$SRC" home etc
echo "home-init.tar.gz: $OUT"

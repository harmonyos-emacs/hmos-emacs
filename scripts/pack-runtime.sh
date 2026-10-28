#!/bin/bash
# Pack the Emacs Lisp/leim/etc/terminfo tree that ships inside the HAP as
# rawfile/emacs-runtime.tar.gz.  The tarball is a build artifact and is not
# tracked by git.
#
# Usage: scripts/pack-runtime.sh [STAGE_DIR]
#   STAGE_DIR defaults to /home/song/opt/ohos-runtime (the installed tree made
#   by build-emacs-ohos.sh + make install).  It must contain lisp/, leim/,
#   etc/ and terminfo/.
set -e

REPO=$(cd "$(dirname "$0")/.." && pwd)
STAGE=${1:-/home/song/opt/ohos-runtime}
OUT=$REPO/app/entry/src/main/resources/rawfile/emacs-runtime.tar.gz

for d in lisp leim etc terminfo; do
  if [ ! -d "$STAGE/$d" ]; then
    echo "missing $STAGE/$d" >&2
    exit 1
  fi
done

# Drop stale compiled files so the pack always reflects the staged tree.
tar czf "$OUT" -C "$STAGE" lisp leim etc terminfo
echo "emacs-runtime.tar.gz: $OUT ($(du -h "$OUT" | cut -f1))"

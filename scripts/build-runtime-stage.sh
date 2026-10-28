#!/bin/bash
# Internal build step: assemble the runtime tree from this checkout.
#
# The runtime is lisp/ + leim/ + etc/ of the current Emacs source tree (the
# byte-compiled .elc files are generated there during the Emacs build).  No
# externally installed Emacs tree is needed.
#
# Usage: ARCH=aarch64 scripts/build-runtime-stage.sh [arch]
# Output: build/runtime/<arch> (override with RUNTIME_BUILD)
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
ARCH=${1:-${ARCH:-aarch64}}
STAGE=${RUNTIME_BUILD:-$BUILD_ROOT/runtime/$ARCH}

for d in lisp leim etc; do
  [ -d "$REPO/emacs/$d" ] || { echo "missing emacs/$d" >&2; exit 1; }
done

rm -rf "$STAGE"
mkdir -p "$STAGE"
for d in lisp leim etc; do
  cp -a "$REPO/emacs/$d" "$STAGE/$d"
done

echo "runtime stage: $STAGE"

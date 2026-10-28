#!/bin/bash
# Pack the Emacs Lisp/leim/etc tree that ships inside the HAP as
# rawfile/emacs-runtime.tar.gz, together with an immutable manifest.
#
# Internal build step: clean-build.sh assembles the stage with
# scripts/build-runtime-stage.sh and then calls this script.
#
# Usage: scripts/pack-runtime.sh [STAGE_DIR]
#   STAGE_DIR defaults to build/runtime/<arch>; it must contain
#   lisp/, leim/ and etc/.
#
# Environment:
#   ARCH      target ABI recorded in the manifest (default: x86_64)
#   BUILD_ID  optional build id; defaults to the Emacs source commit
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
ARCH=${ARCH:-x86_64}
STAGE=${1:-$BUILD_ROOT/runtime/$ARCH}
OUT=$REPO/app/entry/src/main/resources/rawfile/emacs-runtime.tar.gz
MANIFEST=$REPO/app/entry/src/main/resources/rawfile/emacs-runtime.manifest.json
SOURCE_COMMIT=$(git -C "$REPO/emacs" rev-parse HEAD)
SOURCE_DIRTY=$(git -C "$REPO/emacs" status --porcelain | wc -l | tr -d ' ')
# Keep metadata stable for the same source tree; callers can override it.
BUILD_ID=${BUILD_ID:-${SOURCE_DATE_EPOCH:-$SOURCE_COMMIT}}

for d in lisp leim etc; do
  if [ ! -d "$STAGE/$d" ]; then
    echo "missing $STAGE/$d" >&2
    exit 1
  fi
done

# Overlay the backend Lisp files that live in the Emacs source tree so the
# packed runtime always matches the current checkout.  If the stage is not
# writable, build a hard-linked view of it first and overlay that instead.
OVERLAY_FILES="lisp/term/ohos-win.el lisp/menu-bar.el lisp/loadup.el lisp/frame.el lisp/faces.el"
if [ ! -w "$STAGE/lisp/term" ]; then
  CACHE=$BUILD_ROOT/cache/runtime-stage
  rm -rf "$CACHE"
  mkdir -p "$CACHE"
  cp -al "$STAGE"/. "$CACHE"/ 2>/dev/null || cp -a "$STAGE"/. "$CACHE"/
  STAGE=$CACHE
fi
for f in $OVERLAY_FILES; do
  if [ -f "$REPO/emacs/$f" ]; then
    rm -f "$STAGE/$f" "$STAGE/$f"c
    cp -f "$REPO/emacs/$f" "$STAGE/$f"
  fi
done

# Generated autoload files (*loaddefs.el) record the load path they were
# produced with.  When the runtime is packed from the source tree those are
# host paths such as
#   (autoload 'cl-coerce "../.worktrees/task-02/emacs/lisp/emacs-lisp/cl-extra")
# which do not exist on the device: `require` then fails with
#   Eager macro-expansion failure: (file-missing "Cannot open load file" ...)
# and Emacs aborts startup.  Rewrite them so they are resolved against
# EMACSLOADPATH instead.  Clean stages are unaffected (nothing matches).
find "$STAGE/lisp" -name '*loaddefs.el' -print0 2>/dev/null \
  | xargs -0 -r sed -i -E 's#"([^"]*/)?\.worktrees/[^/"]*/emacs/lisp/#"#g'

# GnuTLS trusts only the bundle shipped with the HAP (the sandbox has no
# system store).  Ship it in the runtime etc/ tree, which is what
# $HOME/../etc/ssl/ca-bundle.crt resolves to.
CA_BUNDLE=$REPO/app/certs/ca-bundle.crt
if [ -f "$CA_BUNDLE" ]; then
  mkdir -p "$STAGE/etc/ssl"
  cp -f "$CA_BUNDLE" "$STAGE/etc/ssl/ca-bundle.crt"
fi

# Normalize tar metadata and gzip header so the same staged tree produces the
# same archive bytes on repeated clean builds.
tar -cf - --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 \
    --numeric-owner -C "$STAGE" lisp leim etc \
  | gzip -n > "$OUT"
RUNTIME_SHA=$(sha256sum "$OUT" | awk '{print $1}')
RUNTIME_SIZE=$(stat -c '%s' "$OUT")
STAGE_REAL=$(cd "$STAGE" && pwd)

cat > "$MANIFEST" <<EOF
{
  "arch": "$ARCH",
  "build_id": "$BUILD_ID",
  "source_commit": "$SOURCE_COMMIT",
  "source_dirty_files": $SOURCE_DIRTY,
  "runtime_sha256": "$RUNTIME_SHA",
  "runtime_bytes": $RUNTIME_SIZE,
  "stage_dir": "$STAGE_REAL",
  "entries": ["lisp", "leim", "etc"]
}
EOF

echo "emacs-runtime.tar.gz: $OUT ($(du -h "$OUT" | cut -f1))"
echo "manifest: $MANIFEST"

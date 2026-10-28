#!/bin/bash
# Structural checks for the per-frame renderer architecture.
#
#   * the old draw command protocol is gone
#   * renderer state lives in renderer/, not in the host or entry library
#   * libentry.so does not include renderer headers
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "check-per-frame: $*" >&2; exit 1; }

hits=$(grep -R -n -E \
  'ohos_draw_command|ohos_draw_opcode|OHOS_DRAW_BATCH|draw_batch|ohos_queue_draw|ohos_render_submit|ohos_render_notify_surface|ohos_render_pending|gpu_direct' \
  "$REPO/emacs/src" "$REPO/renderer" "$REPO/app/entry/src/main/cpp" \
  --exclude-dir=build 2>/dev/null || true)
[ -z "$hits" ] || fail "legacy draw protocol still present:
$hits"

if [ -d "$REPO/renderer" ]; then
  for src in renderer.cpp surface.cpp present.cpp; do
    [ -f "$REPO/renderer/$src" ] || fail "missing renderer/$src"
  done
fi

if grep -R -n 'ohos_render.h\|renderer_internal.h' \
     "$REPO/app/entry/src/main/cpp" 2>/dev/null | grep -v build; then
  fail "libentry sources must not include renderer headers"
fi

echo "check-per-frame: ok"

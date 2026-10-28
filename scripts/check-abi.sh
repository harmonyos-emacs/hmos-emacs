#!/bin/bash
# Assert the OHOS GUI ABI surfaces of the two shared libraries.
#
#   libemacs_gui.so : exports exactly ohos_emacs_api
#   libentry.so     : exports only RegisterEmacsModule, no ohos_* symbols
#   libemacs_gui.so : has no undefined host symbols
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
NM=${NM:-$CT/sdk/default/openharmony/native/llvm/bin/llvm-nm}
ABI=${ARCH:-arm64-v8a}
GUI=${GUI:-$REPO/app/entry/libs/$ABI/libemacs_gui.so}
ENTRY=${ENTRY:-$REPO/app/entry/build/default/intermediates/cmake/default/obj/$ABI/libentry.so}

fail() { echo "check-abi: $*" >&2; exit 1; }

[ -f "$GUI" ] || fail "missing $GUI (run scripts/build-libemacs-gui.sh)"
[ -f "$ENTRY" ] || fail "missing $ENTRY (run scripts/build-debug-app.sh once)"

gui_exports=$("$NM" -D --defined-only "$GUI" | awk '$2=="T"||$2=="W"{print $3}')
[ "$gui_exports" = "ohos_emacs_api" ] \
  || fail "libemacs_gui.so must export only ohos_emacs_api, got: $gui_exports"

if "$NM" -D --defined-only "$ENTRY" | awk '{print $3}' | grep -q '^ohos'; then
  fail "libentry.so still exports ohos_* symbols"
fi

# The renderer archive is linked into libemacs_gui.so.  Any undefined
# ohos_* symbol means the host ABI or the renderer was not fully linked.
if "$NM" -D -u "$GUI" | awk '{print $3}' | grep '^ohos'; then
  fail "libemacs_gui.so has undefined host symbols"
fi

echo "check-abi: ok ($GUI, $ENTRY)"

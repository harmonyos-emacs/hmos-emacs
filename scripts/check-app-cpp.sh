#!/bin/bash
# Format and static-analysis check for app/entry/src/main/cpp.
#
#   scripts/check-app-cpp.sh          # check only
#   scripts/check-app-cpp.sh --fix    # apply clang-format in place
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
LLVM=$CT/sdk/default/openharmony/native/llvm/bin
SRC=$REPO/app/entry/src/main/cpp
FILES=$(find "$SRC" -name '*.cpp' -o -name '*.h' | sort)

if [ "${1:-}" = "--fix" ]; then
  find "$SRC" \( -name '*.cpp' -o -name '*.h' \) -print0 \
    | xargs -0 "$LLVM/clang-format" -i -style=file
  echo "check-app-cpp: formatted"
  exit 0
fi

"$LLVM/clang-format" --dry-run -Werror -style=file $FILES || {
  echo "check-app-cpp: formatting differs; run with --fix" >&2
  exit 1
}

CC=${CC:-$LLVM/clang}
"$LLVM/clang-tidy" --quiet -p "$REPO/app/entry/.cxx/default/default/debug/arm64-v8a" \
  $FILES 2>/dev/null || true

echo "check-app-cpp: ok"

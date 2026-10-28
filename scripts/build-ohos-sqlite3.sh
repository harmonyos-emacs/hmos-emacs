#!/bin/bash
# Cross-build the static SQLite (amalgamation) that Emacs uses for
# sqlite-open / sqlite-execute / sqlite-select.
#
# Source pinning lives in third_party/versions.json (version + url + sha256)
# and the archive is tracked under third_party/src.  This script is offline:
# a missing archive is an error, never a download.
#
#   scripts/build-ohos-sqlite3.sh [abi]
#   ABI=arm64-v8a scripts/build-ohos-sqlite3.sh
#
# Output: build/deps/<abi>/{include/sqlite3.h,lib/libsqlite3.a}
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"
TP=$ROOT/third_party
SDK=${OHOS_SDK:-$CT/sdk/default/openharmony}
LLVM=$SDK/native/llvm/bin
SYSROOT=$SDK/native/sysroot

ABI=${1:-${ABI:-arm64-v8a}}
case $ABI in
  arm64-v8a) TRIPLE=aarch64-linux-ohos ;;
  x86_64)    TRIPLE=x86_64-linux-ohos ;;
  *) echo "unsupported abi: $ABI" >&2; exit 2 ;;
esac
PREFIX=${DEPS_PREFIX:-$BUILD_ROOT/deps/$ABI}
SRC=$TP/src
WORK=$TP/build

meta () { python3 - "$TP/versions.json" "$1" "$2" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])
PY
}

URL=$(meta sqlite3 url)
SHA=$(meta sqlite3 sha256)
VER=$(meta sqlite3 version)
ARCHIVE=$SRC/${URL##*/}
DIR=$WORK/${ARCHIVE##*/}
DIR=${DIR%.zip}

[ -f "$ARCHIVE" ] || {
  echo "missing tracked sqlite amalgamation $ARCHIVE" >&2
  echo "this build is offline: restore it from git (third_party/src)" >&2
  exit 1
}
echo "$SHA  $ARCHIVE" | sha256sum -c - >/dev/null || {
  echo "sqlite3: checksum mismatch for ${URL##*/} (want $SHA)" >&2
  exit 1
}

if [ ! -d "$DIR" ]; then
  echo "== unpack ${URL##*/}"
  mkdir -p "$WORK"
  unzip -q -o "$ARCHIVE" -d "$WORK"
fi
[ -f "$DIR/sqlite3.c" ] || { echo "sqlite3.c missing in $DIR" >&2; exit 1; }

# Fixed compile-time configuration.  Keep this list in versions.json
# (compile_flags) so the manifest can report it: threads on, FTS5/RTREE and
# column metadata on, loadable-extension loading off (this build has no
# dynamic Emacs modules, and the app should not dlopen arbitrary code).
read -r -a FLAGS <<<"$(python3 - "$TP/versions.json" <<'PY'
import json, sys
print(" ".join(json.load(open(sys.argv[1]))["sqlite3"]["compile_flags"]))
PY
)"

OBJ=$DIR/sqlite3-ohos-$ABI.o
echo "== compile sqlite3 $VER for $TRIPLE"
"$LLVM/clang" --target="$TRIPLE" --sysroot="$SYSROOT" \
  -O2 -fPIC -std=c11 "${FLAGS[@]}" -c "$DIR/sqlite3.c" -o "$OBJ"

mkdir -p "$PREFIX/include" "$PREFIX/lib" "$WORK"
"$LLVM/llvm-ar" rcs "$PREFIX/lib/libsqlite3.a" "$OBJ"
cp "$DIR/sqlite3.h" "$PREFIX/include/sqlite3.h"
[ -f "$DIR/sqlite3ext.h" ] && cp "$DIR/sqlite3ext.h" "$PREFIX/include/sqlite3ext.h"

echo "SQLite $VER installed to $PREFIX"
ls -l "$PREFIX/lib/libsqlite3.a" "$PREFIX/include/sqlite3.h"

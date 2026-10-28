#!/bin/bash
# Check the inputs required for a reproducible clean build.
#
#   scripts/preflight.sh --build-only   host tools + pinned archives
#   scripts/preflight.sh --deps         + installed target dependency prefix
#   scripts/preflight.sh --deploy       + debug signing material and device target
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/env.sh

CHECK_DEPLOY=0
CHECK_DEPS=0
case "${1:-}" in
  --deploy) CHECK_DEPLOY=1 ;;
  --deps) CHECK_DEPS=1 ;;
  ""|--build-only) ;;
  *) echo "usage: $0 [--build-only|--deps|--deploy]" >&2; exit 2 ;;
esac

fail=0
ok() { printf '[ OK ] %s\n' "$1"; }
miss() { printf '[MISS] %s\n' "$1"; fail=1; }

check_dir() { if [ -d "$1" ]; then ok "$2"; else miss "$2 ($1)"; fi; }
check_file() { if [ -f "$1" ]; then ok "$2"; else miss "$2 ($1)"; fi; }
check_exec() { if [ -x "$1" ]; then ok "$2"; else miss "$2 ($1)"; fi; }
check_tool() {
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; else miss "$1"; fi
}

printf '== repository\n'
check_file "$REPO/.gitmodules" ".gitmodules"
if [ -f "$REPO/emacs/configure.ac" ] || [ -f "$REPO/emacs/autogen.sh" ]; then
  ok "emacs submodule"
else
  miss "emacs submodule"
fi

printf '== HarmonyOS SDK\n'
check_dir "$CT" "command-line-tools ($CT)"
check_dir "${OHOS_SDK:-}" "OHOS SDK ($OHOS_SDK)"
check_exec "$HDC" "hdc"
check_exec "${OHOS_SDK:-}/native/llvm/bin/clang" "target clang"
check_exec "${OHOS_SDK:-}/native/llvm/bin/llvm-ar" "llvm-ar"
check_file "${OHOS_SDK:-}/native/sysroot/usr/include/stdio.h" "target sysroot"
check_exec "${CT:-}/bin/hvigorw" "hvigorw"
check_exec "${CT:-}/bin/ohpm" "ohpm"

SDK_API=$(python3 - "${OHOS_SDK:-}/sdk-pkg.json" "${OHOS_SDK:-}/../sdk-pkg.json" <<'PY2' 2>/dev/null || true
import json, sys
for p in sys.argv[1:]:
    try:
        print(json.load(open(p))["data"]["apiVersion"])
        break
    except Exception:
        pass
PY2
)
if [ -n "$SDK_API" ] && [ "$SDK_API" -ge 20 ] 2>/dev/null; then
  ok "SDK API $SDK_API (need >= 20)"
else
  miss "SDK API >= 20 (got '${SDK_API:-unknown}')"
fi

# The host toolchain drives the dependency builds and builds the native
# bootstrap tools; HOST_SYSROOT is not needed (system headers/libraries).
printf '== host tools\n'
for t in cc make autoconf m4 pkg-config makeinfo python3 tar gzip xz unzip \
         sha256sum git patch; do
  check_tool "$t"
done
if printf '#include <term.h>\n' | "${CC:-cc}" -E - >/dev/null 2>&1; then
  ok "host terminfo headers (ncurses)"
else
  miss "host terminfo headers (install ncurses/libtinfo development files)"
fi
check_exec "$JAVA_HOME/bin/java" "Java 17 ($JAVA_HOME)"

printf '== pinned archives (third_party/versions.json)\n'
while IFS='|' read -r name path sha; do
  if [ -f "$REPO/$path" ]; then
    if [ "$(sha256sum "$REPO/$path" | awk '{print $1}')" = "$sha" ]; then
      ok "$name archive"
    else
      miss "$name archive checksum ($path)"
    fi
  else
    miss "$name archive ($path)"
  fi
done < <(python3 - third_party/versions.json <<'PY2'
import json, sys
for name, entry in json.load(open(sys.argv[1])).items():
    if not isinstance(entry, dict):
        continue
    url = entry.get("url")
    sha = entry.get("sha256")
    if not url or not isinstance(sha, str):
        continue
    print("|".join((name, "third_party/src/" + url.rsplit("/", 1)[-1], sha)))
PY2
)

# --deps runs after clean-build.sh has built the target dependencies.
if [ "$CHECK_DEPS" = 1 ]; then
  printf '== target dependency prefix\n'
  case "${ARCH:-aarch64}" in
    aarch64) ABI=arm64-v8a ;;
    x86_64)  ABI=x86_64 ;;
    *) ABI=${ABI:-arm64-v8a} ;;
  esac
  PREFIX=${DEPS_PREFIX:-$BUILD_ROOT/deps/$ABI}
  check_dir "$PREFIX" "dependency prefix ($PREFIX)"
  DEPS_FILES="include/png.h lib/libpng16.a"
  if [ "$ABI" = arm64-v8a ]; then
    DEPS_FILES="$DEPS_FILES
      include/libxml2/libxml/HTMLparser.h lib/libxml2.a
      include/sqlite3.h lib/libsqlite3.a
      include/gnutls/gnutls.h lib/libgnutls.a
      include/nettle/nettle-meta.h lib/libnettle.a lib/libhogweed.a
      include/gmp.h lib/libgmp.a
      include/libtasn1.h lib/libtasn1.a
      include/unistring/version.h lib/libunistring.a
      include/curses.h lib/libncurses.a"
  fi
  for f in $DEPS_FILES; do
    check_file "$PREFIX/$f" "$ABI/$f"
  done
  if [ "$ABI" = arm64-v8a ]; then

  # Compare the installed versions with the pins.  Components without a
  # pkg-config file (libunistring, ncurses) are covered by the file checks.
  while IFS='|' read -r name pc; do
    [ -n "$pc" ] || continue
    pcf=$PREFIX/lib/pkgconfig/$pc.pc
    if [ ! -f "$pcf" ]; then
      miss "$name pkg-config ($pc.pc)"
      continue
    fi
    got=$(sed -n 's/^Version: //p' "$pcf" | head -1)
    want=$(python3 - third_party/versions.json "$name" <<'PY2'
import json, sys
print(json.load(open(sys.argv[1]))[sys.argv[2]]["version"])
PY2
)
    if [ "$got" = "$want" ]; then
      ok "$name version ($got)"
    else
      miss "$name version (want $want, got ${got:-none})"
    fi
  done <<'EOF'
libpng|libpng16
libxml2|libxml-2.0
gnutls|gnutls
nettle|nettle
gmp|gmp
libtasn1|libtasn1
EOF

  GOT_SQLITE=$(sed -n 's/^#define SQLITE_VERSION *"\(.*\)"/\1/p' \
    "$PREFIX/include/sqlite3.h" 2>/dev/null | head -1)
  WANT_SQLITE=$(python3 - third_party/versions.json <<'PY2'
import json
print(json.load(open("third_party/versions.json"))["sqlite3"]["version"])
PY2
)
  if [ "$GOT_SQLITE" = "$WANT_SQLITE" ]; then
    ok "sqlite3 version ($GOT_SQLITE)"
  else
    miss "sqlite3 version (want $WANT_SQLITE, got ${GOT_SQLITE:-none})"
  fi
  fi
fi

if [ "$CHECK_DEPLOY" = 1 ]; then
  printf '== deploy\n'
  # Same resolver the debug build uses, so preflight cannot disagree with it.
  if [ -f "$REPO/scripts/lib/signing.sh" ]; then
    . "$REPO/scripts/lib/signing.sh"
    if signing_resolve debug 2>/dev/null; then
      ok "debug signing material (${SIGN_PROFILE##*/})"
    else
      miss "debug signing material (DEBUG_*; see docs/build-deploy.md)"
    fi
  else
    miss "scripts/lib/signing.sh"
  fi
  check_exec "$HDC" "hdc ($HDC)"
  if [ -n "${TARGET:-}" ]; then ok "device target ($TARGET)"; else miss "device target (TARGET)"; fi
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "preflight failed; install the missing host tools or restore the pinned archives" >&2
  exit 1
fi
echo
echo "preflight ok"

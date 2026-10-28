#!/bin/bash
# Install (or remove) an already-built HAP on the HarmonyOS device.
#
# This script does not build, sign or edit the app project: it only resolves
# which HAP to use, sanity-checks it against the current build and device, and
# installs it.  Build the package first with scripts/build-debug-app.sh
# (debug) or scripts/build-release-app.sh (AppGallery).
#
# Usage:
#   scripts/deploy.sh                          # install the latest debug HAP
#   scripts/deploy.sh --hap dist/foo.hap       # install an explicit HAP
#   scripts/deploy.sh --uninstall              # remove the app and its data
#   scripts/deploy.sh --uninstall --keep-data  # remove the app, keep data
#
# Options:
#   --hap FILE    install FILE instead of the default debug HAP
#   --arch ARCH   architecture of the HAP (default: aarch64)
#   --uninstall   uninstall the bundle instead of installing a HAP
#   --keep-data   with --uninstall, keep the application data (bm uninstall -k)
#   --no-start    install without launching the ability (and uninstall without
#                 the force-stop)
#   --force       install even when the HAP is stale or the ABI looks wrong
#   -h, --help    show this help
#
# Environment:
#   TARGET        hdc target, required
#   ARCH          architecture of the HAP (default: aarch64)
#   DIST          where the default HAP lives (default: <repo>/dist)
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
. "$REPO/scripts/lib/app-package.sh"

ARCH=${ARCH:-aarch64}
DIST=${DIST:-$REPO/dist}
BUNDLE=emacs.hmos.org
ABILITY=EntryAbility

HAP=
UNINSTALL=0
KEEP_DATA=0
START=1
FORCE=0

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^#\{1\} \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hap)       HAP=${2:?--hap requires a file}; shift 2 ;;
    --hap=*)     HAP=${1#*=}; shift ;;
    --arch)      ARCH=${2:?--arch requires a value}; shift 2 ;;
    --arch=*)    ARCH=${1#*=}; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --keep-data) KEEP_DATA=1; shift ;;
    --no-start)  START=0; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "deploy: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$UNINSTALL" = 1 ] && [ -n "$HAP" ]; then
  echo "deploy: --hap cannot be combined with --uninstall" >&2
  exit 2
fi
if [ "$KEEP_DATA" = 1 ] && [ "$UNINSTALL" != 1 ]; then
  echo "deploy: --keep-data is only meaningful with --uninstall" >&2
  exit 2
fi

: "${TARGET:?TARGET is required (set TARGET or OHOS_TARGET)}"
if [ -z "${HDC:-}" ] || [ ! -x "$HDC" ]; then
  echo "deploy: hdc not found (set CT or HDC)" >&2
  exit 2
fi

if [ "$UNINSTALL" = 1 ]; then
  if [ "$START" = 1 ]; then
    "$HDC" -t "$TARGET" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
  fi
  # bm uninstall drops the application data unless -k is given; there is no
  # separate data directory left behind to clean up.
  args=(bm uninstall -n "$BUNDLE")
  [ "$KEEP_DATA" = 1 ] && args+=(-k)
  OUT=$("$HDC" -t "$TARGET" shell "${args[@]}" 2>&1) || true
  printf '%s\n' "$OUT"
  if ! printf '%s' "$OUT" | grep -qi 'success'; then
    echo "deploy: uninstall of $BUNDLE failed" >&2
    exit 1
  fi
  if [ "$KEEP_DATA" = 1 ]; then
    echo "deploy: uninstalled $BUNDLE (data kept)"
  else
    echo "deploy: uninstalled $BUNDLE (data removed)"
  fi
  exit 0
fi

ABI=$(app_package_require_abi "$ARCH") || {
  echo "deploy: unsupported ARCH: $ARCH" >&2
  exit 2
}

if [ -z "$HAP" ]; then
  VERSION=$(app_package_version_name 2>/dev/null || true)
  if [ -n "$VERSION" ] && [ -f "$DIST/Homacs-$VERSION-debug-$ABI.hap" ]; then
    HAP=$DIST/Homacs-$VERSION-debug-$ABI.hap
  else
    HAP=$(ls -t "$DIST"/Homacs-*-debug-"$ABI".hap 2>/dev/null | head -1 || true)
  fi
fi
if [ -z "$HAP" ] || [ ! -f "$HAP" ]; then
  echo "deploy: no HAP for $ARCH in $DIST" >&2
  echo "deploy: run scripts/build-debug-app.sh, or pass --hap FILE" >&2
  if ls "$DIST"/*.hap >/dev/null 2>&1; then
    ls -1t "$DIST"/*.hap >&2
  fi
  exit 1
fi
HAP=$(cd "$(dirname "$HAP")" && pwd)/$(basename "$HAP")

# The sidecar written by build-*-app.sh records which build this package came
# from.  Use it to refuse the most expensive mistake of the old combined
# script: silently installing a HAP that no longer matches libemacs_gui.so or
# the source tree.
META=${HAP%.hap}.json
HAP_MODE=unknown
HAP_PROVISION=
HAP_REV=
HAP_LIB_SHA=
HAP_ABI=$ABI
if [ -f "$META" ]; then
  meta() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' \
      "$META" "$1"
  }
  HAP_MODE=$(meta mode)
  HAP_PROVISION=$(meta provision_type)
  HAP_REV=$(meta git_rev)
  HAP_LIB_SHA=$(meta libemacs_gui_sha256)
  HAP_ABI=$(meta abi)
  [ -n "$HAP_ABI" ] || HAP_ABI=$ABI
  [ -n "$HAP_PROVISION" ] || HAP_PROVISION=$HAP_MODE
else
  echo "deploy: warning: $META missing; cannot tell whether the HAP is stale" >&2
fi

STALE=
if [ -n "$HAP_LIB_SHA" ]; then
  LIB=$REPO/app/entry/libs/$HAP_ABI/libemacs_gui.so
  if [ -f "$LIB" ] && [ "$(sha256sum "$LIB" | awk '{print $1}')" != "$HAP_LIB_SHA" ]; then
    STALE="libemacs_gui.so changed since this HAP was built"
  fi
fi
if [ -n "$HAP_REV" ]; then
  HEAD_REV=$(git -C "$REPO" rev-parse HEAD)
  if [ "$HAP_REV" != "$HEAD_REV" ]; then
    STALE="${STALE:+$STALE; }source moved since this HAP was built (${HAP_REV:0:12} != ${HEAD_REV:0:12})"
  fi
fi
if [ -n "$STALE" ] && [ "$FORCE" != 1 ]; then
  echo "deploy: refusing to install a stale HAP: $STALE" >&2
  echo "deploy: rebuild with scripts/build-debug-app.sh, or pass --force" >&2
  exit 1
fi

DEVICE_ABIS=$("$HDC" -t "$TARGET" shell param get const.product.cpu.abilist 2>/dev/null \
  | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)
if [ -n "$DEVICE_ABIS" ]; then
  if ! printf '%s' "$DEVICE_ABIS" | tr ',' '\n' | tr -d ' ' | grep -qx "$HAP_ABI"; then
    if [ "$FORCE" != 1 ]; then
      echo "deploy: HAP ABI $HAP_ABI is not supported by the device ($DEVICE_ABIS)" >&2
      echo "deploy: build with ARCH=aarch64 for arm64 devices, or pass --force" >&2
      exit 1
    fi
    echo "deploy: warning: HAP ABI $HAP_ABI not in device abilist ($DEVICE_ABIS)" >&2
  fi
fi

# A HAP signed with a debug profile cannot replace an app installed from a
# release profile (and vice versa): the installer rejects it with 9568286
# "install provision type not same".  Detect it here and say what to do
# instead of letting the install fail with a bare error code.
INSTALLED_PROVISION=$("$HDC" -t "$TARGET" shell bm dump -n "$BUNDLE" 2>/dev/null \
  | tr -d '\r' | sed -n 's/.*"appProvisionType": "\([^"]*\)".*/\1/p' | head -1 || true)
if [ -n "$INSTALLED_PROVISION" ] && [ "$HAP_PROVISION" != unknown ] \
   && [ "$INSTALLED_PROVISION" != "$HAP_PROVISION" ]; then
  if [ "$FORCE" != 1 ]; then
    echo "deploy: installed $BUNDLE is a $INSTALLED_PROVISION build; this HAP is $HAP_PROVISION" >&2
    echo "deploy: uninstall it first: scripts/deploy.sh --uninstall [--keep-data]" >&2
    echo "deploy: (--keep-data keeps runtime/home; switching back needs another uninstall)" >&2
    exit 1
  fi
  echo "deploy: warning: provision type differs (installed $INSTALLED_PROVISION, HAP $HAP_PROVISION)" >&2
fi

printf 'deploy: %s (%s, %s, sha256 %s)\n' \
  "$(basename "$HAP")" "$HAP_MODE" "$HAP_ABI" \
  "$(sha256sum "$HAP" | awk '{print $1}')"

LOG=$(mktemp)
if ! "$HDC" -t "$TARGET" install "$HAP" >"$LOG" 2>&1; then
  cat "$LOG" >&2
  rm -f "$LOG"
  echo "deploy: install failed" >&2
  exit 1
fi
cat "$LOG"
if ! grep -qi 'success' "$LOG"; then
  rm -f "$LOG"
  echo "deploy: install did not report success" >&2
  exit 1
fi
rm -f "$LOG"

if [ "$START" = 1 ]; then
  "$HDC" -t "$TARGET" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
  if ! "$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a "$ABILITY"; then
    echo "deploy: installed but failed to start $BUNDLE" >&2
    exit 1
  fi
fi
echo "deploy: installed $BUNDLE"

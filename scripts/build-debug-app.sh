#!/bin/bash
# Build and sign a debug HAP for device deployment.  This script never talks
# to a device: it produces the signed package and its metadata sidecar, and
# scripts/deploy.sh installs it.
#
# Usage:
#   ARCH=aarch64 scripts/build-debug-app.sh [--force-runtime]
#
# Environment:
#   ARCH           target architecture (default: aarch64)
#   DIST           output directory (default: <repo>/dist)
#   FORCE_RUNTIME  1 = always reassemble the runtime tarball
#   DEBUG_*        signing material, see scripts/lib/signing.sh
#
# Output:
#   dist/Homacs-<versionName>-debug-<abi>.hap
#   dist/Homacs-<versionName>-debug-<abi>.json
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
. "$REPO/scripts/lib/signing.sh"
. "$REPO/scripts/lib/app-package.sh"

ARCH=${ARCH:-aarch64}
DIST=${DIST:-$REPO/dist}

case "${1:-}" in
  --force-runtime) FORCE_RUNTIME=1 ;;
  "") ;;
  *) echo "usage: $0 [--force-runtime]" >&2; exit 2 ;;
esac
if [ $# -gt 1 ]; then
  echo "usage: $0 [--force-runtime]" >&2
  exit 2
fi

ABI=$(app_package_require_abi "$ARCH") || exit 2

signing_resolve debug || exit 1
signing_describe
signing_check_profile debug || exit 1

app_package_build debug "$ARCH" || exit 1

VERSION=$(app_package_version_name) || exit 1
mkdir -p "$DIST"
SIGNED=$DIST/Homacs-$VERSION-debug-$ABI.hap
METADATA=${SIGNED%.hap}.json

signing_sign "$APP_PACKAGE_UNSIGNED_HAP" "$SIGNED"
signing_verify "$SIGNED" || exit 1
app_package_write_metadata debug "$ARCH" "$SIGNED" "$METADATA" || exit 1

printf 'debug hap: %s\n' "$SIGNED"
printf 'metadata:  %s\n' "$METADATA"
printf 'sha256:    %s\n' "$(signing_sha256 "$SIGNED")"

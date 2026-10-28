#!/bin/bash
# Build and sign the AppGallery .app package with the release certificate and
# an ACL-bearing release profile.  Nothing is installed on a device.
#
# Usage:
#   ARCH=aarch64 scripts/build-release-app.sh [--force-runtime]
#
# Environment:
#   DIST           output directory (default: <repo>/dist)
#   FORCE_RUNTIME  1 = always reassemble the runtime tarball
#   RELEASE_*      signing material, see scripts/lib/signing.sh
#
# Output:
#   dist/Homacs-<versionName>-release.hap (+ .json sidecar)
#   dist/Homacs-<versionName>-release.app
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

app_package_require_abi "$ARCH" >/dev/null || exit 2

signing_resolve release || exit 1
signing_describe
signing_check_profile release || exit 1

app_package_build release "$ARCH" || exit 1

VERSION=$(app_package_version_name) || exit 1
mkdir -p "$DIST"
SIGNED_HAP=$DIST/Homacs-$VERSION-release.hap
APP_OUT=$DIST/Homacs-$VERSION-release.app
APP_PACK_INFO=$APP_PACKAGE_APP/entry/build/default/outputs/default/pack.info
METADATA=$DIST/Homacs-$VERSION-release.json

[ -f "$APP_PACK_INFO" ] || { echo "missing $APP_PACK_INFO" >&2; exit 1; }

signing_sign "$APP_PACKAGE_UNSIGNED_HAP" "$SIGNED_HAP" -compatibleVersion 12
signing_verify "$SIGNED_HAP" "$DIST/hap.cer" "$DIST/hap.p7b" || exit 1

STAGE=$(mktemp -d)
cp "$SIGNED_HAP" "$STAGE/"
cp "$APP_PACK_INFO" "$STAGE/"
(cd "$STAGE" && zip -q -r "$APP_OUT" .)
rm -rf "$STAGE"

signing_sign "$APP_OUT" "$APP_OUT.signed" -inForm zip -compatibleVersion 12
mv "$APP_OUT.signed" "$APP_OUT"
signing_verify "$APP_OUT" "$DIST/app.cer" "$DIST/app.p7b" || exit 1

app_package_write_metadata release "$ARCH" "$SIGNED_HAP" "$METADATA" || exit 1

sha256sum "$APP_OUT" "$SIGNED_HAP"
printf 'release app: %s\n' "$APP_OUT"
printf 'release hap: %s\n' "$SIGNED_HAP"
printf 'metadata:    %s\n' "$METADATA"

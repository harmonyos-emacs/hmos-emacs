#!/bin/bash
# Packaging helpers shared by build-debug-app.sh and build-release-app.sh.
# Source this file; it defines functions only.
#
# Both build modes run the same pipeline:
#
#   ARCH -> abiFilters         (temporarily, restored on exit)
#   renderer static library
#   runtime tarball            (rebuilt when sources are newer, or FORCE_RUNTIME=1)
#   hvigor cache invalidation
#   hvigor assembleHap         (debug or release buildMode)
#
# Signing is not handled here; see scripts/lib/signing.sh.

[ -n "${APP_PACKAGE_SH_LOADED:-}" ] && return 0
APP_PACKAGE_SH_LOADED=1

APP_PACKAGE_APP=${APP_PACKAGE_APP:-$REPO/app}
APP_PACKAGE_RAW=$APP_PACKAGE_APP/entry/src/main/resources/rawfile
APP_PACKAGE_TARBALL=$APP_PACKAGE_RAW/emacs-runtime.tar.gz
APP_PACKAGE_RUNTIME_MANIFEST=$APP_PACKAGE_RAW/emacs-runtime.manifest.json
APP_PACKAGE_PROFILE=$APP_PACKAGE_APP/entry/build-profile.json5
APP_PACKAGE_UNSIGNED_HAP=$APP_PACKAGE_APP/entry/build/default/outputs/default/entry-default-unsigned.hap

app_package_log() {
  printf 'app: %s\n' "$*"
}

app_package_fail() {
  printf 'app: %s\n' "$*" >&2
  return 1
}

# app_package_abi ARCH -> ABI name used by entry/libs and abiFilters
app_package_abi() {
  case "${1:-}" in
    aarch64|arm64*) printf '%s' arm64-v8a ;;
    x86_64|x64)     printf '%s' x86_64 ;;
    *) return 1 ;;
  esac
}

app_package_require_abi() {
  local abi
  abi=$(app_package_abi "$1") || {
    app_package_fail "unsupported ARCH: ${1:-<empty>} (want aarch64 or x86_64)"
    return 1
  }
  printf '%s' "$abi"
}

# app_package_use_abi ARCH rewrites entry/build-profile.json5 and registers an
# EXIT/INT/TERM trap that restores the original file.  The profile stays a
# tracked, unmodified file in the worktree after every build.
app_package_use_abi() {
  local arch=${1:-} abi tmp
  abi=$(app_package_require_abi "$arch") || return 1
  APP_PACKAGE_ARCH=$arch
  APP_PACKAGE_ABI=$abi

  [ -f "$APP_PACKAGE_PROFILE" ] || {
    app_package_fail "missing $APP_PACKAGE_PROFILE"
    return 1
  }

  tmp=$(mktemp)
  cp -p "$APP_PACKAGE_PROFILE" "$tmp"
  APP_PACKAGE_PROFILE_BACKUP=$tmp

  if ! python3 - "$APP_PACKAGE_PROFILE" "$abi" <<'PY'
import json
import sys

path, abi = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
options = data.setdefault('buildOption', {}).setdefault('externalNativeOptions', {})
options['abiFilters'] = [abi]
with open(path, 'w') as handle:
    json.dump(data, handle, indent=2)
    handle.write('\n')
PY
  then
    rm -f "$tmp"
    APP_PACKAGE_PROFILE_BACKUP=
    app_package_fail "cannot set abiFilters in $APP_PACKAGE_PROFILE"
    return 1
  fi

  trap app_package_restore_profile EXIT
  trap 'app_package_restore_profile; exit 130' INT TERM
  app_package_log "abiFilters -> $abi (restored on exit)"
}

app_package_restore_profile() {
  if [ -n "${APP_PACKAGE_PROFILE_BACKUP:-}" ] && [ -f "$APP_PACKAGE_PROFILE_BACKUP" ]; then
    mv -f "$APP_PACKAGE_PROFILE_BACKUP" "$APP_PACKAGE_PROFILE"
  fi
  APP_PACKAGE_PROFILE_BACKUP=
}

# hvigor treats entry/libs/**/*.so as a static input of the native packaging
# step and keeps reusing the copies it made on the first build, so a rebuilt
# libemacs_gui.so would silently not reach the HAP.  Drop those intermediates
# so the libraries in entry/libs/ are always the ones that get packaged, and
# bump the mtimes that hvigor hashes: when only an Emacs object changed, every
# app task is "up-to-date" and the stale package would be installed.
app_package_invalidate() {
  local f
  touch "$APP_PACKAGE_APP/entry/src/main/cpp/host/napi_module.cpp"
  for f in "$APP_PACKAGE_APP"/entry/libs/*/libemacs_gui.so; do
    [ -f "$f" ] && touch "$f"
  done
  rm -rf "$APP_PACKAGE_APP/entry/build/default/intermediates/libs" \
         "$APP_PACKAGE_APP/entry/build/default/intermediates/stripped_native_libs" \
         "$APP_PACKAGE_UNSIGNED_HAP" \
         "$APP_PACKAGE_APP/entry/build/default/outputs/default/entry-default-signed.hap"
  return 0
}

# app_package_runtime_stale: 0 when the runtime tarball must be rebuilt
app_package_runtime_stale() {
  [ "${FORCE_RUNTIME:-0}" = 1 ] && return 0
  if [ ! -f "$APP_PACKAGE_TARBALL" ] || [ ! -f "$APP_PACKAGE_RUNTIME_MANIFEST" ]; then
    return 0
  fi
  local newer f
  newer=$(find "$REPO/emacs/lisp" "$REPO/emacs/leim" "$REPO/emacs/etc" \
            \( -name '*.el' -o -name '*.elc' \) \
            -newer "$APP_PACKAGE_TARBALL" -print -quit 2>/dev/null)
  [ -n "$newer" ] && return 0
  for f in lisp/term/ohos-win.el lisp/menu-bar.el lisp/loadup.el lisp/frame.el lisp/faces.el; do
    [ -f "$REPO/emacs/$f" ] && [ "$REPO/emacs/$f" -nt "$APP_PACKAGE_TARBALL" ] && return 0
  done
  return 1
}

app_package_prepare_runtime() {
  local arch=${1:-}
  if app_package_runtime_stale; then
    app_package_log "assembling runtime"
    ARCH="$arch" "$REPO/scripts/build-runtime-stage.sh" "$arch" >/dev/null || return 1
    ARCH="$arch" "$REPO/scripts/pack-runtime.sh" >/dev/null || return 1
  else
    app_package_log "reusing runtime ${APP_PACKAGE_TARBALL##*/}"
  fi
}

app_package_hvigor() {
  local mode=$1 log args
  log=$(mktemp)
  args=(--mode module -p module=entry@default)
  [ "$mode" = release ] && args+=(-p buildMode=release)

  if ! ( cd "$APP_PACKAGE_APP" && "$CT/bin/ohpm" install --all >/dev/null ); then
    rm -f "$log"
    app_package_fail "ohpm install failed in $APP_PACKAGE_APP"
    return 1
  fi
  # The hvigor output is captured instead of piped through tail: a failed
  # ArkTS/C++ build used to be invisible behind the pipe and the previous HAP
  # was installed instead.
  if ! ( cd "$APP_PACKAGE_APP" \
         && "$CT/bin/hvigorw" "${args[@]}" assembleHap --no-daemon >"$log" 2>&1 ); then
    tail -30 "$log" >&2
    app_package_fail "hvigor $mode build failed; log: $log"
    return 1
  fi
  if ! grep -q 'BUILD SUCCESSFUL' "$log"; then
    tail -30 "$log" >&2
    app_package_fail "hvigor $mode build did not report BUILD SUCCESSFUL; log: $log"
    return 1
  fi
  rm -f "$log"

  [ -f "$APP_PACKAGE_UNSIGNED_HAP" ] || {
    app_package_fail "missing $APP_PACKAGE_UNSIGNED_HAP"
    return 1
  }
}

# app_package_build MODE ARCH builds the unsigned HAP and leaves its path in
# APP_PACKAGE_UNSIGNED_HAP.
app_package_build() {
  local mode=${1:-} arch=${2:-}
  case "$mode" in
    debug|release) ;;
    *) app_package_fail "usage: app_package_build debug|release ARCH"; return 2 ;;
  esac

  export PATH=${JAVA_HOME:+$JAVA_HOME/bin:}$CT/bin:$PATH
  export DEVECO_SDK_HOME=$CT/sdk
  # hvigor needs a writable user home; the default ~/.hvigor may not exist or
  # may be read-only, in which case hvigor silently fails to package.
  export HVIGOR_USER_HOME=${HVIGOR_USER_HOME:-$REPO/.hvigor-home}
  mkdir -p "$HVIGOR_USER_HOME"

  app_package_use_abi "$arch" || return 1

  app_package_log "building renderer"
  ARCH="$arch" "$REPO/scripts/build-ohos-render.sh" >/dev/null || return 1

  app_package_prepare_runtime "$arch" || return 1

  app_package_invalidate
  app_package_log "running hvigor assembleHap ($mode)"
  app_package_hvigor "$mode" || return 1
  return 0
}

app_package_version_name() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["app"]["versionName"])' \
    "$APP_PACKAGE_APP/AppScope/app.json5"
}

app_package_version_code() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["app"]["versionCode"])' \
    "$APP_PACKAGE_APP/AppScope/app.json5"
}

# app_package_write_metadata MODE ARCH SIGNED_HAP OUT_JSON
# The sidecar is what deploy.sh uses to warn about stale or wrong-ABI packages.
app_package_write_metadata() {
  local mode=$1 arch=$2 hap=$3 out=$4 abi lib
  abi=$(app_package_abi "$arch") || return 1
  lib=$APP_PACKAGE_APP/entry/libs/$abi/libemacs_gui.so
  python3 - "$mode" "$arch" "$abi" "$hap" "$out" \
    "$APP_PACKAGE_APP/AppScope/app.json5" "$REPO" "$lib" <<'PY'
import datetime
import hashlib
import json
import os
import subprocess
import sys

mode, arch, abi, hap, out, app_json, repo, lib = sys.argv[1:9]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


with open(app_json) as handle:
    app = json.load(handle)['app']

metadata = {
    'bundle': app['bundleName'],
    'mode': mode,
    'provision_type': mode,
    'arch': arch,
    'abi': abi,
    'version_code': app['versionCode'],
    'version_name': app['versionName'],
    'hap': os.path.basename(hap),
    'hap_sha256': sha256(hap),
    'git_rev': subprocess.check_output(
        ['git', '-C', repo, 'rev-parse', 'HEAD'], text=True).strip(),
    'git_dirty_files': len(subprocess.check_output(
        ['git', '-C', repo, 'status', '--porcelain'], text=True).splitlines()),
    'built_at': datetime.datetime.now(datetime.timezone.utc)
                        .strftime('%Y-%m-%dT%H:%M:%SZ'),
}
if os.path.exists(lib):
    metadata['libemacs_gui_sha256'] = sha256(lib)

with open(out, 'w') as handle:
    json.dump(metadata, handle, indent=2)
    handle.write('\n')
PY
}

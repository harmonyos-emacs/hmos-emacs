#!/bin/bash
# Signing helpers shared by build-debug-app.sh and build-release-app.sh.
# Source this file; it defines constants and functions only.
#
# Material is namespaced per profile and resolved the same way for both:
#
#   debug    DEBUG_KEYSTORE / DEBUG_KEYSTORE_PWD / DEBUG_KEY_ALIAS /
#            DEBUG_KEY_PWD / DEBUG_APP_CERT / DEBUG_PROFILE
#   release  RELEASE_KEYSTORE / RELEASE_KEYSTORE_PWD / RELEASE_KEY_ALIAS /
#            RELEASE_KEY_PWD / RELEASE_APP_CERT / RELEASE_PROFILE
#
# Resolution order for every value:
#   1. the explicit <MODE>_* environment variable
#   2. refs/<mode>/CREDENTIALS.txt (store_password= / key_password=)
#   3. the repository default path for that profile
#   4. a hard error
#
# Passwords are never defaulted from a repository path.  They come from the
# environment or from a 0600 CREDENTIALS.txt, exactly like the release profile
# always required.  Both profiles are validated (bundle name, profile type,
# device binding, required ACLs) and both signed packages are verified with
# verify-app before they are reported as built.

[ -n "${SIGNING_SH_LOADED:-}" ] && return 0
SIGNING_SH_LOADED=1

SIGN_BUNDLE=${SIGN_BUNDLE:-emacs.hmos.org}
SIGN_ALG=${SIGN_ALG:-SHA256withECDSA}
SIGN_TOOL=${SIGN_TOOL:-${CT:+$CT/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar}}

# ACLs declared by app/entry/src/main/module.json5 that the profile must
# allow.  Kept in one place so debug and release can never drift apart.
SIGN_REQUIRED_ACLS=(
  ohos.permission.READ_PASTEBOARD
  ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY
  ohos.permission.READ_WRITE_DESKTOP_DIRECTORY
  ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY
)

signing_fail() {
  printf 'signing: %s\n' "$*" >&2
  return 1
}

# signing_env_value MODE NAME -> prints the <MODE>_<NAME> environment value
signing_env_value() {
  local mode=$1 name=$2 prefix var
  case "$mode" in
    debug)   prefix=DEBUG ;;
    release) prefix=RELEASE ;;
    *) return 2 ;;
  esac
  var=${prefix}_${name}
  printf '%s' "${!var:-}"
}

# signing_default MODE NAME -> prints the repository default for that profile
signing_default() {
  case "$1:$2" in
    debug:KEYSTORE)   printf '%s' "$REPO/refs/debug/demo.p12" ;;
    debug:APP_CERT)   printf '%s' "$REPO/refs/debug/cert1.cer" ;;
    debug:PROFILE)    printf '%s' "$REPO/refs/debug/emacs-hmos3Debug.p7b" ;;
    debug:KEY_ALIAS)  printf '%s' demo_key ;;
    release:KEYSTORE) printf '%s' "$REPO/refs/release/emacs-hmos-release.p12" ;;
    release:APP_CERT) printf '%s' "$REPO/refs/release/release-cert1.cer" ;;
    release:PROFILE)  printf '%s' "$REPO/refs/release/release-profile3Release.p7b" ;;
    release:KEY_ALIAS) printf '%s' emacs_release ;;
    *) return 1 ;;
  esac
}

# signing_cred_file MODE -> path of that profile's CREDENTIALS.txt
signing_cred_file() {
  printf '%s' "$REPO/refs/$1/CREDENTIALS.txt"
}

# signing_cred_value MODE KEY -> value from CREDENTIALS.txt, 1 if unavailable
signing_cred_value() {
  local file
  file=$(signing_cred_file "$1")
  [ -f "$file" ] || return 1
  sed -n "s/^$2=//p" "$file" | head -1
}

# signing_resolve MODE resolves all material into SIGN_* variables and checks
# that every file exists, that the CREDENTIALS file is not world readable and
# that java/hap-sign-tool are available.  Returns 1 with a message on failure.
signing_resolve() {
  local mode=${1:-}
  case "$mode" in
    debug|release) ;;
    *) signing_fail "usage: signing_resolve debug|release"; return 2 ;;
  esac

  local cred perms value
  SIGN_MODE=$mode

  # The old shared names are deliberately not read any more; say so once
  # instead of failing later with a confusing "missing password".
  if [ "$mode" = debug ] && [ -z "${DEBUG_KEYSTORE:-}" ] \
     && { [ -n "${KEYSTORE:-}" ] || [ -n "${PROFILE:-}" ] || [ -n "${APP_CERT:-}" ]; }; then
    printf 'signing: note: KEYSTORE/PROFILE/APP_CERT are no longer read; rename them to DEBUG_KEYSTORE/DEBUG_PROFILE/DEBUG_APP_CERT\n' >&2
  fi

  SIGN_KEYSTORE=$(signing_env_value "$mode" KEYSTORE)
  [ -n "$SIGN_KEYSTORE" ] || SIGN_KEYSTORE=$(signing_default "$mode" KEYSTORE)
  SIGN_APP_CERT=$(signing_env_value "$mode" APP_CERT)
  [ -n "$SIGN_APP_CERT" ] || SIGN_APP_CERT=$(signing_default "$mode" APP_CERT)
  SIGN_PROFILE=$(signing_env_value "$mode" PROFILE)
  [ -n "$SIGN_PROFILE" ] || SIGN_PROFILE=$(signing_default "$mode" PROFILE)
  SIGN_KEY_ALIAS=$(signing_env_value "$mode" KEY_ALIAS)
  [ -n "$SIGN_KEY_ALIAS" ] || SIGN_KEY_ALIAS=$(signing_default "$mode" KEY_ALIAS)

  cred=$(signing_cred_file "$mode")
  if [ -f "$cred" ]; then
    perms=$(stat -c %a "$cred" 2>/dev/null || true)
    case "$perms" in
      600|400) ;;
      *) signing_fail "$cred must be 0600, found ${perms:-unknown}"; return 1 ;;
    esac
  fi

  SIGN_KEYSTORE_PWD=$(signing_env_value "$mode" KEYSTORE_PWD)
  if [ -z "$SIGN_KEYSTORE_PWD" ]; then
    value=$(signing_cred_value "$mode" store_password) || value=
    SIGN_KEYSTORE_PWD=$value
  fi
  SIGN_KEY_PWD=$(signing_env_value "$mode" KEY_PWD)
  if [ -z "$SIGN_KEY_PWD" ]; then
    value=$(signing_cred_value "$mode" key_password) || value=
    SIGN_KEY_PWD=$value
  fi

  local f
  for f in "$SIGN_KEYSTORE" "$SIGN_APP_CERT" "$SIGN_PROFILE"; do
    [ -f "$f" ] || { signing_fail "missing $mode material: $f"; return 1; }
  done
  [ -n "$SIGN_KEY_ALIAS" ] || { signing_fail "empty $mode key alias"; return 1; }
  [ -n "$SIGN_KEYSTORE_PWD" ] || {
    signing_fail "missing $mode keystore password (export ${mode^^}_KEYSTORE_PWD or add store_password= to $cred)"
    return 1
  }
  [ -n "$SIGN_KEY_PWD" ] || {
    signing_fail "missing $mode key password (export ${mode^^}_KEY_PWD or add key_password= to $cred)"
    return 1
  }

  signing_require_tools
}

signing_require_tools() {
  # Prefer the JAVA_HOME binary even when its bin/ is not on PATH yet.
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    SIGN_JAVA=$JAVA_HOME/bin/java
  elif command -v java >/dev/null 2>&1; then
    SIGN_JAVA=java
  else
    signing_fail "java not found (set JAVA_HOME)"
    return 1
  fi
  if [ -z "$SIGN_TOOL" ] || [ ! -f "$SIGN_TOOL" ]; then
    signing_fail "hap-sign-tool.jar not found (set CT or SIGN_TOOL, got '${SIGN_TOOL:-}')"
    return 1
  fi
}

# signing_check_profile validates the resolved PROFILE for the given mode:
# bundle name, debug/release type, device binding and the ACL set used by
# module.json5.  Both build paths call this before signing.
signing_check_profile() {
  local mode=${1:-}
  python3 - "$mode" "$SIGN_PROFILE" "$SIGN_BUNDLE" "${SIGN_REQUIRED_ACLS[*]}" <<'PY'
import json
import sys

mode, path, bundle, acls = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()

try:
    raw = open(path, 'rb').read()
except OSError as exc:
    sys.exit('signing: cannot read profile %s: %s' % (path, exc))

start = raw.find(b'{"version-name"')
if start < 0:
    sys.exit('signing: cannot parse profile: %s' % path)
try:
    data, _ = json.JSONDecoder().raw_decode(raw[start:].decode('utf-8', 'replace'))
except ValueError as exc:
    sys.exit('signing: cannot parse profile %s: %s' % (path, exc))


def fail(message):
    sys.exit('signing: %s (%s)' % (message, path))


if data.get('bundle-info', {}).get('bundle-name') != bundle:
    fail('profile bundle-name mismatch, want %s' % bundle)

profile_type = data.get('type')
device_ids = (data.get('debug-info') or {}).get('device-ids') or []
if mode == 'debug':
    if profile_type != 'debug':
        fail('debug build needs a debug profile, got type=%r' % profile_type)
    if not device_ids:
        fail('debug profile is not bound to any device (empty debug-info.device-ids)')
else:
    if profile_type != 'release':
        fail('release build needs a release profile, got type=%r' % profile_type)
    # A release profile may still be device-bound: AGC issues those for
    # internal testing (app-distribution-type=internaltesting).  They are
    # valid for signing and installing on the registered devices, but not
    # for AppGallery upload, so surface the binding instead of rejecting it.

missing = sorted(set(acls) - set(data.get('acls', {}).get('allowed-acls', [])))
if missing:
    fail('profile missing ACLs: ' + ', '.join(missing))

name = path.rsplit('/', 1)[-1]
if mode == 'debug':
    # Debug profiles are always device-bound; only release needs the
    # distribution/binding summary.
    print('signing: debug profile ok (%s)' % name)
else:
    distribution = data.get('app-distribution-type') or 'unknown'
    details = [distribution]
    if device_ids:
        details.append('device-bound: %d device(s)' % len(device_ids))
    print('signing: release profile ok (%s: %s)' % (name, ', '.join(details)))
    if device_ids:
        print('signing: note: device-bound profile; this package only installs '
              'on the registered device(s) and cannot be uploaded to AppGallery')
PY
}

# signing_sign IN OUT [extra hap-sign-tool args...]
signing_sign() {
  local in=$1 out=$2
  shift 2
  "$SIGN_JAVA" -jar "$SIGN_TOOL" sign-app -mode localSign -signAlg "$SIGN_ALG" \
    -keyAlias "$SIGN_KEY_ALIAS" -keyPwd "$SIGN_KEY_PWD" \
    -appCertFile "$SIGN_APP_CERT" -profileFile "$SIGN_PROFILE" \
    -keystoreFile "$SIGN_KEYSTORE" -keystorePwd "$SIGN_KEYSTORE_PWD" \
    -inFile "$in" -outFile "$out" "$@" >/dev/null
}

# signing_verify FILE [CERT_OUT PROFILE_OUT]
# Without output paths the exported chain/profile are written to a temporary
# directory and removed again, so verification is mandatory but leaves no
# debug artifacts behind.
signing_verify() {
  local in=$1 cert_out=${2:-} prof_out=${3:-} tmp=
  if [ -z "$cert_out" ]; then
    tmp=$(mktemp -d)
    cert_out=$tmp/cert-chain.cer
    prof_out=$tmp/profile.p7b
  fi
  if ! "$SIGN_JAVA" -jar "$SIGN_TOOL" verify-app -inFile "$in" \
       -outCertChain "$cert_out" -outProfile "$prof_out" >/dev/null; then
    [ -n "$tmp" ] && rm -rf "$tmp"
    signing_fail "verify-app failed: $in"
    return 1
  fi
  [ -n "$tmp" ] && rm -rf "$tmp"
  return 0
}

signing_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

# signing_describe prints the non-secret material identity for build logs.
signing_describe() {
  printf 'signing: %s material profile=%s cert=%s alias=%s\n' \
    "$SIGN_MODE" "${SIGN_PROFILE##*/}" "${SIGN_APP_CERT##*/}" "$SIGN_KEY_ALIAS"
}

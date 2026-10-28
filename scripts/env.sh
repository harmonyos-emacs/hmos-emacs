#!/bin/bash
# Shared, machine-local build environment.  Source this file; do not execute it.
#
# All external assets are deliberately outside git.  Override them with the
# variables below (or an untracked .env.local sourced by your shell).

ENV_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${REPO:=$ENV_REPO}"
export REPO

# Optional machine-local values; never committed.
if [ -f "$REPO/.env.local" ]; then
  . "$REPO/.env.local"
fi

# HarmonyOS Command Line Tools.  Prefer OHOS_CT/CT; otherwise discover a
# command-line-tools installation under the user's home or /opt.
if [ -z "${CT:-}" ]; then
  for candidate in \
    "${OHOS_CT:-}" \
    "$HOME"/Desktop/commandline-tools-linux-*/command-line-tools \
    "$HOME"/commandline-tools-linux-*/command-line-tools \
    /opt/commandline-tools-linux-*/command-line-tools \
    /opt/commandline-tools-*/command-line-tools
  do
    if [ -n "$candidate" ] && [ -d "$candidate/sdk/default/openharmony" ]; then
      CT=$candidate
      break
    fi
  done
fi
export CT

export OHOS_SDK=${OHOS_SDK:-${CT:+$CT/sdk/default/openharmony}}
export HDC=${HDC:-${CT:+$CT/sdk/default/openharmony/toolchains/hdc}}

# Every build product lives under one deletable root:
#   build/deps/<abi>     pinned target dependencies
#   build/host           native bootstrap tools
#   build/target/<arch>  Emacs configure/build tree
#   build/runtime/<arch> assembled runtime stage
export BUILD_ROOT=${BUILD_ROOT:-$REPO/build}
export HOSTBUILD=${HOSTBUILD:-$BUILD_ROOT/host}

# Java and host text tools are external, but discover common locations.
if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in /usr/lib/jvm/java-17-openjdk-* "$HOME"/opt/jdk-17*; do
    if [ -x "$candidate/bin/java" ]; then JAVA_HOME=$candidate; break; fi
  done
fi
export JAVA_HOME

for candidate in "$HOME/opt/autoconf/bin" /usr/bin; do
  if [ -x "$candidate/autoconf" ]; then AUTOCONF_BIN=$candidate; break; fi
done
for candidate in "$HOME/opt/texinfo/bin" /usr/bin; do
  if [ -x "$candidate/makeinfo" ]; then TEXINFO_BIN=$candidate; break; fi
done
export AUTOCONF_BIN TEXINFO_BIN
if [ -n "${AUTOCONF_BIN:-}" ]; then PATH=$AUTOCONF_BIN:$PATH; fi
if [ -n "${TEXINFO_BIN:-}" ]; then PATH=$TEXINFO_BIN:$PATH; fi
export PATH

# Device selection is intentionally not defaulted to a developer machine.
TARGET=${TARGET:-${OHOS_TARGET:-}}
export TARGET
export DIST=${DIST:-$REPO/dist}
export SIGN_ALG=${SIGN_ALG:-SHA256withECDSA}
# Signing material is namespaced per profile and resolved by
# scripts/lib/signing.sh, not here: DEBUG_* for build-debug-app.sh and
# RELEASE_* for build-release-app.sh.  Do not add shared keystore defaults to
# this file; that is how the debug material used to leak into every script.

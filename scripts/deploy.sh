#!/bin/bash
# Build, sign, install and launch the Emacs HAP on the HarmonyOS PC.
set -e

CT=${CT:-/home/song/Desktop/commandline-tools-linux-x64-26.0.0.851/command-line-tools}
HDC=$CT/sdk/default/openharmony/toolchains/hdc
TARGET=${TARGET:-192.168.102.170:39681}
KEY_ALIAS=${KEY_ALIAS:-demo_key}
KEY_PWD=${KEY_PWD:-123456Abc}
KEYSTORE=${KEYSTORE:-/home/song/Desktop/hmtest/sign-material/demo.p12}
KEYSTORE_PWD=${KEYSTORE_PWD:-123456Abc}
LIB=$CT/sdk/default/openharmony/toolchains/lib
REPO=$(cd "$(dirname "$0")/.." && pwd)
APP=$REPO/app
BUNDLE=emacs.hmos.org
ABILITY=EntryAbility

export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}
export PATH=$JAVA_HOME/bin:$CT/bin:$PATH
export DEVECO_SDK_HOME=$CT/sdk

cd "$APP"

# Generated assets: the HOME init tarball is rebuilt from app/home-init/, the
# runtime tarball is large and only rebuilt when missing.
"$REPO/scripts/pack-home-init.sh" >/dev/null
if [ ! -f entry/src/main/resources/rawfile/emacs-runtime.tar.gz ]; then
  "$REPO/scripts/pack-runtime.sh"
fi

"$CT/bin/ohpm" install --all >/dev/null
"$CT/bin/hvigorw" --mode module -p module=entry@default assembleHap --no-daemon | tail -3

UNSIGNED=entry/build/default/outputs/default/entry-default-unsigned.hap
SIGNED=entry/build/default/outputs/default/entry-default-signed.hap
java -jar "$LIB/hap-sign-tool.jar" sign-app -mode localSign -signAlg SHA256withECDSA \
  -keyAlias "$KEY_ALIAS" -keyPwd "$KEY_PWD" \
  -appCertFile "$REPO/refs/cert1.cer" \
  -profileFile "$REPO/refs/emacs-hmosDebug.p7b" \
  -keystoreFile "$KEYSTORE" -keystorePwd "$KEYSTORE_PWD" \
  -inFile "$UNSIGNED" -outFile "$SIGNED" >/dev/null

"$HDC" -t "$TARGET" install "$SIGNED"
"$HDC" -t "$TARGET" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
"$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a "$ABILITY"
echo "deployed $BUNDLE"

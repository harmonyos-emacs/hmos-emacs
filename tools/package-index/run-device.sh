#!/bin/bash
# Run the package-index probes on an attached HarmonyOS device.
#
# This does not need a special app build: the app enters probe mode when
# runtime/package-index/queue.txt exists.  The queue and runner are copied
# through hdc's debug-app file channel, so app-sandbox permissions are kept.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$ROOT/../.." && pwd)
CT=${CT:-/home/song/Desktop/commandline-tools-linux-x64-26.0.0.851/command-line-tools}
HDC=${HDC:-$CT/sdk/default/openharmony/toolchains/hdc}
TARGET=${TARGET:-192.168.102.170:39681}
BUNDLE=${BUNDLE:-emacs.hmos.org}
ABILITY=${ABILITY:-EntryAbility}
REMOTE_RUNTIME=${REMOTE_RUNTIME:-/data/storage/el2/base/haps/entry/files/runtime}
REMOTE_INDEX="$REMOTE_RUNTIME/package-index"
HOST_RUNTIME=${HOST_RUNTIME:-/data/app/el2/100/base/emacs.hmos.org/haps/entry/files/runtime}
HOST_INDEX="$HOST_RUNTIME/package-index"
OUT="$ROOT/results"
POLL_SECONDS=${POLL_SECONDS:-20}
MAX_MINUTES=${MAX_MINUTES:-240}

mkdir -p "$OUT"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/package-index"
cp "$ROOT/runner.el" "$STAGE/package-index/runner.el"
python3 - "$ROOT/packages.json" > "$STAGE/package-index/queue.txt" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1], encoding="utf-8")):
    print(item["name"])
PY

echo "target: $TARGET"
"$HDC" -t "$TARGET" shell "aa force-stop $BUNDLE" >/dev/null 2>&1 || true
sleep 1
# hdc merges an existing directory, so it is safe to send this over old results.
"$HDC" -t "$TARGET" file send -b "$BUNDLE" "$STAGE/package-index" "$REMOTE_RUNTIME"
"$HDC" -t "$TARGET" shell "aa start -b $BUNDLE -a $ABILITY" >/dev/null
echo "started $BUNDLE; waiting for package-index results"

started=$(date +%s)
seen=""
while true; do
  now=$(date +%s)
  if [ $(( (now - started) / 60 )) -ge "$MAX_MINUTES" ]; then
    echo "timeout after ${MAX_MINUTES}m" >&2
    exit 1
  fi
  status=$("$HDC" -t "$TARGET" shell "cat $HOST_INDEX/status.txt 2>/dev/null" 2>/dev/null | tr -d '\r' || true)
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "${status:-starting}"
  for f in $("$HDC" -t "$TARGET" shell "ls $HOST_INDEX/results 2>/dev/null" 2>/dev/null | tr -d '\r' || true); do
    case "$f" in
      *.json|*.log) ;;
      *) continue ;;
    esac
    case " $seen " in
      *" $f "*) ;;
      *)
        if "$HDC" -t "$TARGET" file recv "$HOST_INDEX/results/$f" "$OUT/$f" >/dev/null 2>&1; then
          echo "  copied $f"
          seen="$seen $f"
        fi
        ;;
    esac
  done
  if printf '%s' "$status" | grep -q '^done'; then
    echo "probe finished"
    break
  fi
  sleep "$POLL_SECONDS"
done

echo "results: $OUT"

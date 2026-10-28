#!/bin/bash
# Assert that the NAPI export table, index.d.ts and the ArkTS call sites
# agree on the set of native functions.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CPP=$REPO/app/entry/src/main/cpp
TABLE=$CPP/host/napi_module.cpp
DTS=$CPP/types/libentry/index.d.ts

python3 - "$TABLE" "$DTS" <<'PY'
import re, sys

table = open(sys.argv[1]).read()
dts = open(sys.argv[2]).read()

exports = set(re.findall(r'\{\s*"([A-Za-z0-9_]+)"\s*,', table))
declared = set(re.findall(r'export const ([A-Za-z0-9_]+)', dts))

missing = sorted(exports - declared)
extra = sorted(declared - exports)
if missing:
    print("missing from index.d.ts:", ", ".join(missing), file=sys.stderr)
if extra:
    print("stale in index.d.ts:", ", ".join(extra), file=sys.stderr)
if missing or extra:
    sys.exit(1)
print("check-napi: ok (%d exports)" % len(exports))
PY

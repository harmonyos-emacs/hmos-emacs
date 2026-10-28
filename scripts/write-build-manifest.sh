#!/bin/bash
# Record the exact inputs and produced hashes for a build tree.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/env.sh"
ARCH=${ARCH:-aarch64}
BUILD=${1:-${BUILD:-$BUILD_ROOT/target/$ARCH}}
case "$ARCH" in
  aarch64) ABI=arm64-v8a ;;
  x86_64)  ABI=x86_64 ;;
  *) echo "unsupported ARCH: $ARCH" >&2; exit 2 ;;
esac
RUNTIME=$REPO/app/entry/src/main/resources/rawfile/emacs-runtime.tar.gz
OUT=$BUILD/build-manifest.json
mkdir -p "$BUILD"
BUILD_DIR=$BUILD RUNTIME_TAR=$RUNTIME CT_PATH=$CT SDK_PATH=$OHOS_SDK \
ARCH=$ARCH ABI=$ABI \
DEPS_PREFIX=${DEPS_PREFIX:-$BUILD_ROOT/deps/$ABI} BUILD_ROOT_PATH=$BUILD_ROOT \
REPO_PATH=$REPO \
python3 - <<'PY'
import hashlib
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

def sha(path):
    p = Path(path)
    if not p.is_file():
        return None
    h = hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def git(repo, *args):
    try:
        return subprocess.check_output(['git', '-C', repo, *args],
                                       text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None

repo = Path(os.environ['REPO_PATH'])
build = Path(os.environ['BUILD_DIR'])
emacs = repo / 'emacs'
sdk = Path(os.environ['SDK_PATH']) if os.environ.get('SDK_PATH') else None
sdk_api = None
if sdk:
    for pkg in (sdk / 'sdk-pkg.json', sdk.parent / 'sdk-pkg.json'):
        if pkg.is_file():
            try:
                sdk_api = json.loads(pkg.read_text()).get('data', {}).get('apiVersion')
            except Exception:
                pass
            break
compiler = sdk / 'native/llvm/bin/clang' if sdk else None
compiler_version = None
if compiler and compiler.is_file():
    try:
        compiler_version = subprocess.check_output([str(compiler), '--version'],
                                                   text=True).splitlines()[0]
    except Exception:
        pass
runtime = Path(os.environ['RUNTIME_TAR'])
arch = os.environ.get('ARCH', 'aarch64')
abi = {'aarch64': 'arm64-v8a', 'x86_64': 'x86_64'}.get(arch, arch)
lib = repo / 'app/entry/libs' / abi / 'libemacs_gui.so'
temacs = build / 'src/temacs'
deps_versions = {}
deps = Path(os.environ['DEPS_PREFIX']) if os.environ.get('DEPS_PREFIX') else None
if deps:
    for pc in sorted((deps / 'lib/pkgconfig').glob('*.pc')):
        try:
            for line in pc.read_text().splitlines():
                if line.startswith('Version:'):
                    deps_versions[pc.stem] = line.split(':', 1)[1].strip()
                    break
        except Exception:
            pass

# Feature switches come from the actual configure output, never from the
# command line or from probing paths.
def config_features(path):
    found = {}
    if path.is_file():
        for line in path.read_text(errors='replace').splitlines():
            m = re.match(r'#define (HAVE_[A-Z0-9_]+) 1\s*$', line)
            if m:
                found[m.group(1)] = True
    return found

FEATURES = ('HAVE_GNUTLS', 'HAVE_LIBXML2', 'HAVE_SQLITE3')
config_defines = config_features(build / 'src/config.h')
features = {name: bool(config_defines.get(name)) for name in FEATURES}

# Pinned third-party inputs: version + upstream source + hash of the exact
# archive the build consumed.
pins = {}
try:
    pins = json.loads((repo / 'third_party/versions.json').read_text())
except Exception:
    pass

def pinned(name):
    entry = pins.get(name, {})
    url = entry.get('url') or ''
    archive = repo / 'third_party/src' / url.rsplit('/', 1)[-1] if url else None
    rel = str(archive.relative_to(repo)) if archive and archive.is_file() else None
    return {
        'version': entry.get('version'),
        'source': url or None,
        'archive': rel,
        'sha256': sha(archive) if archive else None,
        'license': entry.get('license'),
    }

DEPS = ('libpng', 'libxml2', 'sqlite3', 'gmp', 'nettle', 'libtasn1',
        'libunistring', 'ncurses', 'gnutls')
dependencies = {name: pinned(name) for name in DEPS}
if deps:
    # Record the installed static archive and pkg-config version as well as
    # the pinned source: they are the objects actually linked into the HAP.
    for name, libfile in (('gnutls', 'libgnutls.a'), ('nettle', 'libnettle.a'),
                          ('gmp', 'libgmp.a'), ('libtasn1', 'libtasn1.a'),
                          ('libunistring', 'libunistring.a'),
                          ('ncurses', 'libncurses.a'), ('libxml2', 'libxml2.a'),
                          ('sqlite3', 'libsqlite3.a'), ('libpng', 'libpng16.a')):
        dependencies[name]['installed_sha256'] = sha(deps / 'lib' / libfile)
    gnutls = dependencies['gnutls']
    gnutls['linked'] = ['nettle', 'hogweed', 'gmp', 'unistring', 'tasn1', 'zlib']

manifest = {
    'schema': 1,
    'generated_at': datetime.now(timezone.utc).isoformat(),
    'repo': {
        'commit': git(repo, 'rev-parse', 'HEAD'),
        'dirty': bool(git(repo, 'status', '--porcelain', '--untracked-files=no')),
        'branch': git(repo, 'branch', '--show-current'),
    },
    'emacs': {
        'commit': git(emacs, 'rev-parse', 'HEAD'),
        'dirty': bool(git(emacs, 'status', '--porcelain', '--untracked-files=no')),
    },
    'arch': arch,
    'features': features,
    'dependencies': dependencies,
    'toolchain': {
        'commandline_tools': os.environ.get('CT_PATH'),
        'sdk': os.environ.get('SDK_PATH'),
        'sdk_api': sdk_api,
        'compiler': compiler_version,
        'java_home': os.environ.get('JAVA_HOME'),
        'build_root': os.environ.get('BUILD_ROOT_PATH'),
        'deps_prefix': os.environ.get('DEPS_PREFIX'),
        'dependency_versions': deps_versions,
    },
    'artifacts': {
        'temacs_sha256': sha(temacs),
        'libemacs_gui_sha256': sha(lib),
        'runtime_tar_sha256': sha(runtime),
        'runtime_tar_bytes': runtime.stat().st_size if runtime.is_file() else None,
    },
    'build_dir': str(build),
}
out = build / 'build-manifest.json'
out.write_text(json.dumps(manifest, indent=2) + '\n')
print(out)
if arch == 'aarch64' and not all(features.values()):
    missing = [n for n, v in features.items() if not v]
    raise SystemExit(f'manifest: features disabled in config.h: {missing}')
PY

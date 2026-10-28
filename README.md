# Homacs

Homacs is a native editor for HarmonyOS, based on GNU Emacs 31.1.  This is an
unofficial port: Emacs is built as `libemacs_gui.so` and runs in-process behind
an ArkUI/XComponent surface, with a per-frame native renderer.

This is an **unofficial** port, not a release of the GNU Emacs project or the
Free Software Foundation.  "Emacs" is used only to describe the software this
project is derived from.

## License

The application as a whole is distributed under the **GNU General Public
License, version 3 or later** (`GPL-3.0-or-later`).  See [`LICENSE`](LICENSE).

Because the HAP statically links Emacs into `libemacs_gui.so`, the application
and the Emacs OHOS port are a combined work.  The complete GPLv3 text is also
shipped with the runtime at `runtime102/etc/COPYING`.

## Corresponding source

- Application and build system: <https://github.com/harmonyos-emacs/hmos-emacs>
- GNU Emacs OHOS fork: <https://github.com/harmonyos-emacs/emacs>
- Emacs baseline commit: `bdca293abae619b38834cf690a7f0a27f29babf2`
  (GNU Emacs 31.1 plus the OHOS port commits)

Build and deployment instructions are in [`docs/build-deploy.md`](docs/build-deploy.md).
The pinned third-party sources are in `third_party/src/`; versions and
licenses are recorded in [`third_party/versions.json`](third_party/versions.json).

When distributing the HAP through AppGallery, the corresponding source URL
above must be included in the store listing.

## Third-party components

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the component list,
versions and licenses.  The in-app **开源声明** button in the host top bar shows the same summary.

## Artwork

The Homacs application icon is original artwork created for this project.
The source SVG is [`docs/assets/homacs-icon.svg`](docs/assets/homacs-icon.svg);
it does not copy the official GNU Emacs swan logo.

## Trademarks

This project is not affiliated with, endorsed by, or sponsored by the Free
Software Foundation, the GNU project, or Huawei.  "Homacs" is the project
name; "Emacs" is used descriptively to describe the software this project is
derived from; "HarmonyOS" is a trademark of Huawei.  GPLv3 does not grant trademark rights (see GPLv3 §7(e)),
so the product name, icon, bundle identifier and store listing must be
reviewed separately for trademark/official-endorsement risk.

The bundle identifier remains `emacs.hmos.org` for continuity with the
existing signing certificate/profile; the `hmos.org` domain and the vendor
metadata should still be reviewed before store publication.  See `NOTICE` for
attribution and modification details.

## Build

```bash
scripts/preflight.sh --build-only
ARCH=aarch64 scripts/clean-build.sh

# debug HAP (build + sign, no device access) and install it
ARCH=aarch64 scripts/build-debug-app.sh
TARGET=<hdc-target> ARCH=aarch64 scripts/deploy.sh

# AppGallery release .app (release certificate + release ACL profile)
ARCH=aarch64 scripts/build-release-app.sh
```

See [`AGENTS.md`](AGENTS.md) and [`docs/build-deploy.md`](docs/build-deploy.md)
for prerequisites, signing profiles and device deployment.

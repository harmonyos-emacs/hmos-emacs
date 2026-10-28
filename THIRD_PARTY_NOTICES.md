# Third-party notices

The HAP statically links the components below.  Version and archive hashes are
recorded in [`third_party/versions.json`](third_party/versions.json); the
corresponding sources and their own license files are in `third_party/src/`.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| GNU Emacs | 31.1 + OHOS port | GPL-3.0-or-later | https://github.com/harmonyos-emacs/emacs |
| GnuTLS | 3.8.9 | LGPL-2.1-or-later OR GPL-3.0-or-later | https://www.gnutls.org/ |
| GMP | 6.3.0 | LGPL-3.0-or-later OR GPL-2.0-or-later | https://gmplib.org/ |
| Nettle | 3.9.1 | LGPL-3.0-or-later OR GPL-2.0-or-later | https://www.lysator.liu.se/~nisse/nettle/ |
| libtasn1 | 4.19.0 | LGPL-2.1-or-later | https://www.gnu.org/software/libtasn1/ |
| libunistring | 1.2 | LGPL-3.0-or-later OR GPL-3.0-or-later | https://www.gnu.org/software/libunistring/ |
| ncurses | 6.5 | MIT/X11-style | https://invisible-island.net/ncurses/ |
| libxml2 | 2.12.10 | MIT | https://gitlab.gnome.org/GNOME/libxml2 |
| SQLite | 3.54.1 | Public Domain | https://www.sqlite.org/ |
| libpng | 1.6.44 | libpng/zlib-style | http://www.libpng.org/ |
| nanosvg | vendored | zlib-style | https://github.com/memononen/nanosvg |
| zlib | OHOS sysroot | zlib-style | https://zlib.net/ |
| libc++_shared.so | OHOS SDK | Apache-2.0 WITH LLVM-exception | OHOS native SDK |

The Homacs application icon is original project artwork (source:
`docs/assets/homacs-icon.svg`) and is not a third-party component.

## Compatibility

All of the above are compatible with distributing the combined work under
GPL-3.0-or-later.  LGPL components are used under their "or later" option; the
complete corresponding source and build scripts are provided so the LGPL
relinking/source obligations can be satisfied.  The full GPLv3 text is in
[`LICENSE`](LICENSE) and in the runtime at `etc/COPYING`.

The Emacs distribution also includes its own `COPYING`, `etc/COPYING`,
`lisp/COPYING` and `leim/COPYING` files, which are part of the runtime archive.

## SDK runtime libraries

The HAP also packages `libc++_shared.so` from the OHOS native SDK.  It is
distributed under the SDK's LLVM/libc++ license; the SDK terms and the
AppGallery developer agreement still apply.

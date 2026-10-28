/* Open-source notice entry for the host top bar and its dialog. */

@Component
export struct OpenSourceButton {
  onOpen: () => void = () => {};

  build() {
    Button('开源声明')
      .fontSize(11)
      .height(24)
      .fontColor('#e6e6e6')
      .backgroundColor('#3a3a3a')
      .borderRadius(4)
      .margin({ left: 4, right: 8 })
      .focusable(false)
      .onClick(() => this.onOpen())
  }
}

@Component
export struct OpenSourceDialog {
  onClose: () => void = () => {};

  private licenseText(): string {
    return 'Homacs - a native editor for HarmonyOS, based on GNU Emacs 31.1.\n'
      + 'License: GPL-3.0-or-later\n\n'
      + 'This application is an unofficial HarmonyOS port of GNU Emacs. '
      + 'The combined work is distributed under GPL-3.0-or-later. '
      + 'The complete GPLv3 text is shipped at runtime/etc/COPYING.\n\n'
      + 'Corresponding source:\n'
      + 'https://github.com/harmonyos-emacs/hmos-emacs\n'
      + 'https://github.com/harmonyos-emacs/emacs\n\n'
      + 'Third-party components:\n'
      + 'GnuTLS 3.8.9 - LGPL-2.1-or-later\n'
      + 'libxml2 2.12.10 - MIT\n'
      + 'SQLite 3.54.1 - Public Domain\n'
      + 'libpng 1.6.44 - libpng/zlib\n'
      + 'ncurses 6.5 - MIT/X11\n'
      + 'GMP 6.3.0 - LGPL-3.0+/GPL-2.0+\n'
      + 'Nettle 3.9.1 - LGPL-3.0+/GPL-2.0+\n'
      + 'libtasn1 4.19.0 - LGPL-2.1+\n'
      + 'libunistring 1.2 - LGPL-3.0+/GPL-3.0+\n'
      + 'nanosvg - zlib-style\n\n'
      + 'Homacs icon: original project artwork.\n\n'
      + 'Full notices: THIRD_PARTY_NOTICES.md in the source tree.';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#55000000')
        .hitTestBehavior(HitTestMode.None)
      Column({ space: 12 }) {
        Row() {
          Text('开源软件声明')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#202020')
          Blank()
          Button('关闭')
            .fontSize(13)
            .height(28)
            .onClick(() => this.onClose())
        }
        .width('100%')
        Scroll() {
          Text(this.licenseText())
            .fontSize(12)
            .fontColor('#333333')
            .lineHeight(18)
            .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
      .width('90%')
      .height('80%')
      .padding(16)
      .backgroundColor('#fdfdfd')
      .borderRadius(10)
    }
    .width('100%')
    .height('100%')
  }
}

import entry from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

class TermBridge {
  onWrite: (data: string) => void = () => {};
  onResize: (cols: number, rows: number) => void = () => {};
  onReady: (cols: number, rows: number) => void = () => {};
  onCopy: (text: string) => void = () => {};
  onPaste: () => void = () => {};
  onOpenUrl: (url: string) => void = () => {};
  onRequestClipboard: () => void = () => {};
  onLog: (msg: string) => void = () => {};

  write(data: string): void {
    this.onWrite(data);
  }

  resize(cols: number, rows: number): void {
    this.onResize(cols, rows);
  }

  ready(cols: number, rows: number): void {
    this.onReady(cols, rows);
  }

  copy(text: string): void {
    this.onCopy(text);
  }

  paste(): void {
    this.onPaste();
  }

  openUrl(url: string): void {
    this.onOpenUrl(url);
  }

  requestClipboard(): void {
    this.onRequestClipboard();
  }

  log(msg: string): void {
    this.onLog(msg);
  }
}

@Entry
@Component
struct Index {
  @State status: string = '';
  @State failedMsg: string = '';
  private dumpStartMs: number = 0;
  @State fontSize: number = 15;
  private bridge: TermBridge = new TermBridge();
  private controller: webview.WebviewController = new webview.WebviewController();
  private timer: number = -1;
  private filesDir: string = '';
  private runtime: string = '';
  private phase: string = 'init';
  private webReady: boolean = false;
  private termCols: number = 80;
  private termRows: number = 24;
  private dumpReady: boolean = false;
  private dumpTicks: number = 0;
  // Optional headless probe mode used by tools/package-index/run-device.sh.
  // It is enabled only when runtime/package-index/queue.txt has package names.
  private benchDir: string = '';
  private benchMode: boolean = false;
  private benchPkgs: string[] = [];
  private benchIndex: number = 0;
  private benchTimer: number = -1;
  private benchStarted: number = 0;
  private benchRunning: boolean = false;

  aboutToAppear(): void {
    this.bridge.onWrite = (data: string) => {
      entry.writeInput(data);
    };
    this.bridge.onResize = (cols: number, rows: number) => {
      entry.resizeTerm(cols, rows);
    };
    this.bridge.onReady = (cols: number, rows: number) => {
      this.onWebReady(cols, rows);
    };
    this.bridge.onCopy = (text: string) => {
      this.setClipboard(text);
    };
    this.bridge.onPaste = () => {
      this.pasteToTerminal();
    };
    this.bridge.onOpenUrl = (url: string) => {
      this.openUrl(url);
    };
    this.bridge.onRequestClipboard = () => {
      this.answerClipboardQuery();
    };
    this.bridge.onLog = (msg: string) => {
      hilog.info(0x0000, 'emacs-term', 'web: %{public}s', msg);
    };

    const ctx = getContext(this) as common.UIAbilityContext;
    this.filesDir = ctx.filesDir;
    this.runtime = ctx.filesDir + '/runtime';
    this.benchDir = this.runtime + '/package-index';
    this.benchMode = entry.fileRead(this.benchDir + '/queue.txt').trim().length > 0;

    hilog.info(0x0000, 'emacs-term', 'startup buildId=%{public}s runtime=%{public}s',
      entry.buildId(), this.runtime);
    this.prepareInitFile(ctx, 0);

    // If the WebView never reports ready, show a retry affordance instead of
    // leaving a blank window.
    setTimeout(() => {
      if (!this.webReady && this.failedMsg.length === 0 && this.phase !== 'install' && this.phase !== 'dump') {
        this.showError('终端页面未能加载');
      }
    }, 12000);
  }

  showError(msg: string): void {
    this.status = '';
    this.failedMsg = msg;
  }

  retry(): void {
    this.failedMsg = '';
    if (!this.webReady) {
      this.phase = 'init';
      this.controller.refresh();
      setTimeout(() => {
        if (!this.webReady) {
          this.showError('终端页面加载失败，请重试或重启应用');
        }
      }, 8000);
      return;
    }
    if (!this.dumpReady) {
      this.startDump();
      return;
    }
    this.tryStart();
  }

  prepareInitFile(ctx: common.UIAbilityContext, tries: number): void {
    const dest = this.runtime + '/home/.emacs';
    const existing = entry.fileRead(dest);
    if ((existing.indexOf('ohos-yank') >= 0 && existing.indexOf('ohos-last-clipboard') >= 0) || tries > 100) {
      this.decideStart();
      return;
    }
    if (tries === 0) {
      try {
        const rf = ctx.resourceManager.getRawFdSync('home-init.tar.gz');
        const tar = this.filesDir + '/home-init.tar.gz';
        entry.startInstallRuntime(rf.fd, rf.offset, rf.length, tar, this.runtime);
        ctx.resourceManager.closeRawFdSync('home-init.tar.gz');
      } catch (e) {
        this.decideStart();
        return;
      }
    }
    setTimeout(() => this.prepareInitFile(ctx, tries + 1), 100);
  }

  decideStart(): void {
    const dump = this.runtime + '/bootstrap-emacs.pdmp';
    const stamp = this.runtime + '/dump.stamp';
    const id = entry.buildId() + ':' + entry.libemacsVersion();

    if (entry.fileRead(stamp) === id && entry.runtimeReady(dump) === 1) {
      this.dumpReady = true;
      this.status = '';
      if (this.benchMode) {
        setTimeout(() => this.tryStart(), 0);
      }
      return;
    }

    entry.fileRemove(dump);
    if (entry.runtimeReady(this.runtime + '/lisp/loadup.el') === 1) {
      this.startDump();
      return;
    }

    const ctx = getContext(this) as common.UIAbilityContext;
    const tar = this.filesDir + '/emacs-runtime.tar.gz';
    const rf = ctx.resourceManager.getRawFdSync('emacs-runtime.tar.gz');
    entry.startInstallRuntime(rf.fd, rf.offset, rf.length, tar, this.runtime);
    ctx.resourceManager.closeRawFdSync('emacs-runtime.tar.gz');
    this.phase = 'install';
    this.status = '正在安装 Emacs 运行时（首次启动，请稍候）...';
    this.timer = setInterval(() => this.tickInstall(), 300);
  }

  tickInstall(): void {
    const st = entry.installState();
    this.status = '正在解包运行时：' + st;
    if (st.indexOf('"done":true') >= 0) {
      clearInterval(this.timer);
      this.startDump();
    }
  }

  envText(): string {
    return 'HOME=' + this.runtime + '/home\n' +
      'EMACSLOADPATH=' + this.runtime + '/lisp\n' +
      'EMACSDATA=' + this.runtime + '/etc\n' +
      'EMACSDOC=' + this.runtime + '/etc\n' +
      'EMACSPATH=' + this.runtime + '/libexec\n' +
      'TERMINFO=' + this.runtime + '/terminfo\n' +
      'TMPDIR=' + this.runtime + '/tmp\n' +
      'LANG=C.UTF-8';
  }

  startDump(): void {
    this.phase = 'dump';
    this.dumpStartMs = Date.now();
    this.dumpTicks = 0;
    this.status = '首次启动：正在生成 Emacs dump（约几秒）...';
    hilog.info(0x0000, 'emacs-term', 'startDump');
    const args = '-batch\n-l\nloadup\n--temacs=pbootstrap';
    entry.startEmacs(args, this.envText(), this.runtime, 80, 24);
    this.timer = setInterval(() => this.tickDump(), 200);
  }

  tickDump(): void {
    this.dumpTicks += 1;
    if (this.dumpStartMs > 0 && Date.now() - this.dumpStartMs > 240000) {
      clearInterval(this.timer);
      this.timer = -1;
      entry.stopEmacs();
      this.showError('生成 dump 超时（日志：runtime/emacs-log.txt）');
      return;
    }
    const chunk = entry.readOutput();
    if (chunk.length > 0) {
      this.status = '正在生成 Emacs dump... (' + chunk.length + ' bytes)';
    }
    if (this.dumpTicks % 5 === 0) {
      const st = entry.state();
      if (st.indexOf('"running":false') >= 0) {
        clearInterval(this.timer);
        if (entry.runtimeReady(this.runtime + '/bootstrap-emacs.pdmp') === 1) {
          hilog.info(0x0000, 'emacs-term', 'dump ok after %{public}d ms', Date.now() - this.dumpStartMs);
          entry.fileWrite(this.runtime + '/dump.stamp', entry.buildId() + ':' + entry.libemacsVersion());
          this.dumpReady = true;
          this.status = '';
          this.tryStart();
        } else {
          this.showError('生成 dump 失败：' + st);
        }
      }
    }
  }

  onWebReady(cols: number, rows: number): void {
    hilog.info(0x0000, 'emacs-term', 'webReady cols=%{public}d rows=%{public}d', cols, rows);
    if (cols > 0 && rows > 0) {
      this.termCols = cols;
      this.termRows = rows;
    }
    this.webReady = true;
    this.tryStart();
  }

  tryStart(): void {
    if (this.phase === 'run' || this.phase === 'bench') {
      return;
    }
    if (this.benchMode) {
      if (!this.dumpReady) {
        return;
      }
      this.phase = 'bench';
      this.startBench();
      return;
    }
    if (!this.webReady || !this.dumpReady) {
      return;
    }
    this.phase = 'run';
    this.status = '';
    hilog.info(0x0000, 'emacs-term', 'startNormal cols=%{public}d rows=%{public}d', this.termCols, this.termRows);
    const args = '--dump-file=' + this.runtime + '/bootstrap-emacs.pdmp';
    entry.stopEmacs();
    entry.startEmacs(args, this.envText(), this.runtime, this.termCols, this.termRows);
    this.timer = setInterval(() => this.pump(), 16);
    setTimeout(() => {
      this.runJs('window.termFit()');
    }, 400);
  }


  startBench(): void {
    const text = entry.fileRead(this.benchDir + '/queue.txt');
    this.benchPkgs = text.split('\n')
      .map((line: string) => line.trim())
      .filter((line: string) => line.length > 0 && line.charAt(0) !== '#');
    this.benchIndex = 0;
    this.benchRunning = false;
    entry.fileWrite(this.benchDir + '/status.txt', 'running 0/' + this.benchPkgs.length);
    this.runNextBench();
  }

  runNextBench(): void {
    if (this.benchIndex >= this.benchPkgs.length) {
      entry.fileWrite(this.benchDir + '/queue.txt', '');
      entry.fileWrite(this.benchDir + '/done.txt', Date.now().toString());
      entry.fileWrite(this.benchDir + '/status.txt',
        'done ' + this.benchPkgs.length + '/' + this.benchPkgs.length);
      this.phase = 'bench-done';
      return;
    }
    const pkg = this.benchPkgs[this.benchIndex];
    const result = this.benchDir + '/results/' + pkg + '.json';
    entry.fileRemove(result);
    const args = '--dump-file=' + this.runtime + '/bootstrap-emacs.pdmp\n' +
      '-batch\n' +
      '-Q\n' +
      '-l\n' + this.benchDir + '/runner.el\n' +
      pkg + '\n' +
      this.benchDir + '\n' +
      result;
    const env = 'HOME=' + this.benchDir + '/home\n' +
      'EMACSLOADPATH=' + this.runtime + '/lisp\n' +
      'EMACSDATA=' + this.runtime + '/etc\n' +
      'EMACSDOC=' + this.runtime + '/etc\n' +
      'EMACSPATH=' + this.runtime + '/libexec\n' +
      'TERMINFO=' + this.runtime + '/terminfo\n' +
      'TMPDIR=' + this.benchDir + '/tmp\n' +
      'LANG=C.UTF-8';
    entry.stopEmacs();
    entry.startEmacs(args, env, this.runtime, 80, 24);
    this.benchStarted = Date.now();
    this.benchRunning = true;
    entry.fileWrite(this.benchDir + '/status.txt',
      'running ' + (this.benchIndex + 1) + '/' + this.benchPkgs.length + ' ' + pkg);
    if (this.benchTimer >= 0) {
      clearInterval(this.benchTimer);
    }
    this.benchTimer = setInterval(() => this.tickBench(), 500);
  }

  tickBench(): void {
    if (!this.benchRunning) {
      return;
    }
    entry.readOutput();
    const st = entry.state();
    if (st.indexOf('"running":true') >= 0) {
      if (Date.now() - this.benchStarted > 300000) {
        entry.stopEmacs();
        const pkg = this.benchPkgs[this.benchIndex];
        entry.fileWrite(this.benchDir + '/status.txt',
          'timeout ' + (this.benchIndex + 1) + '/' + this.benchPkgs.length + ' ' + pkg);
        this.finishBenchOne();
      }
      return;
    }
    if (Date.now() - this.benchStarted < 800) {
      return;
    }
    this.finishBenchOne();
  }

  finishBenchOne(): void {
    if (!this.benchRunning) {
      return;
    }
    this.benchRunning = false;
    if (this.benchTimer >= 0) {
      clearInterval(this.benchTimer);
      this.benchTimer = -1;
    }
    const pkg = this.benchPkgs[this.benchIndex];
    entry.fileWrite(this.benchDir + '/progress.txt',
      (this.benchIndex + 1) + '/' + this.benchPkgs.length + ' ' + pkg);
    this.benchIndex += 1;
    setTimeout(() => this.runNextBench(), 250);
  }

  pump(): void {
    if (this.phase !== 'run') {
      return;
    }
    let total = '';
    for (let i = 0; i < 8; i++) {
      const chunk = entry.readOutput();
      if (chunk.length === 0) {
        break;
      }
      total += chunk;
    }
    if (total.length > 0) {
      const js = 'window.termWrite(' + JSON.stringify(total) + ')';
      this.controller.runJavaScript(js).catch((err: BusinessError) => {
        // The web view may not be ready yet; the next tick will retry.
      });
    }
    const st = entry.state();
    if (st.indexOf('"running":false') >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
      const js = 'window.termWrite(' + JSON.stringify('\r\n\x1b[90m[Emacs 已退出 ' + st + ']\x1b[0m\r\n') + ')';
      this.controller.runJavaScript(js).catch((err: BusinessError) => {});
    }
  }

  runJs(script: string): void {
    this.controller.runJavaScript(script).catch((err: BusinessError) => {});
  }

  focusTerm(): void {
    this.getUIContext().getFocusController().requestFocus('termweb');
    setTimeout(() => {
      this.runJs('window.termFocus()');
    }, 60);
  }

  setClipboard(text: string): void {
    if (text.length === 0) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).catch((err: BusinessError) => {});
  }

  onPasteButton(result: PasteButtonOnClickResult): void {
    if (result === PasteButtonOnClickResult.SUCCESS) {
      this.pasteToTerminal();
    }
    this.focusTerm();
  }

  answerClipboardQuery(): void {
    let text = '';
    try {
      const data = pasteboard.getSystemPasteboard().getDataSync();
      if (data.getRecordCount() > 0) {
        const t = data.getPrimaryText();
        if (t !== undefined) {
          text = t;
        }
      }
      hilog.info(0x0000, 'emacs-term', 'clip query records=%{public}d len=%{public}d',
        data.getRecordCount(), text.length);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'emacs-term', 'clip query failed code=%{public}d msg=%{public}s',
        err.code, err.message);
    }
    this.runJs('window.termClipboardReply(' + JSON.stringify(text) + ')');
  }

  pasteToTerminal(): void {
    pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
      let text = data.getPrimaryText();
      if (text === undefined) {
        text = '';
      }
      if (text.length > 0) {
        this.runJs('window.termSetClipboardCache(' + JSON.stringify(text) + ')');
        this.runJs('window.termPaste(' + JSON.stringify(text) + ')');
        this.runJs('window.termScrollBottom()');
      }
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, 'emacs-term', 'paste failed code=%{public}d msg=%{public}s',
        err.code, err.message);
    });
  }

  openUrl(url: string): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ctx.startAbility({
      action: 'ohos.want.action.viewData',
      uri: url
    }).catch((err: BusinessError) => {});
  }

  copySelection(): void {
    this.controller.runJavaScript('JSON.stringify(window.termGetSelection())')
      .then((result: string) => {
        try {
          const text = JSON.parse(result) as string;
          this.setClipboard(text);
        } catch (e) {
          this.setClipboard(result);
        }
      })
      .catch((err: BusinessError) => {});
  }

  zoom(delta: number): void {
    const next = Math.max(9, Math.min(32, this.fontSize + delta));
    if (next !== this.fontSize) {
      this.fontSize = next;
      this.runJs('window.termSetFont(' + next.toString() + ')');
    }
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
    }
    if (this.benchTimer >= 0) {
      clearInterval(this.benchTimer);
    }
    entry.stopEmacs();
  }

  build() {
    Column() {
      Stack() {
        Web({ src: $rawfile('web/index.html'), controller: this.controller })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(true)
          .zoomAccess(false)
          .horizontalScrollBarAccess(false)
          .verticalScrollBarAccess(false)
          .javaScriptProxy({
            object: this.bridge,
            name: 'ohosBridge',
            methodList: ['write', 'resize', 'ready', 'copy', 'paste', 'openUrl', 'requestClipboard', 'log'],
            controller: this.controller
          })
          .id('termweb')
          .focusable(true)
          .width('100%')
          .height('100%')
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.runJs('window.termFit()');
          })

        if (this.status.length > 0 || this.failedMsg.length > 0) {
          Column() {
            if (this.failedMsg.length === 0) {
              LoadingProgress()
                .width(36)
                .height(36)
                .color('#8ab4f8')
            }
            Text(this.failedMsg.length > 0 ? this.failedMsg : this.status)
              .fontSize(13)
              .fontColor('#dddddd')
              .margin({ top: 12 })
              .textAlign(TextAlign.Center)
            if (this.failedMsg.length > 0) {
              Button('重试')
                .fontSize(14)
                .height(34)
                .margin({ top: 14 })
                .backgroundColor('#3a5f8a')
                .onClick(() => this.retry())
            }
          }
          .padding(20)
          .borderRadius(10)
          .backgroundColor('#e6222222')
        }
      }
      .width('100%')
      .layoutWeight(1)

      Row() {
        PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE })
          .fontSize(12)
          .height(26)
          .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
            this.onPasteButton(result);
          })
        Button('键盘')
          .fontSize(11)
          .height(26)
          .margin({ left: 8 })
          .backgroundColor('#2a2a2a')
          .fontColor('#dddddd')
          .onClick(() => this.focusTerm())
      }
      .width('100%')
      .height(36)
      .padding({ left: 8, right: 8 })
      .backgroundColor('#1c1c1c')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101010')
  }
}

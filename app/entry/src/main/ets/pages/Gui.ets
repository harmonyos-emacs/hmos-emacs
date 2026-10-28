/*
 * Native GUI page.
 *
 * The XComponent owns the NativeWindow; libentry.so loads libemacs_gui.so
 * in-process and presents Emacs' draw command stream directly.  This page
 * owns the host side: IME, clipboard, menus, notifications and the window
 * commands Emacs queues.
 *
 * The page also owns the typed host event mailbox: Emacs queues
 * window/chrome/menu/request records that only ArkTS can apply, and the
 * page drains them with `guiTakeHostEvent'.  Interactive requests answer
 * with `guiMenuResult' / `guiClipboardResult'.
 */
import entry, { HostEvent } from 'libentry.so';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';

import { BusinessError } from '@kit.BasicServicesKit';
import { display, window } from '@kit.ArkUI';
import { unifiedDataChannel } from '@kit.ArkData';
import { pointer } from '@kit.InputKit';
import { Environment, fileIo, fileUri } from '@kit.CoreFileKit';
import { ensureNotificationEnabled, publishNotification } from '../common/HostBridge';
import { frameWindows } from '../common/FrameWindowManager';
import { OpenSourceButton, OpenSourceDialog } from '../components/OpenSource';

/* One entry of an Emacs menu.  `index' is the position of the entry in a
   pre-order walk of the whole menu tree, which is the value reported back
   to Emacs when the entry is picked.  */
interface HostMenuItem {
  kind: string;          // item | separator | pane | submenu
  label: string;
  enabled: boolean;
  id: number;            // C-side menu_items index (item kind only)
  keys: string;
  selected: boolean;
  toggle: boolean;
  radio: boolean;
  help: string;
  submenu: HostMenuLevel | null;
}

interface HostMenuLevel {
  title: string;
  items: HostMenuItem[];
}

/* Shape of the JSON emitted by emacs/src/ohosmenu.c.  ArkTS has no
   structural typing, so the raw payload gets its own interfaces.  */
interface HostMenuBarItem {
  index: number;
  label: string;
}

interface RawMenuBar {
  bar?: HostMenuBarItem[];
}

interface RawMenuItem {
  kind?: string;
  label?: string;
  enabled?: boolean;
  id?: number;
  keys?: string;
  selected?: boolean;
  toggle?: boolean;
  radio?: boolean;
  help?: string;
  items?: RawMenuItem[];
}

interface RawMenuLevel {
  title?: string;
  items?: RawMenuItem[];
}

interface GuiStatusJson {
  width?: number;
  height?: number;
  cols?: number;
  rows?: number;
  textCols?: number;
  textRows?: number;
  surfaceSized?: boolean;
  flushP95Ms?: number;
  blitP95Ms?: number;
  directPresents?: number;
  fullCopies?: number;
  partialCopies?: number;
  rowsCopied?: number;
  fallbacks?: number;
  pendingCmds?: number;
}

interface NotifyJson {
  title?: string;
  text?: string;
}

@Entry
@Component
struct Gui {
  @State status: string = '正在启动原生 GUI...';
  @State error: string = '';
  @State surfaceReady: boolean = false;
  @State title: string = 'Homacs';
  @State busy: boolean = false;
  @State bellFlash: boolean = false;
  @State menuVisible: boolean = false;
  @State menuDialog: boolean = false;
  @State menubar: HostMenuBarItem[] = [];
  /* Menu rendering.  The in-page panel is the supported path: it owns its
     open/close lifecycle, so Escape cancels it, clicking outside closes
     it, and the key focus always returns to the frame (task book M-1..M-6).
     The ArkUI bindMenu variant does not expose that lifecycle (its popup
     never took the key focus, so Escape reached Emacs and left a meta
     prefix pending), so it stays behind this switch.  */
  private useSystemMenu: boolean = false;
  @State sysMenuShow: boolean = false;
  private runtimeTarLen: number = 0;
  /* Per-frame menu state for subwindows.  The typed host event mailbox is
     process-wide, so the main page routes frame != 1 payloads through
     AppStorage for pages/Frame to consume.  */
  @State menuTitle: string = '';
  @State menuItems: HostMenuItem[] = [];
  @State menuDepth: number = 0;
  private fullscreen: boolean = false;
  @State showLicenses: boolean = false;
  private filesDir: string = '';
  private runtime: string = '';
  private phase: string = 'init';
  private dumpReady: boolean = false;
  private dumpStartMs: number = 0;
  private dumpViaAbility: boolean = false;
  private dumpTicks: number = 0;
  private timer: number = -1;
  private publishDisplayMetrics(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const xdpi = d.xDPI > 0 ? d.xDPI : d.densityDPI;
      const ydpi = d.yDPI > 0 ? d.yDPI : d.densityDPI;
      entry.guiSetDisplayMetrics(d.densityDPI, d.densityPixels, d.scaledDensity,
        xdpi, ydpi);
    } catch (e) {
      hilog.error(0x0000, 'arkui.gui', 'display metrics failed: %{public}s',
        JSON.stringify(e));
    }
  }

  private started: boolean = false;
  private guiAttached: boolean = false;
  private demo: string = '';
  private lastClipboard: string = '';
  private startupPermissionsAsked: boolean = false;
  private lastCursor: string = '';
  /* Mouse drag bookkeeping for the surface.  A drag that starts in the
     XComponent and ends over the ArkUI menu bar must not turn the release
     into a menu-bar click.  */
  private surfacePointerDown: boolean = false;
  private surfaceDrag: boolean = false;
  private surfaceDownX: number = 0;
  private surfaceDownY: number = 0;
  private suppressMenuBarClick: boolean = false;
  /* Host focus state.  ArkUI reports focus before Emacs exists, so the
     state is kept here and (re)reported as soon as the backend is up --
     the same order a window manager gives a backend (map, then focus).  */
  private focusState: boolean = true;
  private focusPeerReady: boolean = false;
  /* Reported once the backend reports a real frame (textRows > 0): that is
     the moment Emacs' frame exists and can act on a focus event. */
  private focusFrameSeen: boolean = false;
  /* Window id for pointer style calls.  Resolved once: asking for the
     window on every cursor change and from inside hover made the style
     call re-enter the hover callback, which hung the app.  */
  private pointerWindowId: number = -1;
  private hostCommands: number = 0;
  private areaW: number = 1;
  private areaH: number = 1;
  private menuId: number = -1;
  private menuStack: HostMenuLevel[] = [];
  private bellTimer: number = -1;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.demo = AppStorage.get<string>('guiDemo') ?? '';
    this.filesDir = ctx.filesDir;
    this.runtime = ctx.filesDir + '/runtime102';
    hilog.info(0x0000, 'arkui.gui', 'startup buildId=%{public}s runtime=%{public}s',
      entry.buildId(), this.runtime);
    this.registerHostWake();
    this.primePointer();
    // READ_PASTEBOARD is user_grant: ask once after startup so that
    // `gui-get-selection' / C-y can read the system clipboard.  The
    // permission must also be provisioned through the signing profile's
    // ACL, otherwise this request is denied.
    void this.requestStartupPermissions(ctx);
    try {
      this.decideStart();
    } catch (e) {
      hilog.error(0x0000, 'arkui.gui', 'decideStart failed: %{public}s',
        JSON.stringify(e));
    }
    setTimeout(() => {
      if (!this.started && this.error.length === 0) {
        this.status = '等待原生绘制线程...';
      }
    }, 3000);
  }

  private async requestStartupPermissions(ctx: common.UIAbilityContext): Promise<void> {
    if (this.startupPermissionsAsked) {
      return;
    }
    this.startupPermissionsAsked = true;
    const permissions: Array<Permissions> = [
      'ohos.permission.READ_PASTEBOARD',
      'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
      'ohos.permission.READ_WRITE_DESKTOP_DIRECTORY',
      'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'
    ];
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(ctx, permissions);
      for (let i = 0; i < permissions.length; i++) {
        const granted = i < result.authResults.length && result.authResults[i] === 0;
        hilog.info(0x0000, 'arkui.gui',
          'permission %{public}s granted=%{public}s', permissions[i], granted);
      }
      try {
        hilog.info(0x0000, 'arkui.gui',
          'user dirs desktop=%{public}s documents=%{public}s download=%{public}s',
          Environment.getUserDesktopDir(), Environment.getUserDocumentDir(),
          Environment.getUserDownloadDir());
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(0x0000, 'arkui.gui',
          'user dirs failed code=%{public}d message=%{public}s', err.code, err.message);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'arkui.gui',
        'permission request failed code=%{public}d message=%{public}s',
        err.code, err.message);
    }
  }


  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      clearTimeout(this.timer);
      this.timer = -1;
    }
    if (this.bellTimer >= 0) {
      clearTimeout(this.bellTimer);
      this.bellTimer = -1;
    }
    if (this.guiAttached) {
      entry.guiDetach();
    }
  }

  /* The runtime tarball ships inside the HAP but was extracted only once, so
     a new build with updated Lisp files kept running the old tree.  The
     stamp is the build id, the libemacs version and the tarball length: the
     length changes whenever pack-runtime.sh repacks it, which the other two
     do not.  */
  private runtimeStamp(tarLength: number): string {
    return entry.buildId() + ':' + entry.libemacsVersion() + ':' + tarLength;
  }

  /* Length of the runtime tarball inside the HAP, 0 when unavailable.  */
  private runtimeTarLength(): number {
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      const rf = ctx.resourceManager.getRawFdSync('emacs-runtime.tar.gz');
      const len = rf.length;
      ctx.resourceManager.closeRawFdSync('emacs-runtime.tar.gz');
      return len;
    } catch (e) {
      hilog.warn(0x0000, 'arkui.gui', 'runtime rawfile unavailable: %{public}s',
        JSON.stringify(e));
      return 0;
    }
  }

  decideStart(): void {
    hilog.info(0x0000, 'arkui.gui', 'decideStart enter');
    const tarLen = this.runtimeTarLength();
    const stamp = entry.fileRead(this.runtime + '/runtime.stamp');
    const want = this.runtimeStamp(tarLen);
    const fresh = stamp.length > 0 && stamp === want;
    hilog.info(0x0000, 'arkui.gui', 'runtime stamp=%{public}s want=%{public}s',
      stamp, want);
    if (fresh && entry.runtimeReady(this.runtime + '/lisp/loadup.el') === 1) {
      this.dumpReady = true;
      this.status = '';
      this.startGui();
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      hilog.info(0x0000, 'arkui.gui', 'installing runtime tarball');
      const rf = ctx.resourceManager.getRawFdSync('emacs-runtime.tar.gz');
      const tar = this.filesDir + '/emacs-runtime.tar.gz';
      entry.startInstallRuntime(rf.fd, rf.offset, rf.length, tar, this.runtime);
      ctx.resourceManager.closeRawFdSync('emacs-runtime.tar.gz');
      this.runtimeTarLen = tarLen;
      this.phase = 'install';
      this.status = '正在安装 Emacs 运行时（首次启动，请稍候）...';
      this.timer = setInterval(() => this.tickInstall(), 300);
    } catch (e) {
      hilog.error(0x0000, 'arkui.gui', 'runtime resource failed: %{public}s',
        JSON.stringify(e));
      this.showError('运行时资源不可用：' + JSON.stringify(e));
    }
  }

  tickInstall(): void {
    const st = entry.installState();
    this.status = '正在解包运行时：' + st;
    if (st.indexOf('"done":true') >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
      hilog.info(0x0000, 'arkui.gui', 'runtime install done');
      entry.fileWrite(this.runtime + '/runtime.stamp',
        this.runtimeStamp(this.runtimeTarLen));
      this.dumpReady = true;
      this.startGui();
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
      'EMACS_OHOS_GUI=1\n' +
      'EMACS_OHOS_DRAW_DEBUG=1\n' +
      (this.demo === 'mouse' ? 'EMACS_OHOS_GUI_MOUSE=1\n' : '') +
      'LANG=C.UTF-8';
  }

  startDump(): void {
    this.phase = 'dump';
    this.dumpStartMs = Date.now();
    this.dumpTicks = 0;
    this.dumpViaAbility = true;
    this.status = '正在生成 Emacs dump...';
    const ctx = getContext(this) as common.UIAbilityContext;
    const want: Want = {
      bundleName: 'emacs.hmos.org',
      abilityName: 'DumpAbility',
      parameters: {
        runtime: this.runtime,
        env: this.envText()
      }
    };
    ctx.startAbility(want).catch((e: Error) => {
      this.showError('无法启动 DumpAbility：' + e.message);
    });
    this.timer = setInterval(() => this.tickDump(), 300);
  }

  tickDump(): void {
    this.dumpTicks += 1;
    if (this.dumpStartMs > 0 && Date.now() - this.dumpStartMs > 240000) {
      clearInterval(this.timer);
      this.timer = -1;
      this.showError('生成 dump 超时');
      return;
    }
    if (this.dumpTicks % 3 !== 0) {
      return;
    }
    if (entry.runtimeReady(this.runtime + '/bootstrap-emacs.pdmp') === 1) {
      clearInterval(this.timer);
      this.timer = -1;
      entry.fileWrite(this.runtime + '/dump.stamp',
        entry.buildId() + ':' + entry.libemacsVersion());
      this.dumpReady = true;
      this.status = '';
      this.startGui();
    }
  }

  startGui(): void {
    if (this.started || !this.dumpReady) {
      return;
    }
    this.started = true;
    this.phase = 'run';
    this.status = '';
    hilog.info(0x0000, 'arkui.gui', 'startGui');
    /* This build is CANNOT_DUMP (configure --with-dumping=none): there is no
       portable dump, Emacs always boots by loading loadup.el from the
       runtime lisp tree.  Passing --dump-file would be an unknown option,
       so do not add it.  */
    let args = '--no-build-details';
    if (this.demo === 'cjk') {
      args += '\n--eval\n(progn (switch-to-buffer "*cjk*")'
        + ' (insert "中文测试 — HarmonyOS") (goto-char (point-min))'
        + ' (send-string-to-terminal "\u001b]52;c;Y2xpcGJvYXJkLXRlc3Q=\u0007")'
        + ' (send-string-to-terminal "\u001b]2;Emacs CJK — HarmonyOS\u0007"))';
    } else if (this.demo === 'mouse') {
      args += '\n--eval\n(progn (switch-to-buffer "*mouse*")'
        + ' (insert "mouse line one\\nmouse line two\\nmouse line three")'
        + ' (goto-char (point-min)) (xterm-mouse-mode 1))';
    } else if (this.demo === 'osc52') {
      args += '\n--eval\n(send-string-to-terminal "\u001b]52;c;Y2xpcGJvYXJkLXRlc3Q=\u0007")';
    }
    this.status = '正在启动 Emacs…';
    this.publishDisplayMetrics();
    const rc = entry.startInProcess(args, this.envText(), this.runtime);
    hilog.info(0x0000, 'arkui.gui', 'startInProcess rc=%{public}d', rc);
    this.guiAttached = true;
    this.focusPeerReady = true;
    entry.guiFocus(this.focusState);
  }

  /* Draw work and host-event draining are event-driven through the native
     TSFN wakeup.  There is no periodic tick.  */
  private registerHostWake(): void {
    entry.registerHostWake(() => {
      if (!this.guiAttached) {
        return;
      }
      this.pumpHostCommands();
      this.pollNativeChrome();
      this.checkFirstFrame();
    });
  }

  /* First-frame status is event-driven: the host wake fires once the
     surface has produced a frame.  No periodic tick is needed. */
  private checkFirstFrame(): void {
    if (this.focusFrameSeen) {
      return;
    }
    try {
      const st = JSON.parse(entry.guiState()) as GuiStatusJson;
      if (st.textRows !== undefined && st.textRows > 0) {
        this.focusFrameSeen = true;
        this.status = '';
        entry.guiFocus(this.focusState);
        hilog.info(0x0000, 'arkui.gui', 'first frame rows=%{public}d',
          st.textRows);
      }
    } catch (e) {
    }
  }

  pollNativeChrome(): void {
    /* Escape is consumed by the native key handler while a menu is open;
       take the cancel request here so the popup closes and the frame gets
       the key focus back.  */
    if (entry.guiTakeMenuEsc() === 1) {
      hilog.info(0x0000, 'arkui.gui', 'menu cancel (esc)');
      this.dismissMenu();
    }
    const clip = entry.guiClipboard();
    if (clip.length > 0 && clip !== this.lastClipboard) {
      this.lastClipboard = clip;
      hilog.info(0x0000, 'arkui.gui', 'OSC52 clipboard len=%{public}d', clip.length);
      this.setClipboard(clip);
    }
    const t = entry.guiTitle();
    if (t.length > 0 && t !== this.title) {
      this.title = t;
      window.getLastWindow(getContext(this)).then((win: window.Window) => {
        win.setWindowTitle(t).catch(() => {});
      }).catch(() => {});
    }
  }

  showError(msg: string): void {
    this.error = msg;
    this.status = '';
    hilog.error(0x0000, 'arkui.gui', 'error: %{public}s', msg);
  }

  retry(): void {
    this.error = '';
    this.phase = 'init';
    this.started = false;
    this.guiAttached = false;
    entry.guiDetach();
    this.decideStart();
  }

  /* ------------------------------------------------------------------ */
  /* Host chrome channel.                                               */

  pumpHostCommands(): void {
    for (let i = 0; i < 16; i++) {
      const event = entry.guiTakeHostEvent();
      if (event === null) {
        return;
      }
      this.hostCommands += 1;
      try {
        this.handleHostEvent(event);
      } catch (e) {
        hilog.error(0x0000, 'arkui.gui', 'host event failed: %{public}s',
          JSON.stringify(e));
      }
    }
  }

  private cursorName(kind: number): string {
    if (kind === 1) {
      return 'text';
    } else if (kind === 2) {
      return 'hand';
    } else if (kind === 3) {
      return 'hourglass';
    } else if (kind === 4) {
      return 'vdrag';
    } else if (kind === 5) {
      return 'hdrag';
    } else if (kind === 6) {
      return 'none';
    }
    return 'default';
  }

  handleHostEvent(event: HostEvent): void {
    const frameId = event.frameId;
    switch (event.op) {
      case 1: {
        frameWindows.create({
          frameId: frameId,
          width: event.a,
          height: event.b,
          x: event.c,
          y: event.d,
          parentFrameId: event.e,
          undecorated: event.f !== 0,
          dialog: event.g !== 0,
          title: event.text
        }).catch((e: Error) => {
          entry.guiWindowCreateFailed(frameId, e.message);
        });
        break;
      }
      case 2:
        frameWindows.destroy(frameId).catch((e: Error) => {
          hilog.error(0x0000, 'arkui.gui', 'destroy failed: %{public}s',
            e.message);
        });
        break;
      case 3:
        frameWindows.raise(frameId).catch((e: Error) => {
          hilog.warn(0x0000, 'arkui.gui', 'raise failed: %{public}s',
            e.message);
        });
        break;
      case 4:
        frameWindows.lower(frameId).catch((e: Error) => {
          hilog.warn(0x0000, 'arkui.gui', 'lower failed: %{public}s',
            e.message);
        });
        break;
      case 5:
        frameWindows.setTitle(frameId, event.text).catch((e: Error) => {
          hilog.warn(0x0000, 'arkui.gui', 'title failed: %{public}s',
            e.message);
        });
        break;
      case 6:
        frameWindows.resize(frameId, event.a, event.b).catch((e: Error) => {
          hilog.warn(0x0000, 'arkui.gui', 'resize failed: %{public}s',
            e.message);
        });
        break;
      case 7:
        frameWindows.move(frameId, event.a, event.b).catch((e: Error) => {
          hilog.warn(0x0000, 'arkui.gui', 'move failed: %{public}s',
            e.message);
        });
        break;
      case 8:
        if (frameId === 1) {
          this.hostWindowVisible(event.a !== 0);
        } else {
          frameWindows.setVisible(frameId, event.a !== 0);
        }
        break;
      case 9:
        if (frameId === 1) {
          this.hostFullscreen(event.a !== 0);
        } else {
          frameWindows.setFullscreen(frameId, event.a !== 0);
        }
        break;
      case 10:
        if (frameId === 1) {
          this.hostMinimize();
        } else {
          frameWindows.minimize(frameId);
        }
        break;
      case 11:
        if (frameId === 1) {
          this.hostAlpha(event.a);
        } else {
          frameWindows.setAlpha(frameId, event.a);
        }
        break;
      case 12:
        if (frameId === 1) {
          this.hostCursor(this.cursorName(event.a));
        } else {
          AppStorage.setOrCreate('cursor_' + frameId, this.cursorName(event.a));
        }
        break;
      case 13:
        if (frameId === 1) {
          this.busy = event.a !== 0;
        } else {
          AppStorage.setOrCreate('hourglass_' + frameId, event.a !== 0);
        }
        break;
      case 14:
        if (frameId === 1) {
          this.hostBell();
        } else {
          AppStorage.setOrCreate('bell_' + frameId, Date.now());
        }
        break;
      case 15:
        hilog.info(0x0000, 'arkui.gui', 'pointer-warp frame=%{public}d ignored',
          frameId);
        break;
      case 16:
        frameWindows.setNoFocusOnMap(frameId, event.a !== 0);
        break;
      case 17:
        frameWindows.setNoAcceptFocus(frameId, event.a !== 0);
        break;
      case 18:
        hilog.info(0x0000, 'arkui.gui', 'typed menubar frame=%{public}d',
          frameId);
        if (frameId === 1) {
          try {
            const parsed = JSON.parse(event.text) as RawMenuBar;
            this.menubar = parsed.bar === undefined || parsed.bar === null
              ? [] : parsed.bar;
            hilog.info(0x0000, 'arkui.gui', 'menubar items=%{public}d',
              this.menubar.length);
          } catch (e) {
            hilog.error(0x0000, 'arkui.gui', 'menubar parse failed');
          }
        } else {
          AppStorage.setOrCreate('menubar_' + frameId, event.text);
        }
        break;
      case 19:
        hilog.info(0x0000, 'arkui.gui',
          'typed menu frame=%{public}d id=%{public}d', frameId, event.a);
        if (frameId === 1) {
          this.hostMenu(event.a, event.c !== 0, event.text);
        } else {
          AppStorage.setOrCreate('menu_' + frameId, JSON.stringify({
            id: event.a, dialog: event.c !== 0, json: event.text,
            seq: Date.now()
          }));
          entry.guiMenuOpen(1);
        }
        break;
      case 20:
        if (frameId === 1) {
          if (event.a === this.menuId) {
            this.menuVisible = false;
            this.menuItems = [];
            this.menuStack = [];
            this.menuDepth = 0;
            this.menuTitle = '';
            this.menuId = -1;
          }
        } else {
          AppStorage.setOrCreate('menu_' + frameId, JSON.stringify({
            id: -1, dialog: false, json: '', seq: Date.now()
          }));
          entry.guiMenuOpen(0);
        }
        break;
      case 21:
        if (event.a === 0) {
          this.hostClipboardGet(event.b);
        } else if (event.a === 3) {
          this.hostNotify(event.text);
        }
        break;
      default:
        hilog.warn(0x0000, 'arkui.gui', 'unknown host event op=%{public}d',
          event.op);
        break;
    }
  }

  private getMainWindow(): Promise<window.Window | undefined> {
    const cached = AppStorage.get<window.Window>('mainWindow');
    if (cached !== undefined) {
      return Promise.resolve(cached);
    }
    return window.getLastWindow(getContext(this)).then((win: window.Window) => {
      AppStorage.setOrCreate('mainWindow', win);
      return win;
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, 'arkui.gui', 'getLastWindow failed: %{public}s', err.message);
      return undefined;
    });
  }

  private hostResize(w: number, h: number): void {
    if (!(w > 0) || !(h > 0)) {
      hilog.warn(0x0000, 'arkui.gui', 'resize ignored: %{public}d %{public}d', w, h);
      return;
    }
    this.getMainWindow().then((win: window.Window | undefined) => {
      if (win === undefined) {
        return;
      }
      win.resizeAsync(w, h).then(() => {
        hilog.info(0x0000, 'arkui.gui', 'resizeAsync %{public}dx%{public}d', w, h);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0000, 'arkui.gui', 'resizeAsync failed (%{public}s), trying resize',
          err.message);
        win.resize(w, h).catch((e2: BusinessError) => {
          hilog.error(0x0000, 'arkui.gui', 'resize failed: %{public}s', e2.message);
        });
      });
    });
  }

  private hostMove(x: number, y: number): void {
    this.getMainWindow().then((win: window.Window | undefined) => {
      if (win === undefined) {
        return;
      }
      win.moveWindowToAsync(x, y).then(() => {
        hilog.info(0x0000, 'arkui.gui', 'moveWindowToAsync %{public}d,%{public}d', x, y);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0000, 'arkui.gui', 'moveWindowToAsync failed (%{public}s), trying moveWindowTo',
          err.message);
        win.moveWindowTo(x, y).catch((e2: BusinessError) => {
          hilog.error(0x0000, 'arkui.gui', 'moveWindowTo failed: %{public}s', e2.message);
        });
      });
    });
  }

  private hostFullscreen(on: boolean): void {
    this.getMainWindow().then((win: window.Window | undefined) => {
      if (win === undefined) {
        return;
      }
      this.fullscreen = on;
      win.setWindowLayoutFullScreen(on).then(() => {
        win.setWindowDecorVisible(!on);
        hilog.info(0x0000, 'arkui.gui', 'fullscreen=%{public}d', on ? 1 : 0);
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, 'arkui.gui', 'fullscreen failed: %{public}s', err.message);
      });
    });
  }

  private hostMaximize(): void {
    this.getMainWindow().then((win: window.Window | undefined) => {
      if (win === undefined) {
        return;
      }
      win.maximize().catch((err: BusinessError) => {
        hilog.error(0x0000, 'arkui.gui', 'maximize failed: %{public}s', err.message);
      });
    });
  }

  private hostMinimize(): void {
    this.getMainWindow().then((win: window.Window | undefined) => {
      if (win === undefined) {
        return;
      }
      win.minimize().catch((err: BusinessError) => {
        hilog.error(0x0000, 'arkui.gui', 'minimize failed: %{public}s', err.message);
      });
    });
  }

  /* showWindow() re-shows (and raises) an application main window;
     hideWindow() is not available for it, so hiding maps to minimize.  */
  private hostWindowVisible(on: boolean): void {
    hilog.info(0x0000, 'arkui.gui', 'window-visible %{public}d -> %{public}s',
      on ? 1 : 0, on ? 'showWindow' : 'minimize');
    if (on) {
      this.hostRaise();
    } else {
      this.hostMinimize();
    }
  }

  /* Move the main window to the top of the window stack.  */
  private hostRaise(): void {
    this.getMainWindow().then((win: window.Window | undefined) => {
      if (win === undefined) {
        return;
      }
      win.showWindow().catch((err: BusinessError) => {
        hilog.error(0x0000, 'arkui.gui', 'showWindow failed: %{public}s', err.message);
      });
    });
  }

  private hostAlpha(value: number): void {
    /* window.Window has no opacity setter for a normal application window
       in this SDK; keep the request visible instead of failing silently. */
    hilog.warn(0x0000, 'arkui.gui',
      'alpha %{public}d ignored: setWindowOpacity is not available for app windows',
      value);
  }

  private cursorStyle(name: string): pointer.PointerStyle {
    if (name === 'text') {
      return pointer.PointerStyle.TEXT_CURSOR;
    } else if (name === 'hand') {
      return pointer.PointerStyle.HAND_POINTING;
    } else if (name === 'hourglass') {
      return pointer.PointerStyle.LOADING;
    } else if (name === 'vdrag' || name === 'updown') {
      return pointer.PointerStyle.RESIZE_UP_DOWN;
    } else if (name === 'hdrag' || name === 'leftright') {
      return pointer.PointerStyle.RESIZE_LEFT_RIGHT;
    }
    return pointer.PointerStyle.DEFAULT;
  }

  private hostCursor(name: string): void {
    if (name === this.lastCursor) {
      return;
    }
    this.lastCursor = name;
    /* `cursor none' is Emacs' pointer auto-hide.  Never hide the system
       pointer: it is the only pointer this window has.  */
    if (name === 'none') {
      hilog.info(0x0000, 'arkui.gui', 'cursor none ignored (pointer stays visible)');
      return;
    }
    this.applyPointerStyle(this.cursorStyle(name), name);
  }

  /* The menu bar and other ArkUI chrome are outside the XComponent.  Emacs
     keeps its last cursor shape when the native pointer leaves the surface,
     so reset the system pointer on leave and restore it on re-entry.  Do it
     from a timer: setPointerStyleSync must not run inside onHover.  */
  private hoverPointer(isHover: boolean): void {
    if (this.pointerWindowId < 0) {
      return;
    }
    const name = isHover ? this.lastCursor : 'default';
    const style = isHover ? this.cursorStyle(name)
      : pointer.PointerStyle.DEFAULT;
    setTimeout(() => {
      this.applyPointerStyle(style, name);
    }, 0);
  }

  /* Apply a pointer style without touching the window lookup or the hover
     callback: both re-enter this path and hang the app.  */
  private applyPointerStyle(style: pointer.PointerStyle, name: string): void {
    if (this.pointerWindowId < 0) {
      return;                       /* primePointer() applies DEFAULT soon */
    }
    try {
      pointer.setPointerStyleSync(this.pointerWindowId, style);
      hilog.info(0x0000, 'arkui.gui', 'cursor=%{public}s', name);
    } catch (e) {
      hilog.warn(0x0000, 'arkui.gui', 'cursor %{public}s not supported: %{public}s',
        name, JSON.stringify(e));
    }
  }

  private trackSurfaceMouse(event: MouseEvent): void {
    if (event.action === MouseAction.Press) {
      this.surfacePointerDown = true;
      this.surfaceDrag = false;
      this.surfaceDownX = event.x;
      this.surfaceDownY = event.y;
    } else if (event.action === MouseAction.Move && this.surfacePointerDown) {
      if (Math.abs(event.x - this.surfaceDownX) > 4
          || Math.abs(event.y - this.surfaceDownY) > 4) {
        this.surfaceDrag = true;
      }
    } else if (event.action === MouseAction.Release) {
      if (this.surfaceDrag) {
        this.suppressMenuBarClick = true;
        setTimeout(() => {
          this.suppressMenuBarClick = false;
        }, 300);
      }
      this.surfacePointerDown = false;
      this.surfaceDrag = false;
    }
  }

  private onMenuBarClick(index: number): void {
    hilog.info(0x0000, 'arkui.menu',
      'menu request source=bar frame=1 index=%{public}d', index);
    if (this.surfacePointerDown || this.surfaceDrag
        || this.suppressMenuBarClick) {
      /* The press began in the text surface (or a drag just ended over the
         bar).  Consume the spurious click and reset the drag state.  */
      this.surfacePointerDown = false;
      this.surfaceDrag = false;
      this.suppressMenuBarClick = false;
      hilog.info(0x0000, 'arkui.menu',
        'menu request-suppressed frame=1 index=%{public}d reason=drag', index);
      return;
    }
    entry.guiMenuBarClick(index);
    focusControl.requestFocus('emacs_gui');
  }

  /* ArkUI chrome (menu bar) is outside the XComponent; reset the system
     pointer there and restore Emacs' last shape when leaving it.  */
  private hoverMenuBar(isHover: boolean): void {
    if (isHover && (this.surfacePointerDown || this.surfaceDrag)) {
      this.suppressMenuBarClick = true;
      setTimeout(() => {
        this.suppressMenuBarClick = false;
      }, 300);
    }
    if (this.pointerWindowId < 0) {
      return;
    }
    const name = isHover ? 'default' : this.lastCursor;
    const style = isHover ? pointer.PointerStyle.DEFAULT
      : this.cursorStyle(name);
    setTimeout(() => {
      this.applyPointerStyle(style, name);
    }, 0);
  }

  private hostBell(): void {
    this.bellFlash = true;
    if (this.bellTimer >= 0) {
      clearTimeout(this.bellTimer);
    }
    this.bellTimer = setTimeout(() => {
      this.bellFlash = false;
      this.bellTimer = -1;
    }, 180);
  }

  private hostMenu(id: number, dialog: boolean, json: string): void {
    const level = this.parseMenuLevel(json);
    if (level === null) {
      hilog.error(0x0000, 'arkui.menu', 'menu parse-failed menu=%{public}d', id);
      entry.guiMenuResult(id, -1);
      return;
    }
    /* Emacs waits for exactly one answer per menu id: close a menu that is
       still open before adopting a new one, otherwise the previous wait
       stays blocked and every later menu click does nothing.  */
    if (this.menuId >= 0 && this.menuId !== id) {
      const stale = this.menuId;
      this.menuId = -1;
      entry.guiMenuResult(stale, -1);
      hilog.info(0x0000, 'arkui.menu',
        'menu supersede old=%{public}d new=%{public}d', stale, id);
    }
    this.menuId = id;
    this.menuStack = [level];
    this.menuDepth = 1;
    this.menuTitle = level.title;
    this.menuItems = level.items;
    this.menuDialog = dialog;
    if (this.useSystemMenu) {
      this.sysMenuShow = true;
    } else {
      this.menuVisible = true;
    }
    entry.guiMenuOpen(1);
    hilog.info(0x0000, 'arkui.menu',
      'menu ui-open menu=%{public}d dialog=%{public}s items=%{public}d',
      id, dialog ? '1' : '0', String(level.items.length));
  }

  private parseMenuLevel(json: string): HostMenuLevel | null {
    try {
      const root = JSON.parse(json) as RawMenuLevel;
      if (root === null || root === undefined) {
        return null;
      }
      return this.normalizeMenuLevel(root);
    } catch (e) {
      hilog.error(0x0000, 'arkui.gui', 'menu parse failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /* Convert one level of the JSON emitted by emacs/src/ohosmenu.c.  Every
     field is optional in the payload, so each one is defaulted here; the
     `id` is the absolute menu_items index and is what Emacs needs back.  */
  private normalizeMenuLevel(raw: RawMenuLevel): HostMenuLevel {
    const title: string = raw.title === undefined || raw.title === null ? '' : raw.title;
    const items: HostMenuItem[] = [];
    const src: RawMenuItem[] | undefined = raw.items;
    if (src !== undefined && src !== null) {
      for (let i = 0; i < src.length; i++) {
        const r = src[i];
        const kind: string = r.kind === undefined || r.kind === null ? 'item' : r.kind;
        const label: string = r.label === undefined || r.label === null ? '' : r.label;
        const enabled: boolean = r.enabled === undefined || r.enabled === null
          ? true : r.enabled;
        const id: number = r.id === undefined || r.id === null ? -1 : r.id;
        const keys: string = r.keys === undefined || r.keys === null ? '' : r.keys;
        const selected: boolean = r.selected === true;
        const toggle: boolean = r.toggle === true;
        const radio: boolean = r.radio === true;
        const help: string = r.help === undefined || r.help === null ? '' : r.help;
        let submenu: HostMenuLevel | null = null;
        if (kind === 'submenu' && r.items !== undefined && r.items !== null) {
          submenu = this.normalizeMenuLevel({ title: '', items: r.items });
        }
        items.push({
          kind: kind, label: label, enabled: enabled, id: id, keys: keys,
          selected: selected, toggle: toggle, radio: radio, help: help,
          submenu: submenu
        });
      }
    }
    return { title: title, items: items };
  }

  /* Marker shown before a label: submenu arrow, check mark, radio dot.  */
  private menuMark(item: HostMenuItem): string {
    if (this.menuDialog) {
      return '  ';
    }
    if (item.kind === 'submenu') {
      return '▸ ';
    }
    if (item.toggle && item.selected) {
      return '✓ ';
    }
    if (item.radio && item.selected) {
      return '● ';
    }
    return '  ';
  }

  private pickMenuItem(position: number): void {
    if (position < 0 || position >= this.menuItems.length) {
      return;
    }
    const item = this.menuItems[position];
    if (!item.enabled || item.kind === 'separator' || item.kind === 'pane') {
      return;
    }
    if (item.submenu !== null) {
      hilog.info(0x0000, 'arkui.menu',
        'menu submenu menu=%{public}d item=%{public}d depth=%{public}d',
        this.menuId, item.id, this.menuStack.length + 1);
      this.menuStack.push(item.submenu);
      this.menuDepth = this.menuStack.length;
      this.menuTitle = item.submenu.title;
      this.menuItems = item.submenu.items;
      if (this.useSystemMenu) {
        /* The ArkUI menu is a flat list per level: close it and reopen it
           with the submenu's items. */
        this.sysMenuShow = false;
        setTimeout(() => { this.sysMenuShow = true; }, 80);
      }
      return;
    }
    hilog.info(0x0000, 'arkui.menu',
      'menu pick menu=%{public}d item=%{public}d position=%{public}d',
      this.menuId, item.id, position);
    this.closeMenu(item.id);
  }

  private menuBack(): void {
    if (this.menuStack.length <= 1) {
      this.dismissMenu();
      return;
    }
    this.menuStack.pop();
    const level = this.menuStack[this.menuStack.length - 1];
    this.menuDepth = this.menuStack.length;
    this.menuTitle = level.title;
    this.menuItems = level.items;
    hilog.info(0x0000, 'arkui.menu',
      'menu back menu=%{public}d depth=%{public}d', this.menuId,
      this.menuDepth);
    if (this.useSystemMenu) {
      this.sysMenuShow = false;
      setTimeout(() => { this.sysMenuShow = true; }, 80);
    }
  }

  /* ArkUI owns the menu popup, so it also decides when the menu goes away
     (click outside, Esc, window blur).  Without this callback the menu
     disappeared but key focus stayed on the popup, which made the frame
     untypable after cancelling a menu.  */
  private menuOptions(): MenuOptions {
    return {
      showInSubWindow: false,
      onDisappear: () => {
        entry.guiMenuOpen(0);
        this.sysMenuShow = false;
        const id = this.menuId;
        this.menuId = -1;
        this.menuItems = [];
        this.menuStack = [];
        this.menuDepth = 0;
        this.menuTitle = '';
        this.menuVisible = false;
        if (id >= 0) {
          hilog.info(0x0000, 'arkui.menu',
            'menu disappear menu=%{public}d result=cancel', id);
          entry.guiMenuResult(id, -1);
        }
        this.restoreFrameFocus();
      }
    } as MenuOptions;
  }

  private dismissMenu(): void {
    hilog.info(0x0000, 'arkui.menu', 'menu dismiss menu=%{public}d',
      this.menuId);
    this.closeMenu(-1);
  }

  private closeMenu(index: number): void {
    const id = this.menuId;
    entry.guiMenuOpen(0);
    this.menuVisible = false;
    this.sysMenuShow = false;
    this.menuItems = [];
    this.menuStack = [];
    this.menuDepth = 0;
    this.menuTitle = '';
    this.menuId = -1;
    if (id >= 0) {
      hilog.info(0x0000, 'arkui.menu',
        'menu result-request menu=%{public}d index=%{public}d', id, index);
      entry.guiMenuResult(id, index);
    }
    /* Choosing (or cancelling) a menu must not leave key focus on the
       ArkUI menu: Emacs would stop receiving keys.  */
    this.restoreFrameFocus();
  }

  /* A tap on the text area is a mouse click: put key focus back on the
     XComponent.  Soft-keyboard input is owned by the system IME, not by
     an in-page keyboard component.  */
  private onSurfaceTap(_touch: boolean = true): void {
    /* Seamless IME integration: both a touch tap and a mouse click ask the
       system IME to attach.  There is no in-page keyboard button and no
       source-dependent behaviour. */
    focusControl.requestFocus('emacs_gui');
    entry.guiShowIme();
  }

  private restoreFrameFocus(): void {
    setTimeout(() => {
      focusControl.requestFocus('emacs_gui');
    }, 60);
  }

  private hostNotify(json: string): void {
    try {
      const msg = JSON.parse(json) as NotifyJson;
      const title: string = msg.title === undefined || msg.title === null ? 'Emacs' : msg.title;
      const text: string = msg.text === undefined || msg.text === null ? '' : msg.text;
      const ctx = getContext(this) as common.UIAbilityContext;
      ensureNotificationEnabled(ctx).then((enabled: boolean) => {
        if (!enabled) {
          hilog.warn(0x0000, 'arkui.gui', 'notify skipped: permission disabled');
          return;
        }
        const rc = publishNotification(title, text);
        hilog.info(0x0000, 'arkui.gui', 'notify rc=%{public}d', rc);
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, 'arkui.gui', 'notify permission failed: %{public}s',
          e.message ?? 'unknown');
      });
    } catch (e) {
      hilog.error(0x0000, 'arkui.gui', 'notify failed: %{public}s', JSON.stringify(e));
    }
  }

  private hostClipboardGet(id: number): void {
    pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
      let text = '';
      try {
        const primary = data.getPrimaryText();
        if (primary !== undefined) {
          text = primary;
        }
      } catch (e) {
        hilog.warn(0x0000, 'arkui.gui', 'pasteboard has no text: %{public}s',
          JSON.stringify(e));
      }
      entry.guiClipboardResult(id, text);
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, 'arkui.gui',
        'clipboard-get failed code=%{public}d message=%{public}s',
        err.code, err.message);
      entry.guiClipboardResult(id, '');
    });
  }

  /* ------------------------------------------------------------------ */
  /* Drag and drop: open the dropped file with C-x C-f.                  */

  private handleDropEvent(event: DragEvent): void {
    let uri = '';
    let text = '';
    try {
      const data: unifiedDataChannel.UnifiedData = event.getData();
      if (data !== null && data !== undefined) {
        const records = data.getRecords();
        for (let i = 0; i < records.length; i++) {
          const record = records[i];
          hilog.info(0x0000, 'arkui.gui', 'drop record type=%{public}s', record.getType());
          if (record instanceof unifiedDataChannel.Image) {
            const img = record as unifiedDataChannel.Image;
            const u = img.imageUri !== undefined && img.imageUri.length > 0
              ? img.imageUri : img.uri;
            if (u !== undefined && u.length > 0) {
              uri = u;
            }
          } else if (record instanceof unifiedDataChannel.Video) {
            const vid = record as unifiedDataChannel.Video;
            const u = vid.videoUri !== undefined && vid.videoUri.length > 0
              ? vid.videoUri : vid.uri;
            if (u !== undefined && u.length > 0) {
              uri = u;
            }
          } else if (record instanceof unifiedDataChannel.File) {
            const u = (record as unifiedDataChannel.File).uri;
            if (u !== undefined && u.length > 0) {
              uri = u;
            }
          } else if (record instanceof unifiedDataChannel.PlainText) {
            const t = (record as unifiedDataChannel.PlainText).textContent;
            if (t !== undefined && t.length > 0 && text.length === 0) {
              text = t;
            }
          } else if (record instanceof unifiedDataChannel.Hyperlink) {
            const u = (record as unifiedDataChannel.Hyperlink).url;
            if (u !== undefined && u.length > 0) {
              if (u.startsWith('file://')) {
                uri = u;
              } else if (text.length === 0) {
                text = u;
              }
            }
          }
          if (uri.length > 0) {
            break;
          }
        }
      }
    } catch (e) {
      hilog.error(0x0000, 'arkui.gui', 'drop data failed: %{public}s', JSON.stringify(e));
      return;
    }

    /* A file URI (file://docs/...) is not a path: keep it intact and let
       the file APIs read it under the temporary drag authorization, then
       stage a sandbox copy for Emacs.  Stripping "file://" yields a
       relative "docs/..." path, which is what broke the old drop.  */
    if (uri.length === 0 && text.startsWith('file://')) {
      uri = text;
      text = '';
    }
    if (uri.length > 0) {
      const direct = this.resolveDropPath(uri);
      if (direct.length > 0) {
        try {
          fileIo.statSync(direct);
          text = direct;
          hilog.info(0x0000, 'arkui.gui', 'drop direct: %{public}s', text);
        } catch (e) {
          hilog.warn(0x0000, 'arkui.gui', 'drop direct unavailable: %{public}s', direct);
        }
      }
      if (text.length === 0) {
        try {
          if (fileIo.statSync(uri).isDirectory()) {
            hilog.warn(0x0000, 'arkui.gui', 'drop directory not supported: %{public}s', uri);
            this.showError('拖入文件夹暂不支持');
            return;
          }
          text = this.stageDroppedFile(uri);
          hilog.info(0x0000, 'arkui.gui', 'drop staged: %{public}s', text);
        } catch (e) {
          const err = e as BusinessError;
          hilog.error(0x0000, 'arkui.gui',
            'drop stage failed code=%{public}d message=%{public}s', err.code, err.message);
          this.showError('无法读取拖入的文件: ' + (err.message ?? ''));
          return;
        }
      }
    }
    if (text.length === 0) {
      hilog.warn(0x0000, 'arkui.gui', 'drop without a path');
      return;
    }
    hilog.info(0x0000, 'arkui.gui', 'drop open: %{public}s', text);
    /* C-x C-f <path> RET, one step at a time so Emacs can redraw the
       minibuffer between the keystrokes.  */
    entry.guiWriteInput('\u0018\u0006');
    setTimeout(() => {
      entry.guiWriteInput(text);
      setTimeout(() => {
        entry.guiWriteInput('\r');
        setTimeout(() => {
          focusControl.requestFocus('emacs_gui');
        }, 60);
      }, 80);
    }, 80);
  }

  /* file://docs/storage/Users/currentUser/<dir>/... is a document URI,
     not a filesystem path.  With READ_WRITE_DESKTOP/DOCUMENTS/DOWNLOAD
     granted, Environment returns the corresponding sandbox directory, so
     the original file can be handed to native Emacs and edits save back
     to the user directory.  Unknown URIs fall back to a cache copy.  */
  private resolveDropPath(uri: string): string {
    const prefix = 'file://docs/storage/Users/currentUser/';
    if (!uri.startsWith(prefix)) {
      return '';
    }
    let rel = uri.substring(prefix.length);
    try {
      rel = decodeURIComponent(rel);
    } catch (e) {
      hilog.warn(0x0000, 'arkui.gui', 'drop uri decode failed: %{public}s', uri);
    }
    const slash = rel.indexOf('/');
    if (slash <= 0) {
      return '';
    }
    const dir = rel.substring(0, slash);
    const rest = rel.substring(slash + 1);
    let root = '';
    try {
      if (dir === 'Desktop') {
        root = Environment.getUserDesktopDir();
      } else if (dir === 'Documents') {
        root = Environment.getUserDocumentDir();
      } else if (dir === 'Download' || dir === 'Downloads') {
        root = Environment.getUserDownloadDir();
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, 'arkui.gui',
        'drop dir lookup failed code=%{public}d message=%{public}s', err.code, err.message);
      return '';
    }
    return root.length > 0 ? `${root}/${rest}` : '';
  }

  /* Copy the dragged user file into the app cache through its URI.  The
     drag grants temporary read access to the URI; the native Emacs side
     cannot open user-file paths directly, but it can open the sandbox
     copy.  Edits therefore apply to the copy, not to the original.  */
  private stageDroppedFile(uri: string): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    let name = 'dropped';
    try {
      name = new fileUri.FileUri(uri).name;
    } catch (e) {
      hilog.warn(0x0000, 'arkui.gui', 'drop name failed: %{public}s', JSON.stringify(e));
    }
    const safe = name.replace(/[^A-Za-z0-9._-]/g, '_');
    const dest = `${ctx.cacheDir}/drop-${Date.now()}-${safe}`;
    const src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const dst = fileIo.openSync(dest,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.copyFileSync(src.fd, dst.fd);
      } finally {
        fileIo.closeSync(dst);
      }
    } finally {
      fileIo.closeSync(src);
    }
    return dest;
  }

  /* Wheel input must always enter Emacs through the native WHEEL_EVENT
     path.  Sending a terminal page-key sequence such as "\x1b[6~" through
     guiWriteInput is wrong in a native GUI frame: WriteInput forwards it
     as text (ohos_input_text), so Emacs sees ESC, `[', `6' and `~' as
     four character events and inserts the literal `6~'/`5~' into the
     buffer.  Both the real wheel callback and the touch-drag scroll path
     below funnel through here.  */
  private sendNativeWheel(delta: number, x: number, y: number,
    mods: number): void {
    if (this.areaW <= 1 || this.areaH <= 1) {
      return;
    }
    let cols = 80;
    let rows = 24;
    try {
      const st = JSON.parse(entry.guiState()) as GuiStatusJson;
      const stateCols = st.cols ?? st.textCols;
      const stateRows = st.rows ?? st.textRows;
      if (stateCols !== undefined && stateCols > 0) {
        cols = stateCols;
      }
      if (stateRows !== undefined && stateRows > 0) {
        rows = stateRows;
      }
    } catch (e) {
      hilog.warn(0x0000, 'arkui.gui', 'guiState parse failed');
    }
    /* AxisEvent window coordinates and areaW/areaH are both in vp.
       AxisEvent.x/y is component-local and can be scaled differently;
       use windowX/windowY for the split-window target.  */
    const col = Math.floor(x / this.areaW * cols);
    const row = Math.floor(y / this.areaH * rows);
    hilog.info(0x0000, 'arkui.gui', 'wheel map %{public}s',
      'x=' + x.toString() + ' y=' + y.toString()
      + ' area=' + this.areaW.toString() + 'x' + this.areaH.toString()
      + ' grid=' + cols.toString() + 'x' + rows.toString()
      + ' -> ' + col.toString() + ',' + row.toString());
    entry.guiWheel(delta, col, row, mods);
  }

  private handleAxisEvent(event: AxisEvent): void {
    if (event.action !== AxisAction.UPDATE && event.action !== AxisAction.BEGIN) {
      return;
    }
    const delta = event.getVerticalAxisValue();
    if (delta === 0) {
      return;
    }
    let mods = 0;
    try {
      if (event.getModifierKeyState !== undefined
          && event.getModifierKeyState(['Ctrl'])) {
        mods |= 2;
      }
      if (event.getModifierKeyState !== undefined
          && event.getModifierKeyState(['Shift'])) {
        mods |= 1;
      }
      if (event.getModifierKeyState !== undefined
          && event.getModifierKeyState(['Alt'])) {
        mods |= 4;
      }
    } catch (e) {
      mods = 0;
    }
    const wx = event.windowX !== undefined ? event.windowX : event.x;
    const wy = event.windowY !== undefined ? event.windowY : event.y;
    this.sendNativeWheel(delta, wx, wy, mods);
  }

  /* ------------------------------------------------------------------ */
  /* Existing editing helpers.                                          */

  setClipboard(text: string): void {
    if (text.length === 0) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      hilog.info(0x0000, 'arkui.gui', 'clipboard set len=%{public}d', text.length);
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, 'arkui.gui', 'clipboard set failed: %{public}s', err.message);
    });
  }

  /* Give the window a real mouse pointer.

     ArkUI does not give a SURFACE XComponent a pointer of its own, and the
     page used to touch the pointer only when Emacs sent a cursor shape (or
     `cursor none', which hid the pointer for the whole window).  Prime it
     once the window exists, and re-assert it when the pointer enters the
     surface.  */
  private primePointer(): void {
    this.getMainWindow().then((win: window.Window | undefined) => {
      if (win === undefined) {
        return;
      }
      try {
        const id = win.getWindowProperties().id;
        this.pointerWindowId = id;
        pointer.setPointerVisibleSync(true);
        pointer.setPointerStyleSync(id, pointer.PointerStyle.DEFAULT);
        hilog.info(0x0000, 'arkui.gui', 'pointer primed window=%{public}d', id);
      } catch (e) {
        hilog.warn(0x0000, 'arkui.gui', 'pointer prime failed: %{public}s',
          JSON.stringify(e));
      }
    }).catch(() => {
    });
  }

  async toggleFullscreen(): Promise<void> {
    try {
      const win = AppStorage.get<window.Window>('mainWindow');
      if (win === undefined) {
        return;
      }
      this.fullscreen = !this.fullscreen;
      await win.setWindowLayoutFullScreen(this.fullscreen);
      win.setWindowDecorVisible(!this.fullscreen);
      hilog.info(0x0000, 'arkui.gui', 'fullscreen=%{public}d', this.fullscreen ? 1 : 0);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'arkui.gui', 'fullscreen failed: %{public}s', err.message);
    }
  }

  selectAll(): void {
    entry.guiWriteInput('\u0018h');
    setTimeout(() => {
      focusControl.requestFocus('emacs_gui');
    }, 100);
  }

  cutSelection(): void {
    // Copy first so the system clipboard is updated, then kill the region.
    entry.guiWriteInput('\u001bw');
    setTimeout(() => {
      entry.guiWriteInput('\u0017');
      setTimeout(() => {
        focusControl.requestFocus('emacs_gui');
      }, 100);
    }, 150);
  }

  copySelection(): void {
    entry.guiWriteInput('\u001bw');
    setTimeout(() => {
      focusControl.requestFocus('emacs_gui');
    }, 100);
  }

  copyLine(): void {
    entry.guiWriteInput('\u0003l');
    setTimeout(() => {
      focusControl.requestFocus('emacs_gui');
    }, 100);
  }

  undo(): void {
    entry.guiWriteInput('\u001f');
    setTimeout(() => {
      focusControl.requestFocus('emacs_gui');
    }, 100);
  }

  sendKeys(keys: string): void {
    entry.guiWriteInput(keys);
    setTimeout(() => {
      focusControl.requestFocus('emacs_gui');
    }, 100);
  }

  copyWholeBuffer(): void {
    entry.guiWriteInput('\u0018h');
    setTimeout(() => {
      entry.guiWriteInput('\u001bw');
      setTimeout(() => {
        focusControl.requestFocus('emacs_gui');
      }, 100);
    }, 120);
  }

  pasteToEmacs(): void {
    pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
      let text = data.getPrimaryText();
      if (text === undefined) {
        text = '';
      }
      if (text.length > 0) {
        entry.guiWriteInput(text);
      }
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, 'arkui.gui',
        'paste failed code=%{public}d message=%{public}s', err.code, err.message);
    });
  }

  @Builder
  ContextMenuBuilder() {
    Column({ space: 6 }) {
      Button('复制').width('100%').backgroundColor('#3a3a3a')
        .onClick(() => this.copySelection())
      Button('剪切').width('100%').backgroundColor('#3a3a3a')
        .onClick(() => this.cutSelection())
      Button('粘贴').width('100%').backgroundColor('#3a3a3a')
        .onClick(() => this.pasteToEmacs())
      Button('撤销').width('100%').backgroundColor('#3a3a3a')
        .onClick(() => this.undo())
      Button('全选').width('100%').backgroundColor('#3a3a3a')
        .onClick(() => this.selectAll())
      Button('搜索').width('100%').backgroundColor('#3a3a3a')
        .onClick(() => this.sendKeys('\u0013'))
    }
    .width(150)
    .padding(8)
    .backgroundColor('#e8e8e8')
    .borderRadius(12)
  }

  /* ArkUI Menu built from the same model as the panel.  Submenus are not
     expanded here yet: an item that has one opens the next level by
     replacing menuItems and reopening.  */
  @Builder
  SysMenuBuilder() {
    Menu() {
      ForEach(this.menuItems, (item: HostMenuItem, position: number) => {
        if (item.kind === 'separator') {
          MenuItem({ content: '────────' }).enabled(false)
        } else if (item.kind === 'pane') {
          MenuItem({ content: item.label }).enabled(false)
        } else {
          MenuItem({ content: item.label, labelInfo: item.keys })
            .enabled(item.enabled)
            .onClick(() => this.pickMenuItem(position))
        }
      }, (item: HostMenuItem, position: number) => 'sys:' + position.toString() + ':' + item.label)
    }
    .onDisAppear(() => {
      this.sysMenuShow = false
      if (this.menuVisible) {
        this.dismissMenu()
      }
    })
  }

  @Builder
  MenuPanel() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        if (this.menuDepth > 1 && !this.menuDialog) {
          Button('←')
            .width(36)
            .height(32)
            .fontSize(16)
            .backgroundColor('#3a3a3a')
            .onClick(() => this.menuBack())
        }
        Text(this.menuTitle.length > 0 ? this.menuTitle : 'Menu')
          .fontSize(16)
          .fontColor('#f0f0f0')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Scroll() {
        Column({ space: 2 }) {
          ForEach(this.menuItems, (item: HostMenuItem, position: number) => {
            if (item.kind === 'separator') {
              Divider().color('#4a4a4a').margin({ top: 2, bottom: 2 })
            } else if (item.kind === 'pane') {
              Text(item.label)
                .width('100%')
                .fontSize(12)
                .fontColor('#9a9a9a')
                .padding({ left: 6, top: 2, bottom: 2 })
            } else {
              Column({ space: 2 }) {
                Row({ space: 8 }) {
                  Text(this.menuMark(item) + item.label)
                    .fontSize(14)
                    .fontColor(item.enabled ? '#f0f0f0' : '#7a7a7a')
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.keys)
                    .fontSize(12)
                    .fontColor('#9a9a9a')
                    .maxLines(1)
                }
                .width('100%')
                if (item.help.length > 0) {
                  Text(item.help)
                    .width('100%')
                    .fontSize(11)
                    .fontColor('#8a8a8a')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .width('100%')
              .height(item.help.length > 0 ? 48 : 36)
              .justifyContent(FlexAlign.Center)
              .padding({ left: 8, right: 8 })
              .backgroundColor(item.enabled ? '#333333' : '#242424')
              .borderRadius(6)
              .enabled(item.enabled)
              .onClick(() => this.pickMenuItem(position))
            }
          }, (item: HostMenuItem, position: number) => position.toString() + ':' + item.label)
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: '60%' })
      .scrollBar(BarState.Auto)

      Row({ space: 8 }) {
        Button('取消')
          .layoutWeight(1)
          .height(34)
          .fontSize(14)
          .backgroundColor('#3a3a3a')
          .onClick(() => this.dismissMenu())
      }
      .width('100%')
    }
    .width('58%')
    .padding(12)
    .backgroundColor('#ee1b1b1b')
    .borderRadius(12)
    .position({ x: '21%', y: '6%' })
  }

  @Builder
  MenuBar() {
    Row({ space: 2 }) {
      /* The key includes the label: Emacs republishes the bar with a
         different item count (Lisp-Interaction appears and disappears
         with the buffer), and a key that only used the index made ArkUI
         reuse a child for a different item, which is what displayed
         "Help" twice.  */
      ForEach(this.menubar, (item: HostMenuBarItem) => {
        Text(item.label)
          .fontSize(14)
          .fontColor('#e6e6e6')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          /* The menu bar is driven by the mouse only.  While a plain Text
             could still become the focus target (or the Tab traversal
             stop), every key - Tab above all - went to ArkUI instead of
             the XComponent, so the echo area/minibuffer never saw it.  */
          .focusable(false)
          .focusOnTouch(false)
          .onClick(() => {
            /* Keep the keyboard on the frame: the menu is a mouse popup.  */
            this.onMenuBarClick(item.index);
          })
      }, (item: HostMenuBarItem) => 'mb:' + item.index.toString() + ':' + item.label)
      Blank()
      OpenSourceButton({ onOpen: () => { this.showLicenses = true; } })
    }
    .width('100%')
    .height(32)
    .backgroundColor('#2a2a2a')
    .alignItems(VerticalAlign.Center)
    .onHover((isHover: boolean) => {
      this.hoverMenuBar(isHover);
    })
  }

  build() {
    Column() {
      if (this.menubar.length > 0) {
        this.MenuBar()
      }
      Stack({ alignContent: Alignment.Center }) {
      XComponent({
        id: 'emacs_gui',
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .id('emacs_gui')
        .width('100%')
        .height('100%')
        .onFocus(() => {
          this.focusState = true;
          if (this.focusPeerReady) {
            entry.guiFocus(true);
          }
        })
        .onBlur(() => {
          /* A component blur is not a window blur: the IME text field or
             the menu panel taking focus inside this window must not be
             reported as the window losing focus, or Emacs stops the
             blink timer and draws the inactive cursor.  */
          hilog.info(0x0000, 'arkui.gui', 'component blur ignored (window keeps focus)');
        })
        .focusable(true)
        .defaultFocus(true)
        .onLoad(() => {
          this.surfaceReady = true;
          hilog.info(0x0000, 'arkui.gui', 'surface onLoad');
          this.primePointer();
        })
        .onMouse((event: MouseEvent) => {
          this.trackSurfaceMouse(event);
        })
        .onHover((isHover: boolean) => {
          hilog.info(0x0000, 'arkui.gui', 'hover=%{public}d', isHover ? 1 : 0);
          this.hoverPointer(isHover);
        })
        .onDestroy(() => {
          this.surfaceReady = false;
        })
        .onAxisEvent((event: AxisEvent) => {
          this.handleAxisEvent(event);
        })
        .onDragEnter((event: DragEvent) => {
          hilog.info(0x0000, 'arkui.gui', 'drag enter');
        })
        .onDrop((event: DragEvent) => {
          this.handleDropEvent(event);
        })
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 1 })
              .onAction((event: GestureEvent) => {
                hilog.info(0x0000, 'arkui.gui', 'surface tap source=%{public}d', event.source);
                this.onSurfaceTap(event.source === SourceType.TouchScreen);
              })
          )
        )
        /* Context menu disabled: x_popup_menu_1 crashes on the native
           OHOS terminal without a menu backend. */

      if (this.useSystemMenu) {
        Stack()
          .width(0)
          .height(0)
          .position({ x: 0, y: 0 })
          .bindMenu(this.sysMenuShow, this.SysMenuBuilder(), this.menuOptions())
      }
      if (this.menuVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#55000000')
          .onClick(() => this.dismissMenu())
        this.MenuPanel()
      }
      if (this.useSystemMenu) {
        /* Zero-size anchor that carries the ArkUI menu. */
        Stack()
          .width(0)
          .height(0)
          .position({ x: 0, y: 0 })
          .bindMenu(this.sysMenuShow, this.SysMenuBuilder(), this.menuOptions())
      }

      if (this.busy) {
        Column() {
          LoadingProgress()
            .width(26)
            .height(26)
            .color('#7fb3ff')
        }
        .padding(6)
        .backgroundColor('#99000000')
        .borderRadius(8)
        .position({ x: '93%', y: '93%' })
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.bellFlash) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#22ffffff')
          .hitTestBehavior(HitTestMode.None)
      }

      if (this.error.length > 0) {
        Column({ space: 12 }) {
          Text(this.error)
            .fontSize(16)
            .fontColor('#ffb4b4')
            .textAlign(TextAlign.Center)
            .padding(20)
          Row({ space: 12 }) {
            Button('重试')
              .onClick(() => this.retry())
          }
        }
        .padding(24)
        .backgroundColor('#cc101010')
        .borderRadius(12)
      } else if (this.status.length > 0) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color('#7fb3ff')
          Text(this.status)
            .fontSize(14)
            .fontColor('#d0d0d0')
        }
        .padding(18)
        .backgroundColor('#bb101010')
        .borderRadius(10)
      }
      if (this.showLicenses) {
        OpenSourceDialog({ onClose: () => { this.showLicenses = false; } })
      }
    }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#121212')
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.areaW = Math.max(1, newValue.width as number);
        this.areaH = Math.max(1, newValue.height as number);
        hilog.info(0x0000, 'arkui.gui', 'area %{public}dx%{public}d',
          this.areaW, this.areaH);
      })
    }
    .width('100%')
    .height('100%')
  }
}

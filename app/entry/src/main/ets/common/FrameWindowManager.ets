import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import entry from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'arkui.gui';

export interface FrameWindowParams {
  frameId: number;
  width: number;
  height: number;
  x: number;
  y: number;
  title: string;
  parentFrameId: number;
  undecorated: boolean;
  dialog: boolean;
}

/* One UIAbility, one WindowStage, one native window per Emacs frame.
   The boot frame uses the main window (frame_id 1); every other frame
   gets a subwindow whose page creates XComponent emacs_frame_<id>. */
class FrameWindowManager {
  private stage: window.WindowStage | undefined = undefined;
  private mainWindow: window.Window | undefined = undefined;
  private windows: Map<number, window.Window> = new Map<number, window.Window>();

  init(stage: window.WindowStage, main: window.Window | undefined): void {
    this.stage = stage;
    this.mainWindow = main;
    if (main !== undefined) {
      this.windows.set(1, main);
    }
    hilog.info(DOMAIN, TAG, 'FrameWindowManager init');
  }

  private windowFor(frameId: number): window.Window | undefined {
    return this.windows.get(frameId);
  }

  async create(params: FrameWindowParams): Promise<void> {
    if (this.stage === undefined) {
      throw new Error('WindowStage is not initialized');
    }
    if (this.windows.has(params.frameId)) {
      return;
    }
    const options: window.SubWindowOptions = {
      title: params.title,
      decorEnabled: !params.undecorated,
      maximizeSupported: true,
      outlineEnabled: true
    };
    const parent = params.parentFrameId > 0
      ? this.windows.get(params.parentFrameId) : undefined;
    const name = 'emacs-frame-' + params.frameId;
    const win = parent !== undefined
      ? await parent.createSubWindowWithOptions(name, options)
      : await this.stage.createSubWindowWithOptions(name, options);
    this.windows.set(params.frameId, win);
    try {
      /* Emacs frames often report 0,0; stagger new windows so they do
         not hide each other completely during multi-frame testing. */
      const slot = params.frameId % 8;
      let x = params.x > 0 ? params.x : 40 + slot * 48;
      let y = params.y > 0 ? params.y : 40 + slot * 48;
      if (parent !== undefined) {
        try {
          const rect = parent.getWindowProperties().windowRect;
          x = rect.left + 24 + slot * 24;
          y = rect.top + 48 + slot * 24;
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'parent rect unavailable');
        }
      }
      await win.resize(params.width, params.height);
      await win.moveWindowTo(x, y);
      await win.setWindowLimits({ minWidth: 360, minHeight: 240 });
      win.on('subWindowClose', (): boolean => {
        hilog.info(DOMAIN, TAG, 'subWindowClose frame=%{public}d', params.frameId);
        entry.guiCloseRequest(params.frameId);
        return true;
      });
      win.on('windowEvent', (event: window.WindowEventType) => {
        const focused = event === window.WindowEventType.WINDOW_ACTIVE;
        entry.guiFocusForFrame(params.frameId, focused);
      });
      const storage = new LocalStorage();
      storage.setOrCreate('frameId', params.frameId);
      storage.setOrCreate('title', params.title);
      await win.loadContent('pages/Frame', storage);
      await win.showWindow();
      hilog.info(DOMAIN, TAG,
        'subwindow created frame=%{public}d parent=%{public}d',
        params.frameId, params.parentFrameId);
    } catch (e) {
      this.windows.delete(params.frameId);
      try {
        await win.destroyWindow();
      } catch (destroyError) {
        hilog.warn(DOMAIN, TAG, 'cleanup destroyed subwindow failed');
      }
      throw e as Error;
    }
  }

  async destroy(frameId: number): Promise<void> {
    if (frameId === 1) {
      /* The main window is owned by EntryAbility; deleting the boot frame
         ends the Emacs process rather than destroying this window here. */
      hilog.info(DOMAIN, TAG, 'boot window close handled by Emacs');
      return;
    }
    const win = this.windows.get(frameId);
    if (win === undefined) {
      return;
    }
    this.windows.delete(frameId);
    try {
      win.off('subWindowClose');
      win.off('windowEvent');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'off window events failed');
    }
    await win.destroyWindow();
    hilog.info(DOMAIN, TAG, 'subwindow destroyed frame=%{public}d', frameId);
  }

  async setTitle(frameId: number, title: string): Promise<void> {
    const win = this.windowFor(frameId);
    if (win !== undefined) {
      await win.setWindowTitle(title);
    }
  }

  async resize(frameId: number, width: number, height: number): Promise<void> {
    if (width <= 0 || height <= 0) {
      return;
    }
    const win = this.windowFor(frameId);
    if (win !== undefined) {
      await win.resize(width, height);
    }
  }

  async move(frameId: number, x: number, y: number): Promise<void> {
    const win = this.windowFor(frameId);
    if (win !== undefined) {
      await win.moveWindowTo(x, y);
    }
  }

  async raise(frameId: number): Promise<void> {
    const win = this.windowFor(frameId);
    if (win !== undefined) {
      await win.showWindow();
    }
  }

  async lower(frameId: number): Promise<void> {
    /* Child windows cannot be lowered below their parent on API 24. */
    hilog.info(DOMAIN, TAG, 'lower frame=%{public}d ignored', frameId);
  }

  async setAlpha(frameId: number, percent: number): Promise<void> {
    hilog.info(DOMAIN, TAG, 'alpha frame=%{public}d value=%{public}d ignored',
      frameId, percent);
  }

  async setNoFocusOnMap(frameId: number, noFocus: boolean): Promise<void> {
    hilog.info(DOMAIN, TAG, 'no-focus-on-map frame=%{public}d value=%{public}s',
      frameId, String(noFocus));
  }

  async setNoAcceptFocus(frameId: number, noAccept: boolean): Promise<void> {
    hilog.info(DOMAIN, TAG, 'no-accept-focus frame=%{public}d value=%{public}s',
      frameId, String(noAccept));
  }

  async setFullscreen(frameId: number, on: boolean): Promise<void> {
    const win = this.windowFor(frameId);
    if (win !== undefined) {
      await win.setWindowLayoutFullScreen(on);
      await win.setWindowDecorVisible(!on);
    }
  }

  async setVisible(frameId: number, visible: boolean): Promise<void> {
    const win = this.windowFor(frameId);
    if (win !== undefined) {
      if (visible) {
        await win.showWindow();
      } else {
        await win.minimize();
      }
    }
  }

  async minimize(frameId: number): Promise<void> {
    const win = this.windowFor(frameId);
    if (win !== undefined) {
      await win.minimize();
    }
  }
}

export const frameWindows = new FrameWindowManager();

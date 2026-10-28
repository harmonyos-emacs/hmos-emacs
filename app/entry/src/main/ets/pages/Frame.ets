import entry from 'libentry.so';
import { frameWindows } from '../common/FrameWindowManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { KeyCode, pointer } from '@kit.InputKit';

const DOMAIN = 0x0000;
const TAG = 'arkui.frame';

interface FrameMenuBarItem {
  index: number;
  label: string;
}

interface RawFrameMenuBar {
  bar?: FrameMenuBarItem[];
}

interface RawFrameMenuItem {
  kind?: string;
  label?: string;
  enabled?: boolean;
  id?: number;
  items?: RawFrameMenuItem[];
}

interface RawFrameMenuLevel {
  title?: string;
  items?: RawFrameMenuItem[];
}

interface FrameMenuItem {
  kind: string;
  label: string;
  enabled: boolean;
  id: number;
  submenu: boolean;
  children: FrameMenuItem[];
}

interface FrameMenuState {
  id: number;
  dialog: boolean;
  json: string;
  seq: number;
}

/* A subwindow owns exactly one XComponent and therefore exactly one Emacs
   frame.  The manager passes frameId/title through LocalStorage. */
@Entry({ useSharedStorage: true })
@Component
struct Frame {
  @LocalStorageProp('frameId') frameId: number = 0;
  @LocalStorageProp('title') title: string = 'Emacs';

  @State menubar: FrameMenuBarItem[] = [];
  @State menuVisible: boolean = false;
  @State menuItems: FrameMenuItem[] = [];
  @State menuId: number = -1;
  @State menuTitle: string = '';
  @State menuIndex: number = -1;
  private menuStack: FrameMenuItem[][] = [];
  private menuTitles: string[] = [];
  @State busy: boolean = false;
  @State bellFlash: boolean = false;
  private timer: number = -1;
  private bellTimer: number = -1;
  private lastMenubar: string = '';
  private lastMenu: string = '';
  private lastBell: number = 0;
  private lastCursor: string = '';
  private pointerWindowId: number = -1;

  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'Frame page appear frame=%{public}d', this.frameId);
    this.timer = setInterval(() => this.pollChrome(), 100);
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      this.pointerWindowId = win.getWindowProperties().id;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'frame pointer window failed: %{public}s',
        e.message);
    });
    setTimeout(() => {
      focusControl.requestFocus('emacs_frame_' + this.frameId);
    }, 0);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.bellTimer >= 0) {
      clearTimeout(this.bellTimer);
      this.bellTimer = -1;
    }
  }

  private pollChrome(): void {
    const busy = AppStorage.get<boolean>('hourglass_' + this.frameId);
    if (busy !== undefined) {
      this.busy = busy;
    }
    const bell = AppStorage.get<number>('bell_' + this.frameId);
    if (bell !== undefined && bell !== this.lastBell) {
      this.lastBell = bell;
      this.bellFlash = true;
      if (this.bellTimer >= 0) {
        clearTimeout(this.bellTimer);
      }
      this.bellTimer = setTimeout(() => {
        this.bellFlash = false;
        this.bellTimer = -1;
      }, 180);
    }

    const cursor = AppStorage.get<string>('cursor_' + this.frameId);
    if (cursor !== undefined && cursor !== this.lastCursor) {
      this.lastCursor = cursor;
      this.applyPointer(cursor);
    }

    const menubar = AppStorage.get<string>('menubar_' + this.frameId);
    if (menubar !== undefined && menubar !== this.lastMenubar) {
      this.lastMenubar = menubar;
      try {
        const parsed = JSON.parse(menubar) as RawFrameMenuBar;
        this.menubar = parsed.bar === undefined || parsed.bar === null
          ? [] : parsed.bar;
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'frame menubar parse failed');
      }
    }

    const raw = AppStorage.get<string>('menu_' + this.frameId);
    if (raw !== undefined && raw !== this.lastMenu) {
      this.lastMenu = raw;
      try {
        const state = JSON.parse(raw) as FrameMenuState;
        if (state.id < 0) {
          this.menuVisible = false;
          this.menuId = -1;
          this.menuItems = [];
          return;
        }
        this.menuId = state.id;
        this.menuStack = [];
        this.menuTitles = [];
        this.parseMenu(state.json);
        this.menuVisible = true;
        this.menuIndex = this.firstSelectable();
        setTimeout(() => {
          const ok = focusControl.requestFocus('frame_menu_' + this.frameId);
          hilog.info(DOMAIN, TAG, 'frame menu focus=%{public}s',
            String(ok));
        }, 60);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'frame menu parse failed');
      }
    }
  }

  private selectable(item: FrameMenuItem): boolean {
    return item.kind !== 'separator' && item.kind !== 'pane' && item.enabled;
  }

  private firstSelectable(): number {
    for (let i = 0; i < this.menuItems.length; i++) {
      if (this.selectable(this.menuItems[i])) {
        return i;
      }
    }
    return -1;
  }

  private moveSelection(delta: number): void {
    if (this.menuIndex < 0 || this.menuItems.length === 0) {
      this.menuIndex = this.firstSelectable();
      return;
    }
    let index = this.menuIndex;
    for (let step = 0; step < this.menuItems.length; step++) {
      index = (index + delta + this.menuItems.length) % this.menuItems.length;
      if (this.selectable(this.menuItems[index])) {
        this.menuIndex = index;
        return;
      }
    }
  }

  private handleMenuKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down) {
      return;
    }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.cancelMenu();
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
      this.moveSelection(-1);
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
      this.moveSelection(1);
    } else if (event.keyCode === KeyCode.KEYCODE_ENTER
      || event.keyCode === KeyCode.KEYCODE_NUMPAD_ENTER) {
      if (this.menuIndex >= 0 && this.menuIndex < this.menuItems.length) {
        this.pick(this.menuItems[this.menuIndex]);
      }
    }
  }

  private hoverPointer(isHover: boolean): void {
    if (this.pointerWindowId < 0) {
      return;
    }
    const name = isHover ? this.lastCursor : 'default';
    setTimeout(() => {
      this.applyPointer(name);
    }, 0);
  }

  private hoverMenuBar(isHover: boolean): void {
    if (this.pointerWindowId < 0) {
      return;
    }
    const name = isHover ? 'default' : this.lastCursor;
    setTimeout(() => {
      this.applyPointer(name);
    }, 0);
  }

  private applyPointer(name: string): void {
    if (this.pointerWindowId < 0 || name === 'none') {
      return;
    }
    let style: pointer.PointerStyle = pointer.PointerStyle.DEFAULT;
    if (name === 'text') {
      style = pointer.PointerStyle.TEXT_CURSOR;
    } else if (name === 'hand') {
      style = pointer.PointerStyle.HAND_POINTING;
    } else if (name === 'hourglass') {
      style = pointer.PointerStyle.LOADING;
    } else if (name === 'vdrag' || name === 'updown') {
      style = pointer.PointerStyle.RESIZE_UP_DOWN;
    } else if (name === 'hdrag' || name === 'leftright') {
      style = pointer.PointerStyle.RESIZE_LEFT_RIGHT;
    }
    try {
      pointer.setPointerStyleSync(this.pointerWindowId, style);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'frame cursor %{public}s failed', name);
    }
  }

  private parseItems(src: RawFrameMenuItem[] | undefined): FrameMenuItem[] {
    const items: FrameMenuItem[] = [];
    if (src === undefined || src === null) {
      return items;
    }
    for (let i = 0; i < src.length; i++) {
      const r = src[i];
      const kind = r.kind === undefined || r.kind === null ? 'item' : r.kind;
      const label = r.label === undefined || r.label === null ? '' : r.label;
      const enabled = r.enabled === undefined || r.enabled === null
        ? true : r.enabled;
      const id = r.id === undefined || r.id === null ? -1 : r.id;
      const children = this.parseItems(r.items);
      items.push({ kind: kind, label: label, enabled: enabled, id: id,
        submenu: children.length > 0, children: children });
    }
    return items;
  }

  private parseMenu(json: string): void {
    const root = JSON.parse(json) as RawFrameMenuLevel;
    this.menuTitle = root.title === undefined || root.title === null
      ? '' : root.title;
    this.menuItems = this.parseItems(root.items);
  }

  private openMenu(index: number): void {
    hilog.info(DOMAIN, 'arkui.menu',
      'menu request source=bar frame=%{public}d index=%{public}d',
      this.frameId, index);
    entry.guiMenuBarClick(index, this.frameId);
    focusControl.requestFocus('emacs_frame_' + this.frameId);
  }

  private pick(item: FrameMenuItem): void {
    if (!item.enabled) {
      return;
    }
    if (item.children.length > 0) {
      hilog.info(DOMAIN, 'arkui.menu',
        'menu submenu frame=%{public}d menu=%{public}d item=%{public}d',
        this.frameId, this.menuId, item.id);
      this.menuStack.push(this.menuItems);
      this.menuTitles.push(this.menuTitle);
      this.menuItems = item.children;
      this.menuTitle = item.label;
      this.menuIndex = this.firstSelectable();
      return;
    }
    if (item.id < 0) {
      return;
    }
    hilog.info(DOMAIN, 'arkui.menu',
      'menu pick frame=%{public}d menu=%{public}d item=%{public}d',
      this.frameId, this.menuId, item.id);
    entry.guiMenuResult(this.menuId, item.id);
    this.closeMenu();
  }

  private menuBack(): void {
    if (this.menuStack.length === 0) {
      return;
    }
    this.menuItems = this.menuStack.pop() ?? [];
    this.menuTitle = this.menuTitles.pop() ?? '';
    this.menuIndex = this.firstSelectable();
  }

  private cancelMenu(): void {
    if (this.menuStack.length > 0) {
      this.menuBack();
      return;
    }
    if (this.menuId >= 0) {
      hilog.info(DOMAIN, 'arkui.menu',
        'menu cancel frame=%{public}d menu=%{public}d', this.frameId,
        this.menuId);
      entry.guiMenuResult(this.menuId, -1);
    }
    this.closeMenu();
  }

  private closeMenu(): void {
    if (this.menuId >= 0) {
      hilog.info(DOMAIN, 'arkui.menu',
        'menu close frame=%{public}d menu=%{public}d', this.frameId,
        this.menuId);
    }
    this.menuVisible = false;
    this.menuId = -1;
    this.menuItems = [];
    this.menuIndex = -1;
    entry.guiMenuOpen(0);
    focusControl.requestFocus('emacs_frame_' + this.frameId);
  }

  @Builder
  FrameMenuBar() {
    Row() {
      ForEach(this.menubar, (item: FrameMenuBarItem) => {
        Text(item.label)
          .fontSize(14)
          .fontColor('#e6e6e6')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .focusable(false)
          .focusOnTouch(false)
          .onClick(() => this.openMenu(item.index))
      }, (item: FrameMenuBarItem) => 'fmb:' + item.index.toString() + ':' + item.label)
      Blank()
      Text('—')
        .fontSize(18)
        .fontColor('#e6e6e6')
        .padding({ left: 10, right: 12, top: 2, bottom: 4 })
        .focusable(false)
        .focusOnTouch(false)
        .onClick(() => {
          frameWindows.minimize(this.frameId).catch((e: Error) => {
            hilog.warn(DOMAIN, TAG, 'frame minimize failed: %{public}s',
              e.message);
          });
        })
    }
    .width('100%')
    .height(32)
    .backgroundColor('#2a2a2a')
    .alignItems(VerticalAlign.Center)
    .onHover((isHover: boolean) => {
      this.hoverMenuBar(isHover);
    })
  }

  @Builder
  FrameMenuPanel() {
    Scroll() {
      Column() {
      if (this.menuStack.length > 0) {
        Row() {
          Text('‹ ' + this.menuTitle)
            .fontSize(14)
            .fontColor('#9fc6ff')
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .onClick(() => this.menuBack())
      } else if (this.menuTitle.length > 0) {
        Text(this.menuTitle)
          .fontSize(14)
          .fontColor('#f0f0f0')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }
      ForEach(this.menuItems, (item: FrameMenuItem) => {
        if (item.kind === 'separator') {
          Divider()
            .color('#555555')
            .margin({ top: 3, bottom: 3 })
        } else if (item.kind === 'pane') {
          Text(item.label)
            .fontSize(12)
            .fontColor('#aaaaaa')
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        } else {
          Row() {
            Text(item.label)
              .fontSize(14)
              .fontColor(item.enabled ? '#e6e6e6' : '#777777')
              .layoutWeight(1)
            if (item.submenu) {
              Text('▸')
                .fontSize(14)
                .fontColor('#e6e6e6')
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(this.menuItems.indexOf(item) === this.menuIndex
            ? '#444444' : Color.Transparent)
          .onClick(() => this.pick(item))
        }
      }, (item: FrameMenuItem) => 'fmi:' + item.id.toString() + ':' + item.label)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .alignItems(HorizontalAlign.Start)
    }
    .width(360)
    .constraintSize({ maxHeight: '70%' })
    .scrollBar(BarState.Auto)
    .backgroundColor('#2a2a2a')
    .borderRadius(6)
    .position({ x: 8, y: 36 })
  }

  build() {
    Column() {
      if (this.menubar.length > 0) {
        this.FrameMenuBar()
      }
      Stack({ alignContent: Alignment.TopStart }) {
        XComponent({
          id: 'emacs_frame_' + this.frameId,
          type: XComponentType.SURFACE,
          libraryname: 'entry'
        })
          .id('emacs_frame_' + this.frameId)
          .width('100%')
          .height('100%')
          .focusable(true)
          .defaultFocus(true)
          .onFocus(() => {
            entry.guiFocusForFrame(this.frameId, true);
          })
          .onHover((isHover: boolean) => {
            this.hoverPointer(isHover);
          })
          .gesture(
            TapGesture({ count: 1 })
              .onAction((event: GestureEvent) => {
                focusControl.requestFocus('emacs_frame_' + this.frameId);
                /* Seamless IME: touch and mouse click use the same path. */
                hilog.info(DOMAIN, TAG,
                  'frame surface tap ime frame=%{public}d', this.frameId);
                entry.guiShowIme(this.frameId);
              })
          )
          .onBlur(() => {
            entry.guiFocusForFrame(this.frameId, false);
          })
          .onLoad(() => {
            hilog.info(DOMAIN, TAG, 'frame surface onLoad frame=%{public}d',
              this.frameId);
            entry.guiFocusForFrame(this.frameId, true);
          })

        if (this.menuVisible) {
          Button()
            .width('100%')
            .height('100%')
            .backgroundColor('#33000000')
            .borderRadius(0)
            .stateEffect(false)
            .id('frame_menu_' + this.frameId)
            .focusable(true)
            .onKeyEvent((event: KeyEvent) => this.handleMenuKey(event))
            .onClick(() => this.cancelMenu())
          this.FrameMenuPanel()
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
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}

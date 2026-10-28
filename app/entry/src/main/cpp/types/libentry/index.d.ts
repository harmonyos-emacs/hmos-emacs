/* ArkTS surface of libentry.so.  Keep this list in sync with the NAPI
   export table in host/napi_module.cpp.  */
export const startInProcess: (args: string, env: string, cwd: string) => number;
export const startDumpInProcess: (env: string, cwd: string) => number;

export const startInstallRuntime: (fd: number, offset: number, length: number, tar: string, dir: string) => number;
export const installState: () => string;
export const runtimeReady: (path: string) => number;
export const buildId: () => string;
export const libemacsVersion: () => string;
export const fileRead: (path: string) => string;
export const fileWrite: (path: string, text: string) => number;
export const fileRemove: (path: string) => number;

export const guiDetach: () => number;
export const guiState: () => string;
export const guiWriteInput: (text: string, frameId?: number) => number;
export const guiFocus: (focused: boolean, frameId?: number) => number;
export const guiSetDisplayMetrics: (densityDpi: number, densityPixels: number,
  scaledDensity: number, xdpi: number, ydpi: number) => number;
export const registerHostWake: (callback: () => void) => number;
export const guiShowIme: (frameId?: number) => number;
export const guiTitle: () => string;
export const guiClipboard: () => string;
export const inputActivity: () => number;

/* Typed host event mailbox: the ArkUI page drains one event per tick and
   answers interactive requests with the gui*Result calls.  */
export interface HostEvent {
  op: number;
  frameId: number;
  a: number;
  b: number;
  c: number;
  d: number;
  e: number;
  f: number;
  g: number;
  text: string;
}
export const guiTakeHostEvent: () => HostEvent | null;
export const guiMenuResult: (id: number, index: number) => number;
export const guiClipboardResult: (id: number, text: string) => number;
export const guiWheel: (deltaY: number, col: number, row: number, mods: number, frameId?: number) => number;
/* Menu popup lifecycle: while a menu is open, Escape cancels the menu
   instead of reaching Emacs as a meta prefix. */
export const guiMenuOpen: (open: number) => number;
export const guiMenuBarClick: (index: number, frameId?: number) => number;
export const guiMouse: (x: number, y: number, frameId?: number) => number;
export const guiTakeMenuEsc: () => number;

/* Per-frame window lifecycle. */
export const guiCloseRequest: (frameId: number) => number;
export const guiWindowCreateFailed: (frameId: number, reason: string) => number;
export const guiFocusForFrame: (frameId: number, focused: boolean) => number;

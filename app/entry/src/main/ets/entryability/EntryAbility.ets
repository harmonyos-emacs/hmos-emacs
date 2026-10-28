import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import entry from 'libentry.so';
import { frameWindows } from '../common/FrameWindowManager';

const DOMAIN = 0x0000;
const TAG = 'arkui.ability';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate. ability=%{public}s reason=%{public}d',
      want.abilityName ?? '', launchParam.launchReason);
    const params = want.parameters as Record<string, Object> | undefined;
    const demo = params?.['demo'];
    if (typeof demo === 'string') {
      AppStorage.setOrCreate('guiDemo', demo);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageCreate.');
    const page = 'pages/Gui';
    windowStage.loadContent(page, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load %{public}s. code=%{public}d message=%{public}s',
          page, err.code, err.message);
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s loaded.', page);
    });

    // Allow the window to be resized by dragging its edges on PC, and set
    // sensible limits so the terminal always has room for a usable grid.
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      AppStorage.setOrCreate('mainWindow', mainWindow);
      frameWindows.init(windowStage, mainWindow);
      try {
        windowStage.on('windowStageClose', (): boolean => {
          entry.guiCloseRequest(1);
          return true;
        });
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'windowStageClose hook unavailable: %{public}s',
          JSON.stringify(e));
      }
      mainWindow.setResizeByDragEnabled(true).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'setResizeByDragEnabled failed: %{public}s', e.message);
      });
      mainWindow.setWindowLimits({
        minWidth: 360,
        minHeight: 240,
        maxWidth: 4096,
        maxHeight: 2560
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'setWindowLimits failed: %{public}s', e.message);
      });
    }).catch((e: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'getMainWindow failed: %{public}s', e.message);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy.');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onForeground.');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onBackground.');
  }
}

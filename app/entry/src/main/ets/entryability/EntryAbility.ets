import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;
const TAG = 'EmacsHmos';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate. ability=%{public}s reason=%{public}d',
      want.abilityName ?? '', launchParam.launchReason);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageCreate.');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load pages/Index. code=%{public}d message=%{public}s',
          err.code, err.message);
        return;
      }
      hilog.info(DOMAIN, TAG, 'pages/Index loaded.');
    });

    // Allow the window to be resized by dragging its edges on PC, and set
    // sensible limits so the terminal always has room for a usable grid.
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
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

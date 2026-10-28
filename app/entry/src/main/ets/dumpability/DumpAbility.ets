import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import entry from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'EmacsDump';

/*
 * Dedicated, UI-less ability.  It runs Emacs loadup in this ability's own
 * application process, using a pthread and dlopen.  It must not fork/pty.
 */
export default class DumpAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'DumpAbility onCreate');
    const params = want.parameters as Record<string, Object> | undefined;
    const runtime = params?.['runtime'];
    const env = params?.['env'];
    if (typeof runtime !== 'string' || typeof env !== 'string') {
      hilog.error(DOMAIN, TAG, 'missing runtime/env');
      this.context.terminateSelf();
      return;
    }
    const rc = entry.startDumpInProcess(env, runtime);
    hilog.info(DOMAIN, TAG, 'startDumpInProcess rc=%{public}d', rc);
    if (rc !== 0) {
      this.context.terminateSelf();
    }
  }

  onWindowStageCreate(): void {
    /* No UI: this ability exists only to generate the dump. */
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'DumpAbility onDestroy');
  }
}

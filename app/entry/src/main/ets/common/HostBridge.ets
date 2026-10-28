/*
 * ArkTS half of the native host chrome channel.
 *
 * Notification publishing is only reachable from ArkTS, so the native
 * export guiNotify() loads this module by name and calls the function
 * below.  The GUI page uses the same function for the "notify" host
 * command, which keeps both paths identical.
 */
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'arkui.gui';

/* Notifications with the same id replace each other; a small rolling id
   keeps consecutive Emacs messages visible.  */
let nextNotificationId: number = 1000;

/* Ask the user to enable notifications once.  Without this, publish()
   is accepted by the API but the notification is silently suppressed. */
export async function ensureNotificationEnabled(context: common.UIAbilityContext): Promise<boolean> {
  try {
    if (await notificationManager.isNotificationEnabled()) {
      return true;
    }
    await notificationManager.requestEnableNotification(context);
    return await notificationManager.isNotificationEnabled();
  } catch (err) {
    const e = err as BusinessError;
    hilog.error(DOMAIN, TAG, 'notification permission failed: %{public}d %{public}s',
      e.code, e.message ?? 'unknown');
    /* Once the user has denied the dialog, requestEnableNotification
       cannot show it again.  Open the notification settings page instead
       so the user can enable this app manually. */
    if (e.code === 1600004 || e.code === 1600013) {
      try {
        await notificationManager.openNotificationSettingsWithResult(context);
        return await notificationManager.isNotificationEnabled();
      } catch (settingsError) {
        const se = settingsError as BusinessError;
        hilog.error(DOMAIN, TAG, 'notification settings failed: %{public}d %{public}s',
          se.code, se.message ?? 'unknown');
      }
    }
    return false;
  }
}

/* Publish a basic text notification.  Returns 0 when the request was
   handed to the notification service, -1 when publishing failed. */
export function publishNotification(title: string, text: string): number {
  try {
    const safeTitle: string = title.length > 0 ? title : 'Emacs';
    const safeText: string = text.length > 0 ? text : safeTitle;
    const request: notificationManager.NotificationRequest = {
      id: nextNotificationId,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: safeTitle,
          text: safeText
        }
      }
    };
    nextNotificationId = nextNotificationId >= 65000 ? 1000 : nextNotificationId + 1;
    notificationManager.publish(request).then(() => {
      hilog.info(DOMAIN, TAG, 'notification published: %{public}s', safeTitle);
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'notification failed: %{public}d %{public}s',
        err.code, err.message);
    });
    return 0;
  } catch (err) {
    const e = err as BusinessError;
    hilog.error(DOMAIN, TAG, 'notification threw: %{public}s', e.message ?? 'unknown');
    return -1;
  }
}

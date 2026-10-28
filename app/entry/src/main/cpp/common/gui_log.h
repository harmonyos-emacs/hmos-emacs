/* Single logging entry point.  Modules that need a different hilog tag
   define OHOS_LOG_TAG before including this header.  */
#ifndef OHOS_GUI_LOG_H
#define OHOS_GUI_LOG_H

#include <hilog/log.h>

#ifndef OHOS_LOG_TAG
#define OHOS_LOG_TAG "native.gui"
#endif

#undef LOG_TAG
#define LOG_TAG OHOS_LOG_TAG
#define LOGI(...) OH_LOG_Print (LOG_APP, LOG_INFO, 0x0000, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print (LOG_APP, LOG_WARN, 0x0000, LOG_TAG, __VA_ARGS__)
#define LOGE(...)                                                              \
  OH_LOG_Print (LOG_APP, LOG_ERROR, 0x0000, LOG_TAG, __VA_ARGS__)

/* Category tags are the hilog control plane.  Use hilog -T / -L / -b;
   there is no separate level variable in the app.  */
#define OHOS_LOG_TAG_EMACS_LIFECYCLE "emacs.lifecycle"
#define OHOS_LOG_TAG_EMACS_RENDER "emacs.render"
#define OHOS_LOG_TAG_EMACS_INPUT "emacs.input"
#define OHOS_LOG_TAG_EMACS_MENU "emacs.menu"
#define OHOS_LOG_TAG_EMACS_CLIPBOARD "emacs.clipboard"
#define OHOS_LOG_TAG_NATIVE_SURFACE "native.surface"
#define OHOS_LOG_TAG_NATIVE_RENDER "native.render"
#define OHOS_LOG_TAG_NATIVE_INPUT "native.input"
#define OHOS_LOG_TAG_NATIVE_NAPI "native.napi"
#define OHOS_LOG_TAG_NATIVE_MENU "native.menu"
#define OHOS_LOG_TAG_ARKUI_GUI "arkui.gui"
#define OHOS_LOG_TAG_ARKUI_FRAME "arkui.frame"
#define OHOS_LOG_TAG_ARKUI_MENU "arkui.menu"

/* Debug logs are skipped before formatting when hilog has them disabled.  */
#define LOGD_TAG(tag, ...)                                                     \
  do                                                                           \
    {                                                                          \
      if (OH_LOG_IsLoggable (0x0000, tag, LOG_DEBUG))                          \
        OH_LOG_Print (LOG_APP, LOG_DEBUG, 0x0000, tag, __VA_ARGS__);           \
    }                                                                          \
  while (0)
#define LOGD(...) LOGD_TAG (LOG_TAG, __VA_ARGS__)
#define LOGI_TAG(tag, ...)                                                     \
  OH_LOG_Print (LOG_APP, LOG_INFO, 0x0000, tag, __VA_ARGS__)

/* Every exported NAPI callback starts with this.  Keep the signature out
   of the log: arguments can contain paths, text or clipboard contents.  */
#define OHOS_NAPI_ENTER()                                                      \
  LOGD_TAG (OHOS_LOG_TAG_NATIVE_NAPI, "NAPI %{public}s", __func__)

#endif

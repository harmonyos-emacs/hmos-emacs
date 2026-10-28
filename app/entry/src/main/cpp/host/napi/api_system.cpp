#include "host_api.h"

#include "gui_log.h"

#include "napi_util.h"
#include "system_bridge.h"

#include <string>

namespace ohosgui
{
napi_value
MenuOpen (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t on = 0;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &on);
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_MENU, "menu napi-open on=%{public}d",
            on != 0 ? 1 : 0);
  HostSystem ().SetMenuOpen (on != 0);
  return ReturnInt (env, 0);
}

napi_value
TakeMenuEscEvent (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  (void) info;
  return ReturnInt (env, HostSystem ().TakeMenuEsc ());
}

napi_value
MenuResult (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t id = -1, index = -1;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &id);
  if (argc > 1)
    napi_get_value_int32 (env, argv[1], &index);
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_MENU,
            "menu napi-result menu=%{public}d index=%{public}d", id, index);
  HostSystem ().ResolveMenu (id, index);
  return ReturnInt (env, 0);
}

napi_value
ClipboardResult (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t id = -1;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &id);
  std::string text;
  if (argc > 1)
    text = NapiString (env, argv[1]);
  HostSystem ().ResolveClipboard (id, text);
  return ReturnInt (env, 0);
}

} // namespace ohosgui

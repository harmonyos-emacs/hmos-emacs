#include "host_api.h"

#include "gui_log.h"

#include "napi_util.h"
#include "runtime_install.h"

#include <cstdint>
#include <string>

napi_value
StartInstallRuntime (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 5;
  napi_value argv[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);

  int32_t fd = -1;
  int64_t offset = 0, length = 0;
  std::string tar, dir;
  if (argc > 0)
    fd = NapiInt (env, argv[0], -1);
  if (argc > 1)
    offset = NapiInt64 (env, argv[1], 0);
  if (argc > 2)
    length = NapiInt64 (env, argv[2], 0);
  if (argc > 3)
    tar = NapiString (env, argv[3]);
  if (argc > 4)
    dir = NapiString (env, argv[4]);

  return ReturnInt (env, RuntimeBeginInstall (fd, offset, length, tar, dir));
}

napi_value
InstallState (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  (void) info;
  return ReturnString (env, RuntimeStateJson ());
}

napi_value
RuntimeReady (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  std::string path = argc > 0 ? NapiString (env, argv[0]) : std::string ();
  return ReturnInt (env, RuntimePathReady (path));
}

napi_value
BuildId (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  (void) info;
  return ReturnString (env, RuntimeBuildId ());
}

napi_value
FileRead (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  std::string path = argc > 0 ? NapiString (env, argv[0]) : std::string ();
  return ReturnString (env, RuntimeReadFile (path));
}

napi_value
FileWrite (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  std::string path = argc > 0 ? NapiString (env, argv[0]) : std::string ();
  std::string text = argc > 1 ? NapiString (env, argv[1]) : std::string ();
  return ReturnInt (env, RuntimeWriteFile (path, text));
}

napi_value
FileRemove (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  std::string path = argc > 0 ? NapiString (env, argv[0]) : std::string ();
  return ReturnInt (env, RuntimeRemoveFile (path));
}

napi_value
LibemacsVersion (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  (void) info;
  return ReturnString (env, RuntimeLibemacsVersion ());
}

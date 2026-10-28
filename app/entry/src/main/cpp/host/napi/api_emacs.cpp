#include "host_api.h"

#include "emacs_host.h"
#include "emacs_internal.h"
#include "gui_log.h"
#include "napi_util.h"
#include "ohos_host_abi.h"
#include "ohos_gui.h"
#include "text_lines.h"

#include <pthread.h>
#include <unistd.h>

#include <string>
#include <vector>

napi_value
GuiDetach (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  return ohosgui::Detach (env, info);
}

napi_value
RegisterHostWake (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  napi_valuetype type = napi_undefined;
  if (argc > 0)
    napi_typeof (env, argv[0], &type);
  if (type != napi_function)
    return ReturnInt (env, -1);
  CreateHostWakeup (env, argv[0]);
  return ReturnInt (env, 0);
}

napi_value
GuiSetDisplayMetrics (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 5;
  napi_value argv[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  EmacsHost &h = HostEmacs ();
  h.density_dpi = NapiDouble (env, argc > 0 ? argv[0] : nullptr, 96.0);
  h.density_pixels = NapiDouble (env, argc > 1 ? argv[1] : nullptr, 1.0);
  h.scaled_density = NapiDouble (env, argc > 2 ? argv[2] : nullptr, 1.0);
  h.xdpi = NapiDouble (env, argc > 3 ? argv[3] : nullptr, h.density_dpi);
  h.ydpi = NapiDouble (env, argc > 4 ? argv[4] : nullptr, h.density_dpi);
  h.have_display_metrics = true;
  if (h.api && h.api->set_display_metrics)
    h.api->set_display_metrics (h.density_dpi, h.density_pixels,
                                h.scaled_density, h.xdpi, h.ydpi);
  LOGI ("display metrics dpi=%{public}.1f density=%{public}.2f "
        "scaled=%{public}.2f "
        "xdpi=%{public}.1f ydpi=%{public}.1f",
        h.density_dpi, h.density_pixels, h.scaled_density, h.xdpi, h.ydpi);
  return ReturnInt (env, 0);
}

napi_value
StartDumpInProcess (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  std::string env_text = argc > 0 ? NapiString (env, argv[0]) : std::string ();
  std::string cwd = argc > 1 ? NapiString (env, argv[1]) : std::string ();
  std::vector<std::string> envs;
  SplitLines (env_text, envs);
  for (auto &kv : envs)
    {
      size_t eq = kv.find ('=');
      if (eq != std::string::npos)
        setenv (kv.substr (0, eq).c_str (), kv.substr (eq + 1).c_str (), 1);
    }
  if (!cwd.empty ())
    chdir (cwd.c_str ());
  HostEmacs ().api = EmacsLoadApi ("dump");
  if (!HostEmacs ().api)
    {
      napi_value r;
      napi_create_int32 (env, -2, &r);
      return r;
    }
  if (EmacsStartDumpThread () != 0)
    {
      napi_value r;
      napi_create_int32 (env, -3, &r);
      return r;
    }
  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}

napi_value
StartInProcess (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 3;
  napi_value argv[3] = { nullptr, nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  std::string args_text = argc > 0 ? NapiString (env, argv[0]) : std::string ();
  std::string env_text = argc > 1 ? NapiString (env, argv[1]) : std::string ();
  std::string cwd = argc > 2 ? NapiString (env, argv[2]) : std::string ();
  if (HostEmacs ().running)
    {
      napi_value r;
      napi_create_int32 (env, -2, &r);
      return r;
    }
  std::vector<std::string> envs;
  SplitLines (env_text, envs);
  for (auto &kv : envs)
    {
      size_t eq = kv.find ('=');
      if (eq != std::string::npos)
        setenv (kv.substr (0, eq).c_str (), kv.substr (eq + 1).c_str (), 1);
    }
  if (!cwd.empty ())
    chdir (cwd.c_str ());
  /* Capture Emacs' stderr next to the runtime so native startup errors
     and backtraces can be inspected from the host.  */
  if (!cwd.empty ())
    {
      std::string errpath = cwd + "/emacs-stderr.txt";
      /* Append rather than truncate: a failed Emacs run followed by a
         retry used to wipe the log of the first failure, which made
         startup crashes very hard to diagnose.  */
      if (freopen (errpath.c_str (), "a", stderr) == nullptr)
        LOGE ("cannot redirect stderr to %{public}s", errpath.c_str ());
      /* stderr to a file is block buffered; a startup failure that exits
         through appspawn loses the last buffer, which hid every fatal
         startup error.  Keep it unbuffered so the log always ends with
         the real message.  */
      setvbuf (stderr, nullptr, _IONBF, 0);
    }
  HostEmacs ().cwd = cwd;
  HostEmacs ().args.clear ();
  SplitLines (args_text, HostEmacs ().args);
  HostEmacs ().api = EmacsLoadApi ("gui");
  HostFlushPendingSurface ();
  if (!HostEmacs ().api)
    {
      napi_value r;
      napi_create_int32 (env, -4, &r);
      return r;
    }
  HostEmacs ().running = true;
  MaybeStartStackWatchdog (cwd.c_str ());
  if (EmacsStartGuiThread () != 0)
    {
      napi_value r;
      napi_create_int32 (env, -5, &r);
      return r;
    }
  LOGI ("in-process Emacs thread started");
  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}

napi_value
GuiFocus (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  bool focused = false;
  int32_t frame_id = (int32_t) ohosgui::kBootFrameId;
  if (argc > 0)
    napi_get_value_bool (env, argv[0], &focused);
  if (argc > 1)
    napi_get_value_int32 (env, argv[1], &frame_id);
  ohosgui_focus ((uint32_t) frame_id, focused ? 1 : 0);
  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}
napi_value
InputActivity (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  (void) info;
  napi_value r;
  napi_create_uint32 (
      env, HostEmacs ().activity.load (std::memory_order_relaxed), &r);
  return r;
}

napi_value
GuiShowIme (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t frame_id = (int32_t) ohosgui::kBootFrameId;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &frame_id);
  ohosgui_show_ime ((uint32_t) frame_id);
  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}

napi_value
GuiMenuBarClick (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t index = 0;
  int32_t frame_id = (int32_t) ohosgui::kBootFrameId;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &index);
  if (argc > 1)
    napi_get_value_int32 (env, argv[1], &frame_id);
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_MENU,
            "menu napi-bar frame=%{public}d index=%{public}d", frame_id, index);
  ohos_host_input_menubar ((uint32_t) frame_id, (int) index);
  return ReturnInt (env, 0);
}

napi_value
GuiMouse (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 3;
  napi_value argv[3] = { nullptr, nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t x = 0, y = 0;
  int32_t frame_id = (int32_t) ohosgui::kBootFrameId;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &x);
  if (argc > 1)
    napi_get_value_int32 (env, argv[1], &y);
  if (argc > 2)
    napi_get_value_int32 (env, argv[2], &frame_id);
  ohosgui_mouse ((uint32_t) frame_id, 0, (int) x, (int) y, 0, 1);
  ohosgui_mouse ((uint32_t) frame_id, 0, (int) x, (int) y, 0, 0);
  return ReturnInt (env, 0);
}

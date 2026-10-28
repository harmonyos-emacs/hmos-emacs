/* NAPI entry points implemented by the host modules.  The module table in
   napi_module.cpp is the only consumer; each implementation owns its own
   state.  */
#ifndef OHOS_HOST_API_H
#define OHOS_HOST_API_H

#include <napi/native_api.h>

/* Emacs process lifecycle and input (emacs_host.cpp).  */
napi_value StartInProcess (napi_env env, napi_callback_info info);
napi_value StartDumpInProcess (napi_env env, napi_callback_info info);
napi_value GuiDetach (napi_env env, napi_callback_info info);
napi_value GuiFocus (napi_env env, napi_callback_info info);
napi_value GuiSetDisplayMetrics (napi_env env, napi_callback_info info);
napi_value RegisterHostWake (napi_env env, napi_callback_info info);
napi_value InputActivity (napi_env env, napi_callback_info info);
napi_value GuiMenuBarClick (napi_env env, napi_callback_info info);
void ohos_host_input_menubar (uint32_t frame_id, int index);
napi_value GuiMouse (napi_env env, napi_callback_info info);
napi_value GuiTakeHostEvent (napi_env env, napi_callback_info info);
napi_value GuiCloseRequest (napi_env env, napi_callback_info info);
napi_value GuiWindowCreateFailed (napi_env env, napi_callback_info info);
napi_value GuiFocusForFrame (napi_env env, napi_callback_info info);

/* Runtime installation, file access and build metadata
   (runtime_install.cpp).  */
napi_value StartInstallRuntime (napi_env env, napi_callback_info info);
napi_value InstallState (napi_env env, napi_callback_info info);
napi_value RuntimeReady (napi_env env, napi_callback_info info);
napi_value BuildId (napi_env env, napi_callback_info info);
napi_value LibemacsVersion (napi_env env, napi_callback_info info);
napi_value FileRead (napi_env env, napi_callback_info info);
napi_value FileWrite (napi_env env, napi_callback_info info);
napi_value FileRemove (napi_env env, napi_callback_info info);

/* Input method proxy (ime.cpp).  */
napi_value GuiShowIme (napi_env env, napi_callback_info info);

#endif

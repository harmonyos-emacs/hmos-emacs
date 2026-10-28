#include "host_api.h"

#include "ohos_gui.h"
#define OHOS_LOG_TAG "native.napi"
#include "gui_log.h"

static napi_value
Init (napi_env env, napi_value exports)
{
  OHOS_NAPI_ENTER ();
  napi_property_descriptor desc[] = {
    { "startInProcess", nullptr, StartInProcess, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "startDumpInProcess", nullptr, StartDumpInProcess, nullptr, nullptr,
      nullptr, napi_default, nullptr },
    { "startInstallRuntime", nullptr, StartInstallRuntime, nullptr, nullptr,
      nullptr, napi_default, nullptr },
    { "installState", nullptr, InstallState, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "runtimeReady", nullptr, RuntimeReady, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "buildId", nullptr, BuildId, nullptr, nullptr, nullptr, napi_default,
      nullptr },
    { "libemacsVersion", nullptr, LibemacsVersion, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "fileRead", nullptr, FileRead, nullptr, nullptr, nullptr, napi_default,
      nullptr },
    { "fileWrite", nullptr, FileWrite, nullptr, nullptr, nullptr, napi_default,
      nullptr },
    { "fileRemove", nullptr, FileRemove, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiDetach", nullptr, GuiDetach, nullptr, nullptr, nullptr, napi_default,
      nullptr },
    { "guiState", nullptr, ohosgui::GetState, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiWriteInput", nullptr, ohosgui::WriteInput, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiFocus", nullptr, GuiFocus, nullptr, nullptr, nullptr, napi_default,
      nullptr },
    { "guiSetDisplayMetrics", nullptr, GuiSetDisplayMetrics, nullptr, nullptr,
      nullptr, napi_default, nullptr },
    { "registerHostWake", nullptr, RegisterHostWake, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiShowIme", nullptr, GuiShowIme, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiTitle", nullptr, ohosgui::GetTitle, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiClipboard", nullptr, ohosgui::TakeClipboard, nullptr, nullptr,
      nullptr, napi_default, nullptr },
    { "guiMenuResult", nullptr, ohosgui::MenuResult, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiClipboardResult", nullptr, ohosgui::ClipboardResult, nullptr, nullptr,
      nullptr, napi_default, nullptr },
    { "guiWheel", nullptr, ohosgui::Wheel, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiMenuOpen", nullptr, ohosgui::MenuOpen, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiMouse", nullptr, GuiMouse, nullptr, nullptr, nullptr, napi_default,
      nullptr },
    { "guiTakeHostEvent", nullptr, GuiTakeHostEvent, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiCloseRequest", nullptr, GuiCloseRequest, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiWindowCreateFailed", nullptr, GuiWindowCreateFailed, nullptr, nullptr,
      nullptr, napi_default, nullptr },
    { "guiFocusForFrame", nullptr, GuiFocusForFrame, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiMenuBarClick", nullptr, GuiMenuBarClick, nullptr, nullptr, nullptr,
      napi_default, nullptr },
    { "guiTakeMenuEsc", nullptr, ohosgui::TakeMenuEscEvent, nullptr, nullptr,
      nullptr, napi_default, nullptr },
    { "inputActivity", nullptr, InputActivity, nullptr, nullptr, nullptr,
      napi_default, nullptr },
  };
  ohosgui::RegisterXComponent (env, exports);
  napi_define_properties (env, exports, sizeof desc / sizeof desc[0], desc);
  return exports;
}

static napi_module emacsModule = {
  1, 0, nullptr, Init, "entry", nullptr,
};

extern "C" __attribute__ ((constructor)) void
RegisterEmacsModule (void)
{
  napi_module_register (&emacsModule);
}

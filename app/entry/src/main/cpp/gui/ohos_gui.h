/* HarmonyOS native GUI host: XComponent surface, draw sinks and input. */
#ifndef OHOS_GUI_H
#define OHOS_GUI_H

#include "ohos_host_abi.h"

#include <cstddef>
#include <cstdint>
#include <napi/native_api.h>

namespace ohosgui
{
/* Register the XComponent native object exported by libentry.so.  Safe to
   call from the regular NAPI Init as well: the property is absent there. */
void RegisterXComponent (napi_env env, napi_value exports);

/* Stop presenting: the surface is going away (page hide / detach).  */
void Stop (void);

/* Surface status queries used by the ArkTS page.  */
napi_value Status (napi_env env, napi_callback_info info);
napi_value Detach (napi_env env, napi_callback_info info);
napi_value GetState (napi_env env, napi_callback_info info);
napi_value GetTitle (napi_env env, napi_callback_info info);
napi_value TakeClipboard (napi_env env, napi_callback_info info);

/* Typed host event mailbox (Emacs -> ArkUI).  Emacs pushes typed records;
   the page drains them with guiTakeHostEvent and answers interactive
   requests with MenuResult/ClipboardResult. */
napi_value MenuResult (napi_env env, napi_callback_info info);
napi_value ClipboardResult (napi_env env, napi_callback_info info);
/* Menu popup state: while a menu is open Escape cancels the menu instead
   of reaching Emacs as a meta prefix.  The page reports the state and
   consumes guiTakeMenuEsc() on a host wake.  */
napi_value MenuOpen (napi_env env, napi_callback_info info);
napi_value TakeMenuEscEvent (napi_env env, napi_callback_info info);

napi_value Wheel (napi_env env, napi_callback_info info);
napi_value WriteInput (napi_env env, napi_callback_info info);

/* The single XComponent host creates exactly one frame context.  Its
   stable cross-thread key is 1; every input and surface callback names
   it explicitly so the renderer never depends on the selected frame.  */
constexpr uint32_t kBootFrameId = 1;

/* Exact Emacs frame geometry, published by the backend.  */
extern "C" void ohos_gui_set_frame_metrics (uint32_t frame_id, int width,
                                            int height, int cell_w, int cell_h,
                                            int ascent, int descent);

/* Emacs -> host sinks installed by the in-process loader.  */
extern "C" void ohos_gui_set_title (uint32_t frame_id, const char *title);
extern "C" void ohos_gui_set_clipboard (const char *base64);
} // namespace ohosgui

/* Wake the ArkTS page because a typed host event or chrome update is ready.
   Implemented in host/emacs_host.cpp.  */
void RequestHostWake (void);

/* Hooks implemented in the host process, called from the GUI modules.  */
extern "C" void ohosgui_host_menu_result (int id, int index);
extern "C" void ohosgui_host_request_result (int id, int status,
                                             const char *text);
extern "C" int ohosgui_host_input_resize (uint32_t frame_id, int width,
                                          int height);
extern "C" void ohosgui_host_input_expose (uint32_t frame_id, int x, int y,
                                           int w, int h);

extern "C" void ohos_host_input_key (uint32_t frame_id, unsigned key,
                                     unsigned modifiers, int pressed);
extern "C" void ohos_host_input_text (uint32_t frame_id, const char *text);
extern "C" void ohos_host_input_motion (uint32_t frame_id, int x, int y,
                                        unsigned modifiers);

extern "C" int ohosgui_write_input (uint32_t frame_id, const char *data,
                                    size_t len);
extern "C" void ohosgui_mouse (uint32_t frame_id, int button, int x, int y,
                               unsigned modifiers, int press);
extern "C" void ohosgui_host_input_wheel (uint32_t frame_id, int delta, int col,
                                          int row, unsigned modifiers);
extern "C" void ohosgui_font_metrics (int ascent, int descent, int height,
                                      int space_width, int underline_position,
                                      int underline_thickness);

/* Focus notifications coming from the XComponent focus/blur callbacks. */
extern "C" void ohosgui_focus (uint32_t frame_id, int focused);
extern "C" void ohosgui_show_ime (uint32_t frame_id);

#endif

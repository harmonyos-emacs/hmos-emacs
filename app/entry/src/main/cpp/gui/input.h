#ifndef OHOS_GUI_INPUT_H
#define OHOS_GUI_INPUT_H

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <napi/native_api.h>

namespace ohosgui
{
void OnTouch (OH_NativeXComponent *component, void *window);
void OnMouse (OH_NativeXComponent *component, void *window);
void OnKeyCallback (OH_NativeXComponent *component, void *window);
void OnFocusCallback (OH_NativeXComponent *component, void *window);
void OnBlurCallback (OH_NativeXComponent *component, void *window);

napi_value WriteInput (napi_env env, napi_callback_info info);
napi_value Wheel (napi_env env, napi_callback_info info);

void SetMenuOpen (int on);
int TakeMenuEsc (void);
} // namespace ohosgui

#endif

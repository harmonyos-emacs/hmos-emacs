/* Input method proxy service.  Handles live for the process because
   detaching would drop the composition/preview state.  */
#ifndef OHOS_HOST_IME_H
#define OHOS_HOST_IME_H

#include <inputmethod/inputmethod_attach_options_capi.h>
#include <inputmethod/inputmethod_controller_capi.h>
#include <inputmethod/inputmethod_text_editor_proxy_capi.h>

#include <cstdint>
#include <string>

struct ImeService
{
  uint32_t frame_id = 1;
  InputMethod_TextEditorProxy *proxy = nullptr;
  InputMethod_InputMethodProxy *client = nullptr;
  InputMethod_AttachOptions *options = nullptr;
  std::string preview;
};

ImeService &HostIme ();

#endif

#include "host_api.h"

#include "ime.h"
#include "host_context.h"

#include "gui_log.h"
#include "ohos_gui.h"

#include <string>
#include <inputmethod/inputmethod_controller_capi.h>
#include <inputmethod/inputmethod_text_editor_proxy_capi.h>
#include <inputmethod/inputmethod_attach_options_capi.h>
#include <inputmethod/inputmethod_inputmethod_proxy_capi.h>
#include <inputmethod/inputmethod_types_capi.h>

/* Input method proxy service.  The handles live for the process because
   detaching makes the next show re-attach and lose the preview state.  */
ImeService &g_ime = HostContext::Get ().ime;

ImeService &
HostIme ()
{
  return g_ime;
}

static std::string
ohos_utf16_to_utf8 (const char16_t *text, size_t length)
{
  std::string utf8;
  for (size_t i = 0; i < length; i++)
    {
      unsigned cp = text[i];
      if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < length)
        cp = 0x10000 + ((cp - 0xd800) << 10) + (text[++i] - 0xdc00);
      if (cp < 0x80)
        utf8.push_back ((char) cp);
      else if (cp < 0x800)
        {
          utf8.push_back ((char) (0xc0 | (cp >> 6)));
          utf8.push_back ((char) (0x80 | (cp & 0x3f)));
        }
      else if (cp < 0x10000)
        {
          utf8.push_back ((char) (0xe0 | (cp >> 12)));
          utf8.push_back ((char) (0x80 | ((cp >> 6) & 0x3f)));
          utf8.push_back ((char) (0x80 | (cp & 0x3f)));
        }
      else
        {
          utf8.push_back ((char) (0xf0 | (cp >> 18)));
          utf8.push_back ((char) (0x80 | ((cp >> 12) & 0x3f)));
          utf8.push_back ((char) (0x80 | ((cp >> 6) & 0x3f)));
          utf8.push_back ((char) (0x80 | (cp & 0x3f)));
        }
    }
  return utf8;
}

static void
ohos_ime_insert_text (InputMethod_TextEditorProxy *proxy, const char16_t *text,
                      size_t length)
{
  (void) proxy;
  if (!text || length == 0)
    return;
  g_ime.preview.clear ();
  std::string utf8 = ohos_utf16_to_utf8 (text, length);
  LOGI ("IME insert utf8 len=%{public}zu", utf8.size ());
  ohos_host_input_text (g_ime.frame_id, utf8.c_str ());
}

static void
ohos_ime_send_key (unsigned code)
{
  ohos_host_input_key (g_ime.frame_id, code, 0, 1);
  ohos_host_input_key (g_ime.frame_id, code, 0, 0);
}

static void
ohos_ime_delete_backward (InputMethod_TextEditorProxy *proxy, int32_t length)
{
  (void) proxy;
  for (int32_t i = 0; i < length; i++)
    ohos_ime_send_key (2055); /* KEYCODE_DEL */
}

static void
ohos_ime_delete_forward (InputMethod_TextEditorProxy *proxy, int32_t length)
{
  (void) proxy;
  for (int32_t i = 0; i < length; i++)
    ohos_ime_send_key (2071); /* KEYCODE_FORWARD_DEL */
}

static void
ohos_ime_enter (InputMethod_TextEditorProxy *proxy,
                InputMethod_EnterKeyType type)
{
  (void) proxy;
  (void) type;
  ohos_ime_send_key (2054); /* KEYCODE_ENTER */
}

static void
ohos_ime_move_cursor (InputMethod_TextEditorProxy *proxy,
                      InputMethod_Direction direction)
{
  (void) proxy;
  switch (direction)
    {
    case IME_DIRECTION_LEFT:
      ohos_ime_send_key (2015);
      break;
    case IME_DIRECTION_RIGHT:
      ohos_ime_send_key (2016);
      break;
    case IME_DIRECTION_UP:
      ohos_ime_send_key (2012);
      break;
    case IME_DIRECTION_DOWN:
      ohos_ime_send_key (2013);
      break;
    default:
      break;
    }
}

static void
ohos_ime_get_config (InputMethod_TextEditorProxy *proxy,
                     InputMethod_TextConfig *config)
{
  (void) proxy;
  if (!config)
    return;
  OH_TextConfig_SetInputType (config, IME_TEXT_INPUT_TYPE_MULTILINE);
  OH_TextConfig_SetEnterKeyType (config, IME_ENTER_KEY_NONE);
  OH_TextConfig_SetPreviewTextSupport (config, true);
  OH_TextConfig_SetSelection (config, 0, 0);
}

static void
ohos_ime_get_left (InputMethod_TextEditorProxy *proxy, int32_t number,
                   char16_t text[], size_t *length)
{
  (void) proxy;
  (void) number;
  (void) text;
  if (length)
    *length = 0;
}

static void
ohos_ime_get_right (InputMethod_TextEditorProxy *proxy, int32_t number,
                    char16_t text[], size_t *length)
{
  (void) proxy;
  (void) number;
  (void) text;
  if (length)
    *length = 0;
}

static int32_t
ohos_ime_index (InputMethod_TextEditorProxy *proxy)
{
  (void) proxy;
  return 0;
}

static int32_t
ohos_ime_preview (InputMethod_TextEditorProxy *proxy, const char16_t text[],
                  size_t length, int32_t start, int32_t end)
{
  (void) proxy;
  (void) start;
  (void) end;
  g_ime.preview = text ? ohos_utf16_to_utf8 (text, length) : std::string ();
  LOGI ("IME preview len=%{public}zu", g_ime.preview.size ());
  return 0;
}

static void
ohos_ime_finish_preview (InputMethod_TextEditorProxy *proxy)
{
  (void) proxy;
  if (!g_ime.preview.empty ())
    {
      LOGI ("IME commit preview len=%{public}zu", g_ime.preview.size ());
      ohos_host_input_text (g_ime.frame_id, g_ime.preview.c_str ());
      g_ime.preview.clear ();
    }
}

static void
ohos_ime_keyboard_status (InputMethod_TextEditorProxy *proxy,
                          InputMethod_KeyboardStatus status)
{
  (void) proxy;
  (void) status;
}

static void
ohos_ime_set_selection (InputMethod_TextEditorProxy *proxy, int32_t start,
                        int32_t end)
{
  (void) proxy;
  (void) start;
  (void) end;
}

static void
ohos_ime_extend (InputMethod_TextEditorProxy *proxy,
                 InputMethod_ExtendAction action)
{
  (void) proxy;
  (void) action;
}

static int32_t
ohos_ime_private (InputMethod_TextEditorProxy *proxy,
                  InputMethod_PrivateCommand *command[], size_t size)
{
  (void) proxy;
  (void) command;
  (void) size;
  return 0;
}

/* Drop the current IME client and its proxy.  The input method service
   invalidates a client while its window is in the background, so a later
   ShowKeyboard on the stale handle fails with 12800016 ("client is not
   editable").  Re-attaching gives us a fresh editable client.  */
static void
ohos_ime_reset (void)
{
  if (g_ime.client)
    {
      InputMethod_ErrorCode err
          = OH_InputMethodController_Detach (g_ime.client);
      if (err != IME_ERR_OK)
        LOGW ("IME detach err=%{public}d", err);
      g_ime.client = nullptr;
    }
  if (g_ime.proxy)
    {
      OH_TextEditorProxy_Destroy (g_ime.proxy);
      g_ime.proxy = nullptr;
    }
  if (g_ime.options)
    {
      OH_AttachOptions_Destroy (g_ime.options);
      g_ime.options = nullptr;
    }
  g_ime.preview.clear ();
}

bool
ohos_ime_init (void)
{
  if (g_ime.client)
    return true;
  g_ime.proxy = OH_TextEditorProxy_Create ();
  if (!g_ime.proxy)
    return false;
  OH_TextEditorProxy_SetGetTextConfigFunc (g_ime.proxy, ohos_ime_get_config);
  OH_TextEditorProxy_SetInsertTextFunc (g_ime.proxy, ohos_ime_insert_text);
  OH_TextEditorProxy_SetDeleteBackwardFunc (g_ime.proxy,
                                            ohos_ime_delete_backward);
  OH_TextEditorProxy_SetDeleteForwardFunc (g_ime.proxy,
                                           ohos_ime_delete_forward);
  OH_TextEditorProxy_SetSendEnterKeyFunc (g_ime.proxy, ohos_ime_enter);
  OH_TextEditorProxy_SetMoveCursorFunc (g_ime.proxy, ohos_ime_move_cursor);
  OH_TextEditorProxy_SetGetLeftTextOfCursorFunc (g_ime.proxy,
                                                 ohos_ime_get_left);
  OH_TextEditorProxy_SetGetRightTextOfCursorFunc (g_ime.proxy,
                                                  ohos_ime_get_right);
  OH_TextEditorProxy_SetGetTextIndexAtCursorFunc (g_ime.proxy, ohos_ime_index);
  OH_TextEditorProxy_SetSetPreviewTextFunc (g_ime.proxy, ohos_ime_preview);
  OH_TextEditorProxy_SetFinishTextPreviewFunc (g_ime.proxy,
                                               ohos_ime_finish_preview);
  OH_TextEditorProxy_SetSendKeyboardStatusFunc (g_ime.proxy,
                                                ohos_ime_keyboard_status);
  OH_TextEditorProxy_SetHandleSetSelectionFunc (g_ime.proxy,
                                                ohos_ime_set_selection);
  OH_TextEditorProxy_SetHandleExtendActionFunc (g_ime.proxy, ohos_ime_extend);
  OH_TextEditorProxy_SetReceivePrivateCommandFunc (g_ime.proxy,
                                                   ohos_ime_private);
  OH_TextEditorProxy_SetCallbackInMainThread (g_ime.proxy, true);
  g_ime.options = OH_AttachOptions_Create (true);
  if (!g_ime.options)
    {
      LOGE ("IME options null");
      return false;
    }
  InputMethod_ErrorCode err = OH_InputMethodController_Attach (
      g_ime.proxy, g_ime.options, &g_ime.client);
  LOGE ("IME attach err=%{public}d", err);
  return err == IME_ERR_OK && g_ime.client;
}

extern "C" void
ohosgui_show_ime (uint32_t frame_id)
{
  g_ime.frame_id = frame_id;
  if (!ohos_ime_init ())
    return;
  InputMethod_ErrorCode err = OH_InputMethodProxy_ShowKeyboard (g_ime.client);
  if (err != IME_ERR_OK)
    {
      LOGW ("IME show err=%{public}d; re-attaching", err);
      ohos_ime_reset ();
      if (!ohos_ime_init ())
        return;
      err = OH_InputMethodProxy_ShowKeyboard (g_ime.client);
    }
  LOGI ("IME show err=%{public}d", err);
}

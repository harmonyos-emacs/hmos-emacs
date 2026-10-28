#include "host_api.h"

#include "emacs_host.h"

#include "emacs_internal.h"
#include "host_context.h"
#include "text_lines.h" // NOLINT: shared service operations
#include "napi_util.h"

/*
 * Native back end for GNU Emacs on HarmonyOS.
 *
 * The Emacs core is loaded from libemacs_gui.so into this process and
 * runs on its own thread.  libentry.so owns the ArkUI surface, the draw
 * command stream and the host-side window/IME services; Emacs owns
 * redisplay, frames and fonts.
 */

#include <napi/native_api.h>
#include <execinfo.h>
#include <signal.h>
#include <ucontext.h>

#include <hilog/log.h>

#include <atomic>
#include <deque>
#include <mutex>
#include <cerrno>
#include <climits>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <algorithm>
#include <vector>

#include <dirent.h>
#include <dlfcn.h>
#include <link.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <zlib.h>
#include <execinfo.h>
#include <signal.h>
#include <ucontext.h>
#include <ctime>

#include "ohos_gui.h"

#include <inputmethod/inputmethod_controller_capi.h>
#include <inputmethod/inputmethod_text_editor_proxy_capi.h>
#include <inputmethod/inputmethod_attach_options_capi.h>
#include <inputmethod/inputmethod_inputmethod_proxy_capi.h>
#include <inputmethod/inputmethod_types_capi.h>

#define OHOS_LOG_TAG "native.host"
#include "gui_log.h"

static void
InProcLog (const char *s)
{
  if (!s)
    return;

  /* Emacs' log callback is still a string (no ABI bump).  Map the
     existing prefixes onto hilog tags/levels so the normal hilog
     controls apply; hot render/probe lines are DEBUG.  */
  const char *tag = OHOS_LOG_TAG_EMACS_LIFECYCLE;
  LogLevel level = LOG_INFO;
  const char *message = s;

  if (strncmp (s, "OHOSDBG ", 8) == 0)
    {
      tag = OHOS_LOG_TAG_EMACS_RENDER;
      level = LOG_DEBUG;
      message = s + 8;
    }
  else if (strncmp (s, "input ", 6) == 0 || strncmp (s, "menubar ", 8) == 0
           || strncmp (s, "key ", 4) == 0)
    {
      tag = OHOS_LOG_TAG_EMACS_INPUT;
      level = LOG_DEBUG;
    }
  else if (strncmp (s, "glyphstr ", 9) == 0
           || strncmp (s, "image glyph", 11) == 0)
    {
      tag = OHOS_LOG_TAG_EMACS_RENDER;
      level = LOG_DEBUG;
    }
  else if (strncmp (s, "menu", 4) == 0)
    tag = OHOS_LOG_TAG_EMACS_MENU;

  if (level == LOG_DEBUG && !OH_LOG_IsLoggable (0x0000, tag, LOG_DEBUG))
    return;
  OH_LOG_Print (LOG_APP, level, 0x0000, tag, "%{public}s", message);
}
/* Process-lifetime service owning everything about the in-process Emacs:
   the resolved ABI, the thread, its arguments and the draw-wakeup TSFN.  */
EmacsHost &g_emacs = HostContext::Get ().emacs;

EmacsHost &
HostEmacs ()
{
  return g_emacs;
}
static struct
{
  bool have = false;
  int kind = -1;
  uint32_t frame_id = ohosgui::kBootFrameId;
  void *window = nullptr;
  int width = 0;
  int height = 0;
  uint64_t generation = 0;
} pending_surface;

static void *last_surface_window;
static bool initial_surface_pending;

static void
DeliverSurface (void)
{
  if (!g_emacs.api)
    return;
  if (initial_surface_pending && last_surface_window
      && g_emacs.api->surface_created)
    {
      LOGI ("OHOSDBG calling surface created");
      g_emacs.api->surface_created (
          pending_surface.frame_id, last_surface_window, pending_surface.width,
          pending_surface.height, pending_surface.generation);
      LOGI ("OHOSDBG returned surface created");
      initial_surface_pending = false;
      /* The pending event is the same boot surface: do not report the
         creation twice.  A pending resize was already folded into the
         size above.  */
      if (pending_surface.kind == 0 || pending_surface.kind == 1)
        pending_surface.have = false;
    }
  if (!pending_surface.have)
    return;
  if (pending_surface.kind == 0 && g_emacs.api->surface_created)
    {
      LOGI ("OHOSDBG calling pending surface created");
      g_emacs.api->surface_created (
          pending_surface.frame_id, pending_surface.window,
          pending_surface.width, pending_surface.height,
          pending_surface.generation);
      LOGI ("OHOSDBG returned pending surface created");
    }
  else if (pending_surface.kind == 1 && g_emacs.api->surface_resized)
    g_emacs.api->surface_resized (pending_surface.frame_id,
                                  pending_surface.width, pending_surface.height,
                                  pending_surface.generation);
  else if (pending_surface.kind == 2 && g_emacs.api->surface_destroyed)
    g_emacs.api->surface_destroyed (pending_surface.frame_id,
                                    pending_surface.generation);
  pending_surface.have = false;
}

extern "C" void
HostFlushPendingSurface (void)
{
  LOGI ("OHOSDBG surface flush pending have=%{public}d kind=%{public}d "
        "api=%{public}p created=%{public}p",
        pending_surface.have ? 1 : 0, pending_surface.kind, g_emacs.api,
        g_emacs.api ? (void *) g_emacs.api->surface_created : nullptr);
  DeliverSurface ();
}

extern "C" void
ohos_host_surface_created (uint32_t frame_id, void *window, int width,
                           int height, uint64_t generation)
{
  LOGI ("OHOSDBG surface created %{public}dx%{public}d", width, height);
  last_surface_window = window;
  pending_surface = { true, 0, frame_id, window, width, height, generation };
  if (!g_emacs.api)
    initial_surface_pending = true;
  DeliverSurface ();
}

extern "C" void
ohos_host_surface_resized (uint32_t frame_id, int width, int height,
                           uint64_t generation)
{
  pending_surface
      = { true, 1, frame_id, last_surface_window, width, height, generation };
  if (!g_emacs.api && last_surface_window)
    initial_surface_pending = true;
  DeliverSurface ();
}

extern "C" void
ohos_host_surface_destroyed (uint32_t frame_id, uint64_t generation)
{
  pending_surface = { true, 2, frame_id, nullptr, 0, 0, generation };
  DeliverSurface ();
}

extern "C" void
ohos_host_input_key (uint32_t frame_id, unsigned key, unsigned modifiers,
                     int pressed)
{
  g_emacs.activity.fetch_add (1, std::memory_order_relaxed);
  if (g_emacs.api && g_emacs.api->input_key)
    g_emacs.api->input_key (frame_id, key, modifiers, pressed);
}

extern "C" void
ohos_host_input_motion (uint32_t frame_id, int x, int y, unsigned modifiers)
{
  g_emacs.activity.fetch_add (1, std::memory_order_relaxed);
  if (g_emacs.api && g_emacs.api->input_motion)
    g_emacs.api->input_motion (frame_id, x, y, modifiers);
}

extern "C" void
ohos_host_input_text (uint32_t frame_id, const char *text)
{
  g_emacs.activity.fetch_add (1, std::memory_order_relaxed);
  if (g_emacs.api && g_emacs.api->input_text)
    g_emacs.api->input_text (frame_id, text);
}

/* ------------------------------------------------------------------ */
/* Typed host -> ArkUI event mailbox.  Emacs only pushes small value
   records or copied strings; ArkTS drains them through guiTakeHostEvent
   and applies them on the UI thread.  */

enum class HostOp : int
{
  CREATE = 1,
  DESTROY,
  RAISE,
  LOWER,
  TITLE,
  SIZE,
  POSITION,
  VISIBLE,
  FULLSCREEN,
  MINIMIZE,
  ALPHA,
  CURSOR,
  HOURGLASS,
  BELL,
  POINTER_WARP,
  NO_FOCUS_ON_MAP,
  NO_ACCEPT_FOCUS,
  MENU_BAR,
  MENU_SHOW,
  MENU_CLOSE,
  REQUEST
};

struct HostEvent
{
  HostOp op;
  uint32_t frame_id = 0;
  int a = 0, b = 0, c = 0, d = 0, e = 0, f = 0, g = 0;
  std::string text;
};

static std::mutex g_event_lock;
static std::deque<HostEvent> g_event_queue;

static bool
PushHostEvent (HostEvent &&event)
{
  {
    std::lock_guard<std::mutex> guard (g_event_lock);
    if (g_event_queue.size () >= 256)
      {
        LOGE ("host event queue full op=%{public}d frame=%{public}u",
              (int) event.op, event.frame_id);
        return false;
      }
    g_event_queue.push_back (std::move (event));
  }
  RequestHostWake ();
  return true;
}

static int
HostCreateWindow (uint32_t frame_id, const struct ohos_window_params *params)
{
  if (!params)
    return -1;
  HostEvent event{};
  event.op = HostOp::CREATE;
  event.frame_id = frame_id;
  event.a = params->width;
  event.b = params->height;
  event.c = params->x;
  event.d = params->y;
  event.e = (int) params->parent_frame_id;
  event.f = params->undecorated;
  event.g = params->dialog;
  event.text = params->title ? params->title : "";
  return PushHostEvent (std::move (event)) ? 0 : -1;
}

static void
HostDestroyWindow (uint32_t frame_id)
{
  HostEvent event{};
  event.op = HostOp::DESTROY;
  event.frame_id = frame_id;
  PushHostEvent (std::move (event));
}

static void
HostRaiseWindow (uint32_t frame_id)
{
  HostEvent event{};
  event.op = HostOp::RAISE;
  event.frame_id = frame_id;
  PushHostEvent (std::move (event));
}

static void
HostLowerWindow (uint32_t frame_id)
{
  HostEvent event{};
  event.op = HostOp::LOWER;
  event.frame_id = frame_id;
  PushHostEvent (std::move (event));
}

static void
HostSetWindowTitle (uint32_t frame_id, const char *title)
{
  HostEvent event{};
  event.op = HostOp::TITLE;
  event.frame_id = frame_id;
  event.text = title ? title : "";
  PushHostEvent (std::move (event));
}

static void
HostSetWindowSize (uint32_t frame_id, int width, int height)
{
  HostEvent event{};
  event.op = HostOp::SIZE;
  event.frame_id = frame_id;
  event.a = width;
  event.b = height;
  PushHostEvent (std::move (event));
}

static void
HostSetWindowPosition (uint32_t frame_id, int x, int y)
{
  HostEvent event{};
  event.op = HostOp::POSITION;
  event.frame_id = frame_id;
  event.a = x;
  event.b = y;
  PushHostEvent (std::move (event));
}

static void
HostSetVisible (uint32_t frame_id, int visible)
{
  HostEvent event{};
  event.op = HostOp::VISIBLE;
  event.frame_id = frame_id;
  event.a = visible;
  PushHostEvent (std::move (event));
}

static void
HostSetFullscreen (uint32_t frame_id, int fullscreen)
{
  HostEvent event{};
  event.op = HostOp::FULLSCREEN;
  event.frame_id = frame_id;
  event.a = fullscreen;
  PushHostEvent (std::move (event));
}

static void
HostMinimizeWindow (uint32_t frame_id)
{
  HostEvent event{};
  event.op = HostOp::MINIMIZE;
  event.frame_id = frame_id;
  PushHostEvent (std::move (event));
}

static void
HostSetAlpha (uint32_t frame_id, int percent)
{
  HostEvent event{};
  event.op = HostOp::ALPHA;
  event.frame_id = frame_id;
  event.a = percent;
  PushHostEvent (std::move (event));
}

static void
HostSetCursor (uint32_t frame_id, int cursor)
{
  HostEvent event{};
  event.op = HostOp::CURSOR;
  event.frame_id = frame_id;
  event.a = cursor;
  PushHostEvent (std::move (event));
}

static void
HostSetHourglass (uint32_t frame_id, int on)
{
  HostEvent event{};
  event.op = HostOp::HOURGLASS;
  event.frame_id = frame_id;
  event.a = on;
  PushHostEvent (std::move (event));
}

static void
HostBell (uint32_t frame_id)
{
  HostEvent event{};
  event.op = HostOp::BELL;
  event.frame_id = frame_id;
  PushHostEvent (std::move (event));
}

static void
HostPointerWarp (uint32_t frame_id, int x, int y)
{
  HostEvent event{};
  event.op = HostOp::POINTER_WARP;
  event.frame_id = frame_id;
  event.a = x;
  event.b = y;
  PushHostEvent (std::move (event));
}

static void
HostSetNoFocusOnMap (uint32_t frame_id, int no_focus)
{
  HostEvent event{};
  event.op = HostOp::NO_FOCUS_ON_MAP;
  event.frame_id = frame_id;
  event.a = no_focus;
  PushHostEvent (std::move (event));
}

static void
HostSetNoAcceptFocus (uint32_t frame_id, int no_accept)
{
  HostEvent event{};
  event.op = HostOp::NO_ACCEPT_FOCUS;
  event.frame_id = frame_id;
  event.a = no_accept;
  PushHostEvent (std::move (event));
}

static int
HostMenuBar (uint32_t frame_id, const char *text, size_t len)
{
  HostEvent event{};
  event.op = HostOp::MENU_BAR;
  event.frame_id = frame_id;
  event.text.assign (text ? text : "", text ? len : 0);
  return PushHostEvent (std::move (event)) ? 0 : -1;
}

static int
HostMenuShow (uint32_t frame_id, int menu_id, int flags, int dialog,
              const char *text, size_t len)
{
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_MENU,
            "menu host-show frame=%{public}u menu=%{public}d "
            "flags=%{public}d dialog=%{public}d bytes=%{public}zu",
            frame_id, menu_id, flags, dialog, len);
  HostEvent event{};
  event.op = HostOp::MENU_SHOW;
  event.frame_id = frame_id;
  event.a = menu_id;
  event.b = flags;
  event.c = dialog;
  event.text.assign (text ? text : "", text ? len : 0);
  return PushHostEvent (std::move (event)) ? 0 : -1;
}

static void
HostMenuClose (uint32_t frame_id, int menu_id)
{
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_MENU,
            "menu host-close frame=%{public}u menu=%{public}d", frame_id,
            menu_id);
  HostEvent event{};
  event.op = HostOp::MENU_CLOSE;
  event.frame_id = frame_id;
  event.a = menu_id;
  PushHostEvent (std::move (event));
}

static int
HostRequest (uint32_t frame_id, int kind, int request_id, const char *text,
             size_t len)
{
  HostEvent event{};
  event.op = HostOp::REQUEST;
  event.frame_id = frame_id;
  event.a = kind;
  event.b = request_id;
  event.text.assign (text ? text : "", text ? len : 0);
  return PushHostEvent (std::move (event)) ? 0 : -1;
}

/* Host-side frame/chrome callbacks.  Drawing goes directly to the
   statically linked renderer.  */
static const struct ohos_host_api g_ui_api = {
  OHOS_GUI_ABI_VERSION,
  {
      ohosgui::ohos_gui_set_frame_metrics,
      ohosgui::ohos_gui_set_title,
      HostCreateWindow,
      HostDestroyWindow,
      HostRaiseWindow,
      HostSetWindowTitle,
      HostSetWindowSize,
      HostSetWindowPosition,
      HostLowerWindow,
      HostSetVisible,
      HostSetFullscreen,
      HostMinimizeWindow,
      HostSetAlpha,
      HostSetCursor,
      HostSetHourglass,
      HostBell,
      HostPointerWarp,
      HostSetNoFocusOnMap,
      HostSetNoAcceptFocus,
      HostMenuBar,
      HostMenuShow,
      HostMenuClose,
      HostRequest,
      ohosgui::ohos_gui_set_clipboard,
      InProcLog,
      RequestHostWake,
  },
};

/* Resolve the single Emacs-side entry point and verify the ABI.  */
const struct ohos_emacs_api *
EmacsLoadApi (const char *who)
{
  void *h = dlopen ("libemacs_gui.so", RTLD_NOW | RTLD_LOCAL);
  if (!h)
    {
      LOGE ("%{public}s dlopen: %{public}s", who, dlerror ());
      return nullptr;
    }
  const struct ohos_emacs_api *(*get_api) (uint32_t)
      = (const struct ohos_emacs_api *(*) (uint32_t)) dlsym (h,
                                                             "ohos_emacs_api");
  if (!get_api)
    {
      LOGE ("%{public}s missing ohos_emacs_api", who);
      return nullptr;
    }
  const struct ohos_emacs_api *api = get_api (OHOS_GUI_ABI_VERSION);
  if (!api)
    {
      LOGE ("%{public}s ABI mismatch host=%{public}d", who,
            OHOS_GUI_ABI_VERSION);
      return nullptr;
    }
  LOGI ("%{public}s OHOS GUI ABI %{public}d", who, (int) api->abi_version);
  if (g_emacs.have_display_metrics && api->set_display_metrics)
    api->set_display_metrics (g_emacs.density_dpi, g_emacs.density_pixels,
                              g_emacs.scaled_density, g_emacs.xdpi,
                              g_emacs.ydpi);
  return api;
}

static void
HostWakeupCallJs (napi_env env, napi_value js_cb, void *context, void *data)
{
  (void) context;
  (void) data;
  g_emacs.host_wakeup_pending.store (false);
  if (env && js_cb)
    {
      napi_value undefined = nullptr;
      napi_get_undefined (env, &undefined);
      napi_call_function (env, undefined, js_cb, 0, nullptr, nullptr);
    }
}

void
RequestHostWake (void)
{
  if (!g_emacs.host_tsfn)
    return;
  if (g_emacs.host_wakeup_pending.exchange (true))
    return;
  g_emacs.host_wakeup_calls++;
  napi_status status = napi_call_threadsafe_function (
      g_emacs.host_tsfn, nullptr, napi_tsfn_nonblocking);
  if (status != napi_ok)
    {
      g_emacs.host_wakeup_pending.store (false);
      if (status != napi_queue_full)
        LOGW ("host wakeup: napi status=%{public}d", (int) status);
    }
}

void
CreateHostWakeup (napi_env env, napi_value callback)
{
  if (g_emacs.host_tsfn)
    {
      napi_release_threadsafe_function (g_emacs.host_tsfn, napi_tsfn_release);
      g_emacs.host_tsfn = nullptr;
    }
  napi_value name = nullptr;
  napi_create_string_utf8 (env, "ohos-host-wakeup", NAPI_AUTO_LENGTH, &name);
  napi_status status = napi_create_threadsafe_function (
      env, callback, nullptr, name, 8, 1, nullptr, nullptr, nullptr,
      HostWakeupCallJs, &g_emacs.host_tsfn);
  if (status != napi_ok)
    {
      g_emacs.host_tsfn = nullptr;
      LOGW ("host wakeup: create TSFN failed status=%{public}d", (int) status);
    }
}

void
ohos_host_input_menubar (uint32_t frame_id, int index)
{
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_MENU,
            "menu host-enqueue frame=%{public}u index=%{public}d", frame_id,
            index);
  if (g_emacs.api && g_emacs.api->input_menubar)
    g_emacs.api->input_menubar (frame_id, index);
}

extern "C" void
ohosgui_mouse (uint32_t frame_id, int button, int x, int y, unsigned modifiers,
               int press)
{
  g_emacs.activity.fetch_add (1, std::memory_order_relaxed);
  if (g_emacs.api && g_emacs.api->input_mouse)
    g_emacs.api->input_mouse (frame_id, button, x, y, modifiers, press);
}

extern "C" void
ohosgui_host_input_wheel (uint32_t frame_id, int delta, int col, int row,
                          unsigned modifiers)
{
  g_emacs.activity.fetch_add (1, std::memory_order_relaxed);
  if (g_emacs.api && g_emacs.api->input_wheel)
    g_emacs.api->input_wheel (frame_id, delta, col, row, modifiers);
}

extern "C" void
ohosgui_focus (uint32_t frame_id, int focused)
{
  if (g_emacs.api && g_emacs.api->input_focus)
    g_emacs.api->input_focus (frame_id, focused);
}

extern "C" void
ohosgui_font_metrics (int ascent, int descent, int height, int space_width,
                      int underline_position, int underline_thickness)
{
  if (g_emacs.api && g_emacs.api->font_metrics)
    g_emacs.api->font_metrics (ascent, descent, height, space_width,
                               underline_position, underline_thickness);
}

extern "C" int
ohosgui_write_input (uint32_t frame_id, const char *data, size_t len)
{
  bool non_ascii = false;
  for (size_t i = 0; i < len; i++)
    if ((unsigned char) data[i] >= 0x80)
      {
        non_ascii = true;
        break;
      }
  if (!g_emacs.api)
    return (int) len;
  if (non_ascii && g_emacs.api->input_text)
    {
      std::string text (data, len);
      g_emacs.api->input_text (frame_id, text.c_str ());
    }
  else if (g_emacs.api->input_raw)
    g_emacs.api->input_raw (frame_id, data, len);
  return (int) len;
}

/* Host chrome hooks for ohos_gui.cpp.  Each one degrades to a no-op (and
   a non-zero return where it matters) before Emacs has been loaded.  */

extern "C" void
ohosgui_host_menu_result (int id, int index)
{
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_MENU,
            "menu host-result menu=%{public}d index=%{public}d", id, index);
  if (g_emacs.api && g_emacs.api->menu_result)
    g_emacs.api->menu_result (id, index);
}

extern "C" void
ohosgui_host_request_result (int id, int status, const char *text)
{
  if (g_emacs.api && g_emacs.api->request_result)
    g_emacs.api->request_result (id, status, text, text ? strlen (text) : 0);
}

extern "C" void
ohosgui_host_input_expose (uint32_t frame_id, int x, int y, int width,
                           int height)
{
  if (g_emacs.api && g_emacs.api->input_expose)
    g_emacs.api->input_expose (frame_id, x, y, width, height);
}

extern "C" int
ohosgui_host_input_resize (uint32_t frame_id, int width, int height)
{
  if (!g_emacs.api || !g_emacs.api->input_resize || width <= 0 || height <= 0)
    return -1;
  g_emacs.api->input_resize (frame_id, width, height);
  return 0;
}

static void
SetIntProperty (napi_env env, napi_value object, const char *name, int value)
{
  napi_value v;
  napi_create_int32 (env, value, &v);
  napi_set_named_property (env, object, name, v);
}

/* Typed host event drain for ArkTS.  Returns null when the queue is empty,
   otherwise one object { op, frameId, a, b, c, d, e, text }.  */
napi_value
GuiTakeHostEvent (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  (void) info;
  HostEvent event{};
  bool have = false;
  {
    std::lock_guard<std::mutex> guard (g_event_lock);
    if (!g_event_queue.empty ())
      {
        event = std::move (g_event_queue.front ());
        g_event_queue.pop_front ();
        have = true;
      }
  }
  if (!have)
    {
      napi_value null_value;
      napi_get_null (env, &null_value);
      return null_value;
    }
  napi_value object;
  napi_create_object (env, &object);
  SetIntProperty (env, object, "op", (int) event.op);
  SetIntProperty (env, object, "frameId", (int) event.frame_id);
  SetIntProperty (env, object, "a", event.a);
  SetIntProperty (env, object, "b", event.b);
  SetIntProperty (env, object, "c", event.c);
  SetIntProperty (env, object, "d", event.d);
  SetIntProperty (env, object, "e", event.e);
  SetIntProperty (env, object, "f", event.f);
  SetIntProperty (env, object, "g", event.g);
  napi_value text;
  napi_create_string_utf8 (env, event.text.c_str (), event.text.size (), &text);
  napi_set_named_property (env, object, "text", text);
  return object;
}

napi_value
GuiCloseRequest (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 1;
  napi_value argv[1] = { nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t frame_id = (int32_t) ohosgui::kBootFrameId;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &frame_id);
  if (g_emacs.api && g_emacs.api->close_request)
    g_emacs.api->close_request ((uint32_t) frame_id);
  return ReturnInt (env, 0);
}

napi_value
GuiWindowCreateFailed (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t frame_id = 0;
  std::string reason;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &frame_id);
  if (argc > 1)
    reason = NapiString (env, argv[1]);
  if (g_emacs.api && g_emacs.api->window_create_failed)
    g_emacs.api->window_create_failed ((uint32_t) frame_id, reason.c_str ());
  return ReturnInt (env, 0);
}

napi_value
GuiFocusForFrame (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  int32_t frame_id = (int32_t) ohosgui::kBootFrameId;
  bool focused = false;
  if (argc > 0)
    napi_get_value_int32 (env, argv[0], &frame_id);
  if (argc > 1)
    napi_get_value_bool (env, argv[1], &focused);
  if (g_emacs.api && g_emacs.api->input_focus)
    g_emacs.api->input_focus ((uint32_t) frame_id, focused ? 1 : 0);
  return ReturnInt (env, 0);
}

/* Diagnostic helper: when <cwd>/home/stack-watchdog exists, a helper
   thread waits STACK_WATCHDOG_SECONDS and then delivers SIGSEGV to the
   Emacs thread.  Emacs' own fatal-signal handler runs on that thread, so
   the fault log records the native stack of whatever the Emacs thread is
   blocked in (startup hangs included).  No effect when the marker file is
   absent, so normal runs are unchanged.  */

#define STACK_WATCHDOG_SECONDS 120

static void *
StackWatchdog (void *arg)
{
  (void) arg;
  for (int i = 0; i < STACK_WATCHDOG_SECONDS; i++)
    sleep (1);
  if (!g_emacs.running)
    return nullptr;
  LOGE ("stack watchdog: sending SIGSEGV to the Emacs thread");
  pthread_kill (g_emacs.tid, SIGSEGV);
  return nullptr;
}

void
MaybeStartStackWatchdog (const char *cwd)
{
  if (!cwd || !cwd[0])
    return;
  /* Opt-in diagnostic: it kills the Emacs thread after
     STACK_WATCHDOG_SECONDS, so it must never arm by accident.  */
  const char *enable = getenv ("EMACS_OHOS_STACK_WATCHDOG");
  if (!enable || enable[0] != '1')
    return;
  pthread_t tid;
  if (pthread_create (&tid, nullptr, StackWatchdog, (void *) cwd) == 0)
    pthread_detach (tid);
}

static void *
InProcMain (void *arg)
{
  (void) arg;

  std::vector<std::string> args = g_emacs.args;
  if (args.empty () && !g_emacs.cwd.empty ())
    {
      args.push_back ("--dump-file");
      args.push_back (g_emacs.cwd + "/bootstrap-emacs.pdmp");
    }

  std::vector<char *> argv;
  argv.push_back ((char *) "emacs");
  for (auto &a : args)
    argv.push_back (const_cast<char *> (a.c_str ()));
  argv.push_back (nullptr);

  LOGI ("inproc main enter argc=%{public}zu", argv.size () - 1);
  int rc = g_emacs.api->run ((int) argv.size () - 1, argv.data (), &g_ui_api);
  LOGI ("inproc main returned %{public}d", rc);
  return NULL;
}

static void *
DumpInProcessMain (void *arg)
{
  (void) arg;
  char *argv[] = { (char *) "emacs",  (char *) "--temacs=pbootstrap",
                   (char *) "-batch", (char *) "-l",
                   (char *) "loadup", NULL };
  LOGI ("dump-in-process enter argc=5");
  dprintf (2, "dump-in-process argv=[%s][%s][%s][%s][%s]\n", argv[0], argv[1],
           argv[2], argv[3], argv[4]);
  int rc = g_emacs.api->run (5, argv, &g_ui_api);
  LOGI ("dump-in-process returned %{public}d", rc);
  return NULL;
}

int
EmacsStartGuiThread ()
{
  EmacsHost &host = HostEmacs ();
  if (pthread_create (&host.tid, nullptr, InProcMain, nullptr) != 0)
    {
      host.running = false;
      return -1;
    }
  return 0;
}

int
EmacsStartDumpThread ()
{
  pthread_t tid;
  if (pthread_create (&tid, nullptr, DumpInProcessMain, nullptr) != 0)
    return -1;
  pthread_detach (tid);
  return 0;
}

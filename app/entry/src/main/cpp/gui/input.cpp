#include "input.h"

#define OHOS_LOG_TAG "native.input"
#include "gui_log.h"
#include "ohos_gui.h"
#include "surface.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <string>

namespace ohosgui
{
namespace
{
/* Menu popup state: while a menu is open Escape cancels the popup instead
   of reaching Emacs as a meta prefix.  */
std::atomic<int> g_menu_open{ 0 };
std::atomic<int> g_menu_esc{ 0 };

int
CellWidth (const Surface &s)
{
  return s.cell_w > 0 ? s.cell_w : kFontW;
}

int
CellHeight (const Surface &s)
{
  return s.cell_h > 0 ? s.cell_h : kNativeLineH;
}

/* Map surface pixels to frame pixels.  The frame bitmap may be scaled
   to the window while a resize settles, so account for both the scale
   and the centering offsets.  */
bool
PointFromSurface (Surface &s, float x, float y, int &fx, int &fy)
{
  if (s.frame_w <= 0 || s.frame_h <= 0 || s.width <= 0 || s.height <= 0)
    return false;
  float scale = std::min ((float) s.width / (float) s.frame_w,
                          (float) s.height / (float) s.frame_h);
  float dx = ((float) s.width - (float) s.frame_w * scale) / 2.0f;
  float dy = ((float) s.height - (float) s.frame_h * scale) / 2.0f;
  float fxx = (x - dx) / scale;
  float fyy = (y - dy) / scale;
  if (fxx < 0 || fyy < 0 || fxx >= s.frame_w || fyy >= s.frame_h)
    return false;
  fx = (int) fxx;
  fy = (int) fyy;
  return true;
}

bool
CellFromPoint (Surface &s, float x, float y, int &col, int &row)
{
  int fx, fy;
  if (!PointFromSurface (s, x, y, fx, fy))
    return false;
  col = fx / CellWidth (s);
  row = fy / CellHeight (s);
  /* Do not clamp ROW to s.rows: mode line and echo area are real Emacs
     frame pixels even though they are not text rows.  */
  return col >= 0 && row >= 0;
}

/* One physical click reaches us through both the touch and the mouse
   callback, in either order and a few ms apart.  The second copy aborts a
   drag before it starts (Emacs folds the duplicate into a double click),
   so drop exact repeats at the single exit instead of relying on callback
   order.  */
void
SendMouse (Surface &s, int button, int x, int y, bool press)
{
  static int last_button = -1, last_x = -1, last_y = -1, last_press = -1;
  static std::chrono::steady_clock::time_point last_at{};
  auto now = std::chrono::steady_clock::now ();

  if (button == 32)
    return;
  if (button == last_button && x == last_x && y == last_y
      && (press ? 1 : 0) == last_press
      && now - last_at < std::chrono::milliseconds (80))
    {
      LOGI ("duplicate mouse event dropped button=%{public}d press=%{public}d "
            "xy=%{public}d,%{public}d",
            button, press ? 1 : 0, x, y);
      return;
    }
  last_button = button;
  last_x = x;
  last_y = y;
  last_press = press ? 1 : 0;
  last_at = now;

  ohosgui_mouse (s.frame_id, button, x, y, 0, press ? 1 : 0);
}

/* Pointer moved to frame pixel (X, Y).  These coordinates are required
   to reach mode line and echo area; cell coordinates would stop at the
   last text row.  */
void
SendMouseMotion (Surface &s, int x, int y)
{
  static int last_x = -1, last_y = -1;
  if (x != last_x || y != last_y)
    {
      last_x = x;
      last_y = y;
    }
  ohos_host_input_motion (s.frame_id, x, y, 0);
}

void
HandleTouch (Surface &s, OH_NativeXComponent_TouchEvent &event)
{
  int col, row, fx, fy;
  if (!PointFromSurface (s, event.x, event.y, fx, fy))
    {
      /* A selection drag can end over the menu bar, which is outside the
         XComponent.  Do not drop the UP: Emacs would keep mouse-1 down.  */
      if (event.type == OH_NATIVEXCOMPONENT_UP && s.mouse_last_x >= 0
          && s.mouse_last_y >= 0)
        SendMouse (s, 0, s.mouse_last_x, s.mouse_last_y, false);
      return;
    }
  CellFromPoint (s, event.x, event.y, col, row);

  /* A physical mouse click arrives here and in OnMouse: one click became
     press,press,release,release and Emacs folded it into a double click
     (task book B-13).  If the mouse callback just handled this same cell,
     the touch copy is the duplicate.  */
  if (s.mouse_event_col == col && s.mouse_event_row == row
      && std::chrono::steady_clock::now () - s.mouse_event_at
             < std::chrono::milliseconds (120))
    {
      LOGI ("touch duplicate of mouse event ignored col=%{public}d "
            "row=%{public}d",
            col, row);
      return;
    }

  if (event.type == OH_NATIVEXCOMPONENT_DOWN)
    {
      SendMouse (s, 0, fx, fy, true);
      s.mouse_last_col = col;
      s.mouse_last_row = row;
      s.mouse_last_x = fx;
      s.mouse_last_y = fy;
      s.metrics.frame_down = std::chrono::steady_clock::now ();
    }
  else if (event.type == OH_NATIVEXCOMPONENT_MOVE
           && (fx != s.mouse_last_x || fy != s.mouse_last_y))
    {
      SendMouseMotion (s, fx, fy);
      s.mouse_last_col = col;
      s.mouse_last_row = row;
      s.mouse_last_x = fx;
      s.mouse_last_y = fy;
    }
  else if (event.type == OH_NATIVEXCOMPONENT_UP)
    {
      /* A long press must stay a press: synthesising mouse-3 from it fired
         after every drag longer than half a second, so releasing a mode-line
         drag opened the context menu instead of ending the drag.  */
      SendMouse (s, 0, fx, fy, false);
      s.mouse_last_x = fx;
      s.mouse_last_y = fy;
    }
}

void
HandleMouse (Surface &s, OH_NativeXComponent_MouseEvent &event)
{
  int col, row, fx, fy;
  int button = event.button == OH_NATIVEXCOMPONENT_RIGHT_BUTTON    ? 2
               : event.button == OH_NATIVEXCOMPONENT_MIDDLE_BUTTON ? 1
                                                                   : 0;

  if (!PointFromSurface (s, event.x, event.y, fx, fy))
    {
      /* The release may arrive after the pointer crossed into the menu
         bar/other ArkUI chrome.  Emacs still needs the button-up, at the
         last frame pixel where the surface saw the pointer.  */
      if (event.action == OH_NATIVEXCOMPONENT_MOUSE_RELEASE
          && s.mouse_last_x >= 0 && s.mouse_last_y >= 0)
        SendMouse (s, button, s.mouse_last_x, s.mouse_last_y, false);
      return;
    }
  CellFromPoint (s, event.x, event.y, col, row);
  s.mouse_event_at = std::chrono::steady_clock::now ();
  s.mouse_event_col = col;
  s.mouse_event_row = row;

  if (event.action == OH_NATIVEXCOMPONENT_MOUSE_PRESS)
    {
      SendMouse (s, button, fx, fy, true);
      s.mouse_last_col = col;
      s.mouse_last_row = row;
      s.mouse_last_x = fx;
      s.mouse_last_y = fy;
    }
  else if (event.action == OH_NATIVEXCOMPONENT_MOUSE_RELEASE)
    {
      SendMouse (s, button, fx, fy, false);
      s.mouse_last_x = fx;
      s.mouse_last_y = fy;
    }
  else if (event.action == OH_NATIVEXCOMPONENT_MOUSE_MOVE
           && (fx != s.mouse_last_x || fy != s.mouse_last_y))
    {
      /* One motion per frame pixel: the device sends MOVE callbacks at
         input rate even when the pointer stays in the same cell.  */
      SendMouseMotion (s, fx, fy);
      s.mouse_last_col = col;
      s.mouse_last_row = row;
      s.mouse_last_x = fx;
      s.mouse_last_y = fy;
    }
}

bool g_ctrl = false;
bool g_shift = false;
bool g_alt = false;

} // namespace

void
OnTouch (OH_NativeXComponent *component, void *window)
{
  OH_NativeXComponent_TouchEvent event;
  if (OH_NativeXComponent_GetTouchEvent (component, window, &event)
      != OH_NATIVEXCOMPONENT_RESULT_SUCCESS)
    return;
  SurfacePtr s = AcquireSurfaceByComponent (component);
  if (!s || !s->window)
    return;
  HandleTouch (*s, event);
}

void
OnMouse (OH_NativeXComponent *component, void *window)
{
  OH_NativeXComponent_MouseEvent event;
  if (OH_NativeXComponent_GetMouseEvent (component, window, &event)
      != OH_NATIVEXCOMPONENT_RESULT_SUCCESS)
    return;
  SurfacePtr s = AcquireSurfaceByComponent (component);
  if (!s || !s->window)
    return;
  HandleMouse (*s, event);
}

void
SetMenuOpen (int on)
{
  g_menu_open = on ? 1 : 0;
}

int
TakeMenuEsc (void)
{
  return g_menu_esc.exchange (0);
}

void
OnKey (OH_NativeXComponent *component, OH_NativeXComponent_KeyEvent *event)
{
  OH_NativeXComponent_KeyAction action;
  OH_NativeXComponent_KeyCode code;
  if (OH_NativeXComponent_GetKeyEventAction (event, &action) != 0
      || OH_NativeXComponent_GetKeyEventCode (event, &code) != 0)
    return;

  uint64_t modifier_keys = 0;
  bool caps_lock = false;
  bool have_modifiers
      = OH_NativeXComponent_GetKeyEventModifierKeyStates (event, &modifier_keys)
        == 0;
  OH_NativeXComponent_GetKeyEventCapsLockState (event, &caps_lock);
  LOGI ("OHOSDBG onkey code=%{public}u action=%{public}d mods=%{public}llu",
        (unsigned) code, (int) action, (unsigned long long) modifier_keys);

  if (code == KEY_CTRL_LEFT || code == KEY_CTRL_RIGHT)
    {
      g_ctrl = action == OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN;
      return;
    }
  if (code == KEY_SHIFT_LEFT || code == KEY_SHIFT_RIGHT)
    {
      g_shift = action == OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN;
      return;
    }
  if (code == KEY_ALT_LEFT || code == KEY_ALT_RIGHT || code == KEY_META_LEFT
      || code == KEY_META_RIGHT)
    {
      g_alt = action == OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN;
      return;
    }
  if (action != OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN)
    return;
  if (code == KEY_ESCAPE && g_menu_open.load () != 0)
    {
      /* Cancel the open menu instead of feeding Emacs a meta prefix.  */
      g_menu_esc = 1;
      RequestHostWake ();
      LOGI ("key evt esc closes the open menu");
      return;
    }

  SurfacePtr surface = AcquireSurfaceByComponent (component);
  if (!surface)
    return;
  Surface &s = *surface;
  s.metrics.key_events++;
  s.metrics.key_time = std::chrono::steady_clock::now ();
  s.metrics.key_pending_timed = false;
  s.metrics.key_waiting = true;

  unsigned mods = 0;
  if (have_modifiers)
    {
      if (modifier_keys & (1u << 1))
        mods |= 1u; /* shift */
      if (modifier_keys & (1u << 0))
        mods |= 2u; /* ctrl */
      if (modifier_keys & (1u << 2))
        mods |= 4u; /* alt */
    }
  else
    {
      mods = (g_shift ? 1u : 0u) | (g_ctrl ? 2u : 0u) | (g_alt ? 4u : 0u);
    }
  if (caps_lock)
    mods |= 16u;
  ohos_host_input_key (s.frame_id, (unsigned) code, mods, 1);
}

void
OnKeyCallback (OH_NativeXComponent *component, void *window)
{
  OH_NativeXComponent_KeyEvent *event = nullptr;
  if (OH_NativeXComponent_GetKeyEvent (component, &event) == 0 && event)
    OnKey (component, event);
  else
    LOGW ("key callback without event");
}

/* Focus bookkeeping.  ArkUI reports focus on the XComponent itself; the
   input method proxy is only attached while the surface has focus, so
   these two callbacks are what makes IME (and the hardware keyboard)
   reliable after a window switch.  */
void
OnFocusCallback (OH_NativeXComponent *component, void *window)
{
  (void) window;
  SurfacePtr s = AcquireSurfaceByComponent (component);
  LOGI ("xcomponent focus frame=%{public}u", s ? s->frame_id : kBootFrameId);
  ohosgui_focus (s ? s->frame_id : kBootFrameId, 1);
}

void
OnBlurCallback (OH_NativeXComponent *component, void *window)
{
  (void) window;
  SurfacePtr s = AcquireSurfaceByComponent (component);
  LOGI ("xcomponent blur frame=%{public}u", s ? s->frame_id : kBootFrameId);
  ohosgui_focus (s ? s->frame_id : kBootFrameId, 0);
}

napi_value
WriteInput (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  char text[4096] = { 0 };
  size_t len = 0;
  if (argc > 0)
    napi_get_value_string_utf8 (env, argv[0], text, sizeof text, &len);
  int32_t frame_id = (int32_t) kBootFrameId;
  if (argc > 1)
    napi_get_value_int32 (env, argv[1], &frame_id);
  napi_value r;
  napi_create_int32 (env, ohosgui_write_input ((uint32_t) frame_id, text, len),
                     &r);
  return r;
}

/* Mouse wheel.  ArkUI reports an axis event on the UI thread; deliver it
   through the native backend input queue as WHEEL_EVENT instead of an SGR
   keyboard sequence.  */
napi_value
Wheel (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  size_t argc = 5;
  napi_value argv[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
  napi_get_cb_info (env, info, &argc, argv, nullptr, nullptr);
  double delta = 0;
  int32_t col = 0, row = 0, mods = 0;
  int32_t frame_id = (int32_t) kBootFrameId;
  if (argc > 0)
    napi_get_value_double (env, argv[0], &delta);
  if (argc > 1)
    napi_get_value_int32 (env, argv[1], &col);
  if (argc > 2)
    napi_get_value_int32 (env, argv[2], &row);
  if (argc > 3)
    napi_get_value_int32 (env, argv[3], &mods);
  if (argc > 4)
    napi_get_value_int32 (env, argv[4], &frame_id);
  if (delta == 0)
    {
      napi_value zero;
      napi_create_int32 (env, 0, &zero);
      return zero;
    }
  col = std::max (0, (int) col);
  row = std::max (0, (int) row);
  ohosgui_host_input_wheel ((uint32_t) frame_id, delta > 0 ? 1 : -1, (int) col,
                            (int) row, (unsigned) mods);
  LOGI ("wheel delta=%{public}.1f at=%{public}d,%{public}d mods=%{public}d",
        delta, (int) col, (int) row, mods);
  napi_value r;
  napi_create_int32 (env, 1, &r);
  return r;
}

} // namespace ohosgui

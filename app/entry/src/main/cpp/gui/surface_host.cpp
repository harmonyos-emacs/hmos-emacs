#include "surface_host.h"

#include <cstdint>

extern "C" void ohos_host_surface_created (uint32_t, void *, int, int,
                                           uint64_t);
extern "C" void ohos_host_surface_resized (uint32_t, int, int, uint64_t);
extern "C" void ohos_host_surface_destroyed (uint32_t, uint64_t);

#include "gui_context.h"
#define OHOS_LOG_TAG "native.surface"
#include "gui_log.h"
#include "input.h"
#include "ohos_gui.h"
#include "surface.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>

namespace ohosgui
{
namespace
{
/* The UI thread only reports surface geometry.  Emacs owns the final
   frame rect: it consumes the RESIZED event and asks for a pixelwise
   frame resize itself.  Never resize the frame from here.  */

bool
ParseFrameId (const char *component_id, uint32_t *frame_id)
{
  if (!component_id || !frame_id)
    return false;
  if (strcmp (component_id, "emacs_gui") == 0)
    {
      *frame_id = 1;
      return true;
    }
  unsigned parsed = 0;
  if (sscanf (component_id, "emacs_frame_%u", &parsed) == 1 && parsed > 0)
    {
      *frame_id = parsed;
      return true;
    }
  return false;
}

Surface *
SurfaceForComponent (OH_NativeXComponent *component, bool create)
{
  Surface *surface = FindSurfaceByComponent (component);
  if (surface || !create)
    return surface;
  char id[OH_XCOMPONENT_ID_LEN_MAX + 1] = { 0 };
  uint64_t len = OH_XCOMPONENT_ID_LEN_MAX + 1;
  if (OH_NativeXComponent_GetXComponentId (component, id, &len) != 0)
    return nullptr;
  uint32_t frame_id = 0;
  if (!ParseFrameId (id, &frame_id))
    {
      LOGW ("unknown XComponent id=%{public}s", id);
      return nullptr;
    }
  surface = GetOrCreateSurface (frame_id, id);
  BindSurfaceComponent (frame_id, component);
  return surface;
}
} // namespace

void
ConfigureGeometry (Surface &s)
{
  if (s.width <= 0 || s.height <= 0)
    return;
  if (s.frame_w > 0 && s.frame_h > 0)
    {
      s.cell_w = s.cell_w > 0 ? s.cell_w : kFontW;
      s.cell_h = s.cell_h > 0 ? s.cell_h : kNativeLineH;
      s.cols = std::max (2, s.frame_w / s.cell_w);
      s.rows = std::max (2, s.frame_h / s.cell_h);
      return;
    }
  s.cell_w = kFontW;
  s.cell_h = kNativeLineH;
  s.cols = std::max (2, s.width / s.cell_w);
  s.rows = std::max (2, s.height / s.cell_h);
}

void
OnSurfaceCreated (OH_NativeXComponent *component, void *window)
{
  LOGI ("OnSurfaceCreated enter component=%{public}p window=%{public}p",
        component, window);
  Surface *s = SurfaceForComponent (component, true);
  if (!s)
    return;
  s->component = component;
  s->window = window;
  uint64_t width = 0, height = 0;
  OH_NativeXComponent_GetXComponentSize (component, window, &width, &height);
  s->width = (int) width;
  s->height = (int) height;
  s->running = true;
  {
    std::lock_guard<std::recursive_mutex> guard (s->lock);
    ConfigureGeometry (*s);
  }
  ohos_host_surface_created (s->frame_id, window, s->width, s->height,
                             ++s->generation);
  LOGI ("surface ready frame=%{public}u %{public}dx%{public}d gen=%{public}llu",
        s->frame_id, s->width, s->height, (unsigned long long) s->generation);
}

void
OnSurfaceChanged (OH_NativeXComponent *component, void *window)
{
  Surface *s = SurfaceForComponent (component, true);
  if (!s)
    return;
  uint64_t width = 0, height = 0;
  OH_NativeXComponent_GetXComponentSize (component, window, &width, &height);
  if ((int) width == s->width && (int) height == s->height)
    return;
  s->width = (int) width;
  s->height = (int) height;
  {
    std::lock_guard<std::recursive_mutex> guard (s->lock);
    ConfigureGeometry (*s);
  }
  ohos_host_surface_resized (s->frame_id, s->width, s->height, ++s->generation);
}

void
OnSurfaceDestroyed (OH_NativeXComponent *component, void *window)
{
  Surface *s = FindSurfaceByComponent (component);
  if (!s)
    return;
  uint32_t frame_id = s->frame_id;
  ohos_host_surface_destroyed (frame_id, s->generation);
  UnbindSurfaceComponent (frame_id, component);
  LOGI ("surface destroyed frame=%{public}u", frame_id);
  RemoveSurface (frame_id);
}

OH_NativeXComponent_Callback g_callback
    = { OnSurfaceCreated, OnSurfaceChanged, OnSurfaceDestroyed, OnTouch };
OH_NativeXComponent_MouseEvent_Callback g_mouse_callback = { OnMouse, nullptr };

} // namespace

namespace ohosgui
{
extern "C" void
ohos_gui_set_title (uint32_t frame_id, const char *title)
{
  SurfacePtr s = AcquireSurfaceByFrame (frame_id);
  if (!s)
    return;
  {
    std::lock_guard<std::recursive_mutex> guard (s->lock);
    s->title = title ? title : "";
  }
  RequestHostWake ();
}

extern "C" void
ohos_gui_set_clipboard (const char *b64)
{
  SurfacePtr s = AcquireCurrentSurface ();
  if (!s)
    return;
  {
    std::lock_guard<std::recursive_mutex> guard (s->lock);
    s->clipboard_b64 = b64 ? b64 : "";
    s->clipboard_pending = !s->clipboard_b64.empty ();
  }
  RequestHostWake ();
}

void
RegisterXComponent (napi_env env, napi_value exports)
{
  napi_value obj = nullptr;
  if (napi_get_named_property (env, exports, OH_NATIVE_XCOMPONENT_OBJ, &obj)
          != napi_ok
      || !obj)
    return;
  OH_NativeXComponent *component = nullptr;
  if (napi_unwrap (env, obj, reinterpret_cast<void **> (&component)) != napi_ok
      || !component)
    return;

  char cid[OH_XCOMPONENT_ID_LEN_MAX + 1] = { 0 };
  uint64_t cid_size = OH_XCOMPONENT_ID_LEN_MAX + 1;
  OH_NativeXComponent_GetXComponentId (component, cid, &cid_size);
  uint32_t frame_id = 0;
  if (!ParseFrameId (cid, &frame_id))
    {
      LOGW ("XComponent id=%{public}s is not a frame id", cid);
      return;
    }
  GetOrCreateSurface (frame_id, cid);
  BindSurfaceComponent (frame_id, component);
  LOGI (
      "RegisterXComponent id=%{public}s frame=%{public}u component=%{public}p",
      cid, frame_id, component);

  OH_NativeXComponent_RegisterCallback (component, &g_callback);
  OH_NativeXComponent_RegisterMouseEventCallback (component, &g_mouse_callback);
  int32_t keyrc
      = OH_NativeXComponent_RegisterKeyEventCallback (component, OnKeyCallback);
  int32_t focusrc = OH_NativeXComponent_RegisterFocusEventCallback (
      component, OnFocusCallback);
  int32_t blurrc = OH_NativeXComponent_RegisterBlurEventCallback (
      component, OnBlurCallback);
  LOGI ("XComponent registered keyrc=%{public}d focusrc=%{public}d "
        "blurrc=%{public}d",
        keyrc, focusrc, blurrc);
}

void
Stop ()
{
  SurfacePtr s = AcquireCurrentSurface ();
  if (!s)
    return;
  s->running = false;
  std::lock_guard<std::recursive_mutex> guard (s->lock);
}

extern "C" void
ohos_gui_set_frame_metrics (uint32_t frame_id, int width, int height,
                            int cell_w, int cell_h, int ascent, int descent)
{
  LOGI ("OHOSDBG frame-metrics id=%{public}u %{public}dx%{public}d", frame_id,
        width, height);
  (void) ascent;
  (void) descent;
  SurfacePtr s = AcquireSurfaceByFrame (frame_id);
  if (!s || width <= 0 || height <= 0)
    return;
  std::lock_guard<std::recursive_mutex> guard (s->lock);
  s->frame_w = width;
  s->frame_h = height;
  if (cell_w > 0)
    s->cell_w = cell_w;
  if (cell_h > 0)
    s->cell_h = cell_h;
  s->cols = std::max (2, s->frame_w / s->cell_w);
  s->rows = std::max (2, s->frame_h / s->cell_h);
}

} // namespace ohosgui

#include "renderer_internal.h"

#define OHOS_LOG_TAG "native.render"
#include "gui_log.h"

namespace
{
bool
IsStale (const struct ohos_renderer *r, uint64_t generation)
{
  if (generation == 0)
    return false;
  if (r->destroyed_generation != 0 && generation <= r->destroyed_generation)
    return true;
  return r->last_generation != 0 && generation < r->last_generation;
}
} // namespace

extern "C" void
ohos_renderer_apply_surface_event (struct ohos_renderer *r,
                                   const struct OhosSurfaceEvent *event)
{
  if (!r || !event)
    return;

  switch (event->kind)
    {
    case OHOS_SURFACE_CREATED:
      if (!event->window || event->surface_w <= 0 || event->surface_h <= 0)
        return;
      if (r->destroyed_generation != 0
          && event->generation <= r->destroyed_generation)
        {
          LOGI_TAG (OHOS_LOG_TAG_NATIVE_RENDER, "renderer %{public}p drop stale CREATED gen=%{public}llu",
                r, (unsigned long long) event->generation);
          return;
        }
      if (IsStale (r, event->generation))
        return;
      r->window = event->window;
      r->surface_w = event->surface_w;
      r->surface_h = event->surface_h;
      r->surface_generation = event->generation;
      r->last_generation = event->generation;
      r->destroyed_generation = 0;
      r->buffer_configured = false;
      r->surface_state = RenderSurfaceState::PENDING_SURFACE;
      /* A new NativeWindow means any buffer state belonged to the old
         surface.  The bitmap is dropped so begin_frame rebuilds it and
         requests one full redisplay.  */
      renderer_release_backing_store (r);
      r->need_full_repaint = true;
      LOGI_TAG (OHOS_LOG_TAG_NATIVE_RENDER, "renderer %{public}p surface created %{public}dx%{public}d "
            "gen=%{public}llu",
            r, r->surface_w, r->surface_h,
            (unsigned long long) r->surface_generation);
      break;

    case OHOS_SURFACE_RESIZED:
      if (event->surface_w <= 0 || event->surface_h <= 0)
        return;
      if (IsStale (r, event->generation)
          || r->surface_state == RenderSurfaceState::DESTROYED)
        return;
      r->surface_w = event->surface_w;
      r->surface_h = event->surface_h;
      r->surface_generation = event->generation;
      r->last_generation = event->generation;
      r->buffer_configured = false;
      if (r->frame_w > r->surface_w || r->frame_h > r->surface_h)
        r->surface_state = RenderSurfaceState::RESIZING;
      else if (r->bitmap_valid)
        r->surface_state = RenderSurfaceState::READY;
      else
        r->surface_state = RenderSurfaceState::PENDING_SURFACE;
      LOGI_TAG (OHOS_LOG_TAG_NATIVE_RENDER, "renderer %{public}p surface resized %{public}dx%{public}d "
            "gen=%{public}llu",
            r, r->surface_w, r->surface_h,
            (unsigned long long) r->surface_generation);
      break;

    case OHOS_SURFACE_DESTROYED:
      if (IsStale (r, event->generation)
          && r->surface_state == RenderSurfaceState::DESTROYED)
        return;
      r->window = nullptr;
      r->surface_w = 0;
      r->surface_h = 0;
      r->surface_generation = event->generation;
      r->last_generation = event->generation;
      r->destroyed_generation
          = event->generation != 0 ? event->generation : r->last_generation;
      r->buffer_configured = false;
      r->surface_state = RenderSurfaceState::DESTROYED;
      renderer_release_backing_store (r);
      r->need_full_repaint = true;
      LOGI_TAG (OHOS_LOG_TAG_NATIVE_RENDER, "renderer %{public}p surface destroyed gen=%{public}llu",
            r, (unsigned long long) r->surface_generation);
      break;

    default:
      break;
    }
}

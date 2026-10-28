#include "renderer_internal.h"

#define OHOS_LOG_TAG "native.render"
#include "gui_log.h"

#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>

#include <algorithm>
#include <cstring>
#include <unistd.h>

bool
renderer_rebuild_backing_store (struct ohos_renderer *r)
{
  if (!r || r->frame_w <= 0 || r->frame_h <= 0)
    return false;

  renderer_release_backing_store (r);

  OH_Drawing_BitmapFormat format
      = { COLOR_FORMAT_RGBA_8888, ALPHA_FORMAT_OPAQUE };
  OH_Drawing_Bitmap *bitmap = OH_Drawing_BitmapCreate ();
  if (!bitmap)
    return false;
  OH_Drawing_BitmapBuild (bitmap, (uint32_t) r->frame_w,
                          (uint32_t) r->frame_h, &format);
  OH_Drawing_Canvas *canvas = OH_Drawing_CanvasCreate ();
  if (!canvas)
    {
      OH_Drawing_BitmapDestroy (bitmap);
      return false;
    }
  OH_Drawing_CanvasBind (canvas, bitmap);
  OH_Drawing_CanvasClear (canvas, renderer_argb (r->background));

  r->bitmap = bitmap;
  r->canvas = canvas;
  r->bitmap_w = r->frame_w;
  r->bitmap_h = r->frame_h;
  r->bitmap_valid = true;
  r->buffer_configured = false;
  r->need_full_repaint = true;
  r->frame_has_draw = false;
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_RENDER, "renderer %{public}p backing store %{public}dx%{public}d",
        r, r->bitmap_w, r->bitmap_h);
  return true;
}

int
renderer_present_native (struct ohos_renderer *r)
{
  if (!r || !r->window || !r->bitmap_valid || !r->bitmap || !r->canvas
      || r->surface_w <= 0 || r->surface_h <= 0)
    return 0;

  OHNativeWindow *window = (OHNativeWindow *) r->window;
  if (!r->buffer_configured)
    {
      OH_NativeWindow_NativeWindowHandleOpt (window, SET_BUFFER_GEOMETRY,
                                             r->surface_w, r->surface_h);
      int32_t interval = 1;
      OH_NativeWindow_NativeWindowHandleOpt (window, SET_SWAP_INTERVAL,
                                             interval);
      r->buffer_configured = true;
    }

  OHNativeWindowBuffer *buffer = nullptr;
  int fence = -1;
  int ret = OH_NativeWindow_NativeWindowRequestBuffer (window, &buffer, &fence);
  if (fence >= 0)
    close (fence);
  if (ret != 0 || !buffer)
    {
      LOGW ("renderer %{public}p request buffer failed ret=%{public}d",
            r, ret);
      return 0;
    }

  BufferHandle *handle = OH_NativeWindow_GetBufferHandleFromNative (buffer);
  OH_NativeBuffer *native_buffer = nullptr;
  OH_NativeBuffer_Config config = {};
  if (OH_NativeBuffer_FromNativeWindowBuffer (buffer, &native_buffer) == 0
      && native_buffer)
    {
      OH_NativeBuffer_GetConfig (native_buffer, &config);
    }

  void *mapped = nullptr;
  if (native_buffer)
    OH_NativeBuffer_Map (native_buffer, &mapped);
  void *pixels = mapped ? mapped : (handle ? handle->virAddr : nullptr);
  if (!pixels)
    {
      if (native_buffer)
        OH_NativeBuffer_Unmap (native_buffer);
      OH_NativeWindow_NativeWindowAbortBuffer (window, buffer);
      LOGW ("renderer %{public}p no buffer pixels", r);
      return 0;
    }

  int bw = config.width > 0 ? config.width : r->surface_w;
  int bh = config.height > 0 ? config.height : r->surface_h;
  int dst_stride
      = config.stride > 0
            ? config.stride
            : (handle && handle->stride > 0 ? handle->stride : bw * 4);
  if (dst_stride < bw * 4)
    dst_stride = bw * 4;

  uint8_t *dst = (uint8_t *) pixels;
  uint32_t bg = renderer_argb (r->background);
  for (int y = 0; y < bh; y++)
    {
      uint32_t *row = (uint32_t *) (dst + y * dst_stride);
      for (int x = 0; x < bw; x++)
        row[x] = bg;
    }

  const uint8_t *src = (const uint8_t *) OH_Drawing_BitmapGetPixels (r->bitmap);
  int copy_w = std::min (r->bitmap_w, bw);
  int copy_h = std::min (r->bitmap_h, bh);
  if (src)
    for (int y = 0; y < copy_h; y++)
      memcpy (dst + y * dst_stride, src + y * r->bitmap_w * 4,
              copy_w * 4);

  Region region = {};
  Region::Rect rect = { 0, 0, (uint32_t) bw, (uint32_t) bh };
  region.rects = &rect;
  region.rectNumber = 1;
  if (native_buffer)
    OH_NativeBuffer_Unmap (native_buffer);
  ret = OH_NativeWindow_NativeWindowFlushBuffer (window, buffer, -1, region);
  if (ret != 0)
    {
      OH_NativeWindow_NativeWindowAbortBuffer (window, buffer);
      LOGW ("renderer %{public}p flush failed ret=%{public}d", r, ret);
      return 0;
    }

  LOGD_TAG (OHOS_LOG_TAG_NATIVE_RENDER, "renderer %{public}p present content=%{public}dx%{public}d "
        "buffer=%{public}dx%{public}d gen=%{public}llu",
        r, copy_w, copy_h, bw, bh,
        (unsigned long long) r->surface_generation);
  return 1;
}

extern "C" int
ohos_renderer_present (struct ohos_renderer *r)
{
  if (!r)
    return 0;
  renderer_flush_text_run (r);

  if (r->surface_state != RenderSurfaceState::READY)
    return 0;
  if (!r->frame_complete)
    /* Nothing new to commit.  This is not a failure: flush_display and
       frame_up_to_date may both ask for a present in the same pass.  */
    return OHOS_RENDER_PRESENTED;

  if (!r->frame_has_draw)
    {
      r->frame_complete = false;
      r->frame_state = RenderFrameState::IDLE;
      return OHOS_RENDER_PRESENTED;
    }

  if (!renderer_present_native (r))
    {
      /* Keep the complete frame so the next present can retry, and keep
         the backing store for the same reason.  The caller requests a
         redisplay.  */
      return 0;
    }

  r->frame_has_draw = false;
  r->frame_complete = false;
  r->frame_state = RenderFrameState::IDLE;

  int result = OHOS_RENDER_PRESENTED;
  if (r->need_full_repaint)
    {
      r->need_full_repaint = false;
      result |= OHOS_RENDER_FULL_REPAINT;
      LOGD_TAG (OHOS_LOG_TAG_NATIVE_RENDER, "renderer %{public}p request full repaint", r);
    }
  return result;
}

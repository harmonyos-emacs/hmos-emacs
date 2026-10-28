/* Shared state of one per-frame renderer context.

   This header is private to the renderer sources.  The public C ABI lives in
   emacs/src/ohos_render.h and deliberately exposes no OH_Drawing or
   NativeWindow type.  */

#ifndef OHOS_RENDERER_INTERNAL_H
#define OHOS_RENDERER_INTERNAL_H

#include "ohos_render.h"

#include <native_drawing/drawing_bitmap.h>
#include <native_drawing/drawing_brush.h>
#include <native_drawing/drawing_canvas.h>
#include <native_drawing/drawing_font.h>
#include <native_drawing/drawing_text_blob.h>
#include <native_drawing/drawing_typeface.h>

#include <cstdint>
#include <unordered_map>

enum class RenderSurfaceState
{
  EMPTY,
  PENDING_SURFACE,
  READY,
  RESIZING,
  DESTROYED
};

enum class RenderFrameState
{
  IDLE,
  ACTIVE,
  COMPLETE
};

struct RendererFontCache
{
  OH_Drawing_Font *mono = nullptr;
  OH_Drawing_Font *cjk = nullptr;
  OH_Drawing_Typeface *mono_typeface = nullptr;
  OH_Drawing_Typeface *cjk_typeface = nullptr;
  OH_Drawing_Brush *brush = nullptr;
  std::unordered_map<uint64_t, OH_Drawing_TextBlob *> blobs;
};

/* Redisplay emits long runs of adjacent cells with identical face.  Keep
   one run per context and flush it on the next non-text op or at
   end_frame: this preserves the batching the old command protocol got
   for free without reintroducing a command queue.  */
struct RendererTextRun
{
  bool active = false;
  int x = 0;
  int y = 0;
  int h = 0;
  int total_w = 0;
  uint32_t fg = 0;
  uint32_t bg = 0;
  uint32_t flags = 0;
  bool wide = false;
  int count = 0;
  unsigned codes[128];
  int widths[128];
};

struct ohos_renderer
{
  /* Surface.  Owned by the UI thread, only read here.  */
  void *window = nullptr;
  int surface_w = 0;
  int surface_h = 0;
  uint64_t surface_generation = 0;
  uint64_t last_generation = 0;
  uint64_t destroyed_generation = 0;
  RenderSurfaceState surface_state = RenderSurfaceState::EMPTY;
  bool buffer_configured = false;

  /* Content geometry, from the Emacs frame.  */
  int frame_w = 0;
  int frame_h = 0;
  int cell_w = 0;
  int cell_h = 0;

  /* Backing store.  Bitmap is frame_w x frame_h; the surface buffer is
     surface_w x surface_h and receives the bitmap at (0, 0) plus opaque
     padding.  */
  OH_Drawing_Bitmap *bitmap = nullptr;
  OH_Drawing_Canvas *canvas = nullptr;
  int bitmap_w = 0;
  int bitmap_h = 0;
  bool bitmap_valid = false;

  /* Frame transaction.  */
  RenderFrameState frame_state = RenderFrameState::IDLE;
  bool frame_complete = false;
  bool frame_has_draw = false;
  bool need_full_repaint = false;
  uint32_t background = 0xffffffffu;

  RendererFontCache fonts;
  RendererTextRun text_run;
};

/* renderer.cpp */
uint32_t renderer_argb (uint32_t rgb);
bool renderer_can_draw (const struct ohos_renderer *r);
void renderer_release_backing_store (struct ohos_renderer *r);
void renderer_release_fonts (struct ohos_renderer *r);
bool renderer_init_fonts (struct ohos_renderer *r);
OH_Drawing_TextBlob *renderer_text_blob (struct ohos_renderer *r,
                                         uint32_t code, uint32_t flags,
                                         int height, bool wide);
void renderer_flush_text_run (struct ohos_renderer *r);

/* present.cpp */
bool renderer_rebuild_backing_store (struct ohos_renderer *r);
int renderer_present_native (struct ohos_renderer *r);

#endif /* OHOS_RENDERER_INTERNAL_H */

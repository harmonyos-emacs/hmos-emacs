#include "renderer_internal.h"

#define OHOS_LOG_TAG "native.render"
#include "gui_log.h"

#include <native_drawing/drawing_font_mgr.h>
#include <native_drawing/drawing_rect.h>
#include <native_drawing/drawing_typeface.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>

namespace
{
bool
IsWideCode (unsigned code)
{
  return (code >= 0x1100 && code <= 0x115f)
         || (code >= 0x2e80 && code <= 0xa4cf)
         || (code >= 0xac00 && code <= 0xd7a3)
         || (code >= 0xf900 && code <= 0xfaff)
         || (code >= 0xfe30 && code <= 0xfe4f)
         || (code >= 0xff00 && code <= 0xff60)
         || (code >= 0xffe0 && code <= 0xffe6)
         || (code >= 0x1f300 && code <= 0x1faff)
         || (code >= 0x20000 && code <= 0x3fffd);
}

int
Utf8Encode (unsigned code, char *out)
{
  if (code < 0x80)
    {
      out[0] = (char) code;
      return 1;
    }
  if (code < 0x800)
    {
      out[0] = (char) (0xc0 | (code >> 6));
      out[1] = (char) (0x80 | (code & 0x3f));
      return 2;
    }
  if (code < 0x10000)
    {
      out[0] = (char) (0xe0 | (code >> 12));
      out[1] = (char) (0x80 | ((code >> 6) & 0x3f));
      out[2] = (char) (0x80 | (code & 0x3f));
      return 3;
    }
  out[0] = (char) (0xf0 | (code >> 18));
  out[1] = (char) (0x80 | ((code >> 12) & 0x3f));
  out[2] = (char) (0x80 | ((code >> 6) & 0x3f));
  out[3] = (char) (0x80 | (code & 0x3f));
  return 4;
}
} // namespace

uint32_t
renderer_argb (uint32_t rgb)
{
  return 0xff000000u | (rgb & 0xffffffu);
}

bool
renderer_can_draw (const struct ohos_renderer *r)
{
  return r && r->canvas && r->bitmap_valid
         && r->frame_state == RenderFrameState::ACTIVE
         && r->surface_state == RenderSurfaceState::READY;
}

void
renderer_release_backing_store (struct ohos_renderer *r)
{
  if (!r)
    return;
  if (r->canvas)
    OH_Drawing_CanvasDestroy (r->canvas);
  if (r->bitmap)
    OH_Drawing_BitmapDestroy (r->bitmap);
  r->canvas = nullptr;
  r->bitmap = nullptr;
  r->bitmap_w = 0;
  r->bitmap_h = 0;
  r->bitmap_valid = false;
}

void
renderer_release_fonts (struct ohos_renderer *r)
{
  if (!r)
    return;
  for (auto &entry : r->fonts.blobs)
    if (entry.second)
      OH_Drawing_TextBlobDestroy (entry.second);
  r->fonts.blobs.clear ();
  if (r->fonts.brush)
    OH_Drawing_BrushDestroy (r->fonts.brush);
  if (r->fonts.mono)
    OH_Drawing_FontDestroy (r->fonts.mono);
  if (r->fonts.cjk)
    OH_Drawing_FontDestroy (r->fonts.cjk);
  if (r->fonts.mono_typeface)
    OH_Drawing_TypefaceDestroy (r->fonts.mono_typeface);
  if (r->fonts.cjk_typeface)
    OH_Drawing_TypefaceDestroy (r->fonts.cjk_typeface);
  r->fonts = RendererFontCache ();
}

bool
renderer_init_fonts (struct ohos_renderer *r)
{
  if (!r)
    return false;
  if (r->fonts.mono && r->fonts.cjk && r->fonts.brush)
    return true;

  r->fonts.mono = OH_Drawing_FontCreate ();
  r->fonts.cjk = OH_Drawing_FontCreate ();
  r->fonts.brush = OH_Drawing_BrushCreate ();
  if (!r->fonts.mono || !r->fonts.cjk || !r->fonts.brush)
    {
      renderer_release_fonts (r);
      return false;
    }

  OH_Drawing_FontStyleStruct style
      = { FONT_WEIGHT_400, FONT_WIDTH_NORMAL, FONT_STYLE_NORMAL };
  OH_Drawing_FontMgr *mgr = OH_Drawing_FontMgrCreate ();
  OH_Drawing_Typeface *mono
      = mgr ? OH_Drawing_FontMgrMatchFamilyStyle (mgr, "monospace", style)
            : nullptr;
  if (!mono)
    mono = OH_Drawing_TypefaceCreateDefault ();
  if (mgr)
    OH_Drawing_FontMgrDestroy (mgr);
  r->fonts.mono_typeface = mono;
  if (mono)
    OH_Drawing_FontSetTypeface (r->fonts.mono, mono);

  r->fonts.cjk_typeface = OH_Drawing_TypefaceCreateFromFile (
      "/system/fonts/HarmonyOS_Sans_SC.ttf", 0);
  if (r->fonts.cjk_typeface)
    OH_Drawing_FontSetTypeface (r->fonts.cjk, r->fonts.cjk_typeface);
  else if (mono)
    OH_Drawing_FontSetTypeface (r->fonts.cjk, mono);
  return true;
}

OH_Drawing_TextBlob *
renderer_text_blob (struct ohos_renderer *r, uint32_t code, uint32_t flags,
                    int height, bool wide)
{
  if (!r)
    return nullptr;
  OH_Drawing_Font *font = wide ? r->fonts.cjk : r->fonts.mono;
  if (!font)
    return nullptr;

  uint64_t key = (uint64_t) code | ((uint64_t) (flags & 2) << 21)
                 | ((uint64_t) (wide ? 1 : 0) << 22)
                 | ((uint64_t) (unsigned) height << 23);
  auto it = r->fonts.blobs.find (key);
  if (it != r->fonts.blobs.end ())
    return it->second;

  float size = wide ? (float) height : 15.5f * (float) height / 18.0f;
  OH_Drawing_FontSetTextSize (font, size);
  OH_Drawing_FontSetFakeBoldText (font, (flags & 2) != 0);
  char utf8[8];
  int len = Utf8Encode (code, utf8);
  utf8[len] = 0;
  OH_Drawing_TextBlob *blob
      = OH_Drawing_TextBlobCreateFromString (utf8, font, TEXT_ENCODING_UTF8);
  if (!blob)
    return nullptr;
  if (r->fonts.blobs.size () < 8192)
    r->fonts.blobs.emplace (key, blob);
  else
    {
      /* The cache is bounded; do not leak the blob just because it did
         not fit.  */
      OH_Drawing_TextBlobDestroy (blob);
      return nullptr;
    }
  return blob;
}

namespace
{
void
FillRect (struct ohos_renderer *r, int x, int y, int w, int h, uint32_t rgb)
{
  if (!renderer_can_draw (r) || w <= 0 || h <= 0)
    return;
  OH_Drawing_Rect *rect = OH_Drawing_RectCreate ((float) x, (float) y,
                                                 (float) (x + w),
                                                 (float) (y + h));
  if (!rect)
    return;
  OH_Drawing_BrushSetColor (r->fonts.brush, renderer_argb (rgb));
  OH_Drawing_CanvasAttachBrush (r->canvas, r->fonts.brush);
  OH_Drawing_CanvasDrawRect (r->canvas, rect);
  OH_Drawing_CanvasDetachBrush (r->canvas);
  OH_Drawing_RectDestroy (rect);
}

int
BaselineFor (int height)
{
  return std::max (1, (int) ((float) height * 0.78f));
}
} // namespace

void
renderer_flush_text_run (struct ohos_renderer *r)
{
  if (!r)
    return;
  RendererTextRun &run = r->text_run;
  if (!run.active)
    return;
  if (!renderer_can_draw (r))
    {
      run.active = false;
      run.count = 0;
      return;
    }

  if (run.flags & 1)
    FillRect (r, run.x, run.y, run.total_w, run.h, run.bg);

  OH_Drawing_Font *font = run.wide ? r->fonts.cjk : r->fonts.mono;
  if (font && run.h > 0)
    {
      float size = run.wide ? (float) run.h
                            : 15.5f * (float) run.h / 18.0f;
      OH_Drawing_FontSetTextSize (font, size);
      OH_Drawing_FontSetFakeBoldText (font, (run.flags & 2) != 0);
      OH_Drawing_BrushSetColor (r->fonts.brush, renderer_argb (run.fg));
      OH_Drawing_CanvasAttachBrush (r->canvas, r->fonts.brush);
      int baseline = BaselineFor (run.h);
      int pen_x = run.x;
      for (int i = 0; i < run.count; i++)
        {
          OH_Drawing_TextBlob *blob
              = renderer_text_blob (r, run.codes[i], run.flags, run.h,
                                    run.wide);
          if (blob)
            OH_Drawing_CanvasDrawTextBlob (r->canvas, blob, (float) pen_x,
                                           (float) (run.y + baseline));
          pen_x += run.widths[i];
        }
      OH_Drawing_CanvasDetachBrush (r->canvas);
      OH_Drawing_FontSetFakeBoldText (font, false);
    }

  int line_h = 1;
  if (run.flags & 4)
    FillRect (r, run.x, run.y + run.h - 2, run.total_w, line_h, run.fg);
  if (run.flags & 8)
    FillRect (r, run.x, run.y + run.h / 2, run.total_w, line_h, run.fg);
  if (run.flags & 16)
    FillRect (r, run.x, run.y, run.total_w, line_h, run.fg);

  run.active = false;
  run.count = 0;
  run.total_w = 0;
}

extern "C" struct ohos_renderer *
ohos_renderer_create (void)
{
  struct ohos_renderer *r = new (std::nothrow) ohos_renderer ();
  if (!r)
    return nullptr;
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_RENDER, "renderer create %{public}p", r);
  return r;
}

extern "C" void
ohos_renderer_destroy (struct ohos_renderer *r)
{
  if (!r)
    return;
  LOGI_TAG (OHOS_LOG_TAG_NATIVE_RENDER, "renderer destroy %{public}p", r);
  renderer_release_backing_store (r);
  renderer_release_fonts (r);
  delete r;
}

extern "C" void
ohos_renderer_set_frame_size (struct ohos_renderer *r, int frame_w,
                              int frame_h, int cell_w, int cell_h)
{
  if (!r || frame_w <= 0 || frame_h <= 0)
    return;
  if (frame_w == r->frame_w && frame_h == r->frame_h
      && cell_w == r->cell_w && cell_h == r->cell_h)
    return;
  r->frame_w = frame_w;
  r->frame_h = frame_h;
  if (cell_w > 0)
    r->cell_w = cell_w;
  if (cell_h > 0)
    r->cell_h = cell_h;
  /* The next begin_frame decides whether the backing store has to be
     rebuilt; resize itself never touches the bitmap.  */
  if (r->bitmap_valid
      && (r->bitmap_w != frame_w || r->bitmap_h != frame_h))
    r->surface_state = RenderSurfaceState::RESIZING;
}

extern "C" int
ohos_renderer_begin_frame (struct ohos_renderer *r)
{
  if (!r)
    return 0;
  renderer_flush_text_run (r);
  r->frame_state = RenderFrameState::IDLE;
  r->frame_complete = false;

  if (!r->window || r->surface_state == RenderSurfaceState::EMPTY
      || r->surface_state == RenderSurfaceState::DESTROYED)
    return 0;
  if (r->frame_w <= 0 || r->frame_h <= 0)
    return 0;
  if (r->surface_w > 0 && r->surface_h > 0
      && (r->frame_w > r->surface_w || r->frame_h > r->surface_h))
    {
      r->surface_state = RenderSurfaceState::RESIZING;
      LOGW ("renderer %{public}p frame %{public}dx%{public}d "
            "exceeds surface %{public}dx%{public}d",
            r, r->frame_w, r->frame_h, r->surface_w, r->surface_h);
      return 0;
    }

  if (!r->bitmap_valid || r->bitmap_w != r->frame_w
      || r->bitmap_h != r->frame_h)
    {
      if (!renderer_rebuild_backing_store (r))
        return 0;
    }
  if (!renderer_init_fonts (r))
    return 0;

  r->surface_state = RenderSurfaceState::READY;
  r->frame_state = RenderFrameState::ACTIVE;
  return 1;
}

extern "C" void
ohos_renderer_clear (struct ohos_renderer *r, uint32_t bg)
{
  if (!r)
    return;
  renderer_flush_text_run (r);
  r->background = bg;
  if (!renderer_can_draw (r))
    return;
  OH_Drawing_CanvasClear (r->canvas, renderer_argb (bg));
  r->frame_has_draw = true;
}

extern "C" void
ohos_renderer_fill (struct ohos_renderer *r, int x, int y, int w, int h,
                    uint32_t color)
{
  if (!r)
    return;
  renderer_flush_text_run (r);
  FillRect (r, x, y, w, h, color);
  if (w > 0 && h > 0)
    r->frame_has_draw = true;
}

extern "C" void
ohos_renderer_text (struct ohos_renderer *r, int x, int y, int w, int h,
                    unsigned code, uint32_t fg, uint32_t bg, uint32_t flags)
{
  if (!r || !renderer_can_draw (r) || w <= 0 || h <= 0)
    return;
  bool wide = IsWideCode (code);
  RendererTextRun &run = r->text_run;
  bool compatible
      = run.active && run.count < (int) (sizeof run.codes / sizeof run.codes[0])
        && run.y == y && run.h == h && run.fg == fg && run.bg == bg
        && run.flags == flags && run.wide == wide && run.x + run.total_w == x;
  if (!compatible)
    {
      renderer_flush_text_run (r);
      run.active = true;
      run.x = x;
      run.y = y;
      run.h = h;
      run.total_w = 0;
      run.fg = fg;
      run.bg = bg;
      run.flags = flags;
      run.wide = wide;
      run.count = 0;
    }
  run.codes[run.count] = code;
  run.widths[run.count] = w;
  run.count++;
  run.total_w += w;
  r->frame_has_draw = true;
}

extern "C" void
ohos_renderer_cursor (struct ohos_renderer *r, int x, int y, int w, int h,
                      int bar, uint32_t fg, uint32_t bg, uint32_t flags)
{
  if (!r)
    return;
  renderer_flush_text_run (r);
  (void) bg;
  (void) flags;
  if (bar > 0)
    FillRect (r, x, y, bar, h, fg);
  else
    FillRect (r, x, y, w, h, fg);
  if (w > 0 && h > 0)
    r->frame_has_draw = true;
}

extern "C" void
ohos_renderer_image (struct ohos_renderer *r, int x, int y, int w, int h,
                     const void *rgba, unsigned len)
{
  if (!r || !rgba || w <= 0 || h <= 0
      || len < (unsigned) (w * h * 4))
    return;
  renderer_flush_text_run (r);
  if (!renderer_can_draw (r))
    return;
  OH_Drawing_Bitmap *bitmap = OH_Drawing_BitmapCreate ();
  if (!bitmap)
    return;
  OH_Drawing_BitmapFormat format
      = { COLOR_FORMAT_RGBA_8888, ALPHA_FORMAT_OPAQUE };
  OH_Drawing_BitmapBuild (bitmap, (uint32_t) w, (uint32_t) h, &format);
  void *pixels = OH_Drawing_BitmapGetPixels (bitmap);
  if (pixels)
    memcpy (pixels, rgba, (size_t) w * h * 4);
  OH_Drawing_CanvasDrawBitmap (r->canvas, bitmap, (float) x, (float) y);
  OH_Drawing_BitmapDestroy (bitmap);
  r->frame_has_draw = true;
}

extern "C" void
ohos_renderer_scroll (struct ohos_renderer *r, int x, int from_y, int w,
                      int h, int to_y)
{
  if (!r)
    return;
  renderer_flush_text_run (r);
  if (!renderer_can_draw (r) || w <= 0 || h <= 0 || from_y == to_y)
    return;
  uint8_t *pixels = (uint8_t *) OH_Drawing_BitmapGetPixels (r->bitmap);
  if (!pixels)
    return;
  int x0 = std::max (0, x);
  int x1 = std::min (r->bitmap_w, x + w);
  if (x1 <= x0 || from_y < 0 || to_y < 0 || from_y + h > r->bitmap_h
      || to_y + h > r->bitmap_h)
    return;
  int stride = r->bitmap_w * 4;
  int bytes = (x1 - x0) * 4;
  if (to_y < from_y)
    for (int row = 0; row < h; row++)
      memmove (pixels + (to_y + row) * stride + x0 * 4,
               pixels + (from_y + row) * stride + x0 * 4, bytes);
  else
    for (int row = h - 1; row >= 0; row--)
      memmove (pixels + (to_y + row) * stride + x0 * 4,
               pixels + (from_y + row) * stride + x0 * 4, bytes);
  r->frame_has_draw = true;
}

extern "C" void
ohos_renderer_push_clip (struct ohos_renderer *r, int x, int y, int w, int h)
{
  if (!r || !r->canvas || w <= 0 || h <= 0)
    return;
  renderer_flush_text_run (r);
  OH_Drawing_CanvasSave (r->canvas);
  OH_Drawing_Rect *rect = OH_Drawing_RectCreate ((float) x, (float) y,
                                                 (float) (x + w),
                                                 (float) (y + h));
  if (rect)
    {
      OH_Drawing_CanvasClipRect (r->canvas, rect,
                                 INTERSECT, false);
      OH_Drawing_RectDestroy (rect);
    }
}

extern "C" void
ohos_renderer_pop_clip (struct ohos_renderer *r)
{
  if (!r || !r->canvas)
    return;
  /* Flush while the clip is still active, then restore the canvas.  */
  renderer_flush_text_run (r);
  OH_Drawing_CanvasRestore (r->canvas);
}

extern "C" void
ohos_renderer_end_frame (struct ohos_renderer *r)
{
  if (!r)
    return;
  renderer_flush_text_run (r);
  if (r->frame_state == RenderFrameState::ACTIVE)
    {
      r->frame_state = RenderFrameState::COMPLETE;
      r->frame_complete = true;
    }
}

extern "C" int
ohos_renderer_frame_active (const struct ohos_renderer *r)
{
  return r && r->frame_state == RenderFrameState::ACTIVE;
}

extern "C" int
ohos_renderer_ready (const struct ohos_renderer *r)
{
  return r && r->bitmap_valid && r->surface_state == RenderSurfaceState::READY
         && r->window;
}

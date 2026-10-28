#include "ohos_gui.h"

#define OHOS_LOG_TAG "native.gui"
#include "gui_log.h"
#include "surface_host.h"
#include "surface.h"
#include "ohos_host_abi.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace ohosgui
{
namespace
{
std::string
Base64Decode (const std::string &in)
{
  static const signed char table[256] = {
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, 62, -1, -1, -1, 63, 52, 53, 54, 55, 56, 57, 58, 59, 60,
    61, -1, -1, -1, -1, -1, -1, -1, 0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10,
    11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1, -1,
    -1, -1, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42,
    43, 44, 45, 46, 47, 48, 49, 50, 51, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1
  };
  std::string out;
  int val = 0, valb = -8;
  for (unsigned char c : in)
    {
      if (c == '=')
        break;
      if (table[c] < 0)
        continue;
      val = (val << 6) + table[c];
      valb += 6;
      if (valb >= 0)
        {
          out.push_back (char ((val >> valb) & 0xff));
          valb -= 8;
        }
    }
  return out;
}

double
P95 (const std::vector<double> &values)
{
  if (values.empty ())
    return 0;
  std::vector<double> v = values;
  std::sort (v.begin (), v.end ());
  return v[(size_t) (v.size () * 0.95)];
}
} // namespace

napi_value
Status (napi_env env, napi_callback_info info)
{
  char buf[1024];
  SurfacePtr s = AcquireCurrentSurface ();
  if (!s)
    {
      napi_value r;
      napi_create_string_utf8 (env, "{}", 2, &r);
      return r;
    }
  std::lock_guard<std::recursive_mutex> guard (s->lock);
  snprintf (
      buf, sizeof buf,
      "{\"abi\":%d,\"surface\":%s,\"cols\":%d,\"rows\":%d,"
      "\"textCols\":%d,\"textRows\":%d,\"surfaceSized\":%s,"
      "\"width\":%d,\"height\":%d,\"fps\":%.1f,"
      "\"presentFps\":%.1f,\"presents\":%llu,\"keyP95Ms\":%.1f,"
      "\"glyphs\":%lu,\"keys\":%lu,\"drawP95Ms\":%.1f,\"beginP95Ms\":%.1f,"
      "\"renderP95Ms\":%.1f,\"flushP95Ms\":%.1f,\"blitP95Ms\":%.1f,"
      "\"directPresents\":%llu,\"fullCopies\":%llu,"
      "\"partialCopies\":%llu,\"rowsCopied\":%llu,"
      "\"fallbacks\":%llu,\"title\":\"%s\"}",
      OHOS_GUI_ABI_VERSION, s->window ? "true" : "false", s->cols, s->rows,
      s->cols, s->rows, s->frame_w > 0 ? "true" : "false", s->width, s->height,
      s->metrics.fps, s->metrics.present_fps,
      (unsigned long long) s->metrics.presents, P95 (s->metrics.key_latencies),
      s->metrics.glyph_cmds, s->metrics.key_events, P95 (s->metrics.draw_ms),
      P95 (s->metrics.begin_ms), P95 (s->metrics.render_ms),
      P95 (s->metrics.flush_ms), P95 (s->metrics.blit_ms),
      (unsigned long long) 0ULL, (unsigned long long) 0ULL,
      (unsigned long long) 0ULL, (unsigned long long) 0ULL, s->title.c_str ());
  napi_value r;
  napi_create_string_utf8 (env, buf, NAPI_AUTO_LENGTH, &r);
  return r;
}

napi_value
GetState (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  return Status (env, info);
}

napi_value
Detach (napi_env env, napi_callback_info info)
{
  (void) env;
  (void) info;
  Stop ();
  napi_value r;
  napi_create_int32 (env, 0, &r);
  return r;
}

napi_value
GetTitle (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  SurfacePtr s = AcquireCurrentSurface ();
  std::string title;
  if (s)
    {
      std::lock_guard<std::recursive_mutex> guard (s->lock);
      title = s->title;
    }
  napi_value r;
  napi_create_string_utf8 (env, title.c_str (), title.size (), &r);
  return r;
}

napi_value
TakeClipboard (napi_env env, napi_callback_info info)
{
  OHOS_NAPI_ENTER ();
  (void) info;
  SurfacePtr s = AcquireCurrentSurface ();
  std::string b64;
  if (s)
    {
      std::lock_guard<std::recursive_mutex> guard (s->lock);
      if (s->clipboard_pending)
        {
          b64 = s->clipboard_b64;
          s->clipboard_pending = false;
        }
    }
  std::string text = Base64Decode (b64);
  napi_value r;
  napi_create_string_utf8 (env, text.c_str (), text.size (), &r);
  return r;
}

} // namespace ohosgui

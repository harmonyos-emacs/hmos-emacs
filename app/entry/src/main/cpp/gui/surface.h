#ifndef OHOS_GUI_SURFACE_H
#define OHOS_GUI_SURFACE_H

#include "gui_types.h"
#include "metrics.h"

#include <ace/xcomponent/native_interface_xcomponent.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

namespace ohosgui
{
constexpr int kNativeLineH = kDefaultCellHeight;

/* UI-side window state only.  Drawing, Bitmap, canvas and NativeWindow
   buffers are owned by the statically linked renderer on the Emacs thread. */
struct Surface
{
  uint32_t frame_id = 0;
  std::string component_id;
  uint64_t generation = 0;
  void *window = nullptr;
  OH_NativeXComponent *component = nullptr;
  int width = 0;
  int height = 0;
  std::recursive_mutex lock;
  bool running = false;

  int frame_w = 0;
  int frame_h = 0;
  int cell_w = kFontW;
  int cell_h = kNativeLineH;
  int cols = 0;
  int rows = 0;

  std::string title;
  std::string clipboard_b64;
  bool clipboard_pending = false;

  std::chrono::steady_clock::time_point mouse_event_at{};
  int mouse_event_col = -1;
  int mouse_event_row = -1;
  int mouse_last_col = -1;
  int mouse_last_row = -1;
  int mouse_last_x = -1;
  int mouse_last_y = -1;

  Metrics metrics;
};

/* frame_id / component id registry.  All functions are thread-safe.  */
using SurfacePtr = std::shared_ptr<Surface>;

Surface *GetOrCreateSurface (uint32_t frame_id,
                             const std::string &component_id);
Surface *FindSurfaceByFrame (uint32_t frame_id);
Surface *FindSurfaceByComponent (OH_NativeXComponent *component);
SurfacePtr AcquireSurfaceByFrame (uint32_t frame_id);
SurfacePtr AcquireSurfaceByComponent (OH_NativeXComponent *component);
SurfacePtr AcquireCurrentSurface (void);
void BindSurfaceComponent (uint32_t frame_id, OH_NativeXComponent *component);
void UnbindSurfaceComponent (uint32_t frame_id, OH_NativeXComponent *component);
void RemoveSurface (uint32_t frame_id);

/* Boot-frame compatibility for the single-window status/title paths.  */
Surface &CurrentSurface (void);
} // namespace ohosgui

#endif

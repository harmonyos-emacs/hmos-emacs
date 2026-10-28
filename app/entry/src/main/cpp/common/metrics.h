#ifndef OHOS_GUI_METRICS_H
#define OHOS_GUI_METRICS_H

#include <chrono>
#include <cstdint>
#include <vector>

namespace ohosgui
{
/* UI-thread performance counters.  Kept out of Surface so that present,
   renderer and status code can share them without owning GUI resources.  */
struct Metrics
{
  double fps = 0;
  double present_fps = 0;
  std::vector<double> key_latencies;
  std::chrono::steady_clock::time_point key_time;
  bool key_waiting = false;
  bool key_render_logged = false;
  bool first_frame_logged = false;
  std::chrono::steady_clock::time_point start_time;
  std::chrono::steady_clock::time_point frame_down;
  uint64_t presents = 0;
  std::vector<double> render_ms;
  std::vector<double> blit_ms;
  std::vector<double> draw_ms;
  std::vector<double> begin_ms;
  std::vector<double> key_to_pending_ms;
  std::vector<double> pending_to_present_ms;
  std::vector<double> frame_ms;
  std::vector<int> frame_batches;
  std::vector<int> frame_backlog;
  std::chrono::steady_clock::time_point key_pending_time;
  bool key_pending_timed = false;
  std::vector<double> flush_ms;
  unsigned long glyph_cmds = 0;
  unsigned long key_events = 0;
  int last_blits = 0;
  unsigned long cmds_applied = 0;
  unsigned long epochs_applied = 0;
  unsigned long presents_skipped = 0;
  unsigned long flush_fail = 0;
  unsigned long batches_applied = 0;
  unsigned long surface_rebuilds = 0;
};
} // namespace ohosgui

#endif

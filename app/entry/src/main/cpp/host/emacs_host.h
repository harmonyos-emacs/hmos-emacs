/* In-process Emacs service.  The instance owns the resolved ABI, the Emacs
   thread and the draw-wakeup TSFN; napi adapters only call into it.  */
#ifndef OHOS_HOST_EMACS_HOST_H
#define OHOS_HOST_EMACS_HOST_H

#include <napi/native_api.h>
#include <pthread.h>

#include <atomic>
#include <chrono>
#include <vector>
#include <string>
#include <vector>

struct ohos_emacs_api;

struct EmacsHost
{
  const struct ohos_emacs_api *api = nullptr;
  pthread_t tid{};
  bool running = false;
  std::vector<std::string> args;
  std::string cwd;
  napi_threadsafe_function host_tsfn = nullptr;
  std::atomic<bool> host_wakeup_pending{ false };
  std::atomic<unsigned long> host_wakeup_calls{ 0 };
  std::atomic<uint32_t> activity{ 0 };
  bool have_display_metrics = false;
  double density_dpi = 96.0;
  double density_pixels = 1.0;
  double scaled_density = 1.0;
  double xdpi = 96.0;
  double ydpi = 96.0;
};

EmacsHost &HostEmacs ();
extern "C" void HostFlushPendingSurface (void);

/* Wake ArkTS because Emacs queued a typed host event or chrome update.  */
void RequestHostWake (void);
/* Register the ArkTS callback that drains typed host events.  */
void CreateHostWakeup (napi_env env, napi_value callback);

#endif

#ifndef OHOS_GUI_CONTEXT_H
#define OHOS_GUI_CONTEXT_H

#include "surface.h"

#include <memory>
#include <mutex>
#include <unordered_map>

namespace ohosgui
{
/* Top-level owner of the UI-thread state.  Each Emacs frame has exactly one
   Surface; the component map lets XComponent callbacks find their frame.  */
struct GuiContext
{
  std::mutex lock;
  std::unordered_map<uint32_t, std::shared_ptr<Surface> > surfaces;
  std::unordered_map<OH_NativeXComponent *, uint32_t> components;
};

GuiContext &CurrentContext (void);
} // namespace ohosgui

#endif

#include "gui_context.h"
#include "surface.h"

#include <utility>

namespace ohosgui
{
namespace
{
GuiContext g_context;
} // namespace

GuiContext &
CurrentContext (void)
{
  return g_context;
}

Surface *
GetOrCreateSurface (uint32_t frame_id, const std::string &component_id)
{
  if (frame_id == 0)
    return nullptr;
  std::lock_guard<std::mutex> guard (g_context.lock);
  auto it = g_context.surfaces.find (frame_id);
  if (it != g_context.surfaces.end ())
    {
      if (!component_id.empty ())
        it->second->component_id = component_id;
      return it->second.get ();
    }
  auto surface = std::make_shared<Surface> ();
  surface->frame_id = frame_id;
  surface->component_id = component_id;
  Surface *raw = surface.get ();
  g_context.surfaces.emplace (frame_id, std::move (surface));
  return raw;
}

Surface *
FindSurfaceByFrame (uint32_t frame_id)
{
  std::lock_guard<std::mutex> guard (g_context.lock);
  auto it = g_context.surfaces.find (frame_id);
  return it == g_context.surfaces.end () ? nullptr : it->second.get ();
}

SurfacePtr
AcquireSurfaceByFrame (uint32_t frame_id)
{
  std::lock_guard<std::mutex> guard (g_context.lock);
  auto it = g_context.surfaces.find (frame_id);
  return it == g_context.surfaces.end () ? nullptr : it->second;
}

SurfacePtr
AcquireSurfaceByComponent (OH_NativeXComponent *component)
{
  if (!component)
    return nullptr;
  std::lock_guard<std::mutex> guard (g_context.lock);
  auto it = g_context.components.find (component);
  if (it == g_context.components.end ())
    return nullptr;
  auto surface = g_context.surfaces.find (it->second);
  return surface == g_context.surfaces.end () ? nullptr : surface->second;
}

SurfacePtr
AcquireCurrentSurface (void)
{
  SurfacePtr surface = AcquireSurfaceByFrame (1);
  if (!surface)
    {
      GetOrCreateSurface (1, "emacs_gui");
      surface = AcquireSurfaceByFrame (1);
    }
  return surface;
}

Surface *
FindSurfaceByComponent (OH_NativeXComponent *component)
{
  if (!component)
    return nullptr;
  std::lock_guard<std::mutex> guard (g_context.lock);
  auto it = g_context.components.find (component);
  if (it == g_context.components.end ())
    return nullptr;
  auto surface = g_context.surfaces.find (it->second);
  return surface == g_context.surfaces.end () ? nullptr
                                              : surface->second.get ();
}

void
BindSurfaceComponent (uint32_t frame_id, OH_NativeXComponent *component)
{
  if (frame_id == 0 || !component)
    return;
  std::lock_guard<std::mutex> guard (g_context.lock);
  g_context.components[component] = frame_id;
}

void
UnbindSurfaceComponent (uint32_t frame_id, OH_NativeXComponent *component)
{
  std::lock_guard<std::mutex> guard (g_context.lock);
  if (component)
    g_context.components.erase (component);
  auto it = g_context.surfaces.find (frame_id);
  if (it != g_context.surfaces.end ())
    {
      it->second->component = nullptr;
      it->second->window = nullptr;
      it->second->running = false;
    }
}

void
RemoveSurface (uint32_t frame_id)
{
  std::lock_guard<std::mutex> guard (g_context.lock);
  for (auto it = g_context.components.begin ();
       it != g_context.components.end ();)
    {
      if (it->second == frame_id)
        it = g_context.components.erase (it);
      else
        ++it;
    }
  g_context.surfaces.erase (frame_id);
}

Surface &
CurrentSurface (void)
{
  Surface *surface = FindSurfaceByFrame (1);
  if (!surface)
    surface = GetOrCreateSurface (1, "emacs_gui");
  return *surface;
}

} // namespace ohosgui

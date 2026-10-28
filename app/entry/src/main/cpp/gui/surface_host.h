#ifndef OHOS_GUI_SURFACE_HOST_H
#define OHOS_GUI_SURFACE_HOST_H

namespace ohosgui
{
struct Surface;

/* Derive the cached character grid from the surface and frame metrics.
   This is diagnostic/UI state only; the renderer uses the frame's pixel
   rect, not a cell grid.  */
void ConfigureGeometry (Surface &s);
} // namespace ohosgui

#endif

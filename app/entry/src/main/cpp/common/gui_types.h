#ifndef OHOS_GUI_TYPES_H
#define OHOS_GUI_TYPES_H

#include <cstdint>
#include <vector>

#include "text_style.h"

namespace ohosgui
{
constexpr int kFontW = kDefaultCellWidth;
constexpr int kFontH = kDefaultCellHeight;

struct Color
{
  uint8_t r, g, b;
};

constexpr Color kDefaultFg = { 220, 220, 220 };
constexpr Color kDefaultBg = { 30, 30, 30 };

/* xterm's first 16 colors, tuned for the dark HarmonyOS surface. */
constexpr Color kPalette[16] = {
  { 0, 0, 0 },       { 205, 49, 49 },   { 13, 188, 121 }, { 229, 229, 16 },
  { 36, 114, 200 },  { 188, 63, 188 },  { 17, 168, 205 }, { 229, 229, 229 },
  { 102, 102, 102 }, { 241, 76, 76 },   { 35, 209, 139 }, { 245, 245, 67 },
  { 59, 142, 234 },  { 214, 112, 214 }, { 41, 184, 219 }, { 255, 255, 255 }
};

inline uint32_t
Pixel (Color c)
{
  /* NativeWindow uses RGBA_8888 with byte order R,G,B,A.  On little-endian
     a uint32_t store therefore starts with R. */
  return (uint32_t) c.r | ((uint32_t) c.g << 8) | ((uint32_t) c.b << 16)
         | 0xff000000u;
}

struct Cell
{
  uint32_t ch = ' ';
  Color fg = kDefaultFg;
  Color bg = kDefaultBg;
  uint8_t attr = 0; /* bit 0 bold, bit 1 reverse, bit 2 underline */
};

struct Pen
{
  Color fg = kDefaultFg;
  Color bg = kDefaultBg;
  uint8_t attr = 0;
  void
  Reset ()
  {
    fg = kDefaultFg;
    bg = kDefaultBg;
    attr = 0;
  }
};
} // namespace ohosgui

#endif

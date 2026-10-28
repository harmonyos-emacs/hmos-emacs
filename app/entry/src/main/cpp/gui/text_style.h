/* Text metrics shared by the font setup and the native glyph renderer.
   Values are device pixels for the default 9x18 cell; the same constants
   must drive both measurement and rasterisation.  */
#ifndef OHOS_GUI_TEXT_STYLE_H
#define OHOS_GUI_TEXT_STYLE_H

constexpr int kDefaultCellWidth = 9;
constexpr int kDefaultCellHeight = 18;
/* Latin glyphs are rendered slightly smaller than the cell; CJK fills it.  */
constexpr float kMonoTextSize = 15.5f;
constexpr int kMonoBaseline = 14;
constexpr float kCjkTextSize = 18.0f;

#endif

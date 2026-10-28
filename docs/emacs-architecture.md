# Emacs OHOS 侧架构

## 1. 文档状态

本页只维护 Emacs 的 OHOS 实现：frame/terminal 接入、renderer context、
surface 几何、绘制/present 和 Emacs RIF 集成。通用 Emacs redisplay、
非 OHOS 平台行为不在本页。

>
> 系统级组件/线程/ABI 总览见 [整体架构](architecture.md)，App 侧见
> [app-architecture.md](app-architecture.md)。

---

## 2. 第一性定位

```text
Emacs     决定显示什么
renderer  决定怎么变成像素
UI 线程   决定窗口、输入和 surface 生命周期
```

更精确地说：

```text
Emacs:
  frame / window / glyph / face / font / damage / redisplay

renderer:
  per-frame surface / bitmap / canvas / padding / present

UI:
  XComponent / NativeWindow / input / IME / SurfaceEvent
```

renderer 是 **Emacs frame 的输出设备**，不是进程级屏幕设备。

### 2.1 职责总览

```text
surface 驱动 frame 尺寸
frame 决定内容几何
renderer 决定像素
UI 决定窗口和输入
```

展开：

```text
UI:
  决定窗口尺寸、surface 生命周期、输入路由

surface:
  提供可用 buffer 尺寸，是 frame 尺寸的输入

frame:
  surface 像素尺寸经 Emacs 布局后得到的内容 rect
  是 glyph/内容几何的唯一权威

renderer:
  只根据 frame content rect 生成像素
  不决定窗口尺寸，也不决定内容布局
```

---

## 3. 线程模型

### UI 线程

负责：

```text
XComponent 生命周期
NativeWindow 生命周期
键盘、触摸、IME
SurfaceEvent 投递
```

禁止：

```text
创建 Bitmap / Canvas
RequestBuffer / FlushBuffer
调用 renderer
修改 Emacs frame 状态
```

### Emacs 线程

负责：

```text
frame 创建、删除、选择
redisplay
绘图回调
SurfaceEvent 消费
renderer 状态迁移
present
```

所有 renderer 函数（除 surface event 入队接口）只能在 Emacs 线程调用。

---

## 4. Per-Frame Context

### 4.1 所有权

每个 Emacs frame 拥有一个 renderer context：

```c
struct ohos_output
{
  /* Emacs frame output data */
  struct ohos_renderer *renderer;
  ...
};
```

renderer context 的生命周期与 frame 一致：

```text
ohos_create_frame
  → ohos_renderer_create()
  → 存入 frame->output_data.ohos->renderer

ohos_delete_frame
  → ohos_renderer_destroy()
  → 清空 frame->output_data.ohos->renderer
```

不允许：

```text
全局 bitmap
全局 canvas
全局 surface
全局 content size
```

### 4.2 Context 内容

```c
struct ohos_renderer
{
  /* surface */
  void *window;
  int surface_w;
  int surface_h;
  uint64_t surface_generation;
  RenderSurfaceState surface_state;

  /* content */
  int frame_w;
  int frame_h;
  int frame_cell_w;
  int frame_cell_h;

  /* backing store */
  Bitmap *bitmap;
  Canvas *canvas;
  int bitmap_w;
  int bitmap_h;

  /* frame transaction */
  RenderFrameState frame_state;
  bool frame_complete;
  bool frame_has_draw;
  bool need_full_repaint;

  /* caches */
  FontCache fonts;
  ImageCache images;
};
```

### 4.3 多 frame

```text
frame A ── renderer A ── surface A
frame B ── renderer B ── surface B
```

每个 frame 的：

```text
surface
content size
bitmap
frame transaction
```

互相独立。

如果某个 platform 只支持一个 XComponent，则只创建一个 frame context，
但接口仍保持 per-frame，不把限制写进 renderer。

---

## 5. SurfaceEvent

### 5.1 UI → Emacs

```c
enum SurfaceEventKind
{
  SURFACE_CREATED,
  SURFACE_RESIZED,
  SURFACE_DESTROYED,
};

struct SurfaceEvent
{
  enum SurfaceEventKind kind;
  uint32_t surface_id;
  void *window;
  int surface_w;
  int surface_h;
  uint64_t generation;
};
```

`surface_id` 用于路由到对应 frame context。

### 5.2 规则

```text
CREATED     绑定 window，初始化 surface 尺寸
RESIZED     只更新 surface 尺寸，不重建 bitmap
DESTROYED   使对应 context 的 surface 失效
```

连续 `RESIZED` 合并为最新一个。

`DESTROYED` 不能被后续的旧 generation 越过。

### 5.3 应用位置

```text
UI 线程:
  enqueue SurfaceEvent

Emacs 线程:
  ohos_read_socket / ohos_apply_surface_events
  → 找到 surface_id 对应的 context
  → ohos_renderer_apply_surface_event(ctx, event)
```

没有对应 frame context 时：

```text
缓存为 pending surface
frame 创建后再绑定
不得丢弃唯一创建事件
```

---

## 6. 几何权威

### 6.1 尺寸来源与内容几何

这两个概念必须分开：

```text
尺寸来源：surface 驱动 frame
内容几何：frame 决定 content rect
```

正常窗口 resize 流程：

```text
surface_w/h
  → 交给 Emacs 的 pixelwise frame resize
  → Emacs 计算 menu bar/tool bar/scroll bar/fringe/border/min size
  → FRAME_PIXEL_WIDTH / FRAME_PIXEL_HEIGHT
  → renderer content rect
```

关键规则：

```text
surface 提供可用像素尺寸
Emacs 决定最终 frame 像素尺寸
renderer 只使用最终 frame content rect
```

backend 不预先做：

```text
cols = floor(surface_w / cell_w)
frame_w = cols * cell_w
```

也不应把 surface 尺寸手动截断到字符网格。

frame 的字符列数仍然存在：

```text
cols = floor(text_pixel_width / cell_w)
```

但它是 frame 确定后的**派生值**，不是缩减 frame 尺寸的依据。

surface 变化后，frame 可能变化，也可能不变：

```text
Emacs 采用 surface 尺寸
Emacs 受 min/max size 限制
Emacs 因菜单栏、滚动条、边框做调整
字符列数变化但像素 frame 不变
```

无论哪种，最终都以：

```text
FRAME_PIXEL_WIDTH × FRAME_PIXEL_HEIGHT
```

作为 renderer 的 content rect。

### 6.2 内容几何权威

```text
frame content = FRAME_PIXEL_WIDTH × FRAME_PIXEL_HEIGHT
```

frame 是**内容几何**的唯一权威，不是 frame 尺寸的来源。

尺寸由 surface 驱动，但一旦 frame 确定：

```text
glyph 布局
内容坐标
裁切边界
present content rect
```

全部以 frame 为准，surface 不能缩放或平移内容。

所有：

```text
glyph 坐标
mode line
menu bar
scroll bar
cursor
```

都以 frame pixel rect 为准。

### 6.3 surface

```text
surface = NativeWindow buffer 尺寸
```

surface 是 frame 尺寸的输入，同时是 buffer 的硬约束：

```text
frame <= surface
```

如果 Emacs 最终给出的 frame 大于 surface：

```text
RESIZING
不绘制
不 present
```

### 6.4 padding

```text
content rect = (0, 0, frame_w, frame_h)
buffer      = surface_w × surface_h
padding     = surface - frame
```

present 时：

```text
1. 整个 buffer 填 frame background
2. content 拷贝到 (0,0)
3. FlushBuffer
```

padding 必须是不透明背景色。

### 6.5 frame > surface

```text
不绘制
不 present
状态 = RESIZING
保持 last-good frame
```

不能裁剪内容后提交。

---

## 7. Renderer 状态

每个 context 独立维护：

```text
EMPTY
  → PENDING_SURFACE
  → READY
  → RESIZING
  → READY
  → DESTROYED
```

```text
EMPTY             没有 surface
PENDING_SURFACE   有 pending surface，尚未应用
READY             surface >= frame，可绘制/present
RESIZING          frame 或 surface 变化中
DESTROYED         surface 销毁
```

状态只由 Emacs 线程迁移。

---

## 8. 绘制接口

### 8.2 直接类型化接口

```c
struct ohos_renderer;

struct ohos_renderer *ohos_renderer_create (void);
void ohos_renderer_destroy (struct ohos_renderer *r);

/* surface，仅 Emacs 线程应用 */
void ohos_renderer_apply_surface_event (
    struct ohos_renderer *r,
    const struct SurfaceEvent *event);

/* frame 尺寸，来自 Emacs frame */
void ohos_renderer_set_frame_size (
    struct ohos_renderer *r,
    int frame_w,
    int frame_h,
    int cell_w,
    int cell_h);

/* 帧事务 */
int  ohos_renderer_begin_frame (struct ohos_renderer *r);
void ohos_renderer_clear (struct ohos_renderer *r, uint32_t bg);
void ohos_renderer_fill (
    struct ohos_renderer *r,
    int x, int y, int w, int h,
    uint32_t color);
void ohos_renderer_text (
    struct ohos_renderer *r,
    int x, int y, int w, int h,
    unsigned code,
    uint32_t fg,
    uint32_t bg,
    uint32_t flags);
void ohos_renderer_image (
    struct ohos_renderer *r,
    int x, int y, int w, int h,
    const void *rgba,
    unsigned len);
void ohos_renderer_cursor (
    struct ohos_renderer *r,
    int x, int y, int w, int h,
    int bar,
    uint32_t fg,
    uint32_t bg,
    uint32_t flags);
void ohos_renderer_scroll (
    struct ohos_renderer *r,
    int x, int y, int w, int h,
    int dy);
void ohos_renderer_end_frame (struct ohos_renderer *r);
int  ohos_renderer_present (struct ohos_renderer *r);
```

### 8.3 调用约定

```text
begin_frame
  clear / fill / text / image / cursor / scroll
end_frame
present
```

规则：

```text
begin_frame 是唯一允许重建 framebuffer 的入口
end_frame 标记本帧 content 完整
present 只提交完整帧
present 失败不能提交半帧
```

`image` 的 RGBA 指针在函数返回前被消费，不保存跨帧指针。

---

## 9. Emacs Redisplay 集成

### 9.1 frame output data

`ohosgui.c` 的 redisplay hooks 从 frame 取 context：

```c
static struct ohos_renderer *
frame_renderer (struct frame *f)
{
  struct ohos_output *o = FRAME_OUTPUT_DATA (f);
  return o ? o->renderer : NULL;
}
```

所有绘制入口都显式绑定 frame，不使用全局 renderer。

### 9.2 update_begin / update_end

```text
ohos_update_begin (frame)
  → begin_frame(ctx)

ohos_update_end (frame)
  → end_frame(ctx)
```

### 9.3 flush_display / frame_up_to_date

```text
ohos_flush (frame)
  → need_flip 时 present(ctx)
  → 成功：清 need_flip
  → 失败：不标记完成，请求下一次 redisplay

ohos_frame_up_to_date (frame)
  → 再次确保已完成的 frame 已 present
```

### 9.4 frame 删除

```text
ohos_delete_frame (frame)
  → destroy renderer context
  → 释放 bitmap/canvas/font/image cache
```

---

## 10. Resize 协议

```text
UI:
  OnSurfaceChanged
    → 合并最新 RESIZED
    → 唤醒 Emacs
    → 不重建 buffer

Emacs:
  消费 RESIZED
  → 找到 frame context
  → 以 surface_w/h 请求 pixelwise frame resize
  → Emacs 计算最终 FRAME_PIXEL_WIDTH/HEIGHT
  → set_frame_size(frame_w, frame_h)

Renderer:
  begin_frame
    → surface/frame 稳定时重建一次 framebuffer
    → 否则保持 RESIZING

  present
    → 只在 READY 时提交
    → 旧帧保持完整
```

要求：

```text
surface 是 frame 尺寸的来源
frame 是内容几何的权威
resize 事件本身不重建 bitmap
begin_frame 才能重建
resize 未稳定不 present
重建后请求一次全量 redisplay
```

---

## 11. 全量重绘

renderer 重建 bitmap 后旧内容丢失，而 Emacs 可能只发送局部更新。

因此：

```text
begin_frame 重建 bitmap
  → need_full_repaint = true
  → end_frame/present 后通知 Emacs
  → Emacs 标记 frame garbaged
  → 下一次 redisplay 全量绘制
```

通知可以复用 expose 事件，但必须：

```text
只在 frame context 已 ready 后分发
不能绕过 frame 生命周期
```

---

## 12. 字体与图像

### 字体

Emacs 是 font/fontset 权威。

renderer 不硬编码：

```text
monospace
默认 cell 尺寸
系统字体路径
```

frame context 接收：

```text
font descriptor / font id
cell_w / cell_h
ascent / descent
```

renderer 只负责字形栅格化和缓存。

### 图像

Emacs 解码并给出 RGBA。renderer 只负责：

```text
缩放
裁剪
合成
```

---

## 14. 失败处理

```text
surface 未 ready        present 返回 0
frame 未设置            begin_frame 返回 0
frame > surface         RESIZING，不绘制
generation 不匹配        丢弃事件
content 未 complete     present 返回 0
RequestBuffer 失败      last-good 保留
FlushBuffer 失败        丢弃当前帧，请求重绘
```

任何失败都不能：

```text
崩溃
提交半帧
修改别的 frame 的 context
```

---

## 15. 与 Emacs 约束的对应

| Emacs 约束 | 本架构 |
|---|---|
| redisplay 在 Emacs 线程 | renderer 只在该线程调用 |
| frame 拥有 output data | 每 frame 一个 renderer context |
| update_begin/end 是 per-frame | begin/end 接收 context |
| flush_display 是 per-frame | present 接收 context |
| frame_up_to_date 需要 present 成功 | 失败不标记完成 |
| 多 frame | 每 frame 独立 surface/bitmap |
| 字体由 Emacs 决定 | context 接收 font metrics |
| surface 是平台资源 | UI 只投递事件 |

---

---

## 17. 结论

```text
renderer 不是进程全局设备
renderer 是每个 Emacs frame 的像素后端
```

```text
Emacs 拥有语义和 frame
renderer 拥有像素和 surface
UI 拥有窗口和输入
```

```text
同线程、静态链接、直接调用
无命令队列
无全局绘制状态
```

---

## 18. 多窗口边界（BLOCKED）

renderer 的接口保持 per-frame，但产品状态不承诺多窗口：

```text
一个窗口 ↔ 一个 XComponent/NativeWindow ↔ 一个 frame ↔ 一个 renderer
共享：一个 Emacs 线程、一个 Lisp 状态
不共享：frame、surface、bitmap、焦点
```

约束：

- `frame_id` 是唯一跨线程键；不跨 ABI 传 `frame*`、Lisp 对象或 renderer 指针；
- 每个 frame 有独立 renderer context、surface 状态和 present 事务；
- surface/input 事件必须带 `frame_id` 和 generation；
- 一个 frame 的 present 失败不能影响其它 frame。

多 subWindow 的创建、关闭、焦点、IME、菜单和 MW 用例属于实验路径；
本文不维护第二份设计，能力边界和解除条件见
[capabilities.md](capabilities.md#4-已知阻塞)。

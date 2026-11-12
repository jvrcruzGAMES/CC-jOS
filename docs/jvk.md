# `libjvk` (`jvk`) — Vulkan-Style Pixelwise 2D & 3D Graphics & UI Library for CC-jOS

`libjvk` (`/System/Libraries/jvk.lua`) is the official, cryptographically signed userspace graphics and UI library bundled with **CC-jOS**.

 Both the **BIOS Framebuffer (`BIOS.fb`)** and **`libjvk`** are **100% pixelwise** (`2×3` sub-pixels per character cell, using CC:Tweaked teletext drawing characters `0x80`–`0x9F` / `128`–`159` and `sanjuuni`-style 2-color block quantization). On a standard `51 × 19` CC:Tweaked terminal, the pixelwise framebuffer provides a **`102 × 57` pixel canvas** where each sub-pixel has a `1:1` square aspect ratio.

---

## Architecture & Pixelwise Rendering Stack

```
+-----------------------------------------------------------------------+
|                    Userspace .app Bundle (e.g. Init.app)              |
|                        local jvk = require("jvk")                     |
+-----------------------------------------------------------------------+
                                    |
                                    | VkInstance -> VkDevice -> VkSwapchainKHR (102x57 px)
                                    | VkRenderPass -> VkPipeline -> VkCommandBuffer
                                    | jvk.queueSubmit(...) & jvk.queuePresent(...)
                                    v
+-----------------------------------------------------------------------+
|             Bundled Graphics Library (/System/Libraries/jvk.lua)      |
|  - Pixelwise 2D UI Widgets & 3x5 Bitmap Font Text Renderer            |
|  - 3D Math (vec3, mat4), Mesh Generators & Depth-Buffered Rasterizer  |
+-----------------------------------------------------------------------+
                                    |
                                    | syscall("fb.info" | "fb.submitBatch" | "fb.present")
                                    | Requires permission: "graphics.framebuffer"
                                    v
+-----------------------------------------------------------------------+
|                    Kernel Framebuffer Syscall Layer                   |
|                      (/System/Kernel/kernel.lua)                      |
+-----------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------+
|                BIOS Pixelwise Framebuffer (BIOS.fb)                   |
|   - 2x3 Sub-pixel Teletext Block Quantizer (\128..\159, sanjuuni)     |
|   - Flushes encoded teletext scanlines via rawTerm.blit               |
+-----------------------------------------------------------------------+
```

---

## How `2×3` Sub-Pixel Teletext Rendering Works (`sanjuuni` Style)

Each CC:Tweaked terminal cell `(cx, cy)` displays a `2 × 3` grid of sub-pixels encoded by character codes `128` through `159` (`0x80`–`0x9F`):

```
+-------------------+-------------------+
| (px0,   py0)   b0 | (px0+1, py0)   b1 |
+-------------------+-------------------+
| (px0,   py0+1) b2 | (px0+1, py0+1) b3 |
+-------------------+-------------------+
| (px0,   py0+2) b4 | (px0+1, py0+2) bg |
+-------------------+-------------------+
```

During `BIOS.fb.present()`:
1. For each `2×3` pixel block in the `102 × 57` pixel buffer, the quantizer selects the two most frequent colors in the block (`c1`, `c2`).
2. If more than two colors appear in the same `2×3` block, remaining sub-pixels are snapped to whichever of `c1` or `c2` is closest in Euclidean RGB distance in CC:Tweaked's 16-color palette.
3. Because sub-pixel 6 (bottom-right) is always rendered using the cell's background color in CC:Tweaked, `bg` is assigned to sub-pixel 6's color, `fg` is assigned to the other color, and bits `0..4` (`1, 2, 4, 8, 16`) form the teletext character `string.char(128 + mask)`.

---

## Quick Start Example (Pixelwise 2D UI + Embedded 3D Viewport)

```lua
local jvk = require("jvk")

-- 1. Create Vulkan-style Instance, Device, Queue & Pixelwise Swapchain (102x57)
local instance = jvk.createInstance({
    applicationInfo = {
        applicationName = "DemoApp",
        applicationVersion = "1.1.0",
        engineName = "libjvk"
    }
})

local physicalDevices = jvk.enumeratePhysicalDevices(instance)
local device = jvk.createDevice(physicalDevices[1])
local queue = device:getQueue()
local swapchain = jvk.createSwapchain(device)

-- 2. Create RenderPass & Graphics Pipelines (2D and 3D)
local renderPass = jvk.createRenderPass(device, {
    loadOp = jvk.LOAD_OP_CLEAR,
    clearColor = jvk.COLORS.BLACK
})

local pipeline2D = jvk.createGraphicsPipeline(device, {
    bindPoint = jvk.PIPELINE_BIND_POINT_GRAPHICS_2D
})

local pipeline3D = jvk.createGraphicsPipeline(device, {
    bindPoint = jvk.PIPELINE_BIND_POINT_GRAPHICS_3D,
    polygonMode = jvk.POLYGON_MODE_LINE,
    cullMode = jvk.CULL_MODE_NONE,
    depthTestEnable = true
})

-- 3. Record Command Buffer in Pixel Coordinates (1..102, 1..57)
local cube = jvk.mesh.cube(1.8)
local cmd = jvk.createCommandBuffer(device)

cmd:begin()
cmd:beginRenderPass({ renderPass = renderPass, swapchain = swapchain })

cmd:bindPipeline(pipeline2D)
cmd:uiWindow({
    x = 1, y = 1, w = swapchain.width, h = swapchain.height,
    title = "CC-jOS Userspace [libjvk]",
    headerColor = jvk.COLORS.BLUE,
    bodyColor = jvk.COLORS.BLACK
})

cmd:uiViewport3D({
    x = 4, y = 10, w = 44, h = 44,
    title = "3D Cube",
    borderColor = jvk.COLORS.CYAN,
    render = function(subCmd, aspect)
        subCmd:bindPipeline(pipeline3D)
        local model = jvk.mat4.mul(jvk.mat4.rotationY(0.65), jvk.mat4.rotationX(0.45))
        local view  = jvk.mat4.lookAt(
            jvk.vec3.new(0, 0, 3.1),
            jvk.vec3.new(0, 0, 0),
            jvk.vec3.new(0, 1, 0)
        )
        local proj  = jvk.mat4.perspective(math.pi / 3, aspect, 0.1, 50.0)
        local mvp   = jvk.mat4.mul(proj, jvk.mat4.mul(view, model))

        subCmd:pushConstants({ mvp = mvp, fg = jvk.COLORS.CYAN })
        subCmd:drawMesh(cube)
        subCmd:bindPipeline(pipeline2D)
    end
})

cmd:uiLabel({
    x = 53, y = 24, w = 44,
    text = "Kernel's up",
    fg = jvk.COLORS.LIME,
    align = "center"
})

cmd:endRenderPass()
cmd:endRecording()

-- 4. Submit Command Buffer to Queue & Present Swapchain
jvk.queueSubmit(queue, cmd)
jvk.queuePresent(queue, swapchain)
```

---

## API Reference

### 1. Core Lifecycle Functions
| Function | Description |
| :--- | :--- |
| `jvk.createInstance(createInfo)` | Creates a `VkInstance` handle with `applicationInfo`. |
| `jvk.enumeratePhysicalDevices(instance)` | Queries `syscall("fb.info")` and returns sub-pixel `VkPhysicalDevice` adapters (`width = termW * 2`, `height = termH * 3`). |
| `jvk.createDevice(physicalDevice, createInfo)` | Creates a logical `VkDevice` and its graphics `VkQueue` (`device:getQueue()`). |
| `jvk.createSwapchain(device, createInfo)` | Allocates pixelwise color buffer (`pixels[y][x]`) and 3D depth buffer (`depth[y][x]`). |
| `jvk.createRenderPass(device, renderPassInfo)` | Defines attachment `loadOp` (`LOAD_OP_CLEAR` / `LOAD_OP_LOAD`), `clearColor`, `clearDepth`. |
| `jvk.createGraphicsPipeline(device, pipelineInfo)` | Creates a `VkPipeline` (`GRAPHICS_2D` or `GRAPHICS_3D`, `POLYGON_MODE_LINE` / `FILL`, `cullMode`, `depthTestEnable`). |
| `jvk.createCommandBuffer(device)` | Allocates a recordable `VkCommandBuffer`. |
| `jvk.queueSubmit(queue, cmdBuffers)` | Executes recorded command buffers into the pixel swapchain and submits pixel rows via `syscall("fb.submitBatch")`. |
| `jvk.queuePresent(queue, swapchain)` | Quantizes `2×3` sub-pixel blocks into teletext characters and flushes to the screen via `syscall("fb.present")`. |
| `jvk.measureText(text, scale)` | Returns `(pixelWidth, pixelHeight)` of a string rendered with the built-in 3×5 bitmap font. |

### 2. Command Buffer (`VkCommandBuffer`) Methods
- **State & Pipeline**:
  - `cmd:begin()` / `cmd:reset()` / `cmd:endRecording()`
  - `cmd:beginRenderPass({ renderPass = rp, swapchain = sc })` / `cmd:endRenderPass()`
  - `cmd:bindPipeline(pipeline)`
  - `cmd:setViewport({ x, y, width, height })`
  - `cmd:pushConstants({ mvp = mat, fg = col, color = col })`
- **Pixelwise 2D Drawing Primitives**:
  - `cmd:drawPixel(x, y, color)`
  - `cmd:drawLine2D(x0, y0, x1, y1, color)`
  - `cmd:drawRect(x, y, w, h, color)`
  - `cmd:drawBorderBox(x, y, w, h, borderColor, bgColor, title, titleColor)`
  - `cmd:drawText(x, y, text, fgColor, bgColor, scale)` (renders 3×5 pixel bitmap font into pixel buffer)
  - `cmd:drawTextCentered(y, text, fgColor, bgColor, regionX, regionW, scale)`
- **Pixelwise 2D UI Widgets**:
  - `cmd:uiWindow({ x, y, w, h, title, headerColor, titleColor, borderColor, bodyColor })`
  - `cmd:uiPanel({ x, y, w, h, title, borderColor, bg, border })`
  - `cmd:uiLabel({ x, y, w, text, fg, bg, scale, align = "left" | "center" | "right" })`
  - `cmd:uiButton({ x, y, w, h, label, fg, bg, active })`
  - `cmd:uiProgressBar({ x, y, w, h, progress, fillBg, emptyBg, fg, label })`
- **3D Rendering & 3D UI Widgets**:
  - `cmd:drawLine3D(v0, v1, color)`
  - `cmd:drawTriangle3D(v0, v1, v2, color)`
  - `cmd:drawMesh(mesh, opts)`
  - `cmd:uiViewport3D({ x, y, w, h, title, borderColor, bg, render = function(cmd, aspect, w, h) ... end })`

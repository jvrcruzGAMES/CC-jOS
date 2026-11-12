# `libjvk` (`jvk`) — Vulkan-Style 2D & 3D Graphics & UI Library for CC-jOS

`libjvk` (`/System/Libraries/jvk.lua`) is the official, cryptographically signed userspace graphics and UI library bundled with **CC-jOS**.

While lower-level boot stages (`startup.lua` BIOS and `bootloader.lua`) render the hardcoded boot splash screen (a centered white uppercase `J`) directly via the BIOS Framebuffer (`BIOS.fb`), all userspace `.app` bundles build 2D and 3D user interfaces through `libjvk`.

---

## Architecture & Rendering Stack

```
+-----------------------------------------------------------------------+
|                    Userspace .app Bundle (e.g. Init.app)              |
|                        local jvk = require("jvk")                     |
+-----------------------------------------------------------------------+
                                    |
                                    | VkInstance -> VkDevice -> VkSwapchainKHR
                                    | VkRenderPass -> VkPipeline -> VkCommandBuffer
                                    | jvk.queueSubmit(...) & jvk.queuePresent(...)
                                    v
+-----------------------------------------------------------------------+
|             Bundled Graphics Library (/System/Libraries/jvk.lua)      |
|  - 2D UI Widget Engine (Windows, Panels, Labels, Buttons, Progress)   |
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
|                       BIOS Framebuffer (BIOS.fb)                      |
|                         (/startup.lua -> term.blit)                   |
+-----------------------------------------------------------------------+
```

---

## Required `.app` Permission

To use `libjvk` or any `fb.*` kernel syscall, declare `"graphics.framebuffer"` in your app's `manifest.lua`:

```lua
return {
    id = "com.example.myapp",
    name = "MyApp",
    version = "1.0.0",
    type = "user",
    entry = "main.lua",
    permissions = {
        "graphics.framebuffer",
    },
    files = {
        ["main.lua"] = "<sha256>",
    }
}
```

---

## Quick Start Example (2D UI + Embedded 3D Viewport)

```lua
local jvk = require("jvk")

-- 1. Create Vulkan-style Instance, Device, Queue & Swapchain
local instance = jvk.createInstance({
    applicationInfo = {
        applicationName = "DemoApp",
        applicationVersion = "1.0.0",
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
    clearColor = jvk.COLORS.BLACK,
    clearTextColor = jvk.COLORS.WHITE,
    clearChar = " "
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

-- 3. Record Command Buffer
local cube = jvk.mesh.cube(1.8)
local cmd = jvk.createCommandBuffer(device)

cmd:begin()
cmd:beginRenderPass({ renderPass = renderPass, swapchain = swapchain })

cmd:bindPipeline(pipeline2D)
cmd:uiWindow({
    x = 1, y = 1, w = swapchain.width, h = swapchain.height,
    title = "My 2D + 3D App",
    headerColor = jvk.COLORS.BLUE,
    bodyColor = jvk.COLORS.BLACK
})

cmd:uiViewport3D({
    x = 3, y = 3, w = 22, h = 13,
    title = "3D Scene",
    borderColor = jvk.COLORS.CYAN,
    render = function(subCmd, aspect)
        subCmd:bindPipeline(pipeline3D)
        local model = jvk.mat4.mul(jvk.mat4.rotationY(0.6), jvk.mat4.rotationX(0.4))
        local view  = jvk.mat4.lookAt(
            jvk.vec3.new(0, 0, 3.2),
            jvk.vec3.new(0, 0, 0),
            jvk.vec3.new(0, 1, 0)
        )
        local proj  = jvk.mat4.perspective(math.pi / 3, aspect, 0.1, 50.0)
        local mvp   = jvk.mat4.mul(proj, jvk.mat4.mul(view, model))

        subCmd:pushConstants({ mvp = mvp, fg = jvk.COLORS.CYAN, char = "*" })
        subCmd:drawMesh(cube)
        subCmd:bindPipeline(pipeline2D)
    end
})

cmd:uiLabel({
    x = 27, y = 5, w = 20,
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
| `jvk.enumeratePhysicalDevices(instance)` | Queries `syscall("fb.info")` and returns available `VkPhysicalDevice` adapters. |
| `jvk.createDevice(physicalDevice, createInfo)` | Creates a logical `VkDevice` and its graphics `VkQueue` (`device:getQueue()`). |
| `jvk.createSwapchain(device, createInfo)` | Allocates 2D color/character buffers and a floating-point 3D depth buffer (`zBuffer`). |
| `jvk.createRenderPass(device, renderPassInfo)` | Defines attachment `loadOp` (`LOAD_OP_CLEAR` / `LOAD_OP_LOAD`), `clearColor`, `clearDepth`. |
| `jvk.createGraphicsPipeline(device, pipelineInfo)` | Creates a `VkPipeline` (`GRAPHICS_2D` or `GRAPHICS_3D`, `POLYGON_MODE_LINE` / `FILL`, `cullMode`, `depthTestEnable`). |
| `jvk.createCommandBuffer(device)` | Allocates a recordable `VkCommandBuffer`. |
| `jvk.queueSubmit(queue, cmdBuffers)` | Executes recorded command buffers into the swapchain and submits scanlines via `syscall("fb.submitBatch")`. |
| `jvk.queuePresent(queue, swapchain)` | Flushes the kernel framebuffer to the screen via `syscall("fb.present")`. |

### 2. Command Buffer (`VkCommandBuffer`) Methods
- **State & Pipeline**:
  - `cmd:begin()` / `cmd:reset()` / `cmd:endRecording()`
  - `cmd:beginRenderPass({ renderPass = rp, swapchain = sc })` / `cmd:endRenderPass()`
  - `cmd:bindPipeline(pipeline)`
  - `cmd:setViewport({ x, y, width, height })`
  - `cmd:pushConstants({ mvp = mat, fg = col, bg = col, char = ch })`
- **2D Drawing Primitives**:
  - `cmd:drawPixel(x, y, fgColor, bgColor, char)`
  - `cmd:drawLine2D(x0, y0, x1, y1, fgColor, bgColor, char)`
  - `cmd:drawRect(x, y, w, h, bgColor, fgColor, char)`
  - `cmd:drawBorderBox(x, y, w, h, borderColor, bgColor, title, titleColor)`
  - `cmd:drawText(x, y, text, fgColor, bgColor)`
  - `cmd:drawTextCentered(y, text, fgColor, bgColor, regionX, regionW)`
- **2D UI Widgets**:
  - `cmd:uiWindow({ x, y, w, h, title, headerColor, titleColor, borderColor, bodyColor })`
  - `cmd:uiPanel({ x, y, w, h, title, borderColor, bg, border })`
  - `cmd:uiLabel({ x, y, w, text, fg, bg, align = "left" | "center" | "right" })`
  - `cmd:uiButton({ x, y, w, h, label, fg, bg, active })`
  - `cmd:uiProgressBar({ x, y, w, progress, fillBg, emptyBg, fg, label })`
- **3D Rendering & 3D UI Widgets**:
  - `cmd:drawLine3D(v0, v1, fgColor, bgColor, char)`
  - `cmd:drawTriangle3D(v0, v1, v2, fgColor, bgColor, char)`
  - `cmd:drawMesh(mesh, opts)`
  - `cmd:uiViewport3D({ x, y, w, h, title, borderColor, bg, render = function(cmd, aspect, w, h) ... end })`

### 3. 3D Math & Mesh Utilities
- **`jvk.vec3`**: `new(x, y, z)`, `add(a, b)`, `sub(a, b)`, `scale(v, s)`, `dot(a, b)`, `cross(a, b)`, `length(v)`, `normalize(v)`
- **`jvk.mat4`**: `identity()`, `mul(a, b)`, `translation(x, y, z)`, `scaling(sx, sy, sz)`, `rotationX(rad)`, `rotationY(rad)`, `rotationZ(rad)`, `perspective(fovRad, aspect, near, far)`, `lookAt(eye, center, up)`, `transformVec3(m, v)`
- **`jvk.mesh`**: `cube(size)`, `pyramid(size)`

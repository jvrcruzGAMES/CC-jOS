-- ============================================================================
-- CC-jOS Initial Userspace Application (/System/Apps/Init.app/main.lua)
-- Takes over the rendering stack from the BIOS/Bootloader boot splash using
-- the bundled Vulkan-style 2D/3D graphics library (libjvk).
-- ============================================================================

-- 1. Verify userspace privilege isolation
local okSelf, selfInfo = syscall("process.self")
if okSelf and selfInfo then
    local fsAllowed = syscall("hw.fs")
    assert(not fsAllowed, "Userspace app must not have raw hardware FS permission!")
end

-- 2. Confirm the hardcoded BIOS boot screen (centered white uppercase "J")
--    remained intact up until this start app launched.
local okSnap, bootSnap = syscall("fb.snapshot")
if okSnap and bootSnap then
    local cx = math.floor((bootSnap.width + 1) / 2)
    local cy = math.floor((bootSnap.height + 1) / 2)
    local centerChar = bootSnap.textRows[cy]:sub(cx, cx)
    local centerFg   = bootSnap.fgRows[cy]:sub(cx, cx)
    assert(centerChar == "J" and centerFg == "0",
        "Expected centered white 'J' boot screen before Init.app takes over rendering!")
end

-- 3. Take over the rendering stack using libjvk (Vulkan-style 2D & 3D UI Library)
local jvk = require("jvk")

local instance = jvk.createInstance({
    applicationInfo = {
        applicationName = "CC-jOS Init",
        applicationVersion = "1.1.0",
        engineName = "libjvk"
    }
})

local physicalDevices = jvk.enumeratePhysicalDevices(instance)
local device = jvk.createDevice(physicalDevices[1])
local queue = device:getQueue()
local swapchain = jvk.createSwapchain(device)

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

local cubeMesh = jvk.mesh.cube(1.8)
local cmd = jvk.createCommandBuffer(device)

cmd:begin()
cmd:beginRenderPass({
    renderPass = renderPass,
    swapchain = swapchain
})

-- Bind 2D UI Pipeline and draw the main system window
cmd:bindPipeline(pipeline2D)
cmd:uiWindow({
    x = 1,
    y = 1,
    w = swapchain.width,
    h = swapchain.height,
    title = "CC-jOS Userspace [libjvk]",
    headerColor = jvk.COLORS.BLUE,
    titleColor = jvk.COLORS.WHITE,
    borderColor = jvk.COLORS.LIGHT_GRAY,
    bodyColor = jvk.COLORS.BLACK
})

-- Render a 3D Viewport inside the UI window using the 3D pipeline
local vpWidth = math.min(24, math.max(12, math.floor(swapchain.width * 0.45)))
local vpHeight = math.max(7, swapchain.height - 6)
cmd:uiViewport3D({
    x = 3,
    y = 3,
    w = vpWidth,
    h = vpHeight,
    title = "3D Cube",
    borderColor = jvk.COLORS.CYAN,
    bg = jvk.COLORS.BLACK,
    render = function(subCmd, aspect)
        subCmd:bindPipeline(pipeline3D)
        local model = jvk.mat4.mul(
            jvk.mat4.rotationY(0.65),
            jvk.mat4.rotationX(0.45)
        )
        local view = jvk.mat4.lookAt(
            jvk.vec3.new(0, 0, 3.2),
            jvk.vec3.new(0, 0, 0),
            jvk.vec3.new(0, 1, 0)
        )
        local proj = jvk.mat4.perspective(math.pi / 3, aspect, 0.1, 50.0)
        local mvp = jvk.mat4.mul(proj, jvk.mat4.mul(view, model))

        subCmd:pushConstants({ mvp = mvp, fg = jvk.COLORS.CYAN, char = "*" })
        subCmd:drawMesh(cubeMesh)
        subCmd:bindPipeline(pipeline2D)
    end
})

-- Render 2D status panel on the right with "Kernel's up"
local infoX = vpWidth + 5
local infoW = math.max(14, swapchain.width - infoX - 1)
cmd:uiPanel({
    x = infoX,
    y = 3,
    w = infoW,
    h = vpHeight,
    title = "Status",
    borderColor = jvk.COLORS.LIME,
    bg = jvk.COLORS.BLACK
})

cmd:uiLabel({
    x = infoX + 2,
    y = 5,
    w = infoW - 4,
    text = "Kernel's up",
    fg = jvk.COLORS.LIME,
    bg = jvk.COLORS.BLACK,
    align = "center"
})

cmd:uiProgressBar({
    x = infoX + 2,
    y = math.min(swapchain.height - 3, 8),
    w = math.max(6, infoW - 4),
    progress = 1.0,
    fillBg = jvk.COLORS.GREEN,
    emptyBg = jvk.COLORS.GRAY,
    fg = jvk.COLORS.WHITE,
    label = "READY"
})

cmd:endRenderPass()
cmd:endRecording()

jvk.queueSubmit(queue, cmd)
jvk.queuePresent(queue, swapchain)

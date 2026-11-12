-- ============================================================================
-- CC-jOS Home Menu: Launcher.app (/System/Apps/Launcher.app/main.lua)
-- Nintendo Switch qLaunch-Style Home Screen rendered pixelwise via libjvk
-- Horizontal row of square app tiles centered on the screen; WASD navigation
-- ============================================================================

-- 1. Verify userspace privilege isolation
local okSelf, selfInfo = syscall("process.self")
if okSelf and selfInfo then
    local fsAllowed = syscall("hw.fs")
    assert(not fsAllowed, "Userspace Launcher.app must not have raw hardware FS permission!")
end

-- 2. Confirm the hardcoded BIOS boot screen (centered white uppercase "J" in pixel space)
--    remained intact up until Launcher.app launched.
local okSnap, bootSnap = syscall("fb.snapshot")
if okSnap and bootSnap then
    local cx = math.floor((bootSnap.width + 1) / 2)
    local cy = math.floor((bootSnap.height + 1) / 2)
    local centerPix = bootSnap.pixelRows[cy]:sub(cx, cx)
    assert(centerPix == "0",
        "Expected centered white 'J' boot screen in pixelwise framebuffer before Launcher.app takes over rendering!")
end

local jvk = require("jvk")

local instance = jvk.createInstance({
    applicationInfo = {
        applicationName = "CC-jOS qLaunch",
        applicationVersion = "1.0.0",
        engineName = "libjvk"
    }
})

local physicalDevices = jvk.enumeratePhysicalDevices(instance)
local device = jvk.createDevice(physicalDevices[1])
local queue = device:getQueue()
local swapchain = jvk.createSwapchain(device)

local renderPass = jvk.createRenderPass(device, {
    loadOp = jvk.LOAD_OP_CLEAR,
    clearColor = jvk.COLORS.BLACK
})

local pipeline2D = jvk.createGraphicsPipeline(device, {
    bindPoint = jvk.PIPELINE_BIND_POINT_GRAPHICS_2D
})

local cmd = jvk.createCommandBuffer(device)

-- Pixel-art T-Rex icon (12x12) for the Dino.app square tile
local DINO_ICON_12X12 = {
    ".....111111.",
    "....11011111",
    "....11111111",
    "....11111000",
    "....1111111.",
    "1...111111..",
    "11.11111111.",
    ".11111111.1.",
    "..111111....",
    "...11.11....",
    "...1...1....",
    "...11..11..."
}

local function drawSprite(commandBuf, x0, y0, rows, color1, color0)
    for ry = 1, #rows do
        local rowStr = rows[ry]
        for rx = 1, #rowStr do
            local ch = rowStr:sub(rx, rx)
            if ch == "1" then
                commandBuf:drawPixel(x0 + rx - 1, y0 + ry - 1, color1)
            elseif ch == "0" and color0 then
                commandBuf:drawPixel(x0 + rx - 1, y0 + ry - 1, color0)
            end
        end
    end
end

local function buildSlots()
    local okApps, installed = syscall("app.list")
    local slots = {}
    if okApps and installed then
        local i = 1
        while installed[i] do
            local app = installed[i]
            slots[#slots + 1] = {
                id = app.id,
                name = app.name:upper(),
                path = app.path,
                empty = false
            }
            i = i + 1
        end
    end
    -- Pad with empty Switch-style game card slots so there are at least 3 centered squares
    while #slots < 3 do
        slots[#slots + 1] = {
            id = "empty." .. tostring(#slots + 1),
            name = "EMPTY SLOT",
            path = nil,
            empty = true
        }
    end
    return slots
end

local slots = buildSlots()
local selectedIndex = 1
local pulseTick = 0

local function renderQLaunch()
    local W = swapchain.width   -- 102
    local H = swapchain.height  -- 57

    cmd:begin()
    cmd:beginRenderPass({
        renderPass = renderPass,
        swapchain = swapchain
    })
    cmd:bindPipeline(pipeline2D)

    -- 1. Top Nintendo Switch Status Bar (y = 1..7)
    -- Switch Joy-Con red/cyan user badge on top-left
    cmd:drawRect(3, 2, 3, 5, jvk.COLORS.CYAN)
    cmd:drawRect(6, 2, 3, 5, jvk.COLORS.RED)
    cmd:drawText(12, 2, "CC-JOS", jvk.COLORS.WHITE)

    -- Top-right battery indicator
    cmd:drawText(W - 22, 2, "HOME", jvk.COLORS.LIGHT_GRAY)
    cmd:drawRect(W - 5, 2, 3, 5, jvk.COLORS.LIME)
    cmd:drawLine2D(1, 8, W, 8, jvk.COLORS.GRAY)

    -- 2. Selected App Title Centered Above the Row of Squares (y = 11)
    local activeSlot = slots[selectedIndex] or slots[1]
    local titleColor = activeSlot.empty and jvk.COLORS.GRAY or jvk.COLORS.CYAN
    cmd:drawTextCentered(11, activeSlot.name, titleColor, nil, 1, W, 1)

    -- 3. Horizontal Row of Square App Tiles Centered on Screen
    local numSlots = #slots
    local tileSize = 22 -- 22x22 square tiles
    local tileGap  = 6
    local totalRowW = numSlots * tileSize + (numSlots - 1) * tileGap
    local startX = math.floor((W - totalRowW) / 2) + 1
    local tileY  = math.floor((H - tileSize) / 2) + 1 -- y = 18..39 (centered vertically!)

    for i = 1, numSlots do
        local slot = slots[i]
        local tx = startX + (i - 1) * (tileSize + tileGap)
        local ty = tileY

        -- Iconic Nintendo Switch qLaunch pulsing cyan selection border around active square
        if i == selectedIndex then
            local selColor = (pulseTick % 2 == 0) and jvk.COLORS.CYAN or jvk.COLORS.LIGHT_BLUE
            cmd:drawBorderBox(tx - 2, ty - 2, tileSize + 4, tileSize + 4, selColor)
            cmd:drawBorderBox(tx - 1, ty - 1, tileSize + 2, tileSize + 2, selColor)
        end

        if slot.empty then
            -- Empty Switch game card slot
            cmd:drawRect(tx, ty, tileSize, tileSize, jvk.COLORS.GRAY)
            cmd:drawBorderBox(tx, ty, tileSize, tileSize, jvk.COLORS.LIGHT_GRAY)
            cmd:drawRect(tx + 8, ty + 8, 6, 6, jvk.COLORS.BLACK)
        else
            -- Filled App Tile Square (e.g. Dino.app)
            cmd:drawRect(tx, ty, tileSize, tileSize, jvk.COLORS.GRAY)
            cmd:drawBorderBox(tx, ty, tileSize, tileSize, jvk.COLORS.WHITE)
            -- Desert ground strip at bottom of tile
            cmd:drawRect(tx + 1, ty + tileSize - 4, tileSize - 2, 3, jvk.COLORS.YELLOW)
            -- Draw T-Rex pixel sprite centered inside the 22x22 square tile
            drawSprite(cmd, tx + 5, ty + 5, DINO_ICON_12X12, jvk.COLORS.LIME, jvk.COLORS.WHITE)
        end
    end

    -- 4. Bottom Switch System Bar & WASD Controls Prompt
    cmd:drawLine2D(1, H - 8, W, H - 8, jvk.COLORS.GRAY)
    cmd:drawTextCentered(H - 6, "A/D:SELECT  W:START", jvk.COLORS.WHITE, nil, 1, W, 1)

    cmd:endRenderPass()
    cmd:endRecording()

    jvk.queueSubmit(queue, cmd)
    jvk.queuePresent(queue, swapchain)
end

-- Initial render taking over from the BIOS "J" boot screen
renderQLaunch()

-- Main qLaunch Event Loop (WASD navigation + launching apps)
while true do
    local okEv, evType, p1 = syscall("event.wait", 0.25)
    if not okEv or not evType then
        break
    end

    if evType == "timer" then
        pulseTick = pulseTick + 1
        renderQLaunch()
    elseif evType == "key" then
        local key = tostring(p1 or ""):lower()
        if key == "a" then
            if selectedIndex > 1 then
                selectedIndex = selectedIndex - 1
            else
                selectedIndex = #slots
            end
            renderQLaunch()
        elseif key == "d" then
            if selectedIndex < #slots then
                selectedIndex = selectedIndex + 1
            else
                selectedIndex = 1
            end
            renderQLaunch()
        elseif key == "w" or key == "space" or key == "enter" then
            local chosen = slots[selectedIndex]
            if chosen and not chosen.empty and chosen.path then
                local okSpawn, childPid = syscall("process.spawn", chosen.path, {})
                if okSpawn and childPid then
                    syscall("process.wait", childPid)
                    slots = buildSlots()
                    renderQLaunch()
                end
            end
        end
    end
end

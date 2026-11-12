-- ============================================================================
-- CC-jOS Game: Dino.app (/System/Apps/Dino.app/main.lua)
-- Google Chrome Dino Recreation built with libjvk (Pixelwise 2x3 Sub-Pixels)
-- Controls (WASD preferred):
--   W / Space : Jump (or Retry on Game Over)
--   S         : Duck / Fast-Fall
--   A / D     : Move Left / Right
--   Q         : Quit back to qLaunch Home Menu (Launcher.app)
-- ============================================================================

local jvk = require("jvk")

local instance = jvk.createInstance({
    applicationInfo = {
        applicationName = "Chrome Dino",
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

-- ============================================================================
-- Pixel-Art Sprites (1 = primary color, 0 = eye/highlight color)
-- ============================================================================
local DINO_RUN_1 = {
    ".....111111.",
    "....11011111",
    "....11111111",
    "....11111...",
    "....1111111.",
    "1...111111..",
    "11.11111111.",
    ".11111111.1.",
    "..111111....",
    "...11.11....",
    "...11.......",
    "...111......"
}

local DINO_RUN_2 = {
    ".....111111.",
    "....11011111",
    "....11111111",
    "....11111...",
    "....1111111.",
    "1...111111..",
    "11.11111111.",
    ".11111111.1.",
    "..111111....",
    "...11.11....",
    "......11....",
    "......111..."
}

local DINO_JUMP = {
    ".....111111.",
    "....11011111",
    "....11111111",
    "....11111...",
    "....1111111.",
    "1...111111..",
    "11.11111111.",
    ".11111111.1.",
    "..111111....",
    "...11.11....",
    "...1...1....",
    "...11..11..."
}

local DINO_DUCK_1 = {
    ".......1111111.",
    "1.....110111111",
    "11..11111111111",
    ".11111111111...",
    "..11111111111..",
    "...1111111.1...",
    "....11..11.....",
    "....111........"
}

local DINO_DUCK_2 = {
    ".......1111111.",
    "1.....110111111",
    "11..11111111111",
    ".11111111111...",
    "..11111111111..",
    "...1111111.1...",
    "....11..11.....",
    "........111...."
}

local CACTUS_SMALL = {
    "..1..",
    "..1.1",
    "1.1.1",
    "1.111",
    "111..",
    "..1..",
    "..1..",
    "..1..",
    "..1.."
}

local CACTUS_TALL = {
    "...11...",
    "...11...",
    "1..11...",
    "1..11..1",
    "11.11..1",
    ".1111.11",
    "...1111.",
    "...11...",
    "...11...",
    "...11...",
    "...11...",
    "...11..."
}

local PTERO_1 = {
    "...1.......",
    "..11.......",
    ".1011..11..",
    "11111111111",
    "...111111..",
    "....11.....",
    ".....1....."
}

local PTERO_2 = {
    ".....1.....",
    "....11.....",
    ".10111111..",
    "11111111111",
    "...111111..",
    "..11.......",
    "...1......."
}

local CLOUD_SPRITE = {
    "..11111..",
    ".1111111.",
    "111111111"
}

local function drawSprite(commandBuf, x0, y0, rows, color1, color0)
    x0 = math.floor(x0 + 0.5)
    y0 = math.floor(y0 + 0.5)
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

-- ============================================================================
-- Game State & Physics Constants
-- ============================================================================
local W = swapchain.width   -- 102
local H = swapchain.height  -- 57
local GROUND_Y = 47

local highScore = 0
local score = 0
local gameOver = false
local tickCount = 0

local dinoX = 14
local dinoY = GROUND_Y - 12
local dinoVy = 0
local isGrounded = true
local duckTicks = 0
local gravity = 0.85
local jumpVelocity = -5.4

local speed = 2.2
local spawnCooldown = 22
local obstacles = {}
local clouds = {
    { x = 25, y = 12 },
    { x = 72, y = 17 }
}
local pebbles = { 8, 23, 41, 59, 77, 94 }

-- Simple deterministic pseudo-random generator for obstacle variety
local rngState = 1337
local function nextRand(minVal, maxVal)
    rngState = (rngState * 1103515245 + 12345) % 2147483648
    if not minVal then return rngState end
    return minVal + (rngState % (maxVal - minVal + 1))
end

local function resetGame()
    if score > highScore then
        highScore = score
    end
    score = 0
    gameOver = false
    tickCount = 0
    dinoX = 14
    dinoY = GROUND_Y - 12
    dinoVy = 0
    isGrounded = true
    duckTicks = 0
    speed = 2.2
    spawnCooldown = 20
    obstacles = {}
end

local function spawnObstacle()
    local kind = nextRand(1, 4)
    if kind == 1 then
        obstacles[#obstacles + 1] = {
            type = "cactus_small",
            x = W + 2,
            y = GROUND_Y - 9,
            w = 5,
            h = 9
        }
    elseif kind == 2 then
        obstacles[#obstacles + 1] = {
            type = "cactus_tall",
            x = W + 2,
            y = GROUND_Y - 12,
            w = 8,
            h = 12
        }
    else
        -- Flying Pterodactyl (either mid-height where S-ducking dodges it, or low)
        local flyY = (kind == 3) and (GROUND_Y - 16) or (GROUND_Y - 11)
        obstacles[#obstacles + 1] = {
            type = "ptero",
            x = W + 2,
            y = flyY,
            w = 11,
            h = 7
        }
    end
end

local function checkCollision(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and
           ax + aw > bx and
           ay < by + bh and
           ay + ah > by
end

local function stepPhysics()
    if gameOver then return end

    tickCount = tickCount + 1
    score = math.floor(tickCount / 2)
    if score > highScore then
        highScore = score
    end
    speed = math.min(4.8, 2.2 + score * 0.008)

    if duckTicks > 0 then
        duckTicks = duckTicks - 1
    end

    -- Dino vertical physics
    local isDucking = isGrounded and (duckTicks > 0)
    local dinoH = isDucking and 8 or 12
    local dinoW = isDucking and 15 or 12

    if not isGrounded then
        dinoY = dinoY + dinoVy
        dinoVy = dinoVy + gravity
        if dinoY >= GROUND_Y - 12 then
            dinoY = GROUND_Y - 12
            dinoVy = 0
            isGrounded = true
        end
    else
        dinoY = GROUND_Y - dinoH
    end

    -- Scroll clouds
    for i = 1, #clouds do
        clouds[i].x = clouds[i].x - speed * 0.25
        if clouds[i].x < -10 then
            clouds[i].x = W + nextRand(4, 20)
            clouds[i].y = nextRand(10, 20)
        end
    end

    -- Scroll ground pebbles
    for i = 1, #pebbles do
        pebbles[i] = pebbles[i] - speed
        if pebbles[i] < 1 then
            pebbles[i] = W + nextRand(1, 12)
        end
    end

    -- Spawn & move obstacles
    spawnCooldown = spawnCooldown - 1
    if spawnCooldown <= 0 then
        spawnObstacle()
        spawnCooldown = nextRand(16, 30)
    end

    -- Hitbox slightly inset by 2px for fair Chrome Dino feel
    local hx = dinoX + 2
    local hy = dinoY + 1
    local hw = dinoW - 4
    local hh = dinoH - 2

    for i = #obstacles, 1, -1 do
        local obs = obstacles[i]
        obs.x = obs.x - speed
        if checkCollision(hx, hy, hw, hh, obs.x + 1, obs.y + 1, obs.w - 2, obs.h - 2) then
            gameOver = true
        end
        if obs.x + obs.w < -2 then
            table.remove(obstacles, i)
        end
    end
end

local function renderGame()
    cmd:begin()
    cmd:beginRenderPass({
        renderPass = renderPass,
        swapchain = swapchain
    })
    cmd:bindPipeline(pipeline2D)

    -- 1. Top HUD Bar (Score, High Score, Controls)
    cmd:drawText(3, 2, "DINO", jvk.COLORS.LIME)
    local scoreStr = string.format("HI %04d  %04d", highScore, score)
    cmd:drawText(W - jvk.measureText(scoreStr, 1) - 2, 2, scoreStr, jvk.COLORS.WHITE)
    cmd:drawLine2D(1, 8, W, 8, jvk.COLORS.GRAY)

    -- 2. Clouds
    for i = 1, #clouds do
        drawSprite(cmd, clouds[i].x, clouds[i].y, CLOUD_SPRITE, jvk.COLORS.GRAY)
    end

    -- 3. Ground Horizon & Pebbles
    cmd:drawLine2D(1, GROUND_Y, W, GROUND_Y, jvk.COLORS.LIGHT_GRAY)
    for i = 1, #pebbles do
        local px = math.floor(pebbles[i])
        cmd:drawPixel(px, GROUND_Y + 2, jvk.COLORS.GRAY)
        cmd:drawPixel(px + 1, GROUND_Y + 3, jvk.COLORS.GRAY)
    end

    -- 4. Obstacles (Cacti & Pterodactyls)
    for i = 1, #obstacles do
        local obs = obstacles[i]
        if obs.type == "cactus_small" then
            drawSprite(cmd, obs.x, obs.y, CACTUS_SMALL, jvk.COLORS.GREEN)
        elseif obs.type == "cactus_tall" then
            drawSprite(cmd, obs.x, obs.y, CACTUS_TALL, jvk.COLORS.GREEN)
        elseif obs.type == "ptero" then
            local pSprite = (math.floor(tickCount / 3) % 2 == 0) and PTERO_1 or PTERO_2
            drawSprite(cmd, obs.x, obs.y, pSprite, jvk.COLORS.ORANGE, jvk.COLORS.WHITE)
        end
    end

    -- 5. Dino Player Sprite
    local isDucking = isGrounded and (duckTicks > 0)
    local dinoSprite
    if not isGrounded then
        dinoSprite = DINO_JUMP
    elseif isDucking then
        dinoSprite = (math.floor(tickCount / 2) % 2 == 0) and DINO_DUCK_1 or DINO_DUCK_2
    else
        dinoSprite = (math.floor(tickCount / 2) % 2 == 0) and DINO_RUN_1 or DINO_RUN_2
    end
    local dinoColor = gameOver and jvk.COLORS.RED or jvk.COLORS.LIME
    drawSprite(cmd, dinoX, dinoY, dinoSprite, dinoColor, jvk.COLORS.WHITE)

    -- 6. Game Over Overlay or Bottom WASD Controls Bar
    if gameOver then
        cmd:uiPanel({
            x = 18,
            y = 15,
            w = W - 36,
            h = 22,
            borderColor = jvk.COLORS.RED,
            bg = jvk.COLORS.BLACK
        })
        cmd:drawTextCentered(18, "GAME OVER", jvk.COLORS.RED, nil, 18, W - 36, 1)
        cmd:drawTextCentered(27, "W:RETRY  Q:HOME", jvk.COLORS.WHITE, nil, 18, W - 36, 1)
    end

    cmd:drawTextCentered(H - 5, "W:JUMP S:DUCK Q:HOME", jvk.COLORS.GRAY, nil, 1, W, 1)

    cmd:endRenderPass()
    cmd:endRecording()

    jvk.queueSubmit(queue, cmd)
    jvk.queuePresent(queue, swapchain)
end

-- Initial frame render
renderGame()

-- Main 20 FPS Game Loop
while true do
    local okEv, evType, p1 = syscall("event.wait", 0.05)
    if not okEv or not evType then
        break
    end

    if evType == "timer" then
        stepPhysics()
        renderGame()
    elseif evType == "key" then
        local key = tostring(p1 or ""):lower()
        if key == "q" then
            -- Return to qLaunch Home Menu (Launcher.app)
            break
        elseif key == "w" or key == "space" then
            if gameOver then
                resetGame()
                renderGame()
            elseif isGrounded then
                isGrounded = false
                duckTicks = 0
                dinoVy = jumpVelocity
                dinoY = GROUND_Y - 12
            end
        elseif key == "s" then
            if not gameOver then
                if not isGrounded then
                    -- Fast-fall when S is pressed in mid-air
                    dinoVy = math.max(dinoVy, 3.6)
                else
                    -- Duck / crouch on ground
                    duckTicks = 8
                end
            end
        elseif key == "a" then
            if not gameOver then
                dinoX = math.max(6, dinoX - 3)
            end
        elseif key == "d" then
            if not gameOver then
                dinoX = math.min(34, dinoX + 3)
            end
        end
    elseif evType == "key_up" then
        local key = tostring(p1 or ""):lower()
        if key == "s" then
            duckTicks = 0
        end
    end
end

-- ============================================================================
-- CC-jOS Graphics & UI Library: libjvk (/System/Libraries/jvk.lua)
-- Vulkan-Style 2D & 3D Rendering & UI Toolkit for CC-jOS Userspace Apps
-- Communicates exclusively with the Kernel Framebuffer via syscall("fb.*")
-- ============================================================================

local jvk = {
    API_VERSION = "1.0.0",
    VK_SUCCESS = 0,
    PIPELINE_BIND_POINT_GRAPHICS_2D = "GRAPHICS_2D",
    PIPELINE_BIND_POINT_GRAPHICS_3D = "GRAPHICS_3D",
    POLYGON_MODE_FILL = "FILL",
    POLYGON_MODE_LINE = "LINE",
    POLYGON_MODE_POINT = "POINT",
    CULL_MODE_NONE = "NONE",
    CULL_MODE_BACK = "BACK",
    LOAD_OP_CLEAR = "CLEAR",
    LOAD_OP_LOAD = "LOAD"
}

-- Standard CC:Tweaked 16-Color Palette (Hex Blit Codes)
jvk.COLORS = {
    WHITE = "0",
    ORANGE = "1",
    MAGENTA = "2",
    LIGHT_BLUE = "3",
    YELLOW = "4",
    LIME = "5",
    PINK = "6",
    GRAY = "7",
    LIGHT_GRAY = "8",
    CYAN = "9",
    PURPLE = "a",
    BLUE = "b",
    BROWN = "c",
    GREEN = "d",
    RED = "e",
    BLACK = "f"
}

local COLOR_MAP = {
    white = "0", orange = "1", magenta = "2", lightBlue = "3",
    yellow = "4", lime = "5", pink = "6", gray = "7", grey = "7",
    lightGray = "8", lightGrey = "8", cyan = "9", purple = "a",
    blue = "b", brown = "c", green = "d", red = "e", black = "f",
    [1] = "0", [2] = "1", [4] = "2", [8] = "3",
    [16] = "4", [32] = "5", [64] = "6", [128] = "7",
    [256] = "8", [512] = "9", [1024] = "a", [2048] = "b",
    [4096] = "c", [8192] = "d", [16384] = "e", [32768] = "f"
}

local function normColor(col, fallback)
    fallback = fallback or "0"
    if col == nil then return fallback end
    if type(col) == "string" and #col == 1 and col:match("^[0-9a-fA-F]$") then
        return col:lower()
    end
    return COLOR_MAP[col] or fallback
end

-- ============================================================================
-- 1. 3D Vector & 4x4 Matrix Math (jvk.vec3, jvk.mat4)
-- ============================================================================
local vec3 = {}

function vec3.new(x, y, z)
    return { x = tonumber(x) or 0, y = tonumber(y) or 0, z = tonumber(z) or 0 }
end

function vec3.add(a, b)
    return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function vec3.sub(a, b)
    return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function vec3.scale(v, s)
    return { x = v.x * s, y = v.y * s, z = v.z * s }
end

function vec3.dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

function vec3.cross(a, b)
    return {
        x = a.y * b.z - a.z * b.y,
        y = a.z * b.x - a.x * b.z,
        z = a.x * b.y - a.y * b.x
    }
end

function vec3.length(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

function vec3.normalize(v)
    local len = vec3.length(v)
    if len <= 1e-8 then return { x = 0, y = 0, z = 0 } end
    return { x = v.x / len, y = v.y / len, z = v.z / len }
end

jvk.vec3 = vec3

-- Row-major 4x4 Matrices (array of 16 numbers)
local mat4 = {}

function mat4.identity()
    return {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    }
end

function mat4.mul(a, b)
    local out = {}
    for r = 0, 3 do
        for c = 0, 3 do
            out[r * 4 + c + 1] =
                a[r * 4 + 1] * b[0 * 4 + c + 1] +
                a[r * 4 + 2] * b[1 * 4 + c + 1] +
                a[r * 4 + 3] * b[2 * 4 + c + 1] +
                a[r * 4 + 4] * b[3 * 4 + c + 1]
        end
    end
    return out
end

function mat4.translation(tx, ty, tz)
    return {
        1, 0, 0, tx or 0,
        0, 1, 0, ty or 0,
        0, 0, 1, tz or 0,
        0, 0, 0, 1
    }
end

function mat4.scaling(sx, sy, sz)
    return {
        sx or 1, 0, 0, 0,
        0, sy or 1, 0, 0,
        0, 0, sz or 1, 0,
        0, 0, 0, 1
    }
end

function mat4.rotationX(rad)
    local c, s = math.cos(rad), math.sin(rad)
    return {
        1, 0,  0, 0,
        0, c, -s, 0,
        0, s,  c, 0,
        0, 0,  0, 1
    }
end

function mat4.rotationY(rad)
    local c, s = math.cos(rad), math.sin(rad)
    return {
         c, 0, s, 0,
         0, 1, 0, 0,
        -s, 0, c, 0,
         0, 0, 0, 1
    }
end

function mat4.rotationZ(rad)
    local c, s = math.cos(rad), math.sin(rad)
    return {
        c, -s, 0, 0,
        s,  c, 0, 0,
        0,  0, 1, 0,
        0,  0, 0, 1
    }
end

function mat4.perspective(fovRad, aspect, near, far)
    fovRad = fovRad or (math.pi / 3)
    aspect = (aspect and aspect > 0) and aspect or 1.5
    near = near or 0.1
    far = far or 100.0
    local f = 1.0 / math.tan(fovRad * 0.5)
    local nf = 1.0 / (near - far)
    return {
        f / aspect, 0, 0, 0,
        0, f, 0, 0,
        0, 0, (far + near) * nf, (2 * far * near) * nf,
        0, 0, -1, 0
    }
end

function mat4.lookAt(eye, center, up)
    local f = vec3.normalize(vec3.sub(center, eye))
    local s = vec3.normalize(vec3.cross(f, up))
    local u = vec3.cross(s, f)
    return {
         s.x,  s.y,  s.z, -vec3.dot(s, eye),
         u.x,  u.y,  u.z, -vec3.dot(u, eye),
        -f.x, -f.y, -f.z,  vec3.dot(f, eye),
           0,    0,    0,  1
    }
end

function mat4.transformVec3(m, v)
    local x, y, z = v.x, v.y, v.z
    local cx = m[1] * x + m[2] * y + m[3] * z + m[4]
    local cy = m[5] * x + m[6] * y + m[7] * z + m[8]
    local cz = m[9] * x + m[10] * y + m[11] * z + m[12]
    local cw = m[13] * x + m[14] * y + m[15] * z + m[16]
    return cx, cy, cz, cw
end

jvk.mat4 = mat4

-- ============================================================================
-- 2. Built-in 3D Mesh Generators (jvk.mesh)
-- ============================================================================
local mesh = {}

function mesh.cube(size)
    local h = (size or 2.0) * 0.5
    local verts = {
        { x = -h, y = -h, z = -h }, -- 1
        { x =  h, y = -h, z = -h }, -- 2
        { x =  h, y =  h, z = -h }, -- 3
        { x = -h, y =  h, z = -h }, -- 4
        { x = -h, y = -h, z =  h }, -- 5
        { x =  h, y = -h, z =  h }, -- 6
        { x =  h, y =  h, z =  h }, -- 7
        { x = -h, y =  h, z =  h }  -- 8
    }
    local edges = {
        { 1, 2, "9" }, { 2, 3, "9" }, { 3, 4, "9" }, { 4, 1, "9" },
        { 5, 6, "3" }, { 6, 7, "3" }, { 7, 8, "3" }, { 8, 5, "3" },
        { 1, 5, "0" }, { 2, 6, "0" }, { 3, 7, "0" }, { 4, 8, "0" }
    }
    local triangles = {
        { 5, 6, 7, "3", "#" }, { 5, 7, 8, "3", "#" }, -- Front
        { 2, 1, 4, "b", ":" }, { 2, 4, 3, "b", ":" }, -- Back
        { 4, 8, 7, "9", "+" }, { 4, 7, 3, "9", "+" }, -- Top
        { 1, 2, 6, "7", "." }, { 1, 6, 5, "7", "." }, -- Bottom
        { 6, 2, 3, "5", "*" }, { 6, 3, 7, "5", "*" }, -- Right
        { 1, 5, 8, "a", "=" }, { 1, 8, 4, "a", "=" }  -- Left
    }
    return { vertices = verts, edges = edges, triangles = triangles }
end

function mesh.pyramid(size)
    local h = (size or 2.0) * 0.5
    local verts = {
        { x =  0, y =  h, z =  0 }, -- 1: Apex
        { x = -h, y = -h, z = -h }, -- 2
        { x =  h, y = -h, z = -h }, -- 3
        { x =  h, y = -h, z =  h }, -- 4
        { x = -h, y = -h, z =  h }  -- 5
    }
    local edges = {
        { 1, 2, "4" }, { 1, 3, "4" }, { 1, 4, "4" }, { 1, 5, "4" },
        { 2, 3, "1" }, { 3, 4, "1" }, { 4, 5, "1" }, { 5, 2, "1" }
    }
    local triangles = {
        { 1, 5, 4, "4", "^" },
        { 1, 4, 3, "1", "/" },
        { 1, 3, 2, "e", "+" },
        { 1, 2, 5, "6", "*" }
    }
    return { vertices = verts, edges = edges, triangles = triangles }
end

jvk.mesh = mesh

-- ============================================================================
-- 3. Vulkan-Style Instance, PhysicalDevice, Device, Swapchain & Pipeline
-- ============================================================================
function jvk.createInstance(createInfo)
    createInfo = createInfo or {}
    local appInfo = createInfo.applicationInfo or {}
    return {
        _type = "VkInstance",
        applicationName = appInfo.applicationName or "CC-jOS-App",
        applicationVersion = appInfo.applicationVersion or "1.0.0",
        engineName = appInfo.engineName or "jvk",
        apiVersion = jvk.API_VERSION
    }
end

function jvk.enumeratePhysicalDevices(instance)
    assert(type(instance) == "table" and instance._type == "VkInstance", "jvk.enumeratePhysicalDevices: invalid VkInstance")
    local ok, fbInfo = syscall("fb.info")
    if not ok or not fbInfo then
        error("jvk.enumeratePhysicalDevices: failed to query kernel framebuffer (" .. tostring(fbInfo) .. ")", 2)
    end
    return {
        {
            _type = "VkPhysicalDevice",
            name = "CC-jOS BIOS Framebuffer Adapter",
            width = fbInfo.width,
            height = fbInfo.height,
            isColor = fbInfo.isColor
        }
    }
end

function jvk.createDevice(physicalDevice, deviceCreateInfo)
    if type(physicalDevice) == "table" and physicalDevice._type == "VkInstance" then
        -- Convenience overload: allow passing VkInstance directly
        local devs = jvk.enumeratePhysicalDevices(physicalDevice)
        physicalDevice = devs[1]
    end
    assert(type(physicalDevice) == "table" and physicalDevice._type == "VkPhysicalDevice",
        "jvk.createDevice: expected VkPhysicalDevice")

    local queue = {
        _type = "VkQueue",
        familyIndex = 0
    }
    local device = {
        _type = "VkDevice",
        physicalDevice = physicalDevice,
        width = physicalDevice.width,
        height = physicalDevice.height,
        queue = queue,
        createInfo = deviceCreateInfo or {},
        getQueue = function(self) return self.queue end
    }
    queue.device = device
    return device
end

function jvk.createSwapchain(device, swapchainCreateInfo)
    assert(type(device) == "table" and device._type == "VkDevice", "jvk.createSwapchain: expected VkDevice")
    swapchainCreateInfo = swapchainCreateInfo or {}
    local w = swapchainCreateInfo.width or device.width
    local h = swapchainCreateInfo.height or device.height

    local chars, fg, bg, depth = {}, {}, {}, {}
    for y = 1, h do
        chars[y], fg[y], bg[y], depth[y] = {}, {}, {}, {}
        for x = 1, w do
            chars[y][x] = " "
            fg[y][x] = "0"
            bg[y][x] = "f"
            depth[y][x] = 1e9
        end
    end

    return {
        _type = "VkSwapchainKHR",
        device = device,
        width = w,
        height = h,
        chars = chars,
        fg = fg,
        bg = bg,
        depth = depth
    }
end

function jvk.createRenderPass(device, renderPassInfo)
    assert(type(device) == "table" and device._type == "VkDevice", "jvk.createRenderPass: expected VkDevice")
    renderPassInfo = renderPassInfo or {}
    return {
        _type = "VkRenderPass",
        loadOp = renderPassInfo.loadOp or jvk.LOAD_OP_CLEAR,
        clearColor = normColor(renderPassInfo.clearColor, "f"),
        clearTextColor = normColor(renderPassInfo.clearTextColor, "0"),
        clearChar = (type(renderPassInfo.clearChar) == "string" and #renderPassInfo.clearChar > 0)
            and renderPassInfo.clearChar:sub(1, 1) or " ",
        clearDepth = tonumber(renderPassInfo.clearDepth) or 1e9
    }
end

function jvk.createGraphicsPipeline(device, pipelineInfo)
    assert(type(device) == "table" and device._type == "VkDevice", "jvk.createGraphicsPipeline: expected VkDevice")
    pipelineInfo = pipelineInfo or {}
    return {
        _type = "VkPipeline",
        bindPoint = pipelineInfo.bindPoint or jvk.PIPELINE_BIND_POINT_GRAPHICS_2D,
        polygonMode = pipelineInfo.polygonMode or jvk.POLYGON_MODE_LINE,
        cullMode = pipelineInfo.cullMode or jvk.CULL_MODE_NONE,
        depthTestEnable = (pipelineInfo.depthTestEnable ~= false),
        defaultFg = normColor(pipelineInfo.defaultFg, "0"),
        defaultBg = normColor(pipelineInfo.defaultBg, "f")
    }
end

-- ============================================================================
-- 4. Software Rasterizer Helpers (2D & 3D Depth-Tested Rasterization)
-- ============================================================================
local function putPixel(sc, x, y, ch, fgCol, bgCol, z, depthTest)
    x = math.floor(x + 0.5)
    y = math.floor(y + 0.5)
    if x < 1 or x > sc.width or y < 1 or y > sc.height then
        return
    end
    if depthTest and z ~= nil then
        if z > sc.depth[y][x] then
            return
        end
        sc.depth[y][x] = z
    end
    if ch ~= nil and #tostring(ch) > 0 then
        sc.chars[y][x] = tostring(ch):sub(1, 1)
    end
    if fgCol ~= nil then
        sc.fg[y][x] = normColor(fgCol, sc.fg[y][x])
    end
    if bgCol ~= nil then
        sc.bg[y][x] = normColor(bgCol, sc.bg[y][x])
    end
end

local function rasterizeLine(sc, x0, y0, z0, x1, y1, z1, ch, fgCol, bgCol, depthTest, clipRect)
    x0, y0 = math.floor(x0 + 0.5), math.floor(y0 + 0.5)
    x1, y1 = math.floor(x1 + 0.5), math.floor(y1 + 0.5)
    local dx = math.abs(x1 - x0)
    local dy = -math.abs(y1 - y0)
    local sx = (x0 < x1) and 1 or -1
    local sy = (y0 < y1) and 1 or -1
    local err = dx + dy
    local steps = math.max(dx, -dy, 1)
    local stepIdx = 0

    while true do
        local t = stepIdx / steps
        local z = z0 + (z1 - z0) * t
        local insideClip = true
        if clipRect then
            if x0 < clipRect.x or x0 >= clipRect.x + clipRect.w or
               y0 < clipRect.y or y0 >= clipRect.y + clipRect.h then
                insideClip = false
            end
        end
        if insideClip then
            putPixel(sc, x0, y0, ch, fgCol, bgCol, z, depthTest)
        end
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then
            err = err + dy
            x0 = x0 + sx
        end
        if e2 <= dx then
            err = err + dx
            y0 = y0 + sy
        end
        stepIdx = stepIdx + 1
        if stepIdx > 1024 then break end
    end
end

local function edgeFunc(ax, ay, bx, by, px, py)
    return (px - ax) * (by - ay) - (py - ay) * (bx - ax)
end

local function rasterizeTriangleFilled(sc, p0, p1, p2, ch, fgCol, bgCol, depthTest, clipRect)
    local minX = math.max(1, math.floor(math.min(p0.x, p1.x, p2.x)))
    local maxX = math.min(sc.width, math.ceil(math.max(p0.x, p1.x, p2.x)))
    local minY = math.max(1, math.floor(math.min(p0.y, p1.y, p2.y)))
    local maxY = math.min(sc.height, math.ceil(math.max(p0.y, p1.y, p2.y)))

    if clipRect then
        minX = math.max(minX, clipRect.x)
        maxX = math.min(maxX, clipRect.x + clipRect.w - 1)
        minY = math.max(minY, clipRect.y)
        maxY = math.min(maxY, clipRect.y + clipRect.h - 1)
    end

    local area = edgeFunc(p0.x, p0.y, p1.x, p1.y, p2.x, p2.y)
    if math.abs(area) < 1e-5 then return end

    for y = minY, maxY do
        for x = minX, maxX do
            local px, py = x + 0.5, y + 0.5
            local w0 = edgeFunc(p1.x, p1.y, p2.x, p2.y, px, py) / area
            local w1 = edgeFunc(p2.x, p2.y, p0.x, p0.y, px, py) / area
            local w2 = edgeFunc(p0.x, p0.y, p1.x, p1.y, px, py) / area
            if w0 >= -1e-4 and w1 >= -1e-4 and w2 >= -1e-4 then
                local z = w0 * p0.z + w1 * p1.z + w2 * p2.z
                putPixel(sc, x, y, ch, fgCol, bgCol, z, depthTest)
            end
        end
    end
end

local function projectVertex(mvp, viewport, v)
    local cx, cy, cz, cw = mat4.transformVec3(mvp, v)
    if cw <= 0.05 then
        return nil
    end
    local ndcX = cx / cw
    local ndcY = cy / cw
    local ndcZ = cz / cw
    local sx = viewport.x + (ndcX + 1.0) * 0.5 * (viewport.width - 1)
    local sy = viewport.y + (1.0 - (ndcY + 1.0) * 0.5) * (viewport.height - 1)
    return { x = sx, y = sy, z = ndcZ, w = cw }
end

-- ============================================================================
-- 5. Command Buffer Creation & Recording (VkCommandBuffer)
-- ============================================================================
function jvk.createCommandBuffer(device)
    assert(type(device) == "table" and device._type == "VkDevice", "jvk.createCommandBuffer: expected VkDevice")

    local cmd = {
        _type = "VkCommandBuffer",
        device = device,
        state = "INITIAL",
        ops = {}
    }

    function cmd:reset()
        self.ops = {}
        self.state = "INITIAL"
        return self
    end

    function cmd:begin()
        self.ops = {}
        self.state = "RECORDING"
        return self
    end

    function cmd:beginRenderPass(beginInfo)
        assert(self.state == "RECORDING", "VkCommandBuffer must be in RECORDING state")
        assert(type(beginInfo) == "table" and beginInfo.renderPass and beginInfo.swapchain,
            "cmd:beginRenderPass requires { renderPass = ..., swapchain = ... }")
        self.ops[#self.ops + 1] = {
            type = "BEGIN_RENDER_PASS",
            renderPass = beginInfo.renderPass,
            swapchain = beginInfo.swapchain
        }
        return self
    end

    function cmd:bindPipeline(pipeline)
        assert(self.state == "RECORDING", "VkCommandBuffer must be in RECORDING state")
        self.ops[#self.ops + 1] = {
            type = "BIND_PIPELINE",
            pipeline = pipeline
        }
        return self
    end

    function cmd:setViewport(viewport)
        assert(self.state == "RECORDING", "VkCommandBuffer must be in RECORDING state")
        self.ops[#self.ops + 1] = {
            type = "SET_VIEWPORT",
            viewport = {
                x = viewport.x or 1,
                y = viewport.y or 1,
                width = viewport.width or viewport.w or self.device.width,
                height = viewport.height or viewport.h or self.device.height
            }
        }
        return self
    end

    function cmd:pushConstants(constants)
        assert(self.state == "RECORDING", "VkCommandBuffer must be in RECORDING state")
        self.ops[#self.ops + 1] = {
            type = "PUSH_CONSTANTS",
            constants = constants or {}
        }
        return self
    end

    -- ------------------------------------------------------------------------
    -- 2D Primitives
    -- ------------------------------------------------------------------------
    function cmd:drawPixel(x, y, fgColor, bgColor, char)
        self.ops[#self.ops + 1] = {
            type = "DRAW_PIXEL",
            x = x, y = y, fg = fgColor, bg = bgColor, char = char or " "
        }
        return self
    end

    function cmd:drawLine2D(x0, y0, x1, y1, fgColor, bgColor, char)
        self.ops[#self.ops + 1] = {
            type = "DRAW_LINE_2D",
            x0 = x0, y0 = y0, x1 = x1, y1 = y1,
            fg = fgColor, bg = bgColor, char = char or "*"
        }
        return self
    end

    function cmd:drawRect(x, y, w, h, bgColor, fgColor, char)
        self.ops[#self.ops + 1] = {
            type = "DRAW_RECT",
            x = x, y = y, w = w, h = h,
            bg = bgColor, fg = fgColor, char = char or " "
        }
        return self
    end

    function cmd:drawBorderBox(x, y, w, h, borderColor, bgColor, title, titleColor)
        self.ops[#self.ops + 1] = {
            type = "DRAW_BORDER_BOX",
            x = x, y = y, w = w, h = h,
            borderColor = borderColor, bg = bgColor,
            title = title, titleColor = titleColor
        }
        return self
    end

    function cmd:drawText(x, y, text, fgColor, bgColor)
        self.ops[#self.ops + 1] = {
            type = "DRAW_TEXT",
            x = x, y = y, text = tostring(text or ""),
            fg = fgColor, bg = bgColor
        }
        return self
    end

    function cmd:drawTextCentered(y, text, fgColor, bgColor, regionX, regionW)
        text = tostring(text or "")
        regionX = regionX or 1
        regionW = regionW or self.device.width
        local x = regionX + math.max(0, math.floor((regionW - #text) / 2))
        return self:drawText(x, y, text, fgColor, bgColor)
    end

    -- ------------------------------------------------------------------------
    -- 2D UI Toolkit Commands
    -- ------------------------------------------------------------------------
    function cmd:uiWindow(spec)
        local x = spec.x or 1
        local y = spec.y or 1
        local w = spec.w or self.device.width
        local h = spec.h or self.device.height
        local bodyBg = spec.bodyColor or spec.bg or "f"
        local headerBg = spec.headerColor or "b"
        local titleFg = spec.titleColor or "0"
        local borderFg = spec.borderColor or "8"

        self:drawRect(x, y, w, h, bodyBg, "0", " ")
        self:drawBorderBox(x, y, w, h, borderFg, bodyBg)
        self:drawRect(x, y, w, 1, headerBg, titleFg, " ")
        if spec.title then
            self:drawTextCentered(y, " " .. tostring(spec.title) .. " ", titleFg, headerBg, x, w)
        end
        return self
    end

    function cmd:uiPanel(spec)
        local x, y = spec.x or 1, spec.y or 1
        local w, h = spec.w or 10, spec.h or 5
        local bg = spec.bg or "7"
        local border = spec.borderColor or "8"
        self:drawRect(x, y, w, h, bg, "0", " ")
        if spec.border ~= false then
            self:drawBorderBox(x, y, w, h, border, bg, spec.title, spec.titleColor or "0")
        end
        return self
    end

    function cmd:uiLabel(spec)
        local x, y = spec.x or 1, spec.y or 1
        local text = tostring(spec.text or "")
        local fg = spec.fg or "0"
        local bg = spec.bg
        if spec.align == "center" and spec.w then
            return self:drawTextCentered(y, text, fg, bg, x, spec.w)
        elseif spec.align == "right" and spec.w then
            local rx = x + math.max(0, spec.w - #text)
            return self:drawText(rx, y, text, fg, bg)
        end
        return self:drawText(x, y, text, fg, bg)
    end

    function cmd:uiButton(spec)
        local x, y = spec.x or 1, spec.y or 1
        local label = tostring(spec.label or "Button")
        local w = spec.w or (#label + 4)
        local h = spec.h or 1
        local bg = spec.active and (spec.activeBg or "5") or (spec.bg or "9")
        local fg = spec.fg or "f"
        self:drawRect(x, y, w, h, bg, fg, " ")
        local ty = y + math.floor((h - 1) / 2)
        self:drawTextCentered(ty, "[" .. label .. "]", fg, bg, x, w)
        return self
    end

    function cmd:uiProgressBar(spec)
        local x, y = spec.x or 1, spec.y or 1
        local w = spec.w or 20
        local progress = math.max(0, math.min(1, tonumber(spec.progress) or 0))
        local filled = math.floor(w * progress + 0.5)
        local fillBg = spec.fillBg or "5"
        local emptyBg = spec.emptyBg or "7"
        if filled > 0 then
            self:drawRect(x, y, filled, 1, fillBg, "0", " ")
        end
        if filled < w then
            self:drawRect(x + filled, y, w - filled, 1, emptyBg, "0", " ")
        end
        if spec.label then
            self:drawTextCentered(y, tostring(spec.label), spec.fg or "0", nil, x, w)
        end
        return self
    end

    -- ------------------------------------------------------------------------
    -- 3D Rendering & 3D UI Viewport Commands
    -- ------------------------------------------------------------------------
    function cmd:drawLine3D(v0, v1, fgColor, bgColor, char)
        self.ops[#self.ops + 1] = {
            type = "DRAW_LINE_3D",
            v0 = v0, v1 = v1,
            fg = fgColor, bg = bgColor, char = char or "*"
        }
        return self
    end

    function cmd:drawTriangle3D(v0, v1, v2, fgColor, bgColor, char)
        self.ops[#self.ops + 1] = {
            type = "DRAW_TRIANGLE_3D",
            v0 = v0, v1 = v1, v2 = v2,
            fg = fgColor, bg = bgColor, char = char or "#"
        }
        return self
    end

    function cmd:drawMesh(meshObj, opts)
        self.ops[#self.ops + 1] = {
            type = "DRAW_MESH_3D",
            mesh = meshObj,
            opts = opts or {}
        }
        return self
    end

    function cmd:uiViewport3D(spec)
        local x, y = spec.x or 1, spec.y or 1
        local w, h = spec.w or 20, spec.h or 10
        local bg = spec.bg or "f"
        local border = spec.borderColor or "9"
        self:drawRect(x, y, w, h, bg, "0", " ")
        self:drawBorderBox(x, y, w, h, border, bg, spec.title, spec.titleColor or "0")

        local innerX, innerY = x + 1, y + 1
        local innerW, innerH = math.max(1, w - 2), math.max(1, h - 2)
        self:setViewport({ x = innerX, y = innerY, width = innerW, height = innerH })
        if type(spec.render) == "function" then
            local aspect = (innerW / math.max(1, innerH)) * 0.65
            spec.render(self, aspect, innerW, innerH)
        end
        self:setViewport({ x = 1, y = 1, width = self.device.width, height = self.device.height })
        return self
    end

    function cmd:endRenderPass()
        assert(self.state == "RECORDING", "VkCommandBuffer must be in RECORDING state")
        self.ops[#self.ops + 1] = { type = "END_RENDER_PASS" }
        return self
    end

    function cmd:endRecording()
        assert(self.state == "RECORDING", "VkCommandBuffer must be in RECORDING state")
        self.state = "EXECUTABLE"
        return self
    end

    cmd.finish = cmd.endRecording
    return cmd
end

-- ============================================================================
-- 6. Queue Submission & Presentation (jvk.queueSubmit & jvk.queuePresent)
-- ============================================================================
local function executeCommandBuffer(cmd)
    assert(type(cmd) == "table" and cmd._type == "VkCommandBuffer", "Expected VkCommandBuffer")
    assert(cmd.state == "EXECUTABLE", "VkCommandBuffer must be ended via cmd:endRecording() before submission")

    local activeSwapchain = nil
    local activePipeline = {
        bindPoint = jvk.PIPELINE_BIND_POINT_GRAPHICS_2D,
        polygonMode = jvk.POLYGON_MODE_LINE,
        cullMode = jvk.CULL_MODE_NONE,
        depthTestEnable = true
    }
    local activeViewport = {
        x = 1, y = 1,
        width = cmd.device.width,
        height = cmd.device.height
    }
    local pushConst = {
        mvp = mat4.identity(),
        fg = "0",
        bg = nil,
        char = "*"
    }

    for i = 1, #cmd.ops do
        local op = cmd.ops[i]
        local t = op.type

        if t == "BEGIN_RENDER_PASS" then
            activeSwapchain = op.swapchain
            local rp = op.renderPass
            if rp.loadOp == jvk.LOAD_OP_CLEAR then
                for y = 1, activeSwapchain.height do
                    local cRow = activeSwapchain.chars[y]
                    local fRow = activeSwapchain.fg[y]
                    local bRow = activeSwapchain.bg[y]
                    local dRow = activeSwapchain.depth[y]
                    for x = 1, activeSwapchain.width do
                        cRow[x] = rp.clearChar
                        fRow[x] = rp.clearTextColor
                        bRow[x] = rp.clearColor
                        dRow[x] = rp.clearDepth
                    end
                end
            end

        elseif t == "BIND_PIPELINE" then
            activePipeline = op.pipeline

        elseif t == "SET_VIEWPORT" then
            activeViewport = op.viewport

        elseif t == "PUSH_CONSTANTS" then
            for k, v in pairs(op.constants) do
                pushConst[k] = v
            end

        elseif activeSwapchain then
            local sc = activeSwapchain
            if t == "DRAW_PIXEL" then
                putPixel(sc, op.x, op.y, op.char, op.fg, op.bg, nil, false)

            elseif t == "DRAW_LINE_2D" then
                rasterizeLine(sc, op.x0, op.y0, 0, op.x1, op.y1, 0, op.char, op.fg, op.bg, false)

            elseif t == "DRAW_RECT" then
                local x0 = math.max(1, math.floor(op.x))
                local y0 = math.max(1, math.floor(op.y))
                local x1 = math.min(sc.width, math.floor(op.x + op.w - 1))
                local y1 = math.min(sc.height, math.floor(op.y + op.h - 1))
                for py = y0, y1 do
                    for px = x0, x1 do
                        putPixel(sc, px, py, op.char, op.fg, op.bg, nil, false)
                    end
                end

            elseif t == "DRAW_BORDER_BOX" then
                local x0 = math.floor(op.x)
                local y0 = math.floor(op.y)
                local x1 = x0 + math.floor(op.w) - 1
                local y1 = y0 + math.floor(op.h) - 1
                local bFg = op.borderColor or "8"
                local bBg = op.bg
                for px = x0 + 1, x1 - 1 do
                    putPixel(sc, px, y0, "-", bFg, bBg, nil, false)
                    putPixel(sc, px, y1, "-", bFg, bBg, nil, false)
                end
                for py = y0 + 1, y1 - 1 do
                    putPixel(sc, x0, py, "|", bFg, bBg, nil, false)
                    putPixel(sc, x1, py, "|", bFg, bBg, nil, false)
                end
                putPixel(sc, x0, y0, "+", bFg, bBg, nil, false)
                putPixel(sc, x1, y0, "+", bFg, bBg, nil, false)
                putPixel(sc, x0, y1, "+", bFg, bBg, nil, false)
                putPixel(sc, x1, y1, "+", bFg, bBg, nil, false)
                if op.title and #tostring(op.title) > 0 then
                    local titleStr = " " .. tostring(op.title) .. " "
                    local tx = x0 + 2
                    for ti = 1, #titleStr do
                        if tx + ti - 1 < x1 then
                            putPixel(sc, tx + ti - 1, y0, titleStr:sub(ti, ti), op.titleColor or "0", bBg, nil, false)
                        end
                    end
                end

            elseif t == "DRAW_TEXT" then
                local y = math.floor(op.y)
                local x = math.floor(op.x)
                local str = op.text
                if y >= 1 and y <= sc.height then
                    for si = 1, #str do
                        local cx = x + si - 1
                        if cx >= 1 and cx <= sc.width then
                            putPixel(sc, cx, y, str:sub(si, si), op.fg, op.bg, nil, false)
                        end
                    end
                end

            elseif t == "DRAW_LINE_3D" then
                local mvp = pushConst.mvp or mat4.identity()
                local p0 = projectVertex(mvp, activeViewport, op.v0)
                local p1 = projectVertex(mvp, activeViewport, op.v1)
                if p0 and p1 then
                    local clip = {
                        x = activeViewport.x, y = activeViewport.y,
                        w = activeViewport.width, h = activeViewport.height
                    }
                    rasterizeLine(
                        sc, p0.x, p0.y, p0.z, p1.x, p1.y, p1.z,
                        op.char or pushConst.char or "*",
                        op.fg or pushConst.fg or "0",
                        op.bg or pushConst.bg,
                        activePipeline.depthTestEnable,
                        clip
                    )
                end

            elseif t == "DRAW_TRIANGLE_3D" then
                local mvp = pushConst.mvp or mat4.identity()
                local p0 = projectVertex(mvp, activeViewport, op.v0)
                local p1 = projectVertex(mvp, activeViewport, op.v1)
                local p2 = projectVertex(mvp, activeViewport, op.v2)
                if p0 and p1 and p2 then
                    local area = edgeFunc(p0.x, p0.y, p1.x, p1.y, p2.x, p2.y)
                    local culled = (activePipeline.cullMode == jvk.CULL_MODE_BACK and area < 0)
                    if not culled then
                        local clip = {
                            x = activeViewport.x, y = activeViewport.y,
                            w = activeViewport.width, h = activeViewport.height
                        }
                        local ch = op.char or pushConst.char or "#"
                        local fg = op.fg or pushConst.fg or "0"
                        local bg = op.bg or pushConst.bg
                        if activePipeline.polygonMode == jvk.POLYGON_MODE_FILL then
                            rasterizeTriangleFilled(sc, p0, p1, p2, ch, fg, bg, activePipeline.depthTestEnable, clip)
                        else
                            rasterizeLine(sc, p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, ch, fg, bg, activePipeline.depthTestEnable, clip)
                            rasterizeLine(sc, p1.x, p1.y, p1.z, p2.x, p2.y, p2.z, ch, fg, bg, activePipeline.depthTestEnable, clip)
                            rasterizeLine(sc, p2.x, p2.y, p2.z, p0.x, p0.y, p0.z, ch, fg, bg, activePipeline.depthTestEnable, clip)
                        end
                    end
                end

            elseif t == "DRAW_MESH_3D" then
                local m = op.mesh
                local mvp = op.opts.mvp or pushConst.mvp or mat4.identity()
                local clip = {
                    x = activeViewport.x, y = activeViewport.y,
                    w = activeViewport.width, h = activeViewport.height
                }
                if activePipeline.polygonMode == jvk.POLYGON_MODE_FILL and m.triangles then
                    for ti = 1, #m.triangles do
                        local tri = m.triangles[ti]
                        local p0 = projectVertex(mvp, activeViewport, m.vertices[tri[1]])
                        local p1 = projectVertex(mvp, activeViewport, m.vertices[tri[2]])
                        local p2 = projectVertex(mvp, activeViewport, m.vertices[tri[3]])
                        if p0 and p1 and p2 then
                            local area = edgeFunc(p0.x, p0.y, p1.x, p1.y, p2.x, p2.y)
                            if not (activePipeline.cullMode == jvk.CULL_MODE_BACK and area < 0) then
                                local col = tri[4] or op.opts.fg or pushConst.fg or "9"
                                local ch = tri[5] or op.opts.char or "#"
                                rasterizeTriangleFilled(sc, p0, p1, p2, ch, col, op.opts.bg or col, activePipeline.depthTestEnable, clip)
                            end
                        end
                    end
                elseif m.edges then
                    for ei = 1, #m.edges do
                        local edge = m.edges[ei]
                        local p0 = projectVertex(mvp, activeViewport, m.vertices[edge[1]])
                        local p1 = projectVertex(mvp, activeViewport, m.vertices[edge[2]])
                        if p0 and p1 then
                            local col = edge[3] or op.opts.fg or pushConst.fg or "9"
                            local ch = op.opts.char or pushConst.char or "*"
                            rasterizeLine(sc, p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, ch, col, op.opts.bg, activePipeline.depthTestEnable, clip)
                        end
                    end
                end
            end
        end
    end

    return activeSwapchain
end

function jvk.queueSubmit(queue, commandBuffers)
    assert(type(queue) == "table" and queue._type == "VkQueue", "jvk.queueSubmit: expected VkQueue")
    if type(commandBuffers) == "table" and commandBuffers._type == "VkCommandBuffer" then
        commandBuffers = { commandBuffers }
    end
    assert(type(commandBuffers) == "table", "jvk.queueSubmit: expected VkCommandBuffer or list of VkCommandBuffers")

    local lastSwapchain = nil
    for i = 1, #commandBuffers do
        local sc = executeCommandBuffer(commandBuffers[i])
        if sc then lastSwapchain = sc end
    end

    if lastSwapchain then
        local batch = {}
        for y = 1, lastSwapchain.height do
            batch[#batch + 1] = {
                op = "blit",
                x = 1,
                y = y,
                text = table.concat(lastSwapchain.chars[y]),
                fg = table.concat(lastSwapchain.fg[y]),
                bg = table.concat(lastSwapchain.bg[y])
            }
        end
        local ok, err = syscall("fb.submitBatch", batch)
        if not ok then
            error("jvk.queueSubmit failed: " .. tostring(err), 2)
        end
    end
    return jvk.VK_SUCCESS
end

function jvk.queuePresent(queue, swapchain)
    assert(type(queue) == "table" and queue._type == "VkQueue", "jvk.queuePresent: expected VkQueue")
    assert(type(swapchain) == "table" and swapchain._type == "VkSwapchainKHR", "jvk.queuePresent: expected VkSwapchainKHR")
    local ok, err = syscall("fb.present")
    if not ok then
        error("jvk.queuePresent failed: " .. tostring(err), 2)
    end
    return jvk.VK_SUCCESS
end

return jvk

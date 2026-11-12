-- CC-jOS Signed Application Bundle Manifest
return {
    id = "com.jos.launcher",
    name = "Launcher",
    version = "1.0.0",
    type = "user",
    entry = "main.lua",
    permissions = {
        "app.enumerate",
        "graphics.framebuffer",
        "input.events",
        "kernel.console",
        "process.info",
        "process.spawn",
    },
    files = {
        ["main.lua"] = "1173eb7ca0d019de20754617fd18c9e545cae1c17db44a8bbb18e7c21d91c46e",
    }
}

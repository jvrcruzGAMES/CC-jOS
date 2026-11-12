-- CC-jOS Signed Application Bundle Manifest
return {
    id = "com.jos.init",
    name = "Init",
    version = "1.1.0",
    type = "user",
    entry = "main.lua",
    permissions = {
        "graphics.framebuffer",
        "kernel.console",
        "process.info",
    },
    files = {
        ["main.lua"] = "f4c828b5fa1aa4db3307499ebc261f9706672a325e9892cc0a8afb241bf27fab",
    }
}

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
        ["main.lua"] = "9ca74f9fcaab6c075174a855930de388f1a427159ff28dfefcfff23675a7b2d9",
    }
}

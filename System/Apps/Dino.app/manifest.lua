-- CC-jOS Signed Application Bundle Manifest
return {
    id = "com.jos.dino",
    name = "Dino",
    version = "1.0.0",
    type = "user",
    entry = "main.lua",
    permissions = {
        "graphics.framebuffer",
        "input.events",
        "process.info",
    },
    files = {
        ["main.lua"] = "eaff0309354bee597a7708ea7389541eacfe666d470f2bb947019b82f4d131b3",
    }
}

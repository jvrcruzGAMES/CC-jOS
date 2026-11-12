-- CC-jOS Signed Application Bundle Manifest
return {
    id = "com.jos.init",
    name = "Init",
    version = "1.0.0",
    type = "user",
    entry = "main.lua",
    permissions = {
        "kernel.console",
        "process.info",
    },
    files = {
        ["main.lua"] = "efbd9d9b354dfd7b94ca9c70661b6118146c32e5a50dc6478971a109be8eb31c",
    }
}

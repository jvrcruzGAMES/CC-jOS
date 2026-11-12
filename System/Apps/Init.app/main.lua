-- ============================================================================
-- CC-jOS Initial Userspace Application (/System/Apps/Init.app/main.lua)
-- ============================================================================

local ok, selfInfo = syscall("process.self")
if ok and selfInfo then
    -- Verify we are running in unprivileged userspace without raw FS access
    local fsAllowed = syscall("hw.fs")
    assert(not fsAllowed, "Userspace app must not have raw hardware FS permission!")
end

print("Kernel's up")

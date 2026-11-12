# CC-jOS

A barebones, security-focused microkernel operating system for **CC: Tweaked** (ComputerCraft) featuring an immutable hardware root of trust, updateable stage-2 bootloader, strict RSA-SHA256 code signing, per-process capability permissions, and a macOS/iOS-inspired `.app` directory bundle architecture.

---

## Quick Install (In-Game CC: Tweaked)

Run the following command on any CC: Tweaked computer with the `http` API enabled:

```lua
wget run https://raw.githubusercontent.com/jvrcruzGAMES/CC-jOS/main/installer.lua
```

---

## System Architecture

CC-jOS separates the operating system stack into three strictly verified stages before handing off execution to isolated userspace `.app` bundles:

```
+-------------------------------------------------------------------+
|                        Userspace (.app Bundles)                   |
|   /System/Apps/Init.app  |  Future Sysmodules (FS.app, Net.app)   |
+-------------------------------------------------------------------+
                 ^                                 |
                 |  Isolated _ENV + syscall(...)   |
                 v                                 v
+-------------------------------------------------------------------+
|              Kernel (/System/Kernel/kernel.lua + .sig)            |
|  - Coroutine Process Scheduler & IPC Bus                          |
|  - Strict RSA-SHA256 .app Bundle & Per-File Digest Verification   |
|  - Capability Permission Enforcer (User App vs Sysmodule Tiers)   |
+-------------------------------------------------------------------+
                                 ^
                                 |  Verified Jump
+-------------------------------------------------------------------+
|              Bootloader (/boot/bootloader.lua + .sig)             |
|  - Checks & Applies Signed Staged Updates (/boot/update/*)        |
|  - Verifies Kernel Signature & Immediately Jumps to Kernel        |
+-------------------------------------------------------------------+
                                 ^
                                 |  Verified Handoff (BIOS, rawHW)
+-------------------------------------------------------------------+
|                     BIOS (/startup.lua)                           |
|  - Immutable After Install (FS Write/Delete/Move Protection)      |
|  - Embedded RSA-512 / SHA-256 Root Certificate Authority          |
|  - Low-Level Crypto, Canonical Serializer & Panic Utilities       |
+-------------------------------------------------------------------+
```

### 1. BIOS (`/startup.lua`)
- **Immutable After Install**: Wraps the filesystem interface so `/startup.lua` cannot be opened for writing, deleted, moved, or overwritten (`BIOS_IMMUTABLE`), and exposes a frozen read-only `BIOS` utility table to upper layers.
- **Root of Trust**: Embeds the `CC-jOS-Root-CA-v1` RSA-512 / SHA-256 public key and provides pure-Lua cryptographic primitives (`BIOS.sha256`, `BIOS.verifySignature`, `BIOS.verifySignedFile`, `BIOS.serializeCanonical`, `BIOS.loadProtectedChunk`, `BIOS.log`, `BIOS.panic`).

### 2. Bootloader (`/boot/bootloader.lua`)
- **Verified by BIOS**: Must carry a valid `/boot/bootloader.lua.sig` signed by the Root CA before BIOS will execute it.
- **Updateable**: Automatically inspects `/boot/update/` on boot for staged `bootloader.lua` or `kernel.lua` updates, verifies their RSA-SHA256 signatures via `BIOS.verifySignedFile`, atomically installs valid updates, and immediately loads `/System/Kernel/kernel.lua`.

### 3. Barebones Microkernel (`/System/Kernel/kernel.lua`)
- **Strict Userspace Isolation**: Strips privileged ComputerCraft globals (`fs`, `io`, `http`, `loadfile`, `dofile`, `shell`, `multishell`, `package`, `peripheral`, `redstone`) from `_G`. Everything above the kernel runs in a per-process sandboxed `_ENV` and communicates exclusively through `syscall(name, ...)`.
- **Strict Code Signing**: Refuses to launch any `.app` bundle unless:
  1. `manifest.lua` and `signature.sig` are present and valid.
  2. The RSA-SHA256 signature over the canonicalized manifest is valid against the BIOS Root CA.
  3. Every file inside the `.app` directory is listed in `manifest.files` and matches its signed SHA-256 digest (no tampered or extra unsigned files allowed).
- **Strict Permission Enforcing**:
  - Permissions are declared in `manifest.lua` and cryptographically bound by `signature.sig`.
  - **Privilege Tiers**: User applications (`type = "user"`) are forbidden from requesting sysmodule-reserved permissions (`hw.fs.raw`, `hw.http.raw`, `hw.term.raw`, `ipc.register`, `kernel.audit`). Only signed system modules (`type = "sysmodule"`, such as the future `FS.app`) may request hardware or service-registration capabilities.

---

## `.app` Bundle Structure

Every application or sysmodule is packaged as a directory ending in `.app`:

```
/System/Apps/Init.app/
├── manifest.lua    -- Bundle metadata, permissions list, and file SHA-256 map
├── main.lua        -- Entry point executed in isolated userspace _ENV
└── signature.sig   -- RSA-SHA256 cryptographic signature over canonical manifest
```

### Example `manifest.lua`
```lua
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
        ["main.lua"] = "<sha256-digest>",
    }
}
```

---

## Signing & Verification Tooling

Use `tools/jos-sign.lua` to sign system binaries (`bootloader.lua`, `kernel.lua`) or `.app` bundles:

```bash
# Sign bootloader, kernel, and all default .app bundles
lua tools/jos-sign.lua sign-all

# Sign a specific .app bundle
lua tools/jos-sign.lua sign-app System/Apps/Init.app

# Sign a standalone system binary
lua tools/jos-sign.lua sign-file System/Kernel/kernel.lua

# Run the end-to-end verification & security test suite
lua tests/test_os.lua
```

# CC-jOS

A barebones, security-focused microkernel operating system for **CC: Tweaked** (ComputerCraft) featuring an immutable hardware root of trust, a BIOS framebuffer with a centered white `J` boot splash, an updateable stage-2 bootloader, strict RSA-SHA256 code signing, per-process capability permissions, a `.app` directory bundle architecture, and **`libjvk` (`jvk`)** — a bundled Vulkan-style 2D & 3D graphics and UI library.

---

## Quick Install (In-Game CC: Tweaked)

Run the following command on any CC: Tweaked computer with the `http` API enabled:

```lua
wget run https://raw.githubusercontent.com/jvrcruzGAMES/CC-jOS/main/installer.lua
```

---

## System & Rendering Architecture

```
+-------------------------------------------------------------------+
|                        Userspace (.app Bundles)                   |
|   /System/Apps/Launcher.app (qLaunch)  |  /System/Apps/Dino.app   |
+-------------------------------------------------------------------+
                 |                                 |
                 | require("jvk")                  |
                 v                                 |
+--------------------------------------------------+                |
|   Bundled Vulkan-Style Graphics Library (libjvk) |                |
|         /System/Libraries/jvk.lua + .sig         |                |
|  - 2D UI Widgets & 3D Depth-Buffered Rasterizer  |                |
+--------------------------------------------------+                |
                 |                                 |
                 | syscall("fb.*")                 | syscall(...)
                 v                                 v
+-------------------------------------------------------------------+
|              Kernel (/System/Kernel/kernel.lua + .sig)            |
|  - Coroutine Process Scheduler, Event Bus & IPC                   |
|  - Framebuffer Syscall Abstraction (fb.info, fb.submitBatch, ...) |
|  - Strict RSA-SHA256 .app Bundle & Signed System Library Loader   |
|  - Capability Permission Enforcer (User App vs Sysmodule Tiers)   |
+-------------------------------------------------------------------+
                                 ^
                                 |  Verified Jump
+-------------------------------------------------------------------+
|              Bootloader (/boot/bootloader.lua + .sig)             |
|  - Maintains Centered White "J" Boot Screen via BIOS.fb           |
|  - Checks & Applies Signed Staged Updates (/boot/update/*)        |
|  - Verifies Kernel Signature & Immediately Jumps to Kernel        |
+-------------------------------------------------------------------+
                                 ^
                                 |  Verified Handoff (BIOS, rawHW)
+-------------------------------------------------------------------+
|                     BIOS (/startup.lua)                           |
|  - Immutable After Install (FS Write/Delete/Move Protection)      |
|  - Pixelwise 2x3 Teletext Sub-pixel Framebuffer (BIOS.fb)         |
|  - Renders Hardcoded Centered White "J" Boot Splash Screen        |
|  - Embedded RSA-512 / SHA-256 Root Certificate Authority          |
+-------------------------------------------------------------------+
```

### 1. BIOS (`/startup.lua`)
- **Immutable After Install**: Wraps the filesystem interface so `/startup.lua` cannot be opened for writing, deleted, moved, or overwritten (`BIOS_IMMUTABLE`), and exposes a frozen read-only `BIOS` utility table to upper layers.
- **BIOS Framebuffer (`BIOS.fb`) & Boot Screen**: Implements a full scanline backbuffer/frontbuffer (`clear`, `setCell`, `getCell`, `writeText`, `fillRect`, `blitRow`, `submitBatch`, `present`). Immediately on boot, `BIOS.fb.renderBootSplash()` renders a hardcoded **white uppercase `J` centered on a black screen**, which stays displayed until the initial userspace `.app` launches and takes over the rendering stack.
- **Root of Trust**: Embeds the `CC-jOS-Root-CA-v1` RSA-512 / SHA-256 public key and provides pure-Lua cryptographic primitives (`BIOS.sha256`, `BIOS.verifySignature`, `BIOS.verifySignedFile`, `BIOS.serializeCanonical`, `BIOS.loadProtectedChunk`, `BIOS.log`, `BIOS.panic`).

### 2. Bootloader (`/boot/bootloader.lua`)
- **Verified by BIOS**: Must carry a valid `/boot/bootloader.lua.sig` signed by the Root CA before BIOS will execute it.
- **Updateable**: Automatically inspects `/boot/update/` on boot for staged `bootloader.lua` or `kernel.lua` updates, verifies their RSA-SHA256 signatures via `BIOS.verifySignedFile`, atomically installs valid updates, maintains the BIOS framebuffer boot screen, and immediately loads `/System/Kernel/kernel.lua`.

### 3. Barebones Microkernel (`/System/Kernel/kernel.lua`)
- **Strict Userspace Isolation**: Strips privileged ComputerCraft globals (`fs`, `io`, `http`, `loadfile`, `dofile`, `shell`, `multishell`, `package`, `peripheral`, `redstone`) from `_G`. Everything above the kernel runs in a per-process sandboxed `_ENV` and communicates exclusively through `syscall(name, ...)`.
- **Framebuffer Syscalls (`fb.*`)**: Abstracts `BIOS.fb` behind permission-gated kernel syscalls (`fb.info`, `fb.clear`, `fb.setCell`, `fb.getCell`, `fb.writeText`, `fb.fillRect`, `fb.blitRow`, `fb.submitBatch`, `fb.present`, `fb.snapshot`), requiring `"graphics.framebuffer"`.
- **Strict Code Signing**: Verifies `.app` bundles (`manifest.lua`, `signature.sig`, and per-file SHA-256 hashes) as well as signed system libraries loaded via `require("jvk")` (`/System/Libraries/jvk.lua` + `.sig`).

### 4. `libjvk` (`jvk`) — Bundled Vulkan-Style 2D & 3D Graphics Library
- Located at `/System/Libraries/jvk.lua` (signed by `/System/Libraries/jvk.lua.sig`).
- Provides a `libvulkan`-inspired pipeline (`VkInstance`, `VkPhysicalDevice`, `VkDevice`, `VkQueue`, `VkSwapchainKHR`, `VkRenderPass`, `VkPipeline`, `VkCommandBuffer`) for building pixelwise 2D UIs (`uiWindow`, `uiPanel`, `uiLabel`, `uiButton`, `uiProgressBar`) and 3D depth-buffered scenes (`vec3`, `mat4`, `mesh.cube`, `mesh.pyramid`, `drawMesh`, `uiViewport3D`).
- **Full Documentation**: See **[docs/jvk.md](docs/jvk.md)**.

### 5. Bundled Userspace `.app` Bundles
- **`Launcher.app` (`/System/Apps/Launcher.app`)**:
  - Nintendo Switch **qLaunch**-style Home Menu launched by the Kernel on boot.
  - Displays installed `.app` bundles in a centered horizontal row of square tiles with a pulsing cyan selection border.
  - **Controls (WASD)**: `A` / `D` to move between app squares, `W` (or `Space` / `Enter`) to launch the selected app.
- **`Dino.app` (`/System/Apps/Dino.app`)**:
  - Recreation of Google Chrome's **Dino** game rendered pixelwise (`102 × 57` sub-pixels) via `libjvk`.
  - Features animated T-Rex running, jumping, and ducking sprites, cacti & flapping pterodactyl obstacles, scrolling clouds & desert horizon, and high-score tracking.
  - **Controls (WASD)**: `W` / `Space` to jump (or retry on Game Over), `S` to duck / fast-fall, `A` / `D` to adjust horizontal position, `Q` to quit back to `Launcher.app`.

---

## Signing & Verification Tooling

```bash
# Sign bootloader, kernel, libjvk, Launcher.app, and Dino.app
lua tools/jos-sign.lua sign-all

# Sign a specific .app bundle
lua tools/jos-sign.lua sign-app System/Apps/Dino.app

# Sign a standalone system binary or library
lua tools/jos-sign.lua sign-file System/Libraries/jvk.lua

# Run the end-to-end verification & security test suite
lua tests/test_os.lua
```

# Peng — GPU-Accelerated Image Viewer

Peng is a modern, high-performance, GPU-accelerated image viewer built in **Zig** using **SDL3** (Vulkan/Metal) and a custom immediate-mode UI engine. It is designed to be extremely fast, memory-safe, and scriptable via a thread-safe UNIX Domain Socket (UDS) IPC interface.

______________________________________________________________________

## Features

- **GPU Acceleration:** Uses the modern SDL3 GPU API with Vulkan and Metal backends.
- **Camera RAW Zero-Copy Streaming:** High-performance viewing of Camera RAW images (`.arw`, `.raf`, `.cr2`, `.nef`, `.dng`, `.orf`, `.rw2`, `.pef`) with zero full-file allocations in RAM. Streams 256KB Stage-1 headers on background worker threads for off-render-thread metadata probing, range-limited positional reads for preview JPEGs, and instant embedded thumbnail rendering during fast navigation.
- **RAW+JPEG Stacking & Progressive Streaming:** Sibling RAW and JPEG files
  with identical stems (e.g. `DSC00941.ARW` + `DSC00941.JPG`) automatically
  collapse into a single logical photo entry. Employs a 4-tier loading pipeline:
  RAW header thumbnail during rapid scrubbing, crisp RAW embedded preview for
  settled viewing, and zero-flash promotion to companion JPEG lazily when
  screen pixel demand exceeds preview resolution ($M\_{\\text{tex}} > 1.05$) or
  upon pressing `j`.
- **CBZ & Manga Mode Support:** Instant $O(1)$ page seeking inside `.cbz` comic archives with toggleable Right-to-Left (RTL) Manga reading mode (`M` key).
- **Advanced Filtering & Resampling:** Features a 7-filter GPU resampling suite including Nearest, Bilinear, Pixel Art (AA-Nearest), Mitchell-Netravali, Analytical Lanczos3, AMD FSR 1.0, and Tiny CNN (ESPCN).
- **Command Palette:** Built-in searchable palettes for commands (`F1` or `Ctrl+Shift+P`), file search (`Ctrl+P`), and directory navigator (`Ctrl+O`).
- **Docked Image Adjustments Panel:** Interactive side panel (`e` key)
  featuring a 13-parameter photographic color and presence pipeline across
  Light & Tone (Exposure, Contrast, Contrast Blend, Highlights, Shadows, Whites,
  Blacks), White Balance (Temperature, Tint), Color (Vibrance, Saturation),
  and Presence (Clarity, Texture) with live slider dragging, reset shortcuts
  (`Shift+R`), and instant before/after comparison (`\` key).
- **Lightroom-Style Image Triage & SIMD Filtering:** Instant photo triage with Pick (`z`), Reject (`x`), and Unflag (`u`) shortcuts. Filtered view modes (`v` / `Shift+V`) cycle between Default (hides rejected images), Picks Only, Rejects Only, Unflagged Only, and All Images. Filtering and visible count calculations are accelerated via 256-bit SIMD vector instructions (`@Vector(32, u8)`) and hardware popcounting (`POPCNT`), enabling sub-microsecond filtering across collections of 10,000+ photos.
- **UNIX Pipeline Integration & Triage Export:** On application exit, classifications are streamed cleanly to standard output as tab-separated rows (`PICK\t/path/to/image.jpg` or `REJECT\t/path/to/image.jpg`), allowing direct integration with shell tools (`awk`, `xargs`, `cp`, `mv`).
- **Non-Blocking Headless Mode:** Runs offscreen without X11 or Wayland (ideal for CI and servers) with `--headless`.
- **Scriptable IPC Control:** External client controls the viewer's zoom, pan, filters, and takes screenshots in real-time.

______________________________________________________________________

## Supported Formats

| Category            | Formats / Extensions                                                      | Highlights                                                                                                                                                                |
| :------------------ | :------------------------------------------------------------------------ | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Standard Raster** | `.png`, `.jpg`, `.jpeg`, `.webp`, `.avif`, `.bmp`, `.tga`, `.svg`, `.gif` | High-DPI mipmapped GPU rendering, SIMD color conversions                                                                                                                  |
| **Comic Archives**  | `.cbz`                                                                    | Central Directory parsing with $O(1)$ page seeking and RTL Manga mode                                                                                                     |
| **Camera RAW**      | `.arw`, `.raf`, `.cr2`, `.nef`, `.dng`, `.orf`, `.rw2`, `.pef`            | Zero full-file allocations, sub-0.1ms probe, range-limited embedded previews, instant thumbnail scrubbing, RAW+JPEG automatic pairing, and raw sensor dimension reporting |

______________________________________________________________________

## Keyboard Shortcuts

| Shortcut                                | Action                                                            |
| :-------------------------------------- | :---------------------------------------------------------------- |
| `n` / `]` / `Space` / `Right`           | Next Image                                                        |
| `p` / `[` / `Backspace` / `Left`        | Previous Image                                                    |
| `Home` / `End`                          | Jump to First / Last Image                                        |
| `Shift+G`                               | Go to Image Dialog (Numeric Jump)                                 |
| `i` / `+` / `=`                         | Zoom In (with 100% snap detent)                                   |
| `o` / `-`                               | Zoom Out (with 100% snap detent)                                  |
| `a`                                     | Actual Size (1:1 / 100% Universal Pixel Zoom)                     |
| `r` / `0`                               | Reset Zoom & Pan                                                  |
| `h` / `j` / `k` / `l`                   | Pan Left / Down / Up / Right (when zoomed)                        |
| `>`                                     | Rotate Clockwise (90°)                                            |
| `<`                                     | Rotate Counter-Clockwise (90°)                                    |
| `e`                                     | Toggle Edit Side Panel (Image Adjustments)                        |
| `Alt+J`                                 | Toggle RAW+JPEG Stacking (Group / Separate Files)                 |
| `j`                                     | Toggle RAW / Companion JPEG Stream (when pair is active)          |
| `s`                                     | Cycle Scale Mode (Shrink, Full, Crop, Actual, Fit W/H)            |
| `S` (Shift+s)                           | Cycle Resampling Filter Forward (Nearest, Linear, Mitchell, etc)  |
| `Alt+Shift+S`                           | Cycle Resampling Filter Backward                                  |
| `b` / `B` (Shift+b)                     | Increase / Decrease Brightness                                    |
| `c` / `C` (Shift+c)                     | Increase / Decrease Contrast                                      |
| `\`                                     | Toggle Before / After (Original vs Adjusted)                      |
| `Shift+R`                               | Reset Brightness & Contrast                                       |
| `d`                                     | Toggle Image Info Overlay                                         |
| `Shift+D` / `Shift+I`                   | Toggle Stats for Nerds / Performance Overlay                      |
| `Ctrl+T`                                | Toggle Embedded Thumbnail Debug Overlay                           |
| `t`                                     | Toggle Title Bar Overlay                                          |
| `m`                                     | Toggle Manga Mode (Right-to-Left)                                 |
| `f` / `F11`                             | Toggle Borderless Fullscreen                                      |
| `F5` / `Ctrl+R`                         | Refresh / Rescan Directory                                        |
| `z`                                     | Flag Current Image as Pick                                        |
| `x`                                     | Flag Current Image as Reject                                      |
| `u`                                     | Unflag Classification on Current Image                            |
| `v`                                     | Cycle View Mode Forward (Default, Unflagged, Picks, Rejects, All) |
| `Shift+V`                               | Cycle View Mode Backward                                          |
| `:` / `?` / `/` / `F1` / `Ctrl+Shift+P` | Open Command Palette (Actions)                                    |
| `Ctrl+P`                                | Open File Search Palette                                          |
| `Ctrl+O`                                | Open Directory Navigator Palette                                  |
| `q` / `Esc`                             | Close Palette / Dismiss Dialogs / Hide Window (`--server`) / Exit |
| `Ctrl+Q`                                | Quit Server / Exit Application Unconditionally                    |

### Command Palette & Line Editor Navigation

When search or input palettes are active:

- `Down` / `Ctrl+N` / `Ctrl+J`: Select next candidate
- `Up` / `Ctrl+P`: Select previous candidate
- `PageDown` / `Ctrl+V`: Page list down
- `PageUp` / `Alt+V`: Page list up
- `Tab` / `Right`: In Directory Navigator, enter selected folder
- `Shift+Tab` / `Left` / `Backspace`: In Directory Navigator, step out to parent folder
- `Ctrl+W` / `Alt+Backspace`: Delete word backward
- `Ctrl+U`: Clear entire search query
- `Enter`: Confirm selection
- `Esc` / `Ctrl+G`: Dismiss palette

______________________________________________________________________

## Build Targets

Compile all components using the standard Zig build system:

```bash
# Enter the Nix development shell (contains Zig 0.17.0 and SDL3 dependencies)
direnv allow
# OR: nix develop

# Build all executables in release or debug mode
zig build
```

This compiles three executables to `./zig-out/bin/`:

1. `peng`: The primary image viewer.
2. `peng-msg`: A lightweight CLI client for sending IPC control messages.
3. `peng-test-runner`: The automated visual regression test runner.

______________________________________________________________________

## Running the Viewer

Start the image viewer by passing a file or directory path:

```bash
# View a specific image
./zig-out/bin/peng path/to/image.png

# View a directory of images
./zig-out/bin/peng path/to/images_dir/
```

### CLI Flags

| Flag                  | Argument                                                    | Description                                              |
| :-------------------- | :---------------------------------------------------------- | :------------------------------------------------------- |
| `-h`, `--help`        | None                                                        | Displays the help message and available options.         |
| `-W`, `--windowless`  | None                                                        | Runs in borderless/windowless mode (no titlebar chrome). |
| `--scale`             | `none`, `shrink`, `full`, `crop`, `fit_width`, `fit_height` | Sets default image scaling / zoom preset.                |
| `--blur`              | None                                                        | Enables background glassmorphism blur effect (default).  |
| `--no-blur`           | None                                                        | Disables background glassmorphism blur effect.           |
| `--title`             | None                                                        | Shows floating title bar overlay on startup.             |
| `--headless`          | None                                                        | Runs without opening an OS display window.               |
| `--profile-startup`   | None                                                        | Logs cold-start milestone timings in milliseconds.       |
| `--stack-raw-jpeg`    | None                                                        | Group RAW and companion JPEG files into a single image.  |
| `--no-stack-raw-jpeg` | None                                                        | Display RAW and companion JPEG files as separate images. |
| `--thumb-cache`       | `all`, `missing`, `read_only`, `off`                        | Sets the XDG shared thumbnail cache policy.              |
| `--thumb-size`        | `normal`, `large`, `x-large`, `xx-large`                    | Overrides the XDG thumbnail write tier (auto-DPI by default). |
| `--no-thumb-cache`    | None                                                        | Disables the Freedesktop XDG shared thumbnail cache.     |
| `--precache`          | None                                                        | Pre-generates Freedesktop thumbnails for path and exits. |
| `-r`, `--recursive`   | None                                                        | Recursively scans subdirectories when pre-caching.       |
| `--server`            | None                                                        | Runs as a resident background server (`q` hides window). |
| `--ipc`               | None                                                        | Enables the IPC UNIX Domain Socket server.               |
| `-S`, `--socket`      | `<PATH>`                                                    | Enables the IPC server bound to an explicit socket path. |

Aliases:

- `--windowless` can also be specified as `--borderless` or `--undecorated`.
- `--scale` supports preset aliases: `fit` (alias for `full`), `fill` (alias
  for `crop`), `1:1` or `actual` (alias for `none`).
- `--server` can also be specified as `--daemon`; `--socket` as `--ipc-socket`; `--precache` as `--cache-thumbs`.

______________________________________________________________________

## Remote IPC Control (`peng-msg`) & Resident Server Mode

When `peng` is launched with `--server`, `--ipc` (default `/tmp/peng-$PID.sock`), or `--socket <path>`, it starts a UDS server and prints the socket path to `stdout`.

In `--server` mode (or when auto-spawned via `peng-msg --spawn`), `peng` keeps its GPU device and compiled shaders warm in the background. When no `--socket <path>` is specified, both `peng --server` and `peng-msg` resolve the default socket path from `$XDG_RUNTIME_DIR/peng.sock`, falling back to `/tmp/peng-$UID.sock` (or `$TMPDIR/peng.sock` on macOS and `%TEMP%\peng.sock` on Windows). Pressing `q`, `Esc`, clicking the window close button, or sending `peng-msg close` hides the window and unloads the active image cache and directory playlist (preserving only the warm GPU device, shaders, and picks/rejects selections). While hidden, view/navigation IPC commands return `{"ok":false,"error":"WindowHidden"}`, while `open`, `preview`, `selections`, `clear_selections`, `close`, and `quit` remain available. Sending bare `peng-msg --spawn open` shows the window with the File Picker palette open when no media is loaded. Pressing `Ctrl+Q`, selecting **Quit Server** in the Command Palette, or sending `peng-msg quit` terminates the server process.

You can send commands to a running instance using the `peng-msg` utility.
Every `peng-msg` invocation writes a single-line JSON response to `stdout`
(`{"ok":true}` on success, or `{"ok":false,"error":"<reason>"}` with exit code
`1` on failure, except `preview` / `clear-and-preview`, which emit a Kitty
Graphics Protocol `t=t` escape sequence on success), making it easy to inspect
or pipe into `jq`:

```bash
# General Usage:
./zig-out/bin/peng-msg [-s|--spawn] [-S|--socket <path>] [socket_path] <command_words...>

# Resident Server Workflow (auto-spawns peng --server on default socket if not running):
./zig-out/bin/peng-msg --spawn open
./zig-out/bin/peng-msg --spawn open /path/to/photo.jpg
./zig-out/bin/peng-msg close
./zig-out/bin/peng-msg quit

# Examples with explicit socket path:
# Open a new image file, directory, or .cbz archive in the running instance
./zig-out/bin/peng-msg /tmp/peng-1234.sock open /path/to/photo.jpg
# Adjust zoom factor (min 0.001, max 100.0)
./zig-out/bin/peng-msg /tmp/peng-1234.sock zoom 2.5

# Pan coordinates (x, y)
./zig-out/bin/peng-msg /tmp/peng-1234.sock pan 100 -50

# Set Scale Mode / Preset (none, shrink, full, crop, fit, fill, 1:1, actual)
./zig-out/bin/peng-msg /tmp/peng-1234.sock scale fit
./zig-out/bin/peng-msg /tmp/peng-1234.sock scale fill
./zig-out/bin/peng-msg /tmp/peng-1234.sock scale 1:1

# Set Manga Mode (true, false)
./zig-out/bin/peng-msg /tmp/peng-1234.sock manga true

# Toggle Windowless / Borderless Mode (toggle, true, false, on, off)
./zig-out/bin/peng-msg /tmp/peng-1234.sock windowless toggle
./zig-out/bin/peng-msg /tmp/peng-1234.sock borderless true

# Toggle Floating Title Bar Overlay (toggle, true, false)
./zig-out/bin/peng-msg /tmp/peng-1234.sock title toggle

# Adjust brightness, contrast, and optional contrast blend (0.0 to 1.0)
./zig-out/bin/peng-msg /tmp/peng-1234.sock adjust 0.2 1.4 1.0

# Batch adjust tonal quad (highlights, shadows, whites, blacks)
./zig-out/bin/peng-msg /tmp/peng-1234.sock tone 0.15 -0.10 0.05 -0.05

# Batch adjust color (temperature, tint, vibrance, saturation)
./zig-out/bin/peng-msg /tmp/peng-1234.sock color 0.10 0.00 0.25 0.10

# Batch adjust presence (clarity, texture)
./zig-out/bin/peng-msg /tmp/peng-1234.sock presence 0.20 0.15

# Single parameter adjustments (all 13 photographic grading slugs supported:
# brightness, contrast, contrast_blend, highlights, shadows, whites, blacks,
# temperature, tint, vibrance, saturation, texture, clarity)
./zig-out/bin/peng-msg /tmp/peng-1234.sock brightness 0.15
./zig-out/bin/peng-msg /tmp/peng-1234.sock clarity 0.30
./zig-out/bin/peng-msg /tmp/peng-1234.sock texture 0.10
./zig-out/bin/peng-msg /tmp/peng-1234.sock contrast_blend 0.85

# Reset all image adjustments or reset viewport transform
./zig-out/bin/peng-msg /tmp/peng-1234.sock reset_adjustments
./zig-out/bin/peng-msg /tmp/peng-1234.sock reset_view

# Toggle navigation crossfade transition (on, off, toggle)
./zig-out/bin/peng-msg /tmp/peng-1234.sock crossfade on

# Toggle status snackbar notification (true, false, toggle)
./zig-out/bin/peng-msg /tmp/peng-1234.sock snackbar true

# Capture high-resolution screenshot to file
./zig-out/bin/peng-msg /tmp/peng-1234.sock screenshot /path/to/output.png

# Toggle Before / After Comparison (toggle, on, off)
./zig-out/bin/peng-msg /tmp/peng-1234.sock compare toggle

# Toggle or set Edit Side Panel visibility (toggle, on, off, reset)
./zig-out/bin/peng-msg /tmp/peng-1234.sock edit toggle
./zig-out/bin/peng-msg /tmp/peng-1234.sock edit on
./zig-out/bin/peng-msg /tmp/peng-1234.sock edit reset


# Apply Resampling Filter (mitchell, lanczos3, fsr, tiny_cnn, linear, pixel_art)
./zig-out/bin/peng-msg /tmp/peng-1234.sock filter mitchell
./zig-out/bin/peng-msg /tmp/peng-1234.sock filter lanczos3
./zig-out/bin/peng-msg /tmp/peng-1234.sock filter fsr
./zig-out/bin/peng-msg /tmp/peng-1234.sock filter tiny_cnn

# Navigation
./zig-out/bin/peng-msg /tmp/peng-1234.sock next
./zig-out/bin/peng-msg /tmp/peng-1234.sock prev

# Image Classification (pick, reject, unflag, selections, clear_selections)
./zig-out/bin/peng-msg /tmp/peng-1234.sock pick
./zig-out/bin/peng-msg /tmp/peng-1234.sock reject
./zig-out/bin/peng-msg /tmp/peng-1234.sock unflag

# Query current picks and rejects as JSON (`{"ok":true,"picks":[...],...}`)
./zig-out/bin/peng-msg /tmp/peng-1234.sock selections | jq -r '.picks[]'

# Clear all picks and rejects in the current session
./zig-out/bin/peng-msg /tmp/peng-1234.sock clear_selections

# Set Active View Mode (default, unflagged, picks, rejects, all)
./zig-out/bin/peng-msg /tmp/peng-1234.sock view picks
./zig-out/bin/peng-msg /tmp/peng-1234.sock view rejects
./zig-out/bin/peng-msg /tmp/peng-1234.sock view default

# Toggle UI Palettes (action, files, none)
./zig-out/bin/peng-msg /tmp/peng-1234.sock palette action
./zig-out/bin/peng-msg /tmp/peng-1234.sock palette none

# RAW+JPEG Pairing Controls
./zig-out/bin/peng-msg /tmp/peng-1234.sock stack_raw_jpeg toggle
./zig-out/bin/peng-msg /tmp/peng-1234.sock toggle_stream

# Toggle Thumbnail Preview (true, false, toggle)
./zig-out/bin/peng-msg /tmp/peng-1234.sock thumb toggle

# Pre-cache Freedesktop thumbnails for the active directory in the background
./zig-out/bin/peng-msg /tmp/peng-1234.sock precache

# Render a fast terminal image preview via the Kitty Graphics Protocol
# (Kitty, Ghostty, WezTerm, Konsole)
./zig-out/bin/peng-msg -s preview 800 600 /path/to/photo.RAF
fd . testfiles/images -e jpg | \
  fzf --preview './zig-out/bin/peng-msg -s preview --clear 800 600 {}'

# Wait for background image decoder to finish loading
./zig-out/bin/peng-msg /tmp/peng-1234.sock wait_load

# Close/hide the window (in --server mode, keeps the server resident)
./zig-out/bin/peng-msg /tmp/peng-1234.sock close

# Quit the app / terminate the resident server
./zig-out/bin/peng-msg /tmp/peng-1234.sock quit
```

______________________________________________________________________

## Architecture

Peng is structured around a reactive, unidirectional **game-engine frame
pipeline** (`src/viewer.zig`, `src/app/systems/root.zig`) backed by an acyclic
17-package Zig module graph (`build.zig`):

```text
Phase 1: Ingest          Phase 2a: Reduce Intents      Phase 2b: Sync Hardware & Workers    Phase 3: Render Snapshot
┌─────────────────────┐  ┌──────────────────────────┐  ┌─────────────────────────────────┐  ┌──────────────────────────┐
│ • pollFrameInput    │─▶│ • IPC / Palette / Keys   │─▶│ • sysSyncWindow                 │─▶│ • buildUiViewModel       │
│ • drainWorkerEvents │  │ • Pointer Hits & Motion  │  │ • sysProcessAssetUploads (GPU)  │  │   (*const AppState)      │
│   (O(1) MPSC swap,  │  │ • sysExecuteIntents      │  │ • sysUpdateCache (DecodeMode &  │  │ • ui.layout.renderFrame  │
│    CPU staging)     │  │   (single-pass reducer)  │  │   DecodePriority workers)       │  │ • 2-pass RenderPacket    │
└─────────────────────┘  └──────────────────────────┘  └─────────────────────────────────┘  └──────────────────────────┘
```

### Key Design Choices

- **Lock-Free Main-Thread State (`ViewerState`)**: `ViewerState` lives 100% on
  the main thread with zero GPU handles, worker mutexes, or stored allocators.
  Background `std.Io` workers communicate strictly via an $O(1)$-swapped MPSC
  event queue and cancel cooperatively via 3-tier generation and per-slot atomic
  `job_epochs`.
- **Decoupled Simulation & Presentation (`app` $\\leftrightarrow$ `ui`)**: `app`
  and `ui` are independent sibling modules (`app` never imports `ui`; `ui` has
  zero SDL or `core` linkage), bridged in `src/viewer.zig` via an immutable
  `UiViewModel` snapshot (`*const AppState`) and explicit `*InteractionState`
  immediate-mode hit rects.
- **Zero-Lag Pre-Render GPU Promotion**: GPU texture uploads
  (`sysProcessAssetUploads`) and worker dispatch (`sysUpdateCache`) run at the
  end of Phase 2—right *before* `renderFrame` rather than after—so CPU-staged
  thumbnails and full surfaces promote to GPU textures and render on the **same
  frame** with zero extra frame latency.
- **Control-Plane vs. Data-Plane Separation**: Control inputs (keyboard, mouse,
  palette, and UDS `ipc_command`s) reduce through pure value-typed `AppIntent`s,
  while data-plane worker completions (`sdl.Surface` pixels and directory scans)
  stage directly onto CPU cache unions (`ThumbnailState.staged_cpu`,
  `ResidentAsset.loaded_cpu` / `.promoting_gpu`) with zero render-thread disk
  I/O.
- **Cold-Start I/O Overlap & Adaptive 0% CPU Sleep**: Startup `openPath`
  launches initial file/directory workers *before* window and Vulkan pipeline
  creation to hide cold-start latency, while `computeFrameWaitStrategy` ticks at
  display refresh rate during active animations/glides and drops to blocking
  `waitEvent` (`0%` CPU) once settled (including after the 5s `32 MiB` staging
  buffer idle decay).

______________________________________________________________________

## Performance Telemetry ("Stats for Nerds")

Press `Shift+D` or `Shift+I` (or select **Toggle Stats for Nerds** in the Command
Palette) to open the draggable performance overlay. Snapshots are gathered lazily
in `buildUiViewModel` only while the panel is visible, adding zero overhead
during normal viewing.

### Cache & Worker Residency

| Metric               | What It Represents                                                                                                          |
| :------------------- | :-------------------------------------------------------------------------------------------------------------------------- |
| **Source Mode**      | *(Camera RAW only)* Active RAW stream (`RAW Embedded Preview`).                                                             |
| **RAW Sensor**       | *(Camera RAW only)* Native sensor pixel dimensions and megapixel count parsed from RAW headers.                             |
| **Cache Hit**        | `Yes` if the current slide's texture was already resident in the VRAM LRU cache upon navigation; `No` if decoded on demand. |
| **Memory Size**      | GPU VRAM footprint of the currently displayed texture (including mipmap pyramid levels when enabled).                       |
| **Total Cache VRAM** | Aggregate GPU VRAM across all resident cached slots vs. the `1024 MB` cache budget, plus resident slot count.               |
| **Decode Workers**   | Active background decode tasks vs. maximum worker concurrency (`active / max`).                                             |

### Active Image Decode & GPU Upload

| Metric                 | What It Represents                                                                                                                                                                              |
| :--------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Disk Read Time**     | Background worker I/O time spent reading compressed file or Stage-2 range bytes from storage.                                                                                                   |
| **CBZ Extract Time**   | *(`.cbz` pages only)* Worker time spent inflating the compressed page entry from the ZIP archive.                                                                                               |
| **Compressed Size**    | *(`.cbz` pages only)* Compressed byte size of the page inside the `.cbz` archive.                                                                                                               |
| **Decode Time**        | Worker CPU image decompression duration (`SDL_image` / format decoder).                                                                                                                         |
| **Convert Time**       | Worker CPU pixel-format conversion duration (e.g., SIMD `RGB24`/`BGR24` $\\to$ `RGBA32` when GPU compute unpack is unavailable, or high-bit-depth conversion).                                  |
| **GPU Upload**         | Main-thread staging transfer, optional `RGB24` compute unpack, and mipmap command recording duration for the active texture.                                                                    |
| **GPU Upload Mode**    | `Direct VRAM` when uploaded at full resolution; `CPU Downscale Fallback` when source dimensions exceed hardware texture limits (`16384 px`).                                                    |
| **CPU Fallback Time**  | *(Fallback mode only)* CPU box/bilinear pre-downscale duration prior to GPU upload.                                                                                                             |
| **Thumb Load Time**    | Progressive thumbnail load + GPU upload duration, tagged by source (`Header` = initial 256 KB EXIF read, `Positional` = range read beyond 256 KB, `XDG Cache` = `$XDG_CACHE_HOME/thumbnails/`). |
| **Thumb Hit Ratio**    | Session thumbnail lookup counts across tiers (`Hdr` / `Pos` / `Cache` / `Miss`).                                                                                                                |
| **Thumb Cache Writes** | Completed (and currently `Queued`) background PNG writes to the Freedesktop shared thumbnail cache.                                                                                             |
| **Mipmap Status**      | Whether trilinear mipmaps are enabled for the active texture and the allocated mip level count.                                                                                                 |
| **Mipmap Gen**         | GPU mipmap-generation pass recording time during texture upload.                                                                                                                                |

### Frame Pacing, Phase CPU & UI Geometry (Rolling 60-Frame Window)

| Metric              | What It Represents                                                                                                                                                                                                                               |
| :------------------ | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Frame Rate**      | GPU swapchain presentation rate measured directly at `cmd_buf.submit()`, latched every `500 ms` (`100 ms` initial bootstrap, skipping cold-wake scanout) and settling to `Idle` / `Idle (last X FPS)` after `1.0 s` without contiguous presents. |
| **Frame CPU**       | Total **active** main-thread CPU time per rendered frame (`mean ± stdev` and 60-frame `max` spike), summing Phases `1` through `3b` while **excluding** idle OS event-wait sleep and VSync swapchain wait.                                       |
| **1. Ingest**       | Active CPU spent draining the MPSC worker queue, computing wait strategy, pumping SDL input events (excluding blocking `waitEvent` / `waitEventTimeout` sleep), and syncing pointer hit state.                                                   |
| **2a. Intents**     | Active CPU spent ticking animations, running IPC/palette/keyboard/pointer/slideshow systems, and reducing `AppIntent`s (`sysExecuteIntents`).                                                                                                    |
| **2b. Sync/Upload** | Active CPU spent syncing window state, promoting staged CPU surfaces/thumbnails to GPU VRAM (`sysProcessAssetUploads`), and running cache eviction + prefetch dispatch (`sysUpdateCache`).                                                       |
| **3a. UI Layout**   | Active CPU spent building the read-only `UiViewModel` snapshot and immediate-mode `RectCut` `UiDrawList` commands.                                                                                                                               |
| **3b. GPU Encode**  | Active CPU spent rasterizing/packing uncached glyphs into `TextCache`, batching UI vertices (`buildRenderPacket`), uploading per-frame vertex data, encoding Vulkan/Metal passes, and submitting `cmd_buf` (excluding swapchain wait).           |
| **Swapchain Wait**  | Blocking duration inside `waitAndAcquireSwapchainTexture` waiting on display VSync or GPU backpressure (excluded from `Frame CPU`).                                                                                                              |
| **UI Batches**      | Number of GPU draw batches emitted in the most recent frame.                                                                                                                                                                                     |
| **UI Vertices**     | Total UI quad vertices uploaded in the most recent frame.                                                                                                                                                                                        |

*(Tip: **Toggle Font Atlas Debug** in the Command Palette opens a companion HUD showing the `1024x1024` glyph shelf cursor, active font-size pages, and cached ASCII/Unicode glyph counts.)*

______________________________________________________________________

## Running the Automated Test Suite

We have a native visual regression testing suite that runs the app in headless mode, drives it over UDS IPC, and compares screenshot outputs against golden baselines using SDL3 surface diffs.

```bash
# Run all unit tests and visual integration tests
zig build test

# Overwrite golden baseline screenshots with the current run's outputs
./zig-out/bin/peng-test-runner --update-baselines
```

Mismatched pixels are highlighted in red and saved as a diff image under `testfiles/current-run/diff_*.png`.

______________________________________________________________________

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE) (GPLv3).

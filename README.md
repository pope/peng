# Peng — GPU-Accelerated Image Viewer

Peng is a modern, high-performance, GPU-accelerated image viewer built in **Zig** using **SDL3** (Vulkan/Metal), and **Clay UI**. It is designed to be extremely fast, memory-safe, and scriptable via a thread-safe UNIX Domain Socket (UDS) IPC interface.

______________________________________________________________________

## Features

- **GPU Acceleration:** Uses the modern SDL3 GPU API with Vulkan and Metal backends.
- **Camera RAW Zero-Copy Streaming:** High-performance viewing of Camera RAW images (`.arw`, `.raf`, `.cr2`, `.nef`, `.dng`, `.orf`, `.rw2`, `.pef`) with zero full-file allocations in RAM. Streams 128KB stack headers for sub-0.1ms metadata probing, range-limited positional reads for preview JPEGs, and instant embedded thumbnail rendering during fast navigation.
- **CBZ & Manga Mode Support:** Instant $O(1)$ page seeking inside `.cbz` comic archives with toggleable Right-to-Left (RTL) Manga reading mode (`M` key).
- **Advanced Filtering & Resampling:** Features high-quality resampling shaders including Bilinear, Mitchell-Netravali, and Lanczos3 filters.
- **Command Palette:** Built-in searchable palettes for commands (`F1` or `Ctrl+Shift+P`), file search (`Ctrl+P`), and directory navigator (`Ctrl+O`).
- **Interactive Info & Stats Overlays:** Toggleable draggable panels (`I` key) displaying camera sensor metadata, preview resolutions, CPU/GPU decoding times, active resampling shader, and rendering metrics.
- **Non-Blocking Headless Mode:** Runs offscreen without X11 or Wayland (ideal for CI and servers) with `--headless`.
- **Scriptable IPC Control:** External client controls the viewer's zoom, pan, filters, and takes screenshots in real-time.

______________________________________________________________________

## Supported Formats

| Category            | Formats / Extensions                                                      | Highlights                                                                                                                                                                      |
| :------------------ | :------------------------------------------------------------------------ | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Standard Raster** | `.png`, `.jpg`, `.jpeg`, `.webp`, `.avif`, `.bmp`, `.tga`, `.svg`, `.gif` | High-DPI mipmapped GPU rendering, SIMD color conversions                                                                                                                        |
| **Comic Archives**  | `.cbz`                                                                    | Central Directory parsing with $O(1)$ page seeking and RTL Manga mode                                                                                                           |
| **Camera RAW**      | `.arw`, `.raf`, `.cr2`, `.nef`, `.dng`, `.orf`, `.rw2`, `.pef`            | Zero full-file allocations, sub-0.1ms probe, range-limited embedded previews, instant thumbnail scrubbing, EXIF orientation auto-correction, and raw sensor dimension reporting |

______________________________________________________________________

## Keyboard Shortcuts

| Shortcut                                | Action                                                   |
| :-------------------------------------- | :------------------------------------------------------- |
| `n` / `]` / `Space` / `Right`           | Next Image                                               |
| `p` / `[` / `Backspace` / `Left`        | Previous Image                                           |
| `Home` / `End`                          | Jump to First / Last Image                               |
| `i` / `+` / `=`                         | Zoom In                                                  |
| `o` / `-`                               | Zoom Out                                                 |
| `a`                                     | Actual Size (1:1 / 100% Zoom)                            |
| `r` / `0`                               | Reset Zoom & Pan                                         |
| `h` / `j` / `k` / `l`                   | Pan Left / Down / Up / Right (when zoomed)               |
| `e` / `>`                               | Rotate Clockwise (90°)                                   |
| `E` / `<`                               | Rotate Counter-Clockwise (90°)                           |
| `s`                                     | Cycle Scale Mode (Shrink, Full, Crop, Actual, Fit W/H)   |
| `S` (Shift+s)                           | Cycle Resampling Filter (Nearest, Linear, Mitchell, etc) |
| `b` / `B` (Shift+b)                     | Increase / Decrease Brightness                           |
| `c` / `C` (Shift+c)                     | Increase / Decrease Contrast                             |
| `Shift+R`                               | Reset Brightness & Contrast                              |
| `d`                                     | Toggle Image Info Overlay                                |
| `Shift+D`                               | Toggle Performance / Stats Overlay                       |
| `t`                                     | Toggle Title Bar Overlay                                 |
| `m`                                     | Toggle Manga Mode (Right-to-Left)                        |
| `f` / `F11`                             | Toggle Borderless Fullscreen                             |
| `F5` / `Ctrl+R`                         | Refresh / Rescan Directory                               |
| `:` / `?` / `/` / `F1` / `Ctrl+Shift+P` | Open Command Palette (Actions)                           |
| `Ctrl+P`                                | Open File Search Palette                                 |
| `Ctrl+O`                                | Open Directory Navigator Palette                         |
| `q` / `Esc`                             | Close Palette / Exit Application                         |

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
# Enter the Nix development shell (contains Zig 0.16.0 and SDL3 dependencies)
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

| Flag                 | Argument                                                    | Description                                              |
| :------------------- | :---------------------------------------------------------- | :------------------------------------------------------- |
| `-h`, `--help`       | None                                                        | Displays the help message and available options.         |
| `-W`, `--windowless` | None                                                        | Runs in borderless/windowless mode (no titlebar chrome). |
| `--scale`            | `none`, `shrink`, `full`, `crop`, `fit_width`, `fit_height` | Sets the default image scaling/fitting mode.             |
| `--blur`             | None                                                        | Enables background glassmorphism blur effect (default).  |
| `--no-blur`          | None                                                        | Disables background glassmorphism blur effect.           |
| `--title`            | None                                                        | Shows floating title bar overlay on startup.             |
| `--headless`         | None                                                        | Runs without opening an OS display window.               |
| `--test-mode`        | None                                                        | Puts the window and event loop into test configuration.  |
| `--update-baselines` | None                                                        | Overwrites baseline golden screenshots.                  |
| `--ipc`              | None                                                        | Enables the IPC UNIX Domain Socket server.               |

Aliases:

- `--windowless` can also be specified as `--borderless` or `--undecorated`.

______________________________________________________________________

## Remote IPC Control (`peng-msg`)

When `peng` is launched with the `--ipc` flag, it starts a UDS server at `/tmp/peng-$PID.sock` and prints the socket path to `stdout`.

You can send commands to a running instance using the `peng-msg` utility:

```bash
# General Usage:
./zig-out/bin/peng-msg <socket_path> <command_words...>

# Examples:
# Adjust zoom factor (min 0.1, max 10.0)
./zig-out/bin/peng-msg /tmp/peng-1234.sock zoom 2.5

# Pan coordinates (x, y)
./zig-out/bin/peng-msg /tmp/peng-1234.sock pan 100 -50

# Set Scale Mode (none, shrink, full, crop, fit_width, fit_height)
./zig-out/bin/peng-msg /tmp/peng-1234.sock scale fit_width
./zig-out/bin/peng-msg /tmp/peng-1234.sock scale fit_height

# Set Manga Mode (true, false)
./zig-out/bin/peng-msg /tmp/peng-1234.sock manga true

# Toggle Windowless / Borderless Mode (toggle, true, false, on, off)
./zig-out/bin/peng-msg /tmp/peng-1234.sock windowless toggle
./zig-out/bin/peng-msg /tmp/peng-1234.sock borderless true

# Toggle Floating Title Bar Overlay (toggle, true, false)
./zig-out/bin/peng-msg /tmp/peng-1234.sock title toggle

# Adjust brightness and contrast
./zig-out/bin/peng-msg /tmp/peng-1234.sock adjust 0.2 -0.1

# Apply Resampling Filter (mitchell, lanczos3, lanczos3_spline, linear, pixel_art)
./zig-out/bin/peng-msg /tmp/peng-1234.sock filter mitchell
./zig-out/bin/peng-msg /tmp/peng-1234.sock filter lanczos3
./zig-out/bin/peng-msg /tmp/peng-1234.sock filter lanczos3_spline

# Navigation
./zig-out/bin/peng-msg /tmp/peng-1234.sock next
./zig-out/bin/peng-msg /tmp/peng-1234.sock prev

# Toggle UI Palettes (action, files, none)
./zig-out/bin/peng-msg /tmp/peng-1234.sock palette action
./zig-out/bin/peng-msg /tmp/peng-1234.sock palette none

# Toggle Thumbnail Preview (true, false, toggle)
./zig-out/bin/peng-msg /tmp/peng-1234.sock thumb toggle

# Toggle Clay Layout Debug Borders
./zig-out/bin/peng-msg /tmp/peng-1234.sock debug true

# Wait for background image decoder to finish loading
./zig-out/bin/peng-msg /tmp/peng-1234.sock wait_load

# Quit the app
./zig-out/bin/peng-msg /tmp/peng-1234.sock quit
```

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

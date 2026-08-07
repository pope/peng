# Peng — GPU-Accelerated Image Viewer

Peng is a modern, high-performance, GPU-accelerated image viewer built in **Zig** using **SDL3** (Vulkan/Metal), and **Clay UI**. It is designed to be extremely fast, memory-safe, and scriptable via a thread-safe UNIX Domain Socket (UDS) IPC interface.

______________________________________________________________________

## Features

- **GPU Acceleration:** Uses the modern SDL3 GPU API with Vulkan and Metal backends.
- **CBZ & Manga Mode Support:** Instant $O(1)$ page seeking inside `.cbz` comic archives with toggleable Right-to-Left (RTL) Manga reading mode (`M` key).
- **Advanced Filtering & Resampling:** Features high-quality resampling shaders including Bilinear, Mitchell-Netravali, and Lanczos3 filters.
- **Command Palette:** Built-in searchable palettes for commands (`F1` or `Ctrl+Shift+P`), file search (`Ctrl+P`), and directory navigator (`Ctrl+O`).
- **Interactive Stats Overlay:** Toggleable sidebar (`I` key) displaying CPU/GPU decoding times, active resampling shader, rendering metrics, and image attributes.
- **Non-Blocking Headless Mode:** Runs offscreen without X11 or Wayland (ideal for CI and servers) with `--headless`.
- **Scriptable IPC Control:** External client controls the viewer's zoom, pan, filters, and takes screenshots in real-time.

______________________________________________________________________

## Keyboard Shortcuts

| Shortcut              | Action                               |
| :-------------------- | :----------------------------------- |
| `F1` / `Ctrl+Shift+P` | Open Command Palette (Actions)       |
| `Ctrl+P`              | Open File Search Palette             |
| `Ctrl+O`              | Open Directory Navigator Palette     |
| `I`                   | Toggle Stats Overlay                 |
| `M`                   | Toggle Manga Mode (Right-to-Left)    |
| `F` / `F11`           | Toggle Fullscreen                    |
| `Space` / `Right`     | Next Image (Prepares Next Page)      |
| `Backspace` / `Left`  | Previous Image                       |
| `Home` / `End`        | Jump to First / Last Image           |
| `=` / `-`             | Zoom In / Out                        |
| `R` / `0`             | Reset Zoom & Pan                     |
| `[` / `]`             | Rotate Counter-Clockwise / Clockwise |
| `P` / `O`             | Increase / Decrease Brightness       |
| `L` / `K`             | Increase / Decrease Contrast         |
| `Shift+R`             | Reset Brightness & Contrast          |
| `Esc`                 | Close Palette / Exit Application     |

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

| Flag                 | Argument                                                   | Description                                             |
| :------------------- | :--------------------------------------------------------- | :------------------------------------------------------ |
| `--scale`            | `none`, `shrink`, `full`, `crop`, `fit_width`, `fit_height` | Sets the default image scaling/fitting mode.            |
| `--headless`         | None                                                       | Runs without opening an OS display window.              |
| `--test-mode`        | None                                                       | Puts the window and event loop into test configuration. |
| `--update-baselines` | None                                                       | Overwrites baseline golden screenshots.                 |
| `--ipc`              | None                                                       | Enables the IPC UNIX Domain Socket server.              |

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

# Adjust brightness and contrast
./zig-out/bin/peng-msg /tmp/peng-1234.sock adjust 0.2 -0.1

# Apply Resampling Filter (mitchell, lanczos3, linear, pixel_art)
./zig-out/bin/peng-msg /tmp/peng-1234.sock filter mitchell
./zig-out/bin/peng-msg /tmp/peng-1234.sock filter lanczos3

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

# VRAM Budgeting, EXIF Header Parsing & Navigation Throttling

## 1. VRAM Cache Budgeting & Memory Safety Invariants

- **VRAM Budget Calculation with Mipmap Overhead**:
  When computing VRAM memory footprints, account for the base RGBA32 texture size ($W \\times H \\times 4\\text{ bytes}$) plus the $+33%$ mipmap pyramid overhead ($\\frac{4}{3} \\times \\text{base size}$). Ensure budget caps (e.g. $1024\\text{ MB}$) can accommodate multiple high-resolution ($24\\text{MP}-50\\text{MP}$) images simultaneously.
- **Neighbor Slot Protection**:
  In VRAM cache eviction routines (`enforceVramBudget`), protect the current image and its immediate neighbors ($\\pm 2$ slots) from eviction to prevent constant re-decoding during user navigation.
- **Mutex Ownership Invariants**:
  Destroy `SDL_Mutex` objects in exactly one owner lifecycle method (e.g. `ViewerState.deinit()`). Do NOT place duplicate `defer c.SDL_DestroyMutex()` calls at initialization callsites, as double-destroying a mutex triggers glibc heap corruption (`malloc_consolidate`: unaligned fastbin chunk).
- **HashMap String Key Lifetimes in Zig**:
  Calling `clearRetainingCapacity()` or `deinit()` on a `std.StringHashMap` or `std.AutoHashMapUnmanaged` with dynamically allocated keys (`allocator.dupe`) clears map slots without freeing key memory. Always iterate `keyIterator()` to free `key.*` before clearing or deinitializing:
  ```zig
  var rot_iter = self.rotation_map.keyIterator();
  while (rot_iter.next()) |key| {
      self.allocator.free(key.*);
  }
  self.rotation_map.clearRetainingCapacity();
  ```

______________________________________________________________________

## 2. Synchronous Header Dimension Parsing & EXIF Rules

- **Frame-1 Target Aspect Layout**:
  Parse full image dimensions (`full_w`, `full_h`) directly from file headers synchronously on the main thread (< 0.1 ms I/O) before spawning decode worker threads. This allows layout math (`getBaseScale`, aspect ratio fitting) to set exact canvas dimensions on Frame 1, eliminating layout jumps and window jitter.
- **EXIF APP1 Segment Skipping Rule**:
  Camera JPEGs embed EXIF thumbnails inside the `APP1` (`0xFF, 0xE1`) segment. When scanning for main image `SOF0`/`SOF2` frame headers, `APP1` segment payloads MUST be explicitly skipped (`idx += seg_len`) to prevent matching the embedded thumbnail's frame header.
- **EXIF Tag Priority**:
  Check EXIF TIFF tags `0x0100` (`ImageWidth`), `0x0101` (`ImageLength`), `0xA002` (`PixelXDimension`), and `0xA003` (`PixelYDimension`) in IFD0 and ExifIFD first, as they reside in the initial 1 KB of the file.

______________________________________________________________________

## 3. Throttled Navigation & Settled Preloading

- **Throttling During Fast Navigation**:
  During rapid scrolling (< 150ms step interval), constrain preload queues strictly to the active image `idx`. Suppress neighbor preloading (+1, -1, +2, -2) to prevent thread/VRAM contention and avoid driver queue submission exhaustion (`VK_ERROR_DEVICE_LOST`).
- **Settled Preload Trigger**:
  In the main frame loop, check if navigation has settled (> 150ms idle time). When idle, invoke `checkIdlePreload()` once to populate neighboring images into VRAM during idle time.

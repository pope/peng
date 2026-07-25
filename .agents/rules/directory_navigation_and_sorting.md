# Directory Navigation & Alphabetical Sorting Invariants

## Keyboard Control Mapping

- `Right`: Navigate into the highlighted subfolder in the directory navigator palette.
- `Enter`: Load the highlighted subfolder's images directly into the viewer and close palette.
- `Shift+Enter`: Load the current directory's images directly into the viewer and close palette.
- `Left`: Step up to the parent directory within the navigator.

## Automatic Step-Up for Empty Subfolder Lists

- When opening the directory navigator (`Ctrl+O`), if the target directory contains 0 subdirectories (e.g. a leaf folder containing only image files), automatically step up to the parent directory and pre-select the child directory in the list.

## Location Persistence Across Resets

- Retain `last_scanned_dir` and `last_nav_dir` in app state across palette resets so re-opening navigation after opening any directory (even one with 0 images) returns to that location instead of resetting to `.`.

## Consistent Case-Insensitive Alphabetical Sorting

- ALL filesystem listings (viewer image playback lists, threaded directory scanners, and directory navigator palette entries) MUST consistently use case-insensitive sorting (`std.ascii.lessThanIgnoreCase`) instead of raw byte ordering (`std.mem.lessThan`).
- This prevents uppercase letters (e.g. `Z`) from sorting before lowercase letters (e.g. `a`) and maintains uniform ordering across all UI components.

# Zig Type Initialization & Result Location Style

## Prefer Result Location Type Inference for Container Initializations

- When initializing containers (`std.ArrayList`, `std.StringHashMap`, `std.AutoHashMap`, `std.ArrayListUnmanaged`, etc.), leverage Zig's result location type inference (`.empty`, `.init(...)`, `.initCapacity(...)`) rather than redundantly spelling out the container type on the right-hand side.

## Struct Fields & Struct Initialization Literals

- For struct field defaults and struct literal field assignments where the field type is already explicit, use leading-dot syntax directly:
  ```zig
  // ✅ Recommended
  last_scanned_dir: std.ArrayList(u8) = .empty,
  rotation_map: std.StringHashMap(f32) = .init(allocator),

  .keys_pressed = .empty,
  .rotation_map = .init(allocator),

  // ❌ Avoid
  last_scanned_dir: std.ArrayList(u8) = std.ArrayList(u8).empty,
  .keys_pressed = std.ArrayList(Key).empty,
  ```

## Local Variable Declarations (var / const)

- Put explicit type annotations on local variable declarations (`var name: Type` or `const name: Type`) and use leading-dot initializers on the right-hand side, rather than leaving the variable untyped and spelling out `Type.initializer`:
  ```zig
  // ✅ Recommended
  var dir_entries: std.ArrayList([]const u8) = .empty;
  var list: std.ArrayList(TextChunk) = try .initCapacity(allocator, 1);
  var command_buf: std.ArrayList(u8) = .empty;
  const default_map: std.StringHashMap(f32) = .init(allocator);

  // ❌ Avoid
  var dir_entries = std.ArrayList([]const u8).empty;
  var list = try std.ArrayList(TextChunk).initCapacity(allocator, 1);
  var command_buf = std.ArrayList(u8).empty;
  ```

## Enum & Optional Result Location Inference

- The same leading-dot inference applies to enum values and optional types when the target type on the LHS or field is explicit:
  ```zig
  // ✅ Recommended
  var mode: DisplayState = .windowed;
  var texture: ?sdl.gpu.Texture = null;

  // ❌ Avoid
  var mode = DisplayState.windowed;
  ```

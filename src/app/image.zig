const std = @import("std");
const sdl = @import("sdl");
const graphics = @import("../ui/graphics.zig");
const fs = @import("fs.zig");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;

pub const CacheStatusTag = enum {
    decoding,
    loaded_cpu,
    loaded_gpu,
    uploading,
    failed,
};

pub const CacheStatus = union(CacheStatusTag) {
    decoding: struct {
        has_thread: bool = false,
    },
    loaded_cpu: struct {
        surface: sdl.Surface,
        w: f32,
        h: f32,
        size_bytes: u64,
        mime_type: []const u8,
        decode_time_ms: f64,
        conversion_time_ms: f64,
        has_thumb: bool = false,
        thumb_w: f32 = 0.0,
        thumb_h: f32 = 0.0,
        thumb_upload_time_ms: f64 = 0.0,
    },
    loaded_gpu: struct {
        gpu_texture: sdl.gpu.Texture,
        w: f32,
        h: f32,
        size_bytes: u64,
        mime_type: []const u8,
        decode_time_ms: f64,
        conversion_time_ms: f64,
        upload_time_ms: f64,
        memory_size_bytes: usize,
        num_mip_levels: u32 = 1,
        mipmap_time_ms: f64 = 0.0,
        has_thumb: bool = false,
        thumb_w: f32 = 0.0,
        thumb_h: f32 = 0.0,
        thumb_upload_time_ms: f64 = 0.0,
    },
    uploading: void,
    failed: void,
};

pub const CacheEntry = struct {
    index: usize,
    generation: usize,
    status: CacheStatus,
    thumb_gpu_texture: ?sdl.gpu.Texture = null,
    thumb_w: f32 = 0.0,
    thumb_h: f32 = 0.0,
    full_w: f32 = 0.0,
    full_h: f32 = 0.0,
    exif_orientation: f32 = 0.0,
    has_thumb: bool = false,
    thumb_upload_time_ms: f64 = 0.0,

    pub fn deinit(self: *CacheEntry, gpu_device: ?sdl.gpu.Device) void {
        if (self.thumb_gpu_texture) |thumb_tex| {
            if (gpu_device) |dev| {
                dev.releaseTexture(thumb_tex);
            }
            self.thumb_gpu_texture = null;
        }
        switch (self.status) {
            .loaded_cpu => |cpu| cpu.surface.destroy(),
            .loaded_gpu => |gpu| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(gpu.gpu_texture);
                }
            },
            else => {},
        }
    }
};

pub const TextureHandle = struct {
    index: usize,
    generation: usize,
};

pub const CacheSlotMap = struct {
    entries: std.ArrayListUnmanaged(CacheEntry) = .empty,

    pub fn deinit(self: *CacheSlotMap, allocator: std.mem.Allocator, gpu_device: ?sdl.gpu.Device) void {
        for (self.entries.items) |*entry| {
            entry.deinit(gpu_device);
        }
        self.entries.deinit(allocator);
    }

    pub fn clear(self: *CacheSlotMap, gpu_device: ?sdl.gpu.Device) void {
        for (self.entries.items) |*entry| {
            entry.deinit(gpu_device);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn clearRetainingCapacity(self: *CacheSlotMap) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn get(self: *CacheSlotMap, index: usize) ?*CacheEntry {
        for (self.entries.items) |*entry| {
            if (entry.index == index) return entry;
        }
        return null;
    }

    pub fn getWithGeneration(self: *CacheSlotMap, index: usize, generation: usize) ?*CacheEntry {
        for (self.entries.items) |*entry| {
            if (entry.index == index and entry.generation == generation) return entry;
        }
        return null;
    }

    pub fn getTexture(self: *CacheSlotMap, handle: TextureHandle) ?sdl.gpu.Texture {
        if (self.getWithGeneration(handle.index, handle.generation)) |entry| {
            switch (entry.status) {
                .loaded_gpu => |gpu| return gpu.gpu_texture,
                else => {},
            }
        }
        return null;
    }

    pub fn getSurface(self: *CacheSlotMap, handle: TextureHandle) ?sdl.Surface {
        if (self.getWithGeneration(handle.index, handle.generation)) |entry| {
            switch (entry.status) {
                .loaded_cpu => |cpu| return cpu.surface,
                else => {},
            }
        }
        return null;
    }

    pub fn updateStatus(self: *CacheSlotMap, index: usize, generation: usize, status: CacheStatus) bool {
        if (self.getWithGeneration(index, generation)) |entry| {
            entry.status = status;
            return true;
        }
        return false;
    }

    pub fn append(self: *CacheSlotMap, allocator: std.mem.Allocator, entry: CacheEntry) !void {
        try self.entries.append(allocator, entry);
    }

    pub fn remove(self: *CacheSlotMap, index_in_list: usize) CacheEntry {
        return self.entries.orderedRemove(index_in_list);
    }

    pub fn removeAndDeinit(self: *CacheSlotMap, index_in_list: usize, gpu_device: ?sdl.gpu.Device) void {
        var entry = self.entries.orderedRemove(index_in_list);
        entry.deinit(gpu_device);
    }

    pub const DEFAULT_MAX_VRAM_BYTES: usize = 1024 * 1024 * 1024;

    pub fn getTotalVramBytes(self: *const CacheSlotMap) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| {
            switch (entry.status) {
                .loaded_gpu => |gpu| total += gpu.memory_size_bytes,
                else => {},
            }
        }
        return total;
    }

    pub fn enforceVramBudget(self: *CacheSlotMap, gpu_device: ?sdl.gpu.Device, current_index: ?usize, max_bytes: usize) void {
        while (self.getTotalVramBytes() > max_bytes) {
            var max_dist: usize = 0;
            var victim_idx: ?usize = null;

            for (self.entries.items, 0..) |entry, i| {
                if (entry.status == .loaded_gpu) {
                    if (current_index) |cur| {
                        if (entry.index == cur) continue;
                        const dist = if (entry.index > cur) entry.index - cur else cur - entry.index;
                        // Protect immediate neighbors (dist <= 2) if possible
                        if (dist <= 2 and self.entries.items.len <= 5) continue;
                        if (dist >= max_dist) {
                            max_dist = dist;
                            victim_idx = i;
                        }
                    } else {
                        victim_idx = i;
                        break;
                    }
                }
            }

            if (victim_idx) |v_i| {
                self.removeAndDeinit(v_i, gpu_device);
            } else {
                break;
            }
        }
    }
};

pub const DecodeArgs = struct {
    state: *ViewerState,
    index: usize,
    generation: usize,
    path: [:0]const u8,
};

pub fn detectMimeType(io: std.Io, path: []const u8) []const u8 {
    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch return "unknown";
    defer file.close(io);

    var header: [12]u8 = undefined;
    var slices = [_][]u8{&header};
    const bytes_read = file.readPositional(io, &slices, 0) catch return "unknown";
    if (bytes_read < 4) return "unknown";

    if (std.mem.startsWith(u8, &header, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) {
        return "image/png";
    }
    if (std.mem.startsWith(u8, &header, &[_]u8{ 0xFF, 0xD8, 0xFF })) {
        return "image/jpeg";
    }
    if (std.mem.startsWith(u8, &header, "GIF87a") or std.mem.startsWith(u8, &header, "GIF89a")) {
        return "image/gif";
    }
    if (std.mem.startsWith(u8, &header, "BM")) {
        return "image/bmp";
    }
    if (bytes_read >= 12 and std.mem.startsWith(u8, &header, "RIFF") and std.mem.eql(u8, header[8..12], "WEBP")) {
        return "image/webp";
    }

    const ext = std.fs.path.extension(path);
    if (fs.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (fs.eqlIgnoreCase(ext, ".jpg") or fs.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (fs.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (fs.eqlIgnoreCase(ext, ".bmp")) return "image/bmp";
    if (fs.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (fs.eqlIgnoreCase(ext, ".tga")) return "image/x-tga";

    return "unknown";
}

pub fn decodeWorker(args: *DecodeArgs) void {
    const state = args.state;
    const index = args.index;
    const path = args.path;
    defer {
        const alloc = state.allocator;
        alloc.free(path);
        alloc.destroy(args);
        _ = state.active_decode_threads.fetchSub(1, .release);
        _ = state.active_threads.fetchSub(1, .release);
        fs.wakeUpMainThread();
    }

    const exif_rot = readJpegExifOrientation(state.io, path) orelse 0.0;
    if (exif_rot != 0.0) {
        state.event_queue.push(state.allocator, state.io, .{
            .exif_orientation_parsed = .{
                .index = index,
                .generation = args.generation,
                .orientation = exif_rot,
            },
        }) catch |err| std.log.err("Failed to push EXIF orientation event: {}", .{err});
        fs.wakeUpMainThread();
    }

    const isValidJob = struct {
        fn check(st: *ViewerState, idx: usize, gen: usize) bool {
            if (st.exiting.load(.acquire)) return false;
            st.cache_mutex.lockUncancelable(st.io);
            defer st.cache_mutex.unlock(st.io);
            return st.cache.getWithGeneration(idx, gen) != null;
        }
    }.check;

    if (!isValidJob(state, index, args.generation)) return;

    const mime_type = detectMimeType(state.io, path);

    if (!isValidJob(state, index, args.generation)) return;

    // Attempt fast EXIF thumbnail decoding for instant placeholder preview
    if (std.mem.eql(u8, mime_type, "image/jpeg") and state.gpu_device != null) {
        var header_buf: [65536]u8 = undefined;
        var thumb_file = std.Io.Dir.openFile(std.Io.Dir.cwd(), state.io, path, .{}) catch null;
        if (thumb_file) |*f| {
            defer f.close(state.io);
            var slices = [_][]u8{&header_buf};
            const n = f.readPositional(state.io, &slices, 0) catch 0;
            if (n > 0) {
                const full_dims = readJpegDimensions(header_buf[0..n]);
                if (extractJpegThumbnail(header_buf[0..n])) |thumb_bytes| {
                    if (sdl.Surface.loadConstMemOpt(thumb_bytes)) |t_surf| {
                        const full_w: f32 = if (full_dims) |d| d.w else 0.0;
                        const full_h: f32 = if (full_dims) |d| d.h else 0.0;
                        state.event_queue.push(state.allocator, state.io, .{
                            .thumb_decoded = .{
                                .index = index,
                                .generation = args.generation,
                                .surface = t_surf,
                                .w = @floatFromInt(t_surf.w()),
                                .h = @floatFromInt(t_surf.h()),
                                .full_w = full_w,
                                .full_h = full_h,
                                .exif_orientation = exif_rot,
                            },
                        }) catch {
                            t_surf.destroy();
                        };
                        fs.wakeUpMainThread();
                    }
                }
            }
        }
    }

    if (!isValidJob(state, index, args.generation)) return;

    const start_decode = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadFilePtr(path.ptr);
    const end_decode = sdl.timer.getTicksNs();

    const decode_time_ms = @as(f64, @floatFromInt(end_decode - start_decode)) / 1_000_000.0;

    if (!isValidJob(state, index, args.generation)) {
        if (surface) |surf| surf.destroy();
        return;
    }

    var final_surface = surface;
    var conversion_time_ms: f64 = 0.0;
    if (surface) |surf| {
        if (state.window_pixel_format != sdl.PixelFormat.unknown and surf.format() != state.window_pixel_format) {
            const start_convert = sdl.timer.getTicksNs();
            const converted = surf.convert(state.window_pixel_format);
            const end_convert = sdl.timer.getTicksNs();

            if (converted) |conv| {
                conversion_time_ms = @as(f64, @floatFromInt(end_convert - start_convert)) / 1_000_000.0;
                surf.destroy();
                final_surface = conv;
            } else {
                std.log.err("SDL_ConvertSurface failed: {s}", .{sdl.getError()});
            }
        }

        if (final_surface) |f_surf| {
            const max_dim: i32 = 8192;
            if (f_surf.w() > max_dim or f_surf.h() > max_dim) {
                var new_w = f_surf.w();
                var new_h = f_surf.h();
                if (f_surf.w() > f_surf.h()) {
                    new_w = max_dim;
                    new_h = @divTrunc(f_surf.h() * max_dim, f_surf.w());
                } else {
                    new_h = max_dim;
                    new_w = @divTrunc(f_surf.w() * max_dim, f_surf.h());
                }
                new_w = @max(1, new_w);
                new_h = @max(1, new_h);

                const scaled = f_surf.scale(new_w, new_h, .linear);
                if (scaled) |sc| {
                    f_surf.destroy();
                    final_surface = sc;
                } else {
                    std.log.err("decodeWorker: SDL_ScaleSurface failed: {s}", .{sdl.getError()});
                }
            }
        }
    }

    // Stat the file
    var size_bytes: u64 = 0;
    if (std.Io.Dir.statFile(std.Io.Dir.cwd(), state.io, path, .{})) |s| {
        size_bytes = s.size;
    } else |err| {
        std.log.debug("decodeWorker: statFile failed for '{s}': {any}", .{ path, err });
    }

    if (!isValidJob(state, index, args.generation)) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());

        state.event_queue.push(state.allocator, state.io, .{
            .image_decoded = .{
                .index = index,
                .generation = args.generation,
                .surface = f_surf,
                .w = orig_w,
                .h = orig_h,
                .mime_type = mime_type,
                .size_bytes = size_bytes,
                .decode_time_ms = decode_time_ms,
                .conversion_time_ms = conversion_time_ms,
                .exif_orientation = exif_rot,
            },
        }) catch {
            f_surf.destroy();
        };
        fs.wakeUpMainThread();
    } else {
        state.event_queue.push(state.allocator, state.io, .{
            .decode_failed = .{
                .index = index,
                .generation = args.generation,
            },
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
        fs.wakeUpMainThread();
    }

    return;
}

pub const JpegDimensions = struct { w: f32, h: f32 };

pub fn parseExifDimensions(data: []const u8) ?JpegDimensions {
    if (data.len < 14) return null;
    if (data[0] != 0xFF or data[1] != 0xD8) return null;

    var idx: usize = 2;
    while (idx + 4 <= data.len) {
        if (data[idx] != 0xFF) break;
        var marker_offset = idx + 1;
        while (marker_offset < data.len and data[marker_offset] == 0xFF) {
            marker_offset += 1;
        }
        if (marker_offset >= data.len) break;
        const marker = data[marker_offset];
        idx = marker_offset + 1;

        if (marker == 0xD9 or marker == 0xDA) break;

        if (idx + 2 > data.len) break;
        const seg_len = (@as(usize, data[idx]) << 8) | @as(usize, data[idx + 1]);
        if (seg_len < 2 or idx + seg_len > data.len) break;

        const payload = data[idx + 2 .. idx + seg_len];
        idx += seg_len;

        if (marker == 0xE1) {
            if (payload.len < 14) continue;
            if (!std.mem.startsWith(u8, payload, "Exif\x00\x00")) continue;

            const tiff = payload[6..];
            if (tiff.len < 8) continue;

            const is_le = if (std.mem.eql(u8, tiff[0..2], "II")) true else if (std.mem.eql(u8, tiff[0..2], "MM")) false else continue;

            const sig = if (is_le) std.mem.readInt(u16, tiff[2..4][0..2], .little) else std.mem.readInt(u16, tiff[2..4][0..2], .big);
            if (sig != 0x002A) continue;

            const ifd0_off = if (is_le) std.mem.readInt(u32, tiff[4..8][0..4], .little) else std.mem.readInt(u32, tiff[4..8][0..4], .big);
            if (ifd0_off >= tiff.len or ifd0_off + 2 > tiff.len) continue;

            var width: ?u32 = null;
            var height: ?u32 = null;
            var exif_sub_ifd_off: ?u32 = null;

            const parseIfd = struct {
                fn run(t: []const u8, off: usize, le: bool, w_out: *?u32, h_out: *?u32, sub_out: ?*?u32) void {
                    if (off >= t.len or off + 2 > t.len) return;
                    const num = if (le) std.mem.readInt(u16, t[off..][0..2], .little) else std.mem.readInt(u16, t[off..][0..2], .big);
                    var entry_off = off + 2;
                    var i: usize = 0;
                    while (i < num) : (i += 1) {
                        if (entry_off + 12 > t.len) break;
                        const entry = t[entry_off .. entry_off + 12];
                        entry_off += 12;

                        const tag = if (le) std.mem.readInt(u16, entry[0..2][0..2], .little) else std.mem.readInt(u16, entry[0..2][0..2], .big);
                        const type_id = if (le) std.mem.readInt(u16, entry[2..4][0..2], .little) else std.mem.readInt(u16, entry[2..4][0..2], .big);

                        var val: u32 = 0;
                        if (type_id == 3) {
                            val = if (le) std.mem.readInt(u16, entry[8..10][0..2], .little) else std.mem.readInt(u16, entry[8..10][0..2], .big);
                        } else if (type_id == 4) {
                            val = if (le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
                        }

                        if (tag == 0x0100 or tag == 0xA002) {
                            if (val > 0) w_out.* = val;
                        } else if (tag == 0x0101 or tag == 0xA003) {
                            if (val > 0) h_out.* = val;
                        } else if (tag == 0x8769 and sub_out != null) {
                            if (val > 0) sub_out.?.* = val;
                        }
                    }
                }
            }.run;

            parseIfd(tiff, ifd0_off, is_le, &width, &height, &exif_sub_ifd_off);

            if (exif_sub_ifd_off) |sub_off| {
                parseIfd(tiff, sub_off, is_le, &width, &height, null);
            }

            if (width != null and height != null) {
                return JpegDimensions{ .w = @floatFromInt(width.?), .h = @floatFromInt(height.?) };
            }
        }
    }
    return null;
}

pub fn readJpegDimensions(data: []const u8) ?JpegDimensions {
    if (parseExifDimensions(data)) |dims| return dims;
    if (data.len < 4) return null;
    if (data[0] != 0xFF or data[1] != 0xD8) return null;

    var idx: usize = 2;
    while (idx + 4 <= data.len) {
        if (data[idx] != 0xFF) break;
        var marker_offset = idx + 1;
        while (marker_offset < data.len and data[marker_offset] == 0xFF) {
            marker_offset += 1;
        }
        if (marker_offset >= data.len) break;
        const marker = data[marker_offset];
        idx = marker_offset + 1;

        if (marker == 0xD9 or marker == 0xDA) break;

        if (idx + 2 > data.len) break;
        const seg_len = (@as(usize, data[idx]) << 8) | @as(usize, data[idx + 1]);
        if (seg_len < 2 or idx + seg_len > data.len) break;

        // Skip APP1 (0xE1) segment so we don't match the embedded thumbnail's SOF marker inside EXIF payload
        if (marker == 0xE1) {
            idx += seg_len;
            continue;
        }

        if ((marker >= 0xC0 and marker <= 0xC3) or
            (marker >= 0xC5 and marker <= 0xC7) or
            (marker >= 0xC9 and marker <= 0xCB) or
            (marker >= 0xCD and marker <= 0xCF))
        {
            if (idx + 7 <= data.len) {
                const h = (@as(u16, data[idx + 3]) << 8) | @as(u16, data[idx + 4]);
                const w = (@as(u16, data[idx + 5]) << 8) | @as(u16, data[idx + 6]);
                if (w > 0 and h > 0) {
                    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
                }
            }
        }

        idx += seg_len;
    }
    return null;
}

pub fn parseExifOrientation(data: []const u8) ?f32 {
    if (data.len < 14) return null;
    if (data[0] != 0xFF or data[1] != 0xD8) return null;

    var idx: usize = 2;
    while (idx + 4 <= data.len) {
        if (data[idx] != 0xFF) break;
        var marker_offset = idx + 1;
        while (marker_offset < data.len and data[marker_offset] == 0xFF) {
            marker_offset += 1;
        }
        if (marker_offset >= data.len) break;
        const marker = data[marker_offset];
        idx = marker_offset + 1;

        if (marker == 0xD9 or marker == 0xDA) break;

        if (idx + 2 > data.len) break;
        const seg_len = (@as(usize, data[idx]) << 8) | @as(usize, data[idx + 1]);
        if (seg_len < 2 or idx + seg_len > data.len) break;

        const payload = data[idx + 2 .. idx + seg_len];
        idx += seg_len;

        if (marker == 0xE1) {
            if (payload.len < 14) continue;
            if (!std.mem.startsWith(u8, payload, "Exif\x00\x00")) continue;

            const tiff = payload[6..];
            if (tiff.len < 8) continue;

            const is_le = if (std.mem.eql(u8, tiff[0..2], "II")) true else if (std.mem.eql(u8, tiff[0..2], "MM")) false else continue;

            const sig = if (is_le) std.mem.readInt(u16, tiff[2..4][0..2], .little) else std.mem.readInt(u16, tiff[2..4][0..2], .big);
            if (sig != 0x002A) continue;

            const ifd0_off = if (is_le) std.mem.readInt(u32, tiff[4..8][0..4], .little) else std.mem.readInt(u32, tiff[4..8][0..4], .big);
            if (ifd0_off >= tiff.len or ifd0_off + 2 > tiff.len) continue;

            const num_entries = if (is_le) std.mem.readInt(u16, tiff[ifd0_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd0_off..][0..2], .big);
            var entry_off = ifd0_off + 2;

            var i: usize = 0;
            while (i < num_entries) : (i += 1) {
                if (entry_off + 12 > tiff.len) break;
                const entry = tiff[entry_off .. entry_off + 12];
                entry_off += 12;

                const tag = if (is_le) std.mem.readInt(u16, entry[0..2][0..2], .little) else std.mem.readInt(u16, entry[0..2][0..2], .big);
                if (tag == 0x0112) {
                    const val = if (is_le) std.mem.readInt(u16, entry[8..10][0..2], .little) else std.mem.readInt(u16, entry[8..10][0..2], .big);
                    return switch (val) {
                        1 => 0.0,
                        3 => 180.0,
                        6 => 90.0,
                        8 => 270.0,
                        5 => 270.0,
                        7 => 90.0,
                        4 => 180.0,
                        else => 0.0,
                    };
                }
            }
        }
    }
    return null;
}

pub fn readJpegExifOrientation(io: std.Io, path: []const u8) ?f32 {
    const ext = std.fs.path.extension(path);
    if (!fs.eqlIgnoreCase(ext, ".jpg") and !fs.eqlIgnoreCase(ext, ".jpeg")) return null;

    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch return null;
    defer file.close(io);

    var buf: [65536]u8 = undefined;
    var slices = [_][]u8{&buf};
    const n = file.readPositional(io, &slices, 0) catch return null;
    return parseExifOrientation(buf[0..n]);
}

pub fn extractJpegThumbnail(data: []const u8) ?[]const u8 {
    if (data.len < 14) return null;
    if (data[0] != 0xFF or data[1] != 0xD8) return null;

    var idx: usize = 2;
    while (idx + 4 <= data.len) {
        if (data[idx] != 0xFF) break;
        var marker_offset = idx + 1;
        while (marker_offset < data.len and data[marker_offset] == 0xFF) {
            marker_offset += 1;
        }
        if (marker_offset >= data.len) break;
        const marker = data[marker_offset];
        idx = marker_offset + 1;

        if (marker == 0xD9 or marker == 0xDA) break;

        if (idx + 2 > data.len) break;
        const seg_len = (@as(usize, data[idx]) << 8) | @as(usize, data[idx + 1]);
        if (seg_len < 2 or idx + seg_len > data.len) break;

        const payload = data[idx + 2 .. idx + seg_len];
        idx += seg_len;

        if (marker == 0xE1) {
            if (payload.len < 14) continue;
            if (!std.mem.startsWith(u8, payload, "Exif\x00\x00")) continue;

            const tiff = payload[6..];
            if (tiff.len < 8) continue;

            const is_le = if (std.mem.eql(u8, tiff[0..2], "II")) true else if (std.mem.eql(u8, tiff[0..2], "MM")) false else continue;

            const sig = if (is_le) std.mem.readInt(u16, tiff[2..4][0..2], .little) else std.mem.readInt(u16, tiff[2..4][0..2], .big);
            if (sig != 0x002A) continue;

            const ifd0_off = if (is_le) std.mem.readInt(u32, tiff[4..8][0..4], .little) else std.mem.readInt(u32, tiff[4..8][0..4], .big);
            if (ifd0_off >= tiff.len or ifd0_off + 2 > tiff.len) continue;

            const num_ifd0_entries = if (is_le) std.mem.readInt(u16, tiff[ifd0_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd0_off..][0..2], .big);
            const ifd1_ptr_off = ifd0_off + 2 + @as(usize, num_ifd0_entries) * 12;
            if (ifd1_ptr_off + 4 > tiff.len) continue;

            const ifd1_off = if (is_le) std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .little) else std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .big);
            if (ifd1_off == 0 or ifd1_off >= tiff.len or ifd1_off + 2 > tiff.len) continue;

            const num_ifd1_entries = if (is_le) std.mem.readInt(u16, tiff[ifd1_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd1_off..][0..2], .big);
            var entry_off = ifd1_off + 2;

            var thumb_off: ?u32 = null;
            var thumb_len: ?u32 = null;

            var i: usize = 0;
            while (i < num_ifd1_entries) : (i += 1) {
                if (entry_off + 12 > tiff.len) break;
                const entry = tiff[entry_off .. entry_off + 12];
                entry_off += 12;

                const tag = if (is_le) std.mem.readInt(u16, entry[0..2][0..2], .little) else std.mem.readInt(u16, entry[0..2][0..2], .big);
                if (tag == 0x0201) {
                    thumb_off = if (is_le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
                } else if (tag == 0x0202) {
                    thumb_len = if (is_le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
                }
            }

            if (thumb_off != null and thumb_len != null) {
                const off = @as(usize, thumb_off.?);
                const len = @as(usize, thumb_len.?);
                if (off < tiff.len and off + len <= tiff.len) {
                    return tiff[off .. off + len];
                }
            }
        }
    }
    return null;
}

test "parseExifOrientation" {
    // 1. Invalid JPEG header -> null
    try std.testing.expectEqual(@as(?f32, null), parseExifOrientation("not a jpeg file"));

    // 2. Little Endian EXIF with Orientation 6 (90 degrees)
    const le_exif = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x1E, // Length = 30
        'E', 'x', 'i', 'f', 0x00, 0x00, // Header
        'I', 'I', // Little Endian
        0x2A, 0x00, // Signature 42
        0x08, 0x00, 0x00, 0x00, // IFD0 Offset = 8
        0x01, 0x00, // 1 entry
        0x12, 0x01, // Tag 0x0112 (Orientation)
        0x03, 0x00, // Type SHORT
        0x01, 0x00, 0x00, 0x00, // Count 1
        0x06, 0x00, 0x00, 0x00, // Value 6 (90 degrees)
        0x00, 0x00, 0x00, 0x00, // Next IFD
    };
    try std.testing.expectEqual(@as(?f32, 90.0), parseExifOrientation(&le_exif));

    // 3. Big Endian EXIF with Orientation 8 (270 degrees)
    const be_exif = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x1E, // Length = 30
        'E', 'x', 'i', 'f', 0x00, 0x00, // Header
        'M', 'M', // Big Endian
        0x00, 0x2A, // Signature 42
        0x00, 0x00, 0x00, 0x08, // IFD0 Offset = 8
        0x00, 0x01, // 1 entry
        0x01, 0x12, // Tag 0x0112 (Orientation)
        0x00, 0x03, // Type SHORT
        0x00, 0x00, 0x00, 0x01, // Count 1
        0x00, 0x08, 0x00, 0x00, // Value 8 (270 degrees)
        0x00, 0x00, 0x00, 0x00, // Next IFD
    };
    try std.testing.expectEqual(@as(?f32, 270.0), parseExifOrientation(&be_exif));

    // 4. Big Endian EXIF with Orientation 3 (180 degrees)
    const be_exif_180 = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x1E, // Length = 30
        'E', 'x', 'i', 'f', 0x00, 0x00, // Header
        'M', 'M', // Big Endian
        0x00, 0x2A, // Signature 42
        0x00, 0x00, 0x00, 0x08, // IFD0 Offset = 8
        0x00, 0x01, // 1 entry
        0x01, 0x12, // Tag 0x0112 (Orientation)
        0x00, 0x03, // Type SHORT
        0x00, 0x00, 0x00, 0x01, // Count 1
        0x00, 0x03, 0x00, 0x00, // Value 3 (180 degrees)
        0x00, 0x00, 0x00, 0x00, // Next IFD
    };
    try std.testing.expectEqual(@as(?f32, 180.0), parseExifOrientation(&be_exif_180));
}

test "readJpegExifOrientation on non-jpeg file" {
    var io_threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const rot = readJpegExifOrientation(io, "src/main.zig");
    try std.testing.expectEqual(@as(?f32, null), rot);
}

test "extractJpegThumbnail" {
    try std.testing.expectEqual(@as(?[]const u8, null), extractJpegThumbnail("invalid data"));

    const dummy_jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xD9 };
    const exif_data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x44, // Length = 68
        'E', 'x', 'i', 'f', 0x00, 0x00, // Exif header
        'I', 'I', // Little Endian
        0x2A, 0x00, // Sig
        0x08, 0x00, 0x00, 0x00, // IFD0 offset = 8
        0x01, 0x00, // IFD0 entries = 1
        0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, // Orientation tag
        0x1A, 0x00, 0x00, 0x00, // IFD1 offset = 26 (relative to TIFF header start)
        0x02, 0x00, // IFD1 entries = 2
        0x01, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, // Tag 0x0201: Thumb offset = 56
        0x02, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, // Tag 0x0202: Thumb len = 4
        0x00, 0x00, 0x00, 0x00, // Next IFD offset = 0
        0xFF, 0xD8, 0xFF, 0xD9, // Thumb payload at offset 56 in TIFF (68 in full buffer)
    };

    const thumb = extractJpegThumbnail(&exif_data);
    try std.testing.expect(thumb != null);
    try std.testing.expectEqualSlices(u8, &dummy_jpeg, thumb.?);
}

test "readJpegDimensions" {
    try std.testing.expectEqual(null, readJpegDimensions("invalid"));

    const jpeg_sof0 = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, // SOF0
        0x00, 0x0B, // Length = 11
        0x08, // Precision 8
        0x04, 0x00, // Height = 1024
        0x08, 0x00, // Width = 2048
        0x03, // Components
        0x01,
        0x11,
        0x00,
    };

    const dims = readJpegDimensions(&jpeg_sof0);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 2048.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 1024.0), dims.?.h);
}

test "parseExifDimensions" {
    const exif_dims_data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x2E, // Length = 46
        'E',  'x',
        'i',  'f',
        0x00, 0x00,
        'I', 'I', // Little Endian
        0x2A, 0x00, // Sig 42
        0x08, 0x00, 0x00, 0x00, // IFD0 offset = 8
        0x02, 0x00, // 2 entries
        0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x30, 0x1E, 0x00, 0x00, // Tag 0x0100 = 7728
        0x01, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x20, 0x14, 0x00, 0x00, // Tag 0x0101 = 5152
        0x00, 0x00, 0x00, 0x00,
    };

    const dims = parseExifDimensions(&exif_dims_data);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 7728.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 5152.0), dims.?.h);
}

//! Wayland `wl_shm` Zero-3D First-Frame Presenter
//!
//! Provides a lightweight, zero-GPU-acceleration `wl_shm` software blitting
//! path for Wayland surfaces during cold-start while Vulkan initializes
//! asynchronously on a background thread. Resolves `libwayland-client` symbols
//! dynamically from the process address space (already loaded by `libSDL3`) so
//! there are no extra build-time library dependencies and non-Linux targets
//! compile to a zero-cost no-op stub.

const builtin = @import("builtin");
const std = @import("std");

const is_linux = builtin.os.tag == .linux;

/// Writable `XRGB8888` pixel buffer backed by a Wayland `wl_shm` memory pool.
pub const FrameBuffer = struct {
    pixels: [*]u8,
    stride: u32,
    w: i32,
    h: i32,
};

const WlProxy = opaque {};
const WlDisplay = opaque {};
const WlInterface = opaque {};

const WlRegistryListener = extern struct {
    global: *const fn (
        data: ?*anyopaque,
        registry: *WlProxy,
        name: u32,
        interface: [*:0]const u8,
        version: u32,
    ) callconv(.c) void,
    global_remove: *const fn (
        data: ?*anyopaque,
        registry: *WlProxy,
        name: u32,
    ) callconv(.c) void,
};

const WL_DISPLAY_GET_REGISTRY: u32 = 1;
const WL_REGISTRY_BIND: u32 = 0;
const WL_SHM_CREATE_POOL: u32 = 0;
const WL_SHM_POOL_CREATE_BUFFER: u32 = 0;
const WL_SHM_POOL_DESTROY: u32 = 1;
const WL_BUFFER_DESTROY: u32 = 0;
const WL_SURFACE_ATTACH: u32 = 1;
const WL_SURFACE_DAMAGE: u32 = 2;
const WL_SURFACE_COMMIT: u32 = 6;
const WL_SURFACE_SET_BUFFER_SCALE: u32 = 8;
const WL_SHM_FORMAT_XRGB8888: u32 = 1;
const WL_MARSHAL_FLAG_DESTROY: u32 = 1;
const MFD_CLOEXEC: c_uint = 0x0001;

const RTLD_LAZY: c_int = 0x0001;
const RTLD_NOLOAD: c_int = 0x0004;

const WlApi = struct {
    dl_handle: ?*anyopaque = null,
    proxy_marshal_flags: *const fn (
        proxy: *WlProxy,
        opcode: u32,
        interface: ?*const WlInterface,
        version: u32,
        flags: u32,
        ...,
    ) callconv(.c) ?*WlProxy,
    proxy_add_listener: *const fn (
        proxy: *WlProxy,
        implementation: *const anyopaque,
        data: ?*anyopaque,
    ) callconv(.c) c_int,
    proxy_destroy: *const fn (proxy: *WlProxy) callconv(.c) void,
    display_roundtrip: *const fn (display: *WlDisplay) callconv(.c) c_int,
    display_flush: *const fn (display: *WlDisplay) callconv(.c) c_int,
    registry_interface: *const WlInterface,
    shm_interface: *const WlInterface,
    shm_pool_interface: *const WlInterface,
    buffer_interface: *const WlInterface,

    fn lookup(
        comptime T: type,
        handle: ?*anyopaque,
        name: [*:0]const u8,
    ) ?T {
        const sym = c_dlsym(handle, name) orelse return null;
        return @ptrCast(@alignCast(sym));
    }

    fn load() ?WlApi {
        return loadInner() catch null;
    }

    fn loadInner() !WlApi {
        var handle: ?*anyopaque = null;
        var owned_handle: ?*anyopaque = null;
        if (c_dlsym(null, "wl_proxy_marshal_flags") == null) {
            // Static SDL3 builds dlopen libwayland-client with RTLD_LOCAL;
            // grab the already-loaded handle via RTLD_NOLOAD.
            owned_handle = c_dlopen(
                "libwayland-client.so.0",
                RTLD_LAZY | RTLD_NOLOAD,
            );
            handle = owned_handle orelse return error.WaylandClientNotLoaded;
        }
        errdefer if (owned_handle) |h| {
            _ = c_dlclose(h);
        };
        return .{
            .dl_handle = owned_handle,
            .proxy_marshal_flags = lookup(
                @FieldType(WlApi, "proxy_marshal_flags"),
                handle,
                "wl_proxy_marshal_flags",
            ) orelse return error.SymbolNotFound,
            .proxy_add_listener = lookup(
                @FieldType(WlApi, "proxy_add_listener"),
                handle,
                "wl_proxy_add_listener",
            ) orelse return error.SymbolNotFound,
            .proxy_destroy = lookup(
                @FieldType(WlApi, "proxy_destroy"),
                handle,
                "wl_proxy_destroy",
            ) orelse return error.SymbolNotFound,
            .display_roundtrip = lookup(
                @FieldType(WlApi, "display_roundtrip"),
                handle,
                "wl_display_roundtrip",
            ) orelse return error.SymbolNotFound,
            .display_flush = lookup(
                @FieldType(WlApi, "display_flush"),
                handle,
                "wl_display_flush",
            ) orelse return error.SymbolNotFound,
            .registry_interface = lookup(
                *const WlInterface,
                handle,
                "wl_registry_interface",
            ) orelse return error.SymbolNotFound,
            .shm_interface = lookup(
                *const WlInterface,
                handle,
                "wl_shm_interface",
            ) orelse return error.SymbolNotFound,
            .shm_pool_interface = lookup(
                *const WlInterface,
                handle,
                "wl_shm_pool_interface",
            ) orelse return error.SymbolNotFound,
            .buffer_interface = lookup(
                *const WlInterface,
                handle,
                "wl_buffer_interface",
            ) orelse return error.SymbolNotFound,
        };
    }

    fn deinit(self: *WlApi) void {
        if (self.dl_handle) |h| {
            _ = c_dlclose(h);
            self.dl_handle = null;
        }
    }
};

extern "c" fn dlopen(
    filename: ?[*:0]const u8,
    flags: c_int,
) callconv(.c) ?*anyopaque;

extern "c" fn dlclose(handle: *anyopaque) callconv(.c) c_int;

extern "c" fn dlsym(
    handle: ?*anyopaque,
    symbol: [*:0]const u8,
) callconv(.c) ?*anyopaque;

fn c_dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque {
    return if (comptime is_linux) dlopen(filename, flags) else null;
}

fn c_dlclose(handle: *anyopaque) c_int {
    return if (comptime is_linux) dlclose(handle) else 0;
}

fn c_dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque {
    return if (comptime is_linux) dlsym(handle, symbol) else null;
}

extern "c" fn memfd_create(
    name: [*:0]const u8,
    flags: c_uint,
) callconv(.c) c_int;

const ShmLayout = struct {
    stride: u32,
    size: usize,
};

fn computeShmLayout(w: i32, h: i32) ?ShmLayout {
    if (w <= 0 or h <= 0) return null;
    const stride_u64 = @as(u64, @intCast(w)) * 4;
    if (stride_u64 > std.math.maxInt(i32)) return null;
    const size_u64 = stride_u64 * @as(u64, @intCast(h));
    if (size_u64 == 0 or size_u64 > std.math.maxInt(i32)) return null;
    return .{
        .stride = @intCast(stride_u64),
        .size = @intCast(size_u64),
    };
}

const ShmSlot = struct {
    fd: std.posix.fd_t,
    mapped: []align(std.heap.page_size_min) u8,
    pool: *WlProxy,
    buffer: *WlProxy,
    w: i32,
    h: i32,
    stride: u32,

    fn create(api: WlApi, shm: *WlProxy, w: i32, h: i32) ?ShmSlot {
        return createInner(api, shm, w, h) catch null;
    }

    fn createInner(api: WlApi, shm: *WlProxy, w: i32, h: i32) !ShmSlot {
        if (comptime !is_linux) return error.UnsupportedPlatform;
        const layout = computeShmLayout(w, h) orelse return error.InvalidSize;

        const raw_fd = memfd_create("peng-shm", MFD_CLOEXEC);
        if (raw_fd < 0) return error.MemfdCreateFailed;
        const fd: std.posix.fd_t = @intCast(raw_fd);
        errdefer _ = std.c.close(fd);

        if (std.c.ftruncate(fd, @intCast(layout.size)) != 0) {
            return error.FtruncateFailed;
        }

        const mapped = try std.posix.mmap(
            null,
            layout.size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(mapped);

        const pool = api.proxy_marshal_flags(
            shm,
            WL_SHM_CREATE_POOL,
            api.shm_pool_interface,
            1,
            0,
            @as(?*anyopaque, null),
            fd,
            @as(i32, @intCast(layout.size)),
        ) orelse return error.ShmPoolCreateFailed;
        errdefer _ = api.proxy_marshal_flags(
            pool,
            WL_SHM_POOL_DESTROY,
            null,
            1,
            WL_MARSHAL_FLAG_DESTROY,
        );

        const buffer = api.proxy_marshal_flags(
            pool,
            WL_SHM_POOL_CREATE_BUFFER,
            api.buffer_interface,
            1,
            0,
            @as(?*anyopaque, null),
            @as(i32, 0),
            w,
            h,
            @as(i32, @intCast(layout.stride)),
            WL_SHM_FORMAT_XRGB8888,
        ) orelse return error.ShmBufferCreateFailed;

        return .{
            .fd = fd,
            .mapped = mapped,
            .pool = pool,
            .buffer = buffer,
            .w = w,
            .h = h,
            .stride = layout.stride,
        };
    }

    fn deinit(self: ShmSlot, api: WlApi) void {
        if (comptime !is_linux) return;
        _ = api.proxy_marshal_flags(
            self.buffer,
            WL_BUFFER_DESTROY,
            null,
            1,
            WL_MARSHAL_FLAG_DESTROY,
        );
        _ = api.proxy_marshal_flags(
            self.pool,
            WL_SHM_POOL_DESTROY,
            null,
            1,
            WL_MARSHAL_FLAG_DESTROY,
        );
        std.posix.munmap(self.mapped);
        _ = std.c.close(self.fd);
    }
};

const RegistryBindState = struct {
    api: WlApi,
    shm: ?*WlProxy = null,
};

fn onRegistryGlobal(
    data: ?*anyopaque,
    registry: *WlProxy,
    name: u32,
    interface: [*:0]const u8,
    _: u32,
) callconv(.c) void {
    const state: *RegistryBindState = @ptrCast(@alignCast(data orelse return));
    if (state.shm != null) return;
    if (std.mem.eql(u8, std.mem.span(interface), "wl_shm")) {
        state.shm = state.api.proxy_marshal_flags(
            registry,
            WL_REGISTRY_BIND,
            state.api.shm_interface,
            1,
            0,
            name,
            interface,
            @as(u32, 1),
            @as(?*anyopaque, null),
        );
    }
}

fn onRegistryGlobalRemove(
    _: ?*anyopaque,
    _: *WlProxy,
    _: u32,
) callconv(.c) void {}

const registry_listener = WlRegistryListener{
    .global = onRegistryGlobal,
    .global_remove = onRegistryGlobalRemove,
};

/// Double-buffered Wayland `wl_shm` presenter for zero-3D first-frame display
/// before handing the `wl_surface` over to Vulkan / SDL GPU.
pub const ShmPresenter = struct {
    api: WlApi,
    display: *WlDisplay,
    surface: *WlProxy,
    shm: *WlProxy,
    slots: [2]?ShmSlot = .{ null, null },
    active_slot: u1 = 0,
    buffer_scale: i32 = 1,
    applied_buffer_scale: i32 = 1,
    has_committed: bool = false,

    /// Binds `wl_shm` on `wl_display` for presenting software frames to
    /// `wl_surface`. Returns `null` on non-Linux targets or if `wl_shm` is
    /// unavailable.
    pub fn init(
        wl_display: *anyopaque,
        wl_surface: *anyopaque,
    ) ?ShmPresenter {
        if (comptime !is_linux) return null;
        var api = WlApi.load() orelse return null;
        var keep_api = false;
        defer if (!keep_api) api.deinit();
        const display: *WlDisplay = @ptrCast(wl_display);
        const surface: *WlProxy = @ptrCast(wl_surface);

        const registry = api.proxy_marshal_flags(
            @ptrCast(display),
            WL_DISPLAY_GET_REGISTRY,
            api.registry_interface,
            1,
            0,
            @as(?*anyopaque, null),
        ) orelse return null;
        defer api.proxy_destroy(registry);

        var bind_state = RegistryBindState{ .api = api };
        defer if (!keep_api) {
            if (bind_state.shm) |bound_shm| {
                api.proxy_destroy(bound_shm);
            }
        };
        if (api.proxy_add_listener(
            registry,
            &registry_listener,
            &bind_state,
        ) != 0) {
            return null;
        }
        if (api.display_roundtrip(display) < 0) return null;

        const shm = bind_state.shm orelse return null;
        keep_api = true;
        return .{
            .api = api,
            .display = display,
            .surface = surface,
            .shm = shm,
        };
    }

    /// Acquires a writable `XRGB8888` buffer of size `w x h` pixels for the
    /// next software frame, alternating between double-buffered SHM pools.
    /// `scale` sets `wl_surface.set_buffer_scale` on commit (use `1` unless
    /// `w` and `h` are exact integer multiples of the logical window size).
    pub fn acquireBuffer(
        self: *ShmPresenter,
        w: i32,
        h: i32,
        scale: i32,
    ) ?FrameBuffer {
        if (comptime !is_linux) return null;
        if (w <= 0 or h <= 0) return null;
        self.buffer_scale = @max(1, scale);

        self.active_slot ^= 1;
        const idx = self.active_slot;
        if (self.slots[idx]) |existing| {
            if (existing.w == w and existing.h == h) {
                return .{
                    .pixels = existing.mapped.ptr,
                    .stride = existing.stride,
                    .w = existing.w,
                    .h = existing.h,
                };
            }
            existing.deinit(self.api);
            self.slots[idx] = null;
        }

        const slot = ShmSlot.create(self.api, self.shm, w, h) orelse
            return null;
        self.slots[idx] = slot;
        return .{
            .pixels = slot.mapped.ptr,
            .stride = slot.stride,
            .w = slot.w,
            .h = slot.h,
        };
    }

    /// Attaches the active SHM buffer to `wl_surface`, marks full damage,
    /// commits, and flushes the Wayland display connection.
    pub fn commit(self: *ShmPresenter) void {
        if (comptime !is_linux) return;
        const slot = self.slots[self.active_slot] orelse return;
        if (self.buffer_scale != self.applied_buffer_scale) {
            _ = self.api.proxy_marshal_flags(
                self.surface,
                WL_SURFACE_SET_BUFFER_SCALE,
                null,
                3,
                0,
                self.buffer_scale,
            );
            self.applied_buffer_scale = self.buffer_scale;
        }
        _ = self.api.proxy_marshal_flags(
            self.surface,
            WL_SURFACE_ATTACH,
            null,
            1,
            0,
            slot.buffer,
            @as(i32, 0),
            @as(i32, 0),
        );
        _ = self.api.proxy_marshal_flags(
            self.surface,
            WL_SURFACE_DAMAGE,
            null,
            1,
            0,
            @as(i32, 0),
            @as(i32, 0),
            @as(i32, std.math.maxInt(i32)),
            @as(i32, std.math.maxInt(i32)),
        );
        _ = self.api.proxy_marshal_flags(
            self.surface,
            WL_SURFACE_COMMIT,
            null,
            1,
            0,
        );
        _ = self.api.display_flush(self.display);
        self.has_committed = true;
    }

    /// Destroys all SHM pools, buffers, memory mappings, and the `wl_shm`
    /// proxy cleanly prior to Vulkan swapchain handoff or window teardown.
    pub fn deinit(self: *ShmPresenter) void {
        if (comptime !is_linux) return;
        if (self.applied_buffer_scale != 1) {
            _ = self.api.proxy_marshal_flags(
                self.surface,
                WL_SURFACE_SET_BUFFER_SCALE,
                null,
                3,
                0,
                @as(i32, 1),
            );
            self.applied_buffer_scale = 1;
            self.buffer_scale = 1;
        }
        for (&self.slots) |*slot_opt| {
            if (slot_opt.*) |slot| {
                slot.deinit(self.api);
                slot_opt.* = null;
            }
        }
        self.api.proxy_destroy(self.shm);
        _ = self.api.display_flush(self.display);
        self.api.deinit();
        self.has_committed = false;
    }
};

test "wayland protocol constants match core Wayland 1.x ABI" {
    try std.testing.expectEqual(@as(u32, 1), WL_DISPLAY_GET_REGISTRY);
    try std.testing.expectEqual(@as(u32, 0), WL_REGISTRY_BIND);
    try std.testing.expectEqual(@as(u32, 0), WL_SHM_CREATE_POOL);
    try std.testing.expectEqual(@as(u32, 0), WL_SHM_POOL_CREATE_BUFFER);
    try std.testing.expectEqual(@as(u32, 1), WL_SHM_POOL_DESTROY);
    try std.testing.expectEqual(@as(u32, 0), WL_BUFFER_DESTROY);
    try std.testing.expectEqual(@as(u32, 1), WL_SURFACE_ATTACH);
    try std.testing.expectEqual(@as(u32, 2), WL_SURFACE_DAMAGE);
    try std.testing.expectEqual(@as(u32, 6), WL_SURFACE_COMMIT);
    try std.testing.expectEqual(@as(u32, 8), WL_SURFACE_SET_BUFFER_SCALE);
    try std.testing.expectEqual(@as(u32, 1), WL_SHM_FORMAT_XRGB8888);
}

test "computeShmLayout validates dimensions and guards overflow" {
    try std.testing.expect(computeShmLayout(0, 100) == null);
    try std.testing.expect(computeShmLayout(100, 0) == null);
    try std.testing.expect(computeShmLayout(-10, 10) == null);
    try std.testing.expect(computeShmLayout(std.math.maxInt(i32), 2) == null);
    try std.testing.expect(computeShmLayout(65536, 65536) == null);

    const ok = computeShmLayout(1024, 768).?;
    try std.testing.expectEqual(@as(u32, 4096), ok.stride);
    try std.testing.expectEqual(@as(usize, 4096 * 768), ok.size);
}

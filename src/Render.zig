const std = @import("std");
const uv = @import("uv");
const zg = struct {
    const DisplayWidth = @import("DisplayWidth");
};

const uv_utils = @import("./uv_utils.zig");
const upgrade_baton = uv_utils.upgrade_baton;
const downgrade_baton = uv_utils.downgrade_baton;

const Render = @This();

alloc: std.mem.Allocator,
loop: uv.Loop,
write_reqs: WriteReqPool,

is_alive: bool = false,
stdin: Tty = undefined,
stdout: Tty = undefined,

grids: Grids = .{},
surfaces: Surfaces = .{},
stack: std.ArrayListUnmanaged(u16) = .{},

// TODO: support terminal fg color? (i.e. not using white but rather fg=0)
// TODO: support terminal predefined colors?
const Color = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const transparent = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white = .{
        .r = std.math.maxInt(u8),
        .g = std.math.maxInt(u8),
        .b = std.math.maxInt(u8),
        .a = std.math.maxInt(u8),
    };
};

pub const Dimensions = struct {
    w: u32,
    h: u32,
    pub const zero: Dimensions = .{ .w = 0, .h = 0 };
};
pub const Position = struct {
    x: u32,
    y: u32,
    pub const zero: Position = .{ .x = 0, .y = 0 };
};

const Grids = std.MultiArrayList(Grid);
pub const GridNum = enum(u16) {
    null = std.math.maxInt(u16),
    _,

    fn to_idx(num: GridNum) ?u16 {
        if (num == .null) return null;
        return @intFromEnum(num);
    }
};
/// A Grid of Cells.
///
/// Think of a texture in GL terms.
/// This should be treated as the storage used for Surfaces.
const Grid = struct {
    dims: Dimensions,

    // all these 2D arrays are the same dimensions at all times.
    /// ASCII char if <= 127, else index to grapheme cluster pool?
    cell_char: std.ArrayListUnmanaged(u16),
    cell_bg: std.ArrayListUnmanaged(Color),
    cell_fg: std.ArrayListUnmanaged(Color),

    pub const empty: Grid = .{
        .dims = .zero,
        .cell_char = .{},
        .cell_bg = .{},
        .cell_fg = .{},
    };
};

const Surfaces = std.MultiArrayList(Surface);
pub const SurfaceNum = enum(u16) {
    null = std.math.maxInt(u16),
    _,

    fn to_idx(num: SurfaceNum) ?u16 {
        if (num == .null) return null;
        return @intFromEnum(num);
    }
};
/// A Clipped and Wrapping Portion of a Grid.
///
/// Think of a viewport in GL terms.
/// This should be treated as surfaces to render on and composit together.
const Surface = struct {
    parent_surface: SurfaceNum = .null,
    /// Position on the screen
    screen_pos: Position = .zero,
    /// Size of the surface.
    /// This is the portion of the grid that will be used.
    dims: Dimensions = .zero,
    /// Backing grid. surfaces can share larger backing grids.
    grid: GridNum = .null,
    /// Position on the backing grid.
    grid_pos: Position = .zero,

    default_fg: Color = .transparent,
    default_bg: Color = .white,
};

const Tty = extern struct {
    raw_handle: uv.c.uv_tty_t,
    r: *Render,

    pub fn handle(t: *Tty) uv.Tty {
        return uv.Tty{ .handle = downgrade_baton(t, uv.c.uv_tty_t) };
    }

    pub fn fromHandle(t: uv.Tty) *Tty {
        return upgrade_baton(t.handle, Tty);
    }
};

const WriteReqPool = std.heap.MemoryPool(WriteReq);
const WriteReq = extern struct {
    req: uv.c.uv_write_t,
    r: *Render,
};

pub fn init(alloc: std.mem.Allocator, loop: uv.Loop) !Render {
    return .{
        .alloc = alloc,
        .loop = loop,
        .write_reqs = WriteReqPool.init(alloc),
    };
}
pub fn deinit(r: *Render) void {
    r.write_reqs.deinit();
    r.surfaces.deinit(r.alloc);
    r.stack.deinit(r.alloc);
    r.* = undefined;
}

pub fn setup(r: *Render) !void {
    if (uv.c.uv_guess_handle(0) != uv.c.UV_TTY)
        return error.StdInNotATty;
    if (uv.c.uv_guess_handle(1) != uv.c.UV_TTY)
        return error.StdOutNotATty;

    r.stdin.r = r;
    r.stdout.r = r;
    try uv.convertError(uv.c.uv_tty_init(
        r.loop.loop,
        r.stdin.handle().handle,
        std.posix.STDIN_FILENO,
        0,
    ));
    try uv.convertError(uv.c.uv_tty_init(
        r.loop.loop,
        r.stdout.handle().handle,
        std.posix.STDOUT_FILENO,
        0,
    ));
    r.is_alive = true;

    try r.stdout.handle().setMode(.raw);

    // enter alternate screen mode
    try r.write(&.{"\x1B[?1049h"}, struct {
        fn cb(req: *WriteReq, status: i32) void {
            uv.convertError(status) catch unreachable;
            req.r.write_reqs.destroy(req);
        }
    }.cb);

    // start handling input
    try r.stdin.handle().readStart(
        struct {
            fn alloc(h: *uv.Tty, size: usize) ?[]u8 {
                return Tty.fromHandle(h.*).r.alloc.alloc(u8, size) catch |e|
                    switch (e) {
                    // libuv interprests this as an error
                    error.OutOfMemory => null,
                };
            }
        }.alloc,

        struct {
            fn read(h: *uv.Tty, nread: isize, buf: []const u8) void {
                uv.convertError(@intCast(nread)) catch |e| switch (e) {
                    error.EOF => h.loop().stop(),

                    // NOTE: actually unreachable.
                    // Not other errors documented as possible.
                    else => unreachable,
                };

                const r_ = Tty.fromHandle(h.*).r;
                if (nread > 0 and buf.len > 0) {
                    r_.handle_input(buf) catch unreachable;
                }
                r_.alloc.free(buf);
            }
        }.read,
    );
}
pub fn teardown(r: *Render) !void {
    std.debug.assert(r.is_alive);

    // leave alternate screen mode
    try r.write(&.{"\x1B[?1049l"}, struct {
        fn cb(req: *WriteReq, status: i32) void {
            uv.convertError(status) catch unreachable;
            req.r.write_reqs.destroy(req);
        }
    }.cb);

    try uv.Tty.resetMode();

    r.stdin.handle().readStop();
    r.stdin.handle().close(null);
    r.stdout.handle().close(null);
    r.is_alive = false;
}

fn write(
    r: *Render,
    bufs: []const []const u8,
    comptime cb: fn (req: *WriteReq, status: i32) void,
) !void {
    const req = try r.write_reqs.create();
    req.r = r;

    try r.stdout.handle().write(.{
        .req = downgrade_baton(req, uv.WriteReq.T),
    }, bufs, struct {
        fn cb_(req_: *uv.WriteReq, status: i32) void {
            @call(.always_inline, cb, .{
                upgrade_baton(req_.req, WriteReq),
                status,
            });
        }
    }.cb_);
}

pub fn tty_get_dimensions(r: *Render) !Dimensions {
    var c_w: c_int = undefined;
    var c_h: c_int = undefined;

    try uv.convertError(
        uv.c.uv_tty_get_winsize(&r.stdin.raw_handle, &c_w, &c_h),
    );
    return .{
        .w = @intCast(c_w),
        .h = @intCast(c_h),
    };
}

fn handle_input(r: *Render, buf: []const u8) !void {
    _ = r;
    _ = buf;
}

pub fn grid_create(r: *Render) !GridNum {
    const num: GridNum = @enumFromInt(r.grids.len);
    if (num == .null)
        return error.OutOfMemory;

    try r.grids.append(r.alloc, .empty);
    return num;
}

pub fn surface_create(r: *Render) !SurfaceNum {
    const num: SurfaceNum = @enumFromInt(r.surfaces.len);
    if (num == .null)
        return error.OutOfMemory;

    try r.surfaces.append(r.alloc, .{});
    return num;
}

pub fn grid_set_dimensions(
    r: *Render,
    num: GridNum,
    dims: Dimensions,
) !void {
    const slice = r.grids.slice();
    slice.items(.dims)[num.to_idx().?] = dims;

    const new_cell_count = dims.w * dims.h;

    const cell_char = &slice.items(.cell_char)[num.to_idx().?];
    const cell_bg = &slice.items(.cell_bg)[num.to_idx().?];
    const cell_fg = &slice.items(.cell_fg)[num.to_idx().?];

    cell_char.clearRetainingCapacity();
    cell_bg.clearRetainingCapacity();
    cell_fg.clearRetainingCapacity();

    try cell_char.ensureTotalCapacity(r.alloc, new_cell_count);
    try cell_bg.ensureTotalCapacity(r.alloc, new_cell_count);
    try cell_fg.ensureTotalCapacity(r.alloc, new_cell_count);
}

pub fn surface_set_grid(
    r: *Render,
    num: SurfaceNum,
    grid: GridNum,
) void {
    const slice = r.surfaces.slice();
    slice.items(.grid)[num.to_idx().?] = grid;
}

pub fn surface_get_grid(r: *Render, num: SurfaceNum) GridNum {
    const slice = r.surfaces.slice();
    return slice.items(.grid)[num.to_idx().?];
}

pub fn surface_set_dimensions(
    r: *Render,
    num: SurfaceNum,
    dims: Dimensions,
) void {
    const slice = r.surfaces.slice();
    slice.items(.dims)[num.to_idx().?] = dims;
}

pub fn surface_get_dimensions(r: *Render, num: SurfaceNum) Dimensions {
    const slice = r.surfaces.slice();
    return slice.items(.dims)[num.to_idx().?];
}

pub fn surface_set_screen_position(
    r: *Render,
    num: SurfaceNum,
    pos: Position,
) void {
    const slice = r.surfaces.slice();
    slice.items(.screen_pos)[num.to_idx().?] = pos;
}

pub fn surface_get_screen_position(r: *Render, num: SurfaceNum) Position {
    const slice = r.surfaces.slice();
    return slice.items(.screen_pos)[num.to_idx().?];
}

pub fn surface_set_grid_position(
    r: *Render,
    num: SurfaceNum,
    pos: Position,
) void {
    const slice = r.surfaces.slice();
    slice.items(.grid_pos)[num.to_idx().?] = pos;
}

pub fn surface_get_grid_position(r: *Render, num: SurfaceNum) Position {
    const slice = r.surfaces.slice();
    return slice.items(.grid_pos)[num.to_idx().?];
}

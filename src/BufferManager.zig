const std = @import("std");
const SkipRope = @import("./SkipRope.zig");

const MultiArrayPool = @import("./multi_array_pool.zig").MultiArrayPool;

const BufferManager = @This();

test {
    std.testing.refAllDecls(@This());
}

io: std.Io,
alloc: std.mem.Allocator,

buffers: Buffers = .empty,

const Buffer = struct {
    file: ?std.Io.File = null,
    rope: SkipRope = .empty,
    name: []const u8,
};
const Buffers = MultiArrayPool(Buffer);
pub const BufferNum = Buffers.Idx;
const RopeInt = @TypeOf(SkipRope.empty.len);

pub const Error = error{
    RegionOutOfBounds,
};

pub fn init(io: std.Io, alloc: std.mem.Allocator) !BufferManager {
    return .{
        .io = io,
        .alloc = alloc,
    };
}

pub fn deinit(bm: *BufferManager) void {
    const bufs = bm.buffers.pool.slice();
    for (
        bufs.items(.name),
        bufs.items(.rope),
        bufs.items(.file),
    ) |name, *rope, file| {
        bm.alloc.free(name);
        rope.deinit(bm.alloc);
        if (file) |f| f.close(bm.io);
    }
    bm.buffers.deinit(bm.alloc);
    bm.* = undefined;
}

pub fn setup(bm: *BufferManager) !void {
    _ = bm;
}
pub fn teardown(bm: *BufferManager) !void {
    _ = bm;
}

pub fn buffer_create(bm: *BufferManager, name: []const u8) !BufferNum {
    return try bm.buffers.create(bm.alloc, .{
        .name = try bm.alloc.dupe(u8, name),
        .rope = .empty,
    });
}

pub fn buffer_set_region(
    bm: *BufferManager,
    num: BufferNum,
    start: isize,
    end: isize,
    text: []const u8,
) !void {
    const idx = num.to_idx().?;
    const bufs = bm.buffers.slice();
    const rope = &bufs.items(.rope)[idx];

    const start_ofs = try region_pos(rope.len, start);
    const end_ofs = try region_pos(rope.len, end);
    if (end_ofs < start_ofs) return error.RegionOutOfBounds;

    try rope.insert(bm.alloc, start_ofs, text);
    rope.delete(
        start_ofs + @as(RopeInt, @intCast(text.len)),
        end_ofs - start_ofs,
    );
}

pub fn buffer_get_rope(bm: *BufferManager, num: BufferNum) *SkipRope {
    return &bm.buffers.slice().items(.rope)[num.to_idx().?];
}

fn region_pos(len: RopeInt, pos: isize) Error!RopeInt {
    const len_usize: usize = len;
    if (pos >= 0) {
        const ofs: usize = @intCast(pos);
        if (ofs > len_usize) return error.RegionOutOfBounds;
        return @intCast(ofs);
    }

    const len_isize = std.math.cast(isize, len_usize) orelse
        return error.RegionOutOfBounds;
    const ofs = len_isize + pos + 1;
    if (ofs < 0) return error.RegionOutOfBounds;
    return @intCast(ofs);
}

fn expect_text(
    bm: *BufferManager,
    buf: BufferNum,
    want: []const u8,
) !void {
    const rope = bm.buffer_get_rope(buf);
    try std.testing.expectFmt(want, "{f}", .{rope.fmtString(0, rope.len)});
}

test "buffer: set region writes rope text" {
    var bm = try BufferManager.init(undefined, std.testing.allocator);
    defer bm.deinit();

    const buf = try bm.buffer_create("scratch");
    try bm.buffer_set_region(buf, 0, -1, "one\ntwo\n");
    try expect_text(&bm, buf, "one\ntwo\n");
}

test "buffer: set region can replace middle range" {
    var bm = try BufferManager.init(undefined, std.testing.allocator);
    defer bm.deinit();

    const buf = try bm.buffer_create("scratch");
    try bm.buffer_set_region(buf, 0, -1, "alpha beta");
    try bm.buffer_set_region(buf, 6, 10, "gamma");
    try expect_text(&bm, buf, "alpha gamma");
}

test "buffer: set region can append at tail with -1" {
    var bm = try BufferManager.init(undefined, std.testing.allocator);
    defer bm.deinit();

    const buf = try bm.buffer_create("scratch");
    try bm.buffer_set_region(buf, 0, -1, "abc");
    try bm.buffer_set_region(buf, -1, -1, "def");
    try expect_text(&bm, buf, "abcdef");
}

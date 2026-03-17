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

pub fn init(io: std.Io, alloc: std.mem.Allocator) BufferManager {
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

pub fn setup(bm: *BufferManager) void {
    _ = bm;
}
pub fn teardown(bm: *BufferManager) void {
    _ = bm;
}

pub fn buffer_create(
    bm: *BufferManager,
    name: []const u8,
) std.mem.Allocator.Error!BufferNum {
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
) (std.mem.Allocator.Error || error{RegionOutOfBounds})!void {
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

pub fn buffer_get_rope_reader(
    bm: *BufferManager,
    num: BufferNum,
    ofs: isize,
) error{RegionOutOfBounds}!SkipRope.ReadCursor {
    const rope = bm.buffer_get_rope(num);
    return rope.read_cursor_at(try region_pos(rope.len, ofs));
}

fn region_pos(len: RopeInt, pos: isize) error{RegionOutOfBounds}!RopeInt {
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

test "buffer: set region cases" {
    var bm = BufferManager.init(undefined, std.testing.allocator);
    defer bm.deinit();

    const cases = [_]struct {
        init_text: []const u8,
        start: isize,
        end: isize,
        text: []const u8,
        want: []const u8,
    }{
        .{
            .init_text = "",
            .start = 0,
            .end = -1,
            .text = "one\ntwo\n",
            .want = "one\ntwo\n",
        },
        .{
            .init_text = "alpha beta",
            .start = 6,
            .end = 10,
            .text = "gamma",
            .want = "alpha gamma",
        },
        .{
            .init_text = "abc",
            .start = -1,
            .end = -1,
            .text = "def",
            .want = "abcdef",
        },
    };

    for (cases) |case| {
        const buf = try bm.buffer_create("scratch");
        try bm.buffer_set_region(buf, 0, -1, case.init_text);
        try bm.buffer_set_region(buf, case.start, case.end, case.text);
        try expect_text(&bm, buf, case.want);
    }
}

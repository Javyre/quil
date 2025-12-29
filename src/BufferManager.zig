const std = @import("std");
const Rope = @import("./Rope.zig");

const MultiArrayPool = @import("./multi_array_pool.zig").MultiArrayPool;

const BufferManager = @This();

test {
    std.testing.refAllDecls(@This());
    // TODO: figure out why we need this line if the above line already exists
    _ = Rope;
}

io: std.Io,
alloc: std.mem.Allocator,

buffers: Buffers = .empty,

const Buffer = struct {
    file: ?std.Io.File = null,
    lines: Lines = .empty,
    name: []const u8,

    pub const Lines = std.ArrayList(std.ArrayList(u8));
};
const Buffers = MultiArrayPool(Buffer);
pub const BufferNum = Buffers.Idx;

pub fn init(io: std.Io, alloc: std.mem.Allocator) !BufferManager {
    return .{
        .io = io,
        .alloc = alloc,
    };
}

pub fn deinit(bm: *BufferManager) void {
    const bufs = bm.buffers.pool.slice();
    for (bufs.items(.name)) |name| {
        bm.alloc.free(name);
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
        .lines = .empty,
    });
}

pub fn buffer_set_region(
    bm: *BufferManager,
    num: BufferNum,
    start: isize,
    end: isize,
    text: []const u8,
) !void {
    _ = bm;
    _ = num;
    _ = start;
    _ = end;
    _ = text;
    @panic("unimplemented");
}

pub fn buffer_get_lines(bm: *BufferManager, num: BufferNum) *Buffer.Lines {
    return &bm.buffers.slice().items(.lines)[num.to_idx().?];
}

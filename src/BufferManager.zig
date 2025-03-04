const std = @import("std");
const uv = @import("uv");
const Rope = @import("./Rope.zig");

const MultiArrayPool = @import("./multi_array_pool.zig").MultiArrayPool;

const BufferManager = @This();

test {
    std.testing.refAllDecls(@This());
    // TODO: figure out why we need this line if the above line already exists
    _ = Rope;
    // _ = @import("Rope.zig");
}

alloc: std.mem.Allocator,
loop: uv.Loop,

buffers: Buffers = .empty,

const Buffer = struct {
    file: ?std.fs.File = null,
    lines: Lines = .empty,
    name: []const u8,

    pub const Lines = std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8));
};
const Buffers = MultiArrayPool(Buffer);
pub const BufferNum = Buffers.Idx;

pub fn init(alloc: std.mem.Allocator, loop: uv.Loop) !BufferManager {
    return .{
        .alloc = alloc,
        .loop = loop,
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

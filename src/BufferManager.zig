const std = @import("std");
const uv = @import("uv");

const MultiArrayPool = @import("./multi_array_pool.zig").MultiArrayPool;

const BufferManager = @This();

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

pub fn buffer_create_scratch(bm: *BufferManager) !BufferNum {
    var lines: Buffer.Lines = .empty;
    try lines.appendSlice(bm.alloc, &.{
        .empty,
        line: {
            var line = std.ArrayListUnmanaged(u8).empty;
            try line.appendSlice(bm.alloc, "// Scratch zig buffer");
            break :line line;
        },
        .empty,
    });

    return try bm.buffers.create(bm.alloc, .{
        .name = try bm.alloc.dupe(u8, "*Scratch*"),
        .lines = lines,
    });
}

pub fn buffer_get_lines(bm: *BufferManager, num: BufferNum) *Buffer.Lines {
    return &bm.buffers.slice().items(.lines)[num.to_idx().?];
}

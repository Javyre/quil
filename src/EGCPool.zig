const std = @import("std");

const StringIndexContext = struct {
    bytes: *const std.ArrayListUnmanaged(u8),

    pub fn eql(_: @This(), a: Idx, b: Idx) bool {
        return a == b;
    }

    pub fn hash(ctx: @This(), key: Idx) u64 {
        return std.hash_map.hashString(std.mem.sliceTo(ctx.bytes.items[key..], 0));
    }
};

const StringIndexAdapter = struct {
    bytes: *const std.ArrayListUnmanaged(u8),

    pub fn eql(ctx: @This(), a: []const u8, b: Idx) bool {
        return std.mem.eql(u8, a, std.mem.sliceTo(ctx.bytes.items[b..], 0));
    }

    pub fn hash(_: @This(), adapted_key: []const u8) u64 {
        std.debug.assert(std.mem.indexOfScalar(u8, adapted_key, 0) == null);
        return std.hash_map.hashString(adapted_key);
    }
};

map: std.HashMapUnmanaged(
    Idx,
    void,
    StringIndexContext,
    std.hash_map.default_max_load_percentage,
),
bytes: std.ArrayListUnmanaged(u8),

pub const Idx = u16;
const EgcPool = @This();

pub const empty: EgcPool = .{ .map = .empty, .bytes = .empty };

pub fn deinit(p: *EgcPool, alloc: std.mem.Allocator) void {
    p.map.deinit(alloc);
    p.bytes.deinit(alloc);
    p.* = undefined;
}

pub fn register_grapheme(
    p: *EgcPool,
    alloc: std.mem.Allocator,
    gc: []const u8,
) !Idx {
    const gop = try p.map.getOrPutContextAdapted(
        alloc,
        gc,
        StringIndexAdapter{
            .bytes = &p.bytes,
        },
        StringIndexContext{
            .bytes = &p.bytes,
        },
    );

    if (gop.found_existing) return gop.key_ptr.*;

    if (p.bytes.items.len + gc.len >= std.math.maxInt(Idx))
        return error.OutOfMemory;
    const idx: Idx = @intCast(p.bytes.items.len);

    try p.bytes.ensureUnusedCapacity(alloc, gc.len + 1);
    p.bytes.appendSliceAssumeCapacity(gc);
    p.bytes.appendAssumeCapacity(0);

    gop.key_ptr.* = idx;
    return idx;
}

pub fn get(p: *EgcPool, idx: Idx) []const u8 {
    std.debug.assert(idx < p.bytes.items.len);
    return std.mem.sliceTo(p.bytes.items[idx..], 0);
}

const std = @import("std");

const StringIndexContext = struct {
    bytes: *const std.ArrayList(u8),

    pub fn eql(_: @This(), a: Idx, b: Idx) bool {
        return a == b;
    }

    pub fn hash(ctx: @This(), key: Idx) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceTo(ctx.bytes.items[key..], 0));
        return h.final();
    }
};

const StringIndexAdapter = struct {
    bytes: *const std.ArrayList(u8),

    pub fn eql(ctx: @This(), a: []const u8, b: Idx) bool {
        return std.mem.eql(u8, a, std.mem.sliceTo(ctx.bytes.items[b..], 0));
    }

    pub fn hash(_: @This(), adapted_key: []const u8) u64 {
        std.debug.assert(std.mem.indexOfScalar(u8, adapted_key, 0) == null);
        var h = std.hash.Wyhash.init(0);
        h.update(adapted_key);
        return h.final();
    }
};

const StringIndexAdapter2 = struct {
    bytes: *const std.ArrayList(u8),

    pub fn eql(ctx: @This(), a: struct { []const u8, []const u8 }, b: Idx) bool {
        const bytes = std.mem.sliceTo(ctx.bytes.items[b..], 0);
        if (bytes.len != a[0].len + a[1].len) return false;
        if (!std.mem.eql(u8, a[0], bytes[0..a[0].len])) return false;
        return std.mem.eql(u8, a[1], bytes[a[0].len..]);
    }

    pub fn hash(_: @This(), adapted_key: struct { []const u8, []const u8 }) u64 {
        std.debug.assert(std.mem.indexOfScalar(u8, adapted_key[0], 0) == null);
        std.debug.assert(std.mem.indexOfScalar(u8, adapted_key[1], 0) == null);
        var h = std.hash.Wyhash.init(0);
        h.update(adapted_key[0]);
        h.update(adapted_key[1]);
        return h.final();
    }
};

map: std.HashMapUnmanaged(
    Idx,
    void,
    StringIndexContext,
    std.hash_map.default_max_load_percentage,
),
bytes: std.ArrayList(u8),

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

pub fn register_grapheme2(
    p: *EgcPool,
    alloc: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
) !Idx {
    const gop = try p.map.getOrPutContextAdapted(
        alloc,
        .{ a, b },
        StringIndexAdapter2{
            .bytes = &p.bytes,
        },
        StringIndexContext{
            .bytes = &p.bytes,
        },
    );

    if (gop.found_existing) return gop.key_ptr.*;

    if (p.bytes.items.len + a.len + b.len >= std.math.maxInt(Idx))
        return error.OutOfMemory;
    const idx: Idx = @intCast(p.bytes.items.len);

    try p.bytes.ensureUnusedCapacity(alloc, a.len + b.len + 1);
    p.bytes.appendSliceAssumeCapacity(a);
    p.bytes.appendSliceAssumeCapacity(b);
    p.bytes.appendAssumeCapacity(0);

    gop.key_ptr.* = idx;
    return idx;
}

pub fn get(p: *EgcPool, idx: Idx) []const u8 {
    std.debug.assert(idx < p.bytes.items.len);
    return std.mem.sliceTo(p.bytes.items[idx..], 0);
}

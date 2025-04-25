const std = @import("std");
const assert = std.debug.assert;
const RangedInt = @import("./ranged_int.zig").RangedInt;

// NOTE: limit the circular dependency by not importing Rope fully
const config = @import("./Rope2.zig").config;
const bounds = @import("./Rope2.zig").bounds;
const TreeSize = @import("./Rope2.zig").TreeSize;
const RopeBytes = @import("./Rope2.zig").RopeBytes;

const Db = @import("./Db.zig");
const Ib = @This();

pub const Num = RangedInt(.ib_num, 0, bounds.indx_blocks_max - 1);
pub const Len = RangedInt(.ib_keys, 0, bounds.indx_block_keys_max);
pub const Idx = RangedInt(.ib_keys, 0, bounds.indx_block_keys_max - 1);

// null_key terminated OR full
keys: [bounds.indx_block_keys_max]RawKey align(config.dcache_line_bytes),
children: [bounds.indx_block_keys_max]RawChild align(config.dcache_line_bytes),

pub const RawKey = enum(u32) {
    null = std.math.maxInt(u32),
    _,
    comptime {
        const res = TreeSize.try_cast(@intFromEnum(RawKey.null));
        assert(res == error.Overflow);
    }

    pub fn some(num: TreeSize) RawKey {
        return @enumFromInt(@intFromEnum(num));
    }
    pub fn unwrap(this: RawKey) ?TreeSize {
        return switch (this) {
            .null => null,
            _ => .cast(@intFromEnum(this)),
        };
    }
};

pub const RawChild = enum(u32) {
    _,
    pub fn wrap_db_num(num: Db.Num) RawChild {
        return @enumFromInt(@intFromEnum(num));
    }
    pub fn wrap_ib_num(num: Num) RawChild {
        return @enumFromInt(@intFromEnum(num));
    }
    pub fn as(this: RawChild, comptime T: type) T {
        switch (T) {
            Db.Num, Num => {},
            else => @compileError("Invalid target type"),
        }
        return T.cast(@intFromEnum(this));
    }
};

pub const empty: Ib = .{
    .keys = @splat(.null),
    .children = @splat(@enumFromInt(std.math.maxInt(u32))),
};

comptime {
    // we store everything as u32s
    assert(@max(
        @typeInfo(Num.Int).int.bits,
        @typeInfo(Db.Num.Int).int.bits,
        @typeInfo(TreeSize.Int).int.bits,
    ) <= 32);

    assert(
        @sizeOf(@FieldType(Ib, "keys")) == config.dcache_line_bytes,
    );
    assert(
        @sizeOf(@FieldType(Ib, "children")) == config.dcache_line_bytes,
    );
    assert(@sizeOf(Ib) == config.dcache_line_bytes * 2);
}

pub fn key_at(this: *Ib, idx: Idx) *RawKey {
    return &this.keys[idx.to_int()];
}

pub fn child_at(this: *Ib, idx: Idx) *RawChild {
    return &this.children[idx.to_int()];
}

pub fn count_keys(this: *const Ib) Len {
    for (this.keys, 0..) |key, i| {
        _ = key.unwrap() orelse return .cast(i);
    }
    return .cast(this.keys.len);
}

pub fn sum_subtree_bytes(this: *const Ib) RopeBytes {
    var sum: RopeBytes = .coerce(0);
    for (this.keys) |key| {
        const subsize = key.unwrap() orelse break;
        sum = .cast(sum.to_int() + RopeBytes.coerce(subsize).to_int());
    }
    return sum;
}

pub fn find_ofs(this: Ib, ofs: RopeBytes) ?struct {
    key_idx: Len,
    child_ofs: RopeBytes,
} {
    var cum_ofs: RopeBytes = .coerce(0);
    var i: u8 = 0;

    for (this.keys) |key| {
        const subsize: RopeBytes = .coerce(key.unwrap() orelse break);

        if (ofs.to_int() < cum_ofs.to_int() + subsize.to_int()) {
            return .{
                .key_idx = .cast(i),
                .child_ofs = cum_ofs,
            };
        }

        cum_ofs = .cast(cum_ofs.to_int() + subsize.to_int());
        i += 1;
    }
    if (cum_ofs == ofs) {
        const last_subsize: TreeSize = this.keys[i - 1].unwrap().?;
        return .{
            .key_idx = .cast(i - 1),
            .child_ofs = .cast(cum_ofs.to_int() - last_subsize.to_int()),
        };
    }
    return null;
}

pub fn format(
    this: *const Ib,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    try writer.writeAll("Ib{ .keys = .{ ");

    const len = this.count_keys().to_int();

    for (0..len, this.keys[0..len]) |i, key| {
        try writer.print("{any}", .{key.unwrap().?.to_int()});
        if (i + 1 < len) try writer.writeAll(", ");
    }
    try writer.writeAll(" }, .children = .{ ");
    for (0..len, this.children[0..len]) |i, child| {
        try writer.print("{any}", .{child.as(Db.Num).to_int()});
        if (i + 1 < len) try writer.writeAll(", ");
    }
    return writer.writeAll(" } }");
}

pub const Slice = struct {
    block: *Ib,
    ofs: Len,
    len: Len,

    pub fn eql(this: Slice, other: Slice) bool {
        return this.block == other.block and
            this.ofs.eql(other.ofs) and
            this.len.eql(other.len);
    }

    fn assert_sane(this: Slice) void {
        _ = Len.cast(this.ofs.to_int() + this.len.to_int());
    }

    fn assert_subslice_of(this: Slice, parent: Slice) void {
        assert(this.block == parent.block);

        const this_min = this.ofs.to_int();
        const this_max = this.ofs.to_int() + this.len.to_int();
        const parent_min = parent.ofs.to_int();
        const parent_max = parent.ofs.to_int() + parent.len.to_int();

        assert(this_min >= parent_min);
        assert(this_min <= parent_max);
        assert(this_max >= parent_min);
        assert(this_max <= parent_max);
    }

    pub fn slice(this: Slice, beg: ?Len, end: ?Len) Slice {
        this.assert_sane();
        const new_ofs = this.ofs.add(beg orelse .coerce(0));
        const new_end = this.ofs.add(end orelse this.len);
        const new_len = new_end.sub(new_ofs);
        const new: Slice = .{
            .block = this.block,
            .ofs = new_ofs,
            .len = new_len,
        };
        new.assert_subslice_of(this);
        new.assert_sane();
        return new;
    }
};

pub fn slice(block: *Ib, beg: ?Len, end: Len) Slice {
    const ofs: Len = beg orelse .coerce(0);
    const res: Slice = .{
        .block = block,
        .ofs = ofs,
        .len = end.sub(ofs),
    };
    res.assert_sane();
    return res;
}

pub fn assert_WriteIter(comptime Ptr: type) void {
    if (@typeInfo(Ptr) != .pointer or @typeInfo(Ptr).pointer.is_const) {
        @compileError("WriteIter must be a non-const pointer");
    }
    const T = @typeInfo(Ptr).pointer.child;
    if (!@hasDecl(T, "next") or !@hasDecl(T, "next_back")) {
        @compileError("WriteIter must have next() and next_back()");
    }
}

pub fn write(dst: Slice, iter: anytype) void {
    assert_WriteIter(@TypeOf(iter));

    dst.assert_sane();
    if (dst.len.eql(.coerce(0))) return;

    var i: Len = .coerce(0);
    while (iter.next()) |el| {
        assert(i.to_int() < dst.len.to_int());
        dst.block.keys[dst.ofs.to_int() + i.to_int()] = .some(el.key);
        dst.block.children[dst.ofs.to_int() + i.to_int()] = el.child;
        i = i.add(.coerce(1));
    }
    // Must fill dst
    assert(i.eql(dst.len));
}

pub fn write_from_back(dst: Slice, iter: anytype) void {
    assert_WriteIter(@TypeOf(iter));

    dst.assert_sane();
    if (dst.len.eql(.coerce(0))) return;

    var i: Len = dst.len;
    while (iter.next_back()) |el| {
        dst.block.keys[dst.ofs.to_int() + i.to_int() - 1] = .some(el.key);
        dst.block.children[dst.ofs.to_int() + i.to_int() - 1] = el.child;
        i = i.sub(.coerce(1));
    }
    // Must fill dst
    assert(i.eql(.coerce(0)));
}

pub fn copy(dst: Slice, src: Slice) void {
    dst.assert_sane();
    src.assert_sane();
    assert(dst.len.eql(src.len));

    if (dst.len.eql(.coerce(0))) return;
    if (dst.eql(src)) return;

    // these ifs should usually be eliminated by the compiler when inlining
    if (dst.block != src.block) {
        @memcpy(
            dst.block.keys[dst.ofs.to_int()..][0..src.len.to_int()],
            src.block.keys[src.ofs.to_int()..][0..src.len.to_int()],
        );
        @memcpy(
            dst.block.children[dst.ofs.to_int()..][0..src.len.to_int()],
            src.block.children[src.ofs.to_int()..][0..src.len.to_int()],
        );
    } else if (dst.ofs.to_int() <= src.ofs.to_int()) {
        std.mem.copyForwards(
            RawKey,
            dst.block.keys[dst.ofs.to_int()..][0..src.len.to_int()],
            src.block.keys[src.ofs.to_int()..][0..src.len.to_int()],
        );
        std.mem.copyForwards(
            RawChild,
            dst.block.children[dst.ofs.to_int()..][0..src.len.to_int()],
            src.block.children[src.ofs.to_int()..][0..src.len.to_int()],
        );
    } else {
        assert(dst.ofs.to_int() > src.ofs.to_int());
        std.mem.copyBackwards(
            RawKey,
            dst.block.keys[dst.ofs.to_int()..][0..src.len.to_int()],
            src.block.keys[src.ofs.to_int()..][0..src.len.to_int()],
        );
        std.mem.copyBackwards(
            RawChild,
            dst.block.children[dst.ofs.to_int()..][0..src.len.to_int()],
            src.block.children[src.ofs.to_int()..][0..src.len.to_int()],
        );
    }
}

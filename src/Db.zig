const std = @import("std");
const assert = std.debug.assert;
const ranged_int = @import("./ranged_int.zig");
const RangedInt = ranged_int.RangedInt;

// NOTE: limit the circular dependency by not importing Rope fully
const config = @import("./Rope2.zig").config;
const bounds = @import("./Rope2.zig").bounds;
const RopeBytes = @import("./Rope2.zig").RopeBytes;

const Db = @This();

pub const Num = RangedInt(.db_num, 0, bounds.data_blocks_max - 1);
pub const Len = RangedInt(.bytes, 0, config.data_block_bytes_max);
pub const Idx = RangedInt(.bytes, 0, config.data_block_bytes_max - 1);

pub const NumOpt = enum(Num.Int) {
    null = std.math.maxInt(Num.Int),
    _,
    comptime {
        const res = Num.try_cast(@intFromEnum(NumOpt.null));
        assert(res == error.Overflow);
    }

    pub fn some(num: Num) NumOpt {
        return @enumFromInt(@intFromEnum(num));
    }
    pub fn unwrap(this: NumOpt) ?Num {
        switch (this) {
            .null => return null,
            _ => return .cast(@intFromEnum(this)),
        }
    }

    pub fn eql(a: NumOpt, b: NumOpt) bool {
        if (a.unwrap() == null and b.unwrap() == null)
            return true;
        if (a.unwrap() != null and b.unwrap() != null)
            return a.unwrap().?.eql(b.unwrap().?);
        return false;
    }
};

pub const BitMap = std.meta.Int(.unsigned, config.data_block_bytes_max);
pub const Meta = struct {
    bytes: Len,
    newlines: BitMap,
    next: NumOpt = .null,
    prev: NumOpt = .null,

    pub fn format(
        this: *const Meta,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "Meta{{ .bytes = {d}, .newlines = {b}, " ++
                ".next = {?d}, .prev = {?d} }}",
            .{
                this.bytes.to_int(),
                this.newlines,
                if (this.next.unwrap()) |n| n.to_int() else null,
                if (this.prev.unwrap()) |p| p.to_int() else null,
            },
        );
    }
};

meta: Meta align(config.dcache_line_bytes),
bytes: [config.data_block_bytes_max]u8 align(config.dcache_line_bytes),

comptime {
    assert(@sizeOf(@FieldType(Db, "meta")) <= config.dcache_line_bytes);
    assert(
        @sizeOf(@FieldType(Db, "bytes")) % config.dcache_line_bytes == 0,
    );
}

/// Shift the bytes in the db by amt bytes, starting at ofs.
/// Does not lose any bytes.
pub fn shr_exact(this: *Db, ofs: Idx, amt: Idx) void {
    assert(ofs.to_int() <= this.meta.bytes.to_int());
    assert(
        this.meta.bytes.to_int() + Len.coerce(amt).to_int() <=
            Len.max_val.to_int(),
    );
    this.shr(ofs, amt);
}

pub fn shr(this: *Db, ofs: Idx, amt_: Len) void {
    // amt < max_len - ofs:
    // something...
    // some_thing..
    //     ^ofs
    //      ^^^^^^^postfix
    //
    // amt >= max_len - ofs:
    // something...
    // some________
    //     ^ofs
    // no postfix

    // NOTE: data shr == significant-most shift = bitmap shl
    //
    // bits that are to be shifted out of the left
    const mask = std.math.boolMask(Db.BitMap, true) << ofs;

    // No postfix
    if (amt_.to_int() >= (Len.max_val.to_int() - ofs.to_int())) {
        if (ofs.to_int() == 0) {
            this.meta.newlines = 0;
            this.bytes = undefined;
            return;
        }
        this.meta.newlines = (this.meta.newlines & ~mask);
        @memset(this.bytes[ofs.to_int()..], undefined);
        return;
    }
    const amt: Idx = .cast(amt_);

    this.meta.newlines =
        (this.meta.newlines & ~mask) |
        ((this.meta.newlines & mask) << amt);

    const postfix_len: Idx =
        .cast((Len.max_val.to_int() - ofs.to_int()) - amt.to_int());
    assert(postfix_len.to_int() > 0);

    // slices may overlap, shift right means dst >= src
    std.mem.copyBackwards(
        u8,
        this.bytes[ofs.to_int() + amt.to_int() ..] //
        [0..postfix_len.to_int()],

        this.bytes[ofs.to_int()..] //
        [0..postfix_len.to_int()],
    );
    @memset(
        this.bytes[ofs.to_int()..][0..amt.to_int()],
        undefined,
    );
}

pub fn format(
    this: *const Db,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    try writer.print("Db{{ .meta = {any}, .bytes = \"{s}\" }}", .{
        this.meta,
        std.fmt.fmtSliceEscapeUpper(this.bytes[0..this.meta.bytes.to_int()]),
    });
}

pub const Slice = struct {
    block: *Db,
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

    pub fn bytes(this: Slice) []u8 {
        return this.block
            .bytes[this.ofs.to_int()..this.ofs.add(this.len).to_int()];
    }

    pub fn take_db_slice(this: *Slice, n_: usize) Slice {
        const n = Len.cast(@min(n_, this.len.to_int()));
        const head = this.slice(null, n);
        this.* = this.slice(n, null);
        return head;
    }

    pub fn take_db_slice_back(this: *Slice, n_: usize) Slice {
        const n = Len.cast(@min(n_, this.len.to_int()));
        const tail = this.slice(this.len.sub(n), null);
        assert(tail.len.eql(n));
        this.* = this.slice(null, this.len.sub(n));
        return tail;
    }
};

pub fn slice(block: *Db, beg: ?Len, end: Len) Slice {
    const ofs: Len = beg orelse Len.coerce(0);
    const res: Slice = .{
        .block = block,
        .ofs = ofs,
        .len = end.sub(ofs),
    };
    res.assert_sane();
    return res;
}

fn recalc_newlines(dst: Slice) void {
    var newlines: BitMap = 0;
    const bytes = dst.bytes();
    for (bytes) |byte| {
        newlines <<= 1;
        newlines |= if (byte == '\n') 1 else 0;
    }
    const mask =
        (std.math.boolMask(BitMap, true) << Idx.cast(dst.ofs).to_int()) |
        (if (dst.ofs.add(.cast(bytes.len)).eql(dst.block.meta.bytes))
            0
        else
            (std.math.boolMask(u128, true) <<
                Idx.cast(dst.ofs.add(.cast(bytes.len))).to_int()));

    dst.block.meta.newlines = (mask & dst.block.meta.newlines) |
        (newlines << Idx.cast(dst.ofs.to_int()).to_int());
}

pub fn write(dst: Slice, iter: anytype) Len {
    const hasMethod = std.meta.hasMethod;

    dst.assert_sane();
    if (hasMethod(@TypeOf(iter), "take_db_slice")) {
        const src = iter.take_db_slice(dst.len.to_int());
        const subdst = dst.slice(null, src.len);

        copy(subdst, src);

        return subdst.len;
    } else if (hasMethod(@TypeOf(iter), "take_str")) {
        const bytes: []const u8 = iter.take_str(dst.len.to_int());
        if (bytes.len == 0) return .coerce(0);
        const subdst = dst.slice(null, .cast(bytes.len));

        @memcpy(subdst.bytes(), bytes);
        recalc_newlines(subdst);

        return subdst.len;
    } else if (hasMethod(@TypeOf(iter), "take_nop")) {
        return .cast(iter.take_nop(dst.len.to_int()));
    } else {
        @compileError("invalid iter type. missing take_str or take_nop " ++
            @typeName(@TypeOf(iter)));
    }
}

pub fn write_back(dst: Slice, iter: anytype) Len {
    const hasMethod = std.meta.hasMethod;
    dst.assert_sane();
    if (hasMethod(@TypeOf(iter), "take_db_slice_back")) {
        const src = iter.take_db_slice_back(dst.len.to_int());
        const subdst = dst.slice(dst.len.sub(src.len), null);

        copy(subdst, src);

        return subdst.len;
    } else if (hasMethod(@TypeOf(iter), "take_str_back")) {
        @compileError("not implemented");
    } else if (hasMethod(@TypeOf(iter), "take_nop_back")) {
        return .cast(iter.take_nop_back(dst.len.to_int()));
    } else {
        @compileError(
            "invalid iter type. missing take_back_str or take_nop_back " ++
                @typeName(@TypeOf(iter)),
        );
    }
}

/// Copy src into dst.
///
/// Must be same block and dst.ofs <= src.ofs.
pub fn copyForwards(dst: Slice, src: Slice) void {
    dst.assert_sane();
    src.assert_sane();
    assert(dst.len.eql(src.len));
    assert(dst.block == src.block);

    if (dst.len.eql(.coerce(0))) return;
    assert(dst.ofs.to_int() <= src.ofs.to_int());
    if (dst.eql(src)) return;

    // len != 0 so these casts are safe
    const dst_ofs: Idx = .cast(dst.ofs);
    const src_ofs: Idx = .cast(src.ofs);

    // populate N low bits
    const m = if (dst.len.eql(.max_val))
        std.math.boolMask(BitMap, false)
    else
        ~(std.math.boolMask(BitMap, true) << @intCast(dst.len.to_int()));

    // apply ofs to m
    const dst_mask = m << dst_ofs.to_int();
    const src_mask = m << src_ofs.to_int();

    const src_copy = src.block.meta.newlines & src_mask;
    dst.block.meta.newlines &= ~dst_mask;
    dst.block.meta.newlines |= src_copy >> src_ofs.sub(dst_ofs).to_int();

    std.mem.copyForwards(u8, dst.bytes(), src.bytes());
}

/// Copy src into dst.
///
/// Must be same block and dst.ofs >= src.ofs.
pub fn copyBackwards(dst: Slice, src: Slice) void {
    dst.assert_sane();
    src.assert_sane();
    assert(dst.len.eql(src.len));
    assert(dst.block == src.block);

    if (dst.len.eql(.coerce(0))) return;
    assert(dst.ofs.to_int() >= src.ofs.to_int());
    if (dst.eql(src)) return;

    // len != 0 so these casts are safe
    const dst_ofs: Idx = .cast(dst.ofs);
    const src_ofs: Idx = .cast(src.ofs);

    // populate N low bits
    const m = if (dst.len.eql(.max_val))
        std.math.boolMask(BitMap, false)
    else
        ~(std.math.boolMask(BitMap, true) << @intCast(dst.len.to_int()));

    // apply ofs to m
    const dst_mask = m << dst_ofs.to_int();
    const src_mask = m << src_ofs.to_int();

    const src_copy = src.block.meta.newlines & src_mask;
    dst.block.meta.newlines &= ~dst_mask;
    dst.block.meta.newlines |= src_copy << dst_ofs.sub(src_ofs).to_int();

    std.mem.copyBackwards(u8, dst.bytes(), src.bytes());
}

pub fn copy(dst: Slice, src: Slice) void {
    dst.assert_sane();
    src.assert_sane();
    assert(dst.len.eql(src.len));

    if (dst.len.eql(.coerce(0))) return;
    if (dst.eql(src)) return;

    // len != 0 so these casts are safe
    const dst_ofs: Idx = .cast(dst.ofs);
    const src_ofs: Idx = .cast(src.ofs);

    const m = if (dst.len.eql(.max_val))
        std.math.boolMask(BitMap, false)
    else
        ~(std.math.boolMask(BitMap, true) << @intCast(dst.len.to_int()));

    const dst_mask = m << dst_ofs.to_int();
    const src_mask = m << src_ofs.to_int();

    const src_copy = src.block.meta.newlines & src_mask;
    dst.block.meta.newlines &= ~dst_mask;

    if (dst_ofs.to_int() > src_ofs.to_int())
        dst.block.meta.newlines |= src_copy << dst_ofs.sub(src_ofs).to_int()
    else
        dst.block.meta.newlines |= src_copy >> src_ofs.sub(dst_ofs).to_int();

    // these ifs should usually be eliminated by the compiler when inlining
    if (dst.block != src.block) {
        @memcpy(dst.bytes(), src.bytes());
    } else if (dst_ofs.to_int() <= src_ofs.to_int()) {
        std.mem.copyForwards(u8, dst.bytes(), src.bytes());
    } else {
        assert(dst_ofs.to_int() > src_ofs.to_int());
        std.mem.copyBackwards(u8, dst.bytes(), src.bytes());
    }
}

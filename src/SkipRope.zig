//! B-skiplist for bytes.
//!
//! K = byte offset, V = byte. Dense: every byte offset exists. Logical leaders
//! are byte offsets; physical index slots store subtree widths.
//!
//! Logical skiplist, grouped by physical blocks:
//! ```
//! L2: [-inf ----------- 4 -----------] +inf
//! L1: [-inf ----- 2 -] [4 ------- 8 -] +inf
//! L0: [-inf 0 1] [2 3] [4 5 6 7] [8 9] +inf
//!
//! L2: [-inf] [-1 ----------- 4 -----------] +inf
//! L1: [-inf] [-1 ----- 2 -] [4 ------- 8 -] +inf
//! L0: [-inf] [-1 0 1] [2 3] [4 5 6 7] [8 9] +inf
//! ```
//!
//! Physical width slots for same examples:
//! ```
//! L2: [4 6]
//! L1: [2 2] [4 2]
//! L0: [1 1] [1 1] [1 1 1 1] [1 1]
//!
//! L2: [0 5 6]
//! L1: [0] [3 2] [4 2]
//! L0: [] [1 1 1] [1 1] [1 1 1 1] [1 1]
//! ```
//!
//! Logical model:
//! - A byte's height is the highest layer where that byte is a leader.
//! - An `Ib` slot is owned by the first byte covered by its `down` subtree.
//! - `Ib.wide[i]` is the byte count covered by `down[i]`.
//! - `Db` is the leaf layer: bytes packed into linked leaf blocks.
//!
//! Header:
//! - The first block of each layer exposes a virtual `-inf` leader.
//! - The virtual leader has no L0 rank.
//! - Slot `0` may be 0-wide only for the virtual leader.
//!
//! Physical model:
//! - Each layer is a linked list of packed blocks.
//! - `Ib` packs upper-layer width slots.
//! - `Db` packs leaf bytes.
const std = @import("std");
const assert = std.debug.assert;
const log = @import("./log.zig").scoped(.rope);

const Allocator = std.mem.Allocator;
const RangedInt = @import("./ranged_int.zig").RangedInt;
const SegmentedPool = @import("./segmented_pool.zig").SegmentedPool;

const SkipRope = @This();

rng: std.Random.DefaultPrng,
root: Ib.Num,
len: BytesInt,
/// ib layer count - 1; total ib+db layer count - 2
ib_height: HeightInt,
ibs: SegmentedPool(
    Ib,
    RangedInt(.ib_num, 0, std.math.maxInt(u32)),
    .coerce(16),
),
dbs: SegmentedPool(
    Db,
    RangedInt(.db_num, 0, std.math.maxInt(u32)),
    .coerce(128),
),

pub const empty: SkipRope = .{
    .rng = .init(0),
    .root = .null,
    .len = 0,
    .ib_height = 0,
    .ibs = .empty,
    .dbs = .empty,
};

const config = .{
    .dcache_line_bytes = 64,
};

// .null doesn't count
const max_dbs = std.math.maxInt(std.meta.Tag(Db.Num)) - 1;
// we cap our height to this
// bottlenecked by max amount of dbs
const max_height = std.math.log_int(u32, Ib.capacity, max_dbs);
const max_bytes = max_dbs * Db.capacity;
const HeightInt = std.math.IntFittingRange(0, max_height);
const BytesInt = std.math.IntFittingRange(0, max_bytes);

comptime {
    assert(@typeInfo(HeightInt).int.bits <= 8);
    assert(@typeInfo(BytesInt).int.bits <= 64);
}

const Ib = extern struct {
    pub const capacity = (2 * config.dcache_line_bytes / @sizeOf(u32)) - 1;
    pub const CapInt = std.math.IntFittingRange(0, capacity);

    /// Subtree width: byte count covered by `down[i]`.
    ///
    /// Slot `0` may be 0-wide for the virtual `-inf` leader.
    wide: [capacity]u32 align(config.dcache_line_bytes) = @splat(0),
    /// Next Ib in the same level.
    next: Num = .null,
    /// Down pointer either to next Ib level or Db leaf.
    ///
    /// 0 down num means null, so it is reliable to use this for iteration end.
    down: [capacity]u32 align(config.dcache_line_bytes) = @splat(0),
    pad: u32 = undefined,

    comptime {
        assert(@sizeOf(Ib) == 4 * config.dcache_line_bytes);
    }

    pub const Num = enum(u32) { null = 0, _ };
    pub const PtrNum = struct {
        ptr: *Ib,
        num: Num,

        pub const Iter = struct {
            prev_is_next: bool,
            /// Only possibly null when prev_is_next == true to cache an
            /// end-of-iteration.
            prev: ?PtrNum,
            pub fn next(it: *Iter, r: *SkipRope) ?PtrNum {
                if (it.prev_is_next) {
                    it.prev_is_next = false;
                    return it.prev;
                }
                if (it.prev == null) return null;

                const next_num = it.prev.?.ptr.next;
                if (next_num == .null) {
                    it.prev = null;
                    return null;
                }

                const next_ptr = r.ib_at(next_num);
                it.prev = .{ .num = next_num, .ptr = next_ptr };
                return it.prev.?;
            }
            pub fn peek(it: *Iter, r: *SkipRope) ?PtrNum {
                const ret = it.next(r);
                it.prev_is_next = true;
                return ret;
            }
            pub fn has_next(it: *const Iter) bool {
                if (it.prev_is_next) return it.prev != null;
                const next_num = it.prev.?.ptr.next;
                return next_num != .null;
            }
        };
        pub fn iter(first: PtrNum) Iter {
            return .{ .prev_is_next = true, .prev = first };
        }

        pub fn shift_suffix_left(ib: PtrNum, src_rank: CapInt) void {
            const src_len = ib.ptr.len();
            const move_len = src_len - src_rank;
            std.mem.copyForwards(
                u32,
                ib.ptr.wide[0..move_len],
                ib.ptr.wide[src_rank..src_len],
            );
            std.mem.copyForwards(
                u32,
                ib.ptr.down[0..move_len],
                ib.ptr.down[src_rank..src_len],
            );
            ib.ptr.truncate(move_len);
        }

        /// Find down ptr of absolute ofs within this ib layer
        pub fn find(
            first: PtrNum,
            r: *SkipRope,
            comptime with_prev: bool,
            prev: if (with_prev) ?PtrNum else void,
            first_ofs: BytesInt,
            first_is_header: bool,
            ofs: BytesInt,
        ) ?struct {
            ib: PtrNum,
            ib_ofs: BytesInt,
            ib_prev: if (with_prev) ?PtrNum else void,
            rank: CapInt,
            rank_ofs: BytesInt,
        } {
            log.debug(@src(), "PtrNum.find()", .{
                .first = first,
                .first_ofs = first_ofs,
                .first_is_header = first_is_header,
                .ofs = ofs,
            });
            var ib_ofs = first_ofs;
            var it = first.iter();

            // Ib always has at least one child
            assert(it.peek(r).?.ptr.down[0] != 0);
            if (first_is_header) {
                @branchHint(.unlikely);
                assert(ib_ofs == 0);
            } else {
                if (with_prev) assert(prev != null);
                // Only header Ib can have 0-width
                assert(it.peek(r).?.ptr.wide[0] != 0);
            }

            var ib_prev = prev;
            while (it.next(r)) |ib| {
                var ib_w: u32 = 0;
                for (0.., ib.ptr.wide, ib.ptr.down) |i, w, d| {
                    if (d == 0) break; // end of ib
                    if (ofs <= ib_ofs + ib_w + w)
                        return .{
                            .ib = ib,
                            .ib_ofs = ib_ofs,
                            .ib_prev = ib_prev,
                            .rank = @intCast(i),
                            .rank_ofs = ib_ofs + ib_w,
                        };
                    ib_w += w;
                }
                ib_ofs += ib_w;
                if (with_prev) ib_prev = ib;
            }
            return null;
        }

        /// Append slice items in this layer after last of `ib_cur`.
        /// May allocate one new sibling block if needed.
        pub fn append_ib_slice(
            ib_cur: PtrNum,
            r: *SkipRope,
            gpa: Allocator,
            ib_cur_len: CapInt,
            slice: struct {
                ib: *const Ib,
                ofs: CapInt,
                len: CapInt,
            },
        ) Allocator.Error!void {
            log.debug(@src(), "append_ib_slice()", .{
                .fits_in_cur = slice.len <= Ib.capacity - ib_cur_len,
                .slice = slice,
                .ib_cur = ib_cur,
                .ib_cur_len = ib_cur_len,
            });
            if (slice.len <= Ib.capacity - ib_cur_len) {
                // fits in ib_cur
                const cpy_len = slice.len;
                @memcpy(
                    ib_cur.ptr.wide[ib_cur_len..][0..cpy_len],
                    slice.ib.wide[slice.ofs..][0..cpy_len],
                );
                @memcpy(
                    ib_cur.ptr.down[ib_cur_len..][0..cpy_len],
                    slice.ib.down[slice.ofs..][0..cpy_len],
                );
            } else {
                // need to allocate an extra block
                const cpy_len1 = @min(
                    slice.len,
                    Ib.capacity - ib_cur_len,
                );
                @memcpy(
                    ib_cur.ptr.wide[ib_cur_len..][0..cpy_len1],
                    slice.ib.wide[slice.ofs..][0..cpy_len1],
                );
                @memcpy(
                    ib_cur.ptr.down[ib_cur_len..][0..cpy_len1],
                    slice.ib.down[slice.ofs..][0..cpy_len1],
                );
                const cpy_len2 = slice.len - cpy_len1;
                assert(cpy_len2 <= Ib.capacity);

                const ib_new = try r.ib_create(gpa);
                ib_new.ptr.* = .{};
                ib_new.ptr.next = ib_cur.ptr.next;
                ib_cur.ptr.next = ib_new.num;

                @memcpy(
                    ib_new.ptr.wide[0..cpy_len2],
                    slice.ib.wide[slice.ofs..][cpy_len1..][0..cpy_len2],
                );
                @memcpy(
                    ib_new.ptr.down[0..cpy_len2],
                    slice.ib.down[slice.ofs..][cpy_len1..][0..cpy_len2],
                );
            }
        }
    };

    pub fn truncate(ib: *Ib, new_len: CapInt) void {
        @memset(ib.wide[new_len..], 0);
        @memset(ib.down[new_len..], 0);
    }

    pub inline fn end(ib: *const Ib, start: CapInt) CapInt {
        return if (start < Ib.capacity)
            for (start.., ib.down[start..]) |i, d| {
                if (d == 0) break @intCast(i);
            } else Ib.capacity
        else
            start;
    }

    pub inline fn len(ib: *const Ib) CapInt {
        return for (0.., ib.down) |i, d| {
            if (d == 0) break @intCast(i);
        } else Ib.capacity;
    }
};

/// Data Leaf Block
///
/// K = byte ofs
/// V = byte
///
/// `-inf` header case is handled as a 0-len Db which would otherwise be
/// invalid.
///
const Db = extern struct {
    const capacity = (2 * config.dcache_line_bytes - 1 - @sizeOf(u32));
    pub const CapInt = std.math.IntFittingRange(0, capacity);

    len: u8 align(config.dcache_line_bytes) = 0,
    data: [capacity]u8 = undefined,
    next: Num = .null,

    comptime {
        assert(u8 == std.math.ByteAlignedInt(
            std.math.IntFittingRange(0, capacity),
        ));
        assert(@sizeOf(Db) == 2 * config.dcache_line_bytes);
    }

    pub const Num = enum(u32) { null = 0, _ };
    pub const PtrNum = struct {
        ptr: *Db,
        num: Num,

        pub const Iter = struct {
            prev_is_next: bool,
            /// Only possibly null when prev_is_next == true to cache an
            /// end-of-iteration.
            prev: ?PtrNum,
            pub fn next(it: *Iter, r: *SkipRope) ?PtrNum {
                if (it.prev_is_next) {
                    it.prev_is_next = false;
                    return it.prev;
                }
                if (it.prev == null) return null;

                const next_num = it.prev.?.ptr.next;
                if (next_num == .null) {
                    it.prev = null;
                    return null;
                }

                const next_ptr = r.db_at(next_num);
                it.prev = .{ .num = next_num, .ptr = next_ptr };
                return it.prev.?;
            }
            pub fn peek(it: *Iter, r: *SkipRope) ?PtrNum {
                const ret = it.next(r);
                it.prev_is_next = true;
                return ret;
            }
            pub fn has_next(it: *const Iter) bool {
                if (it.prev_is_next) return it.prev != null;
                const next_num = it.prev.?.ptr.next;
                return next_num != .null;
            }
        };
        pub fn iter(first: PtrNum) Iter {
            return .{ .prev_is_next = true, .prev = first };
        }

        pub fn shift_suffix_left(db: PtrNum, src_rank: CapInt) void {
            const src_len = db.ptr.len;
            const move_len = src_len - src_rank;
            std.mem.copyForwards(
                u8,
                db.ptr.data[0..move_len],
                db.ptr.data[src_rank..src_len],
            );
            db.ptr.truncate(@intCast(move_len));
        }

        /// Find down ptr of absolute ofs within this db layer
        pub fn find(
            first: PtrNum,
            r: *SkipRope,
            first_ofs: BytesInt,
            first_is_header: bool,
            ofs: BytesInt,
        ) ?struct {
            db: PtrNum,
            db_ofs: BytesInt,
            rank: CapInt,
            rank_ofs: BytesInt,
        } {
            var db_ofs = first_ofs;
            var it = first.iter();
            if (!first_is_header) {
                @branchHint(.likely);
                assert(it.peek(r).?.ptr.len > 0);
            }
            while (it.next(r)) |db| {
                if (ofs <= db_ofs + db.ptr.len) {
                    return .{
                        .db = db,
                        .db_ofs = db_ofs,
                        .rank = @intCast(ofs - db_ofs),
                        .rank_ofs = ofs,
                    };
                }
                db_ofs += db.ptr.len;
            }
            return null;
        }

        /// Append slice items in this layer after last of `db_cur`.
        /// May allocate one new sdbling block if needed.
        pub fn append_db_slice(
            db_cur: PtrNum,
            r: *SkipRope,
            gpa: Allocator,
            slice: struct {
                db: *const Db,
                ofs: CapInt,
                len: CapInt,
            },
        ) Allocator.Error!void {
            log.debug(@src(), "append_db_slice()", .{
                .fits_in_cur = slice.len <= Db.capacity - db_cur.ptr.len,
                .slice = slice,
                .db_cur = db_cur,
            });
            if (slice.len <= Db.capacity - db_cur.ptr.len) {
                // fits in ib_cur
                const cpy_len = slice.len;
                @memcpy(
                    db_cur.ptr.data[db_cur.ptr.len..][0..cpy_len],
                    slice.db.data[slice.ofs..][0..cpy_len],
                );
                db_cur.ptr.len += cpy_len;
            } else {
                // need to allocate an extra block
                const cpy_len1 = @min(
                    slice.len,
                    Db.capacity - db_cur.ptr.len,
                );
                @memcpy(
                    db_cur.ptr.data[db_cur.ptr.len..][0..cpy_len1],
                    slice.db.data[slice.ofs..][0..cpy_len1],
                );
                assert(db_cur.ptr.len + cpy_len1 == Db.capacity);
                db_cur.ptr.len = Db.capacity;

                const cpy_len2 = slice.len - cpy_len1;
                assert(cpy_len2 <= Db.capacity);

                const db_new = try r.db_create(gpa);
                db_new.ptr.* = .{};
                db_new.ptr.next = db_cur.ptr.next;
                db_cur.ptr.next = db_new.num;

                @memcpy(
                    db_new.ptr.data[0..cpy_len2],
                    slice.db.data[slice.ofs..][cpy_len1..][0..cpy_len2],
                );
                db_new.ptr.len = cpy_len2;
            }
        }
    };

    pub fn truncate(db: *Db, new_len: CapInt) void {
        @memset(db.data[new_len..], undefined);
        db.len = new_len;
    }
};

fn FindCursor() type {
    return struct {
        b: union {
            ib: Ib.PtrNum,
            db: Db.PtrNum,
        },
        b_ofs: BytesInt,
        b_is_header: bool,
        down: struct {
            rank: union { in_ib: Ib.CapInt, in_db: Db.CapInt },
            rank_ofs: BytesInt,
        } = undefined,

        pub fn ib_find_ofs(c: *@This(), r: *SkipRope, ofs: BytesInt) bool {
            const found = c.b.ib.find(
                r,
                false,
                {},
                c.b_ofs,
                c.b_is_header,
                ofs,
            ) orelse return false;
            if (c.b.ib.num != found.ib.num) c.b_is_header = false;
            c.b = .{ .ib = found.ib };
            c.b_ofs = found.ib_ofs;
            c.down = .{
                .rank = .{ .in_ib = found.rank },
                .rank_ofs = found.rank_ofs,
            };
            return true;
        }
        pub fn ib_find_ofs_with_prev(
            c: *@This(),
            r: *SkipRope,
            ofs: BytesInt,
            prev: ?Ib.PtrNum,
        ) ?struct {
            ib_prev: ?Ib.PtrNum,
        } {
            const found = c.b.ib.find(
                r,
                true,
                prev,
                c.b_ofs,
                c.b_is_header,
                ofs,
            ) orelse return null;
            if (c.b.ib.num != found.ib.num) c.b_is_header = false;
            c.b = .{ .ib = found.ib };
            c.b_ofs = found.ib_ofs;
            c.down = .{
                .rank = .{ .in_ib = found.rank },
                .rank_ofs = found.rank_ofs,
            };
            return .{ .ib_prev = found.ib_prev };
        }
        pub fn ib_descend_as_ib(c: *@This(), r: *SkipRope) void {
            const parent = c.b.ib;
            const rank = c.down.rank.in_ib;
            const is_header = c.b_is_header and rank == 0;
            const num: Ib.Num = @enumFromInt(
                parent.ptr.down[rank],
            );
            const ib: Ib.PtrNum = .{ .num = num, .ptr = r.ib_at(num) };
            c.b_is_header = is_header;
            c.b = .{ .ib = ib };
            c.b_ofs = c.down.rank_ofs;
        }
        pub fn ib_descend_as_db(c: *@This(), r: *SkipRope) void {
            c.b_is_header = c.b_is_header and c.down.rank.in_ib == 0;
            const num: Db.Num = @enumFromInt(
                c.b.ib.ptr.down[c.down.rank.in_ib],
            );
            const db: Db.PtrNum = .{ .num = num, .ptr = r.db_at(num) };
            c.b = .{ .db = db };
            c.b_ofs = c.down.rank_ofs;
        }
        pub fn db_find_ofs(c: *@This(), r: *SkipRope, ofs: BytesInt) bool {
            const found = c.b.db.find(
                r,
                c.b_ofs,
                c.b_is_header,
                ofs,
            ) orelse return false;
            if (c.b.db.num != found.db.num) c.b_is_header = false;
            c.b = .{ .db = found.db };
            c.b_ofs = found.db_ofs;
            c.down = .{
                .rank = .{ .in_db = found.rank },
                .rank_ofs = found.rank_ofs,
            };
            return true;
        }

        pub fn ib_find_ofs_leaf(
            c: *@This(),
            r: *SkipRope,
            ib_height: HeightInt,
            ofs: BytesInt,
        ) bool {
            for (0..ib_height) |_| {
                if (!c.ib_find_ofs(r, ofs)) return false;
                c.ib_descend_as_ib(r);
            }
            if (!c.ib_find_ofs(r, ofs)) return false;
            c.ib_descend_as_db(r);
            return c.db_find_ofs(r, ofs);
        }
    };
}

pub fn deinit(r: *SkipRope, gpa: Allocator) void {
    r.ibs.deinit(gpa);
    r.dbs.deinit(gpa);
    r.* = undefined;
}

pub fn db_create(r: *SkipRope, gpa: Allocator) Allocator.Error!Db.PtrNum {
    const db = try r.dbs.create(gpa);
    return .{
        .ptr = db.ptr,
        .num = @enumFromInt(db.num.to_int() + 1),
    };
}
pub fn ib_create(r: *SkipRope, gpa: Allocator) Allocator.Error!Ib.PtrNum {
    const ib = try r.ibs.create(gpa);
    return .{
        .ptr = ib.ptr,
        .num = @enumFromInt(ib.num.to_int() + 1),
    };
}
pub fn db_at(r: *SkipRope, num: Db.Num) *Db {
    assert(num != .null);
    return r.dbs.at(.cast(@intFromEnum(num) - 1));
}
pub fn ib_at(r: *SkipRope, num: Ib.Num) *Ib {
    assert(num != .null);
    return r.ibs.at(.cast(@intFromEnum(num) - 1));
}
fn ib_descend_prev(
    r: *SkipRope,
    parent: Ib.PtrNum,
    parent_prev: ?Ib.PtrNum,
    parent_is_header: bool,
    rank: Ib.CapInt,
) ?Ib.PtrNum {
    if (parent_is_header and rank == 0) return null;

    const num: Ib.Num = @enumFromInt(parent.ptr.down[rank]);
    const prev_start_num: Ib.Num = if (rank > 0)
        @enumFromInt(parent.ptr.down[rank - 1])
    else blk: {
        const prev_parent = parent_prev.?;
        break :blk @enumFromInt(
            prev_parent.ptr.down[prev_parent.ptr.len() - 1],
        );
    };
    var it = Ib.PtrNum.iter(.{
        .num = prev_start_num,
        .ptr = r.ib_at(prev_start_num),
    });
    while (it.next(r)) |prev| {
        if (prev.ptr.next == num) return prev;
    }
    unreachable;
}
pub fn db_destroy(r: *SkipRope, num: Db.Num) void {
    assert(num != .null);
    r.dbs.destroy(.cast(@intFromEnum(num) - 1));
}
pub fn ib_destroy(r: *SkipRope, num: Ib.Num) void {
    assert(num != .null);
    r.ibs.destroy(.cast(@intFromEnum(num) - 1));
}

pub fn jsonStringify(r: *const SkipRope, jw: anytype) !void {
    try jw.write(.{
        .root = r.root,
        .len = r.len,
        .ib_height = r.ib_height,
    });
}

pub const ReadCursor = struct {
    it: ?Db.PtrNum.Iter,
    rank: Db.CapInt,
    rest: BytesInt,

    pub fn peek(cur: *ReadCursor, r: *SkipRope) ?[]const u8 {
        if (cur.rest == 0) return null;

        const it = &(cur.it orelse return null);
        const db = it.peek(r) orelse {
            cur.it = null;
            cur.rest = 0;
            return null;
        };

        const avail: usize = db.ptr.len - cur.rank;
        assert(avail != 0);

        const len: Db.CapInt = @intCast(@min(
            @as(usize, cur.rest),
            avail,
        ));
        return db.ptr.data[cur.rank..][0..len];
    }

    pub fn consume(cur: *ReadCursor, r: *SkipRope, n_: BytesInt) void {
        assert(n_ <= cur.rest);
        var n = n_;
        while (n != 0) {
            const chunk = cur.peek(r) orelse unreachable;
            const take: BytesInt = @intCast(@min(@as(usize, n), chunk.len));

            cur.rest -= take;
            n -= take;
            if (take == chunk.len) {
                cur.rank = 0;
                _ = cur.it.?.next(r);
            } else {
                cur.rank += @intCast(take);
            }
        }
    }

    pub fn skip_until(cur: *ReadCursor, r: *SkipRope, needle: u8) bool {
        while (cur.peek(r)) |chunk| {
            if (std.mem.indexOfScalar(u8, chunk, needle)) |idx| {
                cur.consume(r, @intCast(idx + 1));
                return true;
            }
            cur.consume(r, @intCast(chunk.len));
        }
        return false;
    }

    pub fn next_chunk(cur: *ReadCursor, r: *SkipRope) ?[]const u8 {
        const chunk = cur.peek(r) orelse return null;
        cur.consume(r, @intCast(chunk.len));
        return chunk;
    }
};

pub fn read_cursor_at(r: *SkipRope, ofs: BytesInt) ReadCursor {
    assert(ofs <= r.len);
    if (ofs == r.len or r.root == .null) {
        return .{
            .it = null,
            .rank = 0,
            .rest = 0,
        };
    }

    const found = db_iter_at_ofs(r, ofs) orelse unreachable;
    return .{
        .it = found.it,
        .rank = found.rank,
        .rest = r.len - ofs,
    };
}

fn db_iter_at_ofs(
    r: *SkipRope,
    ofs: BytesInt,
) ?struct {
    it: Db.PtrNum.Iter,
    rank: Db.CapInt,
} {
    if (r.root == .null) return null;

    const root: Ib.PtrNum = .{
        .num = r.root,
        .ptr = r.ib_at(r.root),
    };
    var find_cur: FindCursor() = .{
        .b = .{ .ib = root },
        .b_ofs = 0,
        .b_is_header = true,
    };
    if (!find_cur.ib_find_ofs_leaf(r, r.ib_height, ofs))
        std.debug.panic("offset out of bounds", .{});

    var it = find_cur.b.db.iter();
    var rank = find_cur.down.rank.in_db;
    if (rank == find_cur.b.db.ptr.len) {
        _ = it.next(r);
        rank = 0;
    }

    return .{
        .it = it,
        .rank = rank,
    };
}

pub fn insert(
    r: *SkipRope,
    gpa: Allocator,
    pos: BytesInt,
    text: []const u8,
) Allocator.Error!void {
    if (text.len == 0) return;

    // Min height to densely hold text in a b-subtree
    const h_ins_min: HeightInt = if (text.len <= Db.capacity) 0 else ( //
        1 + @as(HeightInt, @intCast(std.math.log_int(u32, Ib.capacity, @intCast(
            @divFloor(text.len, Db.capacity),
        )))) //
    );
    // Augmented probabilistically
    // Actual insert height
    const h_ins = augment_height(r.rng.random(), h_ins_min, max_height);
    var subt: LazySubtree = .{ .height = h_ins, .text = text };

    var h_tree: HeightInt = r.ib_height + 2;

    log.info(@src(), "insert()", .{
        .r_len = r.len,
        .pos = pos,
        .text_len = text.len,
        .text = text,
        .h_ins_min = h_ins_min,
        .h_ins = h_ins,
        .h_tree = h_tree,
    });

    var root: Ib.PtrNum = if (r.root == .null) x: {
        @branchHint(.unlikely);
        const ib_new = try r.ib_create(gpa);
        const db_new = try r.db_create(gpa);
        ib_new.ptr.* = .{};
        db_new.ptr.* = .{};
        ib_new.ptr.wide[0] = 0;
        ib_new.ptr.down[0] = @intFromEnum(db_new.num);
        h_tree = 2;
        break :x ib_new;
    } else .{
        .num = r.root,
        .ptr = r.ib_at(r.root),
    };
    defer assert(r.ib_height == h_tree - 2);
    defer assert(r.root == root.num);

    if (h_ins > h_tree - 1) {
        // Tree doesn't grow in height very often. Not currently optimizing for
        // this path.
        @branchHint(.unlikely);

        log.debug(@src(), "growing tree", .{});

        var root_w: u32 = 0;
        var root_iter = root.iter();
        while (root_iter.next(r)) |ib| {
            for (ib.ptr.wide) |w| root_w += w;
        }

        for (0..(h_ins - (h_tree - 1))) |_| {
            const ib_new = try r.ib_create(gpa);
            ib_new.ptr.* = .{};
            ib_new.ptr.wide[0] = root_w;
            ib_new.ptr.down[0] = @intFromEnum(root.num);

            h_tree += 1;
            root = ib_new;
        }
        assert(h_ins == h_tree - 1);
    }

    assert(h_ins <= h_tree - 1);

    var cur: FindCursor() = .{
        .b = .{ .ib = root },
        .b_ofs = 0,
        .b_is_header = true,
    };

    // top-down from tree top to bottom ib layer
    var h_cur = h_tree - 1;
    while (h_cur > 0) : (h_cur -= 1) {
        if (!cur.ib_find_ofs(r, pos)) {
            std.debug.panic("insertion point out of bounds", .{});
        }

        const rank = cur.down.rank.in_ib;
        if (h_cur == h_ins) {
            const ib_cur_len = cur.b.ib.ptr.end(rank + 1);

            const w_over: u32 =
                @intCast(cur.b.ib.ptr.wide[rank] - (pos - cur.down.rank_ofs));
            cur.b.ib.ptr.wide[rank] -= w_over;

            assert(subt.height == h_cur);
            try subt.inline_first_ib_layer(r, gpa, .{
                .ib = cur.b.ib,
                .rank = rank + 1,
            }, ib_cur_len, w_over);
        } else if (h_cur < h_ins) {
            const w_over: u32 =
                @intCast(cur.b.ib.ptr.wide[rank] - (pos - cur.down.rank_ofs));
            cur.b.ib.ptr.wide[rank] -= w_over;

            assert(subt.height == h_cur);
            const subt_layer = try subt.promoted_next_ib_layer(r, gpa, w_over);
            subt_layer.tail.ptr.next = cur.b.ib.ptr.next;
            cur.b.ib.ptr.next = subt_layer.head.num;

            // move all ib_cur[rank+1..] to the end of tail
            if (rank < Ib.capacity - 1) {
                const ib_cur_len = cur.b.ib.ptr.end(rank + 1);

                // NOTE: down ptrs are zero in this case as the subt is being
                //       built lazily. We count the len here based on 0-wides.
                const tail_len: Ib.CapInt =
                    for (0.., subt_layer.tail.ptr.wide) |i, w| {
                        if (w == 0) break @intCast(i); // end of ib
                    } else Ib.capacity;

                const ib_cur_over_len = ib_cur_len - (rank + 1);
                try subt_layer.tail.append_ib_slice(r, gpa, tail_len, .{
                    .ib = cur.b.ib.ptr,
                    .ofs = rank + 1,
                    .len = ib_cur_over_len,
                });
                cur.b.ib.ptr.truncate(rank + 1);
            }
        } else {
            cur.b.ib.ptr.wide[rank] += @intCast(text.len);
        }

        if (h_cur > 1)
            cur.ib_descend_as_ib(r)
        else
            cur.ib_descend_as_db(r);
    }

    // And now all the same but for the db layer
    assert(h_cur == 0);
    assert(cur.b.db.num != .null);
    {
        if (!cur.db_find_ofs(r, pos))
            std.debug.panic("insertion point out of bounds", .{});

        const rank = cur.down.rank.in_db;
        if (h_cur == h_ins) {
            assert(subt.height == h_cur);
            try subt.inline_first_db_layer(r, gpa, .{
                .db = cur.b.db,
                .rank = rank,
            });
        } else if (h_cur < h_ins) {
            assert(subt.height == h_cur);
            const subt_layer = try subt.promoted_next_db_layer(r, gpa);
            subt_layer.tail.ptr.next = cur.b.db.ptr.next;
            cur.b.db.ptr.next = subt_layer.head.num;

            // move all db_cur[rank..] to the end of tail
            if (rank < Db.capacity) {
                const db_cur_len = cur.b.db.ptr.len;

                const db_cur_over_len = db_cur_len - rank;
                try subt_layer.tail.append_db_slice(r, gpa, .{
                    .db = cur.b.db.ptr,
                    .ofs = rank,
                    .len = @intCast(db_cur_over_len),
                });
                cur.b.db.ptr.truncate(rank);
            }
        } else {
            unreachable;
        }
    }

    r.len += @intCast(text.len);
    r.ib_height = h_tree - 2;
    r.root = root.num;
}

test "insert" {
    const log_ = @import("./log.zig");
    log_.testing_level.* = .warn;
    // log_.testing_scope_levels = &.{
    //     .{ .scope = .fuzz, .level = .info },
    //     .{ .scope = .rope, .level = .debug },
    //     .{ .scope = .rope_test, .level = .debug },
    // };

    var r: SkipRope = .empty;
    defer r.deinit(std.testing.allocator);

    try r.insert(std.testing.allocator, 0, "Hello, world!");
    try r.insert(std.testing.allocator, 1, "Hello, world!");
    try r.insert(std.testing.allocator, 0, "Hello, world!");
    // std.debug.print("{f}", .{r.fmtString(0, r.len)});
}

test "delete-smoke" {
    var r: SkipRope = .empty;
    defer r.deinit(std.testing.allocator);

    try r.insert(std.testing.allocator, 0, "Hello, world!");
    r.delete(5, 2);
    try r.expect_valid();
    try std.testing.expectFmt("Helloworld!", "{f}", .{r.fmtString(0, r.len)});
    try std.testing.expectFmt("world", "{f}", .{r.fmtString(5, 5)});

    r.delete(0, 5);
    try r.expect_valid();
    try std.testing.expectFmt("world!", "{f}", .{r.fmtString(0, r.len)});

    var big: [Db.capacity * 3]u8 = undefined;
    for (&big, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    try r.insert(std.testing.allocator, r.len, &big);
    try r.expect_valid();

    r.delete(3, Db.capacity + 17);
    try r.expect_valid();

    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(std.testing.allocator);
    try expect.appendSlice(std.testing.allocator, "wor");
    try expect.appendSlice(std.testing.allocator, big[Db.capacity + 14 ..]);
    try std.testing.expectFmt(expect.items, "{f}", .{r.fmtString(0, r.len)});
}

test "delete-against-arraylist" {
    var r: SkipRope = .empty;
    defer r.deinit(std.testing.allocator);
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(std.testing.allocator);

    var big: [Db.capacity * 6]u8 = undefined;
    for (&big, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));

    try r.insert(std.testing.allocator, 0, &big);
    try s.appendSlice(std.testing.allocator, &big);

    const Case = struct { pos: BytesInt, len: BytesInt };
    const cases = [_]Case{
        .{ .pos = 0, .len = 1 },
        .{ .pos = 17, .len = 29 },
        .{ .pos = Db.capacity - 5, .len = 11 },
        .{ .pos = Db.capacity + 9, .len = Db.capacity + 21 },
        .{ .pos = Db.capacity * 3 - 7, .len = Db.capacity + 15 },
        .{ .pos = 3, .len = 0 },
        .{ .pos = 5, .len = Db.capacity / 2 },
        .{ .pos = @intCast(big.len - (Db.capacity + 77)), .len = 33 },
    };

    for (cases) |c| {
        if (c.pos > r.len) continue;
        const del_len = @min(c.len, r.len - c.pos);
        r.delete(c.pos, del_len);
        s.replaceRangeAssumeCapacity(c.pos, del_len, "");
        try r.expect_valid();
        try std.testing.expectFmt(s.items, "{f}", .{r.fmtString(0, r.len)});
    }

    r.delete(0, r.len);
    s.replaceRangeAssumeCapacity(0, s.items.len, "");
    try r.expect_valid();
    try std.testing.expectFmt(s.items, "{f}", .{r.fmtString(0, r.len)});
}

test "read cursor streams across db boundaries" {
    var r: SkipRope = .empty;
    defer r.deinit(std.testing.allocator);

    const part = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const text: [part.len * 5]u8 = @bitCast(@as([5][part.len]u8, @splat(part.*)));
    try r.insert(std.testing.allocator, 0, &text);

    var cur = r.read_cursor_at(0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    while (cur.next_chunk(&r)) |chunk| {
        try out.appendSlice(std.testing.allocator, chunk);
    }

    try std.testing.expectEqualStrings(&text, out.items);
}

test "read cursor can start at db boundary" {
    var r: SkipRope = .empty;
    defer r.deinit(std.testing.allocator);

    const part = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const text: [part.len * 5]u8 = @bitCast(@as([5][part.len]u8, @splat(part.*)));
    try r.insert(std.testing.allocator, 0, &text);

    var split_ofs: usize = 0;
    {
        var cur = r.read_cursor_at(0);
        const first = cur.next_chunk(&r).?;
        split_ofs = first.len;
        try std.testing.expect(split_ofs < text.len);
    }

    var cur = r.read_cursor_at(@intCast(split_ofs));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    while (cur.next_chunk(&r)) |chunk| {
        try out.appendSlice(std.testing.allocator, chunk);
    }

    try std.testing.expectEqualStrings(text[split_ofs..], out.items);
}

test "delete: targeted regression cases" {
    const gpa = std.testing.allocator;
    const db_cap: BytesInt = @intCast(Db.capacity);
    const short = @max(
        @as(BytesInt, 1),
        @as(BytesInt, @intCast(Db.capacity / 16)),
    );
    const cross: BytesInt = db_cap + short;
    const many_leaf_blocks = Db.capacity * (Ib.capacity + 8);

    const Case = struct {
        text_len: usize,
        pos: BytesInt,
        len: BytesInt,
    };
    const cases = [_]Case{
        // same-block keep-slot
        .{
            .text_len = Db.capacity * 2,
            .pos = short,
            .len = short,
        },
        // same-block merge-left
        .{
            .text_len = Db.capacity * 2,
            .pos = db_cap,
            .len = short,
        },
        // later-block keep-slot
        .{
            .text_len = Db.capacity * 4,
            .pos = db_cap - short,
            .len = cross,
        },
        // later-block merge-left
        .{
            .text_len = Db.capacity * 4,
            .pos = db_cap,
            .len = cross,
        },
        // exact-tail
        .{
            .text_len = Db.capacity * 5,
            .pos = db_cap + short,
            .len = db_cap * 2 - short,
        },
        // whole-rope
        .{
            .text_len = Db.capacity * 3,
            .pos = 0,
            .len = db_cap * 3,
        },
        // multi-ib later-block keep-slot
        .{
            .text_len = many_leaf_blocks,
            .pos = db_cap * 2,
            .len = db_cap * 20 + 11,
        },
        // multi-ib later-block merge-left
        .{
            .text_len = many_leaf_blocks,
            .pos = db_cap * 31,
            .len = db_cap * 5 + 19,
        },
    };
    const max_text_len = comptime blk: {
        var max_len: usize = 0;
        for (cases) |c| max_len = @max(max_len, c.text_len);
        break :blk max_len;
    };
    var text_buf: [max_text_len]u8 = undefined;

    for (cases) |c| {
        var r: SkipRope = .empty;
        defer r.deinit(gpa);
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(gpa);

        const text = text_buf[0..c.text_len];
        for (text, 0..) |_, i| {
            text[i] = 'a' + @as(u8, @intCast(i % 26));
        }

        try r.insert(gpa, 0, text);
        try s.appendSlice(gpa, text);

        r.delete(c.pos, c.len);
        s.replaceRangeAssumeCapacity(c.pos, c.len, "");

        try r.expect_valid();
        try std.testing.expectFmt(
            s.items,
            "{f}",
            .{r.fmtString(0, r.len)},
        );
    }
}

test "delete: edge-aligned keep-slot and merge-left cases" {
    const gpa = std.testing.allocator;

    var r: SkipRope = .empty;
    defer r.deinit(gpa);
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);

    const text_len = Db.capacity * (Ib.capacity + 4);
    var text: [text_len]u8 = undefined;
    for (&text, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));

    try r.insert(gpa, 0, &text);
    try s.appendSlice(gpa, &text);

    r.delete(Db.capacity - 1, Db.capacity * 3 + 1);
    s.replaceRangeAssumeCapacity(Db.capacity - 1, Db.capacity * 3 + 1, "");
    try r.expect_valid();
    try std.testing.expectFmt(s.items, "{f}", .{r.fmtString(0, r.len)});

    r.delete(Db.capacity * 2, Db.capacity * 2);
    s.replaceRangeAssumeCapacity(Db.capacity * 2, Db.capacity * 2, "");
    try r.expect_valid();
    try std.testing.expectFmt(s.items, "{f}", .{r.fmtString(0, r.len)});
}

test "delete shortens unary top levels" {
    const gpa = std.testing.allocator;

    var r: SkipRope = .empty;
    defer r.deinit(gpa);

    var text: [Db.capacity * Ib.capacity * 2]u8 = undefined;
    for (&text, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));

    try r.insert(gpa, 0, &text);
    try std.testing.expect(r.ib_height > 0);

    const old_root = r.root;
    r.delete(0, text.len);

    try r.expect_valid();
    try std.testing.expectEqual(@as(BytesInt, 0), r.len);
    try std.testing.expectEqual(@as(HeightInt, 0), r.ib_height);
    try std.testing.expectEqual(SkipRope.empty.root, r.root);
    try std.testing.expect(r.root != old_root);
    try std.testing.expectFmt("", "{f}", .{r.fmtString(0, r.len)});
}

pub fn delete(
    r: *SkipRope,
    pos: BytesInt,
    len: BytesInt,
) void {
    if (len == 0) return;
    if (r.root == .null) {
        assert(len == 0);
        return;
    }
    assert(pos <= r.len);
    assert(pos + len <= r.len);

    log.info(@src(), "delete()", .{
        .r_len = r.len,
        .pos = pos,
        .len = len,
    });

    const root: Ib.PtrNum = .{
        .num = r.root,
        .ptr = r.ib_at(r.root),
    };
    var cur: FindCursor() = .{
        .b = .{ .ib = root },
        .b_ofs = 0,
        .b_is_header = true,
    };

    // Delete rule:
    // - If delete starts inside a slot, its owning byte survives and only
    //   that gap width changes.
    // - If delete starts at a slot head, that owning byte dies and its gap
    //   merges left.
    // - Header `-inf` is the only exception.

    // Walk index layers top-down, rewriting the touched suffix in-place
    // before descending.
    var h_cur = r.ib_height + 1;
    var prev_ib: ?Ib.PtrNum = null;
    while (h_cur > 0) : (h_cur -= 1) {
        const found = cur.ib_find_ofs_with_prev(r, pos, prev_ib) orelse
            std.debug.panic("deletion point out of bounds", .{});
        const rank = cur.down.rank.in_ib;
        const del_ofs_in_slot: u32 = @intCast(pos - cur.down.rank_ofs);
        const delete_head =
            del_ofs_in_slot == 0 and !(cur.b_is_header and rank == 0);
        // Keep this slot unless delete starts at its head byte.
        const keep_slot = !delete_head;

        // `dst_*` names the surviving left gap in this layer.
        var rest = len;
        var dst_ib = cur.b.ib;
        var dst_rank = rank;
        var dst_end: Ib.CapInt = rank + 1;
        var dst_w = del_ofs_in_slot;
        if (!keep_slot) {
            // Slot head was deleted, so merge its gap into the left slot.
            if (rank > 0) {
                dst_rank = rank - 1;
                dst_end = rank;
            } else {
                dst_ib = found.ib_prev.?;
                dst_end = dst_ib.ptr.len();
                dst_rank = dst_end - 1;
            }
            dst_w = dst_ib.ptr.wide[dst_rank];
        }

        // Pick the surviving left gap, consume deleted width, then reconnect
        // the first surviving right gap.
        var src_ib_opt: ?Ib.PtrNum = cur.b.ib;
        var src_rank = rank;
        var dst_next: Ib.Num = .null;
        while (src_ib_opt) |src_ib| {
            const next_num = src_ib.ptr.next;
            const src_len = src_ib.ptr.len();

            if (rest > 0) {
                const is_first_block = src_ib.num == cur.b.ib.num;
                var slot = src_rank;
                while (slot < src_len) : (slot += 1) {
                    const slot_w = src_ib.ptr.wide[slot];
                    const slot_is_first = is_first_block and slot == rank;
                    const slot_left_kept =
                        if (slot_is_first) del_ofs_in_slot else 0;
                    const avail = slot_w - slot_left_kept;
                    const del_slot = @min(rest, avail);
                    rest -= del_slot;
                    dst_w += avail - del_slot;
                    if (rest == 0) {
                        src_rank = slot + 1;
                        break;
                    }
                }

                // Either delete still runs past this block, or it ended exactly
                // at the block tail, so there is no surviving right gap here.
                const src_exhausted = src_rank == src_len;
                if (rest > 0 or src_exhausted) {
                    if (src_ib.num == dst_ib.num) {
                        dst_ib.ptr.truncate(dst_end);
                    } else {
                        r.ib_destroy(src_ib.num);
                    }
                    src_ib_opt = if (next_num == .null) null else .{
                        .num = next_num,
                        .ptr = r.ib_at(next_num),
                    };
                    src_rank = 0;
                    continue;
                }
            }

            assert(rest == 0);
            // Once `rest` hits zero, `src_rank` now marks the start of the
            // surviving right gap in `src_ib`.
            if (keep_slot) {
                // If the owning byte survives, later surviving gaps keep
                // starting where they already begin.
                if (src_ib.num == dst_ib.num) {
                    const move_len = src_len - src_rank;
                    std.mem.copyForwards(
                        u32,
                        dst_ib.ptr.wide[dst_end..][0..move_len],
                        src_ib.ptr.wide[src_rank..src_len],
                    );
                    std.mem.copyForwards(
                        u32,
                        dst_ib.ptr.down[dst_end..][0..move_len],
                        src_ib.ptr.down[src_rank..src_len],
                    );
                    dst_end += move_len;
                    dst_next = next_num;
                    break;
                }

                if (src_rank > 0) src_ib.shift_suffix_left(src_rank);
                dst_next = src_ib.num;
                break;
            }

            // If the owning byte dies, its gap merges left, so later surviving
            // gaps may need to be pulled left behind that survivor.
            if (src_ib.num == dst_ib.num) {
                const move_len = src_len - src_rank;
                std.mem.copyForwards(
                    u32,
                    dst_ib.ptr.wide[dst_end..][0..move_len],
                    src_ib.ptr.wide[src_rank..src_len],
                );
                std.mem.copyForwards(
                    u32,
                    dst_ib.ptr.down[dst_end..][0..move_len],
                    src_ib.ptr.down[src_rank..src_len],
                );
                dst_end += move_len;
                dst_next = next_num;
                break;
            }

            // Drain one later block at a time into dst_ib until it is full or
            // until a partial surviving right gap remains.
            const cpy_len = @min(Ib.capacity - dst_end, src_len - src_rank);
            std.mem.copyForwards(
                u32,
                dst_ib.ptr.wide[dst_end..][0..cpy_len],
                src_ib.ptr.wide[src_rank..src_len][0..cpy_len],
            );
            std.mem.copyForwards(
                u32,
                dst_ib.ptr.down[dst_end..][0..cpy_len],
                src_ib.ptr.down[src_rank..src_len][0..cpy_len],
            );
            dst_end += cpy_len;
            src_rank += cpy_len;

            if (src_rank == src_len) {
                r.ib_destroy(src_ib.num);
                src_ib_opt = if (next_num == .null) null else .{
                    .num = next_num,
                    .ptr = r.ib_at(next_num),
                };
                src_rank = 0;
                if (dst_end == Ib.capacity) {
                    dst_next = if (src_ib_opt) |ib| ib.num else .null;
                    break;
                }
                continue;
            }

            src_ib.shift_suffix_left(src_rank);
            dst_next = src_ib.num;
            break;
        }
        assert(rest == 0);

        // Reconnect the first surviving right gap behind the left survivor.
        dst_ib.ptr.wide[dst_rank] = dst_w;
        dst_ib.ptr.truncate(dst_end);
        dst_ib.ptr.next = dst_next;

        // Descend after the local rewrite is complete.
        if (h_cur > 1) {
            prev_ib = ib_descend_prev(
                r,
                cur.b.ib,
                prev_ib,
                cur.b_is_header,
                cur.down.rank.in_ib,
            );
            cur.ib_descend_as_ib(r);
        } else {
            cur.ib_descend_as_db(r);
        }
    }

    assert(h_cur == 0);
    {
        // Leaf step: keep left prefix, splice back surviving byte tail.
        if (!cur.db_find_ofs(r, pos))
            std.debug.panic("deletion point out of bounds", .{});
        const rank = cur.down.rank.in_db;

        var rest = len;
        var dst_end = rank;
        var src_db_opt: ?Db.PtrNum = cur.b.db;
        var src_rank = rank;
        var dst_next: Db.Num = .null;
        while (src_db_opt) |src_db| {
            const next_num = src_db.ptr.next;
            const src_len = src_db.ptr.len;

            if (rest > 0) {
                const del_len = @min(rest, src_len - src_rank);
                rest -= del_len;
                src_rank += @intCast(del_len);
                if (rest > 0 or src_rank == src_len) {
                    if (src_db.num == cur.b.db.num) {
                        cur.b.db.ptr.truncate(dst_end);
                    } else {
                        r.db_destroy(src_db.num);
                    }
                    src_db_opt = if (next_num == .null) null else .{
                        .num = next_num,
                        .ptr = r.db_at(next_num),
                    };
                    src_rank = 0;
                    continue;
                }
            }

            assert(rest == 0);
            const src_exhausted = src_rank == src_len;
            if (src_exhausted) {
                // Delete ended at this block tail, so there is no surviving
                // right gap here; keep scanning for the first later one.
                if (src_db.num == cur.b.db.num) {
                    cur.b.db.ptr.truncate(dst_end);
                } else {
                    r.db_destroy(src_db.num);
                }
                src_db_opt = if (next_num == .null) null else .{
                    .num = next_num,
                    .ptr = r.db_at(next_num),
                };
                src_rank = 0;
                continue;
            }

            // Once `rest` hits zero, `src_rank` now marks the start of the
            // surviving right gap in `src_db`.
            if (src_db.num == cur.b.db.num) {
                const move_len = src_len - src_rank;
                std.mem.copyForwards(
                    u8,
                    cur.b.db.ptr.data[dst_end..][0..move_len],
                    src_db.ptr.data[src_rank..src_len],
                );
                dst_end += @intCast(move_len);
                dst_next = next_num;
                break;
            }

            // Later leaf survives from the middle, so shift its kept tail to
            // the front and relink to it.
            if (src_rank > 0) src_db.shift_suffix_left(src_rank);
            dst_next = src_db.num;
            break;
        }
        assert(rest == 0);
        cur.b.db.ptr.truncate(dst_end);
        cur.b.db.ptr.next = dst_next;

        if (r.len == len and cur.b_is_header) {
            cur.b.db.ptr.truncate(0);
            cur.b.db.ptr.next = .null;
        }
    }

    r.len -= len;

    while (r.ib_height > 0) {
        const root_num = r.root;
        const root_ptr = r.ib_at(root_num);
        const root_is_unary = root_ptr.next == .null and root_ptr.down[1] == 0;
        if (!root_is_unary) break;

        r.root = @enumFromInt(root_ptr.down[0]);
        r.ib_height -= 1;
        r.ib_destroy(root_num);
    }

    if (r.len == 0) {
        const root_num = r.root;
        const root_ptr = r.ib_at(root_num);
        assert(root_ptr.next == .null);
        assert(root_ptr.down[1] == 0);

        const db_num: Db.Num = @enumFromInt(root_ptr.down[0]);
        const db_ptr = r.db_at(db_num);
        assert(db_ptr.next == .null);
        assert(db_ptr.len == 0);

        r.db_destroy(db_num);
        r.ib_destroy(root_num);
        r.root = .null;
        r.ib_height = 0;
    }
}

const FuzzAgainstArrayList = struct {
    const PosCase = enum(u2) { start, end, inner, any };
    const DelCase = enum(u2) { zero, short, to_end, any };

    fn pick_pos(smith: *std.testing.Smith, len: BytesInt) BytesInt {
        if (len == 0) return 0;

        // Hit ends often, but still spend most cases on a full-range pick.
        return switch (smith.valueWeighted(PosCase, &.{
            std.testing.Smith.Weight.value(PosCase, .start, 3),
            std.testing.Smith.Weight.value(PosCase, .end, 3),
            std.testing.Smith.Weight.value(PosCase, .inner, 1),
            std.testing.Smith.Weight.value(PosCase, .any, 9),
        })) {
            .start => 0,
            .end => len,
            .inner => smith.valueRangeAtMost(BytesInt, 0, len - 1),
            .any => smith.valueRangeAtMost(BytesInt, 0, len),
        };
    }

    fn pick_del_len(smith: *std.testing.Smith, max_len: BytesInt) BytesInt {
        if (max_len == 0) return 0;

        // Bias to short dels for more ops,
        // keep some full-tail and full-range cases.
        return switch (smith.valueWeighted(DelCase, &.{
            std.testing.Smith.Weight.value(DelCase, .zero, 1),
            std.testing.Smith.Weight.value(DelCase, .short, 8),
            std.testing.Smith.Weight.value(DelCase, .to_end, 2),
            // Keep some full-range dels so long cuts still show up.
            std.testing.Smith.Weight.value(DelCase, .any, 4),
        })) {
            .zero => 0,
            .short => smith.valueRangeAtMost(BytesInt, 1, @min(max_len, 16)),
            .to_end => max_len,
            .any => smith.valueRangeAtMost(BytesInt, 0, max_len),
        };
    }

    pub fn test_one(ctx: void, smith: *std.testing.Smith) !void {
        _ = ctx;
        const gpa = std.testing.allocator;
        var r: SkipRope = .empty;
        defer r.deinit(gpa);
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(gpa);

        while (!smith.eosWeightedSimple(31, 1)) {
            const do_insert = if (r.len == 0)
                true
            else
                smith.valueWeighted(bool, &.{
                    // Slight insert bias keeps state
                    // rich before dels cut it back.
                    std.testing.Smith.Weight.value(bool, false, 3),
                    std.testing.Smith.Weight.value(bool, true, 5),
                });
            if (do_insert) {
                const pos = pick_pos(smith, r.len);
                var buf: [256]u8 = undefined;
                const text = buf[0..smith.sliceWeighted(&buf, &.{
                    // Mostly short inserts for more ops per case,
                    // with a long tail.
                    std.testing.Smith.Weight.value(u32, 0, 1),
                    std.testing.Smith.Weight.rangeAtMost(u32, 1, 16, 12),
                    std.testing.Smith.Weight.rangeAtMost(u32, 17, 64, 4),
                    std.testing.Smith.Weight.rangeAtMost(u32, 65, 256, 1),
                }, &.{
                    std.testing.Smith.Weight.rangeAtMost(u8, 0, 255, 1),
                })];

                try r.insert(gpa, pos, text);
                try s.insertSlice(gpa, pos, text);
            } else {
                const pos = pick_pos(smith, r.len);
                const del_len = pick_del_len(smith, r.len - pos);

                r.delete(pos, del_len);
                s.replaceRangeAssumeCapacity(pos, del_len, "");
            }

            try r.expect_valid();
            try std.testing.expectFmt(s.items, "{f}", .{
                r.fmtString(0, r.len),
            });
        }
    }
};

test "fuzz-against-arraylist" {
    const log_ = @import("./log.zig");
    log_.testing_level.* = .warn;
    // log_.testing_scope_levels = &.{
    //     .{ .scope = .fuzz, .level = .info },
    //     .{ .scope = .rope, .level = .debug },
    //     .{ .scope = .rope_test, .level = .debug },
    // };

    // std.testing.random_seed = 0x8d31b0a1;

    try std.testing.fuzz({}, FuzzAgainstArrayList.test_one, .{});
    // try lame_fuzz({}, FuzzAgainstArrayList.test_one, .{});
}

fn lame_fuzz(
    ctx: anytype,
    comptime test_one: fn (
        ctx: @TypeOf(ctx),
        smith: *std.testing.Smith,
    ) anyerror!void,
    options: struct {
        corpus: []const []const u8 = &.{},
    },
) !void {
    const flog = @import("./log.zig").scoped(.fuzz);

    _ = options;
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = prng.random();

    for (0..50) |iter| {
        var input: [64 * (1 + 8 + 4 + 1024)]u8 = undefined;
        var w: std.Io.Writer = .fixed(&input);

        var len: usize = 0;
        const n_ops = random.intRangeAtMost(usize, 0, 64);
        for (0..n_ops) |_| {
            try w.writeByte(0);
            const do_insert = len == 0 or random.boolean();
            if (len != 0)
                try w.writeInt(u64, @intFromBool(do_insert), .little);

            if (do_insert) {
                try w.writeInt(
                    u64,
                    @intCast(random.intRangeAtMost(usize, 0, len)),
                    .little,
                );

                const text_len = random.intRangeAtMost(usize, 0, 1024);
                try w.writeInt(u32, @intCast(text_len), .little);
                random.bytes(input[w.end..][0..text_len]);
                w.end += text_len;
                len += text_len;
            } else {
                const beg = random.intRangeAtMost(usize, 0, len);
                const end = random.intRangeAtMost(usize, beg, len);
                try w.writeInt(u64, beg, .little);
                try w.writeInt(u64, end, .little);
                len -= end - beg;
            }
        }
        try w.writeByte(1);

        flog.info(@src(), "fuzzing", .{
            .input_len = w.end,
            .iter = iter,
        });

        var smith: std.testing.Smith = .{ .in = input[0..w.end] };
        test_one(ctx, &smith) catch |e| {
            return e;
        };
    }
}

const LazySubtree = struct {
    text: []const u8,
    /// Initial values:
    /// - `>=2` means:
    ///   - inline first ib layer
    ///   - next ib layer (ib down ptrs)
    ///   - ...
    ///   - next ib layer (db down ptrs)
    ///   - next db layer
    /// - `1` means:
    ///   - inline first ib layer (db down ptrs)
    ///   - next db layer
    /// - `0` means:
    ///   - inline first db layer
    ///
    height: HeightInt,
    prev_layer_begin: ?Begin = null,

    pub const Begin = struct {
        ib: Ib.PtrNum,
        rank: Ib.CapInt,
    };

    pub fn inline_first_ib_layer(
        this: *LazySubtree,
        r: *SkipRope,
        gpa: Allocator,
        begin_: Begin,
        begin_len_: Ib.CapInt,
        w_extra: u32,
    ) Allocator.Error!void {
        log.debug(@src(), "inline_first_ib_layer()", .{
            .this = this,
            .begin = begin_,
            .begin_len = begin_len_,
            .w_extra = w_extra,
        });
        assert(this.height >= 1);

        const w_full =
            std.math.pow(u32, Ib.capacity, this.height - 1) * Db.capacity;

        const begin: Begin, //.
        const begin_len = if (begin_.rank == Ib.capacity) x: {
            const ib_new = try r.ib_create(gpa);
            ib_new.ptr.* = .{};
            ib_new.ptr.next = begin_.ib.ptr.next;
            begin_.ib.ptr.next = ib_new.num;
            break :x .{ .{ .ib = ib_new, .rank = 0 }, 0 };
        } else .{ begin_, begin_len_ };

        // const inline_len = std.math.divCeil(BytesInt, this.text.len, w_full);
        // if (Ib.capacity - begin_len >= inline_len) {
        //     begin.ib.ptr.shift(begin_len, begin.rank, inline_len);

        //     var rest = this.text.len;
        //     var rank = begin.rank;
        //     var i = 0;
        //     while (rest > 0) {
        //         assert(rank < Ib.capacity);
        //         const w_new = @min(w_full, rest);
        //         begin.ib.ptr.w[rank] = w_new;
        //         rest -= w_new;
        //         rank += 1;
        //         i += 1;
        //     }
        //     assert(i == inline_len);

        //     assert(this.prev_layer_begin == null);
        //     this.prev_layer_begin = begin;
        //     this.height -= 1;

        //     return;
        // }

        const len_tail = begin_len - begin.rank;
        var tail_w: [Ib.capacity]u32 = @splat(0);
        var tail_d: [Ib.capacity]u32 = @splat(0);
        @memcpy(
            tail_w[0..len_tail],
            begin.ib.ptr.wide[begin.rank..][0..len_tail],
        );
        @memcpy(
            tail_d[0..len_tail],
            begin.ib.ptr.down[begin.rank..][0..len_tail],
        );

        var ib_cur = begin.ib;
        var rank = begin.rank;

        var w_rest = this.text.len;
        while (w_rest > 0) outer: {
            for (ib_cur.ptr.wide[rank..], rank..) |*w, i| {
                if (w_rest == 0) {
                    rank = @intCast(i);
                    break :outer;
                }
                const w_new = @min(w_full, w_rest);
                w.* = w_new;
                w_rest -= w_new;

                // shove w_extra into last down slot.
                // this down slot will potentially be a fat multi-block so
                // it can surpass w_full.
                if (w_rest == 0) w.* += w_extra;
            }
            if (w_rest == 0) {
                rank = Ib.capacity;
                break;
            }

            const ib_new = try r.ib_create(gpa);
            ib_new.ptr.* = .{};
            ib_new.ptr.next = ib_cur.ptr.next;
            ib_cur.ptr.next = ib_new.num;
            ib_cur = ib_new;
            rank = 0;
        }

        var tail_rest_w = tail_w[0..len_tail];
        var tail_rest_d = tail_d[0..len_tail];
        while (true) {
            assert(tail_rest_w.len == tail_rest_d.len);

            const cpy_len = @min(Ib.capacity - rank, tail_rest_w.len);
            @memcpy(
                ib_cur.ptr.wide[rank..][0..cpy_len],
                tail_rest_w[0..cpy_len],
            );
            @memcpy(
                ib_cur.ptr.down[rank..][0..cpy_len],
                tail_rest_d[0..cpy_len],
            );
            tail_rest_w = tail_rest_w[cpy_len..];
            tail_rest_d = tail_rest_d[cpy_len..];

            if (tail_rest_w.len == 0)
                break;

            const ib_new = try r.ib_create(gpa);
            ib_new.ptr.* = .{};
            ib_new.ptr.next = ib_cur.ptr.next;
            ib_cur.ptr.next = ib_new.num;
            ib_cur = ib_new;
            rank = 0;
        }

        assert(this.prev_layer_begin == null);
        this.prev_layer_begin = begin;
        this.height -= 1;
    }

    /// create one or more ibs with popylated widths but not down pointers
    ///
    /// also populate down pointers of prev layer
    pub fn promoted_next_ib_layer(
        this: *LazySubtree,
        r: *SkipRope,
        gpa: Allocator,
        w_extra: u32,
    ) Allocator.Error!struct {
        head: Ib.PtrNum,
        tail: Ib.PtrNum,
    } {
        log.debug(@src(), "promoted_next_ib_layer", .{
            .this = this,
            .w_extra = w_extra,
        });
        assert(this.height >= 1);
        // we are an ib height

        // full width of an Ib child at cur_height - 1.
        // NOTE: this child is a Db if cur_height == 1.
        // TODO: make this computed only once with pow and then divide at
        //       each next_layer call
        const w_full =
            std.math.pow(u32, Ib.capacity, this.height - 1) * Db.capacity;

        var parent_iter: Ib.PtrNum.Iter = this.prev_layer_begin.?.ib.iter();
        var parent_rank: Ib.CapInt = this.prev_layer_begin.?.rank;

        var ib_new_head: ?Ib.PtrNum = null;
        var ib_new_tail: ?Ib.PtrNum = null;
        var w_rest = this.text.len;

        while (w_rest > 0) {
            const ib_new = try r.ib_create(gpa);
            ib_new.ptr.* = .{};

            for (&ib_new.ptr.wide) |*w| {
                const w_new = @min(w_full, w_rest);
                w.* = w_new;
                w_rest -= w_new;
                if (w_rest == 0) {
                    // shove w_extra into last down slot.
                    // this down slot will potentially be a fat multi-block so
                    // it can surpass w_full.
                    w.* += w_extra;
                    break;
                }
            }

            const parent = parent_iter.peek(r).?;
            parent.ptr.down[parent_rank] = @intFromEnum(ib_new.num);

            // Advance parent slot iter
            parent_rank += 1;
            if (parent_rank == Ib.capacity) {
                _ = parent_iter.next(r);
                parent_rank = 0;
            }

            if (ib_new_head == null)
                ib_new_head = ib_new;
            if (ib_new_tail) |prev|
                prev.ptr.next = ib_new.num;
            ib_new_tail = ib_new;
        }

        this.height -= 1;
        this.prev_layer_begin = .{
            .ib = ib_new_head.?,
            .rank = 0,
        };
        return .{ .head = ib_new_head.?, .tail = ib_new_tail.? };
    }

    pub fn inline_first_db_layer(
        this: *LazySubtree,
        r: *SkipRope,
        gpa: Allocator,
        begin: struct {
            db: Db.PtrNum,
            rank: Db.CapInt,
        },
    ) Allocator.Error!void {
        log.debug(@src(), "inline_first_db_layer", .{
            .this = this,
            .begin = begin,
        });
        assert(this.prev_layer_begin == null);
        assert(this.height == 0);
        const tail_len = begin.db.ptr.len - begin.rank;
        var tail: [Db.capacity]u8 = undefined;
        @memcpy(
            tail[0..tail_len],
            begin.db.ptr.data[begin.rank..begin.db.ptr.len],
        );

        var cur = begin;

        // cur.write_extend(this.text);
        // cur.write_extend(tail[0..tail_len]);

        var rest = this.text;
        while (rest.len > 0) {
            const cpy_len = @min(Db.capacity - cur.rank, rest.len);
            @memcpy(cur.db.ptr.data[cur.rank..][0..cpy_len], rest[0..cpy_len]);
            assert(cur.rank + cpy_len <= Db.capacity);
            cur.db.ptr.len = cur.rank + cpy_len;
            rest = rest[cpy_len..];
            cur.rank += cpy_len;
            log.debug(@src(), "wrote to db", .{ .cur = cur });

            if (rest.len > 0) {
                const db_new = try r.db_create(gpa);
                db_new.ptr.* = .{};
                db_new.ptr.next = cur.db.ptr.next;
                cur.db.ptr.next = db_new.num;
                cur = .{ .db = db_new, .rank = 0 };
            }
        }

        rest = tail[0..tail_len];
        while (rest.len > 0) {
            const cpy_len = @min(Db.capacity - cur.rank, rest.len);
            @memcpy(cur.db.ptr.data[cur.rank..][0..cpy_len], rest[0..cpy_len]);
            assert(cur.rank + cpy_len <= Db.capacity);
            cur.db.ptr.len = cur.rank + cpy_len;
            rest = rest[cpy_len..];
            log.debug(@src(), "wrote to db", .{ .cur = cur });

            if (rest.len > 0) {
                const db_new = try r.db_create(gpa);
                db_new.ptr.* = .{};
                db_new.ptr.next = cur.db.ptr.next;
                cur.db.ptr.next = db_new.num;
                cur = .{ .db = db_new, .rank = 0 };
            }
        }
    }

    /// create one db (or more if overflow children)
    /// with popylated widths but not down pointers
    ///
    /// also populate down pointers of prev layer
    pub fn promoted_next_db_layer(
        this: *LazySubtree,
        r: *SkipRope,
        gpa: Allocator,
    ) Allocator.Error!struct {
        head: Db.PtrNum,
        tail: Db.PtrNum,
    } {
        log.debug(@src(), "promoted_next_db_layer", .{ .this = this });
        assert(this.height == 0);
        // we are an bb height
        const w_full = Db.capacity;

        var parent_iter: Ib.PtrNum.Iter = this.prev_layer_begin.?.ib.iter();
        var parent_rank: Ib.CapInt = this.prev_layer_begin.?.rank;

        var db_new_head: ?Db.PtrNum = null;
        var db_new_tail: ?Db.PtrNum = null;

        var rest = this.text;
        while (rest.len > 0) {
            const db_new = try r.db_create(gpa);
            db_new.ptr.* = .{};

            const w_new = @min(w_full, rest.len);
            db_new.ptr.len = w_new;
            @memcpy(db_new.ptr.data[0..w_new], rest[0..w_new]);
            rest = rest[w_new..];

            const parent = parent_iter.peek(r).?;
            parent.ptr.down[parent_rank] = @intFromEnum(db_new.num);
            parent_rank += 1;
            if (parent_rank == Ib.capacity) {
                _ = parent_iter.next(r);
                parent_rank = 0;
            }

            if (db_new_head == null)
                db_new_head = db_new;
            if (db_new_tail) |prev|
                prev.ptr.next = db_new.num;
            db_new_tail = db_new;
        }
        return .{ .head = db_new_head.?, .tail = db_new_tail.? };
    }
};

const FmtStringArgs = struct {
    r: *SkipRope,
    ofs: BytesInt,
    len: BytesInt,
};
pub fn fmtString(r: *SkipRope, ofs: BytesInt, len: BytesInt) std.fmt.Alt(
    FmtStringArgs,
    formatString,
) {
    return .{ .data = .{ .r = r, .ofs = ofs, .len = len } };
}

/// use via `Rope.fmtString()`
fn formatString(
    args: FmtStringArgs,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const r = args.r;

    assert(args.ofs <= r.len);
    assert(args.ofs + args.len <= r.len);
    if (args.len == 0) return;

    var cur = r.read_cursor_at(args.ofs);
    assert(args.len <= cur.rest);
    cur.rest = args.len;
    while (cur.next_chunk(r)) |chunk| {
        try w.writeAll(chunk);
    }
}

fn augment_height(
    rand: std.Random,
    h_min: HeightInt,
    h_max: HeightInt,
) HeightInt {
    var h = h_min;
    while (h < h_max) {
        // TODO: consider p = 1/cB for some experimentally chosen constant c.
        // p = 1 / B
        if (h == 0) {
            if (rand.uintLessThan(
                std.math.IntFittingRange(0, Db.capacity - 1),
                Db.capacity,
            ) == 0) {
                h += 1;
                continue;
            }
        } else {
            if (rand.uintLessThan(
                std.math.IntFittingRange(0, Ib.capacity - 1),
                Ib.capacity,
            ) == 0) {
                h += 1;
                continue;
            }
        }
        break;
    }
    assert(h >= h_min);
    assert(h <= h_max);
    return h;
}

fn expect_valid(r: *SkipRope) !void {
    if (r.root == .null) {
        try std.testing.expectEqual(r.ib_height, 0);
        try std.testing.expectEqual(r.len, 0);
        return;
    }

    const root: Ib.PtrNum = .{ .num = r.root, .ptr = r.ib_at(r.root) };
    try expect_valid_ib(r, r.len, true, root, .null, r.ib_height);

    // var c: FindCursor = .{
    //     .b = .{ .ib = root },
    //     .b_ofs = 0,
    //     .b_is_header = true,
    // };

    // for (0..r.ib_height) |_| {
    //     try std.testing.expect(c.ib_find_ofs(r, 0));
    //     try std.testing.expect(c.b_is_header);

    //     var iter = c.b.ib.iter();
    //     var is_header = true;
    //     var total_w: BytesInt = 0;
    //     while (iter.next(r)) |ib| {
    //         var ib_w: BytesInt = 0;
    //         for (0.., ib.ptr.wide, ib.ptr.down) |i, w, d| {
    //             if (d == 0) break;
    //             if (!(is_header and i == 0))
    //                 try std.testing.expect(w > 0);
    //             ib_w += w;
    //         }
    //         total_w += ib_w;
    //         is_header = false;
    //     }
    //     try std.testing.expectEqual(r.len, total_w);

    //     c.ib_descend_as_ib(r);
    //     try std.testing.expect(c.b_is_header);
    // }
    // try std.testing.expect(c.ib_find_ofs(r, 0));
    // try std.testing.expect(c.b_is_header);
    // {
    //     var iter = c.b.ib.iter();
    //     var is_header = true;
    //     var total_w: BytesInt = 0;
    //     while (iter.next(r)) |ib| {
    //         var ib_w: BytesInt = 0;
    //         for (0.., ib.ptr.wide, ib.ptr.down) |i, w, d| {
    //             if (d == 0) break;
    //             if (!(is_header and i == 0))
    //                 try std.testing.expect(w > 0);
    //             ib_w += w;
    //         }
    //         total_w += ib_w;
    //         is_header = false;
    //     }
    //     try std.testing.expectEqual(r.len, total_w);
    // }
    // c.ib_descend_as_db(r);
    // try std.testing.expect(c.b_is_header);

    // try std.testing.expect(c.db_find_ofs(r, 0));
    // try std.testing.expect(c.b_is_header);
}

fn expect_valid_ib(
    r: *SkipRope,
    expected_w: BytesInt,
    is_header_: bool,
    ib_cur: Ib.PtrNum,
    ib_cur_end: Ib.Num,
    ib_height: HeightInt,
) !void {
    log.debug(@src(), "expect_valid_ib", .{
        .expected_w = expected_w,
        .is_header_ = is_header_,
        .ib_cur = ib_cur,
        .ib_cur_end = ib_cur_end,
        .ib_height = ib_height,
    });

    var total_w: BytesInt = 0;
    var iter = ib_cur.iter();
    var is_header = is_header_;
    while (iter.next(r)) |ib| {
        for (0.., ib.ptr.wide, ib.ptr.down) |i, w, d| {
            if (d == 0) break;

            const next_d = if (i < Ib.capacity - 1 and ib.ptr.down[i + 1] > 0)
                ib.ptr.down[i + 1]
            else if (iter.peek(r)) |next|
                next.ptr.down[0]
            else
                0;

            if (!is_header) try std.testing.expect(w > 0);
            total_w += w;
            if (ib_height > 0) {
                try r.expect_valid_ib(w, is_header, .{
                    .num = @enumFromInt(d),
                    .ptr = r.ib_at(@enumFromInt(d)),
                }, @enumFromInt(next_d), ib_height - 1);
            } else {
                try r.expect_valid_db(w, is_header, .{
                    .num = @enumFromInt(d),
                    .ptr = r.db_at(@enumFromInt(d)),
                }, @enumFromInt(next_d));
            }

            is_header = false;
        }

        if (ib.ptr.next == ib_cur_end) break;
    }
    try std.testing.expectEqual(
        ib_cur_end,
        if (iter.next(r)) |n| n.num else .null,
    );
    try std.testing.expectEqual(expected_w, total_w);
}

fn expect_valid_db(
    r: *SkipRope,
    expected_w: BytesInt,
    is_header_: bool,
    db_cur: Db.PtrNum,
    db_cur_end: Db.Num,
) !void {
    log.debug(@src(), "expect_valid_db", .{
        .expected_w = expected_w,
        .is_header_ = is_header_,
        // .db_cur = db_cur,
        .db_cur_num = db_cur.num,
        .db_cur_len = db_cur.ptr.len,
        .db_cur_end = db_cur_end,
    });

    var total_w: BytesInt = 0;
    var iter = db_cur.iter();
    var is_header = is_header_;
    while (iter.next(r)) |db| {
        if (!is_header) try std.testing.expect(db.ptr.len > 0);
        total_w += db.ptr.len;
        is_header = false;
        if (db.ptr.next == db_cur_end) break;
    }
    log.debug(@src(), "last next", .{ .next = iter.peek(r) });
    try std.testing.expectEqual(
        db_cur_end,
        if (iter.next(r)) |n| n.num else .null,
    );
    try std.testing.expectEqual(expected_w, total_w);
}

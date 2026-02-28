//! B-skiplist with the following attributes:
//! - K = indx of byte
//! - V = byte
//! - Tracking subtree widths instead of leader keys.
//! - Dense. no holes between bytes, so indices are always implied from widths.
//!
//! B-skiplist repr:
//! ```
//! L2: [-inf 4]
//! L1: [-inf 2] [4 8]
//! L0: [-inf 0 1] [2 3] [4 5 6 7] [8 9]
//!
//! L2: [-inf -1 4]
//! L1: [-inf] [-1 2] [4 8]
//! L0: [-inf] [-1 0 1] [2 3] [4 5 6 7] [8 9]
//! ````
//! Skiprope repr:
//! ```
//! L2: [4 6]
//! L1: [2 2] [4 2]
//! L0: [1 1] [1 1] [1 1 1 1] [1 1]
//!
//! L2: [0 5 6]
//! L1: [0] [3 2] [4 2]
//! L0: [] [1 1 1] [1 1] [1 1 1 1] [1 1]
//! ````
//!
//! - `LN >= L1`: Index Layer (Ib)
//! - `L0`      : Data Layer (Db)
//!
//! Note that the `-inf` element doesn't actually have a rank in L0.
//! This turns out to be easier to special case for our rope usecase.
//!
//! We still follow the same algorithms in terms of block leaders despite this
//! physical repr.
//!
//! For the empty case:
//! ```
//! L2: [-inf]               L2: [0]
//! L1: [-inf]    Becomes:   L1: [0]
//! L0: [-inf]               L0: [0]
//! ```
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
/// ib layer count - 1; total/ib+db layer count - 2
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

    /// How wide the down subtree is. (# of full data bytes)
    ///
    /// The first slot in each layer may be 0-wide with a populated down
    /// pointer as it represents the header `-inf` key of the skiplist.
    ///
    /// All other slots must be > 0 or they signal the end of the block.
    wide: [capacity]u32 align(config.dcache_line_bytes) = @splat(0),
    /// Next Ib in the same level
    next: Num = .null,
    /// Down pointer either to next Ib level or Db leaf
    ///
    /// 0 down num means null,
    /// so it is reliable to use this for iteration end.
    /// (except when building a subtree lazily)
    down: [capacity]u32 align(config.dcache_line_bytes) = @splat(0),
    pad: u32 = undefined,

    const _ = assert(@sizeOf(Ib) == 4 * config.dcache_line_bytes);

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

                const next_num = it.prev.?.ptr.next;
                if (next_num == .null) return null;

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

        /// Find down ptr of absolute ofs within this ib layer
        pub fn find(
            first: PtrNum,
            r: *SkipRope,
            first_ofs: BytesInt,
            first_is_header: bool,
            ofs: BytesInt,
        ) ?struct {
            ib: PtrNum,
            ib_ofs: BytesInt,
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
                // Only header Ib can have 0-width
                assert(it.peek(r).?.ptr.wide[0] != 0);
            }

            while (it.next(r)) |ib| {
                var ib_w: u32 = 0;
                for (0.., ib.ptr.wide, ib.ptr.down) |i, w, d| {
                    if (d == 0) break; // end of ib
                    if (ofs <= ib_ofs + ib_w + w)
                        return .{
                            .ib = ib,
                            .ib_ofs = ib_ofs,
                            .rank = @intCast(i),
                            .rank_ofs = ib_ofs + ib_w,
                        };
                    ib_w += w;
                }
                ib_ofs += ib_w;
            }
            return null;
        }

        /// `ib_cur` becomes `at` long after split.
        pub fn split(
            ib_cur: PtrNum,
            r: *SkipRope,
            gpa: Allocator,
            comptime at: Ib.CapInt,
        ) Allocator.Error!PtrNum {
            const ib_new = try r.ib_create(gpa);
            ib_new.ptr.* = .{};
            ib_new.ptr.next = ib_cur.ptr.next;
            ib_cur.ptr.next = ib_new.num;
            const len_1 = at;
            const len_2 = Ib.capacity - at;
            ib_new.ptr.wide[0..len_2].* = ib_cur.ptr.wide[len_1..].*;
            ib_new.ptr.down[0..len_2].* = ib_cur.ptr.down[len_1..].*;
            ib_cur.ptr.wide[len_1..].* = @splat(0);
            ib_cur.ptr.down[len_1..].* = @splat(0);
            return ib_new;
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

    pub fn insert(ib: *Ib, ib_len: CapInt, at: CapInt, item: struct {
        w: u32,
        d: u32,
    }) void {
        var wide_list: std.ArrayList(u32) = .initBuffer(&ib.ptr.wide);
        var down_list: std.ArrayList(u32) = .initBuffer(&ib.ptr.down);
        wide_list.items.len = ib_len;
        down_list.items.len = ib_len;
        wide_list.insertAssumeCapacity(at, item.w);
        down_list.insertAssumeCapacity(at, item.d);
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

                const next_num = it.prev.?.ptr.next;
                if (next_num == .null) return null;

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

        pub const Found = struct {
            db: PtrNum,
            db_ofs: BytesInt,
            rank: CapInt,
            rank_ofs: BytesInt,
        };
        /// Find down ptr of absolute ofs within this db layer
        pub fn find(
            first: PtrNum,
            r: *SkipRope,
            first_ofs: BytesInt,
            first_is_header: bool,
            ofs: BytesInt,
        ) ?Found {
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

        /// `db_cur` becomes `at` long after split.
        pub fn split(
            db_cur: PtrNum,
            r: *SkipRope,
            gpa: Allocator,
            comptime at: CapInt,
        ) Allocator.Error!PtrNum {
            const db_new = try r.db_create(gpa);
            db_new.ptr.* = .{};
            db_new.ptr.next = db_cur.ptr.next;
            db_cur.ptr.next = db_new.num;
            assert(at <= Db.capacity);
            const len_1 = at;
            const len_2 = Db.capacity - at;
            db_new.ptr.data[0..len_2].* = db_cur.ptr.data[len_1..].*;
            db_cur.ptr.data[len_1..].* = undefined;
            db_new.ptr.len = len_2;
            db_cur.ptr.len = len_1;
            return db_new;
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

    // pub fn insert(db: *Db, db_len: CapInt, at: CapInt, item: struct {
    //     w: u32,
    //     d: u32,
    // }) void {}
};

const FindCursor = struct {
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

    pub fn ib_find_ofs(c: *FindCursor, r: *SkipRope, ofs: BytesInt) bool {
        const found = c.b.ib.find(r, c.b_ofs, c.b_is_header, ofs) orelse
            return false;
        if (c.b.ib.num != found.ib.num) c.b_is_header = false;
        c.b = .{ .ib = found.ib };
        c.b_ofs = found.ib_ofs;
        c.down = .{
            .rank = .{ .in_ib = found.rank },
            .rank_ofs = found.rank_ofs,
        };
        return true;
    }
    pub fn ib_descend_as_ib(c: *FindCursor, r: *SkipRope) void {
        c.b_is_header = c.b_is_header and c.down.rank.in_ib == 0;
        const ib: Ib.PtrNum = .{
            .num = @enumFromInt(c.b.ib.ptr.down[c.down.rank.in_ib]),
            .ptr = r.ib_at(@enumFromInt(c.b.ib.ptr.down[c.down.rank.in_ib])),
        };
        c.b = .{ .ib = ib };
        c.b_ofs = c.down.rank_ofs;
    }
    pub fn ib_descend_as_db(c: *FindCursor, r: *SkipRope) void {
        c.b_is_header = c.b_is_header and c.down.rank.in_ib == 0;
        const db: Db.PtrNum = .{
            .num = @enumFromInt(c.b.ib.ptr.down[c.down.rank.in_ib]),
            .ptr = r.db_at(@enumFromInt(c.b.ib.ptr.down[c.down.rank.in_ib])),
        };
        c.b = .{ .db = db };
        c.b_ofs = c.down.rank_ofs;
    }
    pub fn db_find_ofs(c: *FindCursor, r: *SkipRope, ofs: BytesInt) bool {
        const found = c.b.db.find(r, c.b_ofs, c.b_is_header, ofs) orelse
            return false;
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
        c: *FindCursor,
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

pub fn jsonStringify(r: *const SkipRope, jw: anytype) !void {
    try jw.write(.{
        .root = r.root,
        .len = r.len,
        .ib_height = r.ib_height,
    });
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
        .pos = pos,
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

    if (h_ins > h_tree) {
        // Tree doesn't grow in height very often. Not currently optimizing for
        // this path.
        @branchHint(.unlikely);

        var root_w: u32 = 0;
        for (root.ptr.wide) |w| root_w += w;
        // root only has next if it is at max_height,
        // but we are groing the height here so this is not the case.
        assert(root.ptr.next == .null);

        for (0..(h_ins - h_tree)) |_| {
            const ib_new = try r.ib_create(gpa);
            ib_new.ptr.* = .{};
            ib_new.ptr.wide[0] = root_w;
            ib_new.ptr.down[0] = @intFromEnum(root.num);

            h_tree += 1;
            root = ib_new;
        }
        assert(h_ins == h_tree);
    }

    assert(h_ins <= h_tree);

    var cur: FindCursor = .{
        .b = .{ .ib = root },
        .b_ofs = 0,
        .b_is_header = true,
    };

    // top-down from tree top to bottom ib layer
    var h_cur = h_tree - 1;
    while (h_cur > 0) : (h_cur -= 1) {
        if (!cur.ib_find_ofs(r, pos))
            std.debug.panic("insertion point out of bounds", .{});

        const rank = cur.down.rank.in_ib;
        if (h_cur == h_ins) {
            const ib_cur_len: Ib.CapInt = if (rank < Ib.capacity - 1)
                (for (rank + 1.., cur.b.ib.ptr.down[rank + 1 ..]) |i, d| {
                    if (d == 0) break @intCast(i); // end of ib
                } else Ib.capacity)
            else
                rank + 1;

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
                const ib_cur_len: Ib.CapInt =
                    for (rank + 1.., cur.b.ib.ptr.down[rank + 1 ..]) |i, d| {
                        if (d == 0) break @intCast(i); // end of ib
                    } else Ib.capacity;

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
    log_.testing_scope_levels = &.{
        .{ .scope = .fuzz, .level = .info },
        .{ .scope = .rope, .level = .debug },
        .{ .scope = .rope_test, .level = .debug },
    };

    var r: SkipRope = .empty;
    defer r.deinit(std.testing.allocator);

    try r.insert(std.testing.allocator, 0, "Hello, world!");
    try r.insert(std.testing.allocator, 1, "Hello, world!");
    try r.insert(std.testing.allocator, 2, "Hello, world!");
    try r.insert(std.testing.allocator, 3, "Hello, world!");
    try r.insert(std.testing.allocator, 3, "Hello, world!");
    try r.insert(std.testing.allocator, 3, "Hello, world!");
    try r.insert(std.testing.allocator, 3, "Hello, world!");
    try r.insert(std.testing.allocator, 3, "Hello, world!");
    try r.insert(std.testing.allocator, 3, "Hello, world!");
    try r.insert(std.testing.allocator, 3, "Hello, world!");
    try r.insert(std.testing.allocator, 3, "Hello, world!");
    try r.insert(std.testing.allocator, 0, "Hello, world!");
    try r.insert(std.testing.allocator, 0, "Hello, world!");
    try r.insert(std.testing.allocator, 0, "Hello, world!");
    try r.insert(std.testing.allocator, 0, "Hello, world!");
    std.debug.print("{f}", .{r.fmtString(0, r.len)});
    log.err(@src(), "testing...", .{ .r = r });
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
        begin: Begin,
        begin_len: Ib.CapInt,
        w_extra: u32,
    ) Allocator.Error!void {
        log.debug(@src(), "inline_first_ib_layer()", .{
            .this = this,
            .begin = begin,
            .begin_len = begin_len,
            .w_extra = w_extra,
        });
        assert(this.height >= 1);

        const w_full =
            std.math.pow(u32, Ib.capacity, this.height - 1) * Db.capacity;

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

        //     return;
        // }

        const len_tail = begin_len - begin.rank;
        var tail_w: [Ib.capacity]u32 = @splat(0);
        var tail_d: [Ib.capacity]u32 = @splat(0);
        @memcpy(tail_w[0..len_tail], begin.ib.ptr.wide[begin.rank..]);
        @memcpy(tail_d[0..len_tail], begin.ib.ptr.down[begin.rank..]);

        var ib_cur = begin.ib;
        var rank = begin.rank;

        var w_rest = this.text.len + w_extra;
        while (w_rest > 0) outer: {
            for (ib_cur.ptr.wide[rank..], rank..) |*w, i| {
                if (w_rest == 0) {
                    rank = @intCast(i);
                    break :outer;
                }
                const w_new = @min(w_full, w_rest);
                w.* = w_new;
                w_rest -= w_new;
            }
            if (w_rest == 0)
                break;

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
        var rest = this.text.len + w_extra;

        while (rest > 0) {
            const ib_new = try r.ib_create(gpa);
            ib_new.ptr.* = .{};

            for (&ib_new.ptr.wide) |*w| {
                if (rest == 0) break;
                const w_new = @min(w_full, rest);
                w.* = w_new;
                rest -= w_new;
            }

            const parent = parent_iter.peek(r).?;
            parent.ptr.down[parent_rank] = @intFromEnum(ib_new.num);
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
            if (parent_rank == Db.capacity) {
                _ = parent_iter.next(r);
                parent_rank = 0;
            }

            if (db_new_head == null)
                db_new_head = db_new;
            if (db_new_tail) |prev|
                prev.ptr.next = db_new.num;
            db_new_tail = db_new;
        }
        this.height -= 1;
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
    assert(args.ofs + args.len <= args.len);
    if (args.len == 0) return;

    const root: Ib.PtrNum = .{ .num = r.root, .ptr = r.ib_at(r.root) };
    var find_cur: FindCursor = .{
        .b = .{ .ib = root },
        .b_ofs = 0,
        .b_is_header = true,
    };
    if (!find_cur.ib_find_ofs_leaf(r, r.ib_height, args.ofs))
        std.debug.panic("offset out of bounds", .{});

    assert(find_cur.down.rank_ofs == args.ofs);
    var rank_cur = find_cur.down.rank.in_db;
    var rest = args.len;
    var iter = find_cur.b.db.iter();
    while (rest > 0) {
        const db = iter.peek(r).?;
        try w.writeAll(db.ptr.data[rank_cur..db.ptr.len]);
        rest -= db.ptr.len - rank_cur;
        if (rest > 0) {
            rank_cur = 0;
            _ = iter.next(r);
        }
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
            if (rand.uintAtMost(
                std.math.IntFittingRange(0, Db.capacity),
                Db.capacity,
            ) == 0) {
                h += 1;
                continue;
            }
        } else {
            if (rand.uintAtMost(
                std.math.IntFittingRange(0, Ib.capacity),
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

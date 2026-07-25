//! B-skiplist for ranges.
//!
//! K = range start byte, V = one or more ranges at same start. Sparse: only
//! distinct starts are leaders. Same-start ranges stay adjacent in the leaf
//! stream.
//!
//! Logical skiplist, grouped by physical blocks:
//! ```
//! L2: [-inf             40:e] +inf
//! L1: [-inf  10:{a,b}] [20:d] [40:e] +inf
//! L0: [-inf] [10:a  10:b  15:c] [20:d] [40:e] +inf
//! ```
//!
//! Physical gap/reach slots for same example:
//! ```
//! L2: [-inf:40,max(a,b,c,d)  0,max(e)]
//! L1: [-inf:10,0  10,max(a,b,c)] [20,max(d)] [0,max(e)]
//! L0: [-inf:10] [0,a  5,b  5,c] [20,d] [0,e]
//! ```
//!
//! Read:
//! - `-inf:n,r` is the virtual header `Ib` slot for the entered first block.
//! - `-inf:n` is the virtual header `Rb` cell for the entered first block.
//! - `Ib` slot is `gap,reach`; `Rb` cell is `gap,range`.
//! - Header `Ib` with `gap == 0` and non-null `down` owns the rest of its view.
//! - Header `Ib` reach is 0 when its `down` is null; it is not a real leader.
//! - `reach` stores distance from slot start to max range end under `down[i]`.
//! - `max(x,y)` names the range whose end gives that max.
//!
//! Logical model:
//! - A distinct start's height is the highest layer where that start is a
//!   leader.
//! - An `Ib` slot is owned by the first start covered by its `down` subtree.
//! - `Ib.gap[i]` is distance to the next distinct start at that layer.
//! - `Ib.reach[i]` is distance from slot start to max range end under
//!   `down[i]`.
//! - `Rb` is the leaf layer: one range per cell in start order.
//! - Same-start ranges are adjacent `Rb` cells with `gap == 0`.
//! - Same-start range order is unspecified.
//!
//! Header:
//! - The first block of each layer exposes a virtual `-inf` leader.
//! - Whether slot `0` is header is walk state (`first_is_header`).
//!
//! Physical model:
//! - Each physical layer is a doubly linked list of packed blocks.
//! - Bounded views may start and end within that physical chain.
//! - `Ib` packs upper-layer gaps, reach, and down pointers.
//! - `Rb` separates hot start-walk fields from range lengths and payloads.
//! - A child `down` pointer owns a bounded child view.
//! - ID lookup caches absolute start and `Rb` number; the tree is canonical.
//! - Leader height is random/logical.
//! - Full blocks allocate same-layer siblings.
//!
//! Allocation-failure atomicity is out of scope for now. Several insert paths
//! mutate reachable blocks before later `try` allocs; OOM may leave the tree
//! half-committed. Callers must treat insert OOM as fatal until this changes.
const std = @import("std");
const assert = std.debug.assert;
const log = @import("./log.zig").scoped(.range);
const Allocator = std.mem.Allocator;
const RangedInt = @import("./ranged_int.zig").RangedInt;
const SegmentedPool = @import("./segmented_pool.zig").SegmentedPool;

const SkipRange = @This();

test {
    std.testing.refAllDecls(@This());
}

// Largest live range count whose worst-case block numbers fit in u32.
//
// The insertion-only bound uses the 8/8 top Ib spill. Delete does not preserve
// that fill. It frees a block only when the block becomes empty. Churn can
// leave one slot in each block. Therefore every Ib layer can need N + 1 blocks
// for N ranges. We budget that case. The lower limit keeps delete free of
// block borrow and merge.
const max_ranges = 613_566_755;
const RangeInt = std.math.IntFittingRange(0, max_ranges);

/// Identifies one range until removal. IDs are never reused.
pub const RangeId = enum(u32) { null = 0, _ };
pub const InsertError = Allocator.Error || error{RangeIdExhausted};
const rb_capacity = 41;
const ib_capacity = 15;

const max_rb_count: u32 = max_ranges + 1;
const max_height: u32 = std.math.log_int(u32, ib_capacity, max_rb_count);
const ib_spill_fill = (ib_capacity + 1) / 2;
const max_ib_count: u32 = max_height * max_rb_count;
const IbPoolIndex = RangedInt(.skiprange_ib_num, 0, max_ib_count - 1);
const RbPoolIndex = RangedInt(.skiprange_rb_num, 0, max_rb_count - 1);

comptime {
    // Re-derive the literal. One more range must exceed the Ib number space.
    assert(max_ranges == std.math.maxInt(u32) / max_height - 1);
    const next_rb_count: u64 = max_rb_count + 1;
    const next_height = std.math.log_int(u64, ib_capacity, next_rb_count);
    const next_ib_count = next_height * next_rb_count;
    assert(next_ib_count > std.math.maxInt(u32));
}

// Keep same byte-scale bound as SkipRope's leaf-addressable space.
const max_bytes = (std.math.maxInt(u32) - 1) * 127;
const BytesInt = std.math.IntFittingRange(0, max_bytes);

const config = .{
    // Locality model and layout unit, benchmarked at 64 bytes. Hardware may
    // differ.
    .dcache_line_bytes = 64,
};

pub const RangeFlags = packed struct(u8) {
    start_right: bool = false,
    end_right: bool = false,
    _pad: u6 = 0,
};

pub const Range = struct {
    start: BytesInt,
    end: BytesInt,
    payload: u32,
    flags: RangeFlags = .{},
};

pub const empty: SkipRange = .{
    .rng = .init(0),
    .root = .null,
    .ib_height = 0,
    .range_count = 0,
    .next_id = 1,
    .id_index = .empty,
    .ibs = .empty,
    .rbs = .empty,
};

rng: std.Random.DefaultPrng,
root: Ib.Num,
/// ib layer count - 1; total ib+rb layer count - 2
ib_height: HeightInt,
range_count: RangeInt,
next_id: u64,
id_index: std.AutoHashMapUnmanaged(RangeId, IdIndexEntry),
ibs: SegmentedPool(
    Ib,
    IbPoolIndex,
    .coerce(16),
),
rbs: SegmentedPool(
    Rb,
    RbPoolIndex,
    .coerce(16),
),

const HeightInt = std.math.IntFittingRange(0, max_height);

const Rb = extern struct {
    const capacity = rb_capacity;
    const CapInt = std.math.IntFittingRange(0, capacity);

    /// Start walk stays in the first eight cache lines. Only an entered first
    /// block with `first_is_header` treats rank `0` as the virtual `-inf`
    /// header.
    gap: [capacity]Gap align(config.dcache_line_bytes),
    next: u32,
    /// Same-layer predecessor; may cross a bounded-view boundary.
    prev: u32,
    id: [capacity]u32,
    _pad_0: [12]u8,
    range_len: [capacity]Len align(config.dcache_line_bytes),
    payload: [capacity]u32,
    _pad_1: [20]u8,

    comptime {
        assert(@alignOf(Rb) == config.dcache_line_bytes);
        assert(@sizeOf(Rb) == 16 * config.dcache_line_bytes);
        assert(@offsetOf(Rb, "gap") % config.dcache_line_bytes == 0);
        assert(@offsetOf(Rb, "range_len") % config.dcache_line_bytes == 0);
    }

    const Gap = packed struct(u64) {
        /// Real cell: gap to next distinct start; `0` keeps current start.
        /// header cell: gap to first real start in the view.
        value: BytesInt = 0,
        start_right: bool = false,
        _pad: u24 = 0,
    };

    /// Range length plus end boundary bit.
    const Len = packed struct(u64) {
        value: BytesInt = 0,
        end_right: bool = false,
        _pad: u24 = 0,
    };

    const Num = enum(std.math.IntFittingRange(0, max_rb_count)) { null = 0, _ };
    const PtrNum = struct {
        ptr: *Rb,
        num: Num,

        pub fn jsonStringify(rb: *const PtrNum, jw: anytype) !void {
            try jw.write(@intFromEnum(rb.num));
        }

        const Iter = struct {
            rb: PtrNum,
            start_rel: BytesInt,
            first_is_header: bool,
            rank: CapInt,
            started: bool,

            const Item = struct {
                rb: PtrNum,
                start_rel: BytesInt,
                gap: BytesInt,
                len: Len,
                id: RangeId,
                payload: u32,
                flags: RangeFlags,
            };

            fn next(it: *Iter, sr: *SkipRange) ?Item {
                while (true) {
                    if (!it.started) {
                        it.started = true;
                        if (it.first_is_header) {
                            it.start_rel = it.rb.ptr.gap[0].value;
                            it.rank = 1;
                        } else {
                            it.rank = 0;
                        }
                    } else {
                        const gap = it.rb.ptr.gap[it.rank].value;
                        it.start_rel += gap;
                        it.rank += 1;
                    }

                    if (it.rank < capacity and
                        it.rb.ptr.occupied(it.first_is_header, it.rank))
                    {
                        const gap = it.rb.ptr.gap[it.rank];
                        const range_len = it.rb.ptr.range_len[it.rank];
                        return .{
                            .rb = it.rb,
                            .start_rel = it.start_rel,
                            .gap = gap.value,
                            .len = range_len,
                            .id = @enumFromInt(it.rb.ptr.id[it.rank]),
                            .payload = it.rb.ptr.payload[it.rank],
                            .flags = .{
                                .start_right = gap.start_right,
                                .end_right = range_len.end_right,
                            },
                        };
                    }
                    if (!it.next_block(sr)) return null;
                }
            }

            fn next_block(it: *Iter, sr: *SkipRange) bool {
                const next_num: Rb.Num = @enumFromInt(it.rb.ptr.next);
                if (next_num == .null) return false;
                it.rb = .{
                    .num = next_num,
                    .ptr = sr.rb_at(next_num),
                };
                it.first_is_header = false;
                it.started = false;
                return true;
            }
        };

        fn iter(head: PtrNum, first_is_header: bool) Iter {
            return .{
                .rb = head,
                .start_rel = 0,
                .first_is_header = first_is_header,
                .rank = 0,
                .started = false,
            };
        }
    };

    const Find = struct {
        rb: PtrNum,
        first_is_header: bool,
        rank: CapInt,
        /// predecessor start relative to current view; header anchor is 0
        start_rel: BytesInt,
        /// distance from predecessor to next distinct leader
        gap: BytesInt,
    };

    const View = struct {
        /// First block of this bounded layer view.
        head: PtrNum,
        /// Whether `head` exposes the virtual `-inf` slot at rank 0.
        first_is_header: bool,
        /// Exclusive end offset for this bounded view, relative to its
        /// caller-held base.
        end_rel: ?BytesInt,

        const Iter = struct {
            raw: PtrNum.Iter,
            end_rel: ?BytesInt,

            fn next(it: *Iter, sr: *SkipRange) ?PtrNum.Iter.Item {
                const item = it.raw.next(sr) orelse return null;
                if (it.end_rel) |end| {
                    if (item.start_rel >= end) return null;
                }
                return item;
            }
        };

        fn iter(view: View) Iter {
            return .{
                .raw = view.head.iter(view.first_is_header),
                .end_rel = view.end_rel,
            };
        }

        fn past_end(view: View, start_rel: BytesInt) bool {
            if (view.end_rel) |end| return start_rel >= end;
            return false;
        }
    };

    fn occupied(rb: *const Rb, first_is_header: bool, rank: CapInt) bool {
        assert(rank < capacity);
        return (first_is_header and rank == 0) or rb.id[rank] != 0;
    }

    fn len(rb: *const Rb, first_is_header: bool) CapInt {
        for (0..capacity) |i| {
            const idx: CapInt = @intCast(i);
            if (!rb.occupied(first_is_header, idx)) return idx;
        }
        return capacity;
    }

    fn set_end(rb: *Rb, end_len: CapInt) void {
        if (end_len < capacity) rb.id[end_len] = 0;
    }

    fn set(
        rb: *Rb,
        rank: CapInt,
        range: Range,
        id: RangeId,
        gap: BytesInt,
    ) void {
        rb.gap[rank] = .{
            .value = gap,
            .start_right = range.flags.start_right,
        };
        rb.range_len[rank] = .{
            .value = range.end - range.start,
            .end_right = range.flags.end_right,
        };
        rb.id[rank] = @intFromEnum(id);
        rb.payload[rank] = range.payload;
    }

    fn set_header(rb: *Rb, gap: BytesInt) void {
        rb.gap[0] = .{ .value = gap };
        rb.range_len[0] = .{};
        rb.id[0] = 0;
        rb.payload[0] = 0;
    }

    fn copy_cells(
        dst: *Rb,
        dst_begin: usize,
        src: *const Rb,
        src_begin: usize,
        n: usize,
    ) void {
        if (n == 0) return;
        @memcpy(dst.gap[dst_begin..][0..n], src.gap[src_begin..][0..n]);
        @memcpy(
            dst.range_len[dst_begin..][0..n],
            src.range_len[src_begin..][0..n],
        );
        @memcpy(dst.id[dst_begin..][0..n], src.id[src_begin..][0..n]);
        @memcpy(dst.payload[dst_begin..][0..n], src.payload[src_begin..][0..n]);
    }

    fn move_cells(rb: *Rb, dst_begin: usize, src_begin: usize, n: usize) void {
        if (n == 0) return;
        @memmove(rb.gap[dst_begin..][0..n], rb.gap[src_begin..][0..n]);
        @memmove(
            rb.range_len[dst_begin..][0..n],
            rb.range_len[src_begin..][0..n],
        );
        @memmove(rb.id[dst_begin..][0..n], rb.id[src_begin..][0..n]);
        @memmove(rb.payload[dst_begin..][0..n], rb.payload[src_begin..][0..n]);
    }
};

const Ib = extern struct {
    const capacity = ib_capacity;
    const CapInt = std.math.IntFittingRange(0, capacity);

    /// gap to next distinct start at this layer. header slot stores the gap to
    /// the first real start in the view.
    gap: [capacity]u64 align(config.dcache_line_bytes),
    next: u32,
    /// Same-layer predecessor; may cross a bounded-view boundary.
    prev: u32,
    /// Distance from slot start to max range end under `down[i]`.
    reach: [capacity]u64 align(config.dcache_line_bytes),
    _pad_0: [8]u8,
    /// Down pointer either to next Ib layer or Rb leaf.
    ///
    /// 0 down num means null, so it is reliable to use this for body-slot
    /// iteration end. header slot liveness comes from `first_is_header`.
    down: [capacity]u32 align(config.dcache_line_bytes),
    _pad_1: [4]u8,

    comptime {
        assert(@alignOf(Ib) == config.dcache_line_bytes);
        assert(@sizeOf(Ib) == 5 * config.dcache_line_bytes);
        assert(@offsetOf(Ib, "gap") % config.dcache_line_bytes == 0);
        assert(@offsetOf(Ib, "reach") % config.dcache_line_bytes == 0);
        assert(@offsetOf(Ib, "down") % config.dcache_line_bytes == 0);
    }

    const Num = enum(std.math.IntFittingRange(0, max_ib_count)) { null = 0, _ };
    const PtrNum = struct {
        ptr: *Ib,
        num: Num,

        pub fn jsonStringify(ib: *const PtrNum, jw: anytype) !void {
            try jw.write(@intFromEnum(ib.num));
        }

        const Iter = struct {
            ib: PtrNum,
            slot_start_rel: BytesInt,
            first_is_header: bool,
            rank: CapInt,
            started: bool,

            const Item = struct {
                ib: PtrNum,
                first_is_header: bool,
                rank: CapInt,
                slot_start_rel: BytesInt,
                gap: BytesInt,
                reach: BytesInt,
                down: u32,
            };

            fn next(it: *Iter, sr: *SkipRange) ?Item {
                while (true) {
                    if (!it.started) {
                        it.started = true;
                        it.rank = 0;
                    } else {
                        const gap: BytesInt = @intCast(it.ib.ptr.gap[it.rank]);
                        it.slot_start_rel += gap;
                        it.rank += 1;
                    }

                    if (it.rank < capacity and
                        it.ib.ptr.occupied(it.first_is_header, it.rank))
                    {
                        return .{
                            .ib = it.ib,
                            .first_is_header = it.first_is_header,
                            .rank = it.rank,
                            .slot_start_rel = it.slot_start_rel,
                            .gap = @intCast(it.ib.ptr.gap[it.rank]),
                            .reach = @intCast(it.ib.ptr.reach[it.rank]),
                            .down = it.ib.ptr.down[it.rank],
                        };
                    }
                    if (!it.next_block(sr)) return null;
                }
            }

            fn next_block(it: *Iter, sr: *SkipRange) bool {
                const next_num: Ib.Num = @enumFromInt(it.ib.ptr.next);
                if (next_num == .null) return false;
                it.ib = .{
                    .num = next_num,
                    .ptr = sr.ib_at(next_num),
                };
                it.first_is_header = false;
                it.started = false;
                return true;
            }
        };

        fn iter(head: PtrNum, first_is_header: bool) Iter {
            return .{
                .ib = head,
                .slot_start_rel = 0,
                .first_is_header = first_is_header,
                .rank = 0,
                .started = false,
            };
        }
    };

    const Find = struct {
        ib: PtrNum,
        first_is_header: bool,
        rank: CapInt,
        /// predecessor start relative to current view; header anchor is 0
        start_rel: BytesInt,
        /// distance from predecessor to next distinct leader
        gap: BytesInt,
    };

    const View = struct {
        /// First block of this bounded layer view.
        head: PtrNum,
        /// Whether `head` exposes the virtual `-inf` slot at rank 0.
        first_is_header: bool,
        /// Exclusive end offset for this bounded view, relative to its
        /// caller-held base.
        end_rel: ?BytesInt,

        const Iter = struct {
            raw: PtrNum.Iter,
            end_rel: ?BytesInt,

            fn next(it: *Iter, sr: *SkipRange) ?PtrNum.Iter.Item {
                const item = it.raw.next(sr) orelse return null;
                if (it.end_rel) |end| {
                    if (item.slot_start_rel >= end) return null;
                }
                return item;
            }
        };

        fn iter(view: View) Iter {
            return .{
                .raw = view.head.iter(view.first_is_header),
                .end_rel = view.end_rel,
            };
        }

        fn past_end(view: View, start_rel: BytesInt) bool {
            if (view.end_rel) |end| return start_rel >= end;
            return false;
        }
    };

    fn occupied(ib: *const Ib, first_is_header: bool, rank: CapInt) bool {
        assert(rank < capacity);
        return (first_is_header and rank == 0) or ib.down[rank] != 0;
    }

    fn len(ib: *const Ib, first_is_header: bool) CapInt {
        for (0..capacity) |i| {
            const rank: CapInt = @intCast(i);
            if (!ib.occupied(first_is_header, rank)) return rank;
        }
        return capacity;
    }

    fn set_end(ib: *Ib, end_len: CapInt) void {
        if (end_len < capacity) ib.down[end_len] = 0;
    }

    fn copy_slots(
        dst: *Ib,
        dst_begin: usize,
        src: *const Ib,
        src_begin: usize,
        n: usize,
    ) void {
        if (n == 0) return;
        @memcpy(dst.gap[dst_begin..][0..n], src.gap[src_begin..][0..n]);
        @memcpy(dst.reach[dst_begin..][0..n], src.reach[src_begin..][0..n]);
        @memcpy(dst.down[dst_begin..][0..n], src.down[src_begin..][0..n]);
    }

    fn move_slots(ib: *Ib, dst_begin: usize, src_begin: usize, n: usize) void {
        if (n == 0) return;
        @memmove(ib.gap[dst_begin..][0..n], ib.gap[src_begin..][0..n]);
        @memmove(ib.reach[dst_begin..][0..n], ib.reach[src_begin..][0..n]);
        @memmove(ib.down[dst_begin..][0..n], ib.down[src_begin..][0..n]);
    }
};

// prefix, when present, carries the header-side child; leader carries the
// promoted skiplist leader.
const PendingTower = union(enum) {
    const RbHeads = struct {
        prefix: Rb.Num = .null,
        leader: Rb.Num,
    };

    const IbHeads = struct {
        prefix: Ib.Num = .null,
        leader: Ib.Num,
    };

    const Down = struct {
        prefix: u32,
        leader: u32,
    };

    rb: RbHeads,
    ib: IbHeads,

    fn down(tower: PendingTower) Down {
        return switch (tower) {
            .rb => |heads| .{
                .prefix = @intFromEnum(heads.prefix),
                .leader = @intFromEnum(heads.leader),
            },
            .ib => |heads| .{
                .prefix = @intFromEnum(heads.prefix),
                .leader = @intFromEnum(heads.leader),
            },
        };
    }
};

// Bottom promotion-band frame. Higher layers need only eager reach widening.
const PromoteFrame = struct {
    found: Ib.Find,
    parent_left_max_end_rel: BytesInt,
    parent_right_max_end_rel: BytesInt,
};

// Derived ID lookup state; the tree is canonical. Range insertion and removal
// leave surviving coordinates unchanged. A future text edit must update or
// lazily transform `start_abs`.
const IdIndexEntry = struct {
    start_abs: BytesInt,
    rb_num: Rb.Num,
};

const RemovePathFrame = struct {
    view: Ib.View,
    base_abs: BytesInt,
    ib_num: Ib.Num,
    first_is_header: bool,
    rank: Ib.CapInt,
    prev_slot: ?IbPredecessor,
    slot_start_abs: BytesInt,
};

const RbCell = struct {
    rb_num: Rb.Num,
    first_is_header: bool,
    rank: Rb.CapInt,
};

// Physical predecessors can cross a bounded-view edge. They carry storage
// facts only; logical header state stays on the entered target view.
const RbPredecessor = struct {
    rb_num: Rb.Num,
    rank: Rb.CapInt,
};

const IbPredecessor = struct {
    ib_num: Ib.Num,
    rank: Ib.CapInt,
    is_empty_header: bool,
};

const RemoveLocation = struct {
    range: Range,
    cell: RbCell,
    prev_cell: ?RbPredecessor,
    leaf_view: Rb.View,
    leaf_base_abs: BytesInt,
    path: [max_height]RemovePathFrame,
    path_len: HeightInt,
};

const RemovalReachPlan = struct {
    // Only this suffix is initialized. A common non-max removal writes no
    // entries. Null means the changed child became empty.
    child_reach: [max_height]?BytesInt = undefined,
    changed_begin: HeightInt,
};

comptime {
    assert(@sizeOf(RangeFlags) == 1);
    assert(@sizeOf(Rb.Gap) == 8);
    assert(@sizeOf(Rb.Len) == 8);
}

/// `gpa` must be the allocator used by every insert on `sr`.
pub fn deinit(sr: *SkipRange, gpa: Allocator) void {
    sr.id_index.deinit(gpa);
    sr.ibs.deinit(gpa);
    sr.rbs.deinit(gpa);
    sr.* = undefined;
}

/// Expected O(1): one hash lookup and at most `Rb.capacity` cell comparisons.
/// Allocates nothing.
pub fn get(sr: *const SkipRange, id: RangeId) ?Range {
    const entry = sr.id_index.get(id) orelse return null;
    const rb = sr.rb_at_const(entry.rb_num);
    const rank = id_rank_in_rb(rb, id);
    return range_at(rb, rank, entry.start_abs);
}

/// Expected O(log d + v), where `d` is distinct starts and `v` is conditional
/// bounded-view work when the removed range supplies a subtree max. Removing
/// the final range also clears retained ID-index metadata in O(c), where `c`
/// is index capacity.
/// Worst-case O(n + c). Allocates nothing.
pub fn remove(sr: *SkipRange, id: RangeId) ?Range {
    const entry = sr.id_index.get(id) orelse return null;
    const location = sr.locate_remove(id, entry);
    const has_next_cell = sr.rb_cell_has_next(location.cell);
    const start_survives = sr.start_survives_removal(
        location,
        has_next_cell,
    );
    const reach_plan: RemovalReachPlan = if (sr.range_count == 1)
        .{ .changed_begin = location.path_len }
    else
        sr.plan_removal_reach(id, location);
    log.debug(@src(), "remove locate", .{
        .id = id,
        .start_survives = start_survives,
        .range = location.range,
        .cell = location.cell,
        .prev_cell = location.prev_cell,
        .path = location.path[0..location.path_len],
        .reach_changed_begin = reach_plan.changed_begin,
    });

    assert(sr.id_index.remove(id));
    sr.remove_rb_cell(location, start_survives, has_next_cell);
    sr.range_count -= 1;
    if (sr.range_count == 0) {
        sr.root = .null;
        sr.ib_height = 0;
        sr.id_index.clearRetainingCapacity();
        sr.ibs.clearRetainingCapacity();
        sr.rbs.clearRetainingCapacity();
        return location.range;
    }

    sr.apply_removal_reach(location, reach_plan);
    if (!start_survives) {
        sr.remove_tower(location, reach_plan);
        sr.collapse_root();
    }
    return location.range;
}

/// Asserts `range.start <= range.end`.
/// `gpa` must be the allocator used by every insert and by `deinit`.
/// Allocation failure may leave `sr` invalid; treat it as fatal.
pub fn insert(
    sr: *SkipRange,
    gpa: Allocator,
    range: Range,
) InsertError!RangeId {
    assert(range.start <= range.end);
    const height = augment_height(sr.rng.random(), 0, max_height);
    return sr.insert_with_height(gpa, range, height);
}

fn insert_with_height(
    sr: *SkipRange,
    gpa: Allocator,
    range: Range,
    height: HeightInt,
) InsertError!RangeId {
    if (sr.range_count == max_ranges) return error.OutOfMemory;
    if (sr.next_id > std.math.maxInt(u32))
        return error.RangeIdExhausted;

    try sr.id_index.ensureUnusedCapacity(gpa, 1);
    const id: RangeId = @enumFromInt(sr.next_id);
    const rb_num = try sr.insert_id_with_height(gpa, range, id, height);
    sr.id_index.putAssumeCapacityNoClobber(id, .{
        .start_abs = range.start,
        .rb_num = rb_num,
    });
    sr.next_id += 1;
    return id;
}

fn insert_id_with_height(
    sr: *SkipRange,
    gpa: Allocator,
    range: Range,
    id: RangeId,
    height: HeightInt,
) Allocator.Error!Rb.Num {
    assert(id != .null);

    // First range seeds the leaf. Root growth below builds its tower.
    if (sr.root == .null) {
        const leader = try sr.rb_create(gpa);
        leader.ptr.set(0, range, id, 0);
        leader.ptr.set_end(1);

        var heads: PendingTower.RbHeads = .{ .leader = leader.num };
        if (range.start != 0) {
            const prefix = try sr.rb_create(gpa);
            link_rb_blocks(sr, prefix, leader.num);
            prefix.ptr.set_header(range.start);
            prefix.ptr.set_end(1);
            heads.prefix = prefix.num;
        }

        try sr.grow_root(
            gpa,
            .{ .rb = heads },
            range.start,
            0,
            range.end,
            0,
            @max(@as(HeightInt, 1), height),
            .null,
        );
        sr.range_count = 1;
        return leader.num;
    }

    // Descend once and widen reach. Only bottom promote_h frames can gain a
    // promoted leader, so a fixed stack keeps those frames for one bottom-up
    // tower pass.
    // Same-start returns at the leaf; lower height naturally shrinks
    // retained frames and ascent work. Capacity spills stay in their layer.
    var path: [max_height]PromoteFrame = undefined;
    var promote_h = height;
    var ib_view: Ib.View = .{
        .head = sr.root_ptr(),
        .first_is_header = true,
        .end_rel = null,
    };
    var insert_rel = range.start;
    var end_rel = range.end;
    var walk_h: HeightInt = sr.ib_height + 1;

    const leaf_view: Rb.View = descend: while (true) {
        const need_reach = walk_h <= promote_h;
        const ib_scan = if (need_reach)
            sr.scan_ib(ib_view, insert_rel, true)
        else
            sr.scan_ib(ib_view, insert_rel, false);
        log.debug(@src(), "insert descend", .{
            .height = walk_h,
            .view = ib_view,
            .target_rel = insert_rel,
            .scan = ib_scan,
        });

        // An upper tower hit proves same-start. Keep descending for leaf
        // placement; stop collecting promotion repair state.
        const child_rank = ib_scan.find.rank;
        const child_is_header =
            ib_scan.find.first_is_header and child_rank == 0;
        if (!child_is_header and ib_scan.find.start_rel == insert_rel) {
            promote_h = 0;
        } else if (need_reach) {
            path[walk_h - 1] = .{
                .found = ib_scan.find,
                .parent_left_max_end_rel = ib_scan.left_max_end_rel,
                .parent_right_max_end_rel = ib_scan.right_max_end_rel,
            };
        }

        const child_base_in_parent = ib_scan.find.start_rel;
        const child_gap = ib_scan.find.gap;
        const child_end_in_parent_rel = slot_child_end_rel(
            ib_view.end_rel,
            child_base_in_parent,
            child_gap,
        );
        const child_end_rel = if (child_end_in_parent_rel) |end_in_parent|
            end_in_parent - child_base_in_parent
        else
            null;
        const child_num = ib_scan.find.ib.ptr.down[child_rank];
        const reach: u64 = @intCast(end_rel - child_base_in_parent);
        ib_scan.find.ib.ptr.reach[child_rank] = @max(
            ib_scan.find.ib.ptr.reach[child_rank],
            reach,
        );

        // Mutable coordinates follow the walk: parent-relative to
        // child-relative.
        insert_rel -= child_base_in_parent;
        end_rel -= child_base_in_parent;

        if (walk_h == 1) {
            const rb_num: Rb.Num = @enumFromInt(child_num);
            break :descend .{
                .head = .{ .num = rb_num, .ptr = sr.rb_at(rb_num) },
                .first_is_header = child_is_header,
                .end_rel = child_end_rel,
            };
        }

        const ib_num: Ib.Num = @enumFromInt(child_num);
        ib_view = .{
            .head = .{ .num = ib_num, .ptr = sr.ib_at(ib_num) },
            .first_is_header = child_is_header,
            .end_rel = child_end_rel,
        };
        walk_h -= 1;
    };

    // Leaf commits same-start range or new leader.
    const rb_scan = if (promote_h != 0)
        sr.scan_rb(leaf_view, insert_rel, true)
    else
        sr.scan_rb(leaf_view, insert_rel, false);
    const leaf = rb_scan.find;
    log.debug(@src(), "insert leaf", .{
        .view = leaf_view,
        .target_rel = insert_rel,
        .scan = rb_scan,
    });
    const same_start = rb_scan.same_start;
    // Same-start ranges and leaf-only leaders share one packed insertion.
    if (same_start or promote_h == 0) {
        const place = leaf;
        const old_len = place.rb.ptr.len(place.first_is_header);
        const insert_rank = place.rank + 1;
        const delta: BytesInt = if (same_start)
            0
        else
            insert_rel - leaf.start_rel;
        const prev_gap = delta;
        const gap_after: BytesInt = if (same_start)
            place.rb.ptr.gap[place.rank].value
        else if (leaf.gap == 0)
            0
        else
            leaf.gap - delta;
        const inserted_rb_num = if (old_len < Rb.capacity) blk: {
            place.rb.ptr.move_cells(
                insert_rank + 1,
                insert_rank,
                old_len - insert_rank,
            );
            place.rb.ptr.gap[place.rank].value = prev_gap;
            place.rb.ptr.set(insert_rank, range, id, gap_after);
            place.rb.ptr.set_end(old_len + 1);
            break :blk place.rb.num;
        } else blk: {
            break :blk try sr.rb_spill(
                gpa,
                place.rb,
                place.first_is_header,
                insert_rank,
                prev_gap,
                range,
                id,
                gap_after,
            );
        };
        sr.range_count += 1;
        return inserted_rb_num;
    }

    // Distinct-start promotion makes the leaf leader view, then carries its
    // pending tower through one bottom-up pass over promote_h logical views.
    var pending: PendingTower = .{
        .rb = try sr.rb_promote(gpa, leaf, insert_rel, range, id),
    };
    const inserted_rb_num = pending.rb.leader;
    var left_max_end_rel = rb_scan.left_max_end_rel;
    var right_max_end_rel = @max(rb_scan.right_max_end_rel, end_rel);

    // Ascend once through the retained promotion frames.
    var h_up: HeightInt = 0;
    const tree_h = sr.ib_height + 1;
    while (h_up < @min(promote_h, tree_h)) {
        const frame = path[h_up];
        h_up += 1;
        const child_base_in_parent = frame.found.start_rel;

        // Undo one descent rebase before mutating this parent layer.
        left_max_end_rel += child_base_in_parent;
        right_max_end_rel += child_base_in_parent;
        insert_rel += child_base_in_parent;
        log.debug(@src(), "insert ascend", .{
            .height = h_up,
            .frame = frame,
            .left_max_end_rel = left_max_end_rel,
            .right_max_end_rel = right_max_end_rel,
            .pending = pending,
        });

        const child = pending.down();
        if (h_up < promote_h) {
            // Still below chosen height. Keep carrying pending tower.
            pending = .{
                .ib = try sr.ib_promote(
                    gpa,
                    frame.found,
                    child,
                    insert_rel,
                    left_max_end_rel,
                    right_max_end_rel,
                ),
            };
        } else {
            assert(h_up == promote_h);
            // Promotion height reached. Attach final promoted leader here.
            try sr.ib_attach(
                gpa,
                frame.found,
                child,
                insert_rel,
                left_max_end_rel,
                right_max_end_rel,
            );
        }

        left_max_end_rel = @max(
            frame.parent_left_max_end_rel,
            left_max_end_rel,
        );
        right_max_end_rel = @max(
            frame.parent_right_max_end_rel,
            right_max_end_rel,
        );
    }

    // Build remaining layers above the old root.
    if (h_up < promote_h) {
        try sr.grow_root(
            gpa,
            pending,
            range.start,
            left_max_end_rel,
            right_max_end_rel,
            h_up,
            promote_h,
            if (range.start == 0) .null else sr.root,
        );
    }
    sr.range_count += 1;
    return inserted_rb_num;
}

fn rb_promote(
    sr: *SkipRange,
    gpa: Allocator,
    found: Rb.Find,
    leader_start_rel: BytesInt,
    range: Range,
    id: RangeId,
) Allocator.Error!PendingTower.RbHeads {
    const at_header = found.first_is_header and found.rank == 0;
    const delta = leader_start_rel - found.start_rel;
    const gap_after = if (found.gap == 0) 0 else found.gap - delta;
    if (at_header) {
        const prefix_gap = delta;
        const leader_gap = gap_after;
        if (found.rb.ptr.len(true) == 1) {
            const leader_next = found.rb.ptr.next;
            if (prefix_gap == 0) {
                found.rb.ptr.set(0, range, id, leader_gap);
                found.rb.ptr.set_end(1);
                return .{ .leader = found.rb.num };
            }

            const leader = try sr.rb_create(gpa);
            link_rb_blocks(sr, leader, @enumFromInt(leader_next));
            leader.ptr.set(0, range, id, leader_gap);
            leader.ptr.set_end(1);

            link_rb_blocks(sr, found.rb, leader.num);
            found.rb.ptr.set_header(prefix_gap);
            found.rb.ptr.set_end(1);
            return .{
                .prefix = found.rb.num,
                .leader = leader.num,
            };
        }

        rb_strip_header(found.rb);
        const leader = try sr.rb_create(gpa);
        link_rb_blocks(sr, leader, found.rb.num);
        leader.ptr.set(0, range, id, leader_gap);
        leader.ptr.set_end(1);

        if (prefix_gap == 0) return .{ .leader = leader.num };

        const prefix = try sr.rb_create(gpa);
        link_rb_blocks(sr, prefix, leader.num);
        prefix.ptr.set_header(prefix_gap);
        prefix.ptr.set_end(1);
        return .{
            .prefix = prefix.num,
            .leader = leader.num,
        };
    }

    const leader = try sr.rb_create(gpa);
    leader.ptr.set(0, range, id, gap_after);
    leader.ptr.set_end(1);

    rb_copy_suffix(leader, found.rb, found.rank + 1, 1, found.first_is_header);
    sr.reindex_moved_rb_cells(leader, id);
    link_rb_blocks(sr, leader, @enumFromInt(found.rb.ptr.next));

    found.rb.ptr.set_end(found.rank + 1);
    link_rb_blocks(sr, found.rb, leader.num);
    found.rb.ptr.gap[found.rank].value = delta;
    return .{ .leader = leader.num };
}

fn ib_promote(
    sr: *SkipRange,
    gpa: Allocator,
    found: Ib.Find,
    child: PendingTower.Down,
    leader_start_rel: BytesInt,
    left_max_end_rel: BytesInt,
    right_max_end_rel: BytesInt,
) Allocator.Error!PendingTower.IbHeads {
    const at_header = found.first_is_header and found.rank == 0;
    const delta = leader_start_rel - found.start_rel;
    const gap_after = if (found.gap == 0) 0 else found.gap - delta;
    const leader_reach = right_max_end_rel - leader_start_rel;
    if (at_header) {
        const left_child = if (delta == 0) 0 else found.ib.ptr.down[found.rank];
        const next: PendingTower.IbHeads = next: {
            const prefix_gap = delta;
            const leader_gap = gap_after;
            if (found.ib.ptr.len(true) == 1) {
                const leader_next = found.ib.ptr.next;
                if (prefix_gap == 0) {
                    found.ib.ptr.gap[0] = @intCast(leader_gap);
                    found.ib.ptr.reach[0] = 0;
                    found.ib.ptr.down[0] = 0;
                    found.ib.ptr.set_end(1);
                    break :next .{ .leader = found.ib.num };
                }

                const leader = try sr.ib_create(gpa);
                link_ib_blocks(sr, leader, @enumFromInt(leader_next));
                leader.ptr.gap[0] = @intCast(leader_gap);
                leader.ptr.reach[0] = 0;
                leader.ptr.down[0] = 0;
                leader.ptr.set_end(1);

                link_ib_blocks(sr, found.ib, leader.num);
                found.ib.ptr.gap[0] = @intCast(prefix_gap);
                found.ib.ptr.reach[0] = 0;
                found.ib.ptr.down[0] = 0;
                found.ib.ptr.set_end(1);
                break :next .{
                    .prefix = found.ib.num,
                    .leader = leader.num,
                };
            }

            ib_strip_header(found.ib);
            const leader = try sr.ib_create(gpa);
            link_ib_blocks(sr, leader, found.ib.num);
            leader.ptr.gap[0] = @intCast(leader_gap);
            leader.ptr.reach[0] = 0;
            leader.ptr.down[0] = 0;
            leader.ptr.set_end(1);

            if (prefix_gap == 0)
                break :next .{ .leader = leader.num };

            const prefix = try sr.ib_create(gpa);
            link_ib_blocks(sr, prefix, leader.num);
            prefix.ptr.gap[0] = @intCast(prefix_gap);
            prefix.ptr.reach[0] = 0;
            prefix.ptr.down[0] = 0;
            prefix.ptr.set_end(1);
            break :next .{
                .prefix = prefix.num,
                .leader = leader.num,
            };
        };
        const leader: Ib.PtrNum = .{
            .num = next.leader,
            .ptr = sr.ib_at(next.leader),
        };
        if (next.prefix != .null) {
            const prefix: Ib.PtrNum = .{
                .num = next.prefix,
                .ptr = sr.ib_at(next.prefix),
            };
            prefix.ptr.down[0] = if (child.prefix != 0)
                child.prefix
            else
                left_child;
            leader.ptr.down[0] = child.leader;
            prefix.ptr.reach[0] = @intCast(left_max_end_rel);
            leader.ptr.reach[0] = @intCast(leader_reach);
        } else {
            leader.ptr.down[0] = child.leader;
            leader.ptr.reach[0] = @intCast(leader_reach);
        }
        return next;
    }

    assert(child.prefix == 0);
    const leader = try sr.ib_create(gpa);

    leader.ptr.gap[0] = @intCast(gap_after);
    leader.ptr.reach[0] = 0;
    leader.ptr.down[0] = child.leader;
    leader.ptr.set_end(1);

    const old = found.ib;
    const keep = found.rank + 1;
    const old_len = old.ptr.len(found.first_is_header);
    const moved = old_len - keep;
    if (moved != 0) {
        leader.ptr.copy_slots(1, old.ptr, keep, moved);
        leader.ptr.set_end(1 + @as(Ib.CapInt, @intCast(moved)));
    }
    link_ib_blocks(sr, leader, @enumFromInt(old.ptr.next));
    old.ptr.set_end(keep);
    link_ib_blocks(sr, old, leader.num);
    const left_reach = left_max_end_rel - found.start_rel;
    old.ptr.gap[found.rank] = @intCast(delta);
    old.ptr.reach[found.rank] = @intCast(left_reach);
    leader.ptr.reach[0] = @intCast(leader_reach);
    return .{ .leader = leader.num };
}

fn ib_attach(
    sr: *SkipRange,
    gpa: Allocator,
    found: Ib.Find,
    child: PendingTower.Down,
    leader_start_rel: BytesInt,
    left_max_end_rel: BytesInt,
    right_max_end_rel: BytesInt,
) Allocator.Error!void {
    const at_header = found.first_is_header and found.rank == 0;
    const delta = leader_start_rel - found.start_rel;
    const gap_after = if (found.gap == 0) 0 else found.gap - delta;
    const leader_reach = right_max_end_rel - leader_start_rel;
    if (at_header) {
        const left_child = if (delta == 0) 0 else found.ib.ptr.down[found.rank];
        const left_down = if (child.prefix != 0) child.prefix else left_child;
        const old_len = found.ib.ptr.len(true);
        if (old_len == Ib.capacity) {
            _ = try sr.ib_spill(
                gpa,
                found.ib,
                true,
                1,
                delta,
                left_max_end_rel,
                left_down,
                gap_after,
                leader_reach,
                child.leader,
            );
        } else {
            found.ib.ptr.move_slots(2, 1, old_len - 1);
            found.ib.ptr.gap[0] = @intCast(delta);
            found.ib.ptr.reach[0] = @intCast(left_max_end_rel);
            found.ib.ptr.down[0] = left_down;
            found.ib.ptr.gap[1] = @intCast(gap_after);
            found.ib.ptr.reach[1] = @intCast(leader_reach);
            found.ib.ptr.down[1] = child.leader;
            found.ib.ptr.set_end(old_len + 1);
        }
        return;
    }

    assert(child.prefix == 0);
    const left_reach = left_max_end_rel - found.start_rel;
    const old_len = found.ib.ptr.len(found.first_is_header);
    if (old_len == Ib.capacity) {
        // Promotion ends here. Capacity adds a balanced same-layer spill.
        _ = try sr.ib_spill(
            gpa,
            found.ib,
            found.first_is_header,
            found.rank + 1,
            delta,
            left_reach,
            found.ib.ptr.down[found.rank],
            gap_after,
            leader_reach,
            child.leader,
        );
        return;
    }

    const rank = found.rank + 1;
    found.ib.ptr.move_slots(rank + 1, rank, old_len - rank);
    found.ib.ptr.gap[found.rank] = @intCast(delta);
    found.ib.ptr.gap[rank] = @intCast(gap_after);
    found.ib.ptr.set_end(old_len + 1);
    found.ib.ptr.down[rank] = child.leader;
    found.ib.ptr.reach[found.rank] = @intCast(left_reach);
    found.ib.ptr.reach[rank] = @intCast(leader_reach);
}

fn grow_root(
    sr: *SkipRange,
    gpa: Allocator,
    pending: PendingTower,
    leader_start_abs: BytesInt,
    left_max_end_abs: BytesInt,
    right_max_end_abs: BytesInt,
    built_h: HeightInt,
    tower_h: HeightInt,
    left_fallback: Ib.Num,
) Allocator.Error!void {
    assert(built_h < tower_h);

    const leader_reach = right_max_end_abs - leader_start_abs;
    var h_up = built_h;
    var child = pending.down();
    var fallback: u32 = @intFromEnum(left_fallback);
    while (h_up < tower_h) {
        h_up += 1;
        var left_down = child.prefix;
        if (left_down == 0) {
            left_down = fallback;
            fallback = 0;
        }

        if (h_up < tower_h) {
            const leader = try sr.ib_create(gpa);
            leader.ptr.gap[0] = 0;
            leader.ptr.reach[0] = @intCast(leader_reach);
            leader.ptr.down[0] = child.leader;
            leader.ptr.set_end(1);

            var prefix_num: Ib.Num = .null;
            if (leader_start_abs != 0 or left_down != 0) {
                const prefix = try sr.ib_create(gpa);
                link_ib_blocks(sr, prefix, leader.num);
                prefix.ptr.gap[0] = @intCast(leader_start_abs);
                prefix.ptr.reach[0] = @intCast(left_max_end_abs);
                prefix.ptr.down[0] = left_down;
                prefix.ptr.set_end(1);
                prefix_num = prefix.num;
            }
            child = .{
                .prefix = @intFromEnum(prefix_num),
                .leader = @intFromEnum(leader.num),
            };
            continue;
        }

        const root = try sr.ib_create(gpa);
        root.ptr.gap[0] = @intCast(leader_start_abs);
        root.ptr.reach[0] = @intCast(left_max_end_abs);
        root.ptr.down[0] = left_down;
        root.ptr.gap[1] = 0;
        root.ptr.reach[1] = @intCast(leader_reach);
        root.ptr.down[1] = child.leader;
        root.ptr.set_end(2);
        sr.root = root.num;
        sr.ib_height = tower_h - 1;
    }
}

fn augment_height(
    rand: std.Random,
    h_min: HeightInt,
    h_max: HeightInt,
) HeightInt {
    var h = h_min;
    while (h < h_max) {
        if (h == 0) {
            if (rand.uintLessThan(
                std.math.IntFittingRange(0, Rb.capacity - 1),
                Rb.capacity,
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
    return h;
}

fn ib_create(sr: *SkipRange, gpa: Allocator) Allocator.Error!Ib.PtrNum {
    const ib = try sr.ibs.create(gpa);
    const out: Ib.PtrNum = .{
        .ptr = ib.ptr,
        .num = @enumFromInt(ib.num.to_int() + 1),
    };
    out.ptr.* = undefined;
    out.ptr.next = 0;
    out.ptr.prev = 0;
    return out;
}

fn rb_create(sr: *SkipRange, gpa: Allocator) Allocator.Error!Rb.PtrNum {
    const rb = try sr.rbs.create(gpa);
    const out: Rb.PtrNum = .{
        .ptr = rb.ptr,
        .num = @enumFromInt(rb.num.to_int() + 1),
    };
    out.ptr.* = undefined;
    out.ptr.next = 0;
    out.ptr.prev = 0;
    return out;
}

fn ib_destroy(sr: *SkipRange, num: Ib.Num) void {
    assert(num != .null);
    sr.ibs.destroy(.cast(@intFromEnum(num) - 1));
}

fn rb_destroy(sr: *SkipRange, num: Rb.Num) void {
    assert(num != .null);
    sr.rbs.destroy(.cast(@intFromEnum(num) - 1));
}

fn ib_at(sr: *SkipRange, num: Ib.Num) *Ib {
    assert(num != .null);
    return sr.ibs.at(.cast(@intFromEnum(num) - 1));
}

fn rb_at(sr: *SkipRange, num: Rb.Num) *Rb {
    assert(num != .null);
    return sr.rbs.at(.cast(@intFromEnum(num) - 1));
}

fn ib_at_const(sr: *const SkipRange, num: Ib.Num) *const Ib {
    assert(num != .null);
    return sr.ibs.at(.cast(@intFromEnum(num) - 1));
}

fn rb_at_const(sr: *const SkipRange, num: Rb.Num) *const Rb {
    assert(num != .null);
    return sr.rbs.at(.cast(@intFromEnum(num) - 1));
}

fn link_ib_blocks(sr: *SkipRange, left: Ib.PtrNum, right_num: Ib.Num) void {
    left.ptr.next = @intFromEnum(right_num);
    if (right_num != .null)
        sr.ib_at(right_num).prev = @intFromEnum(left.num);
}

fn link_rb_blocks(sr: *SkipRange, left: Rb.PtrNum, right_num: Rb.Num) void {
    left.ptr.next = @intFromEnum(right_num);
    if (right_num != .null)
        sr.rb_at(right_num).prev = @intFromEnum(left.num);
}

// Structural insertion has not published the new ID yet. Reindex only
// pre-existing cells moved into `rb`.
fn reindex_moved_rb_cells(
    sr: *SkipRange,
    rb: Rb.PtrNum,
    unpublished_id: RangeId,
) void {
    for (0..rb.ptr.len(false)) |rank| {
        const id: RangeId = @enumFromInt(rb.ptr.id[rank]);
        const entry = sr.id_index.getPtr(id) orelse {
            assert(id == unpublished_id);
            continue;
        };
        entry.rb_num = rb.num;
    }
}

fn root_ptr(sr: *SkipRange) Ib.PtrNum {
    return .{
        .num = sr.root,
        .ptr = sr.ib_at(sr.root),
    };
}

fn slot_child_end_rel(
    view_end_rel: ?BytesInt,
    slot_start_rel: BytesInt,
    gap: BytesInt,
) ?BytesInt {
    if (gap == 0) return view_end_rel;

    const next = slot_start_rel + gap;
    if (view_end_rel) |bound| return @min(next, bound);
    return next;
}

fn id_rank_in_rb(rb: *const Rb, id: RangeId) Rb.CapInt {
    const id_int = @intFromEnum(id);
    for (rb.id, 0..) |candidate, rank| {
        if (candidate == id_int) return @intCast(rank);
    }
    // `id_index` points every live ID at its containing Rb.
    unreachable;
}

fn range_at(rb: *const Rb, rank: Rb.CapInt, start_abs: BytesInt) Range {
    return .{
        .start = start_abs,
        .end = start_abs + rb.range_len[rank].value,
        .payload = rb.payload[rank],
        .flags = .{
            .start_right = rb.gap[rank].start_right,
            .end_right = rb.range_len[rank].end_right,
        },
    };
}

fn locate_remove(
    sr: *SkipRange,
    id: RangeId,
    entry: IdIndexEntry,
) RemoveLocation {
    assert(sr.root != .null);

    var path: [max_height]RemovePathFrame = undefined;
    var path_len: HeightInt = 0;
    var ib_view: Ib.View = .{
        .head = sr.root_ptr(),
        .first_is_header = true,
        .end_rel = null,
    };
    var base_abs: BytesInt = 0;
    var target_rel = entry.start_abs;
    var walk_h: HeightInt = sr.ib_height + 1;

    const leaf_view: Rb.View = descend: while (true) {
        const found = sr.scan_ib(ib_view, target_rel, false).find;
        path[path_len] = .{
            .view = ib_view,
            .base_abs = base_abs,
            .ib_num = found.ib.num,
            .first_is_header = found.first_is_header,
            .rank = found.rank,
            .prev_slot = sr.previous_ib_slot(found),
            .slot_start_abs = base_abs + found.start_rel,
        };
        path_len += 1;

        const child_is_header =
            found.first_is_header and found.rank == 0;
        const child_base_rel = found.start_rel;
        const child_end_in_parent_rel = slot_child_end_rel(
            ib_view.end_rel,
            child_base_rel,
            found.gap,
        );
        const child_end_rel = if (child_end_in_parent_rel) |end_rel|
            end_rel - child_base_rel
        else
            null;
        const child_num = found.ib.ptr.down[found.rank];
        base_abs += child_base_rel;
        target_rel -= child_base_rel;

        if (walk_h == 1) {
            const rb_num: Rb.Num = @enumFromInt(child_num);
            break :descend .{
                .head = .{
                    .num = rb_num,
                    .ptr = sr.rb_at(rb_num),
                },
                .first_is_header = child_is_header,
                .end_rel = child_end_rel,
            };
        }

        const ib_num: Ib.Num = @enumFromInt(child_num);
        ib_view = .{
            .head = .{
                .num = ib_num,
                .ptr = sr.ib_at(ib_num),
            },
            .first_is_header = child_is_header,
            .end_rel = child_end_rel,
        };
        walk_h -= 1;
    };

    assert(entry.start_abs == base_abs + target_rel);
    const rb = sr.rb_at(entry.rb_num);
    const rank = id_rank_in_rb(rb, id);
    const cell_first_is_header =
        entry.rb_num == leaf_view.head.num and leaf_view.first_is_header;
    if (entry.rb_num == leaf_view.head.num)
        assert((rb.id[0] == 0) == leaf_view.first_is_header);
    const cell: RbCell = .{
        .rb_num = entry.rb_num,
        .first_is_header = cell_first_is_header,
        .rank = rank,
    };
    return .{
        .range = range_at(rb, rank, entry.start_abs),
        .cell = cell,
        .prev_cell = sr.previous_rb_cell(cell),
        .leaf_view = leaf_view,
        .leaf_base_abs = base_abs,
        .path = path,
        .path_len = path_len,
    };
}

fn previous_ib_slot(
    sr: *const SkipRange,
    found: Ib.Find,
) ?IbPredecessor {
    if (found.rank > 0) {
        const rank = found.rank - 1;
        return .{
            .ib_num = found.ib.num,
            .rank = rank,
            .is_empty_header = found.first_is_header and rank == 0 and
                found.ib.ptr.down[rank] == 0,
        };
    }

    const prev_num: Ib.Num = @enumFromInt(found.ib.ptr.prev);
    if (prev_num == .null) return null;
    const prev = sr.ib_at_const(prev_num);
    const prev_first_is_header = prev.down[0] == 0;
    const prev_len = prev.len(prev_first_is_header);
    assert(prev_len > 0);
    return .{
        .ib_num = prev_num,
        .rank = prev_len - 1,
        .is_empty_header = prev_first_is_header and prev_len == 1,
    };
}

fn previous_rb_cell(
    sr: *const SkipRange,
    cell: RbCell,
) ?RbPredecessor {
    if (cell.rank > 0) return .{
        .rb_num = cell.rb_num,
        .rank = cell.rank - 1,
    };

    const rb = sr.rb_at_const(cell.rb_num);
    const prev_num: Rb.Num = @enumFromInt(rb.prev);
    if (prev_num == .null) return null;
    const prev = sr.rb_at_const(prev_num);
    const prev_first_is_header = prev.id[0] == 0;
    const prev_len = prev.len(prev_first_is_header);
    assert(prev_len > 0);
    return .{
        .rb_num = prev_num,
        .rank = prev_len - 1,
    };
}

fn start_survives_removal(
    sr: *const SkipRange,
    location: RemoveLocation,
    has_next_cell: bool,
) bool {
    if (location.prev_cell) |prev_cell| {
        const prev = sr.rb_at_const(prev_cell.rb_num);
        const prev_same_start =
            prev.id[prev_cell.rank] != 0 and
            prev.gap[prev_cell.rank].value == 0;
        if (prev_same_start) return true;
    }

    const rb = sr.rb_at_const(location.cell.rb_num);
    return rb.gap[location.cell.rank].value == 0 and
        has_next_cell;
}

// Reach can shrink only along the located path. Plan against the intact tree
// so replacement-max scans retain their original bounded views.
fn plan_removal_reach(
    sr: *SkipRange,
    removed_id: RangeId,
    location: RemoveLocation,
) RemovalReachPlan {
    var plan: RemovalReachPlan = .{
        .changed_begin = location.path_len,
    };
    const leaf_frame = location.path[location.path_len - 1];
    const leaf_parent = sr.ib_at_const(leaf_frame.ib_num);
    const old_leaf_max_end_abs: BytesInt =
        leaf_frame.slot_start_abs +
        @as(BytesInt, @intCast(leaf_parent.reach[leaf_frame.rank]));
    assert(location.range.end <= old_leaf_max_end_abs);
    if (location.range.end != old_leaf_max_end_abs) return plan;

    var new_child_max_end_abs = sr.scan_rb_max_end_abs(
        location.leaf_view,
        location.leaf_base_abs,
        removed_id,
    );
    if (new_child_max_end_abs == old_leaf_max_end_abs) return plan;

    var depth = location.path_len;
    while (depth > 0) {
        depth -= 1;
        const frame = location.path[depth];
        const ib = sr.ib_at_const(frame.ib_num);
        const old_child_max_end_abs: BytesInt =
            frame.slot_start_abs +
            @as(BytesInt, @intCast(ib.reach[frame.rank]));
        if (new_child_max_end_abs) |new_max|
            assert(new_max < old_child_max_end_abs);

        plan.child_reach[depth] = if (new_child_max_end_abs) |new_max|
            new_max - frame.slot_start_abs
        else
            null;
        plan.changed_begin = depth;
        if (depth == 0) break;

        const parent = location.path[depth - 1];
        const parent_ib = sr.ib_at_const(parent.ib_num);
        const old_view_max_end_abs: BytesInt =
            parent.slot_start_abs +
            @as(BytesInt, @intCast(parent_ib.reach[parent.rank]));
        assert(old_child_max_end_abs <= old_view_max_end_abs);
        if (old_child_max_end_abs < old_view_max_end_abs) break;

        const new_view_max_end_abs =
            sr.scan_ib_max_end_abs(
                frame.view,
                frame.base_abs,
                frame,
                new_child_max_end_abs,
            );
        if (new_view_max_end_abs == old_view_max_end_abs) break;
        if (new_view_max_end_abs) |new_max|
            assert(new_max < old_view_max_end_abs);
        new_child_max_end_abs = new_view_max_end_abs;
    }
    return plan;
}

fn apply_removal_reach(
    sr: *SkipRange,
    location: RemoveLocation,
    plan: RemovalReachPlan,
) void {
    for (plan.changed_begin..location.path_len) |depth| {
        const frame = location.path[depth];
        sr.ib_at(frame.ib_num).reach[frame.rank] = @intCast(
            plan.child_reach[depth] orelse 0,
        );
    }
}

fn rb_cell_has_next(sr: *const SkipRange, cell: RbCell) bool {
    const rb = sr.rb_at_const(cell.rb_num);
    return cell.rank + 1 < rb.len(cell.first_is_header) or
        rb.next != 0;
}

fn remove_rb_cell(
    sr: *SkipRange,
    location: RemoveLocation,
    start_survives: bool,
    has_next_cell: bool,
) void {
    const cell = location.cell;
    const rb = sr.rb_at(cell.rb_num);
    if (location.prev_cell == null and !start_survives) {
        assert(location.range.start == 0);
        assert(!cell.first_is_header and cell.rank == 0);
        const victim_gap = rb.gap[0].value;
        rb.set_header(victim_gap);
        return;
    }

    const prev_cell = location.prev_cell;
    if (prev_cell) |prev| {
        const prev_rb = sr.rb_at(prev.rb_num);
        const victim_gap = rb.gap[cell.rank].value;
        if (victim_gap == 0 and !has_next_cell)
            prev_rb.gap[prev.rank].value = 0
        else
            prev_rb.gap[prev.rank].value += victim_gap;
    } else {
        assert(location.range.start == 0);
        assert(!cell.first_is_header and cell.rank == 0);
        assert(start_survives);
        assert(has_next_cell);
        assert(rb.gap[cell.rank].value == 0);
    }

    const old_len = rb.len(cell.first_is_header);
    assert(cell.rank < old_len);
    const keep_after = old_len - cell.rank - 1;
    rb.move_cells(cell.rank, cell.rank + 1, keep_after);
    rb.set_end(old_len - 1);

    if (rb.len(cell.first_is_header) != 0) return;
    assert(!cell.first_is_header);
    const next_num = rb.next;
    if (prev_cell) |prev| {
        assert(prev.rb_num != cell.rb_num);
        const prev_rb = sr.rb_at(prev.rb_num);
        assert(prev_rb.next == @intFromEnum(cell.rb_num));
        link_rb_blocks(
            sr,
            .{ .num = prev.rb_num, .ptr = prev_rb },
            @enumFromInt(next_num),
        );
    } else {
        assert(location.range.start == 0);
        assert(start_survives);
        assert(next_num != 0);
        sr.rb_at(@enumFromInt(next_num)).prev = 0;
    }

    const parent = location.path[location.path_len - 1];
    const parent_is_header =
        parent.first_is_header and parent.rank == 0;
    const parent_survives =
        start_survives or parent_is_header or
        parent.slot_start_abs != location.range.start;
    if (parent_survives) {
        const parent_ib = sr.ib_at(parent.ib_num);
        if (parent_ib.down[parent.rank] == @intFromEnum(cell.rb_num))
            parent_ib.down[parent.rank] = next_num;
    }
    sr.rb_destroy(cell.rb_num);
}

fn remove_tower(
    sr: *SkipRange,
    location: RemoveLocation,
    reach_plan: RemovalReachPlan,
) void {
    var depth = location.path_len;
    while (depth > 0) {
        depth -= 1;
        const frame = location.path[depth];
        const is_header = frame.first_is_header and frame.rank == 0;
        if (is_header or frame.slot_start_abs != location.range.start)
            break;
        if (frame.prev_slot == null) {
            assert(location.range.start == 0);
            assert(!frame.first_is_header and frame.rank == 0);
            continue;
        }
        const parent = if (depth == 0)
            null
        else
            location.path[depth - 1];
        const surviving_parent = if (parent) |candidate| blk: {
            const parent_is_header =
                candidate.first_is_header and candidate.rank == 0;
            if (parent_is_header or
                candidate.slot_start_abs != location.range.start)
            {
                break :blk candidate;
            }
            break :blk null;
        } else null;
        const child_empty = depth >= reach_plan.changed_begin and
            reach_plan.child_reach[depth] == null;
        sr.remove_ib_slot(frame, surviving_parent, child_empty);
    }
}

fn remove_ib_slot(
    sr: *SkipRange,
    frame: RemovePathFrame,
    surviving_parent: ?RemovePathFrame,
    child_empty: bool,
) void {
    const prev_slot = frame.prev_slot.?;
    const ib = sr.ib_at(frame.ib_num);
    const prev_ib = sr.ib_at(prev_slot.ib_num);
    if (prev_slot.is_empty_header) {
        assert(prev_ib.gap[prev_slot.rank] == 0);
        prev_ib.gap[prev_slot.rank] = ib.gap[frame.rank];
        prev_ib.reach[prev_slot.rank] = ib.reach[frame.rank];
        prev_ib.down[prev_slot.rank] = ib.down[frame.rank];
    } else {
        const delta = prev_ib.gap[prev_slot.rank];
        if (!child_empty)
            prev_ib.reach[prev_slot.rank] = @max(
                prev_ib.reach[prev_slot.rank],
                delta + ib.reach[frame.rank],
            );
        if (ib.gap[frame.rank] == 0)
            prev_ib.gap[prev_slot.rank] = 0
        else
            prev_ib.gap[prev_slot.rank] += ib.gap[frame.rank];
    }
    const old_len = ib.len(frame.first_is_header);
    assert(frame.rank < old_len);
    const keep_after = old_len - frame.rank - 1;
    ib.move_slots(frame.rank, frame.rank + 1, keep_after);
    ib.set_end(old_len - 1);

    if (ib.len(frame.first_is_header) != 0) return;
    assert(!frame.first_is_header);
    const next_num = ib.next;
    if (prev_slot.ib_num != frame.ib_num) {
        assert(prev_ib.next == @intFromEnum(frame.ib_num));
        link_ib_blocks(
            sr,
            .{ .num = prev_slot.ib_num, .ptr = prev_ib },
            @enumFromInt(next_num),
        );
    }
    if (surviving_parent) |parent| {
        const parent_ib = sr.ib_at(parent.ib_num);
        if (parent_ib.down[parent.rank] == @intFromEnum(frame.ib_num))
            parent_ib.down[parent.rank] = next_num;
    }
    sr.ib_destroy(frame.ib_num);
}

fn collapse_root(sr: *SkipRange) void {
    while (sr.ib_height > 0) {
        const root = sr.root_ptr();
        if (root.ptr.len(true) != 1 or root.ptr.next != 0)
            return;
        const child_num: Ib.Num = @enumFromInt(root.ptr.down[0]);
        assert(child_num != .null);
        const child = sr.ib_at(child_num);
        assert(child.prev == 0);
        sr.root = child_num;
        sr.ib_height -= 1;
        sr.ib_destroy(root.num);
    }
}

fn scan_rb_max_end_abs(
    sr: *SkipRange,
    view: Rb.View,
    base_abs: BytesInt,
    removed_id: RangeId,
) ?BytesInt {
    var max_end_abs: ?BytesInt = null;
    var it = view.iter();
    while (it.next(sr)) |item| {
        if (item.id == removed_id) continue;
        const end_abs = base_abs + item.start_rel + item.len.value;
        max_end_abs = if (max_end_abs) |max_end|
            @max(max_end, end_abs)
        else
            end_abs;
    }
    return max_end_abs;
}

fn scan_ib_max_end_abs(
    sr: *SkipRange,
    view: Ib.View,
    base_abs: BytesInt,
    changed_frame: RemovePathFrame,
    changed_max_end_abs: ?BytesInt,
) ?BytesInt {
    var max_end_abs: ?BytesInt = null;
    var it = view.iter();
    while (it.next(sr)) |item| {
        const item_changed = item.ib.num == changed_frame.ib_num and
            item.rank == changed_frame.rank;
        const end_abs = if (item_changed)
            changed_max_end_abs orelse continue
        else if (item.first_is_header and item.rank == 0 and item.down == 0)
            continue
        else
            base_abs + item.slot_start_rel + item.reach;
        max_end_abs = if (max_end_abs) |max_end|
            @max(max_end, end_abs)
        else
            end_abs;
    }
    return max_end_abs;
}

const RbScan = struct {
    find: Rb.Find,
    left_max_end_rel: BytesInt,
    right_max_end_rel: BytesInt,
    same_start: bool,
};

fn scan_rb(
    sr: *SkipRange,
    view: Rb.View,
    target_rel: BytesInt,
    comptime need_reach: bool,
) RbScan {
    var left_max_end_rel: BytesInt = 0;
    var right_max_end_rel: BytesInt = 0;
    var found: ?Rb.Find = null;
    var same_start = false;
    var rb = view.head;
    var start_rel: BytesInt = 0;
    var rb_first_is_header = view.first_is_header;
    scan: while (true) {
        var i_begin: Rb.CapInt = 0;
        if (rb_first_is_header) {
            start_rel = rb.ptr.gap[0].value;
            if (target_rel < start_rel) {
                found = .{
                    .rb = rb,
                    .first_is_header = true,
                    .rank = 0,
                    .start_rel = 0,
                    .gap = start_rel,
                };
            }
            i_begin = 1;
        }
        for (i_begin..Rb.capacity) |i_usize| {
            const i: Rb.CapInt = @intCast(i_usize);
            if (!rb.ptr.occupied(rb_first_is_header, i)) break;
            if (view.past_end(start_rel)) break;
            if (need_reach) {
                const end = start_rel + rb.ptr.range_len[i].value;
                if (start_rel < target_rel)
                    left_max_end_rel = @max(left_max_end_rel, end)
                else if (start_rel > target_rel)
                    right_max_end_rel = @max(right_max_end_rel, end);
            }
            const gap: BytesInt = rb.ptr.gap[i].value;
            if (found == null) {
                if (target_rel == start_rel) {
                    found = .{
                        .rb = rb,
                        .first_is_header = rb_first_is_header,
                        .rank = i,
                        .start_rel = start_rel,
                        .gap = gap,
                    };
                    same_start = true;
                    break :scan;
                } else if (gap != 0 and target_rel < start_rel + gap) {
                    found = .{
                        .rb = rb,
                        .first_is_header = rb_first_is_header,
                        .rank = i,
                        .start_rel = start_rel,
                        .gap = gap,
                    };
                } else if (gap == 0 and
                    (i + 1 == Rb.capacity or
                        !rb.ptr.occupied(rb_first_is_header, i + 1)) and
                    rb.ptr.next == 0)
                {
                    found = .{
                        .rb = rb,
                        .first_is_header = rb_first_is_header,
                        .rank = i,
                        .start_rel = start_rel,
                        .gap = gap,
                    };
                }
            }
            if (found != null) {
                if (!need_reach)
                    break :scan;
            }
            start_rel += gap;
        }
        if (view.past_end(start_rel)) break;
        if (rb.ptr.next == 0) break;
        const next_num: Rb.Num = @enumFromInt(rb.ptr.next);
        rb = .{
            .num = next_num,
            .ptr = sr.rb_at(next_num),
        };
        rb_first_is_header = false;
    }
    assert(found != null);
    return .{
        .find = found.?,
        .left_max_end_rel = left_max_end_rel,
        .right_max_end_rel = right_max_end_rel,
        .same_start = same_start,
    };
}

const IbScan = struct {
    find: Ib.Find,
    left_max_end_rel: BytesInt,
    right_max_end_rel: BytesInt,
};

fn scan_ib(
    sr: *SkipRange,
    view: Ib.View,
    target_rel: BytesInt,
    comptime need_reach: bool,
) IbScan {
    var left_max_end_rel: BytesInt = 0;
    var right_max_end_rel: BytesInt = 0;
    var found: ?Ib.Find = null;
    var ib = view.head;
    var leader_start_rel: BytesInt = 0;
    var ib_first_is_header = view.first_is_header;
    scan: while (true) {
        if (ib_first_is_header)
            leader_start_rel = @intCast(ib.ptr.gap[0]);

        for (0..Ib.capacity) |i_usize| {
            const i: Ib.CapInt = @intCast(i_usize);
            if (!ib.ptr.occupied(ib_first_is_header, i)) break;
            const child_is_header = ib_first_is_header and i == 0;
            if (!child_is_header and view.past_end(leader_start_rel)) break;

            const gap: BytesInt = @intCast(ib.ptr.gap[i]);
            const slot_start_rel: BytesInt = if (child_is_header)
                0
            else
                leader_start_rel;
            var chosen = false;
            if (found == null) {
                if (child_is_header and
                    (target_rel < leader_start_rel or
                        (gap == 0 and ib.ptr.down[i] != 0)))
                {
                    found = .{
                        .ib = ib,
                        .first_is_header = true,
                        .rank = 0,
                        .start_rel = 0,
                        .gap = gap,
                    };
                    chosen = true;
                } else if (!child_is_header and
                    target_rel == leader_start_rel)
                {
                    found = .{
                        .ib = ib,
                        .first_is_header = ib_first_is_header,
                        .rank = i,
                        .start_rel = leader_start_rel,
                        .gap = gap,
                    };
                    chosen = true;
                } else if (!child_is_header and
                    (gap == 0 or target_rel < leader_start_rel + gap))
                {
                    found = .{
                        .ib = ib,
                        .first_is_header = ib_first_is_header,
                        .rank = i,
                        .start_rel = leader_start_rel,
                        .gap = gap,
                    };
                    chosen = true;
                }
            }

            if (child_is_header) log.debug(@src(), "scan header", .{
                .view = view,
                .ib = ib,
                .target_rel = target_rel,
                .header = .{
                    .gap = gap,
                    .reach = ib.ptr.reach[i],
                    .down = ib.ptr.down[i],
                },
                .chosen = chosen,
            });

            const header_without_child =
                child_is_header and ib.ptr.down[i] == 0;
            if (need_reach and !chosen and !header_without_child) {
                const end_rel = slot_start_rel +
                    @as(BytesInt, @intCast(ib.ptr.reach[i]));
                if (slot_start_rel < target_rel)
                    left_max_end_rel = @max(left_max_end_rel, end_rel)
                else
                    right_max_end_rel = @max(right_max_end_rel, end_rel);
            }
            if (!need_reach and found != null)
                break :scan;
            if (!child_is_header) leader_start_rel += gap;
        }
        if (view.past_end(leader_start_rel)) break;
        if (ib.ptr.next == 0) break;
        const next_num: Ib.Num = @enumFromInt(ib.ptr.next);
        ib = .{
            .num = next_num,
            .ptr = sr.ib_at(next_num),
        };
        ib_first_is_header = false;
    }
    assert(found != null);
    return .{
        .find = found.?,
        .left_max_end_rel = left_max_end_rel,
        .right_max_end_rel = right_max_end_rel,
    };
}

fn ib_strip_header(ib: Ib.PtrNum) void {
    const old_len = ib.ptr.len(true);
    assert(old_len > 1);
    const keep = old_len - 1;
    @memmove(ib.ptr.gap[0..keep], ib.ptr.gap[1 .. keep + 1]);
    @memmove(ib.ptr.reach[0..keep], ib.ptr.reach[1 .. keep + 1]);
    @memmove(ib.ptr.down[0..keep], ib.ptr.down[1 .. keep + 1]);
    ib.ptr.set_end(keep);
}

fn rb_strip_header(rb: Rb.PtrNum) void {
    const old_len = rb.ptr.len(true);
    assert(old_len > 1);
    const keep = old_len - 1;
    rb.ptr.move_cells(0, 1, keep);
    rb.ptr.set_end(keep);
}

fn ib_spill(
    sr: *SkipRange,
    gpa: Allocator,
    ib: Ib.PtrNum,
    first_is_header: bool,
    insert_rank: Ib.CapInt,
    prev_gap: BytesInt,
    prev_reach: BytesInt,
    prev_down: u32,
    gap: BytesInt,
    reach: BytesInt,
    down: u32,
) Allocator.Error!Ib.PtrNum {
    // capacity spill only; balance physical occupancy in this layer.
    const old_len = ib.ptr.len(first_is_header);
    assert(old_len == Ib.capacity);
    assert(insert_rank > 0 and insert_rank <= old_len);

    const spill = try sr.ib_create(gpa);
    link_ib_blocks(sr, spill, @enumFromInt(ib.ptr.next));
    ib.ptr.gap[insert_rank - 1] = @intCast(prev_gap);
    ib.ptr.reach[insert_rank - 1] = @intCast(prev_reach);
    ib.ptr.down[insert_rank - 1] = prev_down;

    const left_len: Ib.CapInt = ib_spill_fill;
    if (insert_rank < left_len) {
        spill.ptr.copy_slots(0, ib.ptr, left_len - 1, old_len - (left_len - 1));
        ib.ptr.move_slots(
            insert_rank + 1,
            insert_rank,
            left_len - 1 - insert_rank,
        );
        ib.ptr.gap[insert_rank] = @intCast(gap);
        ib.ptr.reach[insert_rank] = @intCast(reach);
        ib.ptr.down[insert_rank] = down;
    } else {
        const right_rank = insert_rank - left_len;
        spill.ptr.copy_slots(0, ib.ptr, left_len, right_rank);
        spill.ptr.gap[right_rank] = @intCast(gap);
        spill.ptr.reach[right_rank] = @intCast(reach);
        spill.ptr.down[right_rank] = down;
        spill.ptr.copy_slots(
            right_rank + 1,
            ib.ptr,
            insert_rank,
            old_len - insert_rank,
        );
    }

    ib.ptr.set_end(left_len);
    spill.ptr.set_end(left_len);
    link_ib_blocks(sr, ib, spill.num);
    return spill;
}

fn rb_spill(
    sr: *SkipRange,
    gpa: Allocator,
    rb: Rb.PtrNum,
    first_is_header: bool,
    insert_rank: Rb.CapInt,
    prev_gap: BytesInt,
    range: Range,
    id: RangeId,
    gap: BytesInt,
) Allocator.Error!Rb.Num {
    // capacity spill only; balance physical occupancy in this layer.
    const old_len = rb.ptr.len(first_is_header);
    assert(old_len == Rb.capacity);
    assert(insert_rank > 0 and insert_rank <= old_len);

    const spill = try sr.rb_create(gpa);
    link_rb_blocks(sr, spill, @enumFromInt(rb.ptr.next));
    rb.ptr.gap[insert_rank - 1].value = prev_gap;

    const left_len: Rb.CapInt = (Rb.capacity + 1) / 2;
    if (insert_rank < left_len) {
        spill.ptr.copy_cells(0, rb.ptr, left_len - 1, old_len - (left_len - 1));
        rb.ptr.move_cells(
            insert_rank + 1,
            insert_rank,
            left_len - 1 - insert_rank,
        );
        rb.ptr.set(insert_rank, range, id, gap);
    } else {
        const right_rank = insert_rank - left_len;
        spill.ptr.copy_cells(0, rb.ptr, left_len, right_rank);
        spill.ptr.set(right_rank, range, id, gap);
        spill.ptr.copy_cells(
            right_rank + 1,
            rb.ptr,
            insert_rank,
            old_len - insert_rank,
        );
    }

    rb.ptr.set_end(left_len);
    spill.ptr.set_end(left_len);
    sr.reindex_moved_rb_cells(spill, id);
    link_rb_blocks(sr, rb, spill.num);
    if (insert_rank < left_len) return rb.num;
    return spill.num;
}

fn rb_copy_suffix(
    dst: Rb.PtrNum,
    src: Rb.PtrNum,
    src_cell_begin: Rb.CapInt,
    dst_cell_begin: Rb.CapInt,
    src_first_is_header: bool,
) void {
    const src_len = src.ptr.len(src_first_is_header);
    const moved = src_len - src_cell_begin;
    dst.ptr.copy_cells(dst_cell_begin, src.ptr, src_cell_begin, moved);
    dst.ptr.set_end(dst_cell_begin + moved);
}

const OwnerCounts = struct {
    next: u8 = 0,
    down: u8 = 0,
    active: bool = false,
    seen: bool = false,
    free: bool = false,
};

fn expect_valid(sr: *SkipRange) !void {
    if (sr.root == .null) {
        try std.testing.expectEqual(@as(RangeInt, 0), sr.range_count);
        try std.testing.expectEqual(@as(usize, 0), sr.id_index.count());
        return;
    }

    const gpa = std.testing.allocator;
    const ib_counts = try gpa.alloc(OwnerCounts, sr.ibs.segm_list.len + 1);
    defer gpa.free(ib_counts);
    @memset(ib_counts, .{});

    const rb_counts = try gpa.alloc(OwnerCounts, sr.rbs.segm_list.len + 1);
    defer gpa.free(rb_counts);
    @memset(rb_counts, .{});

    var ranges: RangeInt = 0;
    _ = try sr.expect_valid_ib(
        .{
            .head = sr.root_ptr(),
            .first_is_header = true,
            .end_rel = null,
        },
        0,
        sr.ib_height + 1,
        &ranges,
        ib_counts,
        rb_counts,
    );
    try std.testing.expectEqual(sr.range_count, ranges);
    try std.testing.expectEqual(
        @as(usize, sr.range_count),
        sr.id_index.count(),
    );

    var free_ib = sr.ibs.freeHead();
    while (free_ib) |num| {
        const idx = num.to_int() + 1;
        try std.testing.expect(!ib_counts[idx].free);
        ib_counts[idx].free = true;
        free_ib = sr.ibs.freeNext(num);
    }
    var free_rb = sr.rbs.freeHead();
    while (free_rb) |num| {
        const idx = num.to_int() + 1;
        try std.testing.expect(!rb_counts[idx].free);
        rb_counts[idx].free = true;
        free_rb = sr.rbs.freeNext(num);
    }

    const root_idx = @intFromEnum(sr.root);
    for (ib_counts[1 .. sr.ibs.segm_list.len + 1], 1..) |counts, ib_idx| {
        if (counts.free) {
            try std.testing.expect(!counts.seen);
            try std.testing.expectEqual(
                @as(u8, 0),
                counts.next + counts.down,
            );
            continue;
        }
        try std.testing.expect(counts.seen);
        const owners = counts.next + counts.down;
        if (ib_idx == root_idx)
            try std.testing.expectEqual(@as(u8, 0), owners)
        else
            try std.testing.expectEqual(@as(u8, 1), owners);
        const ib_num: Ib.Num = @enumFromInt(ib_idx);
        const ib = sr.ib_at_const(ib_num);
        if (ib.next != 0) {
            try std.testing.expect(!ib_counts[ib.next].free);
            try std.testing.expectEqual(
                @as(u32, @intCast(ib_idx)),
                sr.ib_at_const(@enumFromInt(ib.next)).prev,
            );
        }
        if (ib.prev != 0) {
            try std.testing.expect(!ib_counts[ib.prev].free);
            try std.testing.expectEqual(
                @as(u32, @intCast(ib_idx)),
                sr.ib_at_const(@enumFromInt(ib.prev)).next,
            );
        }
    }
    for (rb_counts[1 .. sr.rbs.segm_list.len + 1], 1..) |counts, rb_idx| {
        if (counts.free) {
            try std.testing.expect(!counts.seen);
            try std.testing.expectEqual(
                @as(u8, 0),
                counts.next + counts.down,
            );
            continue;
        }
        try std.testing.expect(counts.seen);
        try std.testing.expectEqual(@as(u8, 1), counts.next + counts.down);
        const rb_num: Rb.Num = @enumFromInt(rb_idx);
        const rb = sr.rb_at_const(rb_num);
        if (rb.next != 0) {
            try std.testing.expect(!rb_counts[rb.next].free);
            try std.testing.expectEqual(
                @as(u32, @intCast(rb_idx)),
                sr.rb_at_const(@enumFromInt(rb.next)).prev,
            );
        }
        if (rb.prev != 0) {
            try std.testing.expect(!rb_counts[rb.prev].free);
            try std.testing.expectEqual(
                @as(u32, @intCast(rb_idx)),
                sr.rb_at_const(@enumFromInt(rb.prev)).next,
            );
        }
    }
}

fn expect_valid_ib(
    sr: *SkipRange,
    view: Ib.View,
    base_abs: BytesInt,
    h_cur: HeightInt,
    ranges: *RangeInt,
    ib_counts: []OwnerCounts,
    rb_counts: []OwnerCounts,
) !BytesInt {
    const gpa = std.testing.allocator;
    var active_ibs: std.ArrayList(usize) = .empty;
    defer {
        for (active_ibs.items) |ib_idx|
            ib_counts[ib_idx].active = false;
        active_ibs.deinit(gpa);
    }

    var max_end_abs: BytesInt = base_abs;
    var prev_leader_start_abs: ?BytesInt = null;
    var prev_ib: Ib.Num = .null;
    var it = view.iter();
    while (it.next(sr)) |item| {
        const ib_idx = @as(usize, @intFromEnum(item.ib.num));
        const slot_start_abs = base_abs + item.slot_start_rel;
        const child_is_header = item.first_is_header and item.rank == 0;
        if (!child_is_header) {
            if (prev_leader_start_abs) |prev_abs|
                try std.testing.expect(prev_abs < slot_start_abs);
            prev_leader_start_abs = slot_start_abs;
        }
        if (item.ib.num != prev_ib) {
            try std.testing.expect(!ib_counts[ib_idx].active);
            try std.testing.expect(!ib_counts[ib_idx].seen);
            try active_ibs.append(gpa, ib_idx);
            ib_counts[ib_idx].active = true;
            ib_counts[ib_idx].seen = true;
            if (prev_ib != .null) {
                ib_counts[ib_idx].next += 1;
                try std.testing.expect(ib_counts[ib_idx].next <= 1);
            }
            prev_ib = item.ib.num;
        }

        const gap = item.gap;
        const next_start_abs = if (child_is_header or gap != 0)
            slot_start_abs + gap
        else
            null;
        const has_next_in_subtree = if (next_start_abs) |next_abs|
            if (view.end_rel) |end_rel| next_abs < base_abs + end_rel else true
        else
            false;
        if (child_is_header) {
            if (item.down == 0)
                try std.testing.expectEqual(@as(BytesInt, 0), gap);
            if (view.end_rel) |end_rel|
                try std.testing.expect(
                    slot_start_abs + gap <= base_abs + end_rel,
                );
        } else {
            try std.testing.expect(item.down != 0);
            if (has_next_in_subtree)
                try std.testing.expect(gap > 0)
            else if (view.end_rel) |end_rel|
                try std.testing.expect(
                    gap == 0 or
                        gap == base_abs + end_rel - slot_start_abs,
                )
            else
                try std.testing.expectEqual(@as(BytesInt, 0), gap);
        }

        if (item.down != 0) {
            if (h_cur == 1) {
                const rb_num: Rb.Num = @enumFromInt(item.down);
                rb_counts[@intFromEnum(rb_num)].down += 1;
                try std.testing.expect(
                    rb_counts[@intFromEnum(rb_num)].down <= 1,
                );
            } else {
                const child_num: Ib.Num = @enumFromInt(item.down);
                ib_counts[@intFromEnum(child_num)].down += 1;
                try std.testing.expect(
                    ib_counts[@intFromEnum(child_num)].down <= 1,
                );
            }
        }

        const child_base_abs = if (child_is_header)
            base_abs
        else
            slot_start_abs;
        const child_end_rel = slot_child_end_rel(
            view.end_rel,
            item.slot_start_rel,
            gap,
        );
        const child_view_end_rel = if (child_end_rel) |end_rel|
            end_rel - (child_base_abs - base_abs)
        else
            null;
        const child_end_abs = if (child_is_header and item.down == 0) blk: {
            try std.testing.expectEqual(@as(BytesInt, 0), gap);
            break :blk child_base_abs;
        } else if (h_cur == 1) blk: {
            const rb_num: Rb.Num = @enumFromInt(item.down);
            const rb: Rb.PtrNum = .{
                .num = rb_num,
                .ptr = sr.rb_at(rb_num),
            };
            const child_first_abs = if (child_is_header)
                child_base_abs + rb.ptr.gap[0].value
            else
                child_base_abs;
            if (child_is_header)
                try std.testing.expect(child_first_abs >= slot_start_abs)
            else
                try std.testing.expectEqual(slot_start_abs, child_first_abs);
            if (child_view_end_rel) |end_rel|
                if (child_is_header)
                    try std.testing.expect(
                        child_first_abs <= child_base_abs + end_rel,
                    )
                else
                    try std.testing.expect(
                        child_first_abs < child_base_abs + end_rel,
                    );
            break :blk try sr.expect_valid_rb(
                .{
                    .head = rb,
                    .first_is_header = child_is_header,
                    .end_rel = child_view_end_rel,
                },
                child_base_abs,
                ranges,
                rb_counts,
            );
        } else blk: {
            const child_num: Ib.Num = @enumFromInt(item.down);
            const child: Ib.PtrNum = .{
                .num = child_num,
                .ptr = sr.ib_at(child_num),
            };
            const child_first_abs = if (child_is_header)
                child_base_abs + @as(BytesInt, @intCast(child.ptr.gap[0]))
            else
                child_base_abs;
            if (child_is_header)
                try std.testing.expect(child_first_abs >= slot_start_abs)
            else
                try std.testing.expectEqual(slot_start_abs, child_first_abs);
            if (child_view_end_rel) |end_rel|
                if (child_is_header)
                    try std.testing.expect(
                        child_first_abs <= child_base_abs + end_rel,
                    )
                else
                    try std.testing.expect(
                        child_first_abs < child_base_abs + end_rel,
                    );
            break :blk try sr.expect_valid_ib(
                .{
                    .head = child,
                    .first_is_header = child_is_header,
                    .end_rel = child_view_end_rel,
                },
                child_base_abs,
                h_cur - 1,
                ranges,
                ib_counts,
                rb_counts,
            );
        };
        if (child_end_abs - slot_start_abs != item.reach) {
            log.debug(@src(), "bad reach", .{
                .height = h_cur,
                .base_abs = base_abs,
                .item = item,
                .actual = child_end_abs - slot_start_abs,
            });
        }
        try std.testing.expectEqual(child_end_abs - slot_start_abs, item.reach);
        max_end_abs = @max(max_end_abs, child_end_abs);
    }
    return max_end_abs;
}

fn expect_valid_rb(
    sr: *SkipRange,
    view: Rb.View,
    base_abs: BytesInt,
    ranges: *RangeInt,
    rb_counts: []OwnerCounts,
) !BytesInt {
    const gpa = std.testing.allocator;
    var active_rbs: std.ArrayList(usize) = .empty;
    defer {
        for (active_rbs.items) |rb_idx|
            rb_counts[rb_idx].active = false;
        active_rbs.deinit(gpa);
    }

    var max_end_abs: BytesInt = base_abs;
    var prev_start_abs: ?BytesInt = null;
    var prev_rb = view.head.num;
    const head_idx = @as(usize, @intFromEnum(prev_rb));
    try std.testing.expect(!rb_counts[head_idx].active);
    try std.testing.expect(!rb_counts[head_idx].seen);
    try active_rbs.append(gpa, head_idx);
    rb_counts[head_idx].active = true;
    rb_counts[head_idx].seen = true;
    var it = view.iter();
    if (view.first_is_header) {
        try std.testing.expectEqual(@as(u32, 0), view.head.ptr.id[0]);
        try std.testing.expectEqual(
            @as(BytesInt, 0),
            view.head.ptr.range_len[0].value,
        );
    }
    var item_opt = it.next(sr);
    while (item_opt) |item| {
        const next_item = it.next(sr);
        const start_abs = base_abs + item.start_rel;
        const rb_idx = @as(usize, @intFromEnum(item.rb.num));
        if (item.rb.num != prev_rb) {
            try std.testing.expect(!rb_counts[rb_idx].active);
            try std.testing.expect(!rb_counts[rb_idx].seen);
            try active_rbs.append(gpa, rb_idx);
            rb_counts[rb_idx].active = true;
            rb_counts[rb_idx].seen = true;
            rb_counts[rb_idx].next += 1;
            try std.testing.expect(rb_counts[rb_idx].next <= 1);
            prev_rb = item.rb.num;
        }
        try std.testing.expect(item.id != .null);
        const indexed = sr.id_index.get(item.id) orelse
            return error.MissingIdIndexEntry;
        try std.testing.expectEqual(item.rb.num, indexed.rb_num);
        if (start_abs != indexed.start_abs) {
            log.err(@src(), "bad ID index start", .{
                .item = item,
                .base_abs = base_abs,
                .start_abs = start_abs,
                .indexed = indexed,
            });
        }
        try std.testing.expectEqual(start_abs, indexed.start_abs);

        if (prev_start_abs) |prev_abs|
            try std.testing.expect(prev_abs <= start_abs);

        if (next_item) |next|
            try std.testing.expectEqual(
                next.start_rel - item.start_rel,
                item.gap,
            )
        else if (view.end_rel) |end_rel| {
            const gap_to_view_end = base_abs + end_rel - start_abs;
            if (item.rb.ptr.next != 0)
                try std.testing.expectEqual(gap_to_view_end, item.gap)
            else
                try std.testing.expect(
                    item.gap == 0 or item.gap == gap_to_view_end,
                );
        } else try std.testing.expectEqual(@as(BytesInt, 0), item.gap);

        max_end_abs = @max(max_end_abs, start_abs + item.len.value);
        ranges.* += 1;

        prev_start_abs = start_abs;
        item_opt = next_item;
    }
    return max_end_abs;
}

const DebugRange = struct {
    start: BytesInt,
    end: BytesInt,
    id: RangeId,
    payload: u32,
    flags: RangeFlags,
};

fn debug_collect(
    sr: *SkipRange,
    gpa: Allocator,
) Allocator.Error![]DebugRange {
    var out: std.ArrayList(DebugRange) = .empty;
    defer out.deinit(gpa);

    if (sr.root == .null) return try out.toOwnedSlice(gpa);

    try sr.debug_collect_ib_chain(gpa, &out, .{
        .head = sr.root_ptr(),
        .first_is_header = true,
        .end_rel = null,
    }, 0, sr.ib_height + 1);

    return try out.toOwnedSlice(gpa);
}

fn debug_collect_ib_chain(
    sr: *SkipRange,
    gpa: Allocator,
    out: *std.ArrayList(DebugRange),
    view: Ib.View,
    base_abs: BytesInt,
    h_cur: HeightInt,
) Allocator.Error!void {
    var it = view.iter();
    while (it.next(sr)) |item| {
        const slot_start_abs = base_abs + item.slot_start_rel;
        const child_is_header = item.first_is_header and item.rank == 0;
        const child_base_abs = if (child_is_header)
            base_abs
        else
            slot_start_abs;
        const child_end_rel = slot_child_end_rel(
            view.end_rel,
            item.slot_start_rel,
            item.gap,
        );
        const child_view_end_rel = if (child_end_rel) |end_rel|
            end_rel - (child_base_abs - base_abs)
        else
            null;
        if (child_is_header and item.down == 0) {
            assert(item.gap == 0);
            continue;
        }
        if (h_cur == 1) {
            const rb_num: Rb.Num = @enumFromInt(item.down);
            try sr.debug_collect_rb_chain(gpa, out, .{
                .head = .{
                    .num = rb_num,
                    .ptr = sr.rb_at(rb_num),
                },
                .first_is_header = child_is_header,
                .end_rel = child_view_end_rel,
            }, child_base_abs);
        } else {
            const child_num: Ib.Num = @enumFromInt(item.down);
            try sr.debug_collect_ib_chain(gpa, out, .{
                .head = .{
                    .num = child_num,
                    .ptr = sr.ib_at(child_num),
                },
                .first_is_header = child_is_header,
                .end_rel = child_view_end_rel,
            }, child_base_abs, h_cur - 1);
        }
    }
}

fn debug_collect_rb_chain(
    sr: *SkipRange,
    gpa: Allocator,
    out: *std.ArrayList(DebugRange),
    view: Rb.View,
    base_abs: BytesInt,
) Allocator.Error!void {
    var it = view.iter();
    while (it.next(sr)) |item| {
        const start_abs = base_abs + item.start_rel;
        try out.append(gpa, .{
            .start = start_abs,
            .end = start_abs + item.len.value,
            .id = item.id,
            .payload = item.payload,
            .flags = item.flags,
        });
    }
}

fn expect_debug_matches_oracle(
    sr: *SkipRange,
    oracle: []const DebugRange,
) !void {
    const got = try sr.debug_collect(std.testing.allocator);
    defer std.testing.allocator.free(got);
    const seen = try std.testing.allocator.alloc(bool, oracle.len);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);

    try std.testing.expectEqual(oracle.len, got.len);
    for (got, 0..) |range, i| {
        if (i > 0)
            try std.testing.expect(got[i - 1].start <= range.start);

        const want_idx = for (oracle, 0..) |candidate, candidate_idx| {
            if (candidate.id == range.id) break candidate_idx;
        } else return error.MissingRange;
        if (seen[want_idx]) return error.DuplicateRange;
        seen[want_idx] = true;
        const want = oracle[want_idx];

        try std.testing.expectEqual(want.start, range.start);
        try std.testing.expectEqual(want.end, range.end);
        try std.testing.expectEqual(want.payload, range.payload);
        try std.testing.expectEqual(want.flags, range.flags);
    }
}

const FuzzAgainstRangeOracle = struct {
    const max_live = 3 * Rb.capacity;

    const StartCase = enum(u3) {
        zero,
        peer,
        adjacent,
        fresh_dense,
        fresh_wide,
    };

    const LenCase = enum(u2) {
        zero,
        short,
        long,
    };

    const HeightCase = enum(u2) {
        leaf,
        low,
        tall,
        max,
    };

    const RemoveCase = enum(u2) {
        random,
        oldest_at_start,
        zero_start,
        max_end,
    };

    fn has_start(oracle: []const DebugRange, start: BytesInt) bool {
        for (oracle) |range|
            if (range.start == start) return true;
        return false;
    }

    fn next_fresh_start(
        oracle: []const DebugRange,
        initial: BytesInt,
        max_start: BytesInt,
    ) BytesInt {
        var start = initial;
        for (0..oracle.len + 1) |_| {
            if (!has_start(oracle, start)) return start;
            start = if (start == max_start) 0 else start + 1;
        }
        // Both fresh-start domains contain more values than `max_live`.
        unreachable;
    }

    fn pick_start(
        smith: *std.testing.Smith,
        oracle: []const DebugRange,
    ) BytesInt {
        return switch (smith.valueWeighted(StartCase, &.{
            std.testing.Smith.Weight.value(StartCase, .zero, 4),
            std.testing.Smith.Weight.value(StartCase, .peer, 8),
            std.testing.Smith.Weight.value(StartCase, .adjacent, 4),
            std.testing.Smith.Weight.value(StartCase, .fresh_dense, 5),
            std.testing.Smith.Weight.value(StartCase, .fresh_wide, 2),
        })) {
            .zero => 0,
            .peer => if (oracle.len == 0)
                0
            else
                oracle[smith.index(oracle.len)].start,
            .adjacent => adjacent: {
                if (oracle.len == 0) break :adjacent 0;
                const anchor = oracle[smith.index(oracle.len)].start;
                const after = smith.value(bool);
                if (after and anchor < max_bytes)
                    break :adjacent anchor + 1;
                if (anchor > 0) break :adjacent anchor - 1;
                break :adjacent 1;
            },
            .fresh_dense => next_fresh_start(
                oracle,
                smith.valueRangeAtMost(BytesInt, 0, 255),
                255,
            ),
            .fresh_wide => next_fresh_start(
                oracle,
                smith.valueRangeAtMost(BytesInt, 0, max_bytes),
                max_bytes,
            ),
        };
    }

    fn pick_len(
        smith: *std.testing.Smith,
        max_len: BytesInt,
    ) BytesInt {
        if (max_len == 0) return 0;

        return switch (smith.valueWeighted(LenCase, &.{
            std.testing.Smith.Weight.value(LenCase, .zero, 1),
            std.testing.Smith.Weight.value(LenCase, .short, 8),
            std.testing.Smith.Weight.value(LenCase, .long, 2),
        })) {
            .zero => 0,
            .short => smith.valueRangeAtMost(
                BytesInt,
                1,
                @min(max_len, 16),
            ),
            .long => smith.valueRangeAtMost(
                BytesInt,
                0,
                @min(max_len, 255),
            ),
        };
    }

    fn pick_height(smith: *std.testing.Smith) HeightInt {
        return switch (smith.valueWeighted(HeightCase, &.{
            std.testing.Smith.Weight.value(HeightCase, .leaf, 8),
            std.testing.Smith.Weight.value(HeightCase, .low, 6),
            std.testing.Smith.Weight.value(HeightCase, .tall, 2),
            std.testing.Smith.Weight.value(HeightCase, .max, 1),
        })) {
            .leaf => 0,
            .low => smith.valueRangeAtMost(
                HeightInt,
                0,
                @min(3, max_height),
            ),
            .tall => smith.valueRangeAtMost(
                HeightInt,
                0,
                max_height,
            ),
            .max => max_height,
        };
    }

    fn pick_insert(
        smith: *std.testing.Smith,
        live_count: usize,
    ) bool {
        // Separate call sites let Smith evolve growth, churn, and drain.
        if (live_count == 0) return true;
        if (live_count == max_live) return false;
        if (live_count < Rb.capacity)
            return smith.boolWeighted(1, 9);
        if (live_count < 2 * Rb.capacity)
            return smith.boolWeighted(3, 7);
        return smith.boolWeighted(7, 3);
    }

    fn oldest_at_start(
        oracle: []const DebugRange,
        start: BytesInt,
    ) usize {
        var oldest_idx: ?usize = null;
        for (oracle, 0..) |candidate, candidate_idx| {
            if (candidate.start != start) continue;
            if (oldest_idx) |idx| {
                if (@intFromEnum(candidate.id) >=
                    @intFromEnum(oracle[idx].id))
                {
                    continue;
                }
            }
            oldest_idx = candidate_idx;
        }
        return oldest_idx.?;
    }

    fn pick_remove_index(
        smith: *std.testing.Smith,
        oracle: []const DebugRange,
    ) usize {
        return switch (smith.valueWeighted(RemoveCase, &.{
            std.testing.Smith.Weight.value(RemoveCase, .random, 5),
            std.testing.Smith.Weight.value(
                RemoveCase,
                .oldest_at_start,
                4,
            ),
            std.testing.Smith.Weight.value(RemoveCase, .zero_start, 4),
            std.testing.Smith.Weight.value(RemoveCase, .max_end, 4),
        })) {
            .random => smith.index(oracle.len),
            .oldest_at_start => oldest: {
                const anchor = oracle[smith.index(oracle.len)];
                break :oldest oldest_at_start(oracle, anchor.start);
            },
            .zero_start => zero: {
                for (oracle) |candidate|
                    if (candidate.start == 0)
                        break :zero oldest_at_start(oracle, 0);
                break :zero smith.index(oracle.len);
            },
            .max_end => max: {
                var max_idx: usize = 0;
                for (oracle[1..], 1..) |candidate, candidate_idx| {
                    if (candidate.end > oracle[max_idx].end) {
                        max_idx = candidate_idx;
                    }
                }
                break :max max_idx;
            },
        };
    }

    fn test_one(_: void, smith: *std.testing.Smith) !void {
        const gpa = std.testing.allocator;
        var sr: SkipRange = .empty;
        defer sr.deinit(gpa);

        var oracle: std.ArrayList(DebugRange) = .empty;
        defer oracle.deinit(gpa);

        var operation_count: usize = 0;
        while (!smith.eosWeightedSimple(127, 1)) {
            const insert_range = pick_insert(smith, oracle.items.len);
            if (insert_range) {
                const start = pick_start(smith, oracle.items);
                const len = pick_len(smith, max_bytes - start);
                const range: Range = .{
                    .start = start,
                    .end = start + len,
                    .payload = @truncate(operation_count),
                    .flags = .{
                        .start_right = smith.value(bool),
                        .end_right = smith.value(bool),
                    },
                };
                // Same-start promotion is suppressed; skip that inert input.
                const height = if (has_start(oracle.items, start))
                    0
                else
                    pick_height(smith);
                const id = try sr.insert_with_height(
                    gpa,
                    range,
                    height,
                );
                try oracle.append(gpa, .{
                    .start = range.start,
                    .end = range.end,
                    .id = id,
                    .payload = range.payload,
                    .flags = range.flags,
                });
                try std.testing.expectEqual(range, sr.get(id).?);
            } else {
                const remove_idx = pick_remove_index(
                    smith,
                    oracle.items,
                );
                const want = oracle.swapRemove(remove_idx);
                const removed = sr.remove(want.id) orelse
                    return error.MissingRange;
                try std.testing.expectEqual(want.start, removed.start);
                try std.testing.expectEqual(want.end, removed.end);
                try std.testing.expectEqual(want.payload, removed.payload);
                try std.testing.expectEqual(want.flags, removed.flags);
                try std.testing.expect(sr.get(want.id) == null);
            }
            operation_count += 1;
        }

        try sr.expect_valid();
        try sr.expect_debug_matches_oracle(oracle.items);
    }
};

test "skiprange: fuzz against range oracle" {
    try std.testing.fuzz({}, FuzzAgainstRangeOracle.test_one, .{});
}

test "skiprange: first insert round-trips range" {
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);
    sr.rng = .init(std.testing.random_seed);

    const id = try sr.insert(std.testing.allocator, .{
        .start = 10,
        .end = 14,
        .payload = 7,
    });

    try sr.expect_valid();
    const got = try sr.debug_collect(std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(BytesInt, 10), got[0].start);
    try std.testing.expectEqual(@as(BytesInt, 14), got[0].end);
    try std.testing.expectEqual(id, got[0].id);
    try std.testing.expectEqual(@as(u32, 7), got[0].payload);
}

test "skiprange: ids survive removal churn" {
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);

    const first: Range = .{ .start = 10, .end = 14, .payload = 1 };
    const second: Range = .{ .start = 20, .end = 25, .payload = 2 };
    const first_id = try sr.insert_with_height(
        std.testing.allocator,
        first,
        2,
    );
    const second_id = try sr.insert_with_height(
        std.testing.allocator,
        second,
        2,
    );

    try std.testing.expectEqual(first, sr.get(first_id).?);
    try std.testing.expectEqual(second, sr.remove(second_id).?);
    try std.testing.expect(sr.get(second_id) == null);
    try sr.expect_valid();

    const third: Range = .{ .start = 30, .end = 36, .payload = 3 };
    const third_id = try sr.insert_with_height(
        std.testing.allocator,
        third,
        2,
    );
    try std.testing.expect(@intFromEnum(third_id) > @intFromEnum(second_id));
    try std.testing.expectEqual(first, sr.remove(first_id).?);
    try std.testing.expectEqual(third, sr.remove(third_id).?);
    try std.testing.expectEqual(@as(RangeInt, 0), sr.range_count);
    try std.testing.expectEqual(Ib.Num.null, sr.root);
    try std.testing.expect(sr.get(.null) == null);
    try std.testing.expect(sr.remove(.null) == null);

    const fourth: Range = .{ .start = 5, .end = 8, .payload = 4 };
    const fourth_id = try sr.insert_with_height(
        std.testing.allocator,
        fourth,
        0,
    );
    try std.testing.expect(@intFromEnum(fourth_id) > @intFromEnum(third_id));
    try std.testing.expectEqual(fourth, sr.remove(fourth_id).?);

    sr.next_id = @as(u64, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(
        error.RangeIdExhausted,
        sr.insert_with_height(
            std.testing.allocator,
            .{ .start = 40, .end = 41, .payload = 4 },
            0,
        ),
    );
}

test "skiprange: same-start removal keeps its tower" {
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);

    const leader_id = try sr.insert_with_height(
        std.testing.allocator,
        .{ .start = 10, .end = 14, .payload = 1 },
        3,
    );
    const peer: Range = .{ .start = 10, .end = 18, .payload = 2 };
    const peer_id = try sr.insert_with_height(
        std.testing.allocator,
        peer,
        3,
    );
    _ = try sr.insert_with_height(
        std.testing.allocator,
        .{ .start = 30, .end = 31, .payload = 3 },
        3,
    );

    _ = sr.remove(leader_id).?;
    try std.testing.expectEqual(peer, sr.get(peer_id).?);
    try sr.expect_valid();
}

test "skiprange: start zero peer keeps rank zero real" {
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);

    const leader_id = try sr.insert_with_height(
        std.testing.allocator,
        .{ .start = 0, .end = 17, .payload = 1 },
        3,
    );
    const peer: Range = .{ .start = 0, .end = 9, .payload = 2 };
    const peer_id = try sr.insert_with_height(
        std.testing.allocator,
        peer,
        0,
    );
    const next: Range = .{ .start = 2, .end = 5, .payload = 3 };
    const next_id = try sr.insert_with_height(
        std.testing.allocator,
        next,
        3,
    );

    const leader_entry = sr.id_index.get(leader_id).?;
    const leader_rb = sr.rb_at_const(leader_entry.rb_num);
    try std.testing.expectEqual(
        @as(Rb.CapInt, 0),
        id_rank_in_rb(leader_rb, leader_id),
    );

    _ = sr.remove(leader_id).?;
    try std.testing.expectEqual(peer, sr.get(peer_id).?);
    try std.testing.expectEqual(next, sr.get(next_id).?);
    try sr.expect_valid();
}

test "skiprange: removing start zero transfers header ownership" {
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);

    const zero_id = try sr.insert_with_height(
        std.testing.allocator,
        .{ .start = 0, .end = 4, .payload = 1 },
        3,
    );
    const kept: Range = .{ .start = 10, .end = 14, .payload = 2 };
    const kept_id = try sr.insert_with_height(
        std.testing.allocator,
        kept,
        0,
    );

    _ = sr.remove(zero_id).?;
    try std.testing.expectEqual(kept, sr.get(kept_id).?);
    try sr.expect_valid();

    const appended: Range = .{ .start = 20, .end = 22, .payload = 3 };
    const appended_id = try sr.insert_with_height(
        std.testing.allocator,
        appended,
        2,
    );
    try std.testing.expectEqual(appended, sr.get(appended_id).?);
    try sr.expect_valid();
}

test "skiprange: explicit towers suppress same-start promotion" {
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);

    const cases = [_]struct {
        start: BytesInt,
        end: BytesInt,
        height: HeightInt,
        want_ib_height: HeightInt,
    }{
        .{ .start = 10, .end = 14, .height = 0, .want_ib_height = 0 },
        .{ .start = 20, .end = 25, .height = 2, .want_ib_height = 1 },
        .{ .start = 30, .end = 36, .height = 2, .want_ib_height = 1 },
        .{ .start = 30, .end = 38, .height = 2, .want_ib_height = 1 },
    };
    var oracle: [cases.len]DebugRange = undefined;

    for (cases, 0..) |case, i| {
        const range: Range = .{
            .start = case.start,
            .end = case.end,
            .payload = @intCast(i),
        };
        const id = try sr.insert_with_height(
            std.testing.allocator,
            range,
            case.height,
        );
        oracle[i] = .{
            .start = range.start,
            .end = range.end,
            .id = id,
            .payload = range.payload,
            .flags = range.flags,
        };
        try sr.expect_valid();
        try std.testing.expectEqual(case.want_ib_height, sr.ib_height);
    }

    try sr.expect_debug_matches_oracle(&oracle);
}

test "skiprange: descending max-height inserts match block model" {
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);

    const range_count = 100;
    const height: HeightInt = 3;
    for (0..range_count) |i| {
        const start: BytesInt = @intCast(range_count - i);
        _ = try sr.insert_with_height(
            std.testing.allocator,
            .{ .start = start, .end = start + 1, .payload = @intCast(i) },
            height,
        );
    }

    const rb_count = range_count + 1;
    const ib_count =
        (@as(usize, height) - 1) * rb_count + rb_count / ib_spill_fill;
    try std.testing.expectEqual(rb_count, sr.rbs.segm_list.len);
    try std.testing.expectEqual(ib_count, sr.ibs.segm_list.len);
    try sr.expect_valid();
}

test "skiprange: random inserts match range oracle" {
    var data_prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = data_prng.random();
    const insert_count = 256;
    const check_interval = 16;

    for (0..4) |run| {
        var sr: SkipRange = .empty;
        defer sr.deinit(std.testing.allocator);
        sr.rng = .init(std.testing.random_seed +% @as(u32, @intCast(run)));

        var oracle: std.ArrayList(DebugRange) = .empty;
        defer oracle.deinit(std.testing.allocator);

        for (0..insert_count) |i| {
            const start = rand.uintAtMost(BytesInt, 255);
            const len = rand.uintAtMost(BytesInt, 63);
            const range: Range = .{
                .start = start,
                .end = start + len,
                .payload = @intCast(i),
                .flags = .{
                    .start_right = rand.boolean(),
                    .end_right = rand.boolean(),
                },
            };
            const id = try sr.insert(std.testing.allocator, range);
            try oracle.append(std.testing.allocator, .{
                .start = range.start,
                .end = range.end,
                .id = id,
                .payload = range.payload,
                .flags = range.flags,
            });

            const inserted = i + 1;
            if (inserted % check_interval == 0 and inserted < insert_count) {
                try sr.expect_valid();
                try sr.expect_debug_matches_oracle(oracle.items);
            }
        }
        try sr.expect_valid();
        try sr.expect_debug_matches_oracle(oracle.items);
    }
}

test "skiprange: random id churn matches range oracle" {
    var data_prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = data_prng.random();
    const operation_count = 1_024;
    const max_live = 256;
    const min_live = max_live / 2;
    const check_interval = 16;

    for (0..4) |run| {
        var sr: SkipRange = .empty;
        defer sr.deinit(std.testing.allocator);
        sr.rng = .init(std.testing.random_seed +% @as(u32, @intCast(run)));

        var oracle: std.ArrayList(DebugRange) = .empty;
        defer oracle.deinit(std.testing.allocator);

        var mutation: DebugRange = undefined;
        for (0..operation_count) |operation| {
            const insert_range =
                oracle.items.len < min_live or
                (oracle.items.len < max_live and rand.boolean());
            if (insert_range) {
                const start = rand.uintAtMost(BytesInt, 255);
                const len = rand.uintAtMost(BytesInt, 63);
                const range: Range = .{
                    .start = start,
                    .end = start + len,
                    .payload = rand.int(u32),
                    .flags = .{
                        .start_right = rand.boolean(),
                        .end_right = rand.boolean(),
                    },
                };
                const height = rand.uintAtMost(HeightInt, 3);
                const id = try sr.insert_with_height(
                    std.testing.allocator,
                    range,
                    height,
                );
                mutation = .{
                    .start = range.start,
                    .end = range.end,
                    .id = id,
                    .payload = range.payload,
                    .flags = range.flags,
                };
                try oracle.append(std.testing.allocator, mutation);
                try std.testing.expectEqual(range, sr.get(id).?);
            } else {
                const remove_idx = rand.uintLessThan(
                    usize,
                    oracle.items.len,
                );
                const want = oracle.swapRemove(remove_idx);
                mutation = want;
                const removed = sr.remove(want.id) orelse {
                    const got = try sr.debug_collect(std.testing.allocator);
                    defer std.testing.allocator.free(got);
                    log.err(@src(), "oracle range missing", .{
                        .run = run,
                        .operation = operation,
                        .want = want,
                        .got = got,
                    });
                    return error.MissingRange;
                };
                try std.testing.expectEqual(want.start, removed.start);
                try std.testing.expectEqual(want.end, removed.end);
                try std.testing.expectEqual(want.payload, removed.payload);
                try std.testing.expectEqual(want.flags, removed.flags);
                try std.testing.expect(sr.get(want.id) == null);
            }

            if ((operation + 1) % check_interval == 0) {
                sr.expect_valid() catch |err| {
                    const got = try sr.debug_collect(std.testing.allocator);
                    defer std.testing.allocator.free(got);
                    log.err(@src(), "churn validation failed", .{
                        .run = run,
                        .operation = operation,
                        .insert = insert_range,
                        .mutation = mutation,
                        .oracle = oracle.items,
                        .got = got,
                    });
                    return err;
                };
                try sr.expect_debug_matches_oracle(oracle.items);
            }
        }
        try sr.expect_valid();
        try sr.expect_debug_matches_oracle(oracle.items);
    }
}

test "skiprange: deletion sweeps reclaim spilled towers" {
    const range_count = 96;

    for (0..2) |pass| {
        var sr: SkipRange = .empty;
        defer sr.deinit(std.testing.allocator);

        var ids: [range_count]RangeId = undefined;
        var ranges: [range_count]Range = undefined;
        for (&ids, &ranges, 0..) |*id, *range, i| {
            const start: BytesInt = @intCast(i * 3);
            range.* = .{
                .start = start,
                .end = start + @as(BytesInt, @intCast(i % 17)),
                .payload = @intCast(i),
            };
            id.* = try sr.insert_with_height(
                std.testing.allocator,
                range.*,
                @intCast(i % 4),
            );
        }
        try sr.expect_valid();

        for (0..range_count) |step| {
            const i = if (pass == 0)
                step
            else
                range_count - step - 1;
            try std.testing.expectEqual(ranges[i], sr.remove(ids[i]).?);
            try sr.expect_valid();
        }

        try std.testing.expectEqual(Ib.Num.null, sr.root);
        try std.testing.expectEqual(@as(usize, 0), sr.ibs.segm_list.len);
        try std.testing.expectEqual(@as(usize, 0), sr.rbs.segm_list.len);
    }
}

test "skiprange: same-start ranges survive leaf spills" {
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);

    var oracle: std.ArrayList(DebugRange) = .empty;
    defer oracle.deinit(std.testing.allocator);

    for (0..3 * Rb.capacity) |i| {
        const range: Range = .{
            .start = 10,
            .end = 11 + @as(BytesInt, @intCast(i % 7)),
            .payload = @intCast(i),
        };
        const id = try sr.insert_with_height(std.testing.allocator, range, 0);
        try oracle.append(std.testing.allocator, .{
            .start = range.start,
            .end = range.end,
            .id = id,
            .payload = range.payload,
            .flags = range.flags,
        });
    }

    try sr.expect_valid();
    try sr.expect_debug_matches_oracle(oracle.items);
}

test "skiprange: same-start deletion reclaims leaf spills" {
    const range_count = 3 * Rb.capacity;
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);

    var ids: [range_count]RangeId = undefined;
    var ranges: [range_count]Range = undefined;
    for (&ids, &ranges, 0..) |*id, *range, i| {
        range.* = .{
            .start = 10,
            .end = 11 + @as(BytesInt, @intCast(i % 7)),
            .payload = @intCast(i),
        };
        id.* = try sr.insert_with_height(
            std.testing.allocator,
            range.*,
            if (i == 0) 3 else 0,
        );
    }
    try sr.expect_valid();

    for (0..range_count) |step| {
        const i = step * 37 % range_count;
        try std.testing.expectEqual(ranges[i], sr.remove(ids[i]).?);
        try sr.expect_valid();
    }
    try std.testing.expectEqual(Ib.Num.null, sr.root);
}

test "skiprange: start zero deletion advances a spilled leaf head" {
    const range_count = 3 * Rb.capacity;
    var sr: SkipRange = .empty;
    defer sr.deinit(std.testing.allocator);

    var ids: [range_count]RangeId = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try sr.insert_with_height(
            std.testing.allocator,
            .{
                .start = 0,
                .end = 1 + @as(BytesInt, @intCast(i % 7)),
                .payload = @intCast(i),
            },
            if (i == 0) 3 else 0,
        );
    }

    const head_num = sr.id_index.get(ids[0]).?.rb_num;
    var head_count: usize = 0;
    for (ids) |id| {
        if (sr.id_index.get(id).?.rb_num != head_num) continue;
        head_count += 1;
        _ = sr.remove(id).?;
        try sr.expect_valid();
    }
    try std.testing.expect(head_count > 0);
    try std.testing.expect(head_count < range_count);
    try sr.expect_valid();

    for (ids) |id| {
        if (sr.get(id) == null) continue;
        _ = sr.remove(id).?;
        try sr.expect_valid();
    }
    try std.testing.expectEqual(Ib.Num.null, sr.root);
}

test "skiprange: ordered and reverse starts survive block spills" {
    const cases = [_]struct {
        n: usize,
        height: HeightInt,
        reverse: bool,
    }{
        .{ .n = 2 * Rb.capacity, .height = 0, .reverse = true },
        .{ .n = 2 * Ib.capacity, .height = 2, .reverse = true },
        .{ .n = 2 * Ib.capacity, .height = 2, .reverse = false },
    };

    for (cases) |case| {
        var sr: SkipRange = .empty;
        defer sr.deinit(std.testing.allocator);

        var oracle: std.ArrayList(DebugRange) = .empty;
        defer oracle.deinit(std.testing.allocator);

        for (0..case.n) |i| {
            const rank = if (case.reverse) case.n - i - 1 else i;
            const start: BytesInt = @intCast(rank * 3);
            const range: Range = .{
                .start = start,
                .end = start + 5,
                .payload = @intCast(i),
            };
            const id = try sr.insert_with_height(
                std.testing.allocator,
                range,
                case.height,
            );
            try oracle.append(std.testing.allocator, .{
                .start = range.start,
                .end = range.end,
                .id = id,
                .payload = range.payload,
                .flags = range.flags,
            });
        }

        try sr.expect_valid();
        try sr.expect_debug_matches_oracle(oracle.items);
    }
}

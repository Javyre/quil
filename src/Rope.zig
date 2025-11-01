//! Rope (linked list of string runs) indexed with a B*+tree where the keys are
//! derived from subtree lengths.

const std = @import("std");
const assert = std.debug.assert;
const log = @import("./log.zig").scoped(.rope);
// const log = @import("./log.zig").noop;
const tlog = @import("./log.zig").scoped(.rope_test);

const SegmentedPool = @import("./segmented_pool.zig").SegmentedPool;

const Rope = @This();
const ranged_int = @import("./ranged_int.zig");
const RangedInt = ranged_int.RangedInt;
const Db = @import("./Db.zig");
const Ib = @import("./Ib.zig");
const IbHeight =
    ranged_int.RangedInt(.ib_num, 0, bounds.indx_blocks_height_max);

fn NumAndPtr(comptime B: type) type {
    return struct { ptr: *B, num: B.Num };
}

gpa: std.mem.Allocator,
indx_root: Ib.Num,
indx_height: IbHeight,
indx_blocks: SegmentedPool(Ib, Ib.Num, .coerce(16)),
data_blocks: SegmentedPool(Db, Db.Num, .coerce(128)),

const Config = struct {
    dcache_line_bytes: u8,
    rope_bytes_max: u64,
    data_block_bytes_max: u16,
    /// Size of keys + children arrays
    indx_block_bytes_max: u16,
};

/// Sweet-spot config:
/// - Db.Num/Ib.Num/TreeSize can be stored as u32
/// - indx_block_keys_max is a nice round 16 that fills a cache line nicely
pub const config: Config = x: {
    const dcache_line_bytes = 64;
    break :x .{
        .dcache_line_bytes = dcache_line_bytes,
        .rope_bytes_max = 339 << 30, // 339 GiB
        .data_block_bytes_max = 2 * dcache_line_bytes,
        .indx_block_bytes_max = 2 * dcache_line_bytes,
    };
};
test "sweet-spot comment not stale" {
    try std.testing.expectEqual(32, @max(
        @typeInfo(Ib.Num.Int).int.bits,
        @typeInfo(Db.Num.Int).int.bits,
        @typeInfo(TreeSize.Int).int.bits,
    ));
    try std.testing.expectEqual(16, bounds.indx_block_keys_max);
    try std.testing.expectEqual(
        bounds.indx_block_keys_max * @sizeOf(u32),
        config.dcache_line_bytes,
    );
}

const Bounds = struct {
    subtree_bytes_max: u64,
    data_block_bytes_min: u7,
    data_blocks_max: u64,
    indx_block_keys_max: u8,
    indx_block_keys_min: u8,
    indx_blocks_height_max: u8,
    indx_blocks_max: u64,
};
pub const bounds = rope_bounds(config);

// == Int types for perf and range validation. ==
//
// These assume that you use the provided constructors.
pub const TreeSize = RangedInt(.bytes, 0, bounds.subtree_bytes_max);
pub const RopeBytes = RangedInt(.bytes, 0, config.rope_bytes_max);
pub const RopeBytesSigned = RangedInt(
    .bytes,
    -@as(comptime_int, config.rope_bytes_max),
    @as(comptime_int, config.rope_bytes_max),
);

fn rope_bounds(conf: Config) Bounds {
    const data_block_bytes_min = conf.data_block_bytes_max * 2 / 3;

    const subtree_bytes_max =
        div_ceil(u64, conf.rope_bytes_max, data_block_bytes_min);

    const data_blocks_max =
        div_ceil(u64, conf.rope_bytes_max, data_block_bytes_min);

    // indx block child can be either indx or data block num.
    // BUT data_blocks_max > indx_blocks_max
    // NOTE: No packing accounted for.
    const max_child_size = 2 * @max(
        @sizeOf(std.math.IntFittingRange(0, data_blocks_max - 1)),
        @sizeOf(std.math.IntFittingRange(0, subtree_bytes_max)),
    );
    const indx_block_keys_max = conf.indx_block_bytes_max / max_child_size;
    const indx_block_keys_min = indx_block_keys_max * 2 / 3;

    const indx_blocks_height_max_f = std.math.log(
        f64,
        @floatFromInt(indx_block_keys_min),
        @floatFromInt(data_blocks_max),
    ) - 1;
    const indx_blocks_height_max: u8 =
        @intFromFloat(@ceil(indx_blocks_height_max_f));

    const indx_blocks_max: u64 = @intFromFloat(@ceil(partial_geometric_sum(
        f64,
        indx_blocks_height_max_f,
        @floatFromInt(indx_block_keys_min),
    )));

    assert(data_blocks_max > indx_blocks_max);

    return Bounds{
        .subtree_bytes_max = subtree_bytes_max,
        .data_block_bytes_min = data_block_bytes_min,
        .data_blocks_max = data_blocks_max,
        .indx_block_keys_max = indx_block_keys_max,
        .indx_block_keys_min = indx_block_keys_min,
        .indx_blocks_height_max = indx_blocks_height_max,
        .indx_blocks_max = indx_blocks_max,
    };
}

fn div_ceil(comptime T: type, numerator: T, denominator: T) T {
    return std.math.divCeil(T, numerator, denominator) catch unreachable;
}

/// Calculate \sum_{k=0}^{k_max}}z^k
fn partial_geometric_sum(comptime T: type, k_max: T, z: T) T {
    return (1 - std.math.pow(T, z, k_max + 1)) / (1 - z);
}

fn assert_slice_of(store: anytype, slice: anytype) void {
    const store_ptr_min = @intFromPtr(store.ptr);
    const store_ptr_max = @intFromPtr(store.ptr) + store.len;
    const slice_ptr_min = @intFromPtr(slice.ptr);
    const slice_ptr_max = @intFromPtr(slice.ptr) + slice.len;

    assert(store_ptr_min <= slice_ptr_min);
    assert(slice_ptr_min < store_ptr_max);
    assert(slice_ptr_max <= store_ptr_max);
}

// test "print bounds" {
//     std.debug.print("config = {any}\n", .{config});
//     std.debug.print("bounds = {any}\n", .{bounds});
//     std.debug.print("TreeSize = {any}\n", .{TreeSize});
//     std.debug.print("Db.Num = {any}\n", .{Db.Num});
//     std.debug.print("Ib.Num = {any}\n", .{Ib.Num});
// }

pub fn init(gpa: std.mem.Allocator) Rope {
    var r: Rope = .{
        .gpa = gpa,
        .indx_root = undefined,
        .indx_height = .coerce(1),
        .indx_blocks = .{},
        .data_blocks = .{},
    };

    // These addOne calls dont allocate as we have a stack allocated portion
    // that is large enough for init.
    const root_ib = r.indx_blocks.create(r.gpa) catch unreachable;
    root_ib.ptr.* = .empty;
    r.indx_root = root_ib.num;

    var dbs: [2]struct { ptr: *Db, num: Db.Num } = undefined;
    for (0..2) |i| {
        const db = r.data_blocks.create(r.gpa) catch unreachable;
        db.ptr.* = .{
            .meta = .{
                .bytes = .coerce(0),
                .newlines = undefined,
                .next = .null,
                .prev = .null,
            },
            .bytes = undefined,
        };
        dbs[i] = .{ .ptr = db.ptr, .num = db.num };
        root_ib.ptr.keys[i] = .some(.coerce(0));
        root_ib.ptr.children[i] = .wrap_db_num(db.num);
    }
    dbs[0].ptr.meta.next = .some(dbs[1].num);
    dbs[1].ptr.meta.prev = .some(dbs[0].num);
    return r;
}

pub fn deinit(r: *Rope) void {
    r.indx_blocks.deinit(r.gpa);
    r.data_blocks.deinit(r.gpa);
    r.* = undefined;
}

test init {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();
}

fn db_at(r: *Rope, num: Db.Num) *Db {
    return r.data_blocks.at(num);
}

fn db_at_const(r: *const Rope, num: Db.Num) *const Db {
    return r.data_blocks.at(num);
}

fn ib_at(r: *Rope, num: Ib.Num) *Ib {
    return r.indx_blocks.at(num);
}

fn ib_at_const(r: *const Rope, num: Ib.Num) *const Ib {
    return r.indx_blocks.at(num);
}

const BPathBuf = [bounds.indx_blocks_height_max]BPathEntry;
const BPathEntry = struct {
    parent_ib: *Ib,
    // index to the key in the parent block
    key_idx: Ib.Len,
};

fn find_data_block(
    r: *Rope,
    ofs: RopeBytes,
    path: *std.ArrayList(BPathEntry),
) Db.Len {
    const root_ib = r.ib_at(r.indx_root);
    assert(ofs.to_int() <= root_ib.sum_subtree_bytes().to_int());

    path.clearRetainingCapacity();
    assert(path.capacity >= bounds.indx_blocks_height_max);

    var parent: *Ib = root_ib;
    var rest_ofs: RopeBytes = ofs;

    for (1..r.indx_height.to_int() + 1) |height| {
        const res = parent.find_ofs(rest_ofs) orelse
            @panic("requested ofs out of bounds");

        path.appendAssumeCapacity(.{
            .key_idx = res.key_idx,
            .parent_ib = parent,
        });
        assert(path.items.len == height);

        rest_ofs = .cast(rest_ofs.to_int() - res.child_ofs.to_int());

        if (height < r.indx_height.to_int()) {
            const new_parent =
                r.ib_at(parent.child_at(.cast(res.key_idx)).as(Ib.Num));
            assert(new_parent != parent);
            parent = new_parent;
        } else {
            // if stmt should only be false ONCE for the last iteration
            assert(r.indx_height.eql(.cast(height)));
        }
    }
    assert(r.indx_height.eql(.cast(path.items.len)));
    assert(path.items[path.items.len - 1].parent_ib == parent);

    return .cast(rest_ofs);
}

fn update_parent_keys(
    path: []const BPathEntry,
    new_len: TreeSize,
) void {
    assert(path.len <= bounds.indx_blocks_height_max);

    var next_len: TreeSize = new_len;
    for (0..path.len) |i_rev| {
        const i = path.len - i_rev - 1;
        const entry = path[i];
        const parent = entry.parent_ib;

        parent.key_at(.cast(entry.key_idx)).* = .some(next_len);

        if (i > 0) {
            // This cast is only safe for sum of non-root indx blocks.
            next_len = .cast(parent.sum_subtree_bytes());
        }
    }
}

fn alloc_at(r: *Rope, ofs: RopeBytes, alloc_len: RopeBytes) !struct {
    cursor: Cursor,
    alloc_len: RopeBytes,
} {
    @setEvalBranchQuota(2_000);
    log.info(@src(), "alloc_at()", .{ .ofs = ofs, .alloc_len = alloc_len });

    var path_buf: BPathBuf = undefined;
    var path = std.ArrayList(BPathEntry).initBuffer(&path_buf);
    const ofs_in_targ_db = r.find_data_block(ofs, &path);

    assert(r.indx_height.eql(.cast(path.items.len)));

    const NopIter = struct {
        const NopIter = @This();

        len: RopeBytes,
        pub fn rest_len(this: NopIter) RopeBytes {
            return this.len;
        }
        pub fn take_nop(this: *NopIter, n_: usize) usize {
            const n = this.len.min(.cast(n_));
            this.len = this.len.sub(n);
            return n.to_int();
        }
        pub fn take_nop_back(this: *NopIter, n_: usize) usize {
            return this.take_nop(n_);
        }
    };
    var alloc_iter: NopIter = .{ .len = alloc_len };

    var dbs: Vicinity(Db) = .{
        .left = null,
        .targ = r.vty_targ_db(&path),
        .right = null,
    };

    {
        const targ_db: *const Db = r.db_at(dbs.targ.path_entry.parent_ib
            .child_at(.cast(dbs.targ.path_entry.key_idx))
            .as(Db.Num));
        assert(ofs_in_targ_db.to_int() <= targ_db.meta.bytes.to_int());
    }

    const ins_res_p =
        if (Db.Len.max_val.sub(dbs.targ.len).to_int() >= alloc_len.to_int())
            insert_in_blocks(Db, RopeBytes, &alloc_iter, .{
                .targ = .{ .block = dbs.targ.block, .len = dbs.targ.len },
                .ofs = ofs_in_targ_db,
            })
        else
            try r.insert_with_siblings(Db, RopeBytes, &alloc_iter, .{
                .path = &path,
                .path_cursor = .cast(path.items.len - 1),
                .vty = &dbs,
                .ofs_in_targ = ofs_in_targ_db,
            });

    if (ins_res_p) |ins_res| {
        // insert succeeded
        log.debug(@src(), "insert succeeded without split", .{
            .ins_res = ins_res,
        });
        assert(alloc_iter.rest_len().eql(.coerce(0)));

        dbs.targ.block.meta.bytes = ins_res.targ_len_new;
        if (dbs.right) |right|
            right.block.meta.bytes = ins_res.right_len_new.?;
        if (dbs.left) |left|
            left.block.meta.bytes = ins_res.left_len_new.?;

        dbs.targ.path_entry.parent_ib.key_at(
            .cast(dbs.targ.path_entry.key_idx),
        ).* = .some(.coerce(ins_res.targ_len_new));
        if (dbs.right) |right|
            dbs.targ.path_entry.parent_ib.key_at(right.key_idx).* =
                .some(.coerce(ins_res.right_len_new.?));
        if (dbs.left) |left|
            dbs.targ.path_entry.parent_ib.key_at(left.key_idx).* =
                .some(.coerce(ins_res.left_len_new.?));

        update_parent_keys(
            path.items[0 .. path.items.len - 1],
            .cast(dbs.targ.path_entry.parent_ib.sum_subtree_bytes()),
        );

        return .{
            .cursor = .{ .db = ins_res.block, .ofs = ins_res.ofs },
            .alloc_len = alloc_len,
        };
    }

    // NOTE: Now we know that we need to split target and r/l to create new
    //       data blocks for alloc_len.

    const DbInfo = BInfo(Db);
    const Split = struct { left: DbInfo, right: DbInfo };
    const targ_binfo: DbInfo = .{
        .block = dbs.targ.block,
        .len = dbs.targ.len,
        .key_idx = .cast(dbs.targ.path_entry.key_idx),
    };
    const split: Split = if (dbs.left) |left|
        .{
            .left = left,
            .right = targ_binfo,
        }
    else if (dbs.right) |right|
        .{
            .left = targ_binfo,
            .right = right,
        }
    else
        // a data block should always have at least one sibling in the same
        // parent
        unreachable;

    const split_lens = calc_split_lens(Db, RopeBytes, .{
        .b_len_min = .coerce(bounds.data_block_bytes_min),
        .alloc_len = alloc_len,
        .ofs_in_targ = ofs_in_targ_db,
        .targ = dbs.targ,
        .left = split.left,
        .right = split.right,
    });
    log.info(@src(), "splitting", .{
        .split = split,
        .split_lens = split_lens,
    });

    assert(RopeBytes.add(
        .coerce(split_lens.prefix),
        .coerce(split_lens.postfix),
    ).eql(.add(
        .coerce(split.left.len),
        .coerce(split.right.len),
    )));

    // the split will call update_parent_keys so we might as well set up the
    // new right/left db lens now and piggyback on the update_parent_keys

    split.left.block.meta.bytes = split_lens.left_new;
    split.right.block.meta.bytes = split_lens.right_new;
    dbs.targ.path_entry.parent_ib.key_at(split.left.key_idx).* =
        .some(.coerce(split_lens.left_new));
    dbs.targ.path_entry.parent_ib.key_at(split.right.key_idx).* =
        .some(.coerce(split_lens.right_new));

    // do the split
    const left_db_num: Db.Num = split.right.block.meta.prev.unwrap().?;
    const right_db_num: Db.Num = split.left.block.meta.next.unwrap().?;
    path.items[path.items.len - 1].key_idx = .coerce(split.right.key_idx);
    log.debug(@src(), "pre-insert_dbs parent", .{
        .parent = path.items[path.items.len - 1].parent_ib,
    });
    log.debug(@src(), "left", .{ .left = split.left.block });
    log.debug(@src(), "right", .{ .right = split.right.block });
    const actual_new_dbs = try r.insert_dbs(&path, split_lens.new_bs);
    log.debug(@src(), "post-insert_dbs parent", .{
        .parent = path.items[path.items.len - 1].parent_ib,
    });
    log.debug(@src(), "left", .{ .left = split.left.block });
    log.debug(@src(), "right", .{ .right = split.right.block });
    assert(actual_new_dbs.to_int() > 0);
    assert(actual_new_dbs.to_int() <= split_lens.new_bs.to_int());

    assert(!Db.Num.eql(split.left.block.meta.next.unwrap().?, right_db_num));
    assert(!Db.Num.eql(left_db_num, split.right.block.meta.prev.unwrap().?));

    // fixup the prefix/postfix data
    var buf_store: [2 * config.data_block_bytes_max]u8 = undefined;
    var buf: std.ArrayList(u8) = .initBuffer(&buf_store);
    buf.appendSliceAssumeCapacity(
        split.left.block.slice(null, split.left.len).bytes(),
    );
    buf.appendSliceAssumeCapacity(
        split.right.block.slice(null, split.right.len).bytes(),
    );

    const alloc_pos_cursor = x: {
        var cursor: Cursor = .{
            .db = split.left.block,
            .ofs = .coerce(0),
        };
        var cursor_writer = cursor.writer(r, &.{});
        cursor_writer.writer.writeAll(
            buf.items[0..split_lens.prefix.to_int()],
        ) catch unreachable;
        break :x cursor;
    };
    {
        var cursor: Cursor = .{
            .db = split.right.block,
            .ofs = split_lens.right_new,
        };
        assert(
            buf.items[split_lens.prefix.to_int()..].len ==
                split_lens.postfix.to_int(),
        );
        cursor.seek_back(r, .coerce(split_lens.postfix));
        var cursor_writer = cursor.writer(r, &.{});
        cursor_writer.writer.writeAll(
            buf.items[split_lens.prefix.to_int()..],
        ) catch unreachable;
    }

    const actual_alloc_len: RopeBytes = RopeBytes
        .cast((@as(usize, actual_new_dbs.to_int()) + @as(usize, 2)) *
            @as(usize, bounds.data_block_bytes_min))
        .add(.cast(split_lens.spill))
        .sub(split_lens.prefix)
        .sub(split_lens.postfix);
    assert(actual_alloc_len.to_int() <= alloc_len.to_int());

    if (split_lens.new_bs.eql(actual_new_dbs)) {
        assert(actual_alloc_len.eql(alloc_len));
    }

    return .{
        .cursor = alloc_pos_cursor,
        .alloc_len = actual_alloc_len,
    };
}

fn insert_dbs(
    r: *Rope,
    path: *std.ArrayList(BPathEntry),
    new_dbs: Db.Num,
) !Db.Num {
    log.info(@src(), "insert_dbs()", .{
        .path = path.items,
        .new_dbs = new_dbs,
    });

    // null if targ is root ib
    var path_cursor: ?PathLen =
        if (path.items.len >= 2) .cast(path.items.len - 2) else null;

    const next_db: Db.Num = path.items[path.items.len - 1].parent_ib
        .child_at(.cast(path.items[path.items.len - 1].key_idx))
        .as(Db.Num);
    var new_dbs_iter_: InsertDbIter = .init(r, .{
        .len = new_dbs.retag(.db_num, .ib_keys),
        .next = .some(next_db),
        .prev = r.db_at(next_db).meta.prev,
    });
    const new_dbs_iter = iter_map(&new_dbs_iter_, struct {
        pub fn map(item: DbIterItem) struct {
            key: Ib.RawKey,
            child: Ib.RawChild,
        } {
            return .{
                .key = .some(.coerce(item.db.meta.bytes)),
                .child = .wrap_db_num(item.num),
            };
        }
    }.map);

    const IbTotalLen = RangedInt(
        Ib.Len.tag,
        Db.Num.min_val.to_int(),
        Db.Num.max_val.to_int(),
    );
    const ofs_in_targ_ib = path.items[path.items.len - 1].key_idx;

    const targ_pre_reroot = vty_targ_ib(path, path_cursor);
    if (Ib.Len.max_val.sub(targ_pre_reroot.len).to_int() >= new_dbs.to_int()) {
        const targ = targ_pre_reroot;

        const ins_res = insert_in_blocks(Ib, IbTotalLen, new_dbs_iter, .{
            .targ = .{ .block = targ.block, .len = targ.len },
            .ofs = ofs_in_targ_ib,
        });
        // insert succeeded
        log.debug(@src(), "insert succeeded without split", .{
            .ins_res = ins_res,
        });
        assert(new_dbs_iter.next() == null);
        assert(new_dbs_iter.next_back() == null);
        assert(ins_res.block == targ.block);

        // fix sentinels
        if (ins_res.targ_len_new.to_int() < Ib.Len.max_val.to_int()) {
            targ.block.key_at(.cast(ins_res.targ_len_new)).* = .null;
        }

        if (targ.path_entry) |e| {
            e.parent_ib.key_at(.cast(e.key_idx)).* =
                .some(.cast(targ.block.sum_subtree_bytes()));
            update_parent_keys(
                path.items[0..path_cursor.?.to_int()],
                .cast(e.parent_ib.sum_subtree_bytes()),
            );
        } else {
            assert(path_cursor == null);
            assert(path.items.len == 1);
        }
        return new_dbs;
    }

    var ibs: Vicinity(Ib) = .{
        .left = null,
        .targ = undefined,
        .right = null,
    };
    ibs.targ = if (path_cursor == null) targ: {
        log.info(@src(), "root is full; rerooting", .{});
        const old_len = path.items.len;
        const targ = try r.reroot(path, targ_pre_reroot);
        assert(path.items.len == old_len + 1);
        path_cursor = .coerce(0);

        break :targ targ;
    } else targ_pre_reroot;

    if (try r.insert_with_siblings(Ib, IbTotalLen, new_dbs_iter, .{
        .path = path, // mutable ref
        .path_cursor = path_cursor,
        .vty = &ibs,
        .ofs_in_targ = ofs_in_targ_ib,
    })) |ins_res| {
        // insert succeeded
        log.debug(@src(), "insert succeeded without split", .{
            .ins_res = ins_res,
        });
        assert(new_dbs_iter.next() == null);
        assert(new_dbs_iter.next_back() == null);

        // fix sentinels
        if (ins_res.targ_len_new.to_int() < Ib.Len.max_val.to_int()) {
            ibs.targ.block.key_at(.cast(ins_res.targ_len_new)).* = .null;
        }
        if (ins_res.right_len_new) |right_len_new| {
            if (right_len_new.to_int() < Ib.Len.max_val.to_int())
                ibs.right.?.block.key_at(.cast(right_len_new)).* = .null;
        }
        if (ins_res.left_len_new) |left_len_new| {
            if (left_len_new.to_int() < Ib.Len.max_val.to_int())
                ibs.left.?.block.key_at(.cast(left_len_new)).* = .null;
        }

        if (ibs.targ.path_entry) |e|
            e.parent_ib.key_at(.cast(e.key_idx)).* =
                .some(.cast(ibs.targ.block.sum_subtree_bytes()));
        if (ibs.right) |right|
            ibs.targ.path_entry.?.parent_ib.key_at(right.key_idx).* =
                .some(.cast(right.block.sum_subtree_bytes()));
        if (ibs.left) |left|
            ibs.targ.path_entry.?.parent_ib.key_at(left.key_idx).* =
                .some(.cast(left.block.sum_subtree_bytes()));

        if (ibs.targ.path_entry) |e| {
            update_parent_keys(
                path.items[0..path_cursor.?.to_int()],
                .cast(e.parent_ib.sum_subtree_bytes()),
            );
        } else {
            assert(path_cursor == null);
            assert(path.items.len == 1);
        }
        return new_dbs;
    }

    // NOTE: Now we know that we need to split target and r/l to create new
    //       data blocks for alloc_len.

    const IbInfo = BInfo(Ib);
    // targ is not root at this point
    assert(path_cursor != null);
    const targ_binfo: IbInfo = .{
        .block = ibs.targ.block,
        .len = ibs.targ.len,
        .key_idx = .cast(ibs.targ.path_entry.?.key_idx),
    };
    const Split = struct { left: IbInfo, right: IbInfo };
    const split: Split = if (ibs.left) |left|
        .{
            .left = left,
            .right = targ_binfo,
        }
    else if (ibs.right) |right|
        .{
            .left = targ_binfo,
            .right = right,
        }
    else
        // an indx block should always have at least one sibling in the
        // same parent
        unreachable;

    const split_lens = calc_split_lens(Ib, IbTotalLen, .{
        .b_len_min = .coerce(@as(comptime_int, bounds.indx_block_keys_min)),
        .alloc_len = new_dbs.retag(.db_num, .ib_keys),
        .ofs_in_targ = ofs_in_targ_ib,
        .targ = ibs.targ,
        .left = split.left,
        .right = split.right,
    });
    log.info(@src(), "splitting", .{
        .split = split,
        .split_lens = split_lens,
    });

    const actual_new_ibs = Ib.Num.min(
        split_lens.new_bs,
        new_leaf_blocks_max,
    );
    assert(actual_new_ibs.to_int() > 0);

    const actual_new_dbs = new_dbs.sub(.cast(
        split_lens.new_bs.sub(actual_new_ibs).to_int() *
            bounds.indx_block_keys_min,
    ));
    assert(actual_new_dbs.to_int() > 0);
    assert(actual_new_dbs.to_int() <= new_dbs.to_int());

    var pending_ib_clds: std.ArrayList(Ib.RawChild), //
    var pending_ib_keys: std.ArrayList(Ib.RawKey) = x: {
        var clds_store: [pending_bs_store_len.to_int()]Ib.RawChild = undefined;
        var keys_store: [pending_bs_store_len.to_int()]Ib.RawKey = undefined;
        break :x .{
            .initBuffer(&clds_store),
            .initBuffer(&keys_store),
        };
    };

    new_dbs_iter_ = .init(r, .{
        .len = actual_new_dbs.retag(.db_num, .ib_keys),
        .next = .some(next_db),
        .prev = r.db_at(next_db).meta.prev,
    });

    // iter over prefix + new_dbs + postfix dbs

    // split.right might be empty due to a reroot
    const postfix_last: struct {
        key_idx: Ib.Idx,
        parent_ib: IbInfo,
    } = if (split.right.len.to_int() > 0) .{
        .key_idx = .cast(split.right.len.sub(.coerce(1))),
        .parent_ib = split.right,
    } else .{
        .key_idx = .cast(split.left.len.sub(.coerce(1))),
        .parent_ib = split.left,
    };
    assert(split.left.block
        .key_at(.coerce(0)).unwrap() != null);
    assert(postfix_last.parent_ib.block
        .key_at(postfix_last.key_idx).unwrap() != null);
    const prefix_head: Db.Num = split.left.block
        .child_at(.coerce(0)).as(Db.Num);
    const postfix_tail: Db.Num = postfix_last.parent_ib.block
        .child_at(postfix_last.key_idx).as(Db.Num);

    var prefix_iter: DbIter = .{
        .r = r,
        .next_ = .some(prefix_head),
        .next_back_ = r.db_at(next_db).meta.prev,
    };
    var postfix_iter: DbIter = .{
        .r = r,
        .next_ = .some(next_db),
        .next_back_ = .some(postfix_tail),
    };
    var all_dbs_iter =
        iter_chain(&prefix_iter, iter_chain(&new_dbs_iter_, &postfix_iter));
    var all_dbs_iter_kv = iter_map(&all_dbs_iter, struct {
        pub fn map(item: DbIterItem) struct {
            key: Ib.RawKey,
            child: Ib.RawChild,
        } {
            return .{
                .key = .some(.coerce(item.db.meta.bytes)),
                .child = .wrap_db_num(item.num),
            };
        }
    }.map);

    split.left.block.* = .empty;
    assert(Ib.write(
        split.left.block.slice(null, split_lens.left_new),
        &all_dbs_iter_kv,
    ).eql(split_lens.left_new));
    const new_left_key = split.left.block.sum_subtree_bytes();

    for (0..actual_new_ibs.to_int()) |_| {
        const new_leaf = try r.indx_blocks.create(r.gpa);
        new_leaf.ptr.* = .empty;
        const s = new_leaf.ptr.slice(null, .cast(bounds.indx_block_keys_min));
        assert(Ib.write(s, &all_dbs_iter_kv).eql(s.len));
        pending_ib_keys.appendAssumeCapacity(.some(.cast(
            new_leaf.ptr.sum_subtree_bytes(),
        )));
        pending_ib_clds.appendAssumeCapacity(.wrap_ib_num(new_leaf.num));
    }
    assert(pending_ib_keys.items.len == actual_new_ibs.to_int());
    assert(pending_ib_clds.items.len == actual_new_ibs.to_int());
    assert(actual_new_ibs.to_int() <= new_leaf_blocks_max.to_int());

    split.right.block.* = .empty;
    {
        const wlen = Ib.write(
            split.right.block.slice(null, split_lens.right_new),
            &all_dbs_iter_kv,
        );
        assert(wlen.eql(split_lens.right_new));
    }
    const new_right_key = split.right.block.sum_subtree_bytes();

    assert(all_dbs_iter_kv.next() == null);
    assert(all_dbs_iter_kv.next_back() == null);

    // the split will call update_parent_keys so we set up the new right/left
    // ib keys now and piggyback on the update_parent_keys
    ibs.targ.path_entry.?.parent_ib
        .key_at(split.left.key_idx).* = .some(.cast(new_left_key));
    ibs.targ.path_entry.?.parent_ib
        .key_at(split.right.key_idx).* = .some(.cast(new_right_key));

    // set insert target
    path.items[path.items.len - 2].key_idx = .coerce(split.right.key_idx);
    try r.insert_ibs(path, &pending_ib_keys, &pending_ib_clds);

    return actual_new_dbs;
}

// CALC: max of 64 leaf blocks allocated:
//    => max of 64 * 16 * (2/3) data blocks allocated
//    => max of 64 * 16 * (2/3) * 128 * (2/3) bytes allocated
//            = 56.88KiB allocated
const new_leaf_blocks_max: Ib.Num = .coerce(64);
const pending_bs_store_len =
    new_leaf_blocks_max.add(.cast(2 * bounds.indx_block_keys_max));

const PendingIbSlice = struct {
    keys: []Ib.RawKey,
    children: []Ib.RawChild,

    pub fn slice(this: PendingIbSlice, beg: usize, end: ?usize) PendingIbSlice {
        assert(this.keys.len == this.children.len);
        const end_ = end orelse this.keys.len;
        assert(beg <= end_);
        return .{
            .keys = this.keys[beg..end_],
            .children = this.children[beg..end_],
        };
    }

    pub fn shr(this: PendingIbSlice, amt: usize) void {
        std.mem.copyBackwards(
            Ib.RawChild,
            this.children[amt..],
            this.children[0 .. this.children.len - amt],
        );
        std.mem.copyBackwards(
            Ib.RawKey,
            this.keys[amt..],
            this.keys[0 .. this.keys.len - amt],
        );
    }

    pub fn write(dst: PendingIbSlice, iter: anytype) usize {
        const hasMethod = std.meta.hasMethod;
        assert(dst.keys.len == dst.children.len);
        if (hasMethod(@TypeOf(iter), "take")) {
            const res = iter.take(dst.keys.len);
            assert(res.keys.len == res.children.len);
            const actual_dst = dst.slice(0, res.keys.len);
            @memcpy(actual_dst.keys, res.keys);
            @memcpy(actual_dst.children, res.children);
            return res.keys.len;
        } else {
            var written: usize = 0;
            for (0..dst.keys.len) |i| {
                const el = iter.next() orelse break;
                dst.keys[i] = el.key;
                dst.children[i] = el.child;
                written += 1;
            }
            return written;
        }
    }

    pub fn rest_len(this: PendingIbSlice) usize {
        assert(this.keys.len == this.children.len);
        return this.keys.len;
    }

    pub fn take(this: *PendingIbSlice, n_: usize) struct {
        keys: []Ib.RawKey,
        children: []Ib.RawChild,
    } {
        assert(this.keys.len == this.children.len);
        const n = @min(n_, this.keys.len);
        const head = .{
            .keys = this.keys[0..n],
            .children = this.children[0..n],
        };
        this.* = .{
            .keys = this.keys[n..],
            .children = this.children[n..],
        };
        return .{ .keys = head.keys, .children = head.children };
    }
    pub fn take_back(this: *PendingIbSlice, n_: usize) struct {
        keys: []Ib.RawKey,
        children: []Ib.RawChild,
    } {
        assert(this.keys.len == this.children.len);
        const n = @min(n_, this.keys.len);
        const tail = .{
            .keys = this.keys[this.keys.len - n ..],
            .children = this.children[this.children.len - n ..],
        };
        this.* = .{
            .keys = this.keys[0 .. this.keys.len - n],
            .children = this.children[0 .. this.children.len - n],
        };
        return .{ .keys = tail.keys, .children = tail.children };
    }
};

/// Invalidates the contents of the idxs slice. (used as a workarea)
/// Invalidates the contents of the keys slice. (used as a workarea)
fn insert_ibs(
    r: *Rope,
    path: *std.ArrayList(BPathEntry),
    pending_ib_keys: *std.ArrayList(Ib.RawKey),
    pending_ib_clds: *std.ArrayList(Ib.RawChild),
) !void {
    log.info(@src(), "insert_ibs()", .{
        .path = path.items,
        .pending_ib_keys = pending_ib_keys.items,
        .pending_ib_clds = pending_ib_clds.items,
    });
    // null if targ is root ib
    var path_cursor: ?PathLen =
        if (path.items.len >= 3) .cast(path.items.len - 3) else null;

    // cap iterations because we are paranoid :)
    for (0..bounds.indx_blocks_height_max - 1) |_| {
        assert(pending_ib_keys.items.len > 0);
        assert(pending_ib_clds.items.len > 0);
        assert(pending_ib_keys.items.len == pending_ib_clds.items.len);
        const new_ibs: Ib.Num = .cast(pending_ib_keys.items.len);

        var new_ibs_iter: PendingIbSlice = .{
            .keys = pending_ib_keys.items,
            .children = pending_ib_clds.items,
        };

        const IbTotalLen = RangedInt(
            Ib.Len.tag,
            Ib.Num.min_val.to_int(),
            Ib.Num.max_val.to_int(),
        );
        const ofs_in_targ_ib =
            path.items[if (path_cursor) |c| c.to_int() + 1 else 0].key_idx;

        const targ_pre_reroot = vty_targ_ib(path, path_cursor);
        if (Ib.Len.max_val.sub(targ_pre_reroot.len).to_int() >=
            new_ibs.to_int())
        {
            const targ = targ_pre_reroot;

            const ins_res = insert_in_blocks(Ib, IbTotalLen, &new_ibs_iter, .{
                .targ = .{ .block = targ.block, .len = targ.len },
                .ofs = ofs_in_targ_ib,
            });
            // insert succeeded
            log.debug(@src(), "insert succeeded without split", .{
                .ins_res = ins_res,
            });
            assert(new_ibs_iter.rest_len() == 0);
            assert(ins_res.block == targ.block);

            // fix sentinels
            if (ins_res.targ_len_new.to_int() < Ib.Len.max_val.to_int()) {
                targ.block.key_at(.cast(ins_res.targ_len_new)).* = .null;
            }

            if (targ.path_entry) |e| {
                e.parent_ib.key_at(.cast(e.key_idx)).* =
                    .some(.cast(targ.block.sum_subtree_bytes()));
                update_parent_keys(
                    path.items[0..path_cursor.?.to_int()],
                    .cast(e.parent_ib.sum_subtree_bytes()),
                );
            } else {
                assert(path_cursor == null);
            }
            return;
        }

        var ibs: Vicinity(Ib) = .{
            .left = null,
            .targ = undefined,
            .right = null,
        };
        ibs.targ = if (path_cursor == null) targ: {
            log.info(@src(), "root is full; rerooting", .{});
            const old_len = path.items.len;
            const targ = try r.reroot(path, targ_pre_reroot);
            assert(path.items.len == old_len + 1);
            path_cursor = .coerce(0);

            break :targ targ;
        } else targ_pre_reroot;

        if (try r.insert_with_siblings(Ib, IbTotalLen, &new_ibs_iter, .{
            .path = path, // mutable ref
            .path_cursor = path_cursor,
            .vty = &ibs,
            .ofs_in_targ = ofs_in_targ_ib,
        })) |ins_res| {
            // insert succeeded
            log.debug(@src(), "insert succeeded without split", .{
                .ins_res = ins_res,
            });
            assert(new_ibs_iter.rest_len() == 0);

            if (ins_res.targ_len_new.to_int() < Ib.Len.max_val.to_int()) {
                ibs.targ.block.key_at(.cast(ins_res.targ_len_new)).* = .null;
            }
            if (ins_res.right_len_new) |right_len_new| {
                if (right_len_new.to_int() < Ib.Len.max_val.to_int())
                    ibs.right.?.block.key_at(.cast(right_len_new)).* = .null;
            }
            if (ins_res.left_len_new) |left_len_new| {
                if (left_len_new.to_int() < Ib.Len.max_val.to_int())
                    ibs.left.?.block.key_at(.cast(left_len_new)).* = .null;
            }

            if (ibs.targ.path_entry) |e|
                e.parent_ib.key_at(.cast(e.key_idx)).* =
                    .some(.cast(ibs.targ.block.sum_subtree_bytes()));
            if (ibs.right) |right|
                ibs.targ.path_entry.?.parent_ib.key_at(right.key_idx).* =
                    .some(.cast(right.block.sum_subtree_bytes()));
            if (ibs.left) |left|
                ibs.targ.path_entry.?.parent_ib.key_at(left.key_idx).* =
                    .some(.cast(left.block.sum_subtree_bytes()));

            if (ibs.targ.path_entry) |e| {
                update_parent_keys(
                    path.items[0..path_cursor.?.to_int()],
                    .cast(e.parent_ib.sum_subtree_bytes()),
                );
            } else {
                assert(path_cursor == null);
            }
            return;
        }

        // NOTE: Now we know that we need to split target and r/l to create new
        //       data blocks for alloc_len.

        const IbInfo = BInfo(Ib);
        // targ is not root at this point
        assert(path_cursor != null);
        const targ_binfo: IbInfo = .{
            .block = ibs.targ.block,
            .len = ibs.targ.len,
            .key_idx = .cast(ibs.targ.path_entry.?.key_idx),
        };
        const Split = struct { left: IbInfo, right: IbInfo };
        const split: Split = if (ibs.left) |left|
            .{
                .left = left,
                .right = targ_binfo,
            }
        else if (ibs.right) |right|
            .{
                .left = targ_binfo,
                .right = right,
            }
        else
            // an indx block should always have at least one sibling in the
            // same parent
            unreachable;

        const split_lens = calc_split_lens(Ib, IbTotalLen, .{
            .b_len_min = .coerce(@as(comptime_int, bounds.indx_block_keys_min)),
            .alloc_len = new_ibs.retag(.ib_num, .ib_keys),
            .ofs_in_targ = ofs_in_targ_ib,
            .targ = ibs.targ,
            .left = split.left,
            .right = split.right,
        });
        log.info(@src(), "splitting", .{
            .split = split,
            .split_lens = split_lens,
        });

        assert(split_lens.new_bs.to_int() > 0);
        // this should already be true of the size of pending_ib and from that
        // initial list forward, the size should be decreasing.
        assert(split_lens.new_bs.to_int() <= new_leaf_blocks_max.to_int());

        // see assumptions in doc comment: we have two full blocks worth of
        // scratch space.
        {
            var left_rest = split.left.block.slice(null, split.left.len);
            var right_rest = split.right.block.slice(null, split.right.len);
            const prefix = split_lens.prefix.to_int();
            var slice: PendingIbSlice = .{
                .keys = pending_ib_keys.addManyAtAssumeCapacity(0, prefix),
                .children = pending_ib_clds.addManyAtAssumeCapacity(0, prefix),
            };
            var cursor: usize = 0;
            for ([_]*Ib.Slice{ &left_rest, &right_rest }) |part_rest| {
                cursor += slice.slice(cursor, prefix).write(part_rest);
            }
            assert(cursor == prefix);

            cursor = pending_ib_clds.items.len;
            const postfix = split_lens.postfix.to_int();
            pending_ib_clds.appendNTimesAssumeCapacity(undefined, postfix);
            pending_ib_keys.appendNTimesAssumeCapacity(undefined, postfix);
            slice = .{
                .keys = pending_ib_keys.items,
                .children = pending_ib_clds.items,
            };
            for ([_]*Ib.Slice{ &left_rest, &right_rest }) |part_rest| {
                cursor += slice.slice(cursor, null).write(part_rest);
            }
            assert(cursor == pending_ib_clds.items.len);
            assert(left_rest.len.eql(.min_val));
            assert(right_rest.len.eql(.min_val));
        }

        log.debug(@src(), "pre-bundle pending ibs", .{
            .pending_ib_childs = pending_ib_clds.items,
            .pending_ib_keys = pending_ib_keys.items,
        });

        var pending_ibs: PendingIbSlice = .{
            .keys = pending_ib_keys.items,
            .children = pending_ib_clds.items,
        };

        // bundle pending blocks into new parents (back into left/pending/right)
        split.left.block.* = .empty;
        assert(Ib.write(
            split.left.block.slice(null, split_lens.left_new),
            &pending_ibs,
        ).eql(split_lens.left_new));
        const new_left_key = split.left.block.sum_subtree_bytes();

        for (0..split_lens.new_bs.to_int()) |cursor| {
            const new_child = try r.indx_blocks.create(r.gpa);
            new_child.ptr.* = .empty;
            assert(Ib.write(
                new_child.ptr.slice(null, .cast(bounds.indx_block_keys_min)),
                &pending_ibs,
            ).eql(.cast(bounds.indx_block_keys_min)));
            const new_child_key = new_child.ptr.sum_subtree_bytes();

            // we share the same buffer but always write slower than we
            // read. So no clobbering.
            {
                const write_ptr = &pending_ib_clds.items[cursor];
                const read_ptr = pending_ibs.children.ptr;
                assert(@intFromPtr(write_ptr) < @intFromPtr(read_ptr));
            }

            log.debug(@src(), "new_child", .{ .new_child = new_child });

            pending_ib_keys.items[cursor] = .some(.cast(new_child_key));
            pending_ib_clds.items[cursor] = .wrap_ib_num(new_child.num);
        }
        assert(pending_ibs.rest_len() == split_lens.right_new.to_int());

        split.right.block.* = .empty;
        assert(Ib.write(
            split.right.block.slice(null, split_lens.right_new),
            &pending_ibs,
        ).eql(split_lens.right_new));
        assert(pending_ibs.rest_len() == 0);
        const new_right_key = split.right.block.sum_subtree_bytes();

        pending_ib_clds.shrinkRetainingCapacity(split_lens.new_bs.to_int());
        pending_ib_keys.shrinkRetainingCapacity(split_lens.new_bs.to_int());
        log.debug(@src(), "post-bundle pending ibs", .{
            .pending_ib_childs = pending_ib_clds.items,
            .pending_ib_keys = pending_ib_keys.items,
        });

        // the split will call update_parent_keys so we set up the new right/left
        // ib keys now and piggyback on the update_parent_keys
        ibs.targ.path_entry.?.parent_ib
            .key_at(split.left.key_idx).* = .some(.cast(new_left_key));
        ibs.targ.path_entry.?.parent_ib
            .key_at(split.right.key_idx).* = .some(.cast(new_right_key));

        // set next insert target
        if (split.left.block == ibs.targ.block) {
            const path_entry = &path.items[path_cursor.?.to_int()];
            assert(r.ib_at(
                path_entry.parent_ib
                    .child_at(.cast(path_entry.key_idx))
                    .as(Ib.Num),
            ) == split.left.block);
            path_entry.key_idx = path_entry.key_idx.add(.coerce(1));
        } else {
            assert(split.right.block == ibs.targ.block);
            const path_entry = &path.items[path_cursor.?.to_int()];
            assert(std.meta.eql(path_entry.*, ibs.targ.path_entry.?));
            assert(r.ib_at(
                path_entry.parent_ib
                    .child_at(.cast(path_entry.key_idx))
                    .as(Ib.Num),
            ) == split.right.block);
        }
        path_cursor = path_cursor.?.try_sub(.coerce(1)) catch null;
    }
    @panic("reached max iterations! probably a bug.");
}

/// NOTE: reroot creates a new sibling block but leaves it empty.
///       this temporarily violates the min of 2 children rule, but
///       this should be resolved either by insert_in_blocks or by the
///       split.
fn reroot(
    r: *Rope,
    path: *std.ArrayList(BPathEntry),
    // new_bs: RangedInt(Ib.Idx.tag, 0, @max(
    //     bounds.data_blocks_max,
    //     bounds.indx_blocks_max,
    // )),
    targ: TargBInfo(Ib),
    // ofs_in_targ: Ib.Len,
) !TargBInfo(Ib) {
    assert(targ.block == r.ib_at(r.indx_root));
    assert(targ.len.to_int() >= 2);
    // assert(targ.len.to_int() > ofs_in_targ.to_int());
    const targ_num: Ib.Num = r.indx_root;

    const new_root = try r.indx_blocks.create(r.gpa);
    new_root.ptr.* = .empty;

    // new root needs at least 2 children
    const new_sibling = try r.indx_blocks.create(r.gpa);
    new_sibling.ptr.* = .empty;

    r.indx_root = new_root.num;

    new_root.ptr.key_at(.coerce(0)).* =
        .some(.cast(targ.block.sum_subtree_bytes()));
    new_root.ptr.child_at(.coerce(0)).* = .wrap_ib_num(targ_num);

    assert(new_sibling.ptr.sum_subtree_bytes().eql(.coerce(0)));
    new_root.ptr.key_at(.coerce(1)).* = .some(.coerce(0));
    new_root.ptr.child_at(.coerce(1)).* = .wrap_ib_num(new_sibling.num);

    const path_entry: BPathEntry = .{
        .key_idx = .coerce(0),
        .parent_ib = new_root.ptr,
    };
    path.insertAssumeCapacity(0, path_entry);
    r.indx_height = r.indx_height.add(.coerce(1));

    return .{
        .block = targ.block,
        .len = targ.len,
        .path_entry = path_entry,
    };
}

const DbIterItem = struct {
    db: *Db,
    num: Db.Num,
};

const DbIter = struct {
    r: *Rope,
    next_: Db.NumOpt,
    next_back_: Db.NumOpt,
    done: bool = false,

    pub fn next(this: *DbIter) ?DbIterItem {
        if (this.done) return null;
        this.done = this.next_.eql(this.next_back_);

        const num = this.next_.unwrap() orelse return null;
        const db = this.r.db_at(num);
        this.next_ = db.meta.next;
        return .{ .db = db, .num = num };
    }

    pub fn next_back(this: *DbIter) ?DbIterItem {
        if (this.done) return null;
        this.done = this.next_.eql(this.next_back_);

        const num = this.next_back_.unwrap() orelse return null;
        const db = this.r.db_at(num);
        this.next_back_ = db.meta.prev;
        return .{ .db = db, .num = num };
    }
};

const InsertDbIter = struct {
    r: *Rope,
    len: IbTotalLen,
    prev_: Db.NumOpt, // next builds on top of this
    next_: Db.NumOpt, // next_back builds under this

    const IbTotalLen = RangedInt(
        Ib.Len.tag,
        Db.Num.min_val.to_int(),
        Db.Num.max_val.to_int(),
    );

    pub fn init(r: *Rope, args: struct {
        len: IbTotalLen,
        prev: Db.NumOpt,
        next: Db.NumOpt,
    }) InsertDbIter {
        if (args.prev.unwrap()) |prev_|
            assert(r.db_at(prev_).meta.next.eql(args.next));
        if (args.next.unwrap()) |next_|
            assert(r.db_at(next_).meta.prev.eql(args.prev));

        return .{
            .r = r,
            .len = args.len,
            .next_ = args.next,
            .prev_ = args.prev,
        };
    }

    pub fn rest_len(this: InsertDbIter) IbTotalLen {
        return this.len;
    }

    pub fn next(this: *InsertDbIter) ?DbIterItem {
        if (this.len.eql(.min_val)) return null;
        defer this.len = this.len.sub(.coerce(1));

        const len: Db.Len = .cast(bounds.data_block_bytes_min);
        const db = this.r.data_blocks.create(this.r.gpa) catch unreachable;
        db.ptr.* = .{
            .meta = .{
                .bytes = len,
                .newlines = undefined,
                .prev = this.prev_,
                .next = if (this.len.eql(.coerce(1)))
                    this.next_
                else
                    .null,
            },
            .bytes = undefined,
        };

        if (this.prev_.unwrap()) |p|
            this.r.db_at(p).meta.next = .some(db.num);
        if (this.len.eql(.coerce(1))) {
            if (this.next_.unwrap()) |n|
                this.r.db_at(n).meta.prev = .some(db.num);
        }
        this.prev_ = .some(db.num);

        return .{
            .db = db.ptr,
            .num = db.num,
        };
    }

    pub fn next_back(this: *InsertDbIter) ?DbIterItem {
        if (this.len.eql(.min_val)) return null;
        defer this.len = this.len.sub(.coerce(1));

        const len: Db.Len = .cast(bounds.data_block_bytes_min);
        const db = this.r.data_blocks.create(this.r.gpa) catch unreachable;
        db.ptr.* = .{
            .meta = .{
                .bytes = len,
                .newlines = undefined,
                .next = this.next_,
                .prev = if (this.len.eql(.coerce(1)))
                    this.prev_
                else
                    .null,
            },
            .bytes = undefined,
        };

        if (this.next_.unwrap()) |n|
            this.r.db_at(n).meta.prev = .some(db.num);
        if (this.len.eql(.coerce(1))) {
            if (this.prev_.unwrap()) |p|
                this.r.db_at(p).meta.next = .some(db.num);
        }
        this.next_ = .some(db.num);

        return .{
            .db = db.ptr,
            .num = db.num,
        };
    }
};

fn IterMap(comptime It: type, comptime f: anytype) type {
    return struct {
        inner: It,
        const Item = @typeInfo(@TypeOf(f)).@"fn".return_type.?;

        const IterMap_ = @This();
        const Tmpl = struct {
            pub fn rest_len(this: IterMap_) @TypeOf(this.inner.rest_len()) {
                return this.inner.rest_len();
            }
            pub fn next(this: IterMap_) ?Item {
                return f(this.inner.next() orelse return null);
            }
            pub fn next_back(this: IterMap_) ?Item {
                return f(this.inner.next_back() orelse return null);
            }
        };

        const has = std.meta.hasMethod;
        pub const rest_len = if (has(It, "rest_len")) Tmpl.rest_len else {};
        pub const next = if (has(It, "next")) Tmpl.next else {};
        pub const next_back = if (has(It, "next_back")) Tmpl.next_back else {};
    };
}

inline fn iter_map(
    iter: anytype,
    comptime f: anytype,
) IterMap(@TypeOf(iter), f) {
    return .{ .inner = iter };
}

fn IterChain(comptime ItA: type, comptime ItB: type) type {
    return struct {
        a: ItA,
        a_done: bool = false,
        b: ItB,
        b_done_back: bool = false,

        const IterChain_ = @This();
        const Tmpl = struct {
            pub fn rest_len(this: IterChain_) @TypeOf(this.a.rest_len()) {
                return this.a.rest_len().add(this.b.rest_len());
            }
            pub fn next(this: *IterChain_) @TypeOf(this.a.next()) {
                if (!this.a_done) if (this.a.next()) |a| return a;
                this.a_done = true;
                return this.b.next();
            }
            pub fn next_back(this: *IterChain_) @TypeOf(this.a.next_back()) {
                if (!this.b_done_back) if (this.b.next_back()) |b| return b;
                this.b_done_back = true;
                return this.a.next_back();
            }
        };

        const has = std.meta.hasMethod;
        pub const rest_len = if (has(ItA, "rest_len")) Tmpl.rest_len else {};
        pub const next = if (has(ItA, "next")) Tmpl.next else {};
        pub const next_back = if (has(ItA, "next_back")) Tmpl.next_back else {};
    };
}

inline fn iter_chain(
    iter_a: anytype,
    iter_b: anytype,
) IterChain(@TypeOf(iter_a), @TypeOf(iter_b)) {
    return .{ .a = iter_a, .b = iter_b };
}

fn calc_split_lens(
    comptime B: type,
    comptime BTotalLen: type,
    args: struct {
        b_len_min: B.Len,
        alloc_len: BTotalLen,
        ofs_in_targ: B.Len,
        targ: TargBInfo(B),
        left: BInfo(B),
        right: BInfo(B),
    },
) struct {
    prefix: BTotalLen,
    postfix: BTotalLen,
    spill: B.Len,
    left_new: B.Len,
    right_new: B.Len,
    new_bs: B.Num,
} {
    const total_len: BTotalLen = args.alloc_len
        .add(.coerce(args.left.len))
        .add(.coerce(args.right.len));
    const total_bs: B.Num =
        .cast(total_len.to_int() / args.b_len_min.to_int());
    const spill_len: B.Len =
        .cast(total_len.to_int() % args.b_len_min.to_int());
    assert(total_bs.to_int() >= 3);
    const new_bs: B.Num = total_bs.sub(.coerce(2));

    const prefix_len: BTotalLen = if (args.left.block == args.targ.block)
        .coerce(args.ofs_in_targ)
    else if (args.right.block == args.targ.block)
        BTotalLen.coerce(args.left.len).add(.coerce(args.ofs_in_targ))
    else
        unreachable;
    const postfix_len: BTotalLen = BTotalLen.coerce(args.right.len)
        .add(.coerce(args.left.len))
        .sub(prefix_len);

    assert(spill_len.to_int() <= args.b_len_min.to_int());
    const spill_len_l: B.Len = .min(
        .sub(.max_val, args.b_len_min),
        spill_len,
    );
    const spill_len_r: B.Len = spill_len.sub(spill_len_l);

    const left_len_new: B.Len = spill_len_l.add(args.b_len_min);
    const right_len_new: B.Len = spill_len_r.add(args.b_len_min);

    assert(BTotalLen.eql(
        BTotalLen.coerce(left_len_new)
            .add(.coerce(right_len_new))
            .add(.cast(args.b_len_min.to_int() * new_bs.to_int())),
        total_len,
    ));

    return .{
        .prefix = prefix_len,
        .postfix = postfix_len,
        .spill = spill_len,
        .left_new = left_len_new,
        .right_new = right_len_new,
        .new_bs = new_bs,
    };
}

fn BInfo(comptime B: type) type {
    return struct { block: *B, len: B.Len, key_idx: Ib.Idx };
}

fn TargBInfo(comptime B: type) type {
    return struct {
        block: *B,
        len: B.Len,
        path_entry: switch (B) {
            Db => BPathEntry, // Db can't be root
            Ib => ?BPathEntry,
            else => unreachable,
        },
    };
}

fn Vicinity(comptime B: type) type {
    return struct {
        left: ?BInfo(B),
        targ: TargBInfo(B),
        right: ?BInfo(B),
    };
}

const PathLen = RangedInt(.path_entries, 0, bounds.indx_blocks_height_max);

fn vty_targ_ib(
    path: *const std.ArrayList(BPathEntry),
    path_cursor: ?PathLen,
) TargBInfo(Ib) {
    const path_entry: ?BPathEntry =
        if (path_cursor) |c| path.items[c.to_int()] else null;
    // Ib guaranteed to be parent of *something*
    const block =
        path.items[if (path_cursor) |c| c.to_int() + 1 else 0].parent_ib;
    return .{
        .len = .cast(block.count_keys()),
        .block = block,
        .path_entry = path_entry,
    };
}

fn vty_targ_db(
    r: *Rope,
    path: *const std.ArrayList(BPathEntry),
) TargBInfo(Db) {
    const path_entry: BPathEntry = path.items[path.items.len - 1];
    const block = r.db_at(path_entry.parent_ib.child_at(.cast(path_entry.key_idx))
        .as(Db.Num));
    return .{
        .len = .cast(
            path_entry.parent_ib
                .key_at(.cast(path_entry.key_idx))
                .unwrap().?,
        ),
        .block = block,
        .path_entry = path_entry,
    };
}

fn vty_sibling(
    r: *Rope,
    comptime B: type,
    comptime side: enum { left, right },
    targ_entry: BPathEntry,
) ?BInfo(B) {
    const targ_key_idx: Ib.Idx = Ib.Idx.cast(targ_entry.key_idx);
    const key_idx: Ib.Idx = switch (side) {
        .right => targ_key_idx.try_add(.coerce(1)) catch return null,
        .left => targ_key_idx.try_sub(.coerce(1)) catch return null,
    };
    if (side == .right and
        targ_entry.parent_ib.key_at(key_idx).unwrap() == null)
        return null;

    const block: *B = switch (B) {
        Ib => r.ib_at(targ_entry.parent_ib.child_at(key_idx).as(Ib.Num)),
        Db => r.db_at(targ_entry.parent_ib.child_at(key_idx).as(Db.Num)),
        else => unreachable,
    };

    const len: B.Len = switch (B) {
        Ib => block.count_keys(),
        Db => .cast(targ_entry.parent_ib.key_at(key_idx).unwrap().?),
        else => unreachable,
    };

    return .{
        .len = len,
        .key_idx = key_idx,
        .block = block,
    };
}

inline fn as_option(maybe_opt: anytype) ?switch (@typeInfo(@TypeOf(maybe_opt))) {
    .optional => |o| o.child,
    else => @TypeOf(maybe_opt),
} {
    return maybe_opt;
}

fn insert_with_siblings(
    r: *Rope,
    comptime B: type,
    comptime BTotalLen: type,
    items: anytype,
    args: struct {
        path: *const std.ArrayList(BPathEntry),
        /// index of the entry in path pointing to targ. -1 == null == root
        path_cursor: ?PathLen,
        vty: *Vicinity(B),
        ofs_in_targ: B.Len,
    },
) !?insert_in_blocks_Result(B) {
    const alloc_len: BTotalLen = .cast(items.rest_len());
    const path = args.path;
    const path_cursor = args.path_cursor;
    const vty = args.vty;
    // we should be the ones to populate these
    assert(vty.left == null);
    assert(vty.right == null);

    // path_cursor = null means we are at the root.
    // i.e. no path entry corresponds to targ.
    assert(path.items.len >= if (path_cursor) |c| c.add(.coerce(1)).to_int() else 0);
    assert(path.items.len == r.indx_height.to_int());

    var direct_space: BTotalLen = .cast(B.Len.max_val.sub(vty.targ.len));
    inline for (.{ .right, .left }) |side| {
        const binfo = r.vty_sibling(B, side, as_option(vty.targ.path_entry).?);
        @field(vty, @tagName(side)) = binfo;

        const new_space: B.Len =
            if (binfo) |bi| B.Len.max_val.sub(bi.len) else .coerce(0);
        log.debug(@src(), "side has space", .{
            .side = side,
            .space = new_space.to_int(),
        });
        direct_space = direct_space.add(.coerce(new_space.to_int()));

        if (direct_space.to_int() >= alloc_len.to_int()) {
            log.info(@src(), "fits in direct_space", .{
                .direct_space = direct_space,
            });

            return insert_in_blocks(B, BTotalLen, items, .{
                .targ = .{
                    .block = vty.targ.block,
                    .len = vty.targ.len,
                },
                .right = if (vty.right) |right| .{
                    .block = right.block,
                    .len = right.len,
                } else null,
                .left = if (vty.left) |left| .{
                    .block = left.block,
                    .len = left.len,
                } else null,
                .ofs = args.ofs_in_targ,
            });
        }
    }
    return null;
}

fn insert_in_blocks_Result(comptime B: type) type {
    return struct {
        block: *B,
        ofs: B.Len,
        left_len_new: ?B.Len,
        targ_len_new: B.Len,
        right_len_new: ?B.Len,
    };
}

/// Insert items from iterator into vicinity of blocks.
///
/// Items iterator must have:
/// - rest_len() castable to TTotalLen
/// - one of next()/take()/take_str()/take_nop()/take_db_slice()
/// - a _back() version of the above
///
/// FOR `T == Ib`:
/// `args.right` and `args.targ` MAY be empty.
/// `args.right` is empty when there was a reroot right before calling this fn.
fn insert_in_blocks(
    comptime T: type,
    comptime TTotalLen: type,
    items: anytype,
    args: struct {
        left: ?struct { block: *T, len: T.Len } = null,
        targ: struct { block: *T, len: T.Len },
        right: ?struct { block: *T, len: T.Len } = null,
        ofs: T.Len,
    },
) insert_in_blocks_Result(T) {
    log.debug(@src(), "insert_in_blocks()", .{ .items = items, .args = args });

    const orig_alloc_len: TTotalLen = .cast(items.rest_len());

    var rest = .{
        .prefix = args.targ.block.slice(null, args.ofs),
        .alloc = items,
        .postfix = args.targ.block.slice(args.ofs, args.targ.len),
    };

    // See fn-level comment. Only right and targ may be empty.
    if (T == Ib) if (args.left) |left| assert(left.len.to_int() >= 2);

    const left_len_new: ?T.Len = if (args.left) |left| left_len_new: {
        var left_rest = left.block.slice(left.len, .max_val);

        parts_loop: inline for (.{
            &rest.prefix,
            rest.alloc,
            &rest.postfix,
        }) |part_rest| {
            if (left_rest.len.eql(.min_val)) break :parts_loop;
            const write_len: T.Len = T.write(left_rest, part_rest);
            left_rest = left_rest.slice(write_len, null);
        }

        assert(left_rest.len.eql(.min_val));
        break :left_len_new .max_val;
    } else null;

    const overflow_len: T.Len = x: {
        const total_rest: TTotalLen = TTotalLen.cast(rest.alloc.rest_len())
            .add(.coerce(rest.prefix.len))
            .add(.coerce(rest.postfix.len));
        const of_len: T.Len =
            .cast(total_rest.sub_saturating(.coerce(T.Len.max_val)));

        // See fn-level comment.
        // We take a min of 2 to fill empty blocks due to rerooting.
        if (T == Ib) if (args.right) |right| {
            const right_len_new: T.Len = .max(
                right.len.add(of_len),
                .coerce(2),
            );
            break :x right_len_new.sub(right.len);
        };
        break :x of_len;
    };

    const right_len_new: ?T.Len =
        if (overflow_len.to_int() > 0) right_len_new: {
            const right = args.right.?;
            // alloc overflow in front of right
            T.copyBackwards(
                right.block.slice(overflow_len, .max_val)
                    .slice(null, right.len),
                right.block
                    .slice(null, right.len),
            );
            var right_rest = right.block.slice(null, overflow_len);

            // in reverse order now
            parts_loop: inline for (.{
                &rest.postfix,
                rest.alloc,
                &rest.prefix,
            }) |part_rest| {
                if (right_rest.len.eql(.min_val)) break :parts_loop;
                const write_len: T.Len = T.write_back(right_rest, part_rest);
                right_rest =
                    right_rest.slice(null, right_rest.len.sub(write_len));
            }

            assert(right_rest.len.eql(.min_val));
            break :right_len_new .add(right.len, overflow_len);
        } else if (args.right) |right| right.len else null;

    const targ = args.targ;

    // assert total rest is <= max block len
    const targ_len_new: T.Len = .cast(TTotalLen.cast(rest.alloc.rest_len())
        .add(.coerce(rest.prefix.len))
        .add(.coerce(rest.postfix.len)));
    if (T == Ib) {
        // we need to leave at least two children to be able to split later.
        assert(targ_len_new.to_int() >= 2);
    }

    var targ_rest = targ.block.slice(null, targ_len_new);
    // prefix can only slide to the left. so start with that.
    T.copyForwards(targ_rest.slice(null, rest.prefix.len), rest.prefix);
    targ_rest = targ_rest.slice(rest.prefix.len, null);
    // write postfix (might need to move out of the way for alloc)
    {
        const dst = targ_rest.slice(targ_rest.len.sub(rest.postfix.len), null);
        assert(dst.block == rest.postfix.block);
        if (dst.ofs.to_int() > rest.postfix.ofs.to_int())
            T.copyBackwards(dst, rest.postfix)
        else
            T.copyForwards(dst, rest.postfix);
        targ_rest = targ_rest.slice(null, targ_rest.len.sub(rest.postfix.len));
    }
    // write alloc
    {
        const write_len: T.Len = T.write(targ_rest, rest.alloc);
        targ_rest = targ_rest.slice(write_len, null);
        assert(TTotalLen.cast(rest.alloc.rest_len()).eql(.min_val));
    }
    assert(targ_rest.len.eql(.min_val));

    const new_pos: struct {
        block: *T,
        ofs: T.Len,
    } = if (args.left) |left| x: {
        const shl_amt = T.Len.max_val.sub(left.len);
        break :x if (shl_amt.to_int() > args.ofs.to_int()) .{
            .block = left.block,
            .ofs = .add(left.len, args.ofs),
        } else .{
            .block = targ.block,
            .ofs = .sub(args.ofs, shl_amt),
        };
    } else .{
        .block = targ.block,
        .ofs = args.ofs,
    };

    if (T == Ib) {
        // we need to leave at least two children to be able to split later.
        assert(targ_len_new.to_int() >= 2);
        if (left_len_new) |ln|
            assert(ln.to_int() >= 2);
        if (right_len_new) |rn|
            assert(rn.to_int() >= 2);
    }

    assert(TTotalLen.eql(
        TTotalLen.coerce(targ_len_new)
            .add(.coerce(left_len_new orelse T.Len.min_val))
            .add(.coerce(right_len_new orelse T.Len.min_val)),
        TTotalLen.coerce(args.targ.len)
            .add(.coerce(if (args.left) |left| left.len else T.Len.min_val))
            .add(.coerce(if (args.right) |right| right.len else T.Len.min_val))
            .add(orig_alloc_len),
    ));

    return .{
        .block = new_pos.block,
        .ofs = new_pos.ofs,
        .left_len_new = left_len_new,
        .targ_len_new = targ_len_new,
        .right_len_new = right_len_new,
    };
}

/// Write args.right content directly after args.left. Filling args.left.block
/// first and then possibly overflowing into the beginning of args.right.block.
fn join_blocks(
    comptime B: type,
    args: struct {
        left: B.Slice,
        right: B.Slice,
    },
) struct {
    left_len_new: B.Len,
    right_len_new: B.Len,
} {
    const TTotalLen = RangedInt(
        B.Len.tag,
        B.Len.min_val.to_int(),
        @as(comptime_int, B.Len.max_val.to_int()) * 2,
    );

    assert(args.left.ofs.eql(.coerce(0)));
    assert(args.left.block != args.right.block);

    const len_total =
        TTotalLen.coerce(args.left.len).add(.coerce(args.right.len));
    const len_l_new, //
    const len_r_new = x: {
        var len_l_new: B.Len = .trunc(len_total);
        var len_r_new: B.Len = .cast(len_total.sub(.coerce(len_l_new)));
        if (B == Ib) {
            // We need a min of 2 blocks in Ibs for eventual splitting
            if (0 < len_r_new.to_int() and len_r_new.to_int() < 2) {
                const diff: B.Len = B.Len.cast(2).sub(len_r_new);
                len_l_new = len_l_new.sub(diff);
                len_r_new = len_r_new.add(diff);
                assert(len_l_new.to_int() >= 2);
                assert(len_r_new.to_int() >= 2);
            }
        }
        break :x .{ len_l_new, len_r_new };
    };

    var wslice = args.right;
    assert(args.left.ofs.eql(.coerce(0)));
    const dst_l = args.left.block.slice(args.left.len, len_l_new);
    _ = B.write(dst_l, &wslice);
    assert(wslice.len.eql(len_r_new));
    const dst_r = args.right.block.slice(null, len_r_new);
    // NOTE: we are relying on T.copy detecting the overlapping write and using
    //       `std.mem.copyForwards`
    B.copy(dst_r, wslice);

    return .{
        .left_len_new = len_l_new,
        .right_len_new = len_r_new,
    };
}

const Side = enum { left, right };

/// Find the nearest outward neighbour of the parent_ibs at the tips of the
/// paths.
fn delete__find_nearest_neighbour(
    left: []const BPathEntry,
    right: []const BPathEntry,
    out: []BPathEntry,
) ?Side {
    assert(left.len == right.len);
    assert(left.len == out.len);

    // search both left and right sides concurrently so we can find the nearest
    for (0..left.len) |i_rev| {
        const i = left.len - 1 - i_rev;
        // Find the first parent layer with a outer sibling branch
        if (left[i].key_idx.to_int() > 0) {
            @memcpy(out[i + 1 ..], left[i + 1 ..]);
            out[i] = .{
                .parent_ib = left[i].parent_ib,
                .key_idx = left[i].key_idx.sub(.coerce(1)),
            };
            for (out[0..i], left[0..i]) |*o, l| {
                o.* = .{
                    .parent_ib = l.parent_ib,
                    .key_idx = l.parent_ib.count_keys().sub(.coerce(1)),
                };
            }
            return .left;
        }
        if (right[i].key_idx.to_int() < Ib.Idx.max_val.to_int() and
            right[i].key_idx.to_int() < right[i].parent_ib.count_keys().to_int())
        {
            @memcpy(out[i + 1 ..], right[i + 1 ..]);
            out[i] = .{
                .parent_ib = right[i].parent_ib,
                .key_idx = right[i].key_idx.add(.coerce(1)),
            };
            for (out[0..i], right[0..i]) |*o, l| {
                o.* = .{
                    .parent_ib = l.parent_ib,
                    .key_idx = .coerce(0),
                };
            }
            return .right;
        }
    }
    // This means there's NOTHING on the same layer as left+right outside of
    // the [left,right] cone
    return null;
}

test alloc_at {
    std.testing.log_level = .debug;

    var r = Rope.init(std.testing.allocator);
    defer r.deinit();

    try r.expect_valid();

    for ([_]struct { RopeBytes, u8 }{
        .{ .coerce(0), 'a' },
        .{ .coerce(10), 'b' },
        .{ .coerce(100), 'c' },
        .{ .coerce(100), 'd' },
        .{ .coerce(200), 'e' },
        .{ .coerce(300), 'f' },
        .{ .coerce(1000), 'g' },
        .{ .coerce(10000), 'h' },
    }) |e| {
        const len, const char = e;

        tlog.info(@src(), "======== alloc_at ========", .{ .len = len });
        tlog.debug(@src(), "rope.indx_root", .{ .indx_root = r.indx_root });
        tlog.debug(@src(), "rope.indx_root", .{ .indx_root = r.ib_at(r.indx_root) });
        var rest = len;
        var cur: Cursor = undefined;
        while (rest.to_int() > 0) {
            const res = try r.alloc_at(.coerce(0), .cast(len));
            try r.expect_valid();
            rest = rest.sub(res.alloc_len);
            cur = res.cursor;
        }
        var cur_writer = cur.writer(&r, &.{});
        try cur_writer.writer.splatByteAll(char, len.to_int());
    }
}

pub fn insert(r: *Rope, pos: RopeBytes, text: []const u8) !void {
    // TODO: idea for better cache locality:
    // - First write all text to dbs
    // - Then iteratively insert dbs into tree
    // - Bonus: store dbs in a SoA such that the bytes end up all in one single
    //   big array. Then unfragmented reads are physically identical to normal
    //   string reads and cache prediction basically is 100% correct.
    // - Bonus^2: If we do all the above, we can defragment a rope by just
    //   inserting it's content to a new rope. (insert can take an iterator of
    //   bytes that can delete text chunks from the old rope as we read them. A
    //   sort of "sink" or "drain" iterator.)

    var rest: RopeBytes = .cast(text.len);
    var i: usize = 0;
    var pos_cursor: Cursor = undefined;
    while (rest.to_int() > 0) : (i += 1) {
        if (i >= 1000) @panic("reached max iterations. probably a bug.");

        const res = try r.alloc_at(pos, rest);
        rest = rest.sub(res.alloc_len);
        pos_cursor = res.cursor;
    }
    var writer = pos_cursor.writer(r, &.{});
    writer.writer.writeAll(text) catch unreachable;
}

test "insert-fuzz" {
    std.testing.log_level = .debug;
    // makes for easier print debugging
    const gen_ascii = false;
    const gpa = std.testing.allocator;

    var rope = Rope.init(gpa);
    defer rope.deinit();

    try rope.expect_valid();

    var str: std.ArrayList(u8) = .empty;
    defer str.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    // var prng = std.Random.DefaultPrng.init(0xd946e30);
    const rand = prng.random();

    // not used to generate actual test case but just inserted data.
    var prng2 = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand2 = prng2.random();

    var buf: [1 << 19]u8 = undefined;

    var total_rope_ns: u64 = 0;
    var total_str_ns: u64 = 0;

    for (0..20) |exp| {
        const max_len = @as(usize, 1) << @as(u5, @intCast(exp));

        for (0..200) |_| {
            // for (0..20) |_| {
            const pos: RopeBytes =
                .cast(rand.uintAtMost(usize, rope.get_len().to_int()));
            const text = buf[0..rand.uintLessThan(usize, max_len)];
            if (comptime gen_ascii) {
                // for (text) |*c| c.* = rand2.uintLessThan(u8, 'z' - 'a') + 'a';
                @memset(text, rand2.uintLessThan(u8, 'z' - 'a') + 'a' - (if (rand2.boolean()) ('a' - 'A') else @as(u8, 0)));
            } else {
                rand2.bytes(text);
            }
            // tlog.info(@src(), "-- INSERT --", .{ .pos = pos, .text = text });
            var timer = std.time.Timer.start() catch unreachable;
            try rope.insert(pos, text);
            total_rope_ns += timer.lap();
            try str.insertSlice(gpa, pos.to_int(), text);
            total_str_ns += timer.lap();
            // try rope.expect_valid();
            // try std.testing.expectFmt(str.items, "{s}", .{&rope});
        }
    }

    try rope.expect_valid();
    try std.testing.expectFmt(str.items, "{f}", .{rope.fmtString()});

    var block_counts_store: [bounds.indx_blocks_height_max]u32 = undefined;
    var block_counts: std.ArrayList(u32) = .initBuffer(&block_counts_store);
    rope.count_blocks(&block_counts);

    const total_rope_s = @as(f64, @floatFromInt(total_rope_ns)) /
        @as(f64, @floatFromInt(std.time.ns_per_s));
    const total_str_s = @as(f64, @floatFromInt(total_str_ns)) /
        @as(f64, @floatFromInt(std.time.ns_per_s));

    tlog.info(@src(), "PASS", .{
        .len = rope.get_len(),
        .rope_s = total_rope_s,
        .str_s = total_str_s,
        .ib_count = rope.indx_blocks.segm_list.len,
        .db_count = rope.data_blocks.segm_list.len,
        .block_counts = block_counts.items,
    });
}

pub fn delete(r: *Rope, beg: RopeBytes, end: RopeBytes) void {
    assert(beg.to_int() <= end.to_int());
    if (beg.eql(end)) return;

    // The left and right paths are like beams cutting through the tree, and
    // together they form the CONE OF DESTRUCTION.
    var beg_path_buf: BPathBuf = undefined;
    var eng_path_buf: BPathBuf = undefined;
    var beg_path: std.ArrayList(BPathEntry) = .initBuffer(&beg_path_buf);
    var end_path: std.ArrayList(BPathEntry) = .initBuffer(&eng_path_buf);
    const beg_ofs_in_db = r.find_data_block(beg, &beg_path);
    const end_ofs_in_db = r.find_data_block(end, &end_path);
    assert(beg_path.items.len == end_path.items.len);
    assert(beg_path.items.len == r.indx_height.to_int());
    assert(r.indx_height.to_int() > 0);

    {
        const i = beg_path.items.len - 1;
        const beg_entry: BPathEntry = beg_path.items[i];
        const end_entry: BPathEntry = end_path.items[i];
        const beg_db: NumAndPtr(Db) = x: {
            const num = beg_entry.parent_ib
                .child_at(.cast(beg_entry.key_idx)).as(Db.Num);
            break :x .{ .num = num, .ptr = r.db_at(num) };
        };
        const end_db: NumAndPtr(Db) = if (std.meta.eql(beg_entry, end_entry)) x: {
            // Most interactive deletions are local to a single data block.
            @branchHint(.likely);
            break :x beg_db;
        } else x: {
            const num = end_entry.parent_ib
                .child_at(.cast(end_entry.key_idx)).as(Db.Num);
            break :x .{ .num = num, .ptr = r.db_at(num) };
        };

        r.delete__delete_layer(Db, .{
            .beg = .{ .b = beg_db.ptr, .ofs = beg_ofs_in_db },
            .end = .{ .b = end_db.ptr, .ofs = end_ofs_in_db },
            .beg_parent_path = beg_path.items,
            .end_parent_path = end_path.items,
            .extra = .{
                .beg_num = beg_db.num,
                .end_num = end_db.num,
            },
        });
    }

    // delete all full blocks within the CONE OF DESTRUCTION.
    // and stitch together partial block ends
    for (0..beg_path.items.len) |i_rev| {
        const i = beg_path.items.len - i_rev - 1;
        if (i_rev == 0) assert(i == beg_path.items.len - 1);
        if (i == 0) assert(i_rev == beg_path.items.len - 1);

        const beg_entry: BPathEntry = beg_path.items[i];
        const end_entry: BPathEntry = end_path.items[i];

        if (std.meta.eql(beg_entry, end_entry)) {
            break;
        }

        // include 0-len start/end blocks in rm range
        // these ends are 0 if the cone-of-destr. perfectly lines up with
        // the edge of the ib subtree and so the lower-layer deletion makes
        // the parent end up empty.
        const beg_key, //
        const end_key = .{
            beg_entry.parent_ib.key_at(.cast(beg_entry.key_idx)).unwrap().?,
            end_entry.parent_ib.key_at(.cast(end_entry.key_idx)).unwrap().?,
        };
        const beg_ofs, //
        const end_ofs = .{
            if (beg_key.eql(.coerce(0)))
                beg_entry.key_idx
            else
                beg_entry.key_idx.add(.coerce(1)),
            if (end_key.eql(.coerce(0)))
                end_entry.key_idx.add(.coerce(1))
            else
                end_entry.key_idx,
        };

        r.delete__delete_layer(Ib, .{
            .beg = .{ .b = beg_entry.parent_ib, .ofs = beg_ofs },
            .end = .{ .b = end_entry.parent_ib, .ofs = end_ofs },
            .beg_parent_path = beg_path.items[0..i],
            .end_parent_path = end_path.items[0..i],
            .extra = .{
                .height = if (i_rev == 0) .db_parent else .ib_parent,
            },
        });
    }

    // Reroot/squash left-behind invalid single-child top layers
    const root = r.ib_at(r.indx_root);
    for (0..r.indx_height.sub(.coerce(1)).to_int()) |_| {
        if (!root.count_keys().eql(.coerce(1)))
            break;

        const child_num = root.child_at(.coerce(0)).as(Ib.Num);
        const child = r.ib_at(child_num);
        assert(child.sum_subtree_bytes()
            .eql(.coerce(root.key_at(.coerce(0)).unwrap().?)));
        root.* = child.*;
        r.indx_blocks.destroy(child_num);
    }
    assert(!root.count_keys().eql(.coerce(1)));
}

fn BCursor(comptime B: type) type {
    return struct {
        b: *B,
        ofs: B.Len,
    };
}
fn delete__delete_layer(
    r: *Rope,
    comptime B: type,
    args: struct {
        // we can for the ib layers just pass in the path
        // but for the db layer we don't have a pathentry
        //
        /// rm beg inclusive
        beg: BCursor(B),
        /// rm end exclusive
        end: BCursor(B),
        beg_parent_path: []const BPathEntry,
        end_parent_path: []const BPathEntry,
        extra: switch (B) {
            Ib => struct {
                height: enum {
                    ib_parent,
                    db_parent,
                },
            },
            Db => struct {
                beg_num: Db.Num,
                end_num: Db.Num,
            },
            else => unreachable,
        },
    },
) void {
    // Special Case: delete slice within same parent
    if (args.beg.b == args.end.b) {
        @branchHint(switch (B) {
            // Most interactive deletions are local to a single data block.
            Db => .likely,
            // Less likely as most of the time we are on a layer that isn't the
            // root of the cone of destruction.
            Ib => .unlikely,
            else => unreachable,
        });

        assert(args.beg.ofs.to_int() <= args.end.ofs.to_int());

        {
            const rm = args.beg.b.slice(args.beg.ofs, args.end.ofs);
            switch (B) {
                Db => {},
                Ib => switch (args.extra.height) {
                    .db_parent => for (rm.children()) |c|
                        r.data_blocks.destroy(c.as(Db.Num)),
                    .ib_parent => for (rm.children()) |c|
                        r.delete__destroy_subtree(c.as(Ib.Num)),
                },
                else => unreachable,
            }
        }

        // Shift the right content to be adjacent to the left
        const len_old = args.beg.b.get_len();
        const len_new = len_old.sub(args.end.ofs.sub(args.beg.ofs));

        var slice_from = args.beg.b.slice(args.end.ofs, len_old);
        const slice_to = args.beg.b.slice(args.beg.ofs, len_old);
        _ = B.write(slice_to, &slice_from);
        assert(slice_from.len.eql(.coerce(0)));

        args.beg.b.set_len(len_new);

        // unlucky case :( see equivalent below
        if (len_new.eql(.coerce(1))) {
            const side = r.delete__single_child_to_neigh(B, .{
                .beg_parent_path = args.beg_parent_path,
                .end_parent_path = args.end_parent_path,
                .beg_b = args.beg.b,
                .end_b = args.end.b,
            });
            assert(args.beg.b.get_len().eql(.coerce(
                @as(u1, if (side) |_| 0 else
                // [CASE. no neighbour found]:
                // Do nothing. leave a trail up to the root of 1-length
                // blocks. We will have a reroot pass to clean this up
                // later.
                //
                // If no neighbours to this block were found then this must be
                // either root or only-child of string of only-childs up to
                // root.
                1),
            )));
        }

        const subtree_size = args.beg.b.get_subtree_bytes();
        update_parent_keys(args.beg_parent_path, .cast(subtree_size));
        return;
    }

    const len_old = .{
        .l = args.beg.b.get_len(),
        .r = args.end.b.get_len(),
    };

    switch (B) {
        Ib => {
            const rm_ls = args.beg.b.slice(args.beg.ofs, len_old.l);
            const rm_rs = args.end.b.slice(null, args.end.ofs);
            switch (args.extra.height) {
                .db_parent => {
                    for (rm_ls.children()) |rm_l|
                        r.data_blocks.destroy(rm_l.as(Db.Num));
                    for (rm_rs.children()) |rm_r|
                        r.data_blocks.destroy(rm_r.as(Db.Num));
                },
                .ib_parent => {
                    for (rm_ls.children()) |rm_l|
                        r.delete__destroy_subtree(rm_l.as(Ib.Num));
                    for (rm_rs.children()) |rm_r|
                        r.delete__destroy_subtree(rm_r.as(Ib.Num));
                },
            }
        },
        Db => {},
        else => unreachable,
    }

    // Now join this layer's left and right and update the immediate
    // parents

    const res = join_blocks(B, .{
        .left = args.beg.b.slice(null, args.beg.ofs),
        .right = args.end.b.slice(args.end.ofs, len_old.r),
    });

    assert(res.right_len_new.eql(.coerce(0)) or
        res.right_len_new.to_int() >= 2);

    args.beg.b.set_len(res.left_len_new);
    args.end.b.set_len(res.right_len_new);

    // == UNLUCKY CASE :( ==
    //
    // We deleted all but one of the children of $l||r$.
    // So now we are left with an invalid l = [single child].
    // We have to put this single child somewhere.
    if (res.left_len_new.eql(.coerce(1))) {
        assert(res.right_len_new.eql(.coerce(0)));
        const side = r.delete__single_child_to_neigh(B, .{
            .beg_parent_path = args.beg_parent_path,
            .end_parent_path = args.end_parent_path,
            .beg_b = args.beg.b,
            .end_b = args.end.b,
        });
        assert(args.beg.b.get_len().eql(.coerce(
            @as(u1, if (side) |_| 0 else
            // [CASE. no neighbour found]:
            // Do nothing. leave a trail up to the root of 1-length
            // blocks. We will have a reroot pass to clean this up
            // later.
            1),
        )));
        assert(args.end.b.get_len().eql(.coerce(0)));
    }

    if (B == Db) {
        // Skip over deleted data block range in linked list
        //
        // (the data blocks themselves will be deleted as part of cone of
        // destruction subtree deletion below without needing to worry
        // anymore about the linked list fixup)
        args.end.b.meta.next = .some(args.extra.end_num);
        args.beg.b.meta.prev = .some(args.extra.beg_num);
    }

    const left_bytes: TreeSize = .cast(args.beg.b.get_subtree_bytes());
    const right_bytes: TreeSize = .cast(args.end.b.get_subtree_bytes());
    update_parent_keys(args.beg_parent_path, left_bytes);
    update_parent_keys(args.end_parent_path, right_bytes);
}

fn delete__single_child_to_neigh(
    r: *Rope,
    comptime B: type,
    args: struct {
        beg_parent_path: []const BPathEntry,
        end_parent_path: []const BPathEntry,
        beg_b: *B,
        end_b: *B,
    },
) ?Side {
    assert(args.beg_b.get_len().eql(.coerce(1)));
    assert(args.end_b.get_len().eql(.coerce(0)));
    // Either fit this into a neighbour block or take one away from
    // a neighbour block.
    //
    // neighbour candidates:
    // 1. just left of args.beg.b
    // 2. just right of args.end.b
    //    this works because if left_len_new == 1 then right_len_new
    //    must be 0.
    // 3. NO NEIGHBOURS, this means we need to reroot

    // need the path of the neighbour block so we can update the
    // parent keys
    var neigh_path_store: [
        bounds.indx_blocks_height_max
    ]BPathEntry = undefined;
    const neigh_path = neigh_path_store[0..args.beg_parent_path.len];
    const side = delete__find_nearest_neighbour(
        args.beg_parent_path,
        args.end_parent_path,
        neigh_path,
    ) orelse return null;

    const neigh_parent_entry = neigh_path[neigh_path.len - 1];
    const neigh_b_num = neigh_parent_entry.parent_ib.child_at(
        .cast(neigh_parent_entry.key_idx),
    ).as(B.Num);
    if (B == Db) assert(neigh_b_num.eql(switch (side) {
        .left => args.beg_b.meta.prev.unwrap().?,
        .right => args.end_b.meta.next.unwrap().?,
    }));
    const neigh_b = switch (B) {
        Ib => r.ib_at(neigh_b_num),
        Db => r.db_at(neigh_b_num),
        else => unreachable,
    };
    const neigh_b_len = neigh_b.get_len();
    if (neigh_b_len.eql(.max_val)) {
        // take one from neighbour
        switch (side) {
            .left => args.beg_b.push_front(neigh_b.pop()),
            .right => args.beg_b.push(neigh_b.pop_front()),
        }
        assert(neigh_b.get_len()
            .eql(B.Len.max_val.sub(.coerce(1))));
        assert(args.beg_b.get_len().eql(.coerce(2)));
    } else {
        // add only-child to neighbour
        switch (side) {
            .left => neigh_b.push(args.beg_b.pop()),
            .right => neigh_b.push_front(args.beg_b.pop()),
        }
        assert(neigh_b.get_len()
            .eql(neigh_b_len.sub(.coerce(1))));
        assert(args.beg_b.get_len().eql(.coerce(0)));
    }

    const neigh_bytes: TreeSize = .cast(neigh_b.get_subtree_bytes());
    update_parent_keys(neigh_path, neigh_bytes);
    return side;
}

fn delete__destroy_subtree(r: *Rope, num: Ib.Num) void {
    const Frame = struct {
        ib: *Ib,
        num: Ib.Num,
        len: Ib.Len,
        key_idx: Ib.Len = .coerce(0),
    };
    var stack_buf: [bounds.indx_blocks_height_max]Frame = undefined;
    var stack: std.ArrayList(Frame) = .initBuffer(&stack_buf);

    const ib = r.ib_at(num);
    stack.appendAssumeCapacity(.{
        .ib = ib,
        .num = num,
        .len = ib.count_keys(),
    });

    var i: usize = 0;
    while (stack.items.len > 0) {
        if (i >= bounds.indx_blocks_max)
            @panic("reached max iterations. probably a bug.");
        i += 1;

        const frame = &stack.items[stack.items.len - 1];
        assert(frame.key_idx.to_int() <= frame.len.to_int());

        if (frame.key_idx.to_int() < frame.len.to_int()) {
            const child_num = frame.ib.child_at(.cast(frame.key_idx));
            if (stack.items.len < r.indx_height.to_int()) {
                const child_ib = r.ib_at(child_num.as(Ib.Num));
                stack.appendAssumeCapacity(.{
                    .ib = child_ib,
                    .num = child_num.as(Ib.Num),
                    .len = child_ib.count_keys(),
                });
            } else {
                assert(stack.items.len == r.indx_height.to_int());
                r.data_blocks.destroy(child_num.as(Db.Num));
            }
            frame.key_idx = frame.key_idx.add(.coerce(1));
        } else {
            assert(frame.key_idx.eql(frame.len));
            r.indx_blocks.destroy(frame.num);
            _ = stack.pop() orelse unreachable;
        }
    }
}

pub fn get_len(r: *const Rope) RopeBytes {
    return r.ib_at_const(r.indx_root).sum_subtree_bytes();
}

pub fn fmtString(r: *Rope) std.fmt.Alt(*Rope, formatString) {
    return .{ .data = r };
}

/// use via `Rope.fmtString()`
pub fn formatString(
    r: *Rope,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var cursor = r.abs_cursor_at(.coerce(0));
    var reader = cursor.cursor.reader(r, &.{});
    _ = try (reader.reader.streamRemaining(w) catch |e| switch (e) {
        std.io.Reader.StreamRemainingError.ReadFailed => unreachable,
        std.io.Reader.StreamRemainingError.WriteFailed => |x| x,
    });
}

pub fn format(
    r: *Rope,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try w.print("Rope{{ ", .{});
    try w.print(".ib_root = {d}, ", .{r.indx_root});
    try w.print(".ib_height = {d}, ", .{r.indx_height});
    try w.print(".len = {d}, ", .{r.get_len()});
    try w.print("}}", .{});
}

pub fn jsonStringify(r: *const Rope, jw: anytype) !void {
    try jw.write(.{
        .ib_root = r.indx_root,
        .ib_height = r.indx_height,
        .len = r.get_len(),
    });
}

pub fn abs_cursor_at(r: *Rope, pos: RopeBytes) AbsCursor {
    var c: AbsCursor = undefined;
    c.seek_to(r, pos);
    return c;
}

// We can probably dumb down this abstraction. Used to have it's own
// writer/reader wrappers to track the abs pos but don't think that'll
// actually ever be useful.
pub const AbsCursor = struct {
    cursor: Cursor,
    pos: RopeBytes,

    pub fn seek_to(c: *AbsCursor, r: *Rope, pos: RopeBytes) void {
        var path_buf: BPathBuf = undefined;
        var path = std.ArrayList(BPathEntry).initBuffer(&path_buf);
        const ofs_in_db = r.find_data_block(pos, &path);
        const entry = path.items[path.items.len - 1];
        const db_num = entry.parent_ib
            .child_at(.cast(entry.key_idx)).as(Db.Num);
        c.* = .{
            .pos = pos,
            .cursor = .{
                .db = r.db_at(db_num),
                .ofs = ofs_in_db,
            },
        };
    }

    pub fn seek_by(c: *AbsCursor, r: *Rope, amt: RopeBytesSigned) void {
        c.pos = .cast(RopeBytesSigned.add(.coerce(c.pos), amt));
        c.cursor.seek_by(r, amt);
    }
};

// For reading/writing but no tree mutations. i.e. no (de)alloc of bytes.
//
// NOTE: For rope internal code, this is usually much less efficient than
//       manually copying chunks of data_blocks around as we often have much
//       more info at the callsite about the copy and we can make assumptions.
pub const Cursor = struct {
    db: *Db,
    ofs: Db.Len,

    pub const Reader = struct {
        r: *Rope,
        cursor: *Cursor,
        reader: std.io.Reader,
    };

    pub fn reader(c: *Cursor, r: *Rope, buffer: []u8) Reader {
        // TODO: more clever optimized rebase and readvec impls so that we can
        // copy full data blocks to the buffer when possible to avoid acessing
        // the same db multiple times. Or tbh it might just not make sense to
        // ever use this reader with a buffer. we need to measure...
        return .{
            .r = r,
            .cursor = c,
            .reader = .{
                .vtable = &.{
                    .stream = stream,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub const Writer = struct {
        r: *Rope,
        cursor: *Cursor,
        writer: std.io.Writer,
    };
    pub fn writer(c: *Cursor, r: *Rope, buffer: []u8) Writer {
        return .{
            .r = r,
            .cursor = c,
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = buffer,
                .end = 0,
            },
        };
    }

    fn stream(
        r_: *std.io.Reader,
        w: *std.io.Writer,
        limit: std.io.Limit,
    ) std.io.Reader.StreamError!usize {
        const r: *Reader = @fieldParentPtr("reader", r_);
        const c = r.cursor;
        assert(c.ofs.to_int() <= c.db.meta.bytes.to_int());
        if (c.ofs.eql(c.db.meta.bytes)) {
            c.db = r.r.db_at(c.db.meta.next.unwrap() orelse
                return std.io.Reader.StreamError.EndOfStream);
            c.ofs = .coerce(0);
        }

        const n = try w.write(limit.slice(
            c.db.bytes[c.ofs.to_int()..c.db.meta.bytes.to_int()],
        ));
        c.ofs = c.ofs.add(.cast(n));

        assert(c.ofs.to_int() <= c.db.meta.bytes.to_int());
        return n;
    }

    fn drain(
        w_: *std.io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.io.Writer.Error!usize {
        const w: *Writer = @fieldParentPtr("writer", w_);

        if (w.writer.end > 0) {
            var seek: usize = 0;
            while (seek < w.writer.end) {
                // NOTE: buffer is not fully consumed on WriteFailed due to
                //       rope being full.
                //       You should be confident that there is enough space
                //       in the rope before writing.
                const n = try w.cursor.write(w.r, w.writer.buffer[seek..w.writer.end]);
                seek += n;
            }
            assert(seek == w.writer.end);
            return 0;
        }

        if (data.len > 1) {
            return w.cursor.write(w.r, data[0]);
        }
        assert(data.len == 1);
        if (splat == 0) return 0;

        return w.cursor.write(w.r, data[0]);
    }

    const ByteIter = struct {
        bytes: []const u8,
        pub fn rest_len(this: ByteIter) usize {
            return this.bytes.len;
        }
        pub fn take_str(this: *ByteIter, n_: usize) []const u8 {
            const n: usize = @min(n_, this.bytes.len);
            const res = this.bytes[0..n];
            this.bytes = this.bytes[n..];
            return res;
        }
    };

    pub fn write(
        this: *Cursor,
        r: *Rope,
        src: []const u8,
    ) std.io.Writer.Error!usize {
        assert(this.ofs.to_int() <= this.db.meta.bytes.to_int());

        if (this.ofs.eql(this.db.meta.bytes)) {
            this.db = r.db_at(
                this.db.meta.next.unwrap() orelse
                    return std.io.Writer.Error.WriteFailed,
            );
            this.ofs = .coerce(0);
        }

        var iter: ByteIter = .{ .bytes = src };

        const cpy_len: Db.Len = Db.write(
            this.db.slice(this.ofs, this.db.meta.bytes),
            &iter,
        );
        this.ofs = this.ofs.add(cpy_len);

        assert(this.ofs.to_int() <= this.db.meta.bytes.to_int());
        return cpy_len.to_int();
    }

    pub fn seek_by(this: *Cursor, r: *Rope, amt: RopeBytesSigned) void {
        if (amt.eql(.coerce(0))) return;
        if (amt.to_int() < 0) return this.seek_back(r, .cast(
            RopeBytesSigned.coerce(0).sub(amt),
        ));
        return this.seek_forward(r, .cast(amt));
    }

    pub fn seek_forward(this: *Cursor, r: *Rope, amt_: RopeBytes) void {
        var amt = amt_;
        var i: usize = 0;
        while (!amt.eql(.min_val)) : (i += 1) {
            if (i >= bounds.data_blocks_max)
                @panic("reached max iterations. probably a bug.");

            const fwd_len: Db.Len = .cast(RopeBytes.min(
                amt,
                .coerce(this.db.meta.bytes.sub(this.ofs)),
            ));
            amt = amt.sub(.coerce(fwd_len));
            this.ofs = this.ofs.add(fwd_len);

            assert(this.ofs.to_int() <= this.db.meta.bytes.to_int());
            if (this.ofs.eql(this.db.meta.bytes)) {
                this.db = r.db_at(
                    this.db.meta.next.unwrap() orelse break,
                );
                this.ofs = .coerce(0);
            }
        }
        if (!amt.eql(.min_val))
            std.debug.panic("seek_forward out of bounds", .{});
    }
    pub fn seek_back(this: *Cursor, r: *Rope, amt_: RopeBytes) void {
        var amt = amt_;
        var i: usize = 0;
        while (!amt.eql(.min_val)) : (i += 1) {
            if (i >= bounds.data_blocks_max)
                @panic("reached max iterations. probably a bug.");

            if (this.ofs.eql(.min_val)) {
                this.db = r.db_at(
                    this.db.meta.prev.unwrap() orelse break,
                );
                this.ofs = this.db.meta.bytes;
            }

            assert(this.ofs.to_int() <= this.db.meta.bytes.to_int());
            const rev_len: Db.Len =
                .cast(RopeBytes.min(amt, .coerce(this.ofs)));
            amt = amt.sub(.coerce(rev_len));
            this.ofs = this.ofs.sub(rev_len);
        }
        if (!amt.eql(.min_val))
            std.debug.panic("seek_back out of bounds", .{});
    }
};

fn expect_valid(r: *Rope) !void {
    try std.testing.expect(r.indx_height.to_int() > 0);
    const res = try r.expect_valid_ib(r.ib_at(r.indx_root), .min_val, null);

    var head_path_buf: BPathBuf = undefined;
    var head_path = std.ArrayList(BPathEntry).initBuffer(&head_path_buf);
    const head_ofs_in_db = r.find_data_block(.coerce(0), &head_path);

    try std.testing.expectEqual(Db.Len.coerce(0), head_ofs_in_db);
    const head_entry: BPathEntry = head_path.items[head_path.items.len - 1];
    try std.testing.expectEqual(Ib.Len.coerce(0), head_entry.key_idx);
    const head_db_num = head_entry.parent_ib.child_at(.coerce(0)).as(Db.Num);

    var len: RopeBytes = .coerce(0);
    var cur_db_num: Db.Num = head_db_num;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i >= bounds.data_blocks_max)
            @panic("reached max iterations. probably a bug.");
        const db = r.db_at(cur_db_num);
        len = len.add(.coerce(db.meta.bytes));
        cur_db_num = db.meta.next.unwrap() orelse break;
    }
    try std.testing.expectEqual(res.len, len);
    try std.testing.expectEqual(res.last_db, cur_db_num);
}

const ValidBlockResult = struct { len: RopeBytes, last_db: ?Db.Num };

fn expect_valid_ib(
    r: *Rope,
    ib: *Ib,
    depth: IbHeight,
    prev_db: ?Db.Num,
) !ValidBlockResult {
    // root
    // if (depth.eql(.min_val) and r.indx_height.eql(.coerce(1))) {
    if (depth.eql(.min_val)) {
        try std.testing.expectEqual(r.ib_at(r.indx_root), ib);
        try std.testing.expect(ib.key_at(.coerce(0)).unwrap() != null);
        try std.testing.expect(ib.key_at(.coerce(1)).unwrap() != null);
        try std.testing.expect(ib.count_keys().to_int() >= 2);
    } else {
        try std.testing.expect(r.ib_at(r.indx_root) != ib);
        // rerooting creataes an empty block on the right that should be filled
        // by instert_in_blocks (or split) to have at least 2 children.
        if (ib.count_keys().to_int() < 2) {
            tlog.err(@src(), "", .{ .ib = ib });
            return error.TestExpectedIBMinTwoChildren;
        }
        // try std.testing.expect(
        //     ib.count_keys().to_int() >= bounds.indx_block_keys_min,
        // );
    }

    const is_leaf = depth.add(.coerce(1)).eql(r.indx_height);

    var len: RopeBytes = .coerce(0);
    var last_db = prev_db;
    for (ib.keys, ib.children) |keyp, child| {
        const key: TreeSize = keyp.unwrap() orelse break;

        const res: ValidBlockResult = if (is_leaf) x: {
            if (last_db) |l| if (l.eql(child.as(Db.Num))) {
                tlog.err(
                    @src(),
                    "repeated db in traversal: last_db == child",
                    .{
                        .last_db = l,
                        .child = child.as(Db.Num),
                        .ib = ib,
                    },
                );
                return error.TestExpectedNonRepeatingDbNum;
            };

            break :x .{
                .last_db = child.as(Db.Num),
                .len = .coerce(try r.expect_valid_db(
                    r.db_at(child.as(Db.Num)),
                    DbDepth.cast(depth.to_int() + 1),
                    last_db,
                )),
            };
        } else try r.expect_valid_ib(
            r.ib_at(child.as(Ib.Num)),
            depth.add(.coerce(1)),
            last_db,
        );
        try std.testing.expectEqual(RopeBytes.coerce(key), res.len);
        last_db = res.last_db;
        len = len.add(res.len);
    }
    try std.testing.expectEqual(len, ib.sum_subtree_bytes());
    try std.testing.expect(last_db != null);
    return .{
        .len = len,
        .last_db = last_db.?,
    };
}

const DbDepth = RangedInt(
    IbHeight.tag,
    1,
    IbHeight.max_val.to_int() + 1,
);
fn expect_valid_db(
    r: *Rope,
    db: *Db,
    depth: DbDepth,
    prev_db: ?Db.Num,
) !Db.Len {
    if (depth.to_int() > 1) try std.testing.expect(
        db.meta.bytes.to_int() >= bounds.data_block_bytes_min,
    );
    try std.testing.expectEqual(prev_db, db.meta.prev.unwrap());
    if (prev_db) |p| try std.testing.expectEqual(
        r.db_at(r.db_at(p).meta.next.unwrap().?),
        db,
    );
    return db.meta.bytes;
}

const count_blocks = struct {
    const Counts = std.BoundedArray(u32, bounds.indx_blocks_height_max);
    /// Count number of blocks on each height level of the tree.
    fn count_blocks(r: *Rope, out: *std.ArrayList(u32)) void {
        out.clearRetainingCapacity();
        out.appendNTimesAssumeCapacity(0, r.indx_height.to_int() + 1);

        // root ib should give min height of 1
        assert(r.indx_height.to_int() > 0);
        visit_ib(
            r,
            r.ib_at(r.indx_root),
            r.indx_height.sub(.coerce(1)),
            out,
        );
    }

    fn visit_ib(r: *Rope, ib: *Ib, height: IbHeight, out: *std.ArrayList(u32)) void {
        out.items[height.add(.coerce(1)).to_int()] += 1;

        for (ib.keys, ib.children) |keyp, child| {
            const key: TreeSize = keyp.unwrap() orelse break;
            _ = key;

            if (height.eql(.min_val)) {
                // count the leaf data block
                out.items[0] += 1;
            } else {
                visit_ib(
                    r,
                    r.ib_at(child.as(Ib.Num)),
                    height.sub(.coerce(1)),
                    out,
                );
            }
        }
    }
}.count_blocks;

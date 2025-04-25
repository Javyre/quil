//! Rope (linked list of string runs) indexed with a B*+tree where the keys are
//! derived from subtree lengths.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.rope);

const Rope = @This();
const ranged_int = @import("./ranged_int.zig");
const RangedInt = ranged_int.RangedInt;
const Db = @import("./Db.zig");
const Ib = @import("./Ib.zig");

gpa: std.mem.Allocator,
indx_root: Ib.Num,
indx_height: ranged_int.RangedInt(.ib_num, 0, bounds.indx_blocks_height_max),
indx_blocks: std.SegmentedList(Ib, 16),
data_blocks: std.SegmentedList(Db, 128),

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
    r.indx_root = .cast(r.indx_blocks.len);
    const root_ib = r.indx_blocks.addOne(r.gpa) catch unreachable;
    root_ib.* = .empty;

    var dbs: [2]struct { ptr: *Db, num: Db.Num } = undefined;
    for (0..2) |i| {
        const num: Db.Num = .cast(r.data_blocks.len);
        const ptr = r.data_blocks.addOne(r.gpa) catch unreachable;
        ptr.* = .{
            .meta = .{
                .bytes = .coerce(0),
                .newlines = undefined,
                .next = .null,
                .prev = .null,
            },
            .bytes = undefined,
        };
        dbs[i] = .{ .ptr = ptr, .num = num };
        root_ib.keys[i] = .some(.coerce(0));
        root_ib.children[i] = .wrap_db_num(num);
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
    return r.data_blocks.at(num.to_int());
}

fn ib_at(r: *Rope, num: Ib.Num) *Ib {
    return r.indx_blocks.at(num.to_int());
}

const BlockPathEntry = struct {
    // index to the key in the parent block
    key_idx: Ib.Len,
    parent_ib: *Ib,
};

fn find_data_block(
    r: *Rope,
    ofs: RopeBytes,
    path_store: []BlockPathEntry,
) struct {
    path: []BlockPathEntry,
    ofs_in_db: Db.Len,
} {
    const root_ib = r.ib_at(r.indx_root);
    assert(path_store.len >= bounds.indx_blocks_height_max);
    assert(ofs.to_int() <= root_ib.sum_subtree_bytes().to_int());

    var path = std.ArrayListUnmanaged(BlockPathEntry).initBuffer(path_store);

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

    return .{
        .path = path.items,
        .ofs_in_db = .cast(rest_ofs),
    };
}

fn update_parent_keys(
    path: []BlockPathEntry,
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

    var path_store: [bounds.indx_blocks_height_max]BlockPathEntry = undefined;
    const db_query = r.find_data_block(ofs, &path_store);
    assert_slice_of(&path_store, db_query.path);
    assert(r.indx_height.eql(.cast(db_query.path.len)));

    const targ_db_entry = db_query.path[db_query.path.len - 1];
    // const parent_ib = db_query.path[db_query.path.len - 1].parent_ib;
    // const targ_key_idx: Ib.Idx =
    //     .cast(db_query.path[db_query.path.len - 1].key_idx);

    {
        const targ_db: *const Db = r.db_at(targ_db_entry.parent_ib
            .child_at(.cast(targ_db_entry.key_idx))
            .as(Db.Num));
        assert(db_query.ofs_in_db.to_int() <= targ_db.meta.bytes.to_int());
    }

    var direct_space: RopeBytes = .coerce(0);
    const DbInfo = struct { block: *Db, len: Db.Len, key_idx: Ib.Idx };
    var dbs: struct {
        left: ?DbInfo,
        targ: DbInfo,
        right: ?DbInfo,
    } = .{
        .left = null,
        .targ = undefined,
        .right = null,
    };

    inline for (.{ .targ, .right, .left }) |side| {
        @field(dbs, @tagName(side)), const new_space: Db.Len = targ_db: {
            const key_idx: Ib.Idx = switch (side) {
                .targ => .cast(targ_db_entry.key_idx),
                .right => dbs.targ.key_idx.try_add(.coerce(1)) catch
                    break :targ_db .{ null, .coerce(0) },
                .left => dbs.targ.key_idx.try_sub(.coerce(1)) catch
                    break :targ_db .{ null, .coerce(0) },
                else => unreachable,
            };

            if (side == .right and
                targ_db_entry.parent_ib.key_at(key_idx).unwrap() == null)
            {
                break :targ_db .{ null, .coerce(0) };
            }

            const block = r.db_at(targ_db_entry.parent_ib
                .child_at(key_idx).as(Db.Num));
            const len: Db.Len = .cast(targ_db_entry.parent_ib
                .key_at(key_idx).unwrap().?);
            break :targ_db .{
                .{
                    .len = len,
                    .block = block,
                    .key_idx = key_idx,
                },
                Db.Len.max_val.sub(len),
            };
        };
        log.debug(
            "{any} has space = {d}",
            .{ side, new_space.to_int() },
        );
        direct_space = direct_space.add(.coerce(new_space));

        if (direct_space.to_int() >= alloc_len.to_int()) {
            log.debug("fits in direct_space = {d}", .{direct_space.to_int()});

            var alloc_iter: RopeBytes = alloc_len;
            const res = insert_in_blocks(Db, RopeBytes, &alloc_iter, .{
                .targ = .{
                    .block = dbs.targ.block,
                    .len = dbs.targ.len,
                },
                .right = if (dbs.right) |right| .{
                    .block = right.block,
                    .len = right.len,
                } else null,
                .left = if (dbs.left) |left| .{
                    .block = left.block,
                    .len = left.len,
                } else null,
                .ofs = db_query.ofs_in_db,
            });

            dbs.targ.block.meta.bytes = res.targ_len_new;
            if (dbs.right) |right|
                right.block.meta.bytes = res.right_len_new.?;
            if (dbs.left) |left|
                left.block.meta.bytes = res.left_len_new.?;

            targ_db_entry.parent_ib.key_at(dbs.targ.key_idx).* =
                .some(.coerce(res.targ_len_new));
            if (dbs.right) |right|
                targ_db_entry.parent_ib.key_at(right.key_idx).* =
                    .some(.coerce(res.right_len_new.?));
            if (dbs.left) |left|
                targ_db_entry.parent_ib.key_at(left.key_idx).* =
                    .some(.coerce(res.left_len_new.?));

            update_parent_keys(
                db_query.path[0 .. db_query.path.len - 1],
                .cast(targ_db_entry.parent_ib.sum_subtree_bytes()),
            );

            return .{
                .cursor = .{ .data_block = res.block, .ofs = res.ofs },
                .alloc_len = alloc_len,
            };
        }
    }

    // NOTE: Now we know that we need to split target and r/l to create new
    //       data blocks for alloc_len.

    const split: struct { left: DbInfo, right: DbInfo } = if (dbs.left) |left|
        .{
            .left = left,
            .right = dbs.targ,
        }
    else if (dbs.right) |right|
        .{
            .left = dbs.targ,
            .right = right,
        }
    else
        // a data block should always have at least one sibling in the same
        // parent
        unreachable;
    log.debug("splitting {any}", .{split});

    const total_len: RopeBytes = alloc_len
        .add(.coerce(split.left.len))
        .add(.coerce(split.right.len));
    const total_dbs: Db.Num =
        .cast(total_len.to_int() / bounds.data_block_bytes_min);
    const spill_len: Db.Len =
        .cast(total_len.to_int() % bounds.data_block_bytes_min);
    assert(total_dbs.to_int() >= 3);
    const new_dbs: Db.Num = total_dbs.sub(.coerce(2));

    // the split will call update_parent_keys so we might as well set up the
    // new right/left db lens now and piggyback on the update_parent_keys

    const prefix_len: RopeBytes = if (split.left.block == dbs.targ.block)
        .coerce(db_query.ofs_in_db)
    else if (split.right.block == dbs.targ.block)
        RopeBytes.coerce(split.left.len)
            .add(.coerce(db_query.ofs_in_db))
    else
        unreachable;
    const postfix_len: RopeBytes = RopeBytes.coerce(split.right.len)
        .add(.coerce(split.left.len))
        .sub(prefix_len);

    assert(spill_len.to_int() <= (config.data_block_bytes_max * 2) / 3);
    const spill_len_l: Db.Len = .min(
        .cast(config.data_block_bytes_max - bounds.data_block_bytes_min),
        spill_len,
    );
    const spill_len_r: Db.Len = spill_len.sub(spill_len_l);

    const split_left_len_new: Db.Len =
        spill_len_l.add(.coerce(bounds.data_block_bytes_min));
    const split_right_len_new: Db.Len =
        spill_len_r.add(.coerce(bounds.data_block_bytes_min));

    assert(RopeBytes.eql(
        RopeBytes.coerce(split_left_len_new)
            .add(.coerce(split_right_len_new))
            .add(.cast(bounds.data_block_bytes_min * new_dbs.to_int())),
        total_len,
    ));

    split.left.block.meta.bytes = split_left_len_new;
    split.right.block.meta.bytes = split_right_len_new;
    targ_db_entry.parent_ib.key_at(split.left.key_idx).* =
        .some(.coerce(split_left_len_new));
    targ_db_entry.parent_ib.key_at(split.right.key_idx).* =
        .some(.coerce(split_right_len_new));

    // do the split
    db_query.path[db_query.path.len - 1].key_idx = .cast(split.right.key_idx);
    const actual_new_dbs =
        try r.insert_dbs(db_query.path, &path_store, new_dbs);
    assert(actual_new_dbs.to_int() <= new_dbs.to_int());

    assert(!Db.Num.eql(
        split.left.block.meta.next.unwrap().?,
        split.right.block.meta.prev.unwrap().?,
    ));

    // fixup the prefix/postfix data
    var rest = .{
        .left = split.left.block.slice(null, split.left.len),
        .right = split.right.block.slice(null, split.right.len),
    };
    const alloc_pos_cursor = alloc_pos_cursor: {
        var prefix_rest = prefix_len;
        var cursor: Cursor = .{
            .data_block = split.left.block,
            .ofs = .coerce(0),
        };
        {
            const write_len: Db.Len =
                .cast(RopeBytes.min(.coerce(rest.left.len), prefix_rest));
            // skip this part as it's already written
            cursor.seek_by(r, .coerce(write_len));
            rest.left = rest.left.slice(write_len, null);
            prefix_rest = prefix_rest.sub(.coerce(write_len));
        }
        {
            const write_len: Db.Len =
                .cast(RopeBytes.min(.coerce(rest.right.len), prefix_rest));
            cursor.writer(r)
                .writeAll(rest.right.slice(null, write_len).bytes()) catch
                unreachable;
            rest.right = rest.right.slice(write_len, null);
            prefix_rest = prefix_rest.sub(.coerce(write_len));
        }
        assert(prefix_rest.eql(.min_val));
        break :alloc_pos_cursor cursor;
    };
    assert(postfix_len.eql(
        RopeBytes.coerce(rest.left.len).add(.coerce(rest.right.len)),
    ));
    {
        // reserve right new len. we'll manually copy into it at the end.
        var postfix_rest = postfix_len.sub(.coerce(split_right_len_new));
        var cursor: Cursor = .{
            .data_block = split.right.block,
            .ofs = split_right_len_new,
        };
        cursor.seek_by(r, RopeBytesSigned.coerce(0).sub(.coerce(postfix_len)));
        {
            const write_len: Db.Len =
                .cast(RopeBytes.min(.coerce(rest.left.len), postfix_rest));
            cursor.writer(r)
                .writeAll(rest.left.slice(null, write_len).bytes()) catch
                unreachable;
            rest.left = rest.left.slice(write_len, null);
            postfix_rest = postfix_rest.sub(.coerce(write_len));
        }
        {
            const write_len: Db.Len =
                .cast(RopeBytes.min(.coerce(rest.right.len), postfix_rest));
            cursor.writer(r)
                .writeAll(rest.right.slice(null, write_len).bytes()) catch
                unreachable;
            rest.right = rest.right.slice(write_len, null);
            postfix_rest = postfix_rest.sub(.coerce(write_len));
        }
        assert(postfix_rest.eql(.min_val));
        assert(rest.left.len.add(rest.right.len).eql(split_right_len_new));
        {
            // write right from back into itself to make space for rest.left
            Db.copy(
                split.right.block.slice(
                    split_right_len_new.sub(rest.right.len),
                    split_right_len_new,
                ),
                rest.right,
            );
            rest.right = rest.right.slice(rest.right.len, null);
            // write rest.left
            Db.copy(
                split.right.block.slice(null, rest.left.len),
                rest.left,
            );
            rest.left = rest.left.slice(rest.left.len, null);
        }
    }
    assert(rest.right.len.eql(.min_val));
    assert(rest.left.len.eql(.min_val));

    const actual_alloc_len: RopeBytes = RopeBytes
        .cast((@as(usize, actual_new_dbs.to_int()) + @as(usize, 2)) *
            @as(usize, bounds.data_block_bytes_min))
        .sub(prefix_len)
        .sub(postfix_len);
    assert(actual_alloc_len.to_int() <= alloc_len.to_int());

    return .{
        .cursor = alloc_pos_cursor,
        .alloc_len = actual_alloc_len,
    };
}

fn insert_dbs(
    r: *Rope,
    path_: []BlockPathEntry,
    path_store: []BlockPathEntry,
    new_dbs: Db.Num,
) !Db.Num {
    assert_slice_of(path_store, path_);
    var path = path_;

    const IbInfo = struct { block: *Ib, len: Ib.Len, key_idx: Ib.Idx };
    var ibs: struct {
        left: ?IbInfo,
        targ: struct { block: *Ib, len: Ib.Len, key_idx: ?Ib.Idx },
        right: ?IbInfo,
    } = .{
        .left = null,
        .targ = undefined,
        .right = null,
    };

    // null if targ is root ib
    var targ_ib_entry = if (path.len > 1) path[path.len - 2] else null;
    var direct_space: Db.Num = .coerce(0);

    inline for (.{ .targ, .reroot, .right, .left }) |side| sides: {
        log.debug("side = {any}", .{side});
        if (side == .reroot) {
            if (path.len > 1) break :sides;

            log.debug("root is full; rerooting", .{});

            assert(ibs.targ.block == r.ib_at(r.indx_root));
            const targ_ib_num: Ib.Num = r.indx_root;
            assert(ibs.targ.len.to_int() >= 2);

            const new_root_num: Ib.Num = .cast(r.indx_blocks.len);
            const new_root: *Ib = try r.indx_blocks.addOne(r.gpa);
            new_root.* = .empty;

            // new root needs at least 2 children
            const new_sibling_num: Ib.Num = .cast(r.indx_blocks.len);
            const new_sibling: *Ib = try r.indx_blocks.addOne(r.gpa);
            new_sibling.* = .empty;

            r.indx_root = new_root_num;

            ibs.targ.key_idx = .coerce(0);
            new_root.key_at(.coerce(0)).* =
                .some(.cast(ibs.targ.block.sum_subtree_bytes()));
            new_root.child_at(.coerce(0)).* = .wrap_ib_num(targ_ib_num);

            new_root.key_at(.coerce(1)).* = .some(.coerce(0));
            new_root.child_at(.coerce(1)).* = .wrap_ib_num(new_sibling_num);

            assert(path.len == 1);
            path.len += 1;
            r.indx_height = r.indx_height.add(.coerce(1));
            assert_slice_of(path_store, path);

            path[1] = path[0];
            path[0] = .{
                .key_idx = .coerce(0),
                .parent_ib = new_root,
            };
            targ_ib_entry = path[0];

            break :sides;
        }

        @field(ibs, @tagName(side)), const new_space: Ib.Len = targ_ib: {
            const IbIdx = if (side == .targ) ?Ib.Idx else Ib.Idx;
            const key_idx: IbIdx = switch (side) {
                .targ => if (targ_ib_entry) |e| .cast(e.key_idx) else null,
                .right => ibs.targ.key_idx.?.try_add(.coerce(1)) catch
                    break :targ_ib .{ null, .coerce(0) },
                .left => ibs.targ.key_idx.?.try_sub(.coerce(1)) catch
                    break :targ_ib .{ null, .coerce(0) },
                else => unreachable,
            };

            if (side == .right and
                targ_ib_entry.?.parent_ib.key_at(key_idx).unwrap() == null)
            {
                break :targ_ib .{ null, .coerce(0) };
            }

            const block = if (side == .targ)
                path[path.len - 1].parent_ib
            else
                r.ib_at(targ_ib_entry.?.parent_ib
                    .child_at(key_idx).as(Ib.Num));
            const len = block.count_keys();
            break :targ_ib .{
                .{
                    .len = len,
                    .block = block,
                    .key_idx = key_idx,
                },
                Ib.Len.max_val.sub(len),
            };
        };
        log.debug(
            "{any} has space = {d}",
            .{ side, new_space.to_int() },
        );
        direct_space = direct_space.add(.coerce(new_space.to_int()));

        if (direct_space.to_int() >= new_dbs.to_int()) {
            log.debug("fits in direct_space = {d}", .{direct_space.to_int()});

            const next_db: Db.Num = ibs.targ.block
                .child_at(.cast(path[path.len - 1].key_idx))
                .as(Db.Num);
            var dbs_iter: GenIbDbChildren = .init(r, .{
                .len = new_dbs.retag(.db_num, .ib_keys),
                .next = .some(next_db),
                .prev = r.db_at(next_db).meta.prev,
            });
            const IbTotalLen = RangedInt(
                Ib.Len.tag,
                Db.Num.min_val.to_int(),
                Db.Num.max_val.to_int(),
            );
            _ = insert_in_blocks(Ib, IbTotalLen, &dbs_iter, .{
                .targ = .{
                    .block = ibs.targ.block,
                    .len = ibs.targ.len,
                },
                .right = if (ibs.right) |right| .{
                    .block = right.block,
                    .len = right.len,
                } else null,
                .left = if (ibs.left) |left| .{
                    .block = left.block,
                    .len = left.len,
                } else null,
                .ofs = path[path.len - 1].key_idx,
            });
            assert(dbs_iter.next() == null);
            assert(dbs_iter.next_back() == null);

            if (targ_ib_entry) |e|
                e.parent_ib.key_at(.cast(ibs.targ.key_idx.?)).* =
                    .some(.cast(ibs.targ.block.sum_subtree_bytes()));
            if (ibs.right) |right|
                targ_ib_entry.?.parent_ib.key_at(right.key_idx).* =
                    .some(.cast(right.block.sum_subtree_bytes()));
            if (ibs.left) |left|
                targ_ib_entry.?.parent_ib.key_at(left.key_idx).* =
                    .some(.cast(left.block.sum_subtree_bytes()));

            if (targ_ib_entry) |e| {
                update_parent_keys(
                    path[0 .. path.len - 1],
                    .cast(e.parent_ib.sum_subtree_bytes()),
                );
            } else {
                assert(path.len == 1);
            }

            return new_dbs;
        }
    }

    // NOTE: Now we know that we need to split target and r/l to create new
    //       data blocks for alloc_len.

    const ibs_targ: IbInfo = .{
        .block = ibs.targ.block,
        .len = ibs.targ.len,
        .key_idx = ibs.targ.key_idx.?, // targ is not root at this point
    };
    const split: struct { left: IbInfo, right: IbInfo } = if (ibs.left) |left|
        .{
            .left = left,
            .right = ibs_targ,
        }
    else if (ibs.right) |right|
        .{
            .left = ibs_targ,
            .right = right,
        }
    else
        // an indx block sohuld always have at least one sibling in the
        // same parent
        unreachable;
    log.debug("splitting {any}", .{split});

    // const total_len: Db.Num = new_dbs
    //     .add(.cast(split.left.len.retag(.ib_keys, .db_num))
    //     .add(.cast(split.right.len.retag(.ib_keys, .db_num))));
    // const total_ibs: Ib.Num =
    //     .cast(total_len.to_int() / bounds.indx_block_keys_min);
    // const spill_len: Ib.Len =
    //     .cast(total_len.to_int() % bounds.indx_block_keys_min);
    // assert(total_ibs.to_int() >= 3);
    // const new_ibs: Ib.Num = total_ibs.sub(.coerce(2));
    //
    // const prefix_len: Db.Num = if (split.left.block == ibs.targ.block)
    //     .coerce(path[path.len - 1].key_idx.retag(.ib_keys, .db_num))
    // else if (split.right.block == ibs.targ.block)
    //     Db.Num.coerce(split.left.len.retag(.ib_keys, .db_num))
    //         .add(.coerce(path[path.len - 1].key_idx.retag(.ib_keys, .db_num)))
    // else
    //     unreachable;
    // const postfix_len: Db.Num =
    //     Db.Num.coerce(split.right.len.retag(.ib_keys, .db_num)
    //         .add(.coerce(split.left.len.retag(.ib_keys, .db_num))))
    //         .sub(prefix_len);

    // assert(spill_len.to_int() <= (config.

    @panic("todo: split");
}

const GenIbDbChildren = struct {
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
    }) GenIbDbChildren {
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

    pub fn next(this: *GenIbDbChildren) ?struct {
        key: TreeSize,
        child: Ib.RawChild,
    } {
        if (this.len.eql(.min_val)) return null;
        defer this.len = this.len.sub(.coerce(1));

        const len: Db.Len = .cast(bounds.data_block_bytes_min);
        const num: Db.Num = .cast(this.r.data_blocks.len);
        const db: *Db = this.r.data_blocks.addOne(this.r.gpa) catch unreachable;
        db.* = .{
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
            this.r.db_at(p).meta.next = .some(num);
        if (this.len.eql(.coerce(1))) {
            if (this.next_.unwrap()) |n|
                this.r.db_at(n).meta.prev = .some(num);
        }
        this.prev_ = .some(num);

        return .{
            .key = .coerce(len),
            .child = .wrap_db_num(num),
        };
    }

    pub fn next_back(this: *GenIbDbChildren) ?struct {
        key: TreeSize,
        child: Ib.RawChild,
    } {
        if (this.len.eql(.min_val)) return null;
        defer this.len = this.len.sub(.coerce(1));

        const len: Db.Len = .cast(bounds.data_block_bytes_min);
        const num: Db.Num = .cast(this.r.data_blocks.len);
        const db: *Db = this.r.data_blocks.addOne(this.r.gpa) catch unreachable;
        db.* = .{
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
            this.r.db_at(n).meta.prev = .some(num);
        if (this.len.eql(.coerce(1))) {
            if (this.prev_.unwrap()) |p|
                this.r.db_at(p).meta.next = .some(num);
        }
        this.next_ = .some(num);

        return .{
            .key = .coerce(len),
            .child = .wrap_db_num(num),
        };
    }
};

// TODO: alloc_len -> u8/Db/Ib slice write
//       (optionally null -> alloc undefined space)
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
) struct {
    block: *T,
    ofs: T.Len,
    left_len_new: ?T.Len,
    targ_len_new: T.Len,
    right_len_new: ?T.Len,
} {
    log.debug("alloc_in_blocks(args = {any})", .{args});

    const generic_len = struct {
        inline fn generic_len(_items: anytype) TTotalLen {
            const deref = if (@typeInfo(@TypeOf(_items)) == .pointer)
                _items.*
            else
                _items;

            if (comptime ranged_int.is_ranged_int(@TypeOf(deref)))
                return .coerce(deref);

            if (@hasField(@TypeOf(deref), "len")) return .coerce(deref.len);
            if (@hasDecl(@TypeOf(deref), "len")) return .coerce(deref.len());
            @compileError(
                "_items must have a len field/fn or be TTotalLen castable",
            );
        }
    }.generic_len;

    const orig_alloc_len = generic_len(items);

    comptime {
        T.assert_WriteIter(@TypeOf(items));
    }

    var rest = .{
        .prefix = args.targ.block.slice(null, args.ofs),
        .alloc = items,
        .postfix = args.targ.block.slice(args.ofs, args.targ.len),
    };

    const left_len_new: ?T.Len = if (args.left) |left| left_len_new: {
        var left_rest = left.block.slice(left.len, .max_val);

        parts_loop: inline for (.{
            &rest.prefix,
            rest.alloc,
            &rest.postfix,
        }) |part_rest| {
            if (left_rest.len.eql(.min_val)) break :parts_loop;
            const write_len: T.Len = .cast(@min(
                left_rest.len.to_int(),
                if (@TypeOf(part_rest) == *T.Slice)
                    part_rest.len.to_int()
                else
                    generic_len(part_rest).to_int(),
            ));
            if (@TypeOf(part_rest) == *T.Slice) {
                T.copy(
                    left_rest.slice(null, write_len),
                    part_rest.slice(null, write_len),
                );
                part_rest.* = part_rest.slice(write_len, null);
            } else {
                T.write(
                    left_rest.slice(null, write_len),
                    part_rest,
                );
            }
            left_rest = left_rest.slice(write_len, null);
        }

        assert(left_rest.len.eql(.min_val));
        break :left_len_new .max_val;
    } else null;

    const overflow_len: T.Len = x: {
        const total_rest: TTotalLen = generic_len(rest.alloc)
            .add(.coerce(rest.prefix.len))
            .add(.coerce(rest.postfix.len));
        break :x .cast(total_rest.sub_saturating(.coerce(T.Len.max_val)));
    };

    const right_len_new: ?T.Len =
        if (overflow_len.to_int() > 0) right_len_new: {
            const right = args.right.?;
            // alloc overflow in front of right
            T.copy(
                right.block.slice(overflow_len, T.Len.max_val)
                    .slice(null, right.len),
                right.block.slice(null, right.len),
            );
            var right_rest = right.block.slice(null, overflow_len);

            // in reverse order now
            parts_loop: inline for (.{
                &rest.postfix,
                rest.alloc,
                &rest.prefix,
            }) |part_rest| {
                if (right_rest.len.eql(.min_val)) break :parts_loop;
                const write_len: T.Len = .cast(@min(
                    right_rest.len.to_int(),
                    if (@TypeOf(part_rest) == *T.Slice)
                        part_rest.len.to_int()
                    else
                        generic_len(part_rest).to_int(),
                ));
                if (@TypeOf(part_rest) == *T.Slice) {
                    T.copy(
                        right_rest.slice(right_rest.len.sub(write_len), null),
                        part_rest.slice(part_rest.len.sub(write_len), null),
                    );
                    part_rest.* =
                        part_rest.slice(null, part_rest.len.sub(write_len));
                } else {
                    T.write_from_back(
                        right_rest.slice(right_rest.len.sub(write_len), null),
                        part_rest,
                    );
                }
                right_rest =
                    right_rest.slice(null, right_rest.len.sub(write_len));
            }

            assert(right_rest.len.eql(.min_val));
            break :right_len_new .add(right.len, overflow_len);
        } else null;

    const targ = args.targ;

    // assert total rest is <= max block len
    const targ_len_new: T.Len = .cast(generic_len(rest.alloc)
        .add(.coerce(rest.prefix.len))
        .add(.coerce(rest.postfix.len)));

    var targ_rest = targ.block.slice(null, targ_len_new);
    // prefix can only slide to the left. so start with that.
    T.copy(
        targ_rest.slice(null, rest.prefix.len),
        rest.prefix,
    );
    targ_rest = targ_rest.slice(rest.prefix.len, null);
    // write alloc
    {
        const rest_alloc_len: T.Len = .cast(generic_len(rest.alloc));
        T.write(
            targ_rest.slice(null, rest_alloc_len),
            rest.alloc,
        );
        targ_rest = targ_rest.slice(rest_alloc_len, null);
    }
    // write postfix
    T.copy(
        targ_rest.slice(null, rest.postfix.len),
        rest.postfix,
    );
    targ_rest = targ_rest.slice(rest.postfix.len, null);
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

test alloc_at {
    std.testing.log_level = .debug;

    var r = Rope.init(std.testing.allocator);
    defer r.deinit();

    for ([_]usize{ 0, 10, 100, 100, 200, 300, 1000, 10000 }) |len| {
        log.debug("rope.indx_root = {any}", .{r.indx_root});
        log.debug("indx_blocks = {any}", .{r.indx_blocks});
        log.debug("rope.indx_root = {any}", .{r.ib_at(r.indx_root)});
        log.debug("inserting len = {d}", .{len});
        _ = try r.alloc_at(.coerce(0), .cast(len));
    }
}

// For reading/writing but no tree mutations. i.e. no (de)alloc of bytes.
//
// NOTE: For rope internal code, this is usually much less efficient than
//       manually copying chunks of data_blocks around as we often have much
//       more info at the callsite about the copy and we can make assumptions.
pub const Cursor = struct {
    data_block: *Db,
    ofs: Db.Len,

    pub const ReadError = error{};
    pub const WriteError = error{NoSpaceLeft};

    const Ctx = struct {
        r: *Rope,
        cursor: *Cursor,
        pub fn read(ctx: Ctx, dst: []u8) ReadError!usize {
            return ctx.cursor.read(ctx.r, dst);
        }
        pub fn write(ctx: Ctx, src: []const u8) WriteError!usize {
            return ctx.cursor.write(ctx.r, src);
        }
    };
    pub const Writer = std.io.Writer(Ctx, WriteError, Ctx.write);
    pub const Reader = std.io.Reader(Ctx, ReadError, Ctx.read);

    pub fn reader(c: *Cursor, r: *Rope) Reader {
        return .{ .context = .{ .r = r, .cursor = c } };
    }
    pub fn writer(c: *Cursor, r: *Rope) Writer {
        return .{ .context = .{ .r = r, .cursor = c } };
    }

    pub fn read(this: *Cursor, r: *Rope, dst_: []u8) ReadError!usize {
        assert(this.ofs.to_int() <= this.data_block.meta.bytes.to_int());
        _ = RopeBytes.cast(dst_.len);

        var dst = dst_;
        var i: usize = 0;
        while (dst.len > 0) : (i += 1) {
            if (i >= bounds.data_blocks_max)
                @panic("reached max iterations. probably a bug.");

            const cpy_len: Db.Len = .cast(RopeBytes.min(
                dst.len,
                .coerce(this.data_block.meta.bytes.sub(this.ofs)),
            ));
            @memcpy(
                dst[0..cpy_len.to_int()],
                this.data_block.bytes[this.ofs.to_int()..][0..cpy_len.to_int()],
            );
            dst = dst[cpy_len.to_int()..];
            this.ofs = this.ofs.add(cpy_len);

            assert(this.ofs.to_int() <= this.data_block.meta.bytes.to_int());
            if (this.ofs.eql(this.data_block.meta.bytes)) {
                this.data_block = r.db_at(
                    this.data_block.meta.next.unwrap() orelse break,
                );
                this.ofs = .coerce(0);
            }
        }
        const bytes_read: RopeBytes = .cast(dst_.len - dst.len);
        return bytes_read.to_int();
    }

    pub fn write(this: *Cursor, r: *Rope, src_: []const u8) WriteError!usize {
        assert(this.ofs.to_int() <= this.data_block.meta.bytes.to_int());
        var src = src_;
        var i: usize = 0;
        while (src.len > 0) : (i += 1) {
            if (i >= bounds.data_blocks_max)
                @panic("reached max iterations. probably a bug.");

            const cpy_len: Db.Len = .cast(RopeBytes.min(
                .cast(src.len),
                .coerce(this.data_block.meta.bytes.sub(this.ofs)),
            ));
            {
                var write_bytes = src[0..cpy_len.to_int()];
                Db.write(
                    this.data_block
                        .slice(this.ofs, .max_val)
                        .slice(null, cpy_len),
                    &write_bytes,
                );
                // write consumed all bytes
                assert(write_bytes.len == 0);
            }
            src = src[cpy_len.to_int()..];
            this.ofs = this.ofs.add(cpy_len);

            assert(this.ofs.to_int() <= this.data_block.meta.bytes.to_int());
            if (this.ofs.eql(this.data_block.meta.bytes)) {
                this.data_block = r.db_at(
                    this.data_block.meta.next.unwrap() orelse break,
                );
                this.ofs = .coerce(0);
            }
        }
        const written: RopeBytes = .cast(src_.len - src.len);
        assert(written.to_int() > 0);
        if (written.to_int() != src_.len) return WriteError.NoSpaceLeft;
        return written.to_int();
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
                .coerce(this.data_block.meta.bytes.sub(this.ofs)),
            ));
            amt = amt.sub(.coerce(fwd_len));
            this.ofs = this.ofs.add(fwd_len);

            assert(this.ofs.to_int() <= this.data_block.meta.bytes.to_int());
            if (this.ofs.eql(this.data_block.meta.bytes)) {
                this.data_block = r.db_at(
                    this.data_block.meta.next.unwrap() orelse break,
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
                this.data_block = r.db_at(
                    this.data_block.meta.prev.unwrap() orelse break,
                );
                this.ofs = this.data_block.meta.bytes;
            }

            assert(this.ofs.to_int() <= this.data_block.meta.bytes.to_int());
            const rev_len: Db.Len =
                .cast(RopeBytes.min(amt, .coerce(this.ofs)));
            amt = amt.sub(.coerce(rev_len));
            this.ofs = this.ofs.sub(rev_len);
        }
        if (!amt.eql(.min_val))
            std.debug.panic("seek_back out of bounds", .{});
    }
};

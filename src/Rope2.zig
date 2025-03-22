//! Rope (linked list of string runs) indexed with a B*+tree where the keys are
//! derived from subtree lengths.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.rope);

const Rope = @This();
const RangedInt = @import("./ranged_int.zig").RangedInt;
const Db = @import("./Db.zig");
const Ib = @import("./Ib.zig");

gpa: std.mem.Allocator,
indx_root: *Ib,
indx_height: std.math.IntFittingRange(0, bounds.indx_blocks_height_max),
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
    data_block_bytes_min: u8,
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
        .indx_height = 1,
        .indx_blocks = .{},
        .data_blocks = .{},
    };

    // These addOne calls dont allocate as we have a stack allocated portion
    // that is large enough for init.
    r.indx_root = r.indx_blocks.addOne(r.gpa) catch unreachable;
    r.indx_root.* = .empty;

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
        r.indx_root.keys[i] = .some(.coerce(0));
        r.indx_root.children[i] = .wrap_db_num(num);
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
    assert(path_store.len >= bounds.indx_blocks_height_max);
    assert(ofs.to_int() <= r.indx_root.sum_subtree_bytes().to_int());

    var path = std.ArrayListUnmanaged(BlockPathEntry).initBuffer(path_store);

    var parent: *Ib = r.indx_root;
    var rest_ofs: RopeBytes = ofs;

    for (1..r.indx_height + 1) |height| {
        const res = parent.find_ofs(rest_ofs) orelse
            @panic("requested ofs out of bounds");

        path.appendAssumeCapacity(.{
            .key_idx = res.key_idx,
            .parent_ib = parent,
        });
        assert(path.items.len == height);

        rest_ofs = .cast(rest_ofs.to_int() - res.child_ofs.to_int());

        if (height < r.indx_height) {
            const new_parent =
                r.ib_at(parent.child_at(.cast(res.key_idx)).as(Ib.Num));
            assert(new_parent != parent);
            parent = new_parent;
        } else {
            // if stmt should only be false ONCE for the last iteration
            assert(height == r.indx_height);
        }
    }
    assert(path.items.len == r.indx_height);
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

const AllocAt = struct {
    const Result = struct {
        cursor: Cursor,
        alloc_len: RopeBytes,
    };
    const TargDb = struct {
        key_idx: Ib.Idx,
        db: *Db,
        len: Db.Len,
    };
};

fn alloc_at(r: *Rope, ofs: RopeBytes, alloc_len: RopeBytes) !AllocAt.Result {
    var path_store: [bounds.indx_blocks_height_max]BlockPathEntry = undefined;
    const db_query = r.find_data_block(ofs, &path_store);
    assert_slice_of(&path_store, db_query.path);
    assert(db_query.path.len == r.indx_height);

    const parent_ib = db_query.path[db_query.path.len - 1].parent_ib;
    const targ_key_idx: Ib.Idx =
        .cast(db_query.path[db_query.path.len - 1].key_idx);

    {
        const db: *const Db =
            r.db_at(parent_ib.child_at(targ_key_idx).as(Db.Num));
        assert(db_query.ofs_in_db.to_int() <= db.meta.bytes.to_int());
    }

    var direct_space: RopeBytes = .coerce(0);
    var dbs: struct {
        left: ?struct { block: *Db, len: Db.Len, key_idx: Ib.Idx },
        targ: struct { block: *Db, len: Db.Len, key_idx: Ib.Idx },
        right: ?struct { block: *Db, len: Db.Len, key_idx: Ib.Idx },
    } = .{
        .left = null,
        .targ = undefined,
        .right = null,
    };

    inline for (.{ .targ, .right, .left }) |side| {
        @field(dbs, @tagName(side)), const new_space: Db.Len = targ_db: {
            const key_idx: Ib.Idx = switch (side) {
                .targ => targ_key_idx,
                .right => targ_key_idx.try_add(.coerce(1)) catch
                    break :targ_db .{ null, .coerce(0) },
                .left => targ_key_idx.try_sub(.coerce(1)) catch
                    break :targ_db .{ null, .coerce(0) },
                else => unreachable,
            };

            if (side == .right) {
                if (parent_ib.key_at(key_idx).unwrap() == null)
                    break :targ_db .{ null, .coerce(0) };
            }

            const len: Db.Len = .cast(parent_ib.key_at(key_idx).unwrap().?);
            const block = r.db_at(parent_ib.child_at(key_idx).as(Db.Num));
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
            const res = alloc_in_blocks(Db, .{
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
                .alloc_len = alloc_len,
            });

            dbs.targ.block.meta.bytes = res.targ_len_new;
            if (dbs.right) |right|
                right.block.meta.bytes = res.right_len_new.?;
            if (dbs.left) |left|
                left.block.meta.bytes = res.left_len_new.?;

            parent_ib.key_at(dbs.targ.key_idx).* =
                .some(.coerce(res.targ_len_new));
            if (dbs.right) |right| parent_ib.key_at(right.key_idx).* =
                .some(.coerce(res.right_len_new.?));
            if (dbs.left) |left| parent_ib.key_at(left.key_idx).* =
                .some(.coerce(res.left_len_new.?));

            update_parent_keys(
                db_query.path[0 .. db_query.path.len - 1],
                .cast(parent_ib.sum_subtree_bytes()),
            );

            return .{
                .cursor = .{ .data_block = res.block, .ofs = res.ofs },
                .alloc_len = alloc_len,
            };
        }
    }
    @panic("todo: split");
}

fn alloc_in_blocks(comptime T: type, args: struct {
    left: ?struct { block: *T, len: T.Len } = null,
    targ: struct { block: *T, len: T.Len },
    right: ?struct { block: *T, len: T.Len } = null,
    ofs: T.Len,
    alloc_len: RopeBytes,
}) struct {
    block: *T,
    ofs: T.Len,
    left_len_new: ?T.Len,
    targ_len_new: T.Len,
    right_len_new: ?T.Len,
} {
    log.debug("alloc_in_blocks(args = {any})", .{args});

    var rest = .{
        .prefix = args.targ.block.slice(null, args.ofs),
        .alloc = .{ .len = args.alloc_len },
        .postfix = args.targ.block.slice(args.ofs, null),
    };

    const left_len_new: ?T.Len = if (args.left) |left| left_len_new: {
        var left_rest = left.block.slice(left.len, .max_val);

        parts_loop: inline for (.{
            &rest.prefix,
            &rest.alloc,
            &rest.postfix,
        }) |part_rest| {
            if (left_rest.len.eql(.min_val)) break :parts_loop;
            const write_len: T.Len = .cast(@min(
                left_rest.len.to_int(),
                part_rest.len.to_int(),
            ));
            if (@TypeOf(part_rest) == *T.Slice) {
                T.copy(
                    left_rest.slice(null, write_len),
                    part_rest.slice(null, write_len),
                );
                part_rest.* = part_rest.slice(write_len, null);
            } else {
                part_rest.len = part_rest.len.sub(.coerce(write_len));
            }
            left_rest = left_rest.slice(write_len, null);
        }

        assert(left_rest.len.eql(.min_val));
        break :left_len_new .max_val;
    } else null;

    const overflow_len: T.Len = x: {
        const total_rest: RopeBytes = rest.alloc.len
            .add(.coerce(rest.prefix.len))
            .add(.coerce(rest.postfix.len));
        break :x .cast(total_rest.sub_saturating(.coerce(T.Len.max_val)));
    };

    const right_len_new: ?T.Len =
        if (overflow_len.to_int() > 0) right_len_new: {
            const right = args.right.?;
            // alloc overflow in front of right
            T.copy(
                right.block.slice(overflow_len, null).slice(null, right.len),
                right.block.slice(null, right.len),
            );
            var right_rest = right.block.slice(null, overflow_len);

            // in reverse order now
            parts_loop: inline for (.{
                &rest.postfix,
                &rest.alloc,
                &rest.prefix,
            }) |part_rest| {
                if (right_rest.len.eql(.min_val)) break :parts_loop;
                const write_len: T.Len = .cast(@min(
                    right_rest.len.to_int(),
                    part_rest.len.to_int(),
                ));
                if (@TypeOf(part_rest) == *T.Slice) {
                    T.copy(
                        right_rest.slice(right_rest.len.sub(write_len), null),
                        part_rest.slice(part_rest.len.sub(write_len), null),
                    );
                    part_rest.* =
                        part_rest.slice(null, part_rest.len.sub(write_len));
                } else {
                    part_rest.len = part_rest.len.sub(.coerce(write_len));
                }
                right_rest =
                    right_rest.slice(null, right_rest.len.sub(write_len));
            }

            assert(right_rest.len.eql(.min_val));
            break :right_len_new .add(right.len, overflow_len);
        } else null;

    const targ = args.targ;

    // assert total rest is <= max block len
    const targ_len_new: T.Len = .cast(rest.alloc.len
        .add(.coerce(rest.prefix.len))
        .add(.coerce(rest.postfix.len)));

    var targ_rest = targ.block.slice(null, targ_len_new);
    // prefix can only slide to the left. so start with that.
    T.copy(
        targ_rest.slice(null, rest.prefix.len),
        rest.prefix,
    );
    targ_rest = targ_rest.slice(rest.prefix.len, null);
    // skip alloc len
    targ_rest = targ_rest.slice(.cast(rest.alloc.len), null);
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

    assert(RopeBytes.eql(
        RopeBytes.coerce(targ_len_new)
            .add(.coerce(left_len_new orelse T.Len.min_val))
            .add(.coerce(right_len_new orelse T.Len.min_val)),
        RopeBytes.coerce(args.targ.len)
            .add(.coerce(if (args.left) |left| left.len else T.Len.min_val))
            .add(.coerce(if (args.right) |right| right.len else T.Len.min_val))
            .add(args.alloc_len),
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
};

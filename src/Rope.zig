//! Rope (linked list of string runs) indexed with a B*+tree where the keys are
//! derived from subtree lengths.

// TODO: measure performance of this vs a simpler B+ tree
//       (m/2 keys max instead of 2m/3)

const std = @import("std");
const assert = std.debug.assert;

const Rope = @This();

alloc: std.mem.Allocator,
indx_root: *IndxBlock,
indx_blocks: std.SegmentedList(IndxBlock, indx_blocks_prealloc),
data_blocks: std.SegmentedList(DataBlock, data_blocks_prealloc),

const dcache_line_bytes = 64;

// Values for the below constants were explored with
// https://www.desmos.com/calculator/hu1ea1ahhr

const rope_bytes_max = 1 << 39; // 512 GiB
const rope_bytes_prealloc = 1 << 14; // 16 KiB
// Type use to index into rope bytes
// Root node uses this type for its size.
const ByteIdx = u39;
const ByteIdxDelta = i40;
// Type used to measure size of rope subtrees.
// Every node except for the root uses this type for its size.
const SubtreeByteSize = u32;

const data_block_bytes_max = 2 * dcache_line_bytes; // 1 << 7 = 128
const data_block_bytes_min = data_block_bytes_max * 2 / 3;

// ceil(rope_bytes_max / data_block_bytes_max)
const data_blocks_max = 1 << 32;
const DataBlockIdx = u32;
// ceil(rope_bytes_prealloc / data_block_bytes_max)
const data_blocks_prealloc = 1 << 7;

// floor(indx_block_keys_max * 2 / 3)
const indx_block_keys_min: KeyIdx = 10;
// floor(dcache_line_bytes / byte_size_of(SubtreeByteSize))
const indx_block_keys_max: KeysLen = 16;
const KeyIdx = u4;
const KeysLen = u5;

const indx_block_root_keys_min = 2;

// log(indx_block_keys_min, data_blocks_max / indx_block_keys_min)
const indx_blocks_height_max = 9;
// ceil_pow2(SUM^(indx_blocks_height_max)_n=0[indx_block_keys_min^n])
// = ceil_pow2((indx_block_keys_min^(indx_blocks_height_max + 1) - 1) /
//             (indx_block_keys_min - 1))
const indx_blocks_max = 1 << 30;
const IndxBlockIdx = u30;
const indx_blocks_prealloc = 16;

comptime {
    assert(data_blocks_max ==
        @divExact(rope_bytes_max, data_block_bytes_max));
    assert(data_blocks_prealloc ==
        @divExact(rope_bytes_prealloc, data_block_bytes_max));

    assert(indx_block_keys_min == @as(u6, indx_block_keys_max) * 2 / 3);
    assert(indx_block_keys_max ==
        dcache_line_bytes / byte_size_of(SubtreeByteSize));

    assert(indx_blocks_height_max ==
        // Round up
        1 + std.math.log_int(
        comptime_int,
        indx_block_keys_min,
        data_blocks_max / @as(comptime_int, indx_block_keys_min),
    ));
    assert(std.math.log2_int(usize, indx_blocks_max) ==
        std.math.log2_int(usize, ((std.math.powi(
        usize,
        indx_block_keys_min,
        indx_blocks_height_max + 1,
    ) catch unreachable) - 1) / (indx_block_keys_min - 1)));
}

fn byte_size_of(comptime T: type) comptime_int {
    return (@bitSizeOf(T) + 7) / 8;
}
fn bytes_from_int(i: anytype) [byte_size_of(@TypeOf(i))]u8 {
    const info = @typeInfo(@TypeOf(i)).int;
    return @bitCast(@as(std.meta.Int(
        info.signedness,
        byte_size_of(@TypeOf(i)) * 8,
    ), i));
}
fn int_from_bytes(comptime I: type, bytes: [byte_size_of(I)]u8) I {
    return @truncate(@as(
        std.meta.Int(.unsigned, byte_size_of(I) * 8),
        @bitCast(bytes),
    ));
}

const IndxBlock = extern struct {
    const Idx = IndxBlockIdx;
    const OptIdx = enum(Idx) {
        null = std.math.maxInt(Idx),
        _,
        pub fn to_idx(num: OptIdx) ?Idx {
            if (num == .null) return null;
            return @intFromEnum(num);
        }

        pub fn from_idx(idx: ?Idx) OptIdx {
            if (idx) |i| {
                const res: OptIdx = @enumFromInt(i);
                assert(res != .null);
                return res;
            }
            return .null;
        }
    };
    const RawKey = [byte_size_of(SubtreeByteSize)]u8;
    const RawChild = [
        @max(
            byte_size_of(IndxBlock.Idx),
            byte_size_of(DataBlock.Idx),
        )
    ]u8;

    const null_key: RawKey = @splat(0xFF);

    meta: extern struct {
        // TODO: remove this field and derive from path position
        is_leaf: bool,
        // /// Amount of bytes in this subtree.
        // bytes: ByteIdx = 0,
        // /// Amount of lines in this subtree.
        // lines: ByteIdx = 0,
    } align(dcache_line_bytes),

    keys: [indx_block_keys_max]RawKey align(dcache_line_bytes),
    children: [indx_block_keys_max]RawChild align(dcache_line_bytes),

    comptime {
        assert(@sizeOf([indx_block_keys_max]RawKey) == dcache_line_bytes);
        assert(@sizeOf([indx_block_keys_max]RawChild) == dcache_line_bytes);
    }

    pub const empty_leaf: IndxBlock = .{
        .meta = .{ .is_leaf = true },
        .keys = @splat(null_key),
        .children = undefined,
    };

    pub fn raw_key_is_null(key: RawKey) bool {
        return std.mem.eql(u8, &key, &null_key);
    }

    pub fn keys_len(block: *const IndxBlock) KeysLen {
        for (block.keys, 0..) |key, i| {
            if (raw_key_is_null(key)) return @intCast(i);
        }
        return indx_block_keys_max;
    }

    pub fn child_subtree_bytes(
        block: *const IndxBlock,
        key_idx: KeyIdx,
    ) SubtreeByteSize {
        assert(!IndxBlock.raw_key_is_null(block.keys[key_idx]));
        const bytes = int_from_bytes(SubtreeByteSize, block.keys[key_idx]);
        return bytes;
    }

    pub fn set_child_subtree_bytes(
        block: *IndxBlock,
        key_idx: KeyIdx,
        bytes: SubtreeByteSize,
    ) void {
        assert(!IndxBlock.raw_key_is_null(block.keys[key_idx]));
        block.keys[key_idx] = bytes_from_int(bytes);
    }

    pub fn child_data_block(
        block: *const IndxBlock,
        key_idx: KeyIdx,
    ) DataBlock.Idx {
        assert(block.meta.is_leaf);
        const raw_idx = block.children[key_idx];
        assert(!IndxBlock.raw_key_is_null(block.keys[key_idx]));
        return int_from_bytes(DataBlock.Idx, raw_idx);
    }

    pub fn set_child_data_block(
        block: *IndxBlock,
        key_idx: KeyIdx,
        data_block_idx: DataBlock.Idx,
    ) void {
        assert(block.meta.is_leaf);
        assert(key_idx < indx_block_keys_max);
        block.children[key_idx] = bytes_from_int(data_block_idx);
    }

    pub fn child_indx_block(
        block: *const IndxBlock,
        key_idx: KeyIdx,
    ) IndxBlock.Idx {
        assert(!block.meta.is_leaf);
        const raw_idx = block.children[key_idx];
        assert(!IndxBlock.raw_key_is_null(block.keys[key_idx]));
        return int_from_bytes(IndxBlock.Idx, raw_idx);
    }

    pub fn sum_subtree_sizes(block: *const IndxBlock) SubtreeByteSize {
        var sum: SubtreeByteSize = 0;
        for (block.keys) |key| {
            if (IndxBlock.raw_key_is_null(key)) break;
            sum += int_from_bytes(SubtreeByteSize, key);
        }
        return sum;
    }
};

const DataBlock = struct {
    const Idx = DataBlockIdx;
    const Meta = struct {
        /// Amount of bytes in this block.
        bytes: u8 = 0,
        /// Bitmap of newlines in this block.
        newlines: u128 = 0, // 128 = data_block_bytes_max
        next: ?Idx = null,
        prev: ?Idx = null,
    };

    comptime {
        assert(@sizeOf(Meta) <= dcache_line_bytes);
    }

    meta: Meta align(dcache_line_bytes),
    bytes: [data_block_bytes_max]u8,

    pub const Slice = struct {
        block: *DataBlock,
        ofs: u7,
        len: u8,
    };
    fn slice(db: *DataBlock, ofs: u7, len: u8) Slice {
        return .{
            .block = db,
            .ofs = ofs,
            .len = len,
        };
    }

    // NOTE: If we can eventually get rid of all the long slice sutff,
    //       that would be great.
    //
    //       This is usually much less efficient than manually copying chunks
    //       of data_blocks around as we often have much more info at the
    //       callsite about the copy and we can make assumptions.
    pub const LongSlice = struct {
        start_block: *DataBlock,
        start_ofs: u7,
        len: ByteIdx,
    };
    fn slice_long(db: *DataBlock, r: *Rope, ofs: ByteIdxDelta, len: ByteIdx) LongSlice {
        if (ofs >= 0) {
            var ofs_rest: ByteIdx = @intCast(ofs);
            var start_block = db;
            while (ofs_rest >= start_block.meta.bytes) {
                start_block = r.data_blocks.at(
                    db.meta.next orelse @panic("slice ofs out of bounds"),
                );
                ofs_rest -= start_block.meta.bytes;
            }
            assert(ofs_rest < start_block.meta.bytes);
            return .{
                .start_block = start_block,
                .start_ofs = @intCast(ofs_rest),
                .len = len,
            };
        } else {
            var ofs_rest: ByteIdx = @intCast(-ofs);
            assert(ofs_rest > 0);

            var start_block = r.data_blocks.at(
                db.meta.prev orelse @panic("slice ofs out of bounds"),
            );
            while (ofs_rest > start_block.meta.bytes) {
                start_block = r.data_blocks.at(
                    db.meta.prev orelse @panic("slice ofs out of bounds"),
                );
                ofs_rest -= start_block.meta.bytes;
            }
            assert(ofs_rest < start_block.meta.bytes);
            return .{
                .start_block = start_block,
                .start_ofs = @intCast(
                    start_block.meta.bytes -
                        @as(u8, @intCast(ofs_rest)),
                ),
                .len = len,
            };
        }
    }
};

pub fn init(alloc: std.mem.Allocator) Rope {
    var r: Rope = .{
        .alloc = alloc,
        .indx_root = undefined,
        .indx_blocks = .{},
        .data_blocks = .{},
    };

    // These addOne calls dont allocate as we have a stack allocated portion
    // that is large enough for init.
    r.indx_root = r.indx_blocks.addOne(r.alloc) catch unreachable;
    r.indx_root.* = .empty_leaf;

    var dbs: [2]struct { ptr: *DataBlock, idx: DataBlock.Idx } = undefined;
    for (0..2) |i| {
        const idx: DataBlock.Idx = @intCast(r.data_blocks.len);
        const ptr = r.data_blocks.addOne(r.alloc) catch unreachable;
        ptr.* = .{
            .meta = .{
                .bytes = 0,
                .newlines = 0,
                .next = null,
                .prev = null,
            },
            .bytes = undefined,
        };
        dbs[i] = .{ .ptr = ptr, .idx = idx };
        r.indx_root.keys[i] = bytes_from_int(@as(SubtreeByteSize, 0));
        r.indx_root.children[i] = bytes_from_int(idx);
    }
    dbs[0].ptr.meta.next = dbs[1].idx;
    dbs[1].ptr.meta.prev = dbs[0].idx;
    return r;
}

pub fn deinit(r: *Rope) void {
    r.indx_blocks.deinit(r.alloc);
    r.data_blocks.deinit(r.alloc);
    r.* = undefined;
}

const BlockPathEntry = struct {
    // index to the key in the parent block
    // TODO?: type should be KeysLen so we can point to the end of the block
    //        we just need a way to insert at the end.
    key_idx: KeyIdx,
    // parent block
    parent_block: *IndxBlock,
};

/// Find the leaf index block that *should* contain the given offset.
fn find_indx_leaf_block(
    r: *Rope,
    block_: *IndxBlock,
    ofs: ByteIdx,
    path_store: ?*[indx_blocks_height_max]BlockPathEntry,
) struct {
    block: *IndxBlock,
    block_ofs: ByteIdx,
    path: ?[]BlockPathEntry,
} {
    var block = block_;
    var block_ofs: ByteIdx = 0;
    assert(ofs <= block.sum_subtree_sizes());

    var path = if (path_store) |p|
        std.ArrayListUnmanaged(BlockPathEntry).initBuffer(p)
    else
        null;

    for (0..indx_blocks_height_max) |depth| {
        if (block.meta.is_leaf) {
            return .{
                .block = block,
                .block_ofs = block_ofs,
                .path = if (path) |p| p.items else null,
            };
        }

        const next_block: *IndxBlock, //
        const key_idx: KeyIdx, //
        const next_block_ofs: ByteIdx = next: {
            var cum_len: ByteIdx = block_ofs;
            for (block.keys, 0..) |key, i| {
                if (IndxBlock.raw_key_is_null(key)) {
                    assert(i >= indx_block_keys_min);
                    // handle case where ofs is exactly one past the end of
                    // rope.
                    if (ofs == cum_len) {
                        const last_idx = int_from_bytes(
                            IndxBlock.Idx,
                            block.children[i - 1],
                        );
                        const last_len = int_from_bytes(
                            SubtreeByteSize,
                            block.keys[i - 1],
                        );
                        break :next .{
                            r.indx_blocks.at(last_idx),
                            @intCast(i - 1),
                            cum_len - last_len,
                        };
                    }
                    break;
                }

                const this_len = int_from_bytes(SubtreeByteSize, key);
                if (ofs < cum_len + this_len) {
                    const idx = int_from_bytes(
                        IndxBlock.Idx,
                        block.children[i],
                    );
                    break :next .{
                        r.indx_blocks.at(idx),
                        @intCast(i),
                        cum_len,
                    };
                }
                cum_len += this_len;
            }
            @panic("requested ofs out of bounds");
        };

        assert(next_block != block);
        assert(next_block_ofs >= block_ofs);

        if (path) |*p| {
            assert(p.items.len == depth);
            p.appendAssumeCapacity(.{
                .key_idx = key_idx,
                .parent_block = block,
            });
        }

        // std.debug.assert(next.meta.bytes <= block.meta.bytes);
        // std.debug.assert(next.meta.lines <= block.meta.lines);
        block = next_block;
        block_ofs = next_block_ofs;
    }
    unreachable;
}

// TODO: merge this with find_indx_leaf_block
fn find_data_block(
    r: *Rope,
    root: *IndxBlock,
    ofs: ByteIdx,
    path_store: *[indx_blocks_height_max]BlockPathEntry,
) struct {
    path: []BlockPathEntry,
    // block: *DataBlock,
    block_ofs: ByteIdx,
} {
    const leaf = r.find_indx_leaf_block(root, ofs, path_store);
    var path = leaf.path.?;
    const db_entry: BlockPathEntry, //
    const block_ofs = db: {
        assert(leaf.block.meta.is_leaf);

        var cum_ofs: ByteIdx = leaf.block_ofs;
        // var i: KeyIdx = 0;

        for (leaf.block.keys, 0..) |key, i| {
            if (IndxBlock.raw_key_is_null(key)) {
                // block should not be empty
                assert(i != 0);
                // assert(i >= indx_block_keys_min);
                // handle case where ofs is exactly one past the end of
                // rope.
                if (ofs == cum_ofs) {
                    const last_len = int_from_bytes(
                        SubtreeByteSize,
                        leaf.block.keys[i - 1],
                    );
                    break :db .{
                        .{
                            .parent_block = leaf.block,
                            .key_idx = @intCast(i - 1),
                        },
                        cum_ofs - last_len,
                    };
                }
                break;
            }
            const this_len = int_from_bytes(SubtreeByteSize, key);
            if (this_len == 0) {
                // len = 0 only happends in this situation:
                assert(leaf.block == root);
                assert(leaf.block.keys_len() == 2);

                if (ofs == cum_ofs) break :db .{
                    .{
                        .parent_block = leaf.block,
                        .key_idx = @intCast(i),
                    },
                    cum_ofs,
                };
                break;
            }
            if (ofs < cum_ofs + this_len) {
                break :db .{
                    .{
                        .parent_block = leaf.block,
                        .key_idx = @intCast(i),
                    },
                    cum_ofs,
                };
            }
            cum_ofs += this_len;
        }
        @panic("ofs out of bounds of leaf");
    };

    // extend path to point to data block containing ofs
    path.len += 1;
    path[path.len - 1] = db_entry;

    // const block_idx_raw =
    //     path[path.len - 1].block.children[path[path.len - 1].key_idx];
    // const block_idx = int_from_bytes(DataBlock.Idx, block_idx_raw);
    // const block = r.data_blocks.at(block_idx);

    return .{
        .path = path,
        // .block = block,
        .block_ofs = block_ofs,
    };
}

fn alloc_at(r: *Rope, ofs: ByteIdx, alloc_len: ByteIdx) !struct {
    /// Data block that contains the start of the allocated range.
    start_data_block: *DataBlock,
    /// Offset into the start data block that the allocated range starts at.
    start_ofs: ByteIdx,
    /// Bytes successfully allocated.
    alloc_len: ByteIdx,
} {
    var path_store: [indx_blocks_height_max]BlockPathEntry = undefined;
    const target_query = x: {
        break :x r.find_data_block(r.indx_root, ofs, &path_store);
    };
    assert(target_query.block_ofs <= ofs);

    // path to the leaf block == path to data - 1
    const target_parent_path = target_query.path[0 .. target_query.path.len - 1];

    const target = x: {
        const entry = target_query.path[target_query.path.len - 1];
        const len: u8 = @intCast(
            entry.parent_block.child_subtree_bytes(entry.key_idx),
        );
        assert(len <= data_block_bytes_max);
        if (len == 0) {
            assert(target_query.block_ofs == ofs);
        } else {
            assert(target_query.block_ofs + len > ofs);
        }
        break :x .{
            .parent_block = entry.parent_block,
            .key_idx = entry.key_idx,
            .block = r.data_blocks.at(
                entry.parent_block.child_data_block(entry.key_idx),
            ),
            .block_ofs = target_query.block_ofs,
            .len = @as(u8, len),
            .space = @as(u8, data_block_bytes_max - len),
        };
    };

    // STEP 0: handle the data fitting without data block splitting.

    if (target.space >= alloc_len) {
        // we can fit the data in this single existing data block
        const start_ofs: u7 = @intCast(ofs - target.block_ofs);
        assert(start_ofs < data_block_bytes_max);

        // make room at the ofs
        data_block_shr(target.block, start_ofs, @truncate(alloc_len));

        // set new len
        const new_len: u8 = @intCast(target.len + alloc_len);
        assert(new_len <= data_block_bytes_max);
        assert(target.block.meta.bytes == target.len);
        target.block.meta.bytes = new_len;
        target.parent_block.set_child_subtree_bytes(target.key_idx, new_len);

        indx_block_update_len(target_parent_path, @intCast(alloc_len));

        return .{
            .start_data_block = target.block,
            .start_ofs = start_ofs,
            .alloc_len = alloc_len,
        };
    }

    const target_r = right: {
        const has_right = target.key_idx + 1 < indx_block_keys_max and
            !IndxBlock.raw_key_is_null(
            target.parent_block.keys[target.key_idx + 1],
        );
        if (!has_right) break :right null;

        const len: u8 = @intCast(
            target.parent_block.child_subtree_bytes(target.key_idx + 1),
        );
        assert(len <= data_block_bytes_max);

        break :right .{
            .len = @as(u8, len),
            .space = @as(u8, data_block_bytes_max - len),
            .block = r.data_blocks.at(
                target.parent_block.child_data_block(target.key_idx + 1),
            ),
            .key_idx = target.key_idx + 1,
        };
    };

    if (target_r != null and
        target_r.?.space + target.space >= alloc_len)
    {
        // this + right is enough space
        const start_ofs: u7 = @intCast(ofs - target.block_ofs);
        assert(start_ofs < data_block_bytes_max);

        // make room in the right data block
        //
        // PICTURE: before/after alloc:
        //
        // a-z = data
        // .   = undefined
        // _   = undefined allocated
        //
        // helloworld..... | goodbye........
        // helloworld_____ | _goodbye.......
        //                   ^overflow
        //
        // helloworld..... | goodbye........
        // hellowo______rl | dgoodbye.......
        //                   ^overflow
        //              ^^   ^postfix
        //
        // helloworld..... | goodbye........
        // hellowo________ | __rldgoodbye...
        //                   ^^^^^overflow
        //                     ^^^postfix

        // alloc right
        assert(alloc_len > target.space);
        const overflow_len: u8 = @intCast(alloc_len - target.space);
        const postfix_len: u8 = target.len - start_ofs;
        data_block_shr(target_r.?.block, 0, overflow_len);
        if (postfix_len > 0) {
            const of_pf_len: u8 = @min(postfix_len, overflow_len);
            data_block_cpy(
                target_r.?.block.slice(
                    @intCast(overflow_len -| postfix_len),
                    of_pf_len,
                ),
                target.block.slice(
                    @intCast(target.len - of_pf_len),
                    of_pf_len,
                ),
            );
        }
        data_block_shr(target.block, start_ofs, @truncate(alloc_len));

        // set new len
        const new_target_len = data_block_bytes_max;
        const new_target_r_len = target_r.?.len + overflow_len;
        assert(new_target_len <= data_block_bytes_max);
        assert(new_target_r_len <= data_block_bytes_max);
        assert(
            new_target_len + new_target_r_len ==
                target.len + target_r.?.len + alloc_len,
        );
        assert(target.block.meta.bytes == target.len);
        assert(target_r.?.block.meta.bytes == target_r.?.len);
        target.block.meta.bytes = new_target_len;
        target_r.?.block.meta.bytes = new_target_r_len;
        target.parent_block
            .set_child_subtree_bytes(target.key_idx, new_target_len);
        target.parent_block
            .set_child_subtree_bytes(target.key_idx + 1, new_target_r_len);

        indx_block_update_len(target_parent_path, @intCast(alloc_len));

        return .{
            .start_data_block = target.block,
            .start_ofs = start_ofs,
            .alloc_len = alloc_len,
        };
    }

    const target_l = left: {
        const has_left = target.key_idx > 0;
        if (!has_left) break :left null;

        const len: u8 = @intCast(
            target.parent_block.child_subtree_bytes(target.key_idx - 1),
        );
        assert(len <= data_block_bytes_max);

        break :left .{
            .len = @as(u8, len),
            .space = @as(u8, data_block_bytes_max - len),
            .block_ofs = @as(ByteIdx, target.block_ofs - len),
            .block = r.data_blocks.at(
                target.parent_block.child_data_block(target.key_idx - 1),
            ),
            .key_idx = target.key_idx - 1,
        };
    };

    if (target_l != null and
        @as(ByteIdx, target_l.?.space) +
        @as(ByteIdx, target.space) +
        @as(ByteIdx, if (target_r) |r_| r_.space else 0) >= alloc_len)
    {
        // this + left + right is enough space

        // PICTURE: before/after alloc:
        //
        // a-z = data
        // .   = undefined
        // _   = undefined allocated
        //
        // something... | helloworld..... | goodbye........
        // somethinghel | loworld________ | _goodbye.......
        //          ^^^underflow            ^overflow
        //          ^^^   ^^^^^^^prefix
        //
        // something... | helloworld..... | goodbye........
        // somethinghel | lowo_________rl | dgoodbye.......
        //          ^^^underflow            ^overflow
        //          ^^^   ^^^^prefix   ^^   ^postfix
        //
        // something... | helloworld..... | goodbye........
        // somethinghel | lowo___________ | __rldgoodbye...
        //          ^^^underflow            ^^^^^overflow
        //          ^^^   ^^^^prefix          ^^^postfix
        //
        // something... | helloworld..... | goodbye........
        // somethingh__ | ___________ello | worldgoodbye...
        //          ^^^underflow            ^^^^^overflow
        //          ^prefix          ^^^^   ^^^^^postfix
        //
        // something... | helloworld..... | goodbye........
        // somethinghel | lo_____________ | worldgoodbye...
        //          ^^^underflow            ^^^^^overflow
        //          ^^^   ^^prefix          ^^^^^postfix
        //
        // something... | helloworldlalal | goodbyelolololo
        // somethinghel | lo_worldlalal.. | goodbyelolololo
        //          ^^^underflow
        //          ^^^   ^^prefix

        // alloc left
        assert(alloc_len > target.space);
        const underflow_len: u8 = target_l.?.space;
        const prefix_len: u7 = @intCast(ofs - target.block_ofs);
        if (prefix_len > 0) {
            const uf_pf_len = @min(underflow_len, prefix_len);
            data_block_cpy(
                target_l.?.block.slice(@intCast(target_l.?.len), uf_pf_len),
                target.block.slice(0, uf_pf_len),
            );
        }

        // alloc right
        const overflow_len: u8 = @intCast(
            alloc_len -| target.space -| underflow_len,
        );
        assert(overflow_len <= data_block_bytes_max);
        const postfix_len = target.len - prefix_len;
        if (target_r != null and target_r.?.space > 0 and overflow_len > 0) {
            if (overflow_len == data_block_bytes_max) {
                data_block_clear(target_r.?.block);
            } else {
                data_block_shr(target_r.?.block, 0, overflow_len);
            }
            if (postfix_len > 0) {
                const of_pf_len = @min(postfix_len, overflow_len);
                assert(of_pf_len > 0);
                data_block_cpy(
                    target_r.?.block.slice(
                        @intCast(overflow_len -| postfix_len),
                        of_pf_len,
                    ),
                    target.block.slice(
                        @intCast(target.len - of_pf_len),
                        of_pf_len,
                    ),
                );
            }
        } else {
            assert(overflow_len == 0);
        }

        // alloc target
        if (alloc_len >= underflow_len) {
            // target grows
            if (prefix_len > 0) {
                data_block_shl(target.block, prefix_len, underflow_len);
            }
            if (postfix_len > 0 and prefix_len < target.len) {
                data_block_shr(target.block, prefix_len, @truncate(
                    alloc_len - underflow_len,
                ));
            }
        } else {
            // target shrinks
            data_block_shl(
                target.block,
                target.len,
                underflow_len - @as(u7, @intCast(alloc_len)),
            );
            if (prefix_len > 0) {
                data_block_shl(
                    target.block,
                    prefix_len -
                        (underflow_len - @as(u7, @intCast(alloc_len))),
                    @truncate(alloc_len),
                );
            }
        }

        // set new len
        const new_left_len = data_block_bytes_max;
        const new_this_len = @min(
            target.len + alloc_len - underflow_len,
            data_block_bytes_max,
        );
        assert(new_left_len <= data_block_bytes_max);
        assert(new_this_len <= data_block_bytes_max);

        const parent = target.parent_block;
        if (overflow_len > 0) {
            const new_right_len = target_r.?.len + overflow_len;
            assert(new_right_len <= data_block_bytes_max);
            assert(
                new_left_len + new_this_len + new_right_len ==
                    target_l.?.len + target.len + target_r.?.len + alloc_len,
            );

            assert(target_r.?.block.meta.bytes == target_r.?.len);
            target_r.?.block.meta.bytes = new_right_len;
            parent.set_child_subtree_bytes(target.key_idx + 1, new_right_len);
        } else {
            assert(
                new_left_len + new_this_len ==
                    target_l.?.len + target.len + alloc_len,
            );
        }
        assert(target_l.?.block.meta.bytes == target_l.?.len);
        assert(target.block.meta.bytes == target.len);
        target_l.?.block.meta.bytes = new_left_len;
        target.block.meta.bytes = new_this_len;
        parent.set_child_subtree_bytes(target.key_idx - 1, new_left_len);
        parent.set_child_subtree_bytes(target.key_idx, new_this_len);

        indx_block_update_len(target_parent_path, @intCast(alloc_len));

        if (prefix_len < underflow_len) {
            return .{
                .start_data_block = target_l.?.block,
                .start_ofs = target_l.?.len + prefix_len,
                .alloc_len = alloc_len,
            };
        } else {
            return .{
                .start_data_block = target.block,
                .start_ofs = prefix_len - underflow_len,
                .alloc_len = alloc_len,
            };
        }
    }

    // NOTE: Now we know that we need to split target and r/l to create new
    //       data blocks for alloc_len.
    const InfoL = struct {
        len: u8,
        space: u8,
        block: *DataBlock,
        key_idx: KeyIdx,
        block_ofs: ByteIdx,
    };
    const InfoR = struct {
        len: u8,
        space: u8,
        block: *DataBlock,
        key_idx: KeyIdx,
    };
    const split_l: InfoL, const split_r: InfoR = if (target_l) |l| .{
        InfoL{
            .len = l.len,
            .space = l.space,
            .block = l.block,
            .key_idx = l.key_idx,
            .block_ofs = l.block_ofs,
        },
        InfoR{
            .len = target.len,
            .space = target.space,
            .block = target.block,
            .key_idx = target.key_idx,
        },
    } else if (target_r) |r_| .{
        InfoL{
            .len = target.len,
            .space = target.space,
            .block = target.block,
            .key_idx = target.key_idx,
            .block_ofs = target.block_ofs,
        },
        InfoR{
            .len = r_.len,
            .space = r_.space,
            .block = r_.block,
            .key_idx = r_.key_idx,
        },
    } else @panic(
        \\a data block should always have at least one sibling in the same 
        ++
        \\parent
    );

    // new data blocks and l/r will be 2/3 full. l will contain the spill.
    const total_data_blocks =
        (@as(ByteIdx, split_l.len) +
        @as(ByteIdx, split_r.len) +
        alloc_len) / data_block_bytes_min;
    assert(total_data_blocks >= 3);
    const new_data_blocks: DataBlock.Idx = @intCast(total_data_blocks - 2);

    const prefix_len = ofs - split_l.block_ofs;
    const postfix_len = (split_l.len - prefix_len) + split_r.len;
    var buf_store: [data_block_bytes_max * 2]u8 = undefined;
    var buf = std.ArrayListUnmanaged(u8).initBuffer(&buf_store);
    buf.appendSliceAssumeCapacity(split_l.block.bytes[0..split_l.len]);
    buf.appendSliceAssumeCapacity(split_r.block.bytes[0..split_r.len]);

    // set split l/r lengths in advance so the insert_data_blocks call can
    // accurately recalculate the subtree sizes.
    const spill_len: u6 = @intCast(
        (split_l.len + split_r.len + alloc_len) -
            (total_data_blocks * data_block_bytes_min),
    );
    assert(spill_len <= (data_block_bytes_max + 2) / 3);
    const new_split_l_len: u8 = data_block_bytes_min + @as(u8, spill_len);
    const new_split_r_len: u7 = data_block_bytes_min;
    assert(new_split_l_len <= data_block_bytes_max);
    assert(new_split_r_len <= data_block_bytes_max);
    assert(
        @as(ByteIdx, new_split_l_len) +
            @as(ByteIdx, new_split_r_len) +
            @as(ByteIdx, data_block_bytes_min * new_data_blocks) ==
            @as(ByteIdx, split_l.len) +
            @as(ByteIdx, split_r.len) +
            alloc_len,
    );
    assert(split_l.block.meta.bytes == split_l.len);
    assert(split_r.block.meta.bytes == split_r.len);
    split_l.block.meta.bytes = new_split_l_len;
    split_r.block.meta.bytes = new_split_r_len;
    {
        const parent = target.parent_block;
        parent.set_child_subtree_bytes(split_l.key_idx, new_split_l_len);
        parent.set_child_subtree_bytes(split_r.key_idx, new_split_r_len);
    }

    const allocated_data_blocks = x: {
        var path = target_query.path;
        path[path.len - 1].key_idx = split_r.key_idx;
        var rest: DataBlock.Idx = new_data_blocks;
        assert(rest > 0);
        // bound our loop because we are paranoid :)
        for (0..1000) |_| {
            const res = try r.insert_data_blocks(path, rest);
            rest -= res.inserted_count;
            // NOTE: as things are currently implemented, we will only ever
            // receive a new_path if we DONT have a split. But if there wasn't
            // a split, then we have fit all the requested blocks and ther is
            // no need for another iteration.
            //
            // In light of the above,
            // If we can't correct the path in the case of a split,
            // Then the whole path correction mechanism is a useless
            // waste of cycles and complexity.
            // TODO: remove path correction nonsense
            if (res.new_path != null) {
                // validate the above comment block is correct:
                assert(res.inserted_count == new_data_blocks);
            }

            // If we lost our path, we need to exit and be called again.
            // AFAICT it's not possible to simply requery the path here
            // as the split_l and split_r blocks are probably not in the
            // same parent indx block anymore so we need to re-calculate
            // which blocks we choose as a the split point.
            path = res.new_path orelse break;
            if (rest <= 0) break;
        }
        break :x new_data_blocks - rest;
    };

    // TODO: avoid long slices and do manual chunk copying.
    //       The long copying is just easier to write for now.
    assert(
        buf.items.len == @as(ByteIdx, prefix_len) + @as(ByteIdx, postfix_len),
    );
    assert(r.data_block_set_bytes_long(
        split_l.block.slice_long(r, 0, prefix_len),
        buf.items[0..prefix_len],
    ) == prefix_len);
    assert(r.data_block_set_bytes_long(
        split_r.block.slice_long(
            r,
            // NOTE: This will be negative on PURPOSE
            @as(ByteIdxDelta, new_split_r_len) -
                @as(ByteIdxDelta, postfix_len),
            postfix_len,
        ),
        buf.items[prefix_len..],
    ) == postfix_len);

    const alloc_slice = split_l.block.slice_long(r, prefix_len, alloc_len);
    return .{
        .start_data_block = alloc_slice.start_block,
        .start_ofs = alloc_slice.start_ofs,
        .alloc_len = (@as(ByteIdx, data_block_bytes_min) * 2) +
            @as(ByteIdx, spill_len) +
            @as(ByteIdx, allocated_data_blocks * data_block_bytes_min) -
            (@as(ByteIdx, split_l.len) + @as(ByteIdx, split_r.len)),
    };
}

/// Insert at at most new_data_blocks data blocks right before the datablock
/// pointed to by the given path.
/// New data blocks are initialized to data_block_bytes_min undefined bytes.
///
/// Returns the amount of new data blocks inserted. (nonzero)
/// Modifies path to point to the first new data block.
fn insert_data_blocks(
    r: *Rope,
    path: []BlockPathEntry,
    new_data_blocks: DataBlock.Idx,
) !struct {
    inserted_count: DataBlock.Idx,
    new_path: ?[]BlockPathEntry,
} {
    assert(new_data_blocks > 0);
    assert(path.len > 0);

    // leaf parent block of data block insert point
    const target = target: {
        const child_entry = path[path.len - 1];
        const block = child_entry.parent_block;
        assert(block.meta.is_leaf);
        const len: KeysLen = block.keys_len();
        assert(len <= indx_block_keys_max);
        assert(len > 0);

        const postfix_begin_idx = block.child_data_block(child_entry.key_idx);
        const postfix_begin: *DataBlock = r.data_blocks.at(postfix_begin_idx);

        break :target .{
            .len = @as(KeysLen, len),
            .space = @as(KeyIdx, @intCast(indx_block_keys_max - len)),
            .block = block,
            .entry = if (path.len > 1)
                path[path.len - 2]
            else
                null,
            .data_postfix_begin_idx = postfix_begin_idx,
            .data_postfix_begin = postfix_begin,
        };
    };

    // == Special case for leaf layer ==
    //
    // Thanks to the linked list of data blocks, we don't need to use the stack
    // allocated buffer like we do for the other layers.
    //
    // The main advantage is that by using the stack buffer only for the parent
    // layer and above, we can one-shot allocate an extra order of magnitude
    // more data blocks since we are only bounded by the buffer size in the
    // parent layers.

    if (new_data_blocks <= target.space) {
        // fits in the single indx block
        const start_ofs = path[path.len - 1].key_idx;
        assert(start_ofs < indx_block_keys_max);

        // make room at the ofs
        indx_block_shr(target.block, start_ofs, @truncate(new_data_blocks));

        // insert into the linked list of data blocks and children
        try r.data_block_insert_with_bufs(
            new_data_blocks,
            target.data_postfix_begin,
            target.data_postfix_begin_idx,
            target.block.keys[start_ofs .. start_ofs + new_data_blocks],
            target.block.children[start_ofs .. start_ofs + new_data_blocks],
        );

        // path to the target leaf block
        indx_block_update_len(path[0 .. path.len - 1], @intCast(
            new_data_blocks * data_block_bytes_min,
        ));

        return .{
            .inserted_count = new_data_blocks,
            .new_path = path,
        };
    }

    const target_r = right: {
        const entry = target.entry orelse break :right null;
        const has_right =
            entry.key_idx + 1 < indx_block_keys_max and
            !IndxBlock.raw_key_is_null(
            entry.parent_block.keys[entry.key_idx + 1],
        );
        if (!has_right) break :right null;

        const block = r.indx_blocks.at(
            entry.parent_block.child_indx_block(entry.key_idx + 1),
        );
        assert(block.meta.is_leaf);
        const len: KeysLen = block.keys_len();
        assert(len <= indx_block_keys_max);
        assert(len >= indx_block_keys_min);
        break :right .{
            .len = @as(KeysLen, len),
            .space = @as(KeyIdx, @intCast(indx_block_keys_max - len)),
            .block = block,
        };
    };

    if (target_r != null and
        new_data_blocks <= target.space + target_r.?.space)
    {
        // fits in these two indx blocks.
        const start_ofs = path[path.len - 1].key_idx;
        assert(start_ofs < indx_block_keys_max);

        const prefix_len = start_ofs;
        const postfix_len = target.len - start_ofs;

        var keys_buf: [
            @as(comptime_int, indx_block_keys_max) * 2
        ]IndxBlock.RawKey align(dcache_line_bytes) = undefined;
        var children_buf: [
            @as(comptime_int, indx_block_keys_max) * 2
        ]IndxBlock.RawChild align(dcache_line_bytes) = undefined;
        try r.data_block_insert_with_bufs(
            new_data_blocks,
            target.data_postfix_begin,
            target.data_postfix_begin_idx,
            keys_buf[0..new_data_blocks],
            children_buf[0..new_data_blocks],
        );
        @memcpy(
            keys_buf[new_data_blocks..][0..postfix_len],
            target.block.keys[prefix_len..][0..postfix_len],
        );
        @memcpy(
            children_buf[new_data_blocks..][0..postfix_len],
            target.block.children[prefix_len..][0..postfix_len],
        );

        // grow the right indx block
        assert(new_data_blocks > target.space);
        const overflow_len = new_data_blocks - target.space;
        assert(overflow_len > 0);
        indx_block_shr(target_r.?.block, 0, @truncate(overflow_len));
        const filler_len = indx_block_keys_max - prefix_len;
        @memcpy(
            target_r.?.block.keys[0..overflow_len],
            keys_buf[filler_len..][0..overflow_len],
        );
        @memcpy(
            target_r.?.block.children[0..overflow_len],
            children_buf[filler_len..][0..overflow_len],
        );
        // fill target
        @memcpy(
            target.block.keys[prefix_len..indx_block_keys_max],
            keys_buf[0..filler_len],
        );
        @memcpy(
            target.block.children[prefix_len..indx_block_keys_max],
            children_buf[0..filler_len],
        );

        // update subtree lengths in parent
        {
            const parent = path[path.len - 2];
            const size = target.block.sum_subtree_sizes();
            const size_r = target_r.?.block.sum_subtree_sizes();
            parent.parent_block
                .set_child_subtree_bytes(parent.key_idx, size);
            parent.parent_block
                .set_child_subtree_bytes(parent.key_idx + 1, size_r);
        }
        // path to the parent of the target leaf block
        indx_block_update_len(path[0 .. path.len - 2], @intCast(
            new_data_blocks * data_block_bytes_min,
        ));

        return .{
            .inserted_count = new_data_blocks,
            .new_path = path,
        };
    }

    const target_l = left: {
        const entry = target.entry orelse break :left null;
        const has_left = entry.key_idx > 0;
        if (!has_left) break :left null;

        const block = r.indx_blocks.at(
            entry.parent_block
                .child_indx_block(entry.key_idx - 1),
        );
        assert(block.meta.is_leaf);
        const len: KeysLen = block.keys_len();
        assert(len <= indx_block_keys_max);
        assert(len >= indx_block_keys_min);
        break :left .{
            .len = @as(KeysLen, len),
            .space = @as(KeyIdx, @intCast(indx_block_keys_max - len)),
            .block = block,
        };
    };

    if (target_l != null and
        target_l.?.space +
        target.space +
        (if (target_r) |r_| r_.space else 0) >= new_data_blocks)
    {
        // fits in these three/two indx blocks

        const prefix_len: KeyIdx = path[path.len - 1].key_idx;
        const postfix_len: KeysLen = target.len - prefix_len;

        const underflow_len: KeyIdx = target_l.?.space;
        const overflow_len: KeyIdx = @intCast(
            new_data_blocks -| target.space -| underflow_len,
        );

        var keys_buf: [
            @as(comptime_int, indx_block_keys_max) * 3
        ]IndxBlock.RawKey align(dcache_line_bytes) =
            @splat(IndxBlock.null_key);
        var children_buf: [
            @as(comptime_int, indx_block_keys_max) * 3
        ]IndxBlock.RawChild align(dcache_line_bytes) = undefined;
        @memcpy(
            keys_buf[0..prefix_len],
            target.block.keys[0..prefix_len],
        );
        @memcpy(
            children_buf[0..prefix_len],
            target.block.children[0..prefix_len],
        );
        try r.data_block_insert_with_bufs(
            new_data_blocks,
            target.data_postfix_begin,
            target.data_postfix_begin_idx,
            keys_buf[prefix_len..][0..new_data_blocks],
            children_buf[prefix_len..][0..new_data_blocks],
        );
        @memcpy(
            keys_buf[prefix_len + new_data_blocks ..][0..postfix_len],
            target.block.keys[prefix_len..][0..postfix_len],
        );
        @memcpy(
            children_buf[prefix_len + new_data_blocks ..][0..postfix_len],
            target.block.children[prefix_len..][0..postfix_len],
        );

        @memcpy(
            target_l.?.block.keys[target_l.?.len..],
            keys_buf[0..underflow_len],
        );
        @memcpy(
            target_l.?.block.children[target_l.?.len..],
            children_buf[0..underflow_len],
        );
        target.block.keys =
            keys_buf[underflow_len..][0..indx_block_keys_max].*;
        target.block.children =
            children_buf[underflow_len..][0..indx_block_keys_max].*;

        // maybe grow the right indx block
        if (overflow_len > 0) {
            indx_block_shr(target_r.?.block, 0, overflow_len);
            @memcpy(
                target_r.?.block.keys[0..overflow_len],
                keys_buf[underflow_len +
                    indx_block_keys_max ..][0..overflow_len],
            );
            @memcpy(
                target_r.?.block.children[0..overflow_len],
                children_buf[underflow_len +
                    indx_block_keys_max ..][0..overflow_len],
            );
        }

        // update subtree lengths in parent
        {
            const parent = path[path.len - 2];
            const size_l = target_l.?.block.sum_subtree_sizes();
            const size = target.block.sum_subtree_sizes();
            const size_r = if (overflow_len > 0)
                target_r.?.block.sum_subtree_sizes()
            else
                null;
            parent.parent_block
                .set_child_subtree_bytes(parent.key_idx - 1, size_l);
            parent.parent_block
                .set_child_subtree_bytes(parent.key_idx, size);
            if (overflow_len > 0) {
                parent.parent_block
                    .set_child_subtree_bytes(parent.key_idx + 1, size_r.?);
            }
        }
        // path to the parent of the target leaf block
        indx_block_update_len(path[0 .. path.len - 2], @intCast(
            new_data_blocks * data_block_bytes_min,
        ));

        // set the path to point to the first new data block
        if (prefix_len < underflow_len) {
            path[path.len - 2].key_idx -= 1;
            path[path.len - 1].parent_block = target_l.?.block;
            path[path.len - 1].key_idx = @intCast(target_l.?.len + prefix_len);
        } else {
            path[path.len - 1].key_idx -= underflow_len;
        }

        return .{
            .inserted_count = new_data_blocks,
            .new_path = path,
        };
    }

    const SplitInfo = struct {
        len: KeysLen,
        space: KeyIdx,
        block: *IndxBlock,
    };
    const split_l, const split_r = if (target_l) |l| .{
        SplitInfo{
            .len = l.len,
            .space = l.space,
            .block = l.block,
        },
        SplitInfo{
            .len = target.len,
            .space = target.space,
            .block = target.block,
        },
    } else if (target_r) |r_| .{
        SplitInfo{
            .len = target.len,
            .space = target.space,
            .block = target.block,
        },
        SplitInfo{
            .len = r_.len,
            .space = r_.space,
            .block = r_.block,
        },
    } else unreachable;

    // we need to split target and r/l to create new data blocks for the
    // insertion.

    // new indx blocks are 2/3 full. l will contain the spill.
    // const total_indx_blocks =

    // CALC: max of 64 leaf blocks allocated:
    //    => max of 64 * 16 * (2/3) data blocks allocated
    //    => max of 64 * 16 * (2/3) * 128 * (2/3) bytes allocated
    //            = 56.88KiB allocated
    const new_leaf_blocks_max = 64;

    const new_indx_blocks: IndxBlock.Idx = x: {
        const total_indx_blocks =
            (split_l.len + split_r.len + new_data_blocks) / indx_block_keys_min;
        assert(total_indx_blocks >= 3);
        break :x @min(
            total_indx_blocks - 2,
            new_leaf_blocks_max,
        );
    };
    assert(new_indx_blocks > 0);

    const actual_new_data_blocks =
        split_l.space + // assume spill fills split_l
        (new_indx_blocks * indx_block_keys_min) + // new indx blocks
        // leftover space from split_r after it's existing len
        indx_block_keys_min -
        split_r.len;

    // save the first data block as it is the head of a linked list
    assert(split_l.len > 0);
    assert(!IndxBlock.raw_key_is_null(split_l.block.keys[0]));
    var next_data_block_idx: ?DataBlock.Idx = int_from_bytes(
        DataBlock.Idx,
        split_l.block.children[0],
    );
    try r.data_block_insert(
        actual_new_data_blocks,
        target.data_postfix_begin,
        target.data_postfix_begin_idx,
    );

    const spill_len: KeyIdx = @intCast(
        (split_l.len + split_r.len + actual_new_data_blocks) %
            indx_block_keys_min,
    );
    // indx_block_keys_min + spill_len goes into left
    split_l.block.* = .empty_leaf;
    next_data_block_idx = r.write_data_blocks(
        &split_l.block.keys,
        &split_l.block.children,
        next_data_block_idx.?,
        indx_block_keys_min + spill_len,
    );

    // middle goes into pending indx block insertion
    //
    // 256 + 128 bytes
    // 2*indx_block_keys_max extra spots for the insert_indx_blocks() call
    const pending_bs_store_len =
        new_leaf_blocks_max + (2 * @as(comptime_int, indx_block_keys_max));
    var pending_bs_store: [pending_bs_store_len]IndxBlock.RawChild = undefined;
    var pending_ks_store: [pending_bs_store_len]IndxBlock.RawKey =
        @splat(IndxBlock.null_key);
    var new_pending_bs: std.ArrayListUnmanaged(IndxBlock.RawChild) =
        .initBuffer(pending_bs_store[0..]);
    var new_pending_ks: std.ArrayListUnmanaged(IndxBlock.RawKey) =
        .initBuffer(pending_ks_store[0..]);

    for (0..new_indx_blocks) |_| {
        const new_leaf = try r.indx_blocks.addOne(r.alloc);
        new_leaf.* = .empty_leaf;
        next_data_block_idx = r.write_data_blocks(
            &new_leaf.keys,
            &new_leaf.children,
            next_data_block_idx.?,
            indx_block_keys_min,
        );
        const subtree_bytes = x: {
            var b: SubtreeByteSize = 0;
            for (new_leaf.keys) |key| {
                if (IndxBlock.raw_key_is_null(key)) break;
                b += int_from_bytes(SubtreeByteSize, key);
            }
            break :x b;
        };
        new_pending_bs.appendAssumeCapacity(bytes_from_int(
            @as(IndxBlock.Idx, @intCast(r.indx_blocks.len - 1)),
        ));
        new_pending_ks.appendAssumeCapacity(bytes_from_int(subtree_bytes));
    }
    assert(new_pending_bs.items.len == new_pending_ks.items.len);
    assert(new_pending_bs.items.len <= new_leaf_blocks_max);

    // last indx_block_keys_min goes into right
    split_r.block.* = .empty_leaf;
    assert(r.write_data_blocks(
        &split_r.block.keys,
        &split_r.block.children,
        next_data_block_idx.?,
        indx_block_keys_min,
    ).? == target.data_postfix_begin_idx);

    // set insert target
    if (split_l.block == target.block) {
        path[path.len - 2].key_idx += 1;
    } else {
        assert(split_r.block == target.block);
    }

    // TODO: use corrected path from insert_indx_blocks() call?
    // My hunch is that we can correct the path if the insertion point is in
    // the first two data blocks inserted but the case where it is in split_l
    // is impossible to recover as we lost the path to split_l.
    _ = try r.insert_indx_blocks(
        path[0 .. path.len - 1],
        new_pending_bs.items,
        new_pending_ks.items,
    );

    return .{
        .inserted_count = actual_new_data_blocks,
        .new_path = null,
    };
}

/// insert indx blocks right before the indx block pointed to by the given
/// path.
///
/// Invalidates the contents of the idxs slice. (used as a workarea)
/// Invalidates the contents of the keys slice. (used as a workarea)
/// Ivalidates the contents of the path slice.
///
/// Assumes idxs and keys are slices are over a buffer at least
/// `idxs.len + (2 * indx_block_keys_max)` long.
/// Assumes the path is a slice over a buffer at least
/// `indx_blocks_height_max` long.
///
/// If possible, modifies path to point to the first new indx block.
/// Returns a path slice that may be longer than the input path.
fn insert_indx_blocks(
    r: *Rope,
    path_: []BlockPathEntry,
    idxs: []IndxBlock.RawChild,
    // TODO: see if there is a clever way to avoid having this buffer at all
    keys: []IndxBlock.RawKey,
) !?[]BlockPathEntry {
    assert(idxs.len > 0);
    assert(path_.len > 0);

    const new_leaf_blocks_max = 64;
    assert(idxs.len <= new_leaf_blocks_max);

    var path = path_;
    var path_clobbered = false;
    // this slice of path used for insertion target shortens as we iterate and
    // move up the tree.
    var path_cursor = path.len - 1;
    var pending_bs = idxs;
    var pending_ks = keys;
    // // we can reuse the same buffers as the next iterations should be
    // // progressively smaller.
    // var next_pending_bs = idxs[0..0];
    // var next_pending_ks = keys[0..0];

    // cap iterations because we are paranoid :)
    for (0..indx_blocks_height_max - 1) |_| {
        assert(pending_bs.len > 0);
        assert(pending_ks.len > 0);
        assert(pending_bs.len == pending_ks.len);

        const target = target: {
            const block = path[path_cursor].parent_block;
            const len: KeysLen = block.keys_len();
            assert(len <= indx_block_keys_max);
            assert(len >= 0);

            break :target .{
                .len = @as(KeysLen, len),
                .space = @as(KeyIdx, @intCast(indx_block_keys_max - len)),
                .block = block,
                .entry = if (path_cursor > 0)
                    path[path_cursor - 1]
                else
                    null,
            };
        };

        if (target.space >= pending_bs.len) {
            const start_ofs = path[path_cursor].key_idx;
            assert(start_ofs < indx_block_keys_max);

            indx_block_shr(target.block, start_ofs, @truncate(pending_bs.len));
            @memcpy(
                target.block.keys[start_ofs..][0..pending_ks.len],
                pending_ks,
            );
            @memcpy(
                target.block.children[start_ofs..][0..pending_bs.len],
                pending_bs,
            );

            const size_delta = size_delta: {
                var delta: SubtreeByteSize = 0;
                for (pending_ks) |key| {
                    delta += int_from_bytes(SubtreeByteSize, key);
                }
                break :size_delta delta;
            };

            indx_block_update_len(path, @intCast(size_delta));
            return if (path_clobbered) null else path;
        }

        if (path_cursor == 0) {
            // we are at the root, so we can't split anymore.
            // Instead, we need to creat a new root and make this an internal
            // layer.

            const start_ofs = path[path_cursor].key_idx;

            const prefix_len = start_ofs;
            const postfix_len = target.len - start_ofs;
            //
            // Insert prefix before pending children
            //
            // NOTE: see assumptions in doc comment
            pending_bs.len += prefix_len;
            pending_ks.len += prefix_len;
            std.mem.copyBackwards(
                IndxBlock.RawChild,
                pending_bs[prefix_len..],
                pending_bs[0 .. pending_bs.len - prefix_len],
            );
            std.mem.copyBackwards(
                IndxBlock.RawKey,
                pending_ks[prefix_len..],
                pending_ks[0 .. pending_ks.len - prefix_len],
            );
            @memcpy(
                pending_bs[0..prefix_len],
                target.block.children[0..prefix_len],
            );
            @memcpy(
                pending_ks[0..prefix_len],
                target.block.keys[0..prefix_len],
            );
            //
            // Append postfix to pending children
            //
            // NOTE: see assumptions in doc comment
            pending_bs.len += postfix_len;
            pending_ks.len += postfix_len;
            @memcpy(
                pending_bs[pending_bs.len - postfix_len ..],
                target.block.children[prefix_len..][0..postfix_len],
            );
            @memcpy(
                pending_ks[pending_ks.len - postfix_len ..],
                target.block.keys[prefix_len..][0..postfix_len],
            );
            assert(pending_bs.len == pending_ks.len);

            const spill_len: KeyIdx = @intCast(
                pending_bs.len % indx_block_keys_min,
            );
            assert(spill_len <= (indx_block_keys_max + 2) / 3);
            // group pending blocks into new parents
            {
                var new_pending_bs = std.ArrayListUnmanaged(IndxBlock.RawChild)
                    .initBuffer(pending_bs);
                var new_pending_ks = std.ArrayListUnmanaged(IndxBlock.RawKey)
                    .initBuffer(pending_ks);

                var inserted_count: IndxBlock.Idx = 0;
                var next_child_len: KeysLen = indx_block_keys_min + spill_len;
                while (inserted_count < pending_bs.len) {
                    const new_child = try r.indx_blocks.addOne(r.alloc);
                    new_child.* = .{
                        .meta = .{ .is_leaf = false },
                        .keys = @splat(IndxBlock.null_key),
                        .children = undefined,
                    };
                    @memcpy(
                        new_child.keys[0..next_child_len],
                        pending_ks[inserted_count..][0..next_child_len],
                    );
                    @memcpy(
                        new_child.children[0..next_child_len],
                        pending_bs[inserted_count..][0..next_child_len],
                    );
                    const new_child_subtree_size = x: {
                        var len: SubtreeByteSize = 0;
                        for (new_child.keys) |key| {
                            if (IndxBlock.raw_key_is_null(key)) break;
                            len += int_from_bytes(SubtreeByteSize, key);
                        }
                        break :x len;
                    };

                    // we share the same buffer but always write slower than we
                    // read. So no clobbering.
                    assert(inserted_count >= 1);
                    new_pending_bs.appendAssumeCapacity(bytes_from_int(
                        @as(IndxBlock.Idx, @intCast(r.indx_blocks.len - 1)),
                    ));
                    new_pending_ks.appendAssumeCapacity(bytes_from_int(
                        new_child_subtree_size,
                    ));

                    inserted_count += next_child_len;
                    next_child_len = indx_block_keys_min;
                }

                pending_bs = new_pending_bs.items;
                pending_ks = new_pending_ks.items;
            }

            // repurpose target as the new root
            // NOTE: target.block is already root
            target.block.* = .{
                .meta = .{ .is_leaf = false },
                .keys = @splat(IndxBlock.null_key),
                .children = undefined,
            };

            // insert new root in path
            path.len += 1;
            std.mem.copyBackwards(
                BlockPathEntry,
                path[1..],
                path[0 .. path.len - 1],
            );
            path[0].parent_block = target.block;
            path[0].key_idx = 0;
            path_cursor = 0;
            // update the insert point
            path[1] = if (prefix_len < indx_block_keys_min + spill_len) x: {
                break :x .{
                    .parent_block = r.indx_blocks.at(
                        int_from_bytes(IndxBlock.Idx, pending_bs[0]),
                    ),
                    .key_idx = prefix_len,
                };
            } else if (prefix_len <
                (2 * @as(KeysLen, indx_block_keys_min)) + spill_len)
            x: {
                break :x .{
                    .parent_block = r.indx_blocks.at(
                        int_from_bytes(IndxBlock.Idx, pending_bs[1]),
                    ),
                    .key_idx = prefix_len - (indx_block_keys_min + spill_len),
                };
            } else unreachable;

            continue;
        }

        const target_r = right: {
            assert(path_cursor > 0);
            const entry = target.entry orelse break :right null;
            const has_right =
                entry.key_idx + 1 < indx_block_keys_max and
                !IndxBlock.raw_key_is_null(
                entry.parent_block.keys[entry.key_idx + 1],
            );
            if (!has_right) break :right null;

            const block = r.indx_blocks.at(
                entry.parent_block.child_indx_block(entry.key_idx + 1),
            );
            const len: KeysLen = block.keys_len();
            assert(len <= indx_block_keys_max);
            assert(len >= indx_block_keys_min);
            break :right .{
                .len = @as(KeysLen, len),
                .space = @as(KeyIdx, @intCast(indx_block_keys_max - len)),
                .block = block,
            };
        };

        if (target_r != null and
            target_r.?.space + target.space >= pending_bs.len)
        {
            // this + right is enough space

            const start_ofs = path[path_cursor].key_idx;
            const prefix_len = start_ofs;
            const postfix_len = target.len - start_ofs;

            // See assumptions in doc comment: we have two full blocks worth
            // of scratch space.
            //
            // append postfix to pending
            //
            {
                const end_ofs = pending_bs.len;
                pending_bs.len += postfix_len;
                pending_ks.len += postfix_len;
                @memcpy(
                    pending_bs[end_ofs..],
                    target.block.children[prefix_len..][0..postfix_len],
                );
                @memcpy(
                    pending_ks[end_ofs..],
                    target.block.keys[prefix_len..][0..postfix_len],
                );
            }

            //
            // copy back to the target + right blocks
            //
            const first_write_len = indx_block_keys_max - prefix_len;
            assert(pending_bs.len > first_write_len);
            @memcpy(
                target.block.keys[prefix_len..],
                pending_ks[0..first_write_len],
            );
            @memcpy(
                target.block.children[prefix_len..],
                pending_bs[0..first_write_len],
            );
            const second_write_len = pending_bs.len - first_write_len;
            assert(second_write_len > 0);
            assert(second_write_len <= target_r.?.space);
            std.mem.copyBackwards(
                IndxBlock.RawKey,
                target_r.?.block.keys[second_write_len..][0..target_r.?.len],
                target_r.?.block.keys[0..target_r.?.len],
            );
            std.mem.copyBackwards(
                IndxBlock.RawChild,
                target_r.?.block.children[second_write_len..][0..target_r.?.len],
                target_r.?.block.children[0..target_r.?.len],
            );
            @memcpy(
                target_r.?.block.keys[0..second_write_len],
                pending_ks[first_write_len..][0..second_write_len],
            );
            @memcpy(
                target_r.?.block.children[0..second_write_len],
                pending_bs[first_write_len..][0..second_write_len],
            );
            assert(first_write_len + second_write_len == pending_bs.len);

            // update subtree lengths in parent
            const size_delta = size_delta: {
                const parent = path[path_cursor - 1];
                const size = target.block.sum_subtree_sizes();
                const size_r = target_r.?.block.sum_subtree_sizes();

                var delta: SubtreeByteSize = 0;
                delta += size - parent.parent_block
                    .child_subtree_bytes(parent.key_idx);
                delta += size_r - parent.parent_block
                    .child_subtree_bytes(parent.key_idx + 1);

                parent.parent_block
                    .set_child_subtree_bytes(parent.key_idx, size);
                parent.parent_block
                    .set_child_subtree_bytes(parent.key_idx + 1, size_r);
                break :size_delta delta;
            };

            indx_block_update_len(path[0 .. path_cursor - 1], @intCast(
                size_delta,
            ));
            return if (path_clobbered) null else path;
        }

        const target_l = left: {
            assert(path_cursor > 0);
            const entry = target.entry orelse break :left null;
            const has_left = entry.key_idx > 0;
            if (!has_left) break :left null;

            const block = r.indx_blocks.at(
                entry.parent_block.child_indx_block(entry.key_idx - 1),
            );
            const len: KeysLen = block.keys_len();
            assert(len <= indx_block_keys_max);
            assert(len >= indx_block_keys_min);
            break :left .{
                .len = @as(KeysLen, len),
                .space = @as(KeyIdx, @intCast(indx_block_keys_max - len)),
                .block = block,
            };
        };

        if (target_l != null and
            target_l.?.space +
            target.space +
            (if (target_r) |r_| r_.space else 0) >= pending_bs.len)
        {
            // this + left + (right?) is enough space

            const prefix_len = path[path_cursor].key_idx;
            const postfix_len = target.len - prefix_len;

            // See assumptions in doc comment: we have two full blocks worth
            // of scratch space.
            //
            // prepend prefix to pending children
            //
            pending_bs.len += prefix_len;
            pending_ks.len += prefix_len;
            std.mem.copyBackwards(
                IndxBlock.RawChild,
                pending_bs[prefix_len..][0 .. pending_bs.len - prefix_len],
                pending_bs[0 .. pending_bs.len - prefix_len],
            );
            std.mem.copyBackwards(
                IndxBlock.RawKey,
                pending_ks[prefix_len..][0 .. pending_ks.len - prefix_len],
                pending_ks[0 .. pending_ks.len - prefix_len],
            );
            @memcpy(
                pending_bs[0..prefix_len],
                target.block.children[0..prefix_len],
            );
            @memcpy(
                pending_ks[0..prefix_len],
                target.block.keys[0..prefix_len],
            );
            //
            // append postfix to pending children
            //
            pending_bs.len += postfix_len;
            pending_ks.len += postfix_len;
            @memcpy(
                pending_bs[pending_bs.len - postfix_len ..],
                target.block.children[prefix_len..][0..postfix_len],
            );
            @memcpy(
                pending_ks[pending_ks.len - postfix_len ..],
                target.block.keys[prefix_len..][0..postfix_len],
            );

            // copy back to the left + target + right blocks
            const first_write_len = target_l.?.space;
            assert(pending_bs.len > first_write_len);
            @memcpy(
                target_l.?.block.keys[target_l.?.len..],
                pending_ks[0..first_write_len],
            );
            @memcpy(
                target_l.?.block.children[target_l.?.len..],
                pending_bs[0..first_write_len],
            );
            const second_write_len = @min(
                pending_bs.len - first_write_len,
                indx_block_keys_max,
            );
            assert(second_write_len > 0);
            @memcpy(
                target.block.keys[0..second_write_len],
                pending_ks[first_write_len..][0..second_write_len],
            );
            @memcpy(
                target.block.children[0..second_write_len],
                pending_bs[first_write_len..][0..second_write_len],
            );

            const overflow_len =
                pending_bs.len -| (first_write_len + second_write_len);
            if (overflow_len > 0) {
                assert(target_r != null);
                assert(target_r.?.space >= overflow_len);
                const r_ = target_r.?;
                std.mem.copyBackwards(
                    IndxBlock.RawKey,
                    r_.block.keys[overflow_len..][0..r_.len],
                    r_.block.keys[0..r_.len],
                );
                std.mem.copyBackwards(
                    IndxBlock.RawChild,
                    r_.block.children[overflow_len..][0..r_.len],
                    r_.block.children[0..r_.len],
                );
                const prev_writes_len = first_write_len + second_write_len;
                @memcpy(
                    r_.block.keys[0..overflow_len],
                    pending_ks[prev_writes_len..][0..overflow_len],
                );
                @memcpy(
                    r_.block.children[0..overflow_len],
                    pending_bs[prev_writes_len..][0..overflow_len],
                );
            }

            // update subtree lengths in parent
            const size_delta = size_delta: {
                const parent = path[path_cursor - 1];
                const size_l = target_l.?.block.sum_subtree_sizes();
                const size = target.block.sum_subtree_sizes();
                const size_r = if (overflow_len > 0)
                    target_r.?.block.sum_subtree_sizes()
                else
                    null;

                var delta: SubtreeByteSize = 0;
                delta += size_l - parent.parent_block
                    .child_subtree_bytes(parent.key_idx - 1);
                delta += size - parent.parent_block
                    .child_subtree_bytes(parent.key_idx);

                parent.parent_block
                    .set_child_subtree_bytes(parent.key_idx - 1, size_l);
                parent.parent_block
                    .set_child_subtree_bytes(parent.key_idx, size);

                if (overflow_len > 0) {
                    delta += size_r.? - parent.parent_block
                        .child_subtree_bytes(parent.key_idx + 1);
                    parent.parent_block
                        .set_child_subtree_bytes(parent.key_idx + 1, size_r.?);
                }
                break :size_delta delta;
            };
            indx_block_update_len(path[0 .. path_cursor - 1], @intCast(
                size_delta,
            ));

            // update path to point to the first new indx block
            const underflow_len = target_l.?.space;
            if (prefix_len < underflow_len) {
                path[path_cursor - 1].key_idx -= 1;
                path[path_cursor].parent_block = target_l.?.block;
                path[path_cursor].key_idx =
                    @intCast(target_l.?.len + prefix_len);
            } else {
                path[path_cursor].key_idx -= underflow_len;
            }
            return if (path_clobbered) null else path;
        }

        const SplitInfo = struct {
            len: KeysLen,
            space: KeyIdx,
            block: *IndxBlock,
        };
        const split_l, const split_r = if (target_l) |l| .{
            SplitInfo{
                .len = l.len,
                .space = l.space,
                .block = l.block,
            },
            SplitInfo{
                .len = target.len,
                .space = target.space,
                .block = target.block,
            },
        } else if (target_r) |r_| .{
            SplitInfo{
                .len = target.len,
                .space = target.space,
                .block = target.block,
            },
            SplitInfo{
                .len = r_.len,
                .space = r_.space,
                .block = r_.block,
            },
        } else unreachable;

        // see assumptions in doc comment: we have two full blocks worth of
        // scratch space.
        const prefix_len = path[path_cursor].key_idx;
        const postfix_len = target.len - prefix_len;

        assert(split_l.block != split_r.block);

        const rsh_amt = prefix_len +
            if (split_r.block == target.block) split_l.len else 0;
        pending_bs.len += rsh_amt;
        pending_ks.len += rsh_amt;
        std.mem.copyBackwards(
            IndxBlock.RawChild,
            pending_bs[rsh_amt..],
            pending_bs[0 .. pending_bs.len - rsh_amt],
        );
        std.mem.copyBackwards(
            IndxBlock.RawKey,
            pending_ks[rsh_amt..],
            pending_ks[0 .. pending_ks.len - rsh_amt],
        );

        const next_insert = if (split_r.block == target.block) x: {
            // Insert left into pending children
            @memcpy(
                pending_bs[0..split_l.len],
                split_l.block.children[0..split_l.len],
            );
            @memcpy(
                pending_ks[0..split_l.len],
                split_l.block.keys[0..split_l.len],
            );
            break :x split_l.len;
        } else 0;
        // Insert prefix into pending children
        @memcpy(
            pending_bs[next_insert..][0..prefix_len],
            target.block.children[0..prefix_len],
        );
        @memcpy(
            pending_ks[next_insert..][0..prefix_len],
            target.block.keys[0..prefix_len],
        );
        // Append postfix to pending children
        pending_bs.len += postfix_len;
        pending_ks.len += postfix_len;
        @memcpy(
            pending_bs[pending_bs.len - postfix_len ..],
            target.block.children[prefix_len..][0..postfix_len],
        );
        @memcpy(
            pending_ks[pending_ks.len - postfix_len ..],
            target.block.keys[prefix_len..][0..postfix_len],
        );
        if (split_l.block == target.block) {
            // Append right to pending children
            pending_bs.len += split_r.len;
            pending_ks.len += split_r.len;
            @memcpy(
                pending_bs[pending_bs.len - split_r.len ..],
                split_r.block.children[0..split_r.len],
            );
            @memcpy(
                pending_ks[pending_ks.len - split_r.len ..],
                split_r.block.keys[0..split_r.len],
            );
        }
        assert(pending_bs.len == pending_ks.len);

        const spill_len: KeyIdx = @intCast(
            pending_bs.len % indx_block_keys_min,
        );
        // group pending blocks into new parents (back into left/pending/right)
        var inserted_count: IndxBlock.Idx = 0;
        {
            // indx_block_keys_min + spill_len goes into left
            @memcpy(
                split_l.block.keys[0 .. indx_block_keys_min + spill_len],
                pending_ks[0 .. indx_block_keys_min + spill_len],
            );
            @memset(
                split_l.block.keys[indx_block_keys_min + spill_len ..],
                IndxBlock.null_key,
            );
            @memcpy(
                split_l.block.children[0 .. indx_block_keys_min + spill_len],
                pending_bs[0 .. indx_block_keys_min + spill_len],
            );
            inserted_count += indx_block_keys_min + spill_len;
        }
        // middle goes into next pending
        var new_pending_bs = std.ArrayListUnmanaged(IndxBlock.RawChild)
            .initBuffer(pending_bs);
        var new_pending_ks = std.ArrayListUnmanaged(IndxBlock.RawKey)
            .initBuffer(pending_ks);

        while (inserted_count < pending_bs.len - indx_block_keys_min) {
            const new_child = try r.indx_blocks.addOne(r.alloc);
            new_child.* = .{
                .meta = .{ .is_leaf = false },
                .keys = @splat(IndxBlock.null_key),
                .children = undefined,
            };
            @memcpy(
                new_child.keys[0..indx_block_keys_min],
                pending_ks[inserted_count..][0..indx_block_keys_min],
            );
            @memcpy(
                new_child.children[0..indx_block_keys_min],
                pending_bs[inserted_count..][0..indx_block_keys_min],
            );
            const subtree_bytes = x: {
                var len: SubtreeByteSize = 0;
                for (new_child.keys) |key| {
                    if (IndxBlock.raw_key_is_null(key)) break;
                    len += int_from_bytes(SubtreeByteSize, key);
                }
                break :x len;
            };

            // we share the same buffer but always write slower than we
            // read. So no clobbering.
            assert(inserted_count >= 1);
            new_pending_bs.appendAssumeCapacity(bytes_from_int(
                @as(IndxBlock.Idx, @intCast(r.indx_blocks.len - 1)),
            ));
            new_pending_ks.appendAssumeCapacity(bytes_from_int(subtree_bytes));

            inserted_count += indx_block_keys_min;
        }
        // exactly enough left over for right
        assert(pending_bs.len - inserted_count == indx_block_keys_min);

        // last indx_block_keys_min goes into right
        @memcpy(
            split_r.block.keys[0..indx_block_keys_min],
            pending_ks[pending_ks.len - indx_block_keys_min ..],
        );
        @memset(
            split_r.block.keys[indx_block_keys_min..],
            IndxBlock.null_key,
        );
        @memcpy(
            split_r.block.children[0..indx_block_keys_min],
            pending_bs[pending_bs.len - indx_block_keys_min ..],
        );

        pending_bs = new_pending_bs.items;
        pending_ks = new_pending_ks.items;

        assert(path_cursor >= 0);
        // set next insert target
        if (split_l.block == target.block) {
            path[path_cursor - 1].key_idx += 1;
        } else {
            assert(split_r.block == target.block);
            assert(path[path_cursor - 1].key_idx == target.entry.?.key_idx);
        }
        // path no longer points to the original leaf due to the above line.
        // Even without the above line, we don't have a reliable way to track
        // the original leaf as it may be in pending_bs and so doesn't have a
        // valid path yet as it's subtree is not yet inserted.
        path_clobbered = true;
        path_cursor -= 1;
        continue;
    }
    @panic("bug! passed max iterations");
}

fn write_data_blocks(
    r: *Rope,
    keys_buf: []IndxBlock.RawKey,
    children_buf: []IndxBlock.RawChild,
    start_idx: DataBlock.Idx,
    count: DataBlock.Idx,
) ?DataBlock.Idx {
    var next_idx: ?DataBlock.Idx = start_idx;
    for (0..count) |i| {
        const data_block = r.data_blocks.at(next_idx.?);
        keys_buf[i] = bytes_from_int(@as(
            SubtreeByteSize,
            data_block.meta.bytes,
        ));
        children_buf[i] = bytes_from_int(@as(
            DataBlock.Idx,
            next_idx.?,
        ));
        next_idx = data_block.meta.next;
    }
    return next_idx;
}

fn data_block_insert_with_bufs(
    r: *Rope,
    new_data_blocks: DataBlock.Idx,
    at: *DataBlock,
    at_idx: DataBlock.Idx,
    keys_buf: ?[]IndxBlock.RawKey,
    children_buf: ?[]IndxBlock.RawChild,
) !void {
    assert(new_data_blocks > 0);
    if (keys_buf) |b| assert(b.len == new_data_blocks);
    if (children_buf) |b| assert(b.len == new_data_blocks);

    try r.data_blocks.growCapacity(
        r.alloc,
        r.data_blocks.len + new_data_blocks,
    );

    var last_idx_p = at.meta.prev;
    for (0..new_data_blocks) |i| {
        try r.data_blocks.append(r.alloc, .{
            .meta = .{
                .bytes = data_block_bytes_min,
                .newlines = 0,
                .next = undefined,
                .prev = last_idx_p,
            },
            .bytes = undefined,
        });
        const new_block: DataBlock.Idx = @intCast(r.data_blocks.len - 1);
        if (last_idx_p) |last_idx| {
            r.data_blocks.at(last_idx).meta.next = new_block;
        }
        last_idx_p = new_block;
        if (keys_buf) |b|
            b[i] = bytes_from_int(@as(SubtreeByteSize, data_block_bytes_min));
        if (children_buf) |b|
            b[i] = bytes_from_int(@as(DataBlock.Idx, new_block));
    }
    assert(last_idx_p != null);
    r.data_blocks.at(last_idx_p.?).meta.next = at_idx;
    at.meta.prev = last_idx_p;
}

/// Insert new_data_blocks data blocks right before the datablock pointed to
/// by at.
fn data_block_insert(
    r: *Rope,
    new_data_blocks: DataBlock.Idx,
    at: *DataBlock,
    at_idx: DataBlock.Idx,
) !void {
    try data_block_insert_with_bufs(r, new_data_blocks, at, at_idx, null, null);
}

// /// Insert new_data_blocks data blocks right before the datablock pointed to
// /// by the given path.
// fn insert_data_blocks(
//     r: *Rope,
//     path: []IndxBlockPathEntry,
//     new_data_blocks: DataBlockIdx,
// ) void {
//     assert(new_data_blocks > 0);
//     assert(path.len > 0);
//     {
//         const last = path[path.len - 1];
//         assert(last.key_idx != IndxBlock.null_key);
//         const leaf_idx_raw = last.block.children[last.key_idx];
//         const leaf_idx = int_from_bytes(IndxBlock.Idx, leaf_idx_raw);
//         const leaf = r.data_blocks.at(leaf_idx);
//         assert(leaf.meta.is_leaf);
//     }
//     assert(path[0].block == r.indx_blocks.at(r.indx_root.to_idx().?));
//
//     var plan: [indx_blocks_height_max]struct {
//         action: union(enum) {
//             redist_right,
//             redist_right_left,
//             split: struct {
//                 at_key_idx: KeyIdx,
//                 new_indx_blocks: IndxBlock.Idx,
//             },
//             new_parent_layer: struct {
//                 new_indx_blocks: IndxBlock.Idx,
//             },
//         },
//         result: ?IndxBlockPathEntry,
//     } = undefined;
//
//     // STEP 1: propagate the need for actions up from the leaves.
//
//     var new_ib_count: u64 = new_data_blocks;
//     var i: IndxBlock.Idx = path.len - 1;
//     var j: IndxBlock.Idx = plan.len - 1;
//     while (new_ib_count > 0) {
//         i -= 1;
//         j -= 1;
//     }

// STEP 2: execute the actions top-down.

// for (0..path.len) |i_rev| {
//     const i = path.len - i_rev - 1;
//     // const
//
//     const this_block = path[i].block;
//     const left_block = path[i-1].block.keys
//
//     const avail_keys = indx_block_keys_max - path[i].block.keys_len();
//
//     new_ib_count =
//         (new_ib_count + indx_block_keys_min - 1) /
//         indx_block_keys_min;
//     plan[i].new_indx_blocks = new_ib_count;
// }
// }

/// Copy src to dst. Must not overlap and much be of equal length.
inline fn data_block_cpy(
    dst: DataBlock.Slice,
    src: DataBlock.Slice,
) void {
    assert(dst.len == src.len);
    assert(dst.len <= data_block_bytes_max);
    const m = if (dst.len == data_block_bytes_max)
        std.math.boolMask(u128, false)
    else
        ~(std.math.boolMask(u128, true) << @intCast(dst.len));

    const dst_mask = m << dst.ofs;
    const src_mask = m << src.ofs;

    dst.block.meta.newlines &= ~dst_mask;

    if (dst.ofs > src.ofs) {
        dst.block.meta.newlines |=
            (src.block.meta.newlines & src_mask) << (dst.ofs - src.ofs);
    } else {
        dst.block.meta.newlines |=
            (src.block.meta.newlines & src_mask) >> (src.ofs - dst.ofs);
    }

    @memcpy(
        dst.block.bytes[dst.ofs..][0..src.len],
        src.block.bytes[src.ofs..][0..src.len],
    );
}

fn data_block_set_bytes(db: *DataBlock, ofs: u7, bytes: []const u8) void {
    assert(ofs + bytes.len <= db.meta.bytes);

    var newlines: u128 = 0;
    for (bytes) |byte| {
        newlines <<= 1;
        newlines |= if (byte == '\n') 1 else 0;
    }
    const mask =
        ~(std.math.boolMask(u128, true) << @intCast(ofs)) |
        (if (ofs + bytes.len == db.meta.bytes)
        0
    else
        (std.math.boolMask(u128, true) << @intCast(ofs + bytes.len)));

    db.meta.newlines = (mask & db.meta.newlines) | (newlines << ofs);

    @memcpy(
        db.bytes[ofs..][0..bytes.len],
        bytes,
    );
}

fn data_block_set_bytes_long(
    r: *Rope,
    dst: DataBlock.LongSlice,
    _bytes: []const u8,
) ByteIdx {
    var bytes = _bytes;
    assert(dst.len == bytes.len);
    assert(dst.start_ofs <= dst.start_block.meta.bytes);

    const Cursor = struct {
        block: ?*DataBlock,
        ofs: u7,
    };
    var cur_dst: Cursor = .{
        .block = dst.start_block,
        .ofs = dst.start_ofs,
    };
    while (bytes.len > 0) {
        if (cur_dst.block == null) break;

        const cpy_len = @min(
            bytes.len,
            cur_dst.block.?.meta.bytes - cur_dst.ofs,
        );
        assert(cpy_len > 0);

        data_block_set_bytes(
            cur_dst.block.?,
            cur_dst.ofs,
            bytes[0..cpy_len],
        );

        // advance our cursor. null next blocks validated on next loop.
        assert(cur_dst.ofs + cpy_len <= cur_dst.block.?.meta.bytes);
        if (cur_dst.ofs + cpy_len == cur_dst.block.?.meta.bytes) {
            cur_dst.block = if (cur_dst.block.?.meta.next) |next|
                r.data_blocks.at(next)
            else
                null;
            cur_dst.ofs = 0;
        } else {
            cur_dst.ofs += @intCast(cpy_len);
        }

        bytes = bytes[cpy_len..];
    }
    return @intCast(_bytes.len - bytes.len);
}

/// Copy src to dst. Slices may span multiple blocks.
/// Only overwrites in existing space. Does not modify block lens.
///
/// Individual chunk copy operations must not overlap.
fn data_block_cpy_long(
    dst: DataBlock.LongSlice,
    src: DataBlock.LongSlice,
) void {
    assert(dst.len == src.len);
    assert(src.start_ofs <= src.start_block.meta.bytes);
    assert(dst.start_ofs <= dst.start_block.meta.bytes);
    var rest = src.len;
    const Cursor = struct {
        block: ?*DataBlock,
        ofs: u7,
    };
    var cur_src: Cursor = .{
        .block = src.start_block,
        .ofs = src.start_ofs,
    };
    var cur_dst: Cursor = .{
        .block = dst.start_block,
        .ofs = dst.start_ofs,
    };
    while (rest > 0) {
        if (cur_src.block == null) @panic("src slice len out of bounds");
        if (cur_dst.block == null) @panic("dst slice len out of bounds");

        assert(cur_src.ofs < cur_src.block.meta.bytes);
        assert(cur_dst.ofs < cur_dst.block.meta.bytes);

        const cpy_len = @min(
            rest,
            cur_dst.block.meta.bytes - cur_dst.ofs,
            cur_src.block.meta.bytes - cur_src.ofs,
        );
        assert(cpy_len > 0);

        data_block_cpy(
            cur_dst.block.slice(cur_dst.ofs, cpy_len),
            cur_src.block.slice(cur_src.ofs, cpy_len),
        );

        // advance our cursors. null next blocks validated on next loop.
        assert(cur_src.ofs + cpy_len <= cur_src.block.meta.bytes);
        if (cur_src.ofs + cpy_len == cur_src.block.meta.bytes) {
            cur_src.block = cur_src.block.meta.next;
            cur_src.ofs = 0;
        } else {
            cur_src.ofs += cpy_len;
        }

        assert(cur_dst.ofs + cpy_len <= cur_dst.block.meta.bytes);
        if (cur_dst.ofs + cpy_len == cur_dst.block.meta.bytes) {
            cur_dst.block = cur_dst.block.meta.next;
            cur_dst.ofs = 0;
        } else {
            cur_dst.ofs += cpy_len;
        }

        rest -= cpy_len;
    }
}

/// Shift the bytes in db by amt bytes to the left.
inline fn data_block_shl(db: *DataBlock, ofs: u8, amt: u8) void {
    if (ofs == 0 or amt == 0) return;
    if (amt >= data_block_bytes_max) {
        return data_block_clear(db);
    }

    const mask = if (ofs >= db.meta.bytes)
        std.math.boolMask(u128, false)
    else
        std.math.boolMask(u128, true) << @intCast(ofs);
    // NOTE: data shl == significant-least shift = bitmap shr
    db.meta.newlines =
        (db.meta.newlines & mask) |
        if (amt >= ofs) 0 else ((db.meta.newlines & ~mask) >> @intCast(amt));

    // amt < ofs:
    // something...
    // ome_thing...
    //     ^ofs
    // ^^^prefix
    //
    // amt >= ofs:
    // something...
    // ____thing...
    //     ^ofs
    // no prefix

    const prefix_len = ofs -| amt;
    // slices may overlap, shift left means dst <= src
    std.mem.copyForwards(
        u8,
        db.bytes[0..prefix_len],
        db.bytes[amt..][0..prefix_len],
    );
    @memset(
        db.bytes[prefix_len..][0..@min(amt, ofs)],
        undefined,
    );
}

/// Set bytes to undefined without changing the length.
inline fn data_block_clear(db: *DataBlock) void {
    db.meta.newlines = 0;
    db.bytes = undefined;
}

/// Shift the bytes in db by amt bytes to the right.
inline fn data_block_shr(db: *DataBlock, ofs: u7, _amt: u8) void {
    if (_amt >= data_block_bytes_max) {
        return data_block_clear(db);
    }
    const amt: u7 = @intCast(_amt);

    const mask = std.math.boolMask(u128, true) << ofs;
    // NOTE: data shr == significant-most shift = bitmap shl
    db.meta.newlines =
        (db.meta.newlines & ~mask) |
        ((db.meta.newlines & mask) << amt);

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

    const postfix_len: u7 = @intCast(
        (data_block_bytes_max - @as(u8, ofs)) -| amt,
    );
    // slices may overlap, shift right means dst >= src
    std.mem.copyBackwards(
        u8,
        db.bytes[ofs +| amt..][0..postfix_len],
        db.bytes[ofs..][0..postfix_len],
    );
    @memset(
        db.bytes[ofs..][0..@min(
            amt,
            data_block_bytes_max - @as(u8, ofs),
        )],
        undefined,
    );
}

inline fn indx_block_shr(ib: *IndxBlock, ofs: KeyIdx, amt: KeysLen) void {
    const postfix_len = (indx_block_keys_max - ofs) -| amt;

    // slices may overlap, shift right means dst >= src
    std.mem.copyBackwards(
        IndxBlock.RawKey,
        ib.keys[ofs +| amt..][0..postfix_len],
        ib.keys[ofs..][0..postfix_len],
    );
    @memset(
        ib.keys[ofs..][0..@min(amt, indx_block_keys_max - ofs)],
        undefined,
    );
}

/// Update the parents of the given leaf block of the path to reflect the
/// new length of the leaf block.
fn indx_block_update_len(
    path: []BlockPathEntry,
    len_delta: ByteIdxDelta,
) void {
    if (len_delta == 0) return;

    for (path) |entry| {
        const old_len =
            int_from_bytes(
            SubtreeByteSize,
            entry.parent_block.keys[entry.key_idx],
        );
        entry.parent_block.keys[entry.key_idx] = bytes_from_int(@as(
            SubtreeByteSize,
            @intCast(@as(ByteIdxDelta, @intCast(old_len)) +
                len_delta),
        ));

        // Path shouldn't contain the leaf
        assert(!entry.parent_block.meta.is_leaf);
    }
}

/// Iter backward from the start to the end, setting the children of the index
/// block to the visited data blocks.
///
/// Returns the index of the `prev` of the last data block visited.
fn indx_block_leaf_set_children_backwards(
    r: *Rope,
    block: *IndxBlock,
    key_idx_start: KeyIdx,
    data_blocks_idx_start: DataBlock.Idx,
    count: KeyIdx,
) ?DataBlock.Idx {
    var next_idx_back: ?DataBlock.Idx = data_blocks_idx_start;
    for (0..count) |i_rev| {
        const key_idx: u8 = key_idx_start - i_rev;

        assert(next_idx_back != null);
        const data_block = r.data_blocks.at(next_idx_back.?);

        assert(data_block.meta.bytes >= data_block_bytes_min);
        block.set_child_subtree_bytes(key_idx, data_block_bytes_min);
        block.set_child_data_block(key_idx, data_block);

        next_idx_back = data_block.meta.prev;
    }
    return next_idx_back;
}

// for reading/writing but no tree mutations. i.e. no (de)alloc of bytes.
pub const Stream = struct {
    r: *Rope,
    cursor: Cursor = undefined,

    const Cursor = struct {
        block: *DataBlock,
        ofs: u8,
        pos: ByteIdx,
    };

    pub const ReadError = error{};
    pub const WriteError = error{};

    pub const Writer = std.io.Writer(*@This(), WriteError, write);
    pub const Reader = std.io.Reader(*@This(), ReadError, read);

    pub fn reader(s: *@This()) Reader {
        return .{ .context = s };
    }
    pub fn writer(s: *@This()) Writer {
        return .{ .context = s };
    }

    pub fn read(s: *@This(), _dst: []u8) ReadError!usize {
        assert(s.cursor.ofs <= s.cursor.block.meta.bytes);
        var dst = _dst;

        var i: usize = 0;
        while (dst.len > 0) : (i += 1) {
            if (i >= data_blocks_max)
                @panic("reached max iterations. probably a bug.");

            const cpy_len = @min(
                dst.len,
                s.cursor.block.meta.bytes - s.cursor.ofs,
            );
            @memcpy(
                dst[0..cpy_len],
                s.cursor.block.bytes[s.cursor.ofs..][0..cpy_len],
            );
            dst = dst[cpy_len..];
            s.cursor.ofs += cpy_len;
            s.cursor.pos += cpy_len;

            assert(s.cursor.ofs <= s.cursor.block.meta.bytes);
            if (s.cursor.ofs == s.cursor.block.meta.bytes) {
                s.cursor.block = s.r.data_blocks.at(
                    s.cursor.block.meta.next orelse break,
                );
                s.cursor.ofs = 0;
            }
        }

        const bytes_read: ByteIdx = @intCast(_dst.len - dst.len);
        return bytes_read;
    }

    pub fn write(s: *@This(), _src: []const u8) WriteError!usize {
        assert(s.cursor.ofs <= s.cursor.block.meta.bytes);
        var src = _src;

        var i: usize = 0;
        while (src.len > 0) : (i += 1) {
            if (i >= data_blocks_max)
                @panic("reached max iterations. probably a bug.");

            const cpy_len = @min(
                src.len,
                s.cursor.block.meta.bytes - s.cursor.ofs,
            );
            data_block_set_bytes(
                s.cursor.block,
                @intCast(s.cursor.ofs),
                src[0..cpy_len],
            );
            src = src[cpy_len..];
            s.cursor.ofs += cpy_len;
            s.cursor.pos += cpy_len;

            assert(s.cursor.ofs <= s.cursor.block.meta.bytes);
            if (s.cursor.ofs == s.cursor.block.meta.bytes) {
                s.cursor.block = s.r.data_blocks.at(
                    s.cursor.block.meta.next orelse break,
                );
                s.cursor.ofs = 0;
            }
        }
        const written = _src.len - src.len;
        assert(written > 0);
        return written;
    }

    pub fn get_pos(s: *@This()) ByteIdx {
        return s.cursor.pos;
    }

    pub fn get_end_pos(s: *@This()) ByteIdx {
        return s.r.indx_root.sum_subtree_sizes();
    }

    pub fn seek_to(s: *@This(), pos: ByteIdx) void {
        // TODO: make path output optional
        var path_store: [indx_blocks_height_max]BlockPathEntry = undefined;
        const res = s.r.find_data_block(s.r.indx_root, pos, &path_store);
        const block = s.r.data_blocks.at(
            res.path[res.path.len - 1].parent_block.child_data_block(
                res.path[res.path.len - 1].key_idx,
            ),
        );
        s.cursor = .{
            .block = block,
            .ofs = @intCast(pos - res.block_ofs),
            .pos = pos,
        };
    }

    pub fn seek_by(s: *@This(), delta: ByteIdxDelta) void {
        const slice = s.cursor.block.slice_long(delta, 0);
        s.cursor = .{
            .block = slice.start_block,
            .ofs = slice.start_ofs,
            .pos = @intCast(@as(ByteIdxDelta, s.cursor.pos) + delta),
        };
    }
};

pub fn stream(r: *Rope, initial_pos: ByteIdx) Stream {
    var res: Stream = .{ .r = r };
    res.seek_to(initial_pos);
    return res;
}

// pub fn set_region(r: *Rope, start: ByteIdx, end: ByteIdx, text: []const u8) !void {}
pub fn insert(r: *Rope, ofs: ByteIdx, text: []const u8) !void {
    var rest: ByteIdx = @intCast(text.len);
    var i: usize = 0;
    while (rest > 0) : (i += 1) {
        if (i >= 100) @panic("reached max iterations. probably a bug.");

        const res = try r.alloc_at(ofs, rest);
        rest -= res.alloc_len;
    }
    var s = r.stream(ofs);
    s.writer().writeAll(text) catch unreachable;
}

pub fn get_len(r: *Rope) ByteIdx {
    return r.indx_root.sum_subtree_sizes();
}

pub fn format(
    r: *Rope,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var s = r.stream(0);
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i >= 100) @panic("reached max iterations. probably a bug.");

        var buf: [100]u8 = undefined;
        const len = s.reader().readAll(&buf) catch unreachable;
        try std.fmt.format(writer, "{s}", .{buf[0..len]});
        if (len < buf.len) break;
    }
}

const ValidBlockResult = struct {
    subtree_bytes: SubtreeByteSize,
    last_db_idx: DataBlock.Idx,
};
fn assert_valid_indx_block(
    r: *Rope,
    block: *IndxBlock,
    depth: u8,
    prev_db_idx: ?DataBlock.Idx,
) ValidBlockResult {
    assert(depth <= indx_blocks_height_max);

    // root
    if (depth == 0) {
        if (block.meta.is_leaf) {
            assert(!IndxBlock.raw_key_is_null(block.keys[0]));
            assert(!IndxBlock.raw_key_is_null(block.keys[1]));
            const keys_len = block.keys_len();
            assert(keys_len >= 2);
            assert(keys_len <= indx_block_keys_max);
        }
    }

    var last_db_idx = prev_db_idx;
    for (block.keys, 0..) |key, i| {
        if (IndxBlock.raw_key_is_null(key)) break;
        assert(i < indx_block_keys_max);

        const res = if (block.meta.is_leaf) x: {
            const db_idx = block.child_data_block(@intCast(i));
            break :x ValidBlockResult{
                .last_db_idx = db_idx,
                .subtree_bytes = r.assert_valid_data_block(
                    r.data_blocks.at(db_idx),
                    depth + 1,
                    last_db_idx,
                ),
            };
        } else r.assert_valid_indx_block(
            r.indx_blocks.at(block.child_indx_block(@intCast(i))),
            depth + 1,
            last_db_idx,
        );
        assert(res.subtree_bytes == block.child_subtree_bytes(@intCast(i)));
        last_db_idx = res.last_db_idx;
    }

    return .{
        .subtree_bytes = block.sum_subtree_sizes(),
        .last_db_idx = last_db_idx.?,
    };
}

fn assert_valid_data_block(
    r: *Rope,
    block: *DataBlock,
    depth: u8,
    prev_db_idx: ?DataBlock.Idx,
) SubtreeByteSize {
    assert(depth > 0);
    assert(depth <= indx_blocks_height_max + 1);

    if (depth > 1) {
        assert(block.meta.bytes >= data_block_bytes_min);
    }
    assert(block.meta.prev == prev_db_idx);
    if (prev_db_idx) |p| assert(
        r.data_blocks.at(r.data_blocks.at(p).meta.next.?) == block,
    );
    return block.meta.bytes;
}

fn assert_valid(r: *Rope) void {
    const res = r.assert_valid_indx_block(r.indx_root, 0, null);

    var path_store: [indx_blocks_height_max]BlockPathEntry = undefined;
    const head = r.find_data_block(r.indx_root, 0, &path_store);
    assert(head.block_ofs == 0);
    const head_entry = head.path[head.path.len - 1];
    assert(head_entry.key_idx == 0);
    const head_db_idx = head_entry.parent_block.child_data_block(
        head_entry.key_idx,
    );

    var total_bytes: ByteIdx = 0;
    var cur_db_idx = head_db_idx;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i >= data_blocks_max) @panic("reached max iterations. probably a bug.");
        const db = r.data_blocks.at(cur_db_idx);
        total_bytes += db.meta.bytes;
        cur_db_idx = db.meta.next orelse break;
    }
    assert(total_bytes == res.subtree_bytes);
}

test insert {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.insert(0, "hello world");
    try std.testing.expectFmt("hello world", "{}", .{&rope});
}

test "insert-fuzz" {
    // makes for easier print debugging
    const gen_ascii = true;

    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    var str = std.ArrayList(u8).init(std.testing.allocator);

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();

    var buf: [1024 * 1024]u8 = undefined;

    for (64..buf.len + 1) |max_len| {
        for (0..100) |_| {
            const pos = rand.uintAtMost(ByteIdx, rope.get_len());
            const text = buf[0..rand.uintLessThan(usize, max_len)];
            if (gen_ascii) {
                for (text) |*c| c.* = rand.uintLessThan(u8, 'z' - 'a') + 'a';
            } else {
                rand.bytes(text);
            }
            std.debug.print("pos: {d}, text: `{s}`\n", .{ pos, text });
            try rope.insert(pos, text);
            try str.insertSlice(pos, text);
            rope.assert_valid();
            std.debug.print("len: {d}, rope: `{}`\n", .{
                rope.get_len(),
                &rope,
            });
            try std.testing.expectFmt(str.items, "{}", .{&rope});
        }
    }
}

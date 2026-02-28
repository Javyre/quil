const std = @import("std");
const assert = std.debug.assert;
const SegmentedList = @import("segmented_list.zig").SegmentedList;
const RangedInt = @import("ranged_int.zig").RangedInt;
const log = @import("./log.zig").scoped(.segmented_pool);

const Allocator = std.mem.Allocator;

const is_debug = @import("builtin").mode == .Debug;

pub fn SegmentedPool(
    comptime Item: type,
    comptime Num: type,
    comptime prealloc_item_count: Num,
) type {
    return struct {
        const Pool = @This();

        comptime {
            // Can't change alignment of SegmentedList so we just assert this
            // instead of @max-ing like in std.heap.MemoryPool.
            assert(@sizeOf(Node) <= @sizeOf(Item));
            assert(@alignOf(*anyopaque) <= @alignOf(Item));
        }

        const Node = struct {
            next: ?Num = null,
        };
        const NodePtr = *align(@alignOf(Item)) Node;

        segm_list: SegmentedList(Item, prealloc_item_count.to_int()) = .{},
        free_list: ?Num = null,
        // For leak detection
        len: if (is_debug) Num else void = if (is_debug) Num.coerce(0) else {},

        pub const empty: Pool = .{};

        pub fn deinit(pool: *Pool, alloc: std.mem.Allocator) void {
            if ((comptime is_debug) and !pool.len.eql(.coerce(0)))
                log.debug(@src(), "Pool leaked items", .{ .items = pool.len });
            pool.segm_list.deinit(alloc);
            pool.* = undefined;
        }

        pub const ItemPair = struct {
            ptr: *Item,
            num: Num,
        };

        pub fn create(pool: *Pool, alloc: std.mem.Allocator) Allocator.Error!ItemPair {
            if (pool.free_list) |num| {
                const item: *Item = pool.segm_list.at(num.to_int());
                const node: NodePtr = @ptrCast(item);
                pool.free_list = node.next;
                item.* = undefined;
                if (is_debug)
                    pool.len = pool.len.add(.coerce(1));
                return .{
                    .ptr = item,
                    .num = num,
                };
            }

            const num: Num = Num.try_cast(pool.segm_list.len) catch
                return error.OutOfMemory;
            const item: *Item = try pool.segm_list.addOne(alloc);
            if (is_debug)
                pool.len = pool.len.add(.coerce(1));
            return .{
                .ptr = item,
                .num = num,
            };
        }

        pub fn destroy(pool: *Pool, num: Num) void {
            const item: *Item = pool.segm_list.at(num.to_int());
            item.* = undefined;
            const node: NodePtr = @ptrCast(item);
            node.* = .{ .next = pool.free_list };
            pool.free_list = num;
            if (is_debug)
                pool.len = pool.len.sub(.coerce(1));
        }

        pub fn at(
            pool: anytype,
            num: Num,
        ) @TypeOf(pool.segm_list.at(num.to_int())) {
            return pool.segm_list.at(num.to_int());
        }
    };
}

test "basic" {
    const gpa = std.testing.allocator;
    var pool: SegmentedPool(u64, RangedInt(.foo, 0, 4), .coerce(4)) = .{};
    defer pool.deinit(gpa);

    const p1 = try pool.create(gpa);
    const p2 = try pool.create(gpa);
    const p3 = try pool.create(gpa);

    // Assert uniqueness
    try std.testing.expect(!std.meta.eql(p1, p2));
    try std.testing.expect(!std.meta.eql(p1, p3));
    try std.testing.expect(!std.meta.eql(p2, p3));

    pool.destroy(p2.num);
    const p4 = try pool.create(gpa);

    // Assert memory reuse
    try std.testing.expect(std.meta.eql(p2, p4));
}

const std = @import("std");

// TODO: consider using a HashMap with Context+Adapters for indexing into the
// underlying multiarraylist
pub fn MultiArrayPool(comptime T: type) type {
    return struct {
        pool: std.MultiArrayList(T),

        const Pool = @This();

        pub const empty: Pool = .{ .pool = .empty };

        pub const Idx = enum(u16) {
            null = std.math.maxInt(u16),
            _,

            pub fn to_idx(num: Idx) ?u16 {
                if (num == .null) return null;
                return @intFromEnum(num);
            }
        };

        pub fn deinit(pool: *Pool, alloc: std.mem.Allocator) void {
            pool.pool.deinit(alloc);
            pool.* = undefined;
        }

        pub fn create(pool: *Pool, alloc: std.mem.Allocator, el: T) !Idx {
            const num: Idx = @enumFromInt(pool.pool.len);
            if (num == .null)
                return error.OutOfMemory;

            try pool.pool.append(alloc, el);
            return num;
        }

        pub fn destroy(pool: *Pool, alloc: std.mem.Allocator) void {
            // TODO: destroy
            _ = pool;
            _ = alloc;
        }

        /// WARN: iteration on this slice is currently undefined
        pub fn slice(pool: *Pool) @TypeOf(pool.pool).Slice {
            return pool.pool.slice();
        }
    };
}

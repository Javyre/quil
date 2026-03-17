const std = @import("std");

const assert = std.debug.assert;

pub const ByteParts = struct {
    a: []const u8,
    b: []const u8,

    pub const empty: ByteParts = .{ .a = &.{}, .b = &.{} };

    pub fn len(parts: ByteParts) usize {
        return parts.a.len + parts.b.len;
    }

    pub fn first(parts: ByteParts) u8 {
        assert(parts.len() != 0);
        if (parts.a.len != 0) return parts.a[0];
        return parts.b[0];
    }

    pub fn flatten(parts: ByteParts, dst: []u8) []const u8 {
        const part_len = parts.len();
        assert(part_len <= dst.len);
        @memcpy(dst[0..parts.a.len], parts.a);
        @memcpy(dst[parts.a.len..][0..parts.b.len], parts.b);
        return dst[0..part_len];
    }
};

pub fn ByteRing(comptime cap: u16) type {
    comptime assert(cap > 0);

    return struct {
        head: u16,
        len: u16,
        buf: [cap]u8,

        const Ring = @This();

        pub const empty: Ring = .{
            .head = 0,
            .len = 0,
            .buf = undefined,
        };

        pub fn clear(ring: *Ring) void {
            ring.head = 0;
            ring.len = 0;
        }

        pub fn free(ring: *const Ring) u16 {
            return cap - ring.len;
        }

        pub fn parts(ring: *const Ring) ByteParts {
            return ring.span(0, ring.len);
        }

        pub fn span(ring: *const Ring, start: u16, end: u16) ByteParts {
            assert(start <= end);
            assert(end <= ring.len);
            if (start == end) return .empty;

            const abs_start = (ring.head + start) % cap;
            const span_len = end - start;
            const first_len: u16 = @min(span_len, cap - abs_start);
            const second_len = span_len - first_len;
            return .{
                .a = ring.buf[abs_start..][0..first_len],
                .b = ring.buf[0..second_len],
            };
        }

        pub fn push(ring: *Ring, byte: u8) void {
            assert(ring.free() != 0);
            const tail = (ring.head + ring.len) % cap;
            ring.buf[tail] = byte;
            ring.len += 1;
        }

        pub fn push_slice(ring: *Ring, bytes: []const u8) error{NoSpaceLeft}!void {
            if (bytes.len > ring.free()) return error.NoSpaceLeft;
            for (bytes) |byte| ring.push(byte);
        }

        pub fn pop_front(ring: *Ring, n: u16) void {
            assert(n <= ring.len);
            if (n == ring.len) {
                ring.clear();
                return;
            }
            ring.head = (ring.head + n) % cap;
            ring.len -= n;
        }
    };
}

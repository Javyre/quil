const std = @import("std");
const uucode = @import("uucode");
const MultiArrayPool = @import("./multi_array_pool.zig").MultiArrayPool;
const EgcPool = @import("./EGCPool.zig");
const stdx = @import("./stdx.zig");

const assert = std.debug.assert;

const Render = @This();

io: std.Io,
alloc: std.mem.Allocator,

is_alive: bool = false,
stdin: std.Io.File = undefined,
stdout: std.Io.File = undefined,

egc_pool: EgcPool = .empty,
grids: Grids = .empty,
surfaces: Surfaces = .empty,
surfaces_dirty: bool = false,
flush_overdraw_bm: std.ArrayList(BitMap.Word) = .empty,
flush_requdraw_bm: std.ArrayList(BitMap.Word) = .empty,
flush_grid: GridNum = .null,
stack: std.ArrayList(u16) = .empty,

// TODO: support terminal fg color? (i.e. not using white but rather fg=0)
// TODO: support terminal predefined colors?
const Color = packed struct {
    default_: bool = false,
    _pad: u7 = 0,
    r: u8,
    g: u8,
    b: u8,

    pub const default: Color = .{ .default_ = true, .r = 0, .g = 0, .b = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{
        .r = std.math.maxInt(u8),
        .g = std.math.maxInt(u8),
        .b = std.math.maxInt(u8),
    };
};

pub const Dimensions = struct {
    w: u16,
    h: u16,
    pub const zero: Dimensions = .{ .w = 0, .h = 0 };
    pub fn to_vec(dims: Dimensions) @Vector(2, u16) {
        return .{ dims.w, dims.h };
    }
};
pub const Position = struct {
    x: u16,
    y: u16,
    pub const origin: Position = .{ .x = 0, .y = 0 };
    pub fn to_vec(pos: Position) @Vector(2, u16) {
        return .{ pos.x, pos.y };
    }

    pub fn from_cell_idx(dims: Dimensions, idx: usize) Position {
        std.debug.assert(idx < dims.x * dims.y);
        return .{
            .x = idx % dims.w,
            .y = idx / dims.w,
        };
    }

    pub fn add(pos: Position, other: Position) Position {
        return .{
            .x = pos.x + other.x,
            .y = pos.y + other.y,
        };
    }
};

pub const Rectangle = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pub fn from_pos_dims(pos: Position, dims: Dimensions) Rectangle {
        return .{
            .x = pos.x,
            .y = pos.y,
            .w = dims.w,
            .h = dims.h,
        };
    }
    pub fn to_pos_dims(r: Rectangle) struct { @"0": Position, @"1": Dimensions } {
        return .{
            .{ .x = r.x, .y = r.y },
            .{ .w = r.w, .h = r.h },
        };
    }
};

const Grids = MultiArrayPool(Grid);
pub const GridNum = Grids.Idx;

/// A Grid of Cells.
///
/// Think of a texture in GL terms.
/// This should be treated as the storage used for Surfaces.
const Grid = struct {
    dims: Dimensions,

    // NOTE: all these 2D arrays are the same dimensions at all times.

    /// if == 0        : empty or making room for some wide previous cell.
    /// if in [32, 126]: ASCII char.
    /// if  > 127      : idx+128 to ECG pool.
    cell_char: std.ArrayList(u16),
    cell_bg: std.ArrayList(Color),
    cell_fg: std.ArrayList(Color),

    pub const empty: Grid = .{
        .dims = .zero,
        .cell_char = .empty,
        .cell_bg = .empty,
        .cell_fg = .empty,
    };
};

const Surfaces = MultiArrayPool(Surface);
pub const SurfaceNum = Surfaces.Idx;

/// A Clipped and Wrapping Portion of a Grid.
///
/// Think of a viewport in GL terms.
/// This should be treated as surfaces to render on and composit together.
const Surface = struct {
    label: ?[]const u8 = null,

    parent_surface: SurfaceNum = .null,
    /// Whether we need to rerender this surface on the next flush.
    dirt: Dirt = .clean,
    /// Position on the screen
    /// TODO: Relative offset to parent if parent not null.
    screen_pos: Position = .origin,
    /// Size of the surface.
    /// This is the portion of the grid that will be used.
    dims: Dimensions = .zero,

    // For updating E to invalidate the previously rendered cells:
    flush_prev_screen_pos: Position = .origin,
    flush_prev_dims: Dimensions = .zero,

    /// Bitmap of dirty cells.
    cell_dirt: std.ArrayList(BitMap.Word) = .empty,
    /// Backing grid. surfaces can share larger backing grids.
    grid: GridNum = .null,
    /// Position on the backing grid.
    grid_pos: Position = .origin,
    /// Offset applied to grid_pos. Overflows wrap around our grid portion.
    wrapping_ofs: Position = .origin,

    default_fg: Color = .white,
    default_bg: Color = .default,

    pub const Dirt = enum(u2) {
        /// Need a full redraw of the surface.
        full,
        /// Refer to cell_dirt to redraw only cells marked dirty.
        partial,
        /// No need for redraw.
        clean,
    };
};

/// Bitmap is a []u8 with native endianness and least significant bit first.
/// Compatible with std.mem.(read|write)PackedIntNative
///
/// TODO: optimization: have a small buffer of rects and keep the largest ones.
///       The rest can be baked into the actual bitmap
const BitMap = struct {
    const Word = u128;

    const View = struct {
        bm: []Word,
        bm_dims: Dimensions,
        vp_ofs: Position = .origin,
        vp_dims: Dimensions = .zero,

        pub fn entire(bm: []Word, bm_dims: Dimensions) View {
            return .{
                .bm = bm,
                .bm_dims = bm_dims,
                .vp_ofs = .origin,
                .vp_dims = bm_dims,
            };
        }

        pub fn subview(view: View, vp_ofs: Position, vp_dims: Dimensions) View {
            const ret = View{
                .bm = view.bm,
                .bm_dims = view.bm_dims,
                .vp_ofs = .{
                    .x = view.vp_ofs.x + vp_ofs.x,
                    .y = view.vp_ofs.y + vp_ofs.y,
                },
                .vp_dims = vp_dims,
            };
            ret.assert_valid();
            return ret;
        }

        pub fn assert_valid(view: View) void {
            const cell_count = view.bm_dims.w * view.bm_dims.h;
            std.debug.assert(view.bm.len == (cell_count + @bitSizeOf(Word) - 1) / @bitSizeOf(Word));

            std.debug.assert(view.vp_ofs.x <= view.bm_dims.w);
            std.debug.assert(view.vp_ofs.y <= view.bm_dims.h);
            std.debug.assert(view.vp_ofs.x + view.vp_dims.w <= view.bm_dims.w);
            std.debug.assert(view.vp_ofs.y + view.vp_dims.h <= view.bm_dims.h);
        }

        pub fn assign_or(view: View, other: View) void {
            combine_views(2, &.{ view, other }, view, struct {
                pub inline fn combine(
                    views: [2]Word,
                ) Word {
                    const A_vec = views[0];
                    const B_vec = views[1];
                    return A_vec | B_vec;
                }
            }.combine);
        }

        pub fn set_rect(view: View, rect: Rectangle, comptime val: u1) void {
            view.assert_valid();
            std.debug.assert(rect.x <= view.bm_dims.w);
            std.debug.assert(rect.y <= view.bm_dims.h);
            std.debug.assert(rect.x + rect.w <= view.bm_dims.w);
            std.debug.assert(rect.y + rect.h <= view.bm_dims.h);

            if (rect.w == 0 or rect.h == 0) return;

            for (rect.y..rect.y + rect.h) |rect_y| {
                const x = view.vp_ofs.x + rect.x;
                const y = view.vp_ofs.y + rect_y;
                const base_bit_ofs = y * view.bm_dims.w + x;
                set_bits(std.mem.sliceAsBytes(view.bm), base_bit_ofs, rect.w, val, native_endian);
            }
        }

        /// Returns the viewport x coord of the next set bit, or null if there
        /// are no more set bits in the row.
        ///
        /// `start_x` scans the half-open range `[start_x, view.vp_dims.w)`.
        /// Passing `start_x == view.vp_dims.w` is valid and signals the end of
        /// iteration for that row.
        pub fn find_next_set_in_row(view: View, start_x: u16, row_y: u16) ?struct {
            x: u16,
            count: u16,
        } {
            view.assert_valid();
            std.debug.assert(row_y < view.vp_dims.h);
            std.debug.assert(start_x <= view.vp_dims.w);
            if (start_x == view.vp_dims.w) return null;

            const y = view.vp_ofs.y + row_y;
            const x = view.vp_ofs.x;
            const base_bit_ofs = y * view.bm_dims.w + x + start_x;
            const bit_len = view.vp_dims.w - start_x;

            return if (first_set_bit(
                view.bm,
                base_bit_ofs,
                bit_len,
                true,
                native_endian,
            )) |bit_ofs| .{
                .x = @as(u16, @intCast(bit_ofs)) + start_x,
                .count = @as(u16, @intCast(first_set_bit(
                    view.bm,
                    base_bit_ofs + bit_ofs,
                    bit_len - bit_ofs,
                    false,
                    native_endian,
                ) orelse bit_len - bit_ofs)),
            } else null;
        }
    };

    const native_endian = @import("builtin").cpu.arch.endian();

    pub fn combine_views(
        comptime N: comptime_int,
        views: *const [N]View,
        dest: View,
        comptime combine_fn: fn (
            views: [N]Word,
        ) callconv(.@"inline") Word,
    ) void {
        comptime std.debug.assert(N > 0);

        for (views) |view| {
            std.debug.assert(std.meta.eql(view.vp_dims, dest.vp_dims));
            view.assert_valid();
        }
        dest.assert_valid();

        for (0..dest.vp_dims.h) |vp_y| {
            var vp_x: u16 = 0;
            const VEC_BITS = @bitSizeOf(Word);
            while (vp_x < dest.vp_dims.w) : (vp_x += VEC_BITS) {
                var words: [N]Word = undefined;

                for (views, &words) |view, *word| {
                    const y = view.vp_ofs.y + vp_y;
                    const x = view.vp_ofs.x + vp_x;
                    const base_bit_ofs = y * view.bm_dims.w + x;

                    std.debug.assert(
                        (base_bit_ofs + VEC_BITS - 1) / VEC_BITS <= view.bm.len,
                    );

                    // Since we use native endianness, these reads are
                    // conceptually just a bitcast + shift.
                    word.* = std.mem.readPackedIntNative(
                        Word,
                        std.mem.sliceAsBytes(view.bm),
                        base_bit_ofs,
                    );
                }

                var dest_word = combine_fn(words);

                const dest_y = dest.vp_ofs.y + vp_y;
                const dest_x = dest.vp_ofs.x + vp_x;
                const dest_base_bit_ofs = dest_y * dest.bm_dims.w + dest_x;

                std.debug.assert(
                    (dest_base_bit_ofs + VEC_BITS - 1) / VEC_BITS <= dest.bm.len,
                );

                // Avoid clobbering bits that are not part of the view.
                const bits_overflow: std.math.Log2Int(Word) = @intCast(vp_x + VEC_BITS -| dest.vp_dims.w);
                std.debug.assert(bits_overflow <= VEC_BITS);
                if (bits_overflow > 0) {
                    const prev_word = std.mem.readPackedIntNative(
                        Word,
                        std.mem.sliceAsBytes(dest.bm),
                        dest_base_bit_ofs,
                    );
                    const mask = (std.math.boolMask(Word, true) >> bits_overflow);
                    dest_word = (prev_word & ~mask) | (dest_word & mask);
                }

                std.mem.writePackedIntNative(
                    Word,
                    std.mem.sliceAsBytes(dest.bm),
                    dest_base_bit_ofs,
                    dest_word,
                );
            }
        }
    }

    test combine_views {
        const bits = @bitSizeOf(Word);

        var A_buf = [_]Word{ 0, 0 };
        var B_buf = [_]Word{ 0, 0 };
        var C_buf = [_]Word{ 0, 0, 0, 0 };

        const A = BitMap.View.entire(&A_buf, .{ .w = bits, .h = 2 });
        const B = BitMap.View.entire(&B_buf, .{ .w = bits, .h = 2 });
        const C = BitMap.View.entire(&C_buf, .{ .w = bits + 1, .h = 3 });
        const C_view = BitMap.View.subview(
            C,
            .{ .x = 1, .y = 1 },
            .{ .w = bits, .h = 2 },
        );

        const mid = bits / 2;

        A.set_rect(.{ .x = 0, .y = 0, .w = mid, .h = 1 }, 1);
        A.set_rect(.{ .x = mid, .y = 1, .w = bits - mid, .h = 1 }, 1);

        B.set_rect(.{ .x = 1 + mid, .y = 0, .w = bits - mid - 1, .h = 1 }, 1);
        B.set_rect(.{ .x = 0, .y = 1, .w = mid, .h = 1 }, 1);

        C_view.set_rect(.{ .x = 0, .y = 0, .w = bits, .h = 2 }, 1);

        var result_buf = [_]Word{ 0, 0 };
        const result = BitMap.View.entire(&result_buf, .{ .w = bits, .h = 2 });

        BitMap.combine_views(3, &.{ A, B, C_view }, result, struct {
            pub inline fn combine(
                views: [3]BitMap.Word,
            ) BitMap.Word {
                const A_word = views[0];
                const B_word = views[1];
                const C_word = views[2];
                return (A_word | B_word) & C_word;
            }
        }.combine);

        var expected_buf = [_]Word{ 0, 0 };
        const expected = BitMap.View.entire(&expected_buf, .{ .w = bits, .h = 2 });
        expected.set_rect(.{ .x = 0, .y = 0, .w = bits, .h = 2 }, 1);
        expected.set_rect(.{ .x = mid, .y = 0, .w = 1, .h = 1 }, 0);

        try std.testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(expected.bm),
            std.mem.sliceAsBytes(result.bm),
        );
    }

    test "find_next_set_in_row end sentinel and tail count" {
        var bm = [_]Word{0};
        const whole = BitMap.View.entire(&bm, .{ .w = 16, .h = 3 });
        const view = BitMap.View.subview(
            whole,
            .{ .x = 4, .y = 1 },
            .{ .w = 5, .h = 1 },
        );

        view.set_rect(.{ .x = 1, .y = 0, .w = 4, .h = 1 }, 1);

        try std.testing.expect(view.find_next_set_in_row(5, 0) == null);
        const found = view.find_next_set_in_row(0, 0).?;
        try std.testing.expectEqual(@as(u16, 1), found.x);
        try std.testing.expectEqual(@as(u16, 4), found.count);
        try std.testing.expect(view.find_next_set_in_row(found.x + found.count, 0) == null);
    }

    /// Get a slice containing the bits of an unaligned bit read.
    inline fn select_bits(
        words: anytype,
        bit_ofs: usize,
        bit_count: usize,
        endian: std.builtin.Endian,
    ) x: {
        const W = @typeInfo(@TypeOf(words)).pointer.child;
        const Log2W = std.math.Log2Int(W);
        break :x struct {
            slice: @TypeOf(words),
            beg_mask: W,
            end_mask: W,
            beg_shift: Log2W,
        };
    } {
        if (bit_count == 0) return .{
            .slice = words[0..0],
            .beg_mask = 0,
            .end_mask = 0,
            .beg_shift = 0,
        };
        const W = @typeInfo(@TypeOf(words)).pointer.child;
        const W_bits = @bitSizeOf(W);
        const Log2W = std.math.Log2Int(W);
        std.debug.assert(bit_ofs + bit_count <= words.len * W_bits);

        const beg_shift: Log2W = @intCast(bit_ofs % W_bits);
        const slice_words = (beg_shift + bit_count + W_bits - 1) / W_bits;
        const lowest_word = switch (endian) {
            .little => bit_ofs / W_bits,
            .big => words.len - (bit_ofs / W_bits) - slice_words,
        };
        const slice = words[lowest_word..][0..slice_words];

        const ones = std.math.boolMask(W, true);
        const beg_mask: W = (ones << beg_shift);
        var end_mask: W = ~(ones << @intCast((beg_shift + bit_count) % W_bits));
        if (end_mask == 0) end_mask = ones;
        return .{
            .slice = slice,
            .beg_mask = beg_mask,
            .end_mask = end_mask,
            .beg_shift = beg_shift,
        };
    }

    fn set_bits(
        bytes: []u8,
        bit_ofs: usize,
        bit_count: usize,
        comptime val: u1,
        endian: std.builtin.Endian,
    ) void {
        if (bit_count == 0) return;
        std.debug.assert(bit_ofs + bit_count <= bytes.len * @bitSizeOf(u8));

        const sel = select_bits(bytes, bit_ofs, bit_count, endian);

        if (sel.slice.len == 1) {
            const mask = sel.beg_mask & sel.end_mask;
            switch (val) {
                0 => sel.slice[0] &= ~mask,
                1 => sel.slice[0] |= mask,
            }
            return;
        }

        switch (val) {
            0 => {
                switch (endian) {
                    .little => {
                        sel.slice[0] &= ~sel.beg_mask;
                        sel.slice[sel.slice.len - 1] &= ~sel.end_mask;
                    },
                    .big => {
                        sel.slice[0] &= ~sel.end_mask;
                        sel.slice[sel.slice.len - 1] &= ~sel.beg_mask;
                    },
                }
            },
            1 => {
                switch (endian) {
                    .little => {
                        sel.slice[0] |= sel.beg_mask;
                        sel.slice[sel.slice.len - 1] |= sel.end_mask;
                    },
                    .big => {
                        sel.slice[0] |= sel.end_mask;
                        sel.slice[sel.slice.len - 1] |= sel.beg_mask;
                    },
                }
            },
        }
        @memset(sel.slice[1 .. sel.slice.len - 1], 0xFF * @as(u8, val));
    }

    test set_bits {
        for ([_]std.builtin.Endian{ .little, .big }) |endian| {
            for ([_]usize{ 0, 1, 2, 3, 4, 5, 6 }) |bit_ofs| {
                inline for (.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }) |bit_count| {
                    const uN = std.meta.Int(.unsigned, bit_count);

                    var bytes = [_]u8{0} ** 4;
                    set_bits(&bytes, bit_ofs, bit_count, 1, endian);
                    var val = std.mem.readPackedInt(uN, &bytes, bit_ofs, endian);
                    try std.testing.expectEqual(std.math.boolMask(uN, true), val);

                    bytes = [_]u8{1} ** 4;
                    set_bits(&bytes, bit_ofs, bit_count, 0, endian);
                    val = std.mem.readPackedInt(uN, &bytes, bit_ofs, endian);
                    try std.testing.expectEqual(std.math.boolMask(uN, false), val);

                    bytes = undefined;
                    set_bits(&bytes, bit_ofs, bit_count, 1, endian);
                    val = std.mem.readPackedInt(uN, &bytes, bit_ofs, endian);
                    try std.testing.expectEqual(std.math.boolMask(uN, true), val);

                    bytes = undefined;
                    set_bits(&bytes, bit_ofs, bit_count, 0, endian);
                    val = std.mem.readPackedInt(uN, &bytes, bit_ofs, endian);
                    try std.testing.expectEqual(std.math.boolMask(uN, false), val);
                }
            }
        }
    }

    fn first_set_bit(
        words: []const Word,
        bit_ofs: usize,
        bit_count: usize,
        comptime val: bool,
        endian: std.builtin.Endian,
    ) ?usize {
        if (bit_count == 0) return null;
        const sel = select_bits(words, bit_ofs, bit_count, endian);
        const word_bits: std.math.Log2IntCeil(Word) = @bitSizeOf(Word);

        std.debug.assert(sel.slice.len > 0);

        if (sel.slice.len == 1) {
            // this might be faster with some XOR nonsense
            var word: Word = if (!val) ~sel.slice[0] else sel.slice[0];
            // OPTIMIZATION: we can skip the beg_mask as be shift it out
            // anyways
            // word &= (sel.beg_mask & sel.end_mask);
            word &= sel.end_mask;
            word >>= sel.beg_shift;

            return if (word != 0) @ctz(word) else null;
        }

        switch (endian) {
            .little => {
                var low_word: Word =
                    if (!val) ~sel.slice[0] else sel.slice[0];
                low_word >>= sel.beg_shift;
                if (low_word != 0) return @ctz(low_word);

                var idx: usize = word_bits - sel.beg_shift;
                for (sel.slice[1 .. sel.slice.len - 1]) |word_| {
                    const word: Word = if (!val) ~word_ else word_;
                    if (word != 0) {
                        return idx + @ctz(word);
                    }
                    idx += word_bits;
                }

                var high_word: Word = if (!val)
                    ~sel.slice[sel.slice.len - 1]
                else
                    sel.slice[sel.slice.len - 1];
                high_word &= sel.end_mask;
                return if (high_word != 0) idx + @ctz(high_word) else null;
            },
            .big => {
                var low_word: Word = if (!val)
                    ~sel.slice[sel.slice.len - 1]
                else
                    sel.slice[sel.slice.len - 1];
                low_word >>= sel.beg_shift;
                if (low_word != 0) return @ctz(low_word);

                var idx: usize = word_bits - sel.beg_shift;
                for (1..sel.slice.len - 1) |i| {
                    const word_ = sel.slice[sel.slice.len - i];
                    const word: Word = if (!val) ~word_ else word_;
                    if (word != 0) {
                        return idx + @ctz(word);
                    }
                    idx += word_bits;
                }

                var high_word: Word = if (!val)
                    ~sel.slice[0]
                else
                    sel.slice[0];
                high_word &= sel.end_mask;
                return if (high_word != 0) idx + @ctz(high_word) else null;
            },
        }
    }

    test first_set_bit {
        const words_true = [_]Word{ 1 << 5, 0, 1 << 100 };
        const words_false = [_]Word{
            ~words_true[0],
            ~words_true[1],
            ~words_true[2],
        };
        const eq = std.testing.expectEqual;

        inline for (
            .{ words_true, words_false },
            .{ true, false },
        ) |words, val| {
            try eq(5, first_set_bit(
                &words,
                0,
                words.len * @bitSizeOf(Word),
                val,
                .little,
            ));
            try eq(100, first_set_bit(
                &words,
                0,
                words.len * @bitSizeOf(Word),
                val,
                .big,
            ));
            try eq(null, first_set_bit(
                &words,
                6,
                (@bitSizeOf(Word) * 2) - 6,
                val,
                .little,
            ));
            try eq(0, first_set_bit(
                &words,
                100,
                (@bitSizeOf(Word) * 2) - 100,
                val,
                .big,
            ));
            try eq(2, first_set_bit(
                &words,
                3,
                @bitSizeOf(Word) * 2,
                val,
                .little,
            ));
            try eq(97, first_set_bit(
                &words,
                3,
                @bitSizeOf(Word) * 2,
                val,
                .big,
            ));
        }
    }
};

pub fn init(io: std.Io, alloc: std.mem.Allocator) !Render {
    return .{
        .io = io,
        .alloc = alloc,
    };
}
pub fn deinit(r: *Render) void {
    r.flush_overdraw_bm.deinit(r.alloc);
    r.flush_requdraw_bm.deinit(r.alloc);
    r.egc_pool.deinit(r.alloc);

    const surfaces_slice = r.surfaces.slice();
    for (surfaces_slice.items(.cell_dirt)) |*cd| cd.deinit(r.alloc);
    r.surfaces.deinit(r.alloc);

    // TODO: need to figure out a pattern for destroying
    // multiarraypools without deinit'ing destroyed elems
    const grids_slice = r.grids.slice();
    for (grids_slice.items(.cell_char)) |*cc| cc.deinit(r.alloc);
    for (grids_slice.items(.cell_bg)) |*cb| cb.deinit(r.alloc);
    for (grids_slice.items(.cell_fg)) |*cf| cf.deinit(r.alloc);

    r.grids.deinit(r.alloc);
    r.stack.deinit(r.alloc);
    r.* = undefined;
}

fn tty_name_r(fd: std.posix.fd_t, buf: []u8) ![]u8 {
    // prefer either using std version of ttyname or implementing one once
    // std.Io.File.stat provides device ids so we can do the /dev/ scan
    // ourselves
    const c = struct {
        extern "c" fn ttyname_r(fd: std.posix.fd_t, name: [*]u8, size: usize) c_int;
    };
    return switch (std.posix.errno(
        c.ttyname_r(fd, buf.ptr, buf.len),
    )) {
        .SUCCESS => std.mem.sliceTo(buf, 0),
        .BADF => error.BadFileDescriptor,
        .NODEV => error.NoDevice,
        .NOTTY => error.NotATty,
        // our buffer was too small
        .RANGE => error.OutOfMemory,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn tty_attrs_set_raw_input(attrs: *std.posix.termios) void {
    // terminal input control
    attrs.iflag.BRKINT = false; // ign. BREAK condition
    attrs.iflag.ICRNL = false; // map CR to NL
    attrs.iflag.INPCK = false; // input parity check
    attrs.iflag.ISTRIP = false; // strip 8th bit off chars
    attrs.iflag.IXON = false; // output flow control
    // terminal hardware control
    attrs.cflag.CSIZE = .CS8; // 8bit char size mask
    // local mode / function control
    attrs.lflag.ECHO = false; // input char echoed to terminal
    attrs.lflag.ICANON = false; // canonicalize input lines
    attrs.lflag.IEXTEN = false; // terminal functions from input data
    attrs.lflag.ISIG = false; // signals for INTR, QUIT, [D]SUSP
    // special control characters
    // input availability conditions
    attrs.cc[@intFromEnum(std.posix.V.MIN)] = 1; // min buffered chars
    attrs.cc[@intFromEnum(std.posix.V.TIME)] = 0; // min timeout
}
fn tty_attrs_set_raw_output(attrs: *std.posix.termios) void {
    // terminal output control
    attrs.oflag.ONLCR = true; // map NL to CR-NL
    // terminal hardware control
    attrs.cflag.CSIZE = .CS8; // 8bit char size mask
}

pub fn setup(r: *Render) !void {
    const inaive = std.Io.File.stdin();
    const onaive = std.Io.File.stdout();

    var idev_buf: [128]u8 = @splat(0);
    const idev = if (try inaive.isTty(r.io))
        try tty_name_r(inaive.handle, &idev_buf)
    else
        null;

    var odev_buf: [128]u8 = @splat(0);
    const odev = if (try onaive.isTty(r.io))
        try tty_name_r(onaive.handle, &odev_buf)
    else
        null;

    if (idev != null and odev != null and
        std.mem.eql(u8, idev.?, odev.?))
    {
        const tty = try std.Io.Dir.openFileAbsolute(r.io, odev.?, .{
            .mode = .read_write,
        });
        // WARN: there is an inherent TOCTOU race here as we don't lock
        //       termios/tcattrs on the device
        var attrs = try std.posix.tcgetattr(tty.handle);
        tty_attrs_set_raw_input(&attrs);
        tty_attrs_set_raw_output(&attrs);
        try std.posix.tcsetattr(tty.handle, .DRAIN, attrs);
        r.stdout = tty;
        r.stdin = r.stdout;
    } else {
        r.stdin = inaive;
        r.stdout = onaive;

        if (idev) |idev_| {
            const tty = try std.Io.Dir.openFileAbsolute(r.io, idev_, .{
                .mode = .read_only,
            });
            var attrs = try std.posix.tcgetattr(tty.handle);
            tty_attrs_set_raw_input(&attrs);
            try std.posix.tcsetattr(tty.handle, .DRAIN, attrs);
            r.stdin = tty;
        }
        if (odev) |odev_| {
            const tty = try std.Io.Dir.openFileAbsolute(r.io, odev_, .{
                .mode = .write_only,
            });
            var attrs = try std.posix.tcgetattr(tty.handle);
            tty_attrs_set_raw_output(&attrs);
            try std.posix.tcsetattr(tty.handle, .DRAIN, attrs);
            r.stdout = tty;
        }
    }

    r.is_alive = true;

    // enter alternate screen mode
    try r.stdout.writeStreamingAll(r.io, "\x1B[?1049h");
}
pub fn teardown(r: *Render) !void {
    std.debug.assert(r.is_alive);

    // leave alternate screen mode
    try r.stdout.writeStreamingAll(r.io, "\x1B[?1049l");

    // TODO: unset raw mode for stdout
    //       what libuv does is save the orig termios state pre-raw mode and
    //       restore it
    // try uv.unwrapErr(c.uv_tty_reset_mode());

    r.stdin.close(r.io);
    if (r.stdout.handle != r.stdin.handle)
        r.stdout.close(r.io);
    r.is_alive = false;
}

pub fn flush(r: *Render) !void {
    if (!r.surfaces_dirty) return;
    defer r.surfaces_dirty = false;

    if (r.flush_grid == .null) {
        r.flush_grid = try r.grid_create();
    }

    // Flush grid = undefined (WxH output grid)
    const tty_dims = try r.tty_get_dimensions();
    try r.grid_set_dimensions(r.flush_grid, tty_dims);

    // Overdraw O = 0 (WxH bitmap)
    // Requdraw E = 0 (WxH bitmap)
    const tty_cells = tty_dims.w * tty_dims.h;
    const word_bits = @bitSizeOf(BitMap.Word);
    const bm_words = (tty_cells + word_bits - 1) / word_bits;
    r.flush_overdraw_bm.clearRetainingCapacity();
    r.flush_requdraw_bm.clearRetainingCapacity();
    @memset(try r.flush_overdraw_bm.addManyAsSlice(r.alloc, bm_words), 0);
    @memset(try r.flush_requdraw_bm.addManyAsSlice(r.alloc, bm_words), 0);

    const O = BitMap.View.entire(r.flush_overdraw_bm.items, tty_dims);
    const E = BitMap.View.entire(r.flush_requdraw_bm.items, tty_dims);

    const g_slice = r.grids.slice();
    const out_dims = g_slice.items(.dims)[r.flush_grid.to_idx().?];
    const out_cell_char = g_slice.items(.cell_char)[r.flush_grid.to_idx().?];
    const out_cell_bg = g_slice.items(.cell_bg)[r.flush_grid.to_idx().?];
    const out_cell_fg = g_slice.items(.cell_fg)[r.flush_grid.to_idx().?];

    const s_slice = r.surfaces.slice();
    // top to bottom
    // TODO: use stack field instead of storage order
    for (s_slice.items(.dirt), 0..) |dirt, s_idx| {
        switch (dirt) {
            .full => {
                // TODO
                unreachable;
            },
            .partial => {
                const s_grid_idx = s_slice.items(.grid)[s_idx].to_idx().?;

                const s_screen_pos = s_slice.items(.screen_pos)[s_idx];
                const s_dims = s_slice.items(.dims)[s_idx];
                const s_cell_dirt = s_slice.items(.cell_dirt)[s_idx];
                const s_grid_pos = s_slice.items(.grid_pos)[s_idx];
                const s_wrapping_ofs = s_slice.items(.wrapping_ofs)[s_idx];
                {
                    const cells = s_dims.w * s_dims.h;
                    std.debug.assert(
                        s_cell_dirt.items.len ==
                            (cells + word_bits - 1) / word_bits,
                    );
                }

                const D = BitMap.View.entire(s_cell_dirt.items, s_dims);
                const O_view = O.subview(s_screen_pos, s_dims);
                const E_view = E.subview(s_screen_pos, s_dims);

                // D = (Dirty but not Overdrawn) or Requdraw
                BitMap.combine_views(3, &.{ D, O_view, E_view }, D, struct {
                    pub inline fn combine(
                        views: [3]BitMap.Word,
                    ) BitMap.Word {
                        const D_vec = views[0];
                        const O_vec = views[1];
                        const E_vec = views[2];
                        return (D_vec & ~O_vec) | E_vec;
                    }
                }.combine);

                // draw (newL & D cells) to output grid
                surface_cp_to_grid(.{
                    .screen_pos = s_screen_pos,
                    .dims = s_dims,
                    .grid_pos = s_grid_pos,
                    .wrapping_ofs = s_wrapping_ofs,
                }, .{
                    .dims = g_slice.items(.dims)[s_grid_idx],
                    .cell_char = g_slice.items(.cell_char)[s_grid_idx],
                    .cell_bg = g_slice.items(.cell_bg)[s_grid_idx],
                    .cell_fg = g_slice.items(.cell_fg)[s_grid_idx],
                }, .{
                    .dims = out_dims,
                    .cell_char = out_cell_char,
                    .cell_bg = out_cell_bg,
                    .cell_fg = out_cell_fg,
                }, D);

                // O = O | D
                O_view.assign_or(D);

                // E = E | (prevL - newL)
                const s_prev_screen_pos =
                    &s_slice.items(.flush_prev_screen_pos)[s_idx];
                const s_prev_dims = &s_slice.items(.flush_prev_dims)[s_idx];

                const prevL = Rectangle.from_pos_dims(
                    s_prev_screen_pos.*,
                    s_prev_dims.*,
                );
                const newL = Rectangle.from_pos_dims(
                    s_screen_pos,
                    s_dims,
                );
                // NOTE: deltaL = (oldL - newL) is a subset of oldL
                const deltaL_rects = rectangle_delta(prevL, newL);
                for (deltaL_rects) |deltaL_rect| {
                    E.set_rect(deltaL_rect, 1);
                }

                // prevL = newL
                s_prev_screen_pos.* = s_screen_pos;
                s_prev_dims.* = s_dims;

                // D = 0
                @memset(D.bm, 0);
            },
            .clean => continue,
        }
    }

    try r.grid_direct_draw(.{
        .dims = out_dims,
        .cell_char = out_cell_char,
        .cell_bg = out_cell_bg,
        .cell_fg = out_cell_fg,
    }, O);
}

/// The regions left empty by the new rect wrt the old rect.
fn rectangle_delta(r0: Rectangle, r1: Rectangle) [4]Rectangle {
    // diagram:
    //
    //  /-----------\
    //  |  |     |  |
    //  |  /-----\  |
    //  |  |     |  |
    //  |  |     |  |
    //  |  \-----/  |
    //  |  |     |  |
    //  \-----------/
    //
    // left-right: full h0
    // top-bottom: only min(w0, w1)

    const left = Rectangle{
        .x = r0.x,
        .y = r0.y,
        .w = r1.x -| r0.x,
        .h = r0.h,
    };
    const right = Rectangle{
        .x = r1.x + r1.w,
        .y = r0.y,
        .w = (r0.x + r0.w) -| (r1.x + r1.w),
        .h = r0.h,
    };
    const top = Rectangle{
        .x = r0.x,
        .y = r0.y,
        .w = @min(r0.w, r1.w),
        .h = r0.y -| r1.y,
    };
    const bottom = Rectangle{
        .x = r0.x,
        .y = r1.y + r1.h,
        .w = @min(r0.w, r1.w),
        .h = (r0.y + r0.h) -| (r1.y + r1.h),
    };

    return [4]Rectangle{ left, right, top, bottom };
}

fn surface_cp_to_grid(
    src_s: struct {
        screen_pos: Position,
        dims: Dimensions,
        grid_pos: Position,
        wrapping_ofs: Position,
    },
    src_g: Grid,
    dst_g: Grid,
    src_mask: BitMap.View,
) void {
    src_mask.assert_valid();

    assert(std.meta.eql(src_mask.vp_dims, src_s.dims));
    assert(src_s.dims.w <= dst_g.dims.w);
    assert(src_s.dims.h <= dst_g.dims.h);
    assert(src_s.screen_pos.x < dst_g.dims.w);
    assert(src_s.screen_pos.y < dst_g.dims.h);
    assert(src_s.screen_pos.x + src_s.dims.w <= dst_g.dims.w);
    assert(src_s.screen_pos.y + src_s.dims.h <= dst_g.dims.h);

    // we implement wrapping but covering cells at most once.
    assert(src_s.dims.w <= src_g.dims.w);
    assert(src_s.dims.h <= src_g.dims.h);

    // because we have a wrapping view ofer the src grid, we need to handle
    // four regions of the surface individually.
    //
    //   G
    //   ╔═══════════╗
    //   ║--/    \---║
    //   ║ br   bl   ║
    //   ║ tr   tl   ║  S
    //   ║--\    ┌──────┐
    //   ║  |    │   ║  │
    //   ╚═══════│═══╝  │
    //           └──────┘

    const right_wrap_amt = (src_s.grid_pos.x + src_s.dims.w) % src_g.dims.w;
    const bottom_wrap_amt = (src_s.grid_pos.y + src_s.dims.h) % src_g.dims.h;
    const tl_dims = Dimensions{
        .w = src_s.dims.w - right_wrap_amt,
        .h = src_s.dims.h - bottom_wrap_amt,
    };

    for ([4]struct {
        grid_pos: Position,
        surf_pos: Position,
        dims: Dimensions,
    }{
        .{
            .grid_pos = src_s.grid_pos,
            .surf_pos = .origin,
            .dims = tl_dims,
        },
        .{
            .grid_pos = .{ .x = 0, .y = src_s.grid_pos.y },
            .surf_pos = .{ .x = tl_dims.w, .y = 0 },
            .dims = .{
                .w = right_wrap_amt,
                .h = src_s.dims.h - bottom_wrap_amt,
            },
        },
        .{
            .grid_pos = .{ .x = src_s.grid_pos.x, .y = 0 },
            .surf_pos = .{ .x = 0, .y = tl_dims.h },
            .dims = .{
                .w = src_s.dims.w - right_wrap_amt,
                .h = bottom_wrap_amt,
            },
        },
        .{
            .grid_pos = .{ .x = src_s.grid_pos.x, .y = src_s.grid_pos.y },
            .surf_pos = .{ .x = tl_dims.w, .y = tl_dims.h },
            .dims = .{
                .w = right_wrap_amt,
                .h = bottom_wrap_amt,
            },
        },
    }) |info| {
        GridView.copy(.{
            .grid = src_g,
            .vp_ofs = info.grid_pos,
            .vp_dims = info.dims,
        }, .{
            .grid = dst_g,
            .vp_ofs = src_s.screen_pos.add(info.surf_pos),
            .vp_dims = info.dims,
        }, src_mask.subview(info.surf_pos, info.dims));
    }
}

const GridView = struct {
    grid: Grid,
    vp_ofs: Position,
    vp_dims: Dimensions,

    pub fn assert_valid(view: GridView) void {
        std.debug.assert(view.vp_ofs.x <= view.grid.dims.w);
        std.debug.assert(view.vp_ofs.y <= view.grid.dims.h);
        std.debug.assert(view.vp_ofs.x + view.vp_dims.w <= view.grid.dims.w);
        std.debug.assert(view.vp_ofs.y + view.vp_dims.h <= view.grid.dims.h);
    }

    pub fn copy(src: GridView, dst: GridView, mask: BitMap.View) void {
        src.assert_valid();
        dst.assert_valid();
        mask.assert_valid();

        assert(std.meta.eql(src.vp_dims, dst.vp_dims));
        assert(std.meta.eql(src.vp_dims, mask.vp_dims));

        for (0..src.vp_dims.h) |y_| {
            const y: u16 = @intCast(y_);

            var start_x: u16 = 0;
            while (mask.find_next_set_in_row(start_x, y)) |found| {
                assert(found.count > 0);
                assert(found.x < mask.vp_dims.w);

                const dst_x = dst.vp_ofs.x + found.x;
                const dst_y = dst.vp_ofs.y + y;
                const dst_base_char = dst_y * dst.grid.dims.w + dst_x;

                const src_x = src.vp_ofs.x + found.x;
                const src_y = src.vp_ofs.y + y;
                const src_base_char = src_y * src.grid.dims.w + src_x;

                @memcpy(
                    dst.grid.cell_char.items[dst_base_char..][0..found.count],
                    src.grid.cell_char.items[src_base_char..][0..found.count],
                );
                @memcpy(
                    dst.grid.cell_bg.items[dst_base_char..][0..found.count],
                    src.grid.cell_bg.items[src_base_char..][0..found.count],
                );
                @memcpy(
                    dst.grid.cell_fg.items[dst_base_char..][0..found.count],
                    src.grid.cell_fg.items[src_base_char..][0..found.count],
                );

                start_x = found.x + found.count;
            }
        }
    }
};

const OverflowingWriter = struct {
    overflow: *std.Io.Writer,
    writer: std.Io.Writer,

    pub fn init(buf: []u8, overflow: *std.Io.Writer) OverflowingWriter {
        return .{
            .overflow = overflow,
            .writer = .{
                .buffer = buf,
                .end = 0,
                .vtable = &.{
                    .drain = OverflowingWriter.drain,
                    .flush = std.Io.Writer.noopFlush,

                    // we might be able to implement something here..
                    .rebase = std.Io.Writer.failingRebase,
                },
            },
        };
    }
    pub fn drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        // NOTE: we purposely don't ever flush out the buffer as we only want
        // the overflowing bytes to go into overflow writer.

        const ofw: *OverflowingWriter = @fieldParentPtr("writer", w);
        if (w.unusedCapacityLen() == 0)
            return ofw.overflow.writeSplat(data, splat);

        const old_end = w.end;
        return std.Io.Writer.fixedDrain(w, data, splat) catch |e| switch (e) {
            // we aren't out of space, we just need to be polled again so we
            // can go to the overflow writer
            error.WriteFailed => w.end - old_end,
        };
    }
};

fn grid_direct_draw(r: *Render, grid: Grid, mask: BitMap.View) !void {
    mask.assert_valid();
    assert(std.meta.eql(grid.dims, mask.vp_dims));

    var buf: [1024]u8 = undefined;
    var writer_ = r.stdout.writerStreaming(r.io, &buf);
    const writer = &writer_.interface;
    defer writer.flush() catch unreachable;
    // TODO: what to do with cancellations?
    //       currently turns into generic `WriteFailed`
    // errdefer if (writer_.err) |e| switch (e) {
    //     std.Io.Cancelable.Canceled =>
    // };

    var current_cursor: ?struct {
        pos: Position,
        cell_bg: Color,
        cell_fg: Color,
    } = null;
    for (0..grid.dims.h) |y_| {
        const y: u16 = @intCast(y_);

        var start_x: u16 = 0;
        while (mask.find_next_set_in_row(start_x, y)) |found| {
            assert(found.count > 0);
            assert(found.x + found.count <= grid.dims.w);

            for (found.x..(found.x + found.count)) |x_| {
                const x: u16 = @intCast(x_);

                const i = grid.dims.w * y + x;
                const cell_bg = grid.cell_bg.items[i];
                const cell_fg = grid.cell_fg.items[i];
                const cell_char = grid.cell_char.items[i];

                const need_pos, const need_cell_bg, const need_cell_fg =
                    if (current_cursor) |c_| .{
                        !std.meta.eql(c_.cell_fg, cell_fg),
                        !std.meta.eql(c_.cell_bg, cell_bg),
                        !std.meta.eql(c_.pos, .{ .x = x, .y = y }),
                    } else .{ true, true, true };

                // HVP - set cursor position
                if (need_pos) {
                    writer.print("\x1B[{[row]d};{[col]d}f", .{
                        .row = y + 1,
                        .col = x + 1,
                    }) catch unreachable;
                }
                if (need_cell_fg) {
                    if (cell_fg.default_) {
                        writer.writeAll("\x1B[39m") catch unreachable;
                    } else {
                        writer.print("\x1B[38;2;{[r]d};{[g]d};{[b]d}m", .{
                            .r = cell_fg.r,
                            .g = cell_fg.g,
                            .b = cell_fg.b,
                        }) catch unreachable;
                    }
                }
                if (need_cell_bg) {
                    if (cell_bg.default_) {
                        writer.writeAll("\x1B[49m") catch unreachable;
                    } else {
                        writer.print("\x1B[48;2;{[r]d};{[g]d};{[b]d}m", .{
                            .r = cell_bg.r,
                            .g = cell_bg.g,
                            .b = cell_bg.b,
                        }) catch unreachable;
                    }
                }

                switch (cell_char) {
                    0 => writer.writeByte(' ') catch unreachable,
                    32...126 => |c_| writer.writeByte(@intCast(c_)) catch unreachable,
                    128...std.math.maxInt(@TypeOf(cell_char)) => |egc_idx| {
                        const gc = r.egc_pool.get(egc_idx - 128);
                        writer.writeAll(gc) catch unreachable;
                    },
                    else => unreachable,
                }

                current_cursor = .{
                    .pos = Position{
                        .x = x + 1, // printing the char advances the cursor
                        .y = y,
                    },
                    .cell_bg = cell_bg,
                    .cell_fg = cell_fg,
                };
            }

            start_x = found.x + found.count;
        }
    }
}

pub fn tty_get_dimensions(r: *Render) !Dimensions {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    if (std.posix.errno(
        std.posix.system.ioctl(r.stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize)),
    ) == .SUCCESS) {}
    return .{
        .w = winsize.col,
        .h = winsize.row,
    };
}

pub fn grid_create(r: *Render) !GridNum {
    return try r.grids.create(r.alloc, .empty);
}

pub fn grid_destroy(r: *Render, num: GridNum) void {
    r.grids.destroy(r.alloc, num);
}

pub fn surface_create(r: *Render) !SurfaceNum {
    return try r.surfaces.create(r.alloc, .{});
}

pub fn surface_destroy(r: *Render, num: SurfaceNum) void {
    const slice = r.surfaces.slice();
    slice.items(.cell_dirt)[num.to_idx().?].deinit(r.alloc);
    r.surfaces.destroy(r.alloc, num);
}

pub fn grid_set_dimensions(
    r: *Render,
    num: GridNum,
    dims: Dimensions,
) !void {
    const slice = r.grids.slice();
    slice.items(.dims)[num.to_idx().?] = dims;

    const new_cell_count = dims.w * dims.h;

    const cell_char = &slice.items(.cell_char)[num.to_idx().?];
    const cell_bg = &slice.items(.cell_bg)[num.to_idx().?];
    const cell_fg = &slice.items(.cell_fg)[num.to_idx().?];

    cell_char.clearRetainingCapacity();
    cell_bg.clearRetainingCapacity();
    cell_fg.clearRetainingCapacity();
    @memset(try cell_char.addManyAsSlice(r.alloc, new_cell_count), 0);
    @memset(try cell_bg.addManyAsSlice(r.alloc, new_cell_count), .default);
    @memset(try cell_fg.addManyAsSlice(r.alloc, new_cell_count), .default);
}

pub fn surface_set_label(
    r: *Render,
    num: SurfaceNum,
    label: ?[]const u8,
) void {
    const slice = r.surfaces.slice();
    slice.items(.label)[num.to_idx().?] = label;
}

pub fn surface_set_grid(
    r: *Render,
    num: SurfaceNum,
    grid: GridNum,
) void {
    const slice = r.surfaces.slice();
    slice.items(.grid)[num.to_idx().?] = grid;
}

pub fn surface_get_grid(r: *Render, num: SurfaceNum) GridNum {
    const slice = r.surfaces.slice();
    return slice.items(.grid)[num.to_idx().?];
}

pub fn surface_set_dimensions(
    r: *Render,
    num: SurfaceNum,
    dims: Dimensions,
) !void {
    const slice = r.surfaces.slice();
    slice.items(.dims)[num.to_idx().?] = dims;

    const new_cell_count = dims.w * dims.h;
    const cell_dirt = &slice.items(.cell_dirt)[num.to_idx().?];

    cell_dirt.clearRetainingCapacity();
    const word_bits = @bitSizeOf(BitMap.Word);
    const new_len = (new_cell_count + word_bits - 1) / word_bits;
    @memset(try cell_dirt.addManyAsSlice(r.alloc, new_len), 0);
}

pub fn surface_get_dimensions(r: *Render, num: SurfaceNum) Dimensions {
    const slice = r.surfaces.slice();
    return slice.items(.dims)[num.to_idx().?];
}

pub fn surface_touch(r: *Render, num: SurfaceNum) void {
    const dirt = &r.surfaces.slice().items(.dirt)[num.to_idx().?];
    if (dirt.* == .clean) dirt.* = .partial;
    r.surfaces_dirty = true;
}

pub fn surface_set_screen_position(
    r: *Render,
    num: SurfaceNum,
    pos: Position,
) void {
    const slice = r.surfaces.slice();
    slice.items(.screen_pos)[num.to_idx().?] = pos;
}

pub fn surface_get_screen_position(r: *Render, num: SurfaceNum) Position {
    const slice = r.surfaces.slice();
    return slice.items(.screen_pos)[num.to_idx().?];
}

pub fn surface_set_grid_position(
    r: *Render,
    num: SurfaceNum,
    pos: Position,
) void {
    const slice = r.surfaces.slice();
    slice.items(.grid_pos)[num.to_idx().?] = pos;
}

pub fn surface_get_grid_position(r: *Render, num: SurfaceNum) Position {
    const slice = r.surfaces.slice();
    return slice.items(.grid_pos)[num.to_idx().?];
}

pub const SurfaceWriteUtf8Result = struct {
    pub const End = enum {
        need_feed,
        eos,
        newline,
        row_full,
    };

    bytes: usize,
    cells: u16,
    end: End,
};

pub const Utf8StreamWriter = struct {
    // One row writer over one contig text stream.
    // Extra state is just for gc cuts at input chunk bounds.
    render: *Render,
    surface: SurfaceNum,
    pos: Position,
    gc_iter: *TrueGcIter,

    pub fn init(
        render: *Render,
        surface: SurfaceNum,
        pos: Position,
        gc_iter: *TrueGcIter,
    ) Utf8StreamWriter {
        return .{
            .render = render,
            .surface = surface,
            .pos = pos,
            .gc_iter = gc_iter,
        };
    }

    pub fn write(writer: *Utf8StreamWriter) !SurfaceWriteUtf8Result {
        return try surface_write_utf8_impl(
            writer.render,
            writer.surface,
            writer,
        );
    }
};

pub const TrueGcIter = struct {
    // Holds carry bytes across chunk cuts.
    // Naive per-slice gc scan would split at read bounds.
    ring: stdx.ByteRing(buf_cap),
    input_done: bool,

    pub const buf_cap = 256;

    pub const empty: TrueGcIter = .{
        .ring = .empty,
        .input_done = false,
    };

    pub const Item = struct {
        // Borrowed ring span. Use before next iter mutation.
        bytes: stdx.ByteParts,
        wcwidth: usize,
    };

    pub const Next = union(enum) {
        item: Item,
        need_feed,
        eos,
    };

    pub fn feed(it: *TrueGcIter, text: []const u8) error{GraphemeTooLong}!usize {
        std.debug.assert(!it.input_done);
        if (text.len == 0) return 0;

        var utf8_it = uucode.utf8.Iterator.init(text);
        var fed: usize = 0;
        while (utf8_it.i < text.len) {
            const start = utf8_it.i;
            _ = utf8_it.next() orelse break;
            const cp_len = utf8_it.i - start;
            assert(cp_len != 0);
            if (cp_len > it.ring.free()) {
                if (fed == 0) return error.GraphemeTooLong;
                break;
            }
            it.ring.push_slice(text[start..utf8_it.i]) catch unreachable;
            fed = utf8_it.i;
        }
        return fed;
    }

    pub fn finish_input(it: *TrueGcIter) void {
        it.input_done = true;
    }

    pub fn buffered(it: *const TrueGcIter) stdx.ByteParts {
        return it.ring.parts();
    }

    pub fn discard(it: *TrueGcIter, n: u16) void {
        it.ring.pop_front(n);
    }

    pub fn next_ascii(it: *TrueGcIter, max_len: u16) ?stdx.ByteParts {
        if (it.ring.len == 0 or max_len == 0) return null;

        const ring = it.ring.parts();
        var run_len: u16 = 0;
        for (ring.a) |byte| {
            if (byte >= 128 or ascii_char_is_invisible(byte)) break;
            run_len += 1;
        }
        if (run_len == ring.a.len) {
            for (ring.b) |byte| {
                if (byte >= 128 or ascii_char_is_invisible(byte)) break;
                run_len += 1;
            }
        }
        if (run_len == 0) return null;

        const next_byte: ?u8 = if (run_len < ring.len())
            it.ring.span(run_len, run_len + 1).first()
        else
            null;
        var safe_len = run_len;
        // Keep the last ASCII byte back if the next byte might still join it.
        if (next_byte) |byte| {
            if (byte >= 128 or ascii_char_is_invisible(byte)) safe_len -= 1;
        } else if (!it.input_done) {
            safe_len -= 1;
        }
        if (safe_len == 0) return null;

        const take: u16 = @min(safe_len, max_len);
        const ascii = it.ring.span(0, take);
        it.ring.pop_front(take);
        return ascii;
    }

    pub fn next(it: *TrueGcIter) Next {
        if (it.ring.len == 0) {
            return if (it.input_done) .eos else .need_feed;
        }

        var gc_it = uucode.grapheme.Iterator(BiUtf8Iterator).init(
            .init(&it.ring),
        );
        const start = gc_it.i;
        const wcwidth = uucode.grapheme.wcwidthNext(&gc_it);
        const end = gc_it.i;
        if (start == end) {
            assert(wcwidth == 0);
            return if (it.input_done) .eos else .need_feed;
        }
        assert(start == 0);

        if (gc_it.next_cp == null and !it.input_done) {
            // Found one gc, but maybe only from stream end.
            // Need more bytes to tell real gc end from read cut.
            return .need_feed;
        }

        const gc = it.ring.span(0, @intCast(end));
        it.ring.pop_front(@intCast(end));
        return .{ .item = .{
            .bytes = gc,
            .wcwidth = wcwidth,
        } };
    }
};

const BiUtf8Iterator = struct {
    i: usize = 0,
    ring: *const stdx.ByteRing(TrueGcIter.buf_cap),

    fn init(ring: *const stdx.ByteRing(TrueGcIter.buf_cap)) BiUtf8Iterator {
        return .{
            .ring = ring,
        };
    }

    pub fn next(it: *BiUtf8Iterator) ?u21 {
        const total_len = it.ring.len;
        if (it.i >= total_len) return null;

        var prefix: [4]u8 = undefined;
        var utf8_it = uucode.utf8.Iterator.init(
            it.ring.read_at(@intCast(it.i), &prefix),
        );
        const cp = utf8_it.next() orelse unreachable;
        it.i += utf8_it.i;
        return cp;
    }

    pub fn peek(it: BiUtf8Iterator) ?u21 {
        var next_it = it;
        return next_it.next();
    }
};

test "TrueGcIter decodes codepoint split across ring wrap" {
    var gc_it: TrueGcIter = .empty;
    gc_it.ring.head = TrueGcIter.buf_cap - 1;
    gc_it.ring.len = 2;
    gc_it.ring.buf[TrueGcIter.buf_cap - 1] = 0xc3;
    gc_it.ring.buf[0] = 0xa9;
    gc_it.finish_input();

    var gc_buf: [8]u8 = undefined;
    const gc = gc_it.next().item;
    try std.testing.expectEqualStrings("\u{00e9}", gc.bytes.flatten(&gc_buf));
}

test "surface_write_utf8 ascii run respects wrapping ofs" {
    var r = try Render.init(undefined, std.testing.allocator);
    defer r.deinit();

    const grid = try r.grid_create();
    try r.grid_set_dimensions(grid, .{ .w = 4, .h = 1 });

    const surface = try r.surface_create();
    r.surface_set_grid(surface, grid);
    try r.surface_set_dimensions(surface, .{ .w = 4, .h = 1 });
    r.surface_set_grid_position(surface, .origin);
    r.surfaces.slice().items(.wrapping_ofs)[surface.to_idx().?] = .{ .x = 1, .y = 0 };

    const ret = try r.surface_write_utf8(surface, .origin, "abcd");
    try std.testing.expectEqual(@as(usize, 4), ret.bytes);

    try std.testing.expectEqual(@as(u16, 'd'), r.grid_get_cell_char(grid, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(u16, 'a'), r.grid_get_cell_char(grid, .{ .x = 1, .y = 0 }));
    try std.testing.expectEqual(@as(u16, 'b'), r.grid_get_cell_char(grid, .{ .x = 2, .y = 0 }));
    try std.testing.expectEqual(@as(u16, 'c'), r.grid_get_cell_char(grid, .{ .x = 3, .y = 0 }));
}

test "TrueGcIter split grapheme feed protocol" {
    var gc_it: TrueGcIter = .empty;
    try std.testing.expectEqual(3, try gc_it.feed("A\u{0300}"));
    try std.testing.expectEqual(.need_feed, gc_it.next());
    try std.testing.expectEqual(3, gc_it.ring.len);
    try std.testing.expectEqual(1, try gc_it.feed("B"));
    var gc_buf: [8]u8 = undefined;
    const first = gc_it.next().item;
    try std.testing.expectEqual(3, first.bytes.len());
    try std.testing.expectEqualStrings("A\u{0300}", first.bytes.flatten(&gc_buf));

    try std.testing.expectEqual(.need_feed, gc_it.next());
    gc_it.finish_input();
    const second = gc_it.next().item;
    try std.testing.expectEqual(1, second.wcwidth);
    try std.testing.expectEqual(1, second.bytes.len());
    try std.testing.expectEqualStrings("B", second.bytes.flatten(&gc_buf));
    try std.testing.expectEqual(.eos, gc_it.next());
}

test "TrueGcIter next_ascii keeps last byte for possible gc join" {
    var gc_it: TrueGcIter = .empty;
    try std.testing.expectEqual(3, try gc_it.feed("abc"));
    var buf: [8]u8 = undefined;
    const ascii = gc_it.next_ascii(8).?;
    try std.testing.expectEqualStrings("ab", ascii.flatten(&buf));
    try std.testing.expectEqual(1, gc_it.ring.len);
}

test "TrueGcIter keeps ring wrap grapheme whole" {
    var gc_it: TrueGcIter = .empty;
    gc_it.ring.head = TrueGcIter.buf_cap - 1;
    gc_it.ring.len = 1;
    gc_it.ring.buf[TrueGcIter.buf_cap - 1] = 'A';
    try std.testing.expectEqual(3, try gc_it.feed("\u{0300}B"));
    gc_it.finish_input();
    var gc_buf: [8]u8 = undefined;

    const gc = gc_it.next().item;
    try std.testing.expectEqualStrings("A\u{0300}", gc.bytes.flatten(&gc_buf));
}

test "TrueGcIter errors on too-long deferred grapheme" {
    var gc_it: TrueGcIter = .empty;
    var buf: [TrueGcIter.buf_cap]u8 = undefined;
    buf[0] = 0xc3;
    buf[1] = 0xa9;
    for (0..127) |i| {
        buf[2 + i * 2] = 0xcc;
        buf[3 + i * 2] = 0x80;
    }
    const fed = try gc_it.feed(&buf);
    try std.testing.expectEqual(@as(usize, TrueGcIter.buf_cap), fed);
    try std.testing.expectEqual(.need_feed, gc_it.next());
    try std.testing.expectError(error.GraphemeTooLong, gc_it.feed("\xcc\x80"));
}

test "surface_write_utf8 aggregates split feed result" {
    var r = try Render.init(undefined, std.testing.allocator);
    defer r.deinit();

    const grid = try r.grid_create();
    try r.grid_set_dimensions(grid, .{ .w = 8, .h = 1 });

    const surface = try r.surface_create();
    r.surface_set_grid(surface, grid);
    try r.surface_set_dimensions(surface, .{ .w = 8, .h = 1 });
    r.surface_set_grid_position(surface, .origin);

    const ret = try r.surface_write_utf8(surface, .origin, "ab");
    try std.testing.expectEqual(@as(usize, 2), ret.bytes);
    try std.testing.expectEqual(@as(u16, 2), ret.cells);
    try std.testing.expectEqual(.eos, ret.end);
}

pub fn surface_write_utf8(
    r: *Render,
    num: SurfaceNum,
    pos: Position,
    text: []const u8,
) !SurfaceWriteUtf8Result {
    var gc_it: TrueGcIter = .empty;
    var writer = Utf8StreamWriter.init(r, num, pos, &gc_it);
    var text_i: usize = 0;
    var bytes: usize = 0;
    var cells: u16 = 0;

    while (true) {
        const ret = try writer.write();
        bytes += ret.bytes;
        cells += ret.cells;
        switch (ret.end) {
            .need_feed => {
                if (text_i == text.len) {
                    gc_it.finish_input();
                    continue;
                }
                text_i += try gc_it.feed(text[text_i..]);
            },
            else => return .{
                .bytes = bytes,
                .cells = cells,
                .end = ret.end,
            },
        }
    }
}

fn surface_write_utf8_impl(
    r: *Render,
    num: SurfaceNum,
    writer: *Utf8StreamWriter,
) !SurfaceWriteUtf8Result {
    const pos0 = writer.pos;
    var pos = pos0;

    const s_slice = r.surfaces.slice();
    const s_dims = s_slice.items(.dims)[num.to_idx().?];
    const s_grid = s_slice.items(.grid)[num.to_idx().?];
    const s_grid_pos = s_slice.items(.grid_pos)[num.to_idx().?];
    const s_wrapping_ofs = s_slice.items(.wrapping_ofs)[num.to_idx().?];
    const s_cell_dirt = s_slice.items(.cell_dirt)[num.to_idx().?];
    const s_dirt = &s_slice.items(.dirt)[num.to_idx().?];

    const g_slice = r.grids.slice();
    const g_dims = g_slice.items(.dims)[s_grid.to_idx().?];
    const g_grid = g_slice.items(.cell_char)[s_grid.to_idx().?];

    const info = SurfaceGridInfo{
        .g_dims = g_dims,
        .s_dims = s_dims,
        .s_grid_pos = s_grid_pos,
        .s_wrapping_ofs = s_wrapping_ofs,
    };

    std.debug.assert(pos.x < s_dims.w);
    std.debug.assert(pos.y < s_dims.h);

    const s_cell_dirt_bm = BitMap.View.entire(s_cell_dirt.items, s_dims);

    var cell_count: u16 = 0;
    var byte_count: usize = 0;
    const end: SurfaceWriteUtf8Result.End = while (true) {
        if (writer.gc_iter.next_ascii(s_dims.w - pos.x)) |ascii| {
            if (info.s_wrapping_ofs.x == 0) {
                const g_pos = grid_pos_from_surface_pos(info, pos);
                const base = g_dims.w * g_pos.y + g_pos.x;

                for (ascii.a, 0..) |char, i| {
                    g_grid.items[base + i] = char;
                }
                for (ascii.b, ascii.a.len..) |char, i| {
                    g_grid.items[base + i] = char;
                }
            } else {
                var x = pos.x;
                for (ascii.a) |char| {
                    const g_pos = grid_pos_from_surface_pos(info, .{ .x = x, .y = pos.y });
                    g_grid.items[g_dims.w * g_pos.y + g_pos.x] = char;
                    x += 1;
                }
                for (ascii.b) |char| {
                    const g_pos = grid_pos_from_surface_pos(info, .{ .x = x, .y = pos.y });
                    g_grid.items[g_dims.w * g_pos.y + g_pos.x] = char;
                    x += 1;
                }
            }

            const len: u16 = @intCast(ascii.len());
            pos.x += len;
            cell_count += len;
            byte_count += ascii.len();
            if (pos.x == s_dims.w) break .row_full;
            continue;
        }

        const gc_info = switch (writer.gc_iter.next()) {
            .item => |gc_info| gc_info,
            .need_feed => break .need_feed,
            .eos => {
                break .eos;
            },
        };
        const gc = gc_info.bytes;
        std.debug.assert(gc.len() != 0);
        std.debug.assert(pos.x < g_dims.w);

        if (gc.len() == 1 and gc.first() == '\n') {
            byte_count += gc.len();
            break .newline;
        }

        if (gc.len() == 1) {
            const char = gc.first();
            std.debug.assert(char < 128);
            byte_count += gc.len();
            if (ascii_char_is_invisible(char)) continue;

            const g_pos = grid_pos_from_surface_pos(info, pos);
            g_grid.items[g_dims.w * g_pos.y + g_pos.x] = char;
            pos.x += 1;
            cell_count += 1;
        } else {
            const ecg_idx = try r.egc_pool.register_grapheme2(
                r.alloc,
                gc.a,
                gc.b,
            );
            // TODO: query mode 2027 so we know how terminal handles
            // multi-codepoint gc clusters. wcwidth is just a stand-in.
            // https://mitchellh.com/writing/grapheme-clusters-in-terminals
            // https://github.com/jameslanska/unicode-display-width?tab=readme-ov-file#how-it-works
            const width = gc_info.wcwidth;

            const max_x = @min(s_dims.w, pos.x + width);
            {
                const g_pos = grid_pos_from_surface_pos(info, pos);
                g_grid.items[g_dims.w * g_pos.y + g_pos.x] = ecg_idx + 128;
                pos.x += 1;
                cell_count += 1;
            }
            while (pos.x < max_x) {
                const g_pos = grid_pos_from_surface_pos(info, pos);
                g_grid.items[g_dims.w * g_pos.y + g_pos.x] = 0;
                pos.x += 1;
                cell_count += 1;
            }
            byte_count += gc.len();
        }

        if (pos.x == s_dims.w) {
            break .row_full;
        }
        std.debug.assert(pos.x < s_dims.w);
    };

    writer.pos.x += cell_count;

    if (cell_count != 0) {
        s_cell_dirt_bm.set_rect(.from_pos_dims(pos0, .{ .h = 1, .w = cell_count }), 1);
        s_dirt.* = .partial;
        r.surfaces_dirty = true;
    }

    return .{
        .bytes = byte_count,
        .cells = cell_count,
        .end = end,
    };
}

pub fn grid_get_cell_char(
    r: *Render,
    num: GridNum,
    pos: Position,
) u16 {
    const slice = r.grids.slice();
    const dims = slice.items(.dims)[num.to_idx().?];
    return slice.items(.cell_char)[num.to_idx().?].items[dims.w * pos.y + pos.x];
}

const SurfaceGridInfo = struct {
    g_dims: Dimensions,
    s_dims: Dimensions,
    s_grid_pos: Position,
    s_wrapping_ofs: Position,
};
fn grid_pos_from_surface_pos(info: SurfaceGridInfo, s_pos: Position) Position {
    std.debug.assert(@reduce(.And, s_pos.to_vec() < info.s_dims.to_vec()));
    const s_pos_wrapped =
        (info.s_wrapping_ofs.to_vec() + s_pos.to_vec()) % info.s_dims.to_vec();
    std.debug.assert(@reduce(.And, s_pos_wrapped < info.s_dims.to_vec()));

    const g_pos = info.s_grid_pos.to_vec() + s_pos_wrapped;
    std.debug.assert(@reduce(.And, g_pos < info.g_dims.to_vec()));

    return .{ .x = g_pos[0], .y = g_pos[1] };
}

fn ascii_char_is_invisible(char: u8) bool {
    std.debug.assert(char < 128);
    // C0 control char or DEL
    return char < 32 or char == 127;
}

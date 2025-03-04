const std = @import("std");
const uv = @import("uv");
const zg = struct {
    pub const DisplayWidth = @import("zg_DisplayWidth");
    pub const grapheme = @import("zg_grapheme");
    pub const code_point = @import("zg_code_point");
    pub const ascii = @import("zg_ascii");
};

const uv_utils = @import("./uv_utils.zig");
const MultiArrayPool = @import("./multi_array_pool.zig").MultiArrayPool;
const EgcPool = @import("./EGCPool.zig");

const upgrade_baton = uv_utils.upgrade_baton;
const downgrade_baton = uv_utils.downgrade_baton;

const Render = @This();

alloc: std.mem.Allocator,
loop: uv.Loop,
write_reqs: WriteReqPool,

is_alive: bool = false,
stdin: Tty = undefined,
stdout: Tty = undefined,

display_width_data: zg.DisplayWidth.DisplayWidthData,
egc_pool: EgcPool = .empty,
grids: Grids = .empty,
surfaces: Surfaces = .empty,
surfaces_dirty: bool = false,
flush_overdraw_bm: std.ArrayListUnmanaged(BitMap.Word) = .empty,
flush_requdraw_bm: std.ArrayListUnmanaged(BitMap.Word) = .empty,
flush_grid: GridNum = .null,
stack: std.ArrayListUnmanaged(u16) = .empty,

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
    w: u32,
    h: u32,
    pub const zero: Dimensions = .{ .w = 0, .h = 0 };
    pub fn to_vec(dims: Dimensions) @Vector(2, u32) {
        return .{ dims.w, dims.h };
    }
};
pub const Position = struct {
    x: u32,
    y: u32,
    pub const zero: Position = .{ .x = 0, .y = 0 };
    pub fn to_vec(pos: Position) @Vector(2, u32) {
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
    x: u32,
    y: u32,
    w: u32,
    h: u32,
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
    cell_char: std.ArrayListUnmanaged(u16),
    cell_bg: std.ArrayListUnmanaged(Color),
    cell_fg: std.ArrayListUnmanaged(Color),

    pub const empty: Grid = .{
        .dims = .zero,
        .cell_char = .{},
        .cell_bg = .{},
        .cell_fg = .{},
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
    screen_pos: Position = .zero,
    /// Size of the surface.
    /// This is the portion of the grid that will be used.
    dims: Dimensions = .zero,

    // For updating E to invalidate the previously rendered cells:
    flush_prev_screen_pos: Position = .zero,
    flush_prev_dims: Dimensions = .zero,

    /// Bitmap of dirty cells.
    cell_dirt: std.ArrayListUnmanaged(BitMap.Word) = .empty,
    /// Backing grid. surfaces can share larger backing grids.
    grid: GridNum = .null,
    /// Position on the backing grid.
    grid_pos: Position = .zero,
    /// Offset applied to grid_pos. Overflows wrap around our grid portion.
    wrapping_ofs: Position = .zero,

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
        vp_ofs: Position = .zero,
        vp_dims: Dimensions = .zero,

        pub fn entire(bm: []Word, bm_dims: Dimensions) View {
            return .{
                .bm = bm,
                .bm_dims = bm_dims,
                .vp_ofs = .zero,
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
        pub fn find_next_set_in_row(view: View, start_x: u32, row_y: u32) ?struct {
            x: u32,
            count: u32,
        } {
            view.assert_valid();
            std.debug.assert(row_y < view.bm_dims.h);
            std.debug.assert(start_x < view.bm_dims.w);

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
                .x = @as(u32, @intCast(bit_ofs)) + start_x,
                .count = @as(u32, @intCast(first_set_bit(
                    view.bm,
                    base_bit_ofs + bit_ofs,
                    bit_len - bit_ofs,
                    false,
                    native_endian,
                ) orelse view.vp_dims.w)),
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
        ) callconv(.Inline) Word,
    ) void {
        comptime std.debug.assert(N > 0);

        for (views) |view| {
            std.debug.assert(std.meta.eql(view.vp_dims, dest.vp_dims));
            view.assert_valid();
        }
        dest.assert_valid();

        for (0..dest.vp_dims.h) |vp_y| {
            var vp_x: u32 = 0;
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

const Tty = extern struct {
    raw_handle: uv.c.uv_tty_t,
    r: *Render,

    pub fn handle(t: *Tty) uv.Tty {
        return uv.Tty{ .handle = downgrade_baton(t, uv.c.uv_tty_t) };
    }

    pub fn fromHandle(t: uv.Tty) *Tty {
        return upgrade_baton(t.handle, Tty);
    }
};

const WriteReqPool = std.heap.MemoryPool(WriteReq);
const WriteReq = extern struct {
    req: uv.c.uv_write_t,
    r: *Render,
    buf: [128]u8,
    overflow_buf: extern struct { ptr: [*]u8, len: u32 },
};

pub fn init(alloc: std.mem.Allocator, loop: uv.Loop) !Render {
    return .{
        .alloc = alloc,
        .loop = loop,
        .write_reqs = .init(alloc),
        .display_width_data = try .init(alloc),
    };
}
pub fn deinit(r: *Render) void {
    r.flush_overdraw_bm.deinit(r.alloc);
    r.flush_requdraw_bm.deinit(r.alloc);
    r.egc_pool.deinit(r.alloc);
    r.display_width_data.deinit();
    r.write_reqs.deinit();
    r.surfaces.deinit(r.alloc);
    r.stack.deinit(r.alloc);
    r.* = undefined;
}

pub fn setup(r: *Render) !void {
    if (uv.c.uv_guess_handle(0) != uv.c.UV_TTY)
        return error.StdInNotATty;
    if (uv.c.uv_guess_handle(1) != uv.c.UV_TTY)
        return error.StdOutNotATty;

    r.stdin.r = r;
    r.stdout.r = r;
    try uv.convertError(uv.c.uv_tty_init(
        r.loop.loop,
        r.stdin.handle().handle,
        std.posix.STDIN_FILENO,
        0,
    ));
    try uv.convertError(uv.c.uv_tty_init(
        r.loop.loop,
        r.stdout.handle().handle,
        std.posix.STDOUT_FILENO,
        0,
    ));
    r.is_alive = true;

    try r.stdout.handle().setMode(.raw);

    // enter alternate screen mode
    try r.write(try r.write_req_create(), &.{"\x1B[?1049h"}, struct {
        fn cb(req: *WriteReq, status: i32) void {
            uv.convertError(status) catch unreachable;
            req.r.write_req_destroy(req);
        }
    }.cb);

    // start handling input
    try r.stdin.handle().readStart(
        struct {
            fn alloc(h: *uv.Tty, size: usize) ?[]u8 {
                return Tty.fromHandle(h.*).r.alloc.alloc(u8, size) catch |e|
                    switch (e) {
                    // libuv interprests this as an error
                    error.OutOfMemory => null,
                };
            }
        }.alloc,

        struct {
            fn read(h: *uv.Tty, nread: isize, buf: []const u8) void {
                uv.convertError(@intCast(nread)) catch |e| switch (e) {
                    error.EOF => h.loop().stop(),

                    // NOTE: actually unreachable.
                    // Not other errors documented as possible.
                    else => unreachable,
                };

                const r_ = Tty.fromHandle(h.*).r;
                if (nread > 0 and buf.len > 0) {
                    r_.handle_input(buf) catch unreachable;
                }
                r_.alloc.free(buf);
            }
        }.read,
    );
}
pub fn teardown(r: *Render) !void {
    std.debug.assert(r.is_alive);

    // leave alternate screen mode
    try r.write(try r.write_req_create(), &.{"\x1B[?1049l"}, struct {
        fn cb(req: *WriteReq, status: i32) void {
            uv.convertError(status) catch unreachable;
            req.r.write_req_destroy(req);
        }
    }.cb);

    try uv.Tty.resetMode();

    r.stdin.handle().readStop();
    r.stdin.handle().close(null);
    r.stdout.handle().close(null);
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
    const assert = std.debug.assert;

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
            .surf_pos = .zero,
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

        const assert = std.debug.assert;
        assert(std.meta.eql(src.vp_dims, dst.vp_dims));
        assert(std.meta.eql(src.vp_dims, mask.vp_dims));

        for (0..src.vp_dims.h) |y_| {
            const y: u32 = @intCast(y_);

            var start_x: u32 = 0;
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
    fixed_writer: std.io.FixedBufferStream([]align(8) u8).Writer,
    overflow_writer: std.ArrayListUnmanaged(u8).Writer,

    const WriteError = std.ArrayListUnmanaged(u8).Writer.Error;
    const Writer = std.io.Writer(OverflowingWriter, WriteError, OverflowingWriter.write);

    fn fixed_buffer_full(self: OverflowingWriter) bool {
        const pos = self.fixed_writer.context.getPos() catch unreachable;
        const end_pos = self.fixed_writer.context.getEndPos() catch unreachable;
        std.debug.assert(pos <= end_pos);
        return pos == end_pos;
    }

    pub fn write(self: OverflowingWriter, bytes: []const u8) WriteError!usize {
        if (self.fixed_buffer_full()) {
            return try self.overflow_writer.write(bytes);
        }
        return self.fixed_writer.write(bytes) catch |err| switch (err) {
            error.NoSpaceLeft => {
                return try self.overflow_writer.write(bytes);
            },
            else => unreachable,
        };
    }

    pub fn writer(self: OverflowingWriter) Writer {
        return .{ .context = self };
    }
};

fn grid_direct_draw(r: *Render, grid: Grid, mask: BitMap.View) !void {
    mask.assert_valid();
    const assert = std.debug.assert;
    assert(std.meta.eql(grid.dims, mask.vp_dims));

    var blit_req = try r.write_req_create();
    var fixed_stream = std.io.fixedBufferStream(&blit_req.buf);

    // freed on write completion
    var overflow_buf = std.ArrayListUnmanaged(u8){};

    const writer = (OverflowingWriter{
        .fixed_writer = fixed_stream.writer(),
        .overflow_writer = overflow_buf.writer(r.alloc),
    }).writer();

    var current_cursor: ?struct {
        pos: Position,
        cell_bg: Color,
        cell_fg: Color,
    } = null;
    for (0..grid.dims.h) |y_| {
        const y: u32 = @intCast(y_);

        var start_x: u32 = 0;
        while (mask.find_next_set_in_row(start_x, y)) |found| {
            assert(found.count > 0);
            assert(found.x + found.count <= grid.dims.w);

            for (found.x..(found.x + found.count)) |x_| {
                const x: u32 = @intCast(x_);

                const i = grid.dims.w * y + x;
                const cell_bg = grid.cell_bg.items[i];
                const cell_fg = grid.cell_fg.items[i];
                const cell_char = grid.cell_char.items[i];

                const need_pos, const need_cell_bg, const need_cell_fg =
                    if (current_cursor) |c| .{
                    !std.meta.eql(c.cell_fg, cell_fg),
                    !std.meta.eql(c.cell_bg, cell_bg),
                    !std.meta.eql(c.pos, .{ .x = x, .y = y }),
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
                    32...126 => |c| writer.writeByte(@intCast(c)) catch unreachable,
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

    const of_buf_slice = overflow_buf.allocatedSlice();
    blit_req.overflow_buf = .{
        .ptr = of_buf_slice.ptr,
        .len = @intCast(of_buf_slice.len),
    };

    try r.write(blit_req, &.{
        fixed_stream.getWritten(),
        overflow_buf.items,
    }, struct {
        fn cb(req: *WriteReq, status: i32) void {
            uv.convertError(status) catch unreachable;
            req.r.alloc.free(req.overflow_buf.ptr[0..req.overflow_buf.len]);
            req.r.write_req_destroy(req);
        }
    }.cb);
}

fn write_req_create(r: *Render) !*WriteReq {
    const req = try r.write_reqs.create();
    req.r = r;
    return req;
}

fn write_req_destroy(r: *Render, req: *WriteReq) void {
    r.write_reqs.destroy(req);
}

fn write(
    r: *Render,
    req: *WriteReq,
    bufs: []const []const u8,
    comptime cb: fn (req: *WriteReq, status: i32) void,
) !void {
    try r.stdout.handle().write(.{
        .req = downgrade_baton(req, uv.WriteReq.T),
    }, bufs, struct {
        fn cb_(req_: *uv.WriteReq, status: i32) void {
            @call(.always_inline, cb, .{
                upgrade_baton(req_.req, WriteReq),
                status,
            });
        }
    }.cb_);
}

pub fn tty_get_dimensions(r: *Render) !Dimensions {
    var c_w: c_int = undefined;
    var c_h: c_int = undefined;

    try uv.convertError(
        uv.c.uv_tty_get_winsize(&r.stdin.raw_handle, &c_w, &c_h),
    );
    return .{
        .w = @intCast(c_w),
        .h = @intCast(c_h),
    };
}

fn handle_input(r: *Render, buf: []const u8) !void {
    _ = r;
    _ = buf;
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

pub fn surface_draw_utf8(
    r: *Render,
    num: SurfaceNum,
    pos_: Position,
    text: []const u8,
) !void {
    var pos = pos_;

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

    // ASCII fast path
    if (zg.ascii.isAsciiOnly(text)) {
        var cell_count: u32 = 0;
        for (text) |char| {
            // is ASCII
            std.debug.assert(char < 128);
            if (ascii_char_is_invisible(char)) {
                continue;
            }

            const g_pos = grid_pos_from_surface_pos(info, pos);
            g_grid.items[g_dims.w * g_pos.y + g_pos.x] = char;
            pos.x += 1;
            cell_count += 1;
        }
        s_cell_dirt_bm.set_rect(.from_pos_dims(pos_, .{ .h = 1, .w = cell_count }), 1);
        s_dirt.* = .partial;
        r.surfaces_dirty = true;
        return;
    }

    var cell_count: u32 = 0;
    var gc_it = zg.grapheme.Iterator.init(text, &r.display_width_data.g_data);
    while (gc_it.next()) |gc| {
        std.debug.assert(gc.len != 0);
        std.debug.assert(pos.x < g_dims.w);

        const gc_bytes = gc.bytes(text);

        if (gc.len == 1) {
            const char = gc_bytes[0];
            // is ASCII
            std.debug.assert(char < 128);
            if (ascii_char_is_invisible(char)) continue;

            const g_pos = grid_pos_from_surface_pos(info, pos);
            g_grid.items[g_dims.w * g_pos.y + g_pos.x] = char;
            pos.x += 1;
            cell_count += 1;
        } else {
            const ecg_idx = try r.egc_pool.register_grapheme(
                r.alloc,
                gc_bytes,
            );

            const width = grapheme_width(
                &r.display_width_data,
                gc.bytes(text),
            );

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
        }

        // we should at most be exactly one after the last row cell
        if (pos.x == s_dims.w) break;
        std.debug.assert(pos.x < s_dims.w);
    }
    s_cell_dirt_bm.set_rect(.from_pos_dims(pos_, .{ .h = 1, .w = cell_count }), 1);
    s_dirt.* = .partial;
    r.surfaces_dirty = true;
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

fn grapheme_width(
    data: *zg.DisplayWidth.DisplayWidthData,
    gc_bytes: []const u8,
) u8 {
    // code here adapted from strWidth
    var cp_iter = zg.code_point.Iterator{ .bytes = gc_bytes };
    var gc_width: i8 = 0;

    while (cp_iter.next()) |cp| {
        var w = data.codePointWidth(cp.code);

        if (w != 0) {
            // Handle text emoji sequence.
            if (cp_iter.next()) |ncp| {
                // emoji text sequence.
                if (ncp.code == 0xFE0E) w = 1;
                if (ncp.code == 0xFE0F) w = 2;
            }

            // Only adding width of first non-zero-width code point.
            if (gc_width == 0) {
                gc_width = w;
                break;
            }
        }
    }

    return @intCast(gc_width);
}

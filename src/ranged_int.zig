const std = @import("std");

pub fn RangedInt(
    comptime tag_: @TypeOf(.enum_literal),
    comptime min_: comptime_int,
    comptime max_: comptime_int,
) type {
    const Int_ = std.math.IntFittingRange(min_, max_);
    return enum(Int_) {
        _,
        pub const tag = tag_;
        pub const min_val: @This() = @enumFromInt(min_);
        pub const max_val: @This() = @enumFromInt(max_);
        pub const Int = Int_;

        /// Runtime cast. Validated at runtime.
        pub inline fn try_cast(val: anytype) error{Overflow}!@This() {
            const val_ = if (comptime is_ranged_int(@TypeOf(val)))
                if (@This().tag == @TypeOf(val).tag)
                    val.to_int()
                else
                    @compileError("can't cast " ++
                        @tagName(@TypeOf(val).tag) ++
                        " to incompatible tag " ++
                        @tagName(@This().tag))
            else switch (@typeInfo(@TypeOf(val))) {
                .int => val,
                .comptime_int => val,
                else => @compileError("not a range-compatible type: " ++
                    @typeName(@TypeOf(val))),
            };

            if (comptime (min_ == std.math.minInt(Int) and
                max_ == std.math.maxInt(Int)))
            {
                return @enumFromInt(
                    std.math.cast(Int, val_) orelse return error.Overflow,
                );
            } else {
                return if (min_ <= val_ and val_ <= max_) @enumFromInt(
                    std.math.cast(Int, val_) orelse return error.Overflow,
                ) else error.Overflow;
            }
        }

        /// Runtime cast. Validated at runtime. Panics on error.
        pub inline fn cast(val: anytype) @This() {
            return try_cast(val) catch |err| switch (err) {
                error.Overflow => if (@inComptime())
                    @compileError(std.fmt.comptimePrint(
                        "{d} not in range {d}..={d}",
                        .{
                            if (is_ranged_int(@TypeOf(val)))
                                val.to_int()
                            else
                                val,
                            @This().min_val.to_int(),
                            @This().max_val.to_int(),
                        },
                    ))
                else
                    std.debug.panic(
                        "{d} not in range {d}..={d}",
                        .{
                            if (comptime is_ranged_int(@TypeOf(val)))
                                val.to_int()
                            else
                                val,
                            @This().min_val.to_int(),
                            @This().max_val.to_int(),
                        },
                    ),
            };
        }

        pub inline fn trunc(val: anytype) @This() {
            const val_ = if (comptime is_ranged_int(@TypeOf(val)))
                if (@This().tag == @TypeOf(val).tag)
                    val.to_int()
                else
                    @compileError("can't cast " ++
                        @tagName(@TypeOf(val).tag) ++
                        " to incompatible tag " ++
                        @tagName(@This().tag))
            else switch (@typeInfo(@TypeOf(val))) {
                .int => val,
                .comptime_int => val,
                else => @compileError("not a range-compatible type: " ++
                    @typeName(@TypeOf(val))),
            };

            return @enumFromInt(@max(
                @This().min_val.to_int(),
                @min(val_, @This().max_val.to_int()),
            ));
        }

        pub inline fn is_coercible(val: anytype) bool {
            const this_meta: RangeMeta = comptime .{
                .min_val = @This().min_val.to_int(),
                .max_val = @This().max_val.to_int(),
                .tag = @This().tag,
            };

            const meta: RangeMeta = RangeMeta.from(val) orelse return false;
            return comptime meta.coercible_to(this_meta);
        }

        /// Infallible coercion. Validated at compile time.
        pub inline fn coerce(val: anytype) @This() {
            const T = @TypeOf(val);

            const this_meta: RangeMeta = comptime .{
                .min_val = @This().min_val.to_int(),
                .max_val = @This().max_val.to_int(),
                .tag = @This().tag,
            };
            const meta: RangeMeta = RangeMeta.from(val) orelse
                @compileError("not a range-compatible type: " ++ @typeName(T));

            if (comptime !meta.coercible_to(this_meta))
                @compileError(std.fmt.comptimePrint(
                    "can't coerce {} to {}",
                    .{ meta, this_meta },
                ));

            if (!is_coercible(val))
                @compileError("BUG: is_coercible(val) is false");

            if (comptime is_ranged_int(T))
                return @enumFromInt(val.to_int())
            else
                return @enumFromInt(val);
        }

        pub inline fn retag(
            this: @This(),
            from_tag: @TypeOf(.enum_literal),
            to_tag: @TypeOf(.enum_literal),
        ) RangedInt(to_tag, min_, max_) {
            if (@This().tag != from_tag)
                @compileError("Incorrect from tag " ++ @tagName(from_tag) ++
                    ". Expected " ++ @tagName(@This().tag));
            return @enumFromInt(this.to_int());
        }

        pub fn to_int(this: @This()) Int {
            return @intFromEnum(this);
        }

        pub fn eql(this: @This(), other: @This()) bool {
            return this.to_int() == other.to_int();
        }
        pub fn min(this: @This(), other: @This()) @This() {
            return .cast(@min(this.to_int(), other.to_int()));
        }
        pub fn max(this: @This(), other: @This()) @This() {
            return .cast(@max(this.to_int(), other.to_int()));
        }
        pub fn add(this: @This(), other: @This()) @This() {
            return .cast(this.to_int() + other.to_int());
        }
        pub fn try_add(this: @This(), other: @This()) error{Overflow}!@This() {
            const res = try std.math.add(Int, this.to_int(), other.to_int());
            return @This().try_cast(res);
        }
        pub fn sub(this: @This(), other: @This()) @This() {
            return .cast(this.to_int() - other.to_int());
        }
        pub fn try_sub(this: @This(), other: @This()) error{Overflow}!@This() {
            const res = try std.math.sub(Int, this.to_int(), other.to_int());
            return @This().try_cast(res);
        }
        pub fn sub_saturating(this: @This(), other: @This()) @This() {
            // WARN: NOT TESTED OR THOUGHT OF YET FOR SIGNED INTS
            // we probably need some more comptime cases for signed ints...

            if (comptime @This().min_val.to_int() == 0) {
                return .cast(this.to_int() -| other.to_int());
            }
            return .cast(@max(
                this.to_int() -| other.to_int(),
                @This().min_val.to_int(),
            ));
        }

        pub fn format(
            this: @This(),
            w: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try this.formatNumber(w, .{});
        }

        pub fn formatNumber(
            this: @This(),
            w: *std.Io.Writer,
            number: std.fmt.Number,
        ) std.Io.Writer.Error!void {
            try w.printInt(this.to_int(), number.base, number.case, .{
                .precision = number.precision,
                .width = number.width,
                .alignment = number.alignment,
                .fill = number.fill,
            });
            // try writer.print("{d} in {}", .{
            //     this.to_int(),
            //     RangeMeta.from(this).?,
            // });
        }
    };
}

pub fn is_ranged_int(comptime T: type) bool {
    return @typeInfo(T) == .@"enum" and
        (@hasDecl(T, "min_val") and @TypeOf(T.min_val) == T) and
        (@hasDecl(T, "max_val") and @TypeOf(T.max_val) == T) and
        @hasDecl(T, "tag") and
        @hasDecl(T, "to_int");
}

const RangeMeta = struct {
    min_val: comptime_int,
    max_val: comptime_int,
    tag: ?@TypeOf(.enum_literal),

    pub fn format(
        meta: RangeMeta,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (meta.min_val == meta.max_val) {
            try w.print("{d}", .{meta.min_val});
        } else {
            try w.print("range {d}..={d}", .{ meta.min_val, meta.max_val });
        }
        if (meta.tag) |tag| {
            try w.print(" ({any})", .{tag});
        }
    }

    inline fn from(val: anytype) ?RangeMeta {
        const T = @TypeOf(val);
        return comptime if (is_ranged_int(T)) .{
            .min_val = T.min_val.to_int(),
            .max_val = T.max_val.to_int(),
            .tag = T.tag,
        } else switch (@typeInfo(T)) {
            .int => .{
                .min_val = std.math.minInt(T),
                .max_val = std.math.maxInt(T),
                .tag = null,
            },
            .comptime_int => .{
                .min_val = val,
                .max_val = val,
                .tag = null,
            },
            else => null,
        };
    }

    fn coercible_to(this: RangeMeta, to: RangeMeta) bool {
        if (this.tag) |from_tag| {
            if (to.tag) |to_tag| {
                if (from_tag != to_tag) return false;
            }
        }
        return is_subrange_of_inclusive(
            comptime_int,
            to.min_val,
            to.max_val,
            this.min_val,
            this.max_val,
        );
    }
};

fn is_subrange_of_inclusive(
    comptime T: type,
    super_min: T,
    super_max: T,
    sub_min: T,
    sub_max: T,
) bool {
    return super_min <= sub_min and
        sub_min <= sub_max and
        sub_max <= super_max;
}

const std = @import("std");

fn log(
    comptime src: std.builtin.SourceLocation,
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime msg: []const u8,
    fields: anytype,
) void {
    if (comptime @import("builtin").is_test) {
        if (@intFromEnum(level) > @intFromEnum(std.testing.log_level)) return;
    } else {
        if (comptime !std.log.logEnabled(level, scope)) return;
    }

    const RED = "\x1b[91m";
    const YELLOW = "\x1b[93m";
    const GREEN = "\x1b[92m";
    const MAGENTA = "\x1b[95m";
    const DIM = "\x1b[2m";
    const BOLD = "\x1b[1m";
    const RESET = "\x1b[0m";

    std.debug.print(
        "{[lvl]s} " ++
            "{[dim]s}{[scope]s}{[reset]s} " ++
            "{[bold]s}{[msg]s}{[reset]s}",
        .{
            .lvl = switch (level) {
                .err => BOLD ++ RED ++ "ERRO" ++ RESET,
                .warn => BOLD ++ YELLOW ++ "WARN" ++ RESET,
                .info => BOLD ++ GREEN ++ "INFO" ++ RESET,
                .debug => BOLD ++ MAGENTA ++ "DEBG" ++ RESET,
            },
            .scope = @tagName(scope),
            .msg = msg,
            .bold = BOLD,
            .dim = DIM,
            .reset = RESET,
        },
    );
    inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |field| {
        std.debug.print(" {[dim]s}{[field]s}={[reset]s}{[val]f}", .{
            .field = field,
            .val = std.json.fmt(@field(fields, field), .{}),
            .dim = DIM,
            .reset = RESET,
        });
    }
    std.debug.print(
        " {[dim]s}src=\"{[file]s}:{[line]d}:{[fn_name]s}\"{[reset]s}",
        .{
            .file = src.file,
            .line = src.line,
            .fn_name = src.fn_name,
            .dim = DIM,
            .reset = RESET,
        },
    );
    std.debug.print("\n", .{});
}

pub const noop = x: {
    const f = struct {
        pub fn f(
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            fields: anytype,
        ) void {
            _ = src;
            _ = msg;
            _ = fields;
        }
    };
    break :x .{ .err = f.f, .warn = f.f, .info = f.f, .debug = f.f };
};

pub fn scoped(comptime scope: @Type(.enum_literal)) type {
    return struct {
        pub fn err(
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            fields: anytype,
        ) void {
            @branchHint(.cold);
            log(src, .err, scope, msg, fields);
        }
        pub fn warn(
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            fields: anytype,
        ) void {
            log(src, .warn, scope, msg, fields);
        }
        pub fn info(
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            fields: anytype,
        ) void {
            log(src, .info, scope, msg, fields);
        }
        pub fn debug(
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            fields: anytype,
        ) void {
            log(src, .debug, scope, msg, fields);
        }
    };
}

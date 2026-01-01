const std = @import("std");

fn log(
    comptime src: std.builtin.SourceLocation,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime msg: []const u8,
    fields: anytype,
) !void {
    if (comptime @import("builtin").is_test) {
        if (!test_log_enabled(level, scope)) {
            @branchHint(.likely);
            return;
        }
    } else {
        if (comptime !std.log.logEnabled(level, scope)) return;
    }

    var buf: [64]u8 = undefined;
    const term = std.debug.lockStderr(&buf).terminal();
    defer std.debug.unlockStderr();

    try term.setColor(.bold);
    try term.setColor(switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    });
    try term.writer.writeAll(switch (level) {
        .err => "ERRO",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBG",
    });
    try term.setColor(.reset);

    try term.writer.writeByte(' ');
    try term.setColor(.dim);
    try term.writer.writeAll(@tagName(scope));
    try term.setColor(.reset);

    try term.writer.writeByte(' ');
    try term.setColor(.bold);
    try term.writer.writeAll(msg);
    try term.setColor(.reset);
    inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |field| {
        try term.setColor(.dim);
        try term.writer.writeByte(' ');
        try term.writer.writeAll(field);
        try term.writer.writeByte('=');
        try term.setColor(.reset);
        try term.writer.print("{f}", .{
            std.json.fmt(@field(fields, field), .{}),
        });
    }
    try term.setColor(.dim);
    try term.writer.print(" src=\"{[file]s}:{[line]d}:{[fn_name]s}\"", .{
        .file = src.file,
        .line = src.line,
        .fn_name = src.fn_name,
    });
    try term.setColor(.reset);
    try term.writer.writeByte('\n');
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

pub fn scoped(comptime scope: @EnumLiteral()) type {
    return struct {
        pub fn err(
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            fields: anytype,
        ) void {
            @branchHint(.cold);
            log(src, .err, scope, msg, fields) catch unreachable;
        }
        pub fn warn(
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            fields: anytype,
        ) void {
            log(src, .warn, scope, msg, fields) catch unreachable;
        }
        pub fn info(
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            fields: anytype,
        ) void {
            log(src, .info, scope, msg, fields) catch unreachable;
        }
        pub fn debug(
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            fields: anytype,
        ) void {
            log(src, .debug, scope, msg, fields) catch unreachable;
        }
    };
}

// HACK: we define our own copy of levels as the std version isn't usable with
//       the default test runner.
pub var testing_scope_levels: []const RuntimeScopeLevel = &.{};
pub const RuntimeScopeLevel = struct {
    scope: RuntimeScope,
    level: std.log.Level,
};
pub const RuntimeScope = enum {
    quil,
    rope,
    rope_test,
    segmented_pool,
    fuzz,
};
pub const testing_level = &std.testing.log_level;
fn test_log_enabled(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
) bool {
    for (testing_scope_levels) |scope_level| {
        if (scope_level.scope == @as(RuntimeScope, scope)) {
            return @intFromEnum(level) <= @intFromEnum(scope_level.level);
        }
    }
    return @intFromEnum(level) <= @intFromEnum(std.testing.log_level);
}

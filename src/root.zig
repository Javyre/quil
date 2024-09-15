const std = @import("std");
const uv = @import("uv");

const uv_utils = @import("./uv_utils.zig");
const Render = @import("./Render.zig");

const upgradeBaton = uv_utils.upgradeBaton;
const downgradeBaton = uv_utils.downgradeBaton;

const Error = @import("root").QuilError;

const Command = struct {
    name: []const u8,
    desc: []const u8,
    func: *fn (data: *anyopaque, q: *Quil) Error!void,
    data: *anyopaque,
};
const Commands = std.MultiArrayList(Command);

pub const Quil = struct {
    alloc: std.mem.Allocator,
    loop: uv.Loop,
    cmds: Commands = .{},
    render: Render,
    is_alive: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Quil {
        const loop = try uv.Loop.init(alloc);

        var q = Quil{
            .alloc = alloc,
            .loop = loop,
            .render = try Render.init(alloc, loop),
        };
        try q.cmds.setCapacity(alloc, 32);

        return q;
    }

    pub fn deinit(q: *Quil) void {
        std.debug.assert(!q.is_alive);

        uv.c.uv_walk(q.loop.loop, struct {
            fn cb(handle: ?*uv.c.uv_handle_t, _: ?*anyopaque) callconv(.C) void {
                std.debug.panic(
                    "Handle `{s}` still open on shutdown! This is a bug.\n",
                    .{uv.c.uv_handle_type_name(handle.?.type)},
                );
            }
        }.cb, null);
        q.loop.deinit(q.alloc);

        q.render.deinit();
        q.cmds.deinit(q.alloc);
        q.* = undefined;
    }

    fn tick(q: *Quil) !void {
        _ = q;
    }
};

/// Start the event loop and launch Quil
pub fn run(q: *Quil) !void {
    q.is_alive = true;
    defer q.is_alive = false;

    // Setup Renderer

    try q.render.setup();
    defer {
        std.debug.assert(q.render.is_alive);
        q.render.teardown() catch unreachable;
        _ = q.loop.run(.default) catch unreachable;
        std.debug.assert(!q.render.is_alive);
    }

    // Handle Signals for graceful shutdown

    const SigHandle = extern struct {
        raw_handle: uv.c.uv_signal_t = undefined,
        q: *Quil,
    };
    var sigint_handle: SigHandle = .{ .q = q };
    var sighup_handle: SigHandle = .{ .q = q };
    const sigint_raw_handle = downgradeBaton(&sigint_handle, uv.c.uv_signal_t);
    const sighup_raw_handle = downgradeBaton(&sighup_handle, uv.c.uv_signal_t);

    const handle_signal = struct {
        fn handler(raw_handle: ?*uv.c.uv_signal_t, signum: c_int) callconv(.C) void {
            const handle = upgradeBaton(raw_handle.?, SigHandle);

            switch (signum) {
                uv.c.SIGINT, uv.c.SIGHUP => handle.q.loop.stop(),
                // we haven't listened for any other signums
                else => unreachable,
            }
        }
    }.handler;

    inline for (.{
        .{ sighup_raw_handle, uv.c.SIGHUP },
        .{ sigint_raw_handle, uv.c.SIGINT },
    }) |sig| {
        try uv.convertError(uv.c.uv_signal_init(q.loop.loop, sig[0]));
        try uv.convertError(
            uv.c.uv_signal_start(sig[0], handle_signal, sig[1]),
        );
    }
    defer {
        inline for (.{ sigint_raw_handle, sighup_raw_handle }) |raw_handle| {
            std.debug.assert(uv.c.uv_is_closing(@ptrCast(raw_handle)) == 0);
            uv.c.uv_close(@ptrCast(raw_handle), null);
        }
    }

    // Run Main Loop

    _ = try q.loop.run(.default);
    // Teardown defers run here after loop.stop()
}

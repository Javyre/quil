const std = @import("std");

const uv = @import("./uv.zig");
const c = uv.c;
const MultiArrayPool = @import("./multi_array_pool.zig").MultiArrayPool;
const Render = @import("./Render.zig");
const WindowManager = @import("./WindowManager.zig");
const BufferManager = @import("./BufferManager.zig");

const BufferNum = BufferManager.BufferNum;
pub const Node = WindowManager.Node;
const ICtnrChildIdx = WindowManager.ICtnrChildIdx;

test {
    std.testing.refAllDecls(@This());
}

const upgrade_baton = uv.upgrade_baton;
const downgrade_baton = uv.downgrade_baton;

const Error = if (std.meta.fieldIndex(@import("root"), "QuilError")) |_|
    @import("root").QuilError
else
    error{};

const Command = struct {
    name: []const u8,
    desc: []const u8,
    func: *fn (data: *anyopaque, q: *Quil) Error!void,
    data: *anyopaque,
};
const Commands = MultiArrayPool(Command);

pub const Quil = struct {
    alloc: std.mem.Allocator,
    loop: *c.uv_loop_t,
    cmds: Commands = .empty,
    render: Render,
    win_manager: WindowManager,
    buf_manager: BufferManager,
    is_alive: bool = false,

    pub fn init(q: *Quil, alloc: std.mem.Allocator) !void {
        const loop = try alloc.create(c.uv_loop_t);
        try uv.unwrapErr(c.uv_loop_init(loop));

        q.* = Quil{
            .alloc = alloc,
            .loop = loop,
            .render = try .init(alloc, loop),
            .buf_manager = try .init(alloc, loop),
            .win_manager = try .init(alloc, &q.render, &q.buf_manager),
        };
    }

    pub fn deinit(q: *Quil) void {
        std.debug.assert(!q.is_alive);

        c.uv_walk(q.loop, struct {
            fn cb(handle: ?*c.uv_handle_t, _: ?*anyopaque) callconv(.c) void {
                std.debug.panic(
                    "Handle `{s}` still open on shutdown! This is a bug.\n",
                    .{c.uv_handle_type_name(handle.?.type)},
                );
            }
        }.cb, null);
        uv.unwrapErr(c.uv_loop_close(q.loop)) catch unreachable;
        q.alloc.destroy(q.loop);

        q.render.deinit();
        q.buf_manager.deinit();
        q.win_manager.deinit();
        q.cmds.deinit(q.alloc);
        q.* = undefined;
    }

    fn tick(q: *Quil) !void {
        _ = q;
    }

    //
    // ==== Public API ====
    //
    // NOTE: Functions here should validate input and return errors,
    //       the functions they call can assert valid input.
    //

    // == Buffers ==

    pub fn buf_create(q: *Quil, name: []const u8) !BufferNum {
        return try q.buf_manager.buffer_create(name);
    }
    pub fn buf_set_region(
        q: *Quil,
        buf: BufferNum,
        start: isize,
        end: isize,
        text: []const u8,
    ) !void {
        try q.buf_manager.buffer_set_region(buf, start, end, text);
    }

    // == Windows ==

    pub fn get_root_node(q: *Quil) *Node {
        return q.win_manager.main_root.?;
    }
    pub fn node_get_ctnr(q: *Quil, node: *Node) ?*Node {
        return q.win_manager.node_get_ctnr(node);
    }
    pub fn node_wrap(q: *Quil, node: *Node) !*Node {
        return q.win_manager.node_wrap(node);
    }
    pub fn ctnr_insert(
        q: *Quil,
        ctnr: *Node,
        child: *Node,
        index: ICtnrChildIdx,
    ) !void {
        try q.win_manager.ctnr_insert(ctnr, child, index);
    }
    pub fn win_create(q: *Quil) !*Node {
        return try q.win_manager.win_create();
    }
    pub fn win_get_buf(q: *Quil, win: *Node) BufferNum {
        return q.win_manager.win_get_buf(win);
    }
    pub fn win_set_buf(q: *Quil, win: *Node, buf: BufferNum) !void {
        try q.win_manager.win_set_buf(win, buf);
    }
};

/// Start the event loop and launch Quil
pub fn run(q: *Quil, setup_cb: ?fn (*Quil) Error!void) !void {
    q.is_alive = true;
    defer q.is_alive = false;

    // drive teardown requests.
    defer {
        const active_reqs_p = c.uv_run(q.loop, c.UV_RUN_DEFAULT);
        uv.unwrapErr(active_reqs_p) catch unreachable;
    }

    // Setup Renderer
    try q.render.setup();
    defer q.render.teardown() catch unreachable;

    // Setup Buffer Manager
    try q.buf_manager.setup();
    defer q.buf_manager.teardown() catch unreachable;

    // Setup Window Manager
    try q.win_manager.setup();
    defer q.win_manager.teardown() catch unreachable;

    // Handle Signals for graceful shutdown

    const SigHandle = extern struct {
        raw_handle: c.uv_signal_t = undefined,
        q: *Quil,
    };
    var sigint_handle: SigHandle = .{ .q = q };
    var sighup_handle: SigHandle = .{ .q = q };
    const sigint_raw_handle = downgrade_baton(&sigint_handle, c.uv_signal_t);
    const sighup_raw_handle = downgrade_baton(&sighup_handle, c.uv_signal_t);

    const handle_signal = struct {
        fn handler(raw_handle: ?*c.uv_signal_t, signum: c_int) callconv(.c) void {
            const handle = upgrade_baton(raw_handle.?, SigHandle);

            switch (signum) {
                c.SIGINT, c.SIGHUP => c.uv_stop(handle.q.loop),
                // we haven't listened for any other signums
                else => unreachable,
            }
        }
    }.handler;

    inline for (.{
        .{ sighup_raw_handle, c.SIGHUP },
        .{ sigint_raw_handle, c.SIGINT },
    }) |sig| {
        try uv.unwrapErr(c.uv_signal_init(q.loop, sig[0]));
        try uv.unwrapErr(
            c.uv_signal_start(sig[0], handle_signal, sig[1]),
        );
    }
    defer {
        inline for (.{ sigint_raw_handle, sighup_raw_handle }) |raw_handle| {
            std.debug.assert(c.uv_is_closing(@ptrCast(raw_handle)) == 0);
            c.uv_close(@ptrCast(raw_handle), null);
        }
    }

    try setup(q);
    if (setup_cb) |cb| {
        try cb(q);
    }

    {
        const wm = &q.win_manager;
        const dims = try q.render.tty_get_dimensions();
        try wm.tree_layout(wm.main_root.?, .zero, dims);
    }
    try q.render.flush();

    // Run Main Loop

    const active_reqs_p = c.uv_run(q.loop, c.UV_RUN_DEFAULT);
    try uv.unwrapErr(active_reqs_p);
    // _ = active_reqs_p; // we should probably log if this is nonzero
    // Teardown defers run here after loop.stop()
}

fn setup(q: *Quil) !void {
    const buf = try q.buf_create("*Scratch*");
    const win = try q.win_create();
    const root = q.get_root_node();

    std.debug.assert(root.kind == .ctnr);

    try q.ctnr_insert(root, win, 0);
    try q.win_set_buf(win, buf);
    try q.buf_set_region(buf, 0, -1,
        \\
        \\// Scratch zig buffer
        \\
    );
}

const std = @import("std");

const MultiArrayPool = @import("./multi_array_pool.zig").MultiArrayPool;
const Render = @import("./Render.zig");
const WindowManager = @import("./WindowManager.zig");
const BufferManager = @import("./BufferManager.zig");
pub const logger = @import("./log.zig");
const log = logger.scoped(.quil);

const BufferNum = BufferManager.BufferNum;
pub const Node = WindowManager.Node;
const ICtnrChildIdx = WindowManager.ICtnrChildIdx;

test {
    std.testing.refAllDecls(@This());
    _ = @import("SkipRope.zig");
}

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
    io: std.Io,
    alloc: std.mem.Allocator,
    cmds: Commands = .empty,
    render: Render,
    win_manager: WindowManager,
    buf_manager: BufferManager,
    is_alive: bool = false,

    pub fn init(q: *Quil, io: std.Io, alloc: std.mem.Allocator) !void {
        q.* = Quil{
            .io = io,
            .alloc = alloc,
            .render = try .init(io, alloc),
            .buf_manager = try .init(io, alloc),
            .win_manager = try .init(alloc, &q.render, &q.buf_manager),
        };
    }

    pub fn deinit(q: *Quil) void {
        std.debug.assert(!q.is_alive);

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
    const Static = struct {
        // TODO: consider just having a static *Quil instead.
        var io: ?std.Io = null;
        var shutdown: std.Io.Event = .unset;
    };
    Static.io = q.io;
    defer Static.io = null;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = struct {
            fn handler(sig: std.posix.SIG) callconv(.c) void {
                log.debug(@src(), "received shutdown signal", .{ .sig = sig });
                Static.shutdown.set(Static.io.?);
            }
        }.handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old_hup_act: std.posix.Sigaction = undefined;
    var old_term_act: std.posix.Sigaction = undefined;
    std.posix.sigaction(.HUP, &act, &old_hup_act);
    std.posix.sigaction(.TERM, &act, &old_term_act);
    defer {
        var old_hup_act2: std.posix.Sigaction = undefined;
        var old_term_act2: std.posix.Sigaction = undefined;
        std.posix.sigaction(.HUP, &old_hup_act, &old_hup_act2);
        std.posix.sigaction(.TERM, &old_term_act, &old_term_act2);
        std.debug.assert(std.mem.eql(
            u8,
            std.mem.asBytes(&old_hup_act2),
            std.mem.asBytes(&act),
        ));
        std.debug.assert(std.mem.eql(
            u8,
            std.mem.asBytes(&old_term_act2),
            std.mem.asBytes(&act),
        ));
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

    // Run Input Loop

    const SelectRes = union(enum) {
        shutdown: std.Io.Cancelable!void,
        input: anyerror!void,
    };
    var select_buf: [2]SelectRes = undefined;
    var select: std.Io.Select(SelectRes) = .init(q.io, &select_buf);

    select.concurrent(.shutdown, std.Io.Event.wait, .{
        &Static.shutdown,
        q.io,
    }) catch unreachable;
    select.concurrent(.input, input_loop, .{q}) catch unreachable;

    defer while (select.cancel()) |res| switch (res) {
        .shutdown => |r| r catch |e| switch (e) {
            std.Io.Cancelable.Canceled => {},
        },
        .input => |r| r catch |e| switch (e) {
            std.Io.Cancelable.Canceled => {},
            else => unreachable,
        },
    };

    switch (try select.await()) {
        .shutdown => |r| r catch |e| switch (e) {
            std.Io.Cancelable.Canceled => {},
        },
        .input => |r| if (r) {
            log.err(@src(), "shutting down due to EOF", .{});
        } else |e| switch (e) {
            std.Io.Cancelable.Canceled => {},
            else => unreachable,
        },
    }
}

fn input_loop(q: *Quil) !void {
    var input_buf: [128]u8 = undefined;
    var input_reader = q.render.stdin.readerStreaming(q.io, &input_buf);
    while (input_reader.interface.takeByte() catch |e| switch (e) {
        std.Io.Reader.Error.EndOfStream => null,
        std.Io.Reader.Error.ReadFailed => return input_reader.err.?,
    }) |byte| {
        log.debug(@src(), "input", .{ .byte = &[_]u8{byte} });
    }
    log.debug(@src(), "EOF", .{});
}

fn setup(q: *Quil) !void {
    {
        // SPONGE: delete this once we refer to skiprope outside of just tests
        const SkipRope = @import("SkipRope.zig");
        var r: SkipRope = .empty;
        defer r.deinit(q.alloc);
        try r.insert(q.alloc, 0, "testing 123");
        r.delete(1, 3);
    }

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

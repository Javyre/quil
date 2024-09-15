const std = @import("std");
const uv = @import("uv");

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

fn assertBaton(
    comptime Downgraded: type,
    comptime UpgradedStruct: type,
) void {
    switch (@typeInfo(UpgradedStruct)) {
        .@"struct" => |s| {
            if (s.layout != .@"extern") {
                @compileError("Upgraded type must be a C-ABI struct");
            }
            if (s.fields.len < 1) {
                @compileError("Upgraded type must be a struct with at least one field.");
            }
            if (s.fields[0].type != Downgraded) {
                @compileError("Upgraded type must be a struct with the first field embedding the downgraded type.");
            }
        },
        else => {
            @compileError("Upgraded type must be a struct");
        },
    }
}

fn upgradeBaton(ptr: anytype, comptime UpgradedStruct: type) R: {
    var info = @typeInfo(@TypeOf(ptr));
    info.pointer.child = UpgradedStruct;
    break :R @Type(info);
} {
    const Downgraded = switch (@typeInfo(@TypeOf(ptr))) {
        .pointer => |p| p.child,
        else => {
            @compileError("ptr must be a pointer");
        },
    };
    assertBaton(Downgraded, UpgradedStruct);
    return @ptrCast(ptr);
}

fn downgradeBaton(ptr: anytype, comptime Downgraded: type) R: {
    var info = @typeInfo(@TypeOf(ptr));
    info.pointer.child = Downgraded;
    break :R @Type(info);
} {
    const UpgradedStruct = switch (@typeInfo(@TypeOf(ptr))) {
        .pointer => |p| p.child,
        else => {
            @compileError("ptr must be a pointer");
        },
    };
    assertBaton(Downgraded, UpgradedStruct);
    return @ptrCast(ptr);
}

const Render = struct {
    alloc: std.mem.Allocator,
    loop: uv.Loop,
    write_reqs: WriteReqPool,

    is_alive: bool = false,
    stdin: Tty = undefined,
    stdout: Tty = undefined,

    const Tty = extern struct {
        raw_handle: uv.c.uv_tty_t,
        r: *Render,

        pub fn handle(t: *Tty) uv.Tty {
            return uv.Tty{ .handle = downgradeBaton(t, uv.c.uv_tty_t) };
        }

        pub fn fromHandle(t: uv.Tty) *Tty {
            return upgradeBaton(t.handle, Tty);
        }
    };

    const WriteReqPool = std.heap.MemoryPool(WriteReq);
    const WriteReq = extern struct {
        req: uv.c.uv_write_t,
        r: *Render,
    };

    pub fn init(alloc: std.mem.Allocator, loop: uv.Loop) !Render {
        return .{
            .alloc = alloc,
            .loop = loop,
            .write_reqs = WriteReqPool.init(alloc),
        };
    }
    pub fn deinit(r: *Render) void {
        r.write_reqs.deinit();
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
        try r.write(&.{"\x1B[?1049h"}, struct {
            fn cb(req: *WriteReq, status: i32) void {
                uv.convertError(status) catch unreachable;
                req.r.write_reqs.destroy(req);
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
                        r_.handleInput(buf) catch unreachable;
                    }
                    r_.alloc.free(buf);
                }
            }.read,
        );
    }
    pub fn teardown(r: *Render) !void {
        // leave alternate screen mode
        try r.write(&.{"\x1B[?1049l"}, struct {
            fn cb(req: *WriteReq, status: i32) void {
                uv.convertError(status) catch unreachable;
                req.r.write_reqs.destroy(req);
            }
        }.cb);

        try uv.Tty.resetMode();

        r.stdin.handle().readStop();
        r.stdin.handle().close(null);
        r.stdout.handle().close(null);
        r.is_alive = false;
    }

    fn write(
        r: *Render,
        bufs: []const []const u8,
        comptime cb: fn (req: *WriteReq, status: i32) void,
    ) !void {
        const req = try r.write_reqs.create();
        req.r = r;
        //std.debug.print("POINTER {}\n", .{req});

        try r.stdout.handle().write(.{
            .req = downgradeBaton(req, uv.WriteReq.T),
        }, bufs, struct {
            fn cb_(req_: *uv.WriteReq, status: i32) void {
                @call(.always_inline, cb, .{
                    upgradeBaton(req_.req, WriteReq),
                    status,
                });
            }
        }.cb_);
    }

    fn handleInput(r: *Render, buf: []const u8) !void {
        _ = r;
        _ = buf;
    }
};

const std = @import("std");
const uv = @import("uv");

const uv_utils = @import("./uv_utils.zig");
const upgradeBaton = uv_utils.upgradeBaton;
const downgradeBaton = uv_utils.downgradeBaton;

const Render = @This();

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

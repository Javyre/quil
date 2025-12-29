const std = @import("std");
const quil = @import("quil");

pub const QuilError = error{};
const Error = QuilError;

pub fn main() !void {
    var gpa_: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer std.debug.assert(gpa_.deinit() == .ok);
    const gpa = gpa_.allocator();
    var rt: std.Io.Threaded = .init(gpa, .{});
    const io = rt.io();

    var q: quil.Quil = undefined;
    try q.init(io, gpa);
    defer q.deinit();

    try quil.run(&q, setup);
}

// This code runs right before the starting the event loop.
fn setup(q: *quil.Quil) Error!void {
    _ = q;
    // try vsplit(q, q.get_focused_win());
    //
    // q.cmd_map(struct {
    //     fn write_buf(self: *@This(), qq: *quil.Quil) !void {
    //         _ = self;
    //         _ = qq;
    //     }
    // }{});
    //
    // q.key_map("SPC f s", .write_buf);
}

fn vsplit(q: *quil.Quil, win: *quil.Node) Error!*quil.Node {
    const buf = q.win_get_buf(win);
    const nwin = q.win_create();
    q.win_set_buf(nwin, buf);

    const ctnr =
        try q.node_get_ctnr(win) orelse
        try q.node_wrap(win, .hori);
    q.ctnr_insert(ctnr, nwin, -1);
    q.node_set_width(nwin, 10);
    return nwin;
}

const std = @import("std");
const quil = @import("quil");

pub const QuilError = error{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var q: quil.Quil = undefined;
    try q.init(gpa.allocator());
    defer q.deinit();

    // setup(&q);

    try quil.run(&q);
}

// This code runs before the starting the event loop.
fn setup(q: *quil.Quil) !void {
    const win = q.win_at_point(null);
    const buf = q.win_buf(win);
    const nwin = q.win_split(win, .hori);
    q.win_set_buf(nwin, buf);
    q.win_set_width(nwin, 10);

    q.def_cmd(struct {
        fn write_buf(self: *@This(), qq: *quil.Quil) !void {
            _ = self;
            _ = qq;
        }
    }{});

    q.map("SPC f s", .write_buf);
}

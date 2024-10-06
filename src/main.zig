const std = @import("std");
const quil = @import("quil");

pub const QuilError = error{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // var loga = std.heap.LoggingAllocator(.info, .err).init(gpa.allocator());
    // var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    var q: quil.Quil = undefined;
    try q.init(gpa.allocator());
    defer q.deinit();

    // q.def_cmd(struct {
    //     fn write_buf(self: *@This(), qq: *quil.Quil) !void {
    //         _ = self;
    //         _ = qq;
    //     }
    // }{});
    //
    // q.map("SPC f s", .write_buf);

    try quil.run(&q);
}

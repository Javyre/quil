const std = @import("std");
const uv = @import("uv");
const Render = @import("./Render.zig");
const BufferManager = @import("./BufferManager.zig");

const WindowManager = @This();

const UCtnrChildIdx = u10;
const ICtnrChildIdx = i11;

alloc: std.mem.Allocator,
render: *Render,
buf_manager: *BufferManager,

node_pool: std.heap.MemoryPool(Node),
main_root: ?*Node = null,
floating_roots: std.ArrayListUnmanaged(*Node) = .empty,

pub const Node = struct {
    dims: Render.Dimensions,
    /// Owning reference to next sibling node
    next_sibling: ?*Node = null,

    /// backref to parent ctnr or backing grid for the tree.
    parent: union(enum) {
        // Since tiled surfaces can't overlap, they can share a common
        // backing grid.
        // TODO: add pos here for floating trees
        root_grid: Render.GridNum,
        ctnr: *Node,
    },

    kind: union(enum) {
        ctnr: Container,
        win: Window,
    },

    const Container = struct {
        dir: enum { horizontal, vertical },
        /// Owning reference to first child node
        first_child: ?*Node = null,
    };

    const Window = struct {
        buf: BufferManager.BufferNum,
        surface: Render.SurfaceNum,
    };

    pub const empty_root_ctnr: Node = .{
        .dims = .zero,
        .parent = .{ .root_grid = .null },
        .kind = .{
            .ctnr = .{ .dir = .hori },
        },
    };

    pub const empty_root_win: Node = .{
        .dims = .zero,
        .parent = .{ .root_grid = .null },
        .kind = .{
            .win = .{
                .surface = .null,
                .buf = .null,
            },
        },
    };
};

pub fn init(
    alloc: std.mem.Allocator,
    r: *Render,
    bm: *BufferManager,
) !WindowManager {
    return .{
        .alloc = alloc,
        .render = r,
        .buf_manager = bm,
        .node_pool = .init(alloc),
    };
}

pub fn deinit(wm: *WindowManager) void {
    wm.node_pool.deinit();
    wm.floating_roots.deinit(wm.alloc);
    wm.* = undefined;
}

pub fn setup(wm: *WindowManager) !void {
    const root = try wm.node_pool.create();
    wm.main_root = root;
    root.* = .empty_root_ctnr;

    // TODO: floating trees
    // - don't forget that since we share backing grids, we need to
    //   change the backing grid when a window is reparented to a
    //   new tree.
    // - IDEA: any node with no parent is a floating tree root.
    //         embed the floating tree pos+dims in the root node?
    //         This way there can't be any orphaned nodes. :)
}

pub fn teardown(wm: *WindowManager) !void {
    _ = wm;
}

const LayoutStack = std.BoundedArray(struct {
    node: *Node,
    new_dims: Render.Dimensions,
    new_grid_pos: Render.Position,
}, 24);

pub fn tree_layout(
    wm: *WindowManager,
    root: *Node,
    new_pos: Render.Position,
    new_dims: Render.Dimensions,
) !void {
    std.debug.assert(root.parent == .root_grid);
    try wm.render.grid_set_dimensions(
        root.parent.root_grid.backing_grid,
        new_dims,
    );
    // screen_pos = grid_pos + screen_pos_ofs
    const screen_pos_ofs = new_pos;

    var stack: LayoutStack = try .init(0);

    stack.appendAssumeCapacity(.{
        .node = root,
        .new_dims = new_dims,
        .new_grid_pos = new_pos,
    });

    while (stack.popOrNull()) |s| {
        switch (s.node.kind) {
            .ctnr => |*ctnr| {
                try wm.layout_tiled_ctnr(
                    &stack,
                    s.node,
                    ctnr,
                    s.new_dims,
                    s.new_grid_pos,
                );
            },
            .win => |*win| {
                try wm.layout_tiled_window(
                    s.node,
                    win,
                    s.new_dims,
                    s.new_grid_pos,
                    screen_pos_ofs,
                );
            },
        }
        s.node.dims = s.new_dims;
    }
}

fn layout_tiled_ctnr(
    wm: *WindowManager,
    stack: *LayoutStack,
    node: *Node,
    ctnr: *Node.Container,
    new_dims: Render.Dimensions,
    new_grid_pos: Render.Position,
) !void {
    _ = wm;

    const main_dim_old = switch (ctnr.dir) {
        .horizontal => node.dims.w,
        .vertical => node.dims.h,
    };

    const main_dim_new, const other_dim_new, //
    const main_coord_new, const other_coord_new =
        switch (ctnr.dir) {
        .horizontal => .{
            new_dims.w,     new_dims.h,
            new_grid_pos.x, new_grid_pos.y,
        },
        .vertical => .{
            new_dims.h,     new_dims.w,
            new_grid_pos.y, new_grid_pos.x,
        },
    };

    var main_dim_remainder = main_dim_new;
    var next_main_coord = main_coord_new;
    var next_child = ctnr.first_child;
    while (next_child) |child| : (next_child = child.next_sibling) {
        var child_dims: Render.Dimensions = undefined;
        var child_pos: Render.Position = undefined;
        const child_main_dim, const child_other_dim, //
        const child_main_coord, const child_other_coord =
            switch (ctnr.dir) {
            .horizontal => .{
                &child_dims.w, &child_dims.h,
                &child_pos.x,  &child_pos.y,
            },
            .vertical => .{
                &child_dims.h, &child_dims.w,
                &child_pos.y,  &child_pos.x,
            },
        };

        const child_main_dim_new = if (child.next_sibling == null)
            // use remainder for last element;
            main_dim_remainder
        else
            @divTrunc((child_main_dim.* * main_dim_new), main_dim_old);

        std.debug.assert(child_main_dim.* <= main_dim_new);
        main_dim_remainder -= child_main_dim.*;

        const child_main_coord_new = next_main_coord;
        next_main_coord += child_main_dim_new;

        child_main_dim.* = child_main_dim_new;
        child_other_dim.* = other_dim_new;

        child_main_coord.* = child_main_coord_new;
        child_other_coord.* = other_coord_new;

        stack.appendAssumeCapacity(.{
            .node = child,
            .new_dims = child_dims,
            .new_grid_pos = child_pos,
        });
    }
    std.debug.assert(main_dim_remainder == 0);
}

fn layout_tiled_window(
    wm: *WindowManager,
    node: *Node,
    window: *Node.Window,
    new_dims: Render.Dimensions,
    new_grid_pos: Render.Position,
    screen_pos_ofs: Render.Position,
) !void {
    _ = node;
    try wm.render.surface_set_dimensions(window.surface, new_dims);
    wm.render.surface_set_grid_position(window.surface, new_grid_pos);
    wm.render.surface_set_screen_position(window.surface, .{
        .x = new_grid_pos.x + screen_pos_ofs.x,
        .y = new_grid_pos.y + screen_pos_ofs.y,
    });

    try wm.redraw_window(window, new_dims);
}

fn redraw_window(
    wm: *WindowManager,
    window: *Node.Window,
    dims: Render.Dimensions,
) !void {
    // TODO: impl word/text wrapping

    const buf_lines = wm.buf_manager.buffer_get_lines(window.buf).items;
    const buf_draw_height = @min(dims.h, buf_lines.len);

    for (
        0..,
        buf_lines[0..buf_draw_height],
    ) |y, line| {
        try wm.render.surface_draw_utf8(window.surface, .{
            .x = 0,
            .y = @intCast(y),
        }, line.items);
    }
}

pub fn win_create(wm: *WindowManager) !*Node {
    const node = try wm.node_pool.create();
    // at least temporarily it's own tree. until it is inserted
    // somewhere.
    node.* = .empty_root_win;
    return node;
}

pub fn ctnr_create(wm: *WindowManager) !*Node {
    const node = try wm.node_pool.create();
    // at least temporarily it's own tree. until it is inserted
    // somewhere.
    node.* = .empty_root_ctnr;
    return node;
}

pub fn win_get_buf(
    wm: *WindowManager,
    win: *Node,
) BufferManager.BufferNum {
    _ = wm;
    std.debug.assert(win.kind == .win);
    return win.kind.win.buf;
}

pub fn win_set_buf(
    wm: *WindowManager,
    win: *Node,
    buf: BufferManager.BufferNum,
) !void {
    _ = wm;
    std.debug.assert(win.kind == .win);
    win.kind.win.buf = buf;
}

pub fn node_get_ctnr(wm: *WindowManager, node: *Node) ?*Node {
    _ = wm;
    switch (node.parent) {
        .root_grid => return null,
        .ctnr => |ctnr| return ctnr,
    }
}

pub fn node_get_root(node: *Node) *Node {
    var cur = node;
    while (cur.parent != .root_grid) : (cur = cur.parent.ctnr) {}
    std.debug.assert(cur.parent == .root_grid);
    return cur;
}

/// Ensure the win node has a surface pointing to a valid root grid.
fn win_ensure_surface_grid(wm: *WindowManager, win: *Node) !void {
    std.debug.assert(win.kind == .win);

    const root = node_get_root(win);
    const grid = if (root.parent.root_grid != .null)
        root.parent.root_grid
    else x: {
        const g = try wm.render.grid_create();
        root.parent.root_grid = g;
        break :x g;
    };

    if (win.kind.win.surface == .null) {
        const surface = try wm.render.surface_create();
        wm.render.surface_set_grid(surface, grid);
        win.kind.win.surface = surface;
    } else if (wm.render.surface_get_grid(win.kind.win.surface) != grid) {
        wm.render.surface_set_grid(win.kind.win.surface, grid);
    }
}

pub fn node_wrap(wm: *WindowManager, node: *Node) !*Node {
    const wrapper = try wm.ctnr_create();
    try wm.node_swap(node, wrapper);
    try wm.ctnr_insert(wrapper, node, 0);
    return wrapper;
}

pub fn node_swap(wm: *WindowManager, node: *Node, other: *Node) !void {
    // swap the poiters towards us
    std.mem.swap(
        *Node,
        node_swap__parent_ptr(wm, node),
        node_swap__parent_ptr(wm, other),
    );
    // swap the parent backrefs
    std.mem.swap(@TypeOf(node.parent), &node.parent, &other.parent);
}

fn node_swap__parent_ptr(wm: *WindowManager, node: *Node) **Node {
    switch (node.parent) {
        .root_grid => return if (wm.main_root == node)
            &wm.main_root.?
        else
            &wm.floating_roots.items[
                std.mem.indexOfScalar(
                    *Node,
                    wm.floating_roots.items,
                    node,
                ).?
            ],

        .ctnr => |ctnr| {
            var cur_p = if (ctnr.kind.ctnr.first_child) |*c| c else null;
            while (cur_p) |cur| : ({
                cur_p = if (cur.*.next_sibling) |*c| c else null;
            }) {
                if (cur.* == node) {
                    return cur;
                }
            }
            @panic("node not found in ctnr");
        },
    }
}

pub fn ctnr_get_child_idx(wm: *WindowManager, ctnr: *Node, child: *Node) ?ICtnrChildIdx {
    _ = wm;
    const idx: UCtnrChildIdx = 0;
    var prev_child = ctnr.kind.ctnr.first_child;
    while (prev_child) |cur| : ({
        prev_child = cur.next_sibling;
        idx += 1;
    }) {
        if (cur == child) return idx;
    }
    return null;
}

pub fn ctnr_insert(
    wm: *WindowManager,
    ctnr: *Node,
    child: *Node,
    idx_: ICtnrChildIdx,
) !void {
    std.debug.assert(ctnr.kind == .ctnr);
    const idx: UCtnrChildIdx = if (idx_ >= 0)
        @intCast(idx_)
    else
        ctnr_child_idx_from_back(ctnr, @intCast((-idx_) - 1));

    if (idx == 0) {
        const first_child = ctnr.kind.ctnr.first_child;
        ctnr.kind.ctnr.first_child = child;
        child.next_sibling = first_child;
    } else {
        var i: UCtnrChildIdx = 0;
        var done = false;
        {
            var prev_child = ctnr.kind.ctnr.first_child;
            while (prev_child) |cur| : ({
                prev_child = cur.next_sibling;
                i += 1;
            }) {
                std.debug.assert(i <= idx);
                if (i + 1 == idx) {
                    const next = cur.next_sibling;
                    cur.next_sibling = child;
                    child.next_sibling = next;
                    done = true;
                    break;
                }
            }
        }
        // index out of bounds
        std.debug.assert(done);
    }

    if (child.parent == .root_grid and
        child.parent.root_grid != .null)
    {
        wm.render.grid_destroy(child.parent.root_grid);
    }
    child.parent = .{ .ctnr = ctnr };
    if (child.kind == .win) {
        try wm.win_ensure_surface_grid(child);
    }
}

/// Map [0, len] to [len, 0]
fn ctnr_child_idx_from_back(
    ctnr: *Node,
    idx: UCtnrChildIdx,
) UCtnrChildIdx {
    std.debug.assert(ctnr.kind == .ctnr);
    var child_count: UCtnrChildIdx = 0;
    var prev_child = ctnr.kind.ctnr.first_child;
    while (prev_child) |cur| : ({
        prev_child = cur.next_sibling;
        child_count += 1;
    }) {}
    std.debug.assert(child_count <= idx);

    return child_count - idx;
}

const std = @import("std");
const uv = @import("uv");
const Render = @import("./Render.zig");

const WindowManager = @This();

alloc: std.mem.Allocator,
render: *Render,

node_pool: std.heap.MemoryPool(Node),
main_tree: ?Tree = null,

const Tree = struct {
    backing_grid: Render.GridNum,
    root: *Node,
};

const Node = struct {
    dims: Render.Dimensions,
    /// Owning reference to next sibling node
    next_sibling: ?*Node = null,

    kind: union(enum) {
        split: Split,
        window: Window,
    },

    const Split = struct {
        dir: enum { horizontal, vertical },
        /// Owning reference to first child node
        first_child: ?*Node = null,
    };

    const Window = struct {
        // buf: *Buffer,
        surface: Render.SurfaceNum,
    };
};

pub fn init(alloc: std.mem.Allocator, r: *Render) !WindowManager {
    return .{
        .alloc = alloc,
        .render = r,
        .node_pool = .init(alloc),
    };
}

pub fn deinit(wm: *WindowManager) void {
    wm.node_pool.deinit();
    wm.* = undefined;
}

pub fn setup(wm: *WindowManager) !void {
    const r = wm.render;

    // setup main tiled tree with default window
    {
        const root = try wm.node_pool.create();
        const grid = try wm.render.grid_create();
        const surface = try wm.render.surface_create();
        wm.render.surface_set_grid(surface, grid);
        wm.main_tree = .{
            .root = root,
            .backing_grid = grid,
        };
        root.* = .{
            .dims = .zero,
            .kind = .{
                .window = .{
                    .surface = surface,
                },
            },
        };

        const dims = try r.tty_get_dimensions();
        try wm.tree_layout(&wm.main_tree.?, .zero, dims);
    }

    // TODO: floating trees
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
    tree: *Tree,
    new_pos: Render.Position,
    new_dims: Render.Dimensions,
) !void {
    try wm.render.grid_set_dimensions(tree.backing_grid, new_dims);
    // screen_pos = grid_pos + screen_pos_ofs
    const screen_pos_ofs = new_pos;

    var stack: LayoutStack = try .init(0);

    stack.appendAssumeCapacity(.{
        .node = tree.root,
        .new_dims = new_dims,
        .new_grid_pos = new_pos,
    });

    while (stack.popOrNull()) |s| {
        switch (s.node.kind) {
            .split => |*split| {
                try wm.layout_tiled_split(
                    &stack,
                    s.node,
                    split,
                    s.new_dims,
                    s.new_grid_pos,
                );
            },
            .window => |*window| {
                try wm.layout_tiled_window(
                    s.node,
                    window,
                    s.new_dims,
                    s.new_grid_pos,
                    screen_pos_ofs,
                );
            },
        }
        s.node.dims = s.new_dims;
    }
}

fn layout_tiled_split(
    wm: *WindowManager,
    stack: *LayoutStack,
    node: *Node,
    split: *Node.Split,
    new_dims: Render.Dimensions,
    new_grid_pos: Render.Position,
) !void {
    _ = wm;

    const main_dim_old = switch (split.dir) {
        .horizontal => node.dims.w,
        .vertical => node.dims.h,
    };

    const main_dim_new, const other_dim_new, //
    const main_coord_new, const other_coord_new =
        switch (split.dir) {
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
    var next_child = split.first_child;
    while (next_child) |child| : (next_child = child.next_sibling) {
        var child_dims: Render.Dimensions = undefined;
        var child_pos: Render.Position = undefined;
        const child_main_dim, const child_other_dim, //
        const child_main_coord, const child_other_coord =
            switch (split.dir) {
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

    wm.render.surface_set_dimensions(window.surface, new_dims);
    wm.render.surface_set_grid_position(window.surface, new_grid_pos);
    wm.render.surface_set_screen_position(window.surface, .{
        .x = new_grid_pos.x + screen_pos_ofs.x,
        .y = new_grid_pos.y + screen_pos_ofs.y,
    });
}

// pub fn setup_window(wm: *WindowManager, win: *Window) !void {
//     win.* = .{};
// }

// pub fn createWindow(wm: *WindowManager, r: *Render) !*Window {
//     // const insertion_point = if (wm.root_node) |node| node else wm.root_node.;
// }

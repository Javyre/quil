fn assert_baton(
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

pub fn upgrade_baton(ptr: anytype, comptime UpgradedStruct: type) R: {
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
    assert_baton(Downgraded, UpgradedStruct);
    return @ptrCast(ptr);
}

pub fn downgrade_baton(ptr: anytype, comptime Downgraded: type) R: {
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
    assert_baton(Downgraded, UpgradedStruct);
    return @ptrCast(ptr);
}

const std = @import("std");

pub const c = @cImport({
    @cInclude("uv.h");
});

pub fn assert_baton(
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

pub fn bufFromSlice(slice: []const u8) c.uv_buf_t {
    return .{
        .base = @ptrCast(@constCast(slice.ptr)),
        .len = slice.len,
    };
}

pub fn sliceFromBuf(buf: c.uv_buf_t) []const u8 {
    return @as([*]const u8, @ptrCast(buf.base))[0..buf.len];
}

pub const Error = error{
    E2BIG,
    EACCES,
    EADDRINUSE,
    EADDRNOTAVAIL,
    EAFNOSUPPORT,
    EAGAIN,
    EAI_ADDRFAMILY,
    EAI_AGAIN,
    EAI_BADFLAGS,
    EAI_BADHINTS,
    EAI_CANCELED,
    EAI_FAIL,
    EAI_FAMILY,
    EAI_MEMORY,
    EAI_NODATA,
    EAI_NONAME,
    EAI_OVERFLOW,
    EAI_PROTOCOL,
    EAI_SERVICE,
    EAI_SOCKTYPE,
    EALREADY,
    EBADF,
    EBUSY,
    ECANCELED,
    ECHARSET,
    ECONNABORTED,
    ECONNREFUSED,
    ECONNRESET,
    EDESTADDRREQ,
    EEXIST,
    EFAULT,
    EFBIG,
    EHOSTUNREACH,
    EINTR,
    EINVAL,
    EIO,
    EISCONN,
    EISDIR,
    ELOOP,
    EMFILE,
    EMSGSIZE,
    ENAMETOOLONG,
    ENETDOWN,
    ENETUNREACH,
    ENFILE,
    ENOBUFS,
    ENODEV,
    ENOENT,
    ENOMEM,
    ENONET,
    ENOPROTOOPT,
    ENOSPC,
    ENOSYS,
    ENOTCONN,
    ENOTDIR,
    ENOTEMPTY,
    ENOTSOCK,
    ENOTSUP,
    EPERM,
    EPIPE,
    EPROTO,
    EPROTONOSUPPORT,
    EPROTOTYPE,
    ERANGE,
    EROFS,
    ESHUTDOWN,
    ESPIPE,
    ESRCH,
    ETIMEDOUT,
    ETXTBSY,
    EXDEV,
    UNKNOWN,
    EOF,
    ENXIO,
    EHOSTDOWN,
    EREMOTEIO,
    ENOTTY,
    EFTYPE,
    EILSEQ,
    ESOCKTNOSUPPORT,
};

pub fn unwrapErr(err: c_int) Error!void {
    if (err >= 0) return;
    return switch (err) {
        c.UV_E2BIG => Error.E2BIG,
        c.UV_EACCES => Error.EACCES,
        c.UV_EADDRINUSE => Error.EADDRINUSE,
        c.UV_EADDRNOTAVAIL => Error.EADDRNOTAVAIL,
        c.UV_EAFNOSUPPORT => Error.EAFNOSUPPORT,
        c.UV_EAGAIN => Error.EAGAIN,
        c.UV_EAI_ADDRFAMILY => Error.EAI_ADDRFAMILY,
        c.UV_EAI_AGAIN => Error.EAI_AGAIN,
        c.UV_EAI_BADFLAGS => Error.EAI_BADFLAGS,
        c.UV_EAI_BADHINTS => Error.EAI_BADHINTS,
        c.UV_EAI_CANCELED => Error.EAI_CANCELED,
        c.UV_EAI_FAIL => Error.EAI_FAIL,
        c.UV_EAI_FAMILY => Error.EAI_FAMILY,
        c.UV_EAI_MEMORY => Error.EAI_MEMORY,
        c.UV_EAI_NODATA => Error.EAI_NODATA,
        c.UV_EAI_NONAME => Error.EAI_NONAME,
        c.UV_EAI_OVERFLOW => Error.EAI_OVERFLOW,
        c.UV_EAI_PROTOCOL => Error.EAI_PROTOCOL,
        c.UV_EAI_SERVICE => Error.EAI_SERVICE,
        c.UV_EAI_SOCKTYPE => Error.EAI_SOCKTYPE,
        c.UV_EALREADY => Error.EALREADY,
        c.UV_EBADF => Error.EBADF,
        c.UV_EBUSY => Error.EBUSY,
        c.UV_ECANCELED => Error.ECANCELED,
        c.UV_ECHARSET => Error.ECHARSET,
        c.UV_ECONNABORTED => Error.ECONNABORTED,
        c.UV_ECONNREFUSED => Error.ECONNREFUSED,
        c.UV_ECONNRESET => Error.ECONNRESET,
        c.UV_EDESTADDRREQ => Error.EDESTADDRREQ,
        c.UV_EEXIST => Error.EEXIST,
        c.UV_EFAULT => Error.EFAULT,
        c.UV_EFBIG => Error.EFBIG,
        c.UV_EHOSTUNREACH => Error.EHOSTUNREACH,
        c.UV_EINTR => Error.EINTR,
        c.UV_EINVAL => Error.EINVAL,
        c.UV_EIO => Error.EIO,
        c.UV_EISCONN => Error.EISCONN,
        c.UV_EISDIR => Error.EISDIR,
        c.UV_ELOOP => Error.ELOOP,
        c.UV_EMFILE => Error.EMFILE,
        c.UV_EMSGSIZE => Error.EMSGSIZE,
        c.UV_ENAMETOOLONG => Error.ENAMETOOLONG,
        c.UV_ENETDOWN => Error.ENETDOWN,
        c.UV_ENETUNREACH => Error.ENETUNREACH,
        c.UV_ENFILE => Error.ENFILE,
        c.UV_ENOBUFS => Error.ENOBUFS,
        c.UV_ENODEV => Error.ENODEV,
        c.UV_ENOENT => Error.ENOENT,
        c.UV_ENOMEM => Error.ENOMEM,
        c.UV_ENONET => Error.ENONET,
        c.UV_ENOPROTOOPT => Error.ENOPROTOOPT,
        c.UV_ENOSPC => Error.ENOSPC,
        c.UV_ENOSYS => Error.ENOSYS,
        c.UV_ENOTCONN => Error.ENOTCONN,
        c.UV_ENOTDIR => Error.ENOTDIR,
        c.UV_ENOTEMPTY => Error.ENOTEMPTY,
        c.UV_ENOTSOCK => Error.ENOTSOCK,
        c.UV_ENOTSUP => Error.ENOTSUP,
        c.UV_EPERM => Error.EPERM,
        c.UV_EPIPE => Error.EPIPE,
        c.UV_EPROTO => Error.EPROTO,
        c.UV_EPROTONOSUPPORT => Error.EPROTONOSUPPORT,
        c.UV_EPROTOTYPE => Error.EPROTOTYPE,
        c.UV_ERANGE => Error.ERANGE,
        c.UV_EROFS => Error.EROFS,
        c.UV_ESHUTDOWN => Error.ESHUTDOWN,
        c.UV_ESPIPE => Error.ESPIPE,
        c.UV_ESRCH => Error.ESRCH,
        c.UV_ETIMEDOUT => Error.ETIMEDOUT,
        c.UV_ETXTBSY => Error.ETXTBSY,
        c.UV_EXDEV => Error.EXDEV,
        c.UV_UNKNOWN => Error.UNKNOWN,
        c.UV_EOF => Error.EOF,
        c.UV_ENXIO => Error.ENXIO,
        c.UV_EHOSTDOWN => Error.EHOSTDOWN,
        c.UV_EREMOTEIO => Error.EREMOTEIO,
        c.UV_ENOTTY => Error.ENOTTY,
        c.UV_EFTYPE => Error.EFTYPE,
        c.UV_EILSEQ => Error.EILSEQ,
        c.UV_ESOCKTNOSUPPORT => Error.ESOCKTNOSUPPORT,
        else => std.debug.panic("uv error code {d} not handled", .{err}),
    };
}

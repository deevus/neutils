pub fn zigdownSupressingLog(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    switch (scope) {
        // ignore known zigdown scopes
        .present, .server, .tree_sitter, .syntax, .utils => return,
        else => std.log.defaultLog(level, scope, format, args),
    }
}

const std = @import("std");

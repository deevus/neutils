const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var tools_dir = std.fs.cwd().openDir("src/tools", .{ .iterate = true }) catch {
        return;
    };
    defer tools_dir.close();

    var iter = try tools_dir.walk(b.allocator);
    defer iter.deinit();

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "main.zig")) continue;
        if (std.mem.count(u8, entry.path, &.{std.fs.path.sep}) != 1) continue;

        const tool_name = std.fs.path.dirname(entry.path) orelse continue;

        const path = b.fmt("src/tools/{s}/{s}", .{ tool_name, entry.basename });

        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });

        mod.addImport("zigdown", b.dependency("zigdown", .{}).module("zigdown"));

        const exe = b.addExecutable(.{
            .name = tool_name,
            .root_module = mod,
        });

        b.installArtifact(exe);

        const build_step = b.step(tool_name, b.fmt("Build {s}", .{tool_name}));
        build_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}

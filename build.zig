const std = @import("std");
const BuildZigZon = @import("build.zig.zon");

const Dependency = union(enum) {
    exact: []const u8,
    module: struct {
        name: []const u8,
        module: []const u8,
    },
};

const dependency_map: std.StaticStringMap([]const Dependency) = .initComptime(.{
    .{
        "mbox-diff",
        &[_]Dependency{
            .{ .exact = "cli" },
        },
    },
    .{
        "urlencode",
        &[_]Dependency{
            .{ .exact = "cli" },
        },
    },
    .{
        "urlparse",
        &[_]Dependency{
            .{ .exact = "cli" },
            .{ .exact = "kewpie" },
            .{ .exact = "zigdown" },
        },
    },
});

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", getVersion(optimize));

    const test_all_step = b.step("test", "Run all tool tests");

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

        mod.addOptions("build_options", build_options);

        if (dependency_map.get(tool_name)) |deps| {
            for (deps) |dep| {
                switch (dep) {
                    .exact => |name| {
                        mod.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
                    },
                    .module => |m| {
                        mod.addImport(m.name, b.dependency(m.name, .{ .target = target, .optimize = optimize }).module(m.module));
                    },
                }
            }
        }

        const exe = b.addExecutable(.{
            .name = tool_name,
            .root_module = mod,
        });

        b.installArtifact(exe);

        const build_step = b.step(tool_name, b.fmt("Build {s}", .{tool_name}));
        build_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(b.fmt("run-{s}", .{tool_name}), b.fmt("Run {s}", .{tool_name}));
        run_step.dependOn(&run_cmd.step);

        const unit_tests = b.addTest(.{
            .root_module = mod,
        });

        const test_run = b.addRunArtifact(unit_tests);
        const test_step = b.step(b.fmt("test-{s}", .{tool_name}), b.fmt("Test {s}", .{tool_name}));
        test_step.dependOn(&test_run.step);

        test_all_step.dependOn(test_step);
    }
}

fn getVersion(optimize: std.builtin.OptimizeMode) []const u8 {
    if (optimize == .Debug) {
        const semver = comptime std.SemanticVersion.parse(BuildZigZon.version) catch @compileError("Could not parse version.");
        return std.fmt.comptimePrint("{d}.{d}.{d}-dev", .{ semver.major, semver.minor, semver.patch + 1 });
    }
    return BuildZigZon.version;
}

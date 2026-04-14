const std = @import("std");
const BuildZigZon = @import("build.zig.zon");

const Dependency = union(enum) {
    exact: []const u8,
    module: struct {
        name: []const u8,
        module: []const u8,
    },
    lib: struct {
        name: []const u8,
        path: []const u8,
        deps: []const Dependency = &.{},
    },

    const cli: Dependency = .{ .exact = "cli" };
    const humanize: Dependency = .{ .exact = "humanize" };
    const kewpie: Dependency = .{ .exact = "kewpie" };
    const zigdown: Dependency = .{ .exact = "zigdown" };
    const zigfsm: Dependency = .{ .exact = "zigfsm" };
    const mbox: Dependency = .{ .lib = .{ .name = "mbox", .path = "src/lib/mbox/root.zig", .deps = &.{.zigfsm} } };
    const md: Dependency = .{ .lib = .{ .name = "md", .path = "src/lib/md/root.zig", .deps = &.{.zigdown} } };
};

const libs: []const Dependency = &.{ .mbox, .md };

const default_deps: []const Dependency = &.{.cli};

const dependency_map: std.StaticStringMap([]const Dependency) = .initComptime(.{
    .{
        "urlparse",
        default_deps ++
            &[_]Dependency{
                .kewpie,
                .zigdown,
            },
    },
    .{
        "og-check",
        default_deps ++
            &[_]Dependency{
                .md,
            },
    },
    .{
        "mbox-diff",
        default_deps ++
            &[_]Dependency{
                .mbox,
            },
    },
    .{
        "mbox-index",
        default_deps ++
            &[_]Dependency{
                .mbox,
            },
    },
    .{
        "mbox-gen",
        default_deps ++
            &[_]Dependency{
                .mbox,
                .humanize,
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

        resolveDeps(b, mod, target, optimize, dependency_map.get(tool_name) orelse default_deps);

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

    // register tests for libs
    for (libs) |dep| {
        const mod = resolveMod(b, dep, target, optimize);

        const unit_tests = b.addTest(.{
            .root_module = mod,
        });

        const test_run = b.addRunArtifact(unit_tests);
        const test_step = b.step(b.fmt("test-lib-{s}", .{dep.lib.name}), b.fmt("Test lib-{s}", .{dep.lib.name}));

        test_step.dependOn(&test_run.step);
        test_all_step.dependOn(test_step);
    }
}

fn resolveMod(
    b: *std.Build,
    dependency: Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    switch (dependency) {
        .exact => |name| {
            return b.dependency(name, .{ .target = target, .optimize = optimize }).module(name);
        },
        .module => |m| {
            return b.dependency(m.name, .{ .target = target, .optimize = optimize }).module(m.module);
        },
        .lib => |l| {
            const lib_mod = b.createModule(.{
                .root_source_file = b.path(l.path),
                .target = target,
                .optimize = optimize,
            });
            resolveDeps(b, lib_mod, target, optimize, l.deps);
            return lib_mod;
        },
    }
}

fn resolveDeps(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: []const Dependency,
) void {
    for (deps) |dep| {
        const dep_mod = resolveMod(b, dep, target, optimize);

        const mod_name = switch (dep) {
            .exact => |name| name,
            .module => |m| m.name,
            .lib => |l| l.name,
        };

        mod.addImport(mod_name, dep_mod);
    }
}

fn getVersion(optimize: std.builtin.OptimizeMode) []const u8 {
    if (optimize == .Debug) {
        const semver = comptime std.SemanticVersion.parse(BuildZigZon.version) catch @compileError("Could not parse version.");
        return std.fmt.comptimePrint("{d}.{d}.{d}-dev", .{ semver.major, semver.minor, semver.patch + 1 });
    }
    return BuildZigZon.version;
}

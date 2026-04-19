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

    pub fn resolveModule(
        self: Dependency,
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) *std.Build.Module {
        switch (self) {
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

    const test_all_step = b.step("test", "Run all tests");

    // codegen — must build for host since it runs at build time
    const gen_html_entities = createExecutable(b, "gen-html-entities", .{
        .mod_opts = .{
            .root_source_file = b.path("build/gen_html_entities.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        },
        .test_all_step = test_all_step,
        .install_opts = .{
            .dest_dir = .{ .override = .{ .custom = "codegen" } },
        },
    });

    const whatwg_html = b.dependency("whatwg_html", .{});

    const gen_html_entities_run = b.addRunArtifact(gen_html_entities);
    gen_html_entities_run.expectExitCode(0);
    gen_html_entities_run.addFileArg(whatwg_html.path("entities/out/entities.json"));
    const html_entities_output = gen_html_entities_run.addOutputFileArg("html_entities.zig");

    const html_entities_lib = b.createModule(.{
        .root_source_file = html_entities_output,
        .target = target,
        .optimize = optimize,
    });

    // tools
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

        var exe = createExecutable(b, tool_name, .{
            .mod_opts = .{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            },
            .build_opts = build_options,
            .test_all_step = test_all_step,
        });

        if (std.mem.eql(u8, tool_name, "og-check")) {
            exe.root_module.addImport("html_entities", html_entities_lib);
        }
    }

    // register tests for libs
    for (libs) |dep| {
        const mod = dep.resolveModule(b, target, optimize);

        const unit_tests = b.addTest(.{
            .root_module = mod,
        });

        const test_run = b.addRunArtifact(unit_tests);
        const test_step = b.step(b.fmt("test-lib-{s}", .{dep.lib.name}), b.fmt("Test lib-{s}", .{dep.lib.name}));

        test_step.dependOn(&test_run.step);
        test_all_step.dependOn(test_step);
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
        const dep_mod = dep.resolveModule(b, target, optimize);

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

const ExeOptions = struct {
    mod_opts: std.Build.Module.CreateOptions,
    build_opts: ?*std.Build.Step.Options = null,
    test_all_step: *std.Build.Step,
    install_opts: std.Build.Step.InstallArtifact.Options = .{},
};

fn createExecutable(b: *std.Build, name: []const u8, options: ExeOptions) *std.Build.Step.Compile {
    const mod = b.createModule(options.mod_opts);

    if (options.build_opts) |build_opts| {
        mod.addOptions("build_options", build_opts);
    }

    const target = options.mod_opts.target orelse b.standardTargetOptions(.{});
    const optimize = options.mod_opts.optimize orelse b.standardOptimizeOption(.{});

    resolveDeps(b, mod, target, optimize, dependency_map.get(name) orelse default_deps);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });

    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, options.install_opts).step);

    const build_step = b.step(name, b.fmt("Build {s}", .{name}));
    build_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name}));
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = mod,
    });

    const test_run = b.addRunArtifact(unit_tests);
    const test_step = b.step(b.fmt("test-{s}", .{name}), b.fmt("Test {s}", .{name}));
    test_step.dependOn(&test_run.step);

    options.test_all_step.dependOn(test_step);

    return exe;
}

pub var config: Config = .{
    .str = "",
};

pub fn execute(allocator: Allocator, exec_fn: ExecFn) !void {
    var runner = try AppRunner.init(allocator);

    const app: App = .{
        .version = build_options.version,
        .command = Command{
            .name = "urlencode",
            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .exec = exec_fn,
                    .positional_args = cli.PositionalArgs{
                        .required = &[_]cli.PositionalArg{
                            .{
                                .name = "str",
                                .help = "String to encode",
                                .value_ref = runner.mkRef(&config.str),
                            },
                        },
                    },
                },
            },
        },
    };

    return runner.run(&app);
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const cli = @import("cli");
const App = cli.App;
const AppRunner = cli.AppRunner;
const ExecFn = cli.ExecFn;
const Command = cli.Command;

const build_options = @import("build_options");

const Config = @import("Config.zig");

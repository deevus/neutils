pub var config: Config = .{
    .base_mbox = "",
    .new_mbox = "",
    .output = "",
};

pub fn execute(allocator: Allocator, exec_fn: ExecFn) !void {
    var runner = try AppRunner.init(allocator);

    const app: App = .{
        .version = build_options.version,
        .command = Command{
            .name = "mbox-diff",
            .options = try runner.allocOptions(
                &[_]Option{
                    .{
                        .long_name = "output",
                        .short_alias = 'o',
                        .help = "Output mbox file path",
                        .value_ref = runner.mkRef(&config.output),
                        .required = true,
                    },
                },
            ),

            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .exec = exec_fn,
                    .positional_args = cli.PositionalArgs{
                        .required = &[_]cli.PositionalArg{
                            .{
                                .name = "base_mbox",
                                .help = "Base mbox file (emails to exclude)",
                                .value_ref = runner.mkRef(&config.base_mbox),
                            },
                            .{
                                .name = "new_mbox",
                                .help = "New mbox file (emails to diff against base)",
                                .value_ref = runner.mkRef(&config.new_mbox),
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
const Option = cli.Option;
const Command = cli.Command;

const build_options = @import("build_options");

const Config = @import("Config.zig");

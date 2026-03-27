pub var config: Config = .{
    .url = "",
};

pub fn execute(allocator: Allocator, exec_fn: ExecFn) !void {
    var runner = try AppRunner.init(allocator);

    const app: App = .{
        .version = build_options.version,
        .command = Command{
            .name = "urlparse",
            .options = try runner.allocOptions(
                &[_]Option{
                    .{
                        .long_name = "output-format",
                        .short_alias = 'o',
                        .help = "Output format (json, markdown)",
                        .value_ref = runner.mkRef(&config.output_format),
                    },
                    .{
                        .long_name = "field",
                        .short_alias = 'f',
                        .help = "Extract a single field (scheme, user, password, host, port, path, query, fragment)",
                        .value_ref = runner.mkRef(&config.field),
                    },
                },
            ),

            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .exec = exec_fn,
                    .positional_args = cli.PositionalArgs{
                        .required = &[_]cli.PositionalArg{
                            .{
                                .name = "url",
                                .help = "URL to parse",
                                .value_ref = runner.mkRef(&config.url),
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

const Config = struct {
    input: []const u8 = "",
    output: []const u8 = "",
};

var config: Config = .{};

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var runner = try AppRunner.init(allocator);

    const app: App = .{
        .command = Command{
            .name = "gen-html-entities",
            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .exec = codegen,
                    .positional_args = cli.PositionalArgs{
                        .required = &[_]cli.PositionalArg{
                            .{
                                .name = "input",
                                .help = "Input html-entities json path",
                                .value_ref = runner.mkRef(&config.input),
                            },
                            .{
                                .name = "output",
                                .help = "Output zig file path",
                                .value_ref = runner.mkRef(&config.output),
                            },
                        },
                    },
                },
            },
        },
    };

    return runner.run(&app);
}

const Entity = struct {
    codepoints: []const u21,
    characters: []const u8,
};

pub fn codegen() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = try std.fs.cwd().openFile(config.input, .{});
    defer input.close();

    var read_buf: [4096]u8 = undefined;
    var read_stream = input.reader(&read_buf);
    var reader = &read_stream.interface;

    const json_str = try reader.readAlloc(allocator, @intCast(try input.getEndPos()));
    defer allocator.free(json_str);

    const json: std.json.Value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json_str, .{});
    std.debug.assert(json == .object);

    const output = try std.fs.cwd().createFile(config.output, .{});
    defer output.close();

    var out_buf: [4096]u8 = undefined;
    var out_stream = output.writer(&out_buf);
    var writer = &out_stream.interface;

    try writer.writeAll(
        \\const std = @import("std");
        \\
        \\pub const Entity = struct {
        \\    codepoints: []const u21,
        \\    characters: []const u8,
        \\};
        \\
        \\pub const entities: std.StaticStringMap(Entity) = .initComptime(.{
        \\
    );

    var iter = json.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;

        try writer.print("    .{{ \"{s}\", Entity{{ ", .{key});

        const value = entry.value_ptr.*;

        try writer.writeAll(".codepoints = &[_]u21{");
        const codepoints = value.object.get("codepoints").?;
        const codepoints_count = codepoints.array.items.len;

        for (codepoints.array.items, 0..) |cp, i| {
            try writer.print("{d}", .{cp.integer});

            if (i < codepoints_count - 1) {
                try writer.writeAll(", ");
            }
        }
        try writer.writeAll("}, ");

        const characters = value.object.get("characters").?;
        try writer.writeAll(".characters = ");
        try writeZigStringLiteral(writer, characters.string);

        try writer.writeAll("} },\n");
    }

    try writer.writeAll(
        \\});
    );

    try writer.flush();
}

fn writeZigStringLiteral(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |b| {
        switch (b) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try writer.writeByte(b),
            else => try writer.print("\\x{x:0>2}", .{b}),
        }
    }
    try writer.writeByte('"');
}

const std = @import("std");

const cli = @import("cli");
const App = cli.App;
const AppRunner = cli.AppRunner;
const Command = cli.Command;
const Option = cli.Option;

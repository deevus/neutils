const Output = enum {
    json,
    markdown,
    terminal,
    field,
};

fn getComponentString(component: ?std.Uri.Component) ?[]const u8 {
    const comp = component orelse return null;
    const str = switch (comp) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };

    if (str.len == 0) return null;

    return str;
}

pub fn main() !void {
    try cli.execute(std.heap.page_allocator, urlparse);
}

fn urlparse() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const stdout = File.stdout();
    const stderr = File.stderr();

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buf);
    var stdout_writer_interface = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = stderr.writer(&stderr_buf);
    var stderr_writer_interface = &stderr_writer.interface;

    if (cli.config.output_format != null and cli.config.field != null) {
        try stderr_writer_interface.writeAll("error: --output-format and --field cannot be used together\n");
        try stderr_writer_interface.flush();
        std.process.exit(1);
    }

    const uri = std.Uri.parse(cli.config.url) catch |err| {
        try stderr_writer_interface.writeAll("error: failed to parse URL: ");
        try stderr_writer_interface.writeAll(@errorName(err));
        try stderr_writer_interface.writeAll("\n");
        try stderr_writer_interface.flush();
        std.process.exit(1);
    };

    const output: Output = blk: {
        // output format specified through argument
        if (cli.config.output_format) |f| switch (f) {
            .json => break :blk .json,
            .markdown => break :blk .markdown,
        };

        // field specified through argument
        if (cli.config.field != null) break :blk .field;

        // default to terminal output if stdout is a tty
        if (stdout.isTty()) break :blk .terminal;

        // default to markdown output otherwise
        break :blk .markdown;
    };

    switch (output) {
        .json => try writeJson(gpa, stdout_writer_interface, uri),
        .markdown => try writeMarkdown(gpa, stdout_writer_interface, uri),
        .terminal => try writeTerminal(gpa, stdout_writer_interface, uri),
        .field => {
            switch (cli.config.field.?) {
                .scheme => try stdout_writer_interface.print("{s}", .{uri.scheme}),
                .port => if (uri.port) |p| {
                    try stdout_writer_interface.print("{d}", .{p});
                },
                inline else => |f| if (getComponentString(@field(uri, std.enums.tagName(Field, f).?))) |v| {
                    try stdout_writer_interface.print("{s}", .{v});
                },
            }

            try stdout_writer_interface.writeAll("\n");
        },
    }

    try stdout_writer_interface.flush();
}

fn writeTerminal(allocator: std.mem.Allocator, writer: *Writer, uri: std.Uri) !void {
    var markdown_writer: Writer.Allocating = .init(allocator);
    defer markdown_writer.deinit();

    try writeMarkdown(allocator, &markdown_writer.writer, uri);
    const markdown = markdown_writer.written();

    var parser: zigdown.Parser = .init(allocator, .{});
    defer parser.deinit();
    try parser.parseMarkdown(markdown);

    const terminal_size: zigdown.gfx.TermSize = zigdown.gfx.getTerminalSize() catch .{};

    var renderer: zigdown.ConsoleRenderer = .init(writer, allocator, .{
        .termsize = terminal_size,
    });
    defer renderer.deinit();

    try renderer.renderBlock(parser.document);
}

fn writeMarkdown(allocator: std.mem.Allocator, writer: *Writer, uri: std.Uri) !void {
    try writer.writeAll("# URL\n\n");

    try writer.writeAll("[");
    try uri.writeToStream(writer, .all);
    try writer.writeAll("](");
    try uri.writeToStream(writer, .all);
    try writer.writeAll(")\n\n");

    try writer.writeAll("## Components\n\n");

    try writer.writeAll("|Component|Value|\n");
    try writer.writeAll("|-|-|\n");

    try writer.print("|scheme|{s}|\n", .{uri.scheme});

    if (getComponentString(uri.user)) |u| {
        try writer.print("|user|{s}|\n", .{u});
    }

    if (getComponentString(uri.password)) |p| {
        try writer.print("|password|{s}|\n", .{p});
    }

    if (getComponentString(uri.host)) |h| {
        try writer.print("|host|{s}|\n", .{h});
    }

    if (uri.port) |p| {
        try writer.print("|port|{d}|\n", .{p});
    }

    if (getComponentString(uri.path)) |p| {
        try writer.print("|path|{s}|\n", .{p});
    }

    if (getComponentString(uri.query)) |q| {
        try writer.print("|query|{s}|\n", .{q});
    }

    if (getComponentString(uri.fragment)) |f| {
        try writer.print("|fragment|{s}|\n", .{f});
    }

    if (uri.query) |_| {
        var query_params = try kewpie.parse(allocator, uri);
        defer query_params.deinit();

        try writer.writeAll("## Query Parameters\n\n");

        try writer.writeAll("|Key|Value|\n");
        try writer.writeAll("|-|-|\n");

        var iter = query_params.iterator();
        while (iter.next()) |entry| {
            try writer.print("|{s}|{s}|\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
}

fn writeJson(allocator: std.mem.Allocator, writer: *Writer, uri: std.Uri) !void {
    var json_writer: std.json.Stringify = .{ .writer = writer };
    json_writer.options.whitespace = .indent_2;

    try json_writer.beginObject();

    try json_writer.objectField("scheme");
    try json_writer.write(uri.scheme);

    if (getComponentString(uri.user)) |u| {
        try json_writer.objectField("user");
        try json_writer.write(u);
    }

    if (getComponentString(uri.password)) |p| {
        try json_writer.objectField("password");
        try json_writer.write(p);
    }

    if (getComponentString(uri.host)) |h| {
        try json_writer.objectField("host");
        try json_writer.write(h);
    }

    if (uri.port) |p| {
        try json_writer.objectField("port");
        try json_writer.write(p);
    }

    if (getComponentString(uri.path)) |p| {
        try json_writer.objectField("path");
        try json_writer.write(p);
    }

    if (uri.query) |q| {
        try json_writer.objectField("query");
        try json_writer.write(getComponentString(q).?);

        try json_writer.objectField("queryParams");
        try json_writer.beginObject();

        var query_params = try kewpie.parse(allocator, uri);
        defer query_params.deinit();

        var iter = query_params.iterator();
        while (iter.next()) |kv| {
            try json_writer.objectField(kv.key_ptr.*);
            try json_writer.write(kv.value_ptr.*);
        }

        try json_writer.endObject();
    }

    if (getComponentString(uri.fragment)) |f| {
        try json_writer.objectField("fragment");
        try json_writer.write(f);
    }

    try json_writer.endObject();

    try writer.writeByte('\n');
}

const std = @import("std");
const File = std.fs.File;
const Writer = std.Io.Writer;

const zigdown = @import("zigdown");
const kewpie = @import("kewpie");

const cli = @import("cli.zig");

const Config = @import("Config.zig");
const OutputFormat = Config.OutputFormat;
const Field = Config.Field;

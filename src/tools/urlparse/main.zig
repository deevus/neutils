const version = "0.1.0";

const OutputFormat = enum {
    json,
    markdown,
    terminal,
};

const Field = enum {
    scheme,
    user,
    password,
    host,
    port,
    path,
    query,
    fragment,

    fn fromString(s: []const u8) ?Field {
        const map = std.StaticStringMap(Field).initComptime(.{
            .{ "scheme", .scheme },
            .{ "user", .user },
            .{ "password", .password },
            .{ "host", .host },
            .{ "port", .port },
            .{ "path", .path },
            .{ "query", .query },
            .{ "fragment", .fragment },
        });
        return map.get(s);
    }
};

fn getComponentString(component: ?std.Uri.Component) ?[]const u8 {
    const comp = component orelse return null;
    return switch (comp) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
}

fn printHelp(file: File) !void {
    try file.writeAll(
        \\Usage: urlparse [OPTIONS] <URL>
        \\
        \\Parse a URL and display its components.
        \\
        \\Options:
        \\  --json           Output in JSON format
        \\  --field <name>   Extract a single field (scheme, user, password,
        \\                   host, port, path, query, fragment)
        \\  --help           Show this help message
        \\  --version        Show version information
        \\
        \\Examples:
        \\  urlparse "https://example.com/path?query=value#fragment"
        \\  urlparse --json "https://user:pass@example.com:8080/path"
        \\  urlparse --markdown "https://user:pass@example.com:8080/path"
        \\  urlparse --field host "https://example.com/path"
        \\
    );
}

fn printVersion(file: File) !void {
    try file.writeAll("urlparse ");
    try file.writeAll(version);
    try file.writeAll("\n");
}

pub fn main() !void {
    const stdout = File.stdout();
    const stderr = File.stderr();

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buf);
    var stdout_writer_interface = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = stderr.writer(&stderr_buf);
    var stderr_writer_interface = &stderr_writer.interface;

    var args = std.process.args();
    _ = args.skip(); // Skip program name

    var output_format: OutputFormat = if (stdout.isTty()) .terminal else .markdown;
    var field_filter: ?Field = null;
    var url: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(stdout);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try printVersion(stdout);
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            output_format = .json;
        } else if (std.mem.eql(u8, arg, "--markdown")) {
            output_format = .markdown;
        } else if (std.mem.eql(u8, arg, "--field")) {
            const field_name = args.next() orelse {
                try stderr_writer_interface.writeAll("error: --field requires a field name argument\n");
                try stderr_writer_interface.flush();
                std.process.exit(1);
            };
            field_filter = Field.fromString(field_name) orelse {
                try stderr_writer_interface.writeAll("error: unknown field '");
                try stderr_writer_interface.writeAll(field_name);
                try stderr_writer_interface.writeAll("'\n");
                try stderr_writer_interface.writeAll("valid fields: scheme, user, password, host, port, path, query, fragment\n");
                try stderr_writer_interface.flush();
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr_writer_interface.writeAll("error: unknown option '");
            try stderr_writer_interface.writeAll(arg);
            try stderr_writer_interface.writeAll("'\n");
            try stderr_writer_interface.flush();
            std.process.exit(1);
        } else {
            url = arg;
        }
    }

    const url_str = url orelse {
        try stderr_writer_interface.writeAll("error: no URL provided\n");
        try stderr_writer_interface.writeAll("usage: urlparse [OPTIONS] <URL>\n");
        try stderr_writer_interface.writeAll("try 'urlparse --help' for more information\n");
        try stderr_writer_interface.flush();
        std.process.exit(1);
    };

    const uri = std.Uri.parse(url_str) catch |err| {
        try stderr_writer_interface.writeAll("error: failed to parse URL: ");
        try stderr_writer_interface.writeAll(@errorName(err));
        try stderr_writer_interface.writeAll("\n");
        try stderr_writer_interface.flush();
        std.process.exit(1);
    };

    // Extract component values
    const scheme = uri.scheme;
    const user = getComponentString(uri.user);
    const password = getComponentString(uri.password);
    const host = getComponentString(uri.host);
    const port = uri.port;
    const path = getComponentString(uri.path);
    const query = getComponentString(uri.query);
    const fragment = getComponentString(uri.fragment);

    // Handle single field extraction
    if (field_filter) |field| {
        const value: ?[]const u8 = switch (field) {
            .scheme => scheme,
            .user => user,
            .password => password,
            .host => host,
            .port => null, // Special case: port is u16
            .path => path,
            .query => query,
            .fragment => fragment,
        };

        if (field == .port) {
            if (port) |p| {
                try stdout_writer_interface.writeInt(u16, p, .little);
                try stdout_writer_interface.writeAll("\n");
            }
        } else {
            if (value) |v| {
                try stdout_writer_interface.writeAll(v);
                try stdout_writer_interface.writeAll("\n");
            }
        }
    } else switch (output_format) {
        .json => try writeJson(stdout_writer_interface, uri),
        .markdown => try writeMarkdown(stdout_writer_interface, uri),
        .terminal => try writeTerminal(std.heap.smp_allocator, stdout_writer_interface, uri),
    }

    try stdout_writer_interface.flush();
}

fn writeTerminal(allocator: std.mem.Allocator, writer: *Writer, uri: std.Uri) !void {
    var markdown_writer: Writer.Allocating = .init(allocator);
    defer markdown_writer.deinit();

    try writeMarkdown(&markdown_writer.writer, uri);
    const markdown = markdown_writer.written();

    var parser: zigdown.Parser = .init(allocator, .{});
    defer parser.deinit();
    try parser.parseMarkdown(markdown);

    var renderer: zigdown.ConsoleRenderer = .init(writer, allocator, .{});
    defer renderer.deinit();

    try renderer.renderBlock(parser.document);
}

fn writeMarkdown(writer: *Writer, uri: std.Uri) !void {
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
}

fn writeJson(writer: *Writer, uri: std.Uri) !void {
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

    if (getComponentString(uri.query)) |q| {
        try json_writer.objectField("query");
        try json_writer.write(q);
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

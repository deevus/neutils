const Output = enum {
    json,
    markdown,
    terminal,
    field,
};

pub fn main() !void {
    try cli.execute(std.heap.page_allocator, ogCheck);
}

fn ogCheck() !void {
    var arena: ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const uri: Uri = try .parse(cli.config.url);

    var http_client: std.http.Client = .{ .allocator = allocator };

    var request = try http_client.request(.GET, uri, .{});
    defer request.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try http_client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &body.writer,
        .extra_headers = &.{.{
            .name = "accept",
            .value = "text/html,application/xhtml+xml",
        }},
    });

    if (result.status != .ok) {
        return error.HttpError;
    }

    const bytes = body.written();
    var offset: usize = 0;

    var meta_tags: ArrayList(scan.Meta) = .empty;
    defer meta_tags.deinit(allocator);

    if (std.ascii.indexOfIgnoreCase(bytes, "<title>")) |start| {
        if (std.ascii.indexOfIgnoreCasePos(bytes, start, "</title>")) |end| {
            try meta_tags.append(allocator, .{
                .key = "title",
                .value = .init(bytes[(start + "<title>".len)..end]),
                .namespace = .html,
            });
        }
    }

    while (std.ascii.indexOfIgnoreCasePos(bytes, offset, "<meta ")) |start| {
        if (std.ascii.indexOfIgnoreCasePos(bytes, start, ">")) |end| {
            if (Meta.parse(bytes[start..(end + 1)])) |meta| {
                try meta_tags.append(allocator, meta);
            }
        }

        offset = start + 1;
    }

    var stdout = std.fs.File.stdout();
    defer stdout.close();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_stream = stdout.writer(&stdout_buf);
    const stdout_writer = &stdout_stream.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr();
    var stderr_stream = stderr.writer(&stderr_buf);
    const stderr_writer = &stderr_stream.interface;

    switch (cli.config.output_format) {
        .opengraph => writeOpenGraph(allocator, meta_tags, stdout_writer) catch |err| switch (err) {
            error.MissingTitle, error.MissingType, error.MissingImage, error.MissingUrl => {
                try stderr_writer.print("error: OpenGraph missing required field — {}.\n", .{err});
                try stderr_writer.flush();
            },
            else => return err,
        },
        .twitter => writeTwitter(allocator, meta_tags, stdout_writer) catch |err| switch (err) {
            error.MissingCard, error.MissingTitle, error.MissingImage => {
                try stderr_writer.print("error: Twitter Card missing required field — {}.\n", .{err});
                try stderr_writer.flush();
            },
            else => return err,
        },
        .table => try writeTable(allocator, meta_tags, stdout_writer),
        .json => try writeJson(meta_tags, stdout_writer),
    }
}

fn findByKey(key: []const u8, tags: ArrayList(Meta)) ?*const Meta {
    for (tags.items) |*meta| {
        if (std.mem.eql(u8, meta.key, key)) {
            return meta;
        }
    }

    return null;
}

fn writeOpenGraph(allocator: Allocator, tags: ArrayList(Meta), writer: *Writer) !void {
    var markdown_allocating_writer: AllocatingWriter = .init(allocator);
    defer markdown_allocating_writer.deinit();
    var markdown_writer = &markdown_allocating_writer.writer;

    // required fields
    const title = findByKey("og:title", tags) orelse return error.MissingTitle;
    const @"type" = findByKey("og:type", tags) orelse return error.MissingType;
    const image = findByKey("og:image", tags) orelse return error.MissingImage;
    const url = findByKey("og:url", tags) orelse return error.MissingUrl;

    try markdown_writer.print("# Title: [{f}]({s})\n\n", .{ title.value, url.value.raw });

    if (findByKey("og:description", tags)) |description| {
        try markdown_writer.print("## Description\n\n{f}\n\n", .{description.value});
    }

    if (findByKey("og:site-name", tags)) |site_name| {
        try markdown_writer.print("## Site name: {f}\n\n", .{site_name.value});
    }

    try markdown_writer.print("![Image]({s})\n\n", .{image.value.raw});

    if (findByKey("og:image:alt", tags)) |image_alt| {
        try markdown_writer.print("**Image Alt**: {f}\n\n", .{image_alt.value});
    }

    try markdown_writer.print("**Type**: {s}\n\n", .{@"type".value.raw});
    try markdown_writer.print("**URL**: [{0s}]({0s})\n\n", .{url.value.raw});

    if (findByKey("og:locale", tags)) |locale| {
        try markdown_writer.print("**Locale**: {s})\n\n", .{locale.value.raw});
    }

    try md.renderMarkdownToTerminal(allocator, markdown_allocating_writer.written(), writer);
    try writer.flush();
}

fn writeTwitter(allocator: Allocator, tags: ArrayList(Meta), writer: *Writer) !void {
    var markdown_allocating_writer: AllocatingWriter = .init(allocator);
    defer markdown_allocating_writer.deinit();
    var markdown_writer = &markdown_allocating_writer.writer;

    // required fields — twitter clients fall back to og:* when twitter:* is absent
    const card = findByKey("twitter:card", tags) orelse return error.MissingCard;
    const title = findByKey("twitter:title", tags) orelse findByKey("og:title", tags) orelse return error.MissingTitle;
    const image = findByKey("twitter:image", tags) orelse findByKey("og:image", tags) orelse return error.MissingImage;

    try markdown_writer.print("# Title: {f}\n\n", .{title.value});

    if (findByKey("twitter:description", tags) orelse findByKey("og:description", tags)) |description| {
        try markdown_writer.print("## Description\n\n{f}\n\n", .{description.value});
    }

    if (findByKey("twitter:site", tags)) |site| {
        try markdown_writer.print("## Site: {f}\n\n", .{site.value});
    }

    if (findByKey("twitter:creator", tags)) |creator| {
        try markdown_writer.print("## Creator: {f}\n\n", .{creator.value});
    }

    try markdown_writer.print("![Image]({s})\n\n", .{image.value.raw});

    if (findByKey("twitter:image:alt", tags) orelse findByKey("og:image:alt", tags)) |image_alt| {
        try markdown_writer.print("**Image Alt**: {f}\n\n", .{image_alt.value});
    }

    try markdown_writer.print("**Card**: {s}\n\n", .{card.value.raw});

    if (findByKey("twitter:url", tags) orelse findByKey("og:url", tags)) |url| {
        try markdown_writer.print("**URL**: [{0s}]({0s})\n", .{url.value.raw});
    }

    try md.renderMarkdownToTerminal(allocator, markdown_allocating_writer.written(), writer);
    try writer.flush();
}

fn writeJson(tags: ArrayList(Meta), writer: *Writer) !void {
    var json_writer: std.json.Stringify = .{ .writer = writer };
    json_writer.options.whitespace = .indent_2;

    try json_writer.beginObject();

    for (std.enums.values(Meta.Namespace)) |ns| {
        var ns_started = false;

        for (tags.items) |tag| {
            if (tag.namespace != ns) continue;

            if (!ns_started) {
                try json_writer.objectField(@tagName(ns));
                try json_writer.beginObject();
                ns_started = true;
            }

            const prefix: []const u8 = switch (ns) {
                .og => "og:",
                .article => "article:",
                .book => "book:",
                .profile => "profile:",
                .music => "music:",
                .video => "video:",
                .fb => "fb:",
                .twitter => "twitter:",
                .html => "",
            };
            const key = if (std.mem.startsWith(u8, tag.key, prefix)) tag.key[prefix.len..] else tag.key;

            try json_writer.objectField(key);
            try json_writer.write(tag.value.raw);
        }

        if (ns_started) {
            try json_writer.endObject();
        }
    }

    try json_writer.endObject();
    try writer.writeByte('\n');
    try writer.flush();
}

fn writeTable(allocator: Allocator, tags: ArrayList(scan.Meta), writer: *Writer) !void {
    var markdown_allocating_writer: AllocatingWriter = .init(allocator);
    defer markdown_allocating_writer.deinit();

    var markdown_writer = &markdown_allocating_writer.writer;

    if (tags.items.len > 0) {
        try markdown_writer.writeAll("|Type|Key|Value|\n");
        try markdown_writer.writeAll("|-|-|-|\n");
    }

    for (tags.items) |meta_tag| {
        try markdown_writer.print("|{s}|{s}|{f}|\n", .{ meta_tag.namespace.label(), meta_tag.key, meta_tag.value });
    }

    try md.renderMarkdownToTerminal(allocator, markdown_allocating_writer.written(), writer);
    try writer.flush();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayListUnmanaged;
const File = std.fs.File;
const Writer = std.Io.Writer;
const AllocatingWriter = Writer.Allocating;
const Uri = std.Uri;
const StringHashMap = std.StringHashMapUnmanaged;

const zigdown = @import("zigdown");

const cli = @import("cli.zig");

const Config = @import("Config.zig");
const OutputFormat = Config.OutputFormat;

const fetch = @import("fetch.zig");
const scan = @import("scan.zig");
const Meta = scan.Meta;

const render = @import("render.zig");

const md = @import("md");

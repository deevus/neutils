pub fn writeOpenGraph(allocator: Allocator, tags: ArrayList(Meta), writer: *Writer) !void {
    var markdown_allocating_writer: AllocatingWriter = .init(allocator);
    defer markdown_allocating_writer.deinit();
    const markdown_writer = &markdown_allocating_writer.writer;

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
        try markdown_writer.print("**Locale**: {s}\n\n", .{locale.value.raw});
    }

    try md.renderMarkdownToTerminal(allocator, markdown_allocating_writer.written(), writer);
    try writer.flush();
}

pub fn writeTwitter(allocator: Allocator, tags: ArrayList(Meta), writer: *Writer) !void {
    var markdown_allocating_writer: AllocatingWriter = .init(allocator);
    defer markdown_allocating_writer.deinit();
    const markdown_writer = &markdown_allocating_writer.writer;

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

pub fn writeJson(tags: ArrayList(Meta), writer: *Writer) !void {
    var json_writer: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };

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

pub fn writeTable(allocator: Allocator, tags: ArrayList(scan.Meta), writer: *Writer) !void {
    var markdown_allocating_writer: AllocatingWriter = .init(allocator);
    defer markdown_allocating_writer.deinit();

    const markdown_writer = &markdown_allocating_writer.writer;

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
const ArrayList = std.ArrayListUnmanaged;
const Writer = std.Io.Writer;
const AllocatingWriter = Writer.Allocating;

const scan = @import("scan.zig");
const findByKey = scan.findByKey;
const Meta = scan.Meta;

const md = @import("md");

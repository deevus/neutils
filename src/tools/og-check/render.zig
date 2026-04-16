pub fn writeIssues(allocator: Allocator, issues: []const ScanResult.Issue, writer: *Writer) !void {
    var markdown_builder: MarkdownBuilder = .init(allocator);
    defer markdown_builder.deinit();

    try markdown_builder.print("# {d} issues found\n\n", .{issues.len});

    for (issues) |issue| {
        try markdown_builder.print(" - {s} {s}: {s}\n", .{ @tagName(issue.severity), @tagName(issue.tag), issue.field });
    }

    try markdown_builder.render(allocator, .pretty, writer);
}

pub fn writeOpenGraph(allocator: Allocator, scan_result: ScanResult, stdout: *Writer) !void {
    var markdown_builder: MarkdownBuilder = .init(allocator);
    defer markdown_builder.deinit();

    if (scan_result.findByKey("og:title")) |title| {
        try markdown_builder.print("# Title: {f}\n\n", .{title.value});
    }

    if (scan_result.findByKey("og:description")) |description| {
        try markdown_builder.print("## Description\n\n{f}\n\n", .{description.value});
    }

    if (scan_result.findByKey("og:site-name")) |site_name| {
        try markdown_builder.print("## Site name: {f}\n\n", .{site_name.value});
    }

    if (scan_result.findByKey("og:image")) |image| {
        try markdown_builder.print("![Image]({s})\n\n", .{image.value.raw});
    }

    if (scan_result.findByKey("og:image:alt")) |image_alt| {
        try markdown_builder.print("**Image Alt**: {f}\n\n", .{image_alt.value});
    }

    if (scan_result.findByKey("og:type")) |@"type"| {
        try markdown_builder.print("**Type**: {s}\n\n", .{@"type".value.raw});
    }

    if (scan_result.findByKey("og:url")) |url| {
        try markdown_builder.print("**URL**: [{0s}]({0s})\n\n", .{url.value.raw});
    }

    if (scan_result.findByKey("og:locale")) |locale| {
        try markdown_builder.print("**Locale**: {s}\n\n", .{locale.value.raw});
    }

    try markdown_builder.render(allocator, .pretty, stdout);
}

pub fn writeTwitter(allocator: Allocator, scan_result: ScanResult, stdout: *Writer) !void {
    var markdown_builder: MarkdownBuilder = .init(allocator);
    defer markdown_builder.deinit();

    if (scan_result.findByKey("twitter:title") orelse scan_result.findByKey("og:title")) |title| {
        try markdown_builder.print("# Title: {f}\n\n", .{title.value});
    }

    if (scan_result.findByKey("twitter:description") orelse scan_result.findByKey("og:description")) |description| {
        try markdown_builder.print("## Description\n\n{f}\n\n", .{description.value});
    }

    if (scan_result.findByKey("twitter:site")) |site| {
        try markdown_builder.print("## Site: {f}\n\n", .{site.value});
    }

    if (scan_result.findByKey("twitter:creator")) |creator| {
        try markdown_builder.print("## Creator: {f}\n\n", .{creator.value});
    }

    if (scan_result.findByKey("twitter:image") orelse scan_result.findByKey("og:image")) |image| {
        try markdown_builder.print("![Image]({s})\n\n", .{image.value.raw});
    }

    if (scan_result.findByKey("twitter:image:alt") orelse scan_result.findByKey("og:image:alt")) |image_alt| {
        try markdown_builder.print("**Image Alt**: {f}\n\n", .{image_alt.value});
    }

    if (scan_result.findByKey("twitter:card")) |card| {
        try markdown_builder.print("**Card**: {s}\n\n", .{card.value.raw});
    }

    if (scan_result.findByKey("twitter:url") orelse scan_result.findByKey("og:url")) |url| {
        try markdown_builder.print("**URL**: [{0s}]({0s})\n", .{url.value.raw});
    }

    try markdown_builder.render(allocator, .pretty, stdout);
}

pub fn writeJson(scan_result: ScanResult, writer: *Writer) !void {
    var json_writer: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try json_writer.beginObject();

    for (std.enums.values(Meta.Namespace)) |ns| {
        var ns_started = false;

        for (scan_result.meta_tags.items) |tag| {
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

pub fn writeTable(allocator: Allocator, scan_result: ScanResult, writer: *Writer) !void {
    var markdown_builder: MarkdownBuilder = .init(allocator);
    defer markdown_builder.deinit();

    const tags = scan_result.meta_tags;

    if (tags.items.len > 0) {
        try markdown_builder.writeAll("|Type|Key|Value|\n");
        try markdown_builder.writeAll("|-|-|-|\n");
    }

    for (tags.items) |meta_tag| {
        try markdown_builder.print("|{s}|{s}|{f}|\n", .{ meta_tag.namespace.label(), meta_tag.key, meta_tag.value });
    }

    try markdown_builder.render(allocator, .pretty, writer);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const Writer = std.Io.Writer;
const AllocatingWriter = Writer.Allocating;

const scanner = @import("scanner.zig");
const Meta = scanner.Meta;
const ScanResult = scanner.ScanResult;

const md = @import("md");
const MarkdownBuilder = md.MarkdownBuilder;

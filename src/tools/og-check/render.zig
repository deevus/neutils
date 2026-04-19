const json_options = std.json.Stringify.Options{ .whitespace = .indent_2 };

pub fn writeIssuesCi(scan_result: ScanResult, config: Config, writer: *Writer) !void {
    for (scan_result.errors.items) |issue| try emitCommand(writer, .err, issue, config.url);
    for (scan_result.warnings.items) |issue| try emitCommand(writer, .warn, issue, config.url);
    try writer.flush();
}

fn emitCommand(
    writer: *Writer,
    severity: ScanResult.Issue.Severity,
    issue: ScanResult.Issue,
    url: []const u8,
) !void {
    try writer.print("::{s} title={s}::", .{ severity.json(), issue.schema.label() });
    try writeCiEscaped(writer, url);
    try writer.print(" — {s} `", .{issue.tag.label()});
    try writeCiEscaped(writer, issue.field);
    try writer.writeAll("`");

    if (issue.reason) |reason| {
        try writer.writeAll(": ");
        try writeCiEscaped(writer, reason);
    }

    try writer.writeAll("\n");
}

/// Percent-encode the three characters that workflow-command parsers
/// on GitHub Actions and Forgejo Actions treat as control: `%`, `\r`, `\n`.
/// Schema labels and tag labels are hardcoded and safe; only user-controlled
/// inputs (URL, field) go through this.
fn writeCiEscaped(writer: *Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '%' => try writer.writeAll("%25"),
        '\r' => try writer.writeAll("%0D"),
        '\n' => try writer.writeAll("%0A"),
        else => try writer.writeByte(c),
    };
}

pub fn writeIssuesJson(scan_result: ScanResult, config: Config, writer: *Writer) !void {
    var w: std.json.Stringify = .{
        .writer = writer,
        .options = json_options,
    };

    try w.beginObject();

    try w.objectField("tool");
    try w.write("og-check");

    try w.objectField("version");
    try w.write(build_options.version);

    try w.objectField("schema_version");
    try w.write(1);

    try w.objectField("url");
    try w.write(config.url);

    try w.objectField("status");
    try w.write(if (scan_result.errors.items.len > 0) "fail" else "pass");

    try w.objectField("summary");
    try w.beginObject();
    try w.objectField("errors");
    try w.write(scan_result.errors.items.len);
    try w.objectField("warnings");
    try w.write(scan_result.warnings.items.len);
    try w.endObject();

    try w.objectField("issues");
    try w.beginArray();
    for (scan_result.errors.items) |i| try writeIssueJson(&w, i);
    for (scan_result.warnings.items) |i| try writeIssueJson(&w, i);
    try w.endArray();

    try w.endObject();
    try writer.writeByte('\n');
    try writer.flush();
}

fn writeIssueJson(
    w: *std.json.Stringify,
    issue: ScanResult.Issue,
) !void {
    try w.beginObject();
    try w.objectField("severity");
    try w.write(issue.severity.json());
    try w.objectField("schema");
    try w.write(issue.schema.json());
    try w.objectField("rule");
    try w.write(issue.tag.json());
    try w.objectField("field");
    try w.write(issue.field);

    if (issue.reason) |reason| {
        try w.objectField("reason");
        try w.write(reason);
    }

    try w.objectField("message");
    if (issue.reason) |reason| {
        try w.print("\"{s} `{s}`: {s}\"", .{ issue.tag.label(), issue.field, reason });
    } else {
        try w.print("\"{s} `{s}`\"", .{ issue.tag.label(), issue.field });
    }

    try w.endObject();
}

pub fn writeIssuesHuman(allocator: Allocator, scan_result: ScanResult, config: Config, writer: *Writer) !void {
    var aw: AllocatingWriter = .init(allocator);
    defer aw.deinit();
    var doc: Document = .init(&aw.writer);

    const issues = try scan_result.getIssuesSorted(allocator);
    defer allocator.free(issues);

    if (issues.len == 0) {
        try doc.beginHeading(1);
        try doc.write("✅ ");
        try doc.write(config.url);
        try doc.endHeading();
    } else {
        try doc.beginHeading(1);
        try doc.write("Checking ");
        try doc.write(config.url);
        try doc.endHeading();

        var current_schema: ?Schema = null;
        var list_open = false;

        for (issues) |issue| {
            if (current_schema != issue.schema) {
                if (list_open) {
                    try doc.endBulletList();
                    list_open = false;
                }
                current_schema = issue.schema;
                try doc.heading(2, issue.schema.label());
            }

            if (!list_open) {
                try doc.beginBulletList();
                list_open = true;
            }

            try doc.beginListItem();
            try doc.write(issue.severity.glyph());
            try doc.write(" ");
            try doc.write(issue.tag.label());
            try doc.write(" ");
            try doc.code(issue.field);
            if (issue.reason) |reason| {
                try doc.write(": ");
                try doc.write(reason);
            }
            try doc.endListItem();
        }

        if (list_open) try doc.endBulletList();

        const stats = try std.fmt.allocPrint(
            allocator,
            "errors: {d}, warnings: {d}",
            .{ scan_result.errors.items.len, scan_result.warnings.items.len },
        );
        defer allocator.free(stats);

        try doc.beginParagraph();
        try doc.bold(stats);
        try doc.endParagraph();
    }

    try md.renderPretty(allocator, aw.written(), writer);
}

pub fn writeOpenGraph(allocator: Allocator, scan_result: ScanResult, stdout: *Writer) !void {
    var aw: AllocatingWriter = .init(allocator);
    defer aw.deinit();
    var doc: Document = .init(&aw.writer);

    if (scan_result.findByKey("og:title")) |title| {
        try doc.beginHeading(1);
        try doc.write("Title: ");
        try doc.writeFormatted(title.value);
        try doc.endHeading();
    }

    if (scan_result.findByKey("og:description")) |description| {
        try doc.heading(2, "Description");
        try doc.beginParagraph();
        try doc.writeFormatted(description.value);
        try doc.endParagraph();
    }

    if (scan_result.findByKey("og:site-name")) |site_name| {
        try doc.beginHeading(2);
        try doc.write("Site name: ");
        try doc.writeFormatted(site_name.value);
        try doc.endHeading();
    }

    if (scan_result.findByKey("og:image")) |img| {
        try doc.beginParagraph();
        try doc.image("Image", img.value.raw);
        try doc.endParagraph();
    }

    if (scan_result.findByKey("og:image:alt")) |image_alt| {
        try doc.beginParagraph();
        try doc.bold("Image Alt");
        try doc.write(": ");
        try doc.writeFormatted(image_alt.value);
        try doc.endParagraph();
    }

    if (scan_result.findByKey("og:type")) |@"type"| {
        try doc.beginParagraph();
        try doc.bold("Type");
        try doc.write(": ");
        try doc.write(@"type".value.raw);
        try doc.endParagraph();
    }

    if (scan_result.findByKey("og:url")) |url| {
        try doc.beginParagraph();
        try doc.bold("URL");
        try doc.write(": ");
        try doc.link(url.value.raw, url.value.raw);
        try doc.endParagraph();
    }

    if (scan_result.findByKey("og:locale")) |locale| {
        try doc.beginParagraph();
        try doc.bold("Locale");
        try doc.write(": ");
        try doc.write(locale.value.raw);
        try doc.endParagraph();
    }

    try md.renderPretty(allocator, aw.written(), stdout);
}

pub fn writeTwitter(allocator: Allocator, scan_result: ScanResult, stdout: *Writer) !void {
    var aw: AllocatingWriter = .init(allocator);
    defer aw.deinit();
    var doc: Document = .init(&aw.writer);

    if (scan_result.findByKey("twitter:title") orelse scan_result.findByKey("og:title")) |title| {
        try doc.beginHeading(1);
        try doc.write("Title: ");
        try doc.writeFormatted(title.value);
        try doc.endHeading();
    }

    if (scan_result.findByKey("twitter:description") orelse scan_result.findByKey("og:description")) |description| {
        try doc.heading(2, "Description");
        try doc.beginParagraph();
        try doc.writeFormatted(description.value);
        try doc.endParagraph();
    }

    if (scan_result.findByKey("twitter:site")) |site| {
        try doc.beginHeading(2);
        try doc.write("Site: ");
        try doc.writeFormatted(site.value);
        try doc.endHeading();
    }

    if (scan_result.findByKey("twitter:creator")) |creator| {
        try doc.beginHeading(2);
        try doc.write("Creator: ");
        try doc.writeFormatted(creator.value);
        try doc.endHeading();
    }

    if (scan_result.findByKey("twitter:image") orelse scan_result.findByKey("og:image")) |img| {
        try doc.beginParagraph();
        try doc.image("Image", img.value.raw);
        try doc.endParagraph();
    }

    if (scan_result.findByKey("twitter:image:alt") orelse scan_result.findByKey("og:image:alt")) |image_alt| {
        try doc.beginParagraph();
        try doc.bold("Image Alt");
        try doc.write(": ");
        try doc.writeFormatted(image_alt.value);
        try doc.endParagraph();
    }

    if (scan_result.findByKey("twitter:card")) |card| {
        try doc.beginParagraph();
        try doc.bold("Card");
        try doc.write(": ");
        try doc.write(card.value.raw);
        try doc.endParagraph();
    }

    if (scan_result.findByKey("twitter:url") orelse scan_result.findByKey("og:url")) |url| {
        try doc.beginParagraph();
        try doc.bold("URL");
        try doc.write(": ");
        try doc.link(url.value.raw, url.value.raw);
        try doc.endParagraph();
    }

    try md.renderPretty(allocator, aw.written(), stdout);
}

pub fn writeJson(scan_result: ScanResult, writer: *Writer) !void {
    var json_writer: std.json.Stringify = .{
        .writer = writer,
        .options = json_options,
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
    var aw: AllocatingWriter = .init(allocator);
    defer aw.deinit();
    var doc: Document = .init(&aw.writer);

    const tags = scan_result.meta_tags;

    if (tags.items.len > 0) {
        try doc.beginTable(&.{ "Type", "Key", "Value" });

        for (tags.items) |meta_tag| {
            try doc.beginRow();
            try doc.cell(meta_tag.namespace.label());
            try doc.cell(meta_tag.key);
            try doc.writeFormatted(meta_tag.value);
            try doc.writeRaw("|");
            try doc.endRow();
        }

        try doc.endTable();
    }

    try md.renderPretty(allocator, aw.written(), writer);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const Writer = std.Io.Writer;
const AllocatingWriter = Writer.Allocating;

const scanner = @import("scanner.zig");
const Meta = scanner.Meta;
const ScanResult = scanner.ScanResult;
const Schema = ScanResult.Schema;

const md = @import("md");
const Document = md.Document;

const Config = @import("Config.zig");

const build_options = @import("build_options");

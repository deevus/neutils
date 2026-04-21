pub const Meta = struct {
    raw: []const u8 = "",
    key: []const u8 = "",
    value: Value = .empty,
    namespace: Namespace = .html,
    meta_key: MetaAttribute = .name,

    const init: Meta = .{};

    pub const Value = struct {
        const empty: Value = .{};

        raw: []const u8 = "",

        pub fn init(value: []const u8) Value {
            return .{
                .raw = value,
            };
        }

        pub fn format(self: Value, writer: *Writer) !void {
            var i: usize = 0;
            while (i < self.raw.len) {
                if (self.raw[i] == '&') if (std.mem.indexOf(u8, self.raw[i..], ";")) |j| {
                    const slice = self.raw[(i + 1)..(i + j)];

                    if (slice[0] == '#') {
                        const base: u8 = if (slice[1] == 'x' or slice[1] == 'X') 16 else 10;
                        const start: usize = if (base == 16) 2 else 1;

                        const utf_str: ?[]const u8 = blk: {
                            const codepoint = std.fmt.parseInt(u21, slice[start..slice.len], base) catch break :blk null;

                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(codepoint, &buf) catch break :blk null;

                            break :blk buf[0..n];
                        };

                        if (utf_str) |s| {
                            try writer.writeAll(s);
                            i += j + 1;
                            continue;
                        }
                    } else if (html_entities.get(self.raw[i..(i + j + 1)])) |str| {
                        try writer.writeAll(str);
                        i += j + 1;
                        continue;
                    }
                };

                try writer.writeByte(self.raw[i]);

                i += 1;
            }
        }
    };

    pub const Namespace = enum {
        /// property="og:*"
        og,
        /// property="article:*" — OG type extension
        article,
        /// property="book:*"
        book,
        /// property="profile:*"
        profile,
        /// property="music:*"
        music,
        /// property="video:*"
        video,
        /// property="fb:*" — Facebook extension
        fb,
        /// name="twitter:*" (or the tolerated-but-wrong property="twitter:*")
        twitter,
        /// Classic HTML name=: description, author, keywords, theme-color,
        /// robots, application-name, and the <title> element.
        html,

        pub fn label(ns: Namespace) []const u8 {
            return switch (ns) {
                .og => "OpenGraph",
                .article => "Article",
                .book => "Book",
                .profile => "Profile",
                .music => "Music",
                .video => "Video",
                .fb => "Facebook",
                .twitter => "Twitter Card",
                .html => "HTML",
            };
        }

        pub fn schema(ns: Namespace) ScanResult.Schema {
            return switch (ns) {
                .twitter => .twitter,
                else => .opengraph,
            };
        }

        pub fn requiredAttribute(ns: Namespace) MetaAttribute {
            return switch (ns) {
                .og, .article, .book, .profile, .music, .video, .fb => .property,
                .twitter, .html => .name,
            };
        }

        pub fn attributeMismatchSeverity(ns: Namespace) ScanResult.Issue.Severity {
            return switch (ns) {
                .og, .article, .book, .profile, .music, .video, .fb => .err,
                .twitter, .html => .warn,
            };
        }
    };

    const HtmlKey = enum {
        description,
        author,
        keywords,
        theme_color,
        robots,
        application_name,
        title,
    };

    const html_key_allow_list: StaticStringMap(HtmlKey) = .initComptime(&.{
        .{ "description", .description },
        .{ "author", .author },
        .{ "keywords", .keywords },
        .{ "theme-color", .theme_color },
        .{ "robots", .robots },
        .{ "application-name", .application_name },
        .{ "title", .title },
    });

    pub const State = enum {
        root,
        name,
        equals,
        value,
    };

    pub const KeyState = enum {
        /// We're expecting a key
        key,
        /// We're expecting a value
        value,
    };

    pub const MetaAttribute = enum {
        name,
        property,
        content,
    };

    const key_map: StaticStringMap(MetaAttribute) = .initComptime(&.{
        .{ "name", MetaAttribute.name },
        .{ "property", MetaAttribute.property },
        .{ "content", MetaAttribute.content },
    });

    pub fn parse(slice: []const u8) ?Meta {
        if (!std.mem.startsWith(u8, slice, "<meta ")) {
            return null;
        }

        var key_start: ?usize = null;
        var value_start: ?usize = null;
        var key: ?[]const u8 = null;
        var value: ?[]const u8 = null;
        var state: State = .root;
        var key_state: KeyState = .key;
        var has_content = false;

        var result: Meta = .init;
        result.raw = slice[0..];

        for (slice, 0..) |char, index| {
            switch (state) {
                .root => if (char == ' ') {
                    state = .name;
                    key_start = index + 1;
                },
                .name => if (char == '=') {
                    state = .equals;
                    key = slice[key_start.?..index];
                },
                .equals => if (char == '"') {
                    state = .value;
                    value_start = index + 1;
                },
                .value => if (char == '"') {
                    state = .root;
                    value = slice[value_start.?..index];
                },
            }

            if (key) |k| {
                if (std.meta.stringToEnum(MetaAttribute, k)) |meta_key| {
                    switch (meta_key) {
                        .name, .property => {
                            result.meta_key = meta_key;
                            key_state = .key;
                        },
                        .content => {
                            key_state = .value;
                            has_content = true;
                        },
                    }
                }

                key_start = null;
                key = null;
            }
            if (value) |v| {
                switch (key_state) {
                    .key => {
                        result.key = v;

                        if (std.mem.indexOf(u8, v, ":")) |colon_index| {
                            const prefix = v[0..colon_index];
                            if (std.meta.stringToEnum(Meta.Namespace, prefix)) |ns| {
                                result.namespace = ns;
                            }
                        }
                    },
                    .value => result.value = .init(v),
                }

                value_start = null;
                value = null;
            }
        }

        if (!has_content) {
            return null;
        }

        if (result.namespace == .html and !html_key_allow_list.has(result.key)) {
            return null;
        }

        return result;
    }
};

pub const ScanResult = struct {
    meta_tags: ArrayList(Meta) = .empty,
    errors: ArrayList(Issue) = .empty,
    warnings: ArrayList(Issue) = .empty,

    pub const Issue = struct {
        tag: Tag,
        severity: Severity = .err,
        schema: Schema,
        field: []const u8,
        reason: ?[]const u8 = null,

        pub const Severity = enum {
            err,
            warn,

            pub fn glyph(self: Severity) []const u8 {
                return switch (self) {
                    .err => "❌",
                    .warn => "⚠️",
                };
            }

            pub fn json(self: Severity) []const u8 {
                return switch (self) {
                    .err => "error",
                    .warn => "warning",
                };
            }
        };

        pub const Tag = enum {
            missing_required,
            invalid_url,
            invalid_attribute,

            pub fn label(self: Tag) []const u8 {
                return switch (self) {
                    .missing_required => "missing required field",
                    .invalid_url => "invalid URL",
                    .invalid_attribute => "invalid attribute",
                };
            }

            pub const json = label;
        };
    };

    pub const Schema = enum {
        opengraph,
        twitter,

        pub fn label(self: Schema) []const u8 {
            return switch (self) {
                .opengraph => "OpenGraph",
                .twitter => "Twitter Card",
            };
        }

        pub fn json(self: Schema) []const u8 {
            return @tagName(self);
        }

        pub fn namespaces(self: Schema) []const Meta.Namespace {
            return switch (self) {
                .opengraph => &.{ .og, .article, .book, .profile, .music, .video },
                .twitter => &.{.twitter},
            };
        }
    };

    const init: ScanResult = .{};

    pub fn scan(allocator: Allocator, slice: []const u8) !ScanResult {
        var offset: usize = 0;
        var result: ScanResult = .init;
        var meta_tags = &result.meta_tags;

        if (std.ascii.indexOfIgnoreCase(slice, "<title>")) |start| {
            if (std.ascii.indexOfIgnoreCasePos(slice, start, "</title>")) |end| {
                try meta_tags.append(allocator, .{
                    .key = "title",
                    .value = .init(slice[(start + "<title>".len)..end]),
                    .namespace = .html,
                });
            }
        }

        while (std.ascii.indexOfIgnoreCasePos(slice, offset, "<meta ")) |start| {
            if (std.ascii.indexOfIgnoreCasePos(slice, start, ">")) |end| {
                if (Meta.parse(slice[start..(end + 1)])) |meta| {
                    try meta_tags.append(allocator, meta);
                }
            }

            offset = start + 1;
        }

        return result;
    }

    pub fn deinit(self: *ScanResult, allocator: Allocator) void {
        self.meta_tags.deinit(allocator);
        self.errors.deinit(allocator);
        self.warnings.deinit(allocator);
    }

    pub const ValidateResult = enum {
        success,
        errors,
        warnings_only,
    };

    const url_keys: StaticStringMap([]const []const u8) = .initComptime(&.{
        .{
            @tagName(Schema.opengraph), &.{
                "og:url",
                // image
                "og:image",
                "og:image:url",
                "og:image:secure_url",
                // audio
                "og:audio",
                "og:audio:url",
                "og:audio:secure_url",
                // video
                "og:video",
                "og:video:url",
                "og:video:secure_url",
                // payment
                "payment:success_url",
            },
        },

        .{
            @tagName(Schema.twitter),
            &.{
                "twitter:url",
                // image
                "twitter:image",
                "twitter:image:src",
                //player
                "twitter:player",
                "twitter:player:url",
                "twitter:player:stream",
            },
        },
    });

    fn validateUrlsForSchema(self: *ScanResult, allocator: Allocator, schema: Schema) !void {
        if (url_keys.get(@tagName(schema))) |keys| for (keys) |key| {
            try self.requireValidUrl(allocator, schema, key);
        };
    }

    fn expectMetaAttribute(self: *ScanResult, allocator: Allocator, meta: Meta) !void {
        const expected = meta.namespace.requiredAttribute();
        if (meta.meta_key == expected) return;

        const reason = try std.fmt.allocPrint(allocator, "expected {}, got {}", .{ expected, meta.meta_key });

        try self.appendIssue(allocator, .{
            .tag = .invalid_attribute,
            .severity = meta.namespace.attributeMismatchSeverity(),
            .schema = meta.namespace.schema(),
            .field = meta.key,
            .reason = reason,
        });
    }

    fn validateMetaKeys(self: *ScanResult, allocator: Allocator) !void {
        for (self.meta_tags.items) |meta| {
            try self.expectMetaAttribute(allocator, meta);
        }
    }

    pub fn validate(self: *ScanResult, allocator: Allocator, schemas: []const Schema) !ValidateResult {
        try self.validateMetaKeys(allocator);

        for (schemas) |schema| {
            switch (schema) {
                .opengraph => {
                    try self.requireKey(allocator, .opengraph, "og:title");
                    try self.requireAnyKey(allocator, .opengraph, &.{ "og:image", "og:image:url" });
                    try self.requireKey(allocator, .opengraph, "og:type");
                    try self.requireKey(allocator, .opengraph, "og:url");
                },
                .twitter => {
                    try self.requireKey(allocator, .twitter, "twitter:card");
                    try self.requireAnyKey(allocator, .twitter, &.{ "twitter:title", "og:title" });
                    try self.requireAnyKey(allocator, .twitter, &.{ "twitter:image", "og:image" });
                },
            }

            try self.validateUrlsForSchema(allocator, schema);
        }

        if (self.errors.items.len > 0) return .errors;
        if (self.warnings.items.len > 0) return .warnings_only;
        return .success;
    }

    fn requireValidUrl(self: *ScanResult, allocator: Allocator, schema: Schema, key: []const u8) !void {
        if (self.findByKey(key)) |meta| {
            const url = std.Uri.parse(meta.value.raw) catch {
                try self.appendIssue(allocator, .{
                    .tag = .invalid_url,
                    .schema = schema,
                    .field = key,
                    .reason = "not a valid URL or not absolute",
                });
                return;
            };

            // URLs must be http or https scheme
            if (!(std.mem.eql(u8, url.scheme, "http") or std.mem.eql(u8, url.scheme, "https"))) {
                try self.appendIssue(allocator, .{
                    .tag = .invalid_url,
                    .schema = schema,
                    .field = key,
                    .reason = "must use http or https scheme",
                });
                return;
            }

            switch (try fetch.headStatus(allocator, url)) {
                .ok => {},
                else => |status| {
                    try self.appendIssue(allocator, .{
                        .tag = .invalid_url,
                        .schema = schema,
                        .field = key,
                        .reason = try std.fmt.allocPrint(allocator, "URL returned status: {s}", .{status.phrase() orelse "Unknown"}),
                    });
                },
            }
        }
    }

    fn requireKey(self: *ScanResult, allocator: Allocator, schema: Schema, key: []const u8) !void {
        if (self.findByKey(key) == null) {
            try self.appendIssue(allocator, .{
                .tag = .missing_required,
                .schema = schema,
                .field = key,
            });
        }
    }

    fn requireAnyKey(self: *ScanResult, allocator: Allocator, schema: Schema, keys: []const []const u8) !void {
        for (keys) |k| if (self.findByKey(k) != null) return;
        try self.appendIssue(allocator, .{
            .tag = .missing_required,
            .schema = schema,
            .field = keys[0], // report the preferred key
        });
    }

    fn appendIssue(self: *ScanResult, allocator: Allocator, issue: Issue) !void {
        switch (issue.severity) {
            .err => try self.errors.append(allocator, issue),
            .warn => try self.warnings.append(allocator, issue),
        }
    }

    pub fn findByKey(self: *const ScanResult, key: []const u8) ?*const Meta {
        for (self.meta_tags.items) |*meta| {
            if (std.mem.eql(u8, meta.key, key)) {
                return meta;
            }
        }

        return null;
    }

    pub fn hasErrors(self: *const ScanResult) bool {
        return self.errors.items.len > 0;
    }

    pub fn hasWarnings(self: *const ScanResult) bool {
        return self.warnings.items.len > 0;
    }

    pub fn getIssuesSorted(self: ScanResult, allocator: Allocator) ![]const Issue {
        const all_issues = try std.mem.concat(allocator, Issue, &.{ self.errors.items, self.warnings.items });
        std.mem.sortUnstable(Issue, all_issues, {}, issueLessThan);
        return all_issues;
    }

    fn issueLessThan(_: void, a: Issue, b: Issue) bool {
        const a_schema = @intFromEnum(a.schema);
        const b_schema = @intFromEnum(b.schema);
        if (a_schema != b_schema) return a_schema < b_schema;

        const a_sev = @intFromEnum(a.severity);
        const b_sev = @intFromEnum(b.severity);
        if (a_sev != b_sev) return a_sev < b_sev;

        const a_tag = @intFromEnum(a.tag);
        const b_tag = @intFromEnum(b.tag);
        if (a_tag != b_tag) return a_tag < b_tag;

        return std.mem.lessThan(u8, a.field, b.field);
    }
};

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const StaticStringMap = std.StaticStringMap;
const Writer = std.Io.Writer;

const html_entities = @import("html_entities").characters;

const fetch = @import("fetch.zig");

fn expectFormat(expected: []const u8, raw: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const value: Meta.Value = .init(raw);
    try value.format(&out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "Value.format passes plain text through unchanged" {
    try expectFormat("hello world", "hello world");
}

test "Value.format decodes decimal numeric entities" {
    try expectFormat("ABC", "&#65;&#66;&#67;");
}

test "Value.format decodes hex numeric entities (lower and upper case prefix)" {
    try expectFormat("AB", "&#x41;&#X42;");
}

test "Value.format encodes numeric codepoints as UTF-8" {
    // U+2603 SNOWMAN → E2 98 83
    try expectFormat("\xe2\x98\x83", "&#x2603;");
}

test "Value.format decodes common named entities" {
    try expectFormat("AT&T <hello>", "AT&amp;T &lt;hello&gt;");
}

test "Value.format decodes named entity to multi-byte UTF-8" {
    // &copy; → U+00A9 → C2 A9
    try expectFormat("\xc2\xa9", "&copy;");
}

test "Value.format decodes named entity mapped to multiple codepoints" {
    // &NotEqualTilde; → U+2242 U+0338 → E2 89 82 CC B8
    try expectFormat("\xe2\x89\x82\xcc\xb8", "&NotEqualTilde;");
}

test "Value.format passes unknown named entities through unchanged" {
    try expectFormat("&notarealentity;", "&notarealentity;");
}

test "Value.format passes a bare ampersand through" {
    try expectFormat("A & B", "A & B");
}

test "Value.format leaves malformed numeric entities intact" {
    try expectFormat("&#notanumber;", "&#notanumber;");
}

test "Value.format handles text mixed with entities" {
    try expectFormat(
        "Hello & welcome to A world",
        "Hello &amp; welcome to &#65; world",
    );
}

test "Value.format leaves an unterminated entity reference intact" {
    try expectFormat("&amp no semicolon", "&amp no semicolon");
}

fn runValidate(
    allocator: Allocator,
    html: []const u8,
    schemas: []const ScanResult.Schema,
) !struct { result: ScanResult, status: ScanResult.ValidateResult } {
    var result = try ScanResult.scan(allocator, html);
    const status = try result.validate(allocator, schemas);
    return .{ .result = result, .status = status };
}

fn findIssue(
    issues: []const ScanResult.Issue,
    tag: ScanResult.Issue.Tag,
    field: []const u8,
) ?ScanResult.Issue {
    for (issues) |i| {
        if (i.tag == tag and std.mem.eql(u8, i.field, field)) return i;
    }
    return null;
}

const valid_og_html =
    \\<meta property="og:title" content="Hello">
    \\<meta property="og:image" content="https://example.com/img.png">
    \\<meta property="og:type" content="website">
    \\<meta property="og:url" content="https://example.com">
;

test "validate: minimal valid opengraph → success" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const v = try runValidate(arena.allocator(), valid_og_html, &.{.opengraph});
    try testing.expect(v.status == .success);
    try testing.expectEqual(@as(usize, 0), v.result.errors.items.len);
    try testing.expectEqual(@as(usize, 0), v.result.warnings.items.len);
}

test "validate: og:image:url satisfies image requirement" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html =
        \\<meta property="og:title" content="Hello">
        \\<meta property="og:image:url" content="https://example.com/img.png">
        \\<meta property="og:type" content="website">
        \\<meta property="og:url" content="https://example.com">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.opengraph});
    try testing.expect(v.status == .success);
}

test "validate: missing og:title → missing_required error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html =
        \\<meta property="og:image" content="https://example.com/img.png">
        \\<meta property="og:type" content="website">
        \\<meta property="og:url" content="https://example.com">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.opengraph});
    try testing.expect(v.status == .errors);
    try testing.expect(findIssue(v.result.errors.items, .missing_required, "og:title") != null);
}

test "validate: empty document → all required opengraph fields missing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const v = try runValidate(arena.allocator(), "", &.{.opengraph});
    try testing.expect(v.status == .errors);
    try testing.expect(findIssue(v.result.errors.items, .missing_required, "og:title") != null);
    try testing.expect(findIssue(v.result.errors.items, .missing_required, "og:image") != null);
    try testing.expect(findIssue(v.result.errors.items, .missing_required, "og:type") != null);
    try testing.expect(findIssue(v.result.errors.items, .missing_required, "og:url") != null);
}

test "validate: opengraph tag with name= → invalid_attribute error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html =
        \\<meta name="og:title" content="Hello">
        \\<meta property="og:image" content="https://example.com/img.png">
        \\<meta property="og:type" content="website">
        \\<meta property="og:url" content="https://example.com">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.opengraph});
    try testing.expect(v.status == .errors);
    const issue = findIssue(v.result.errors.items, .invalid_attribute, "og:title") orelse return error.TestExpectedIssue;
    try testing.expect(issue.severity == .err);
}

test "validate: twitter tag with property= → invalid_attribute warning" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html =
        \\<meta property="twitter:card" content="summary">
        \\<meta name="twitter:title" content="Hello">
        \\<meta name="twitter:image" content="https://example.com/img.png">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.twitter});
    try testing.expect(v.status == .warnings_only);
    const issue = findIssue(v.result.warnings.items, .invalid_attribute, "twitter:card") orelse return error.TestExpectedIssue;
    try testing.expect(issue.severity == .warn);
    try testing.expect(issue.schema == .twitter);
}

test "validate: html meta with property= → invalid_attribute warning" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html = valid_og_html ++
        \\
        \\<meta property="description" content="A page">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.opengraph});
    try testing.expect(v.status == .warnings_only);
    const issue = findIssue(v.result.warnings.items, .invalid_attribute, "description") orelse return error.TestExpectedIssue;
    try testing.expect(issue.severity == .warn);
}

test "validate: html meta with name= is not flagged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html = valid_og_html ++
        \\
        \\<meta name="description" content="A page">
        \\<meta name="author" content="Jane">
        \\<meta name="keywords" content="one,two">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.opengraph});
    try testing.expect(v.status == .success);
}

test "validate: <title> element does not trigger attribute warning" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html = "<title>My Page</title>\n" ++ valid_og_html;

    const v = try runValidate(arena.allocator(), html, &.{.opengraph});
    try testing.expect(v.status == .success);
}

test "validate: invalid URL is flagged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html =
        \\<meta property="og:title" content="Hello">
        \\<meta property="og:image" content="not a url">
        \\<meta property="og:type" content="website">
        \\<meta property="og:url" content="https://example.com">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.opengraph});
    try testing.expect(v.status == .errors);
    try testing.expect(findIssue(v.result.errors.items, .invalid_url, "og:image") != null);
}

test "validate: non-http URL scheme is flagged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html =
        \\<meta property="og:title" content="Hello">
        \\<meta property="og:image" content="javascript:alert(1)">
        \\<meta property="og:type" content="website">
        \\<meta property="og:url" content="https://example.com">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.opengraph});
    try testing.expect(v.status == .errors);
    try testing.expect(findIssue(v.result.errors.items, .invalid_url, "og:image") != null);
}

test "validate: twitter requires card, title, image (with og fallback)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html =
        \\<meta name="twitter:card" content="summary">
        \\<meta property="og:title" content="Hello">
        \\<meta property="og:image" content="https://example.com/img.png">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.twitter});
    try testing.expect(v.status == .success);
}

test "validate: missing twitter:card is flagged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html =
        \\<meta name="twitter:title" content="Hello">
        \\<meta name="twitter:image" content="https://example.com/img.png">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.twitter});
    try testing.expect(v.status == .errors);
    try testing.expect(findIssue(v.result.errors.items, .missing_required, "twitter:card") != null);
}

test "validate: errors dominate warnings in status" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html =
        \\<meta name="og:title" content="Hello">
        \\<meta property="og:image" content="https://example.com/img.png">
        \\<meta property="og:type" content="website">
        \\<meta property="og:url" content="https://example.com">
        \\<meta property="description" content="A page">
    ;

    const v = try runValidate(arena.allocator(), html, &.{.opengraph});
    try testing.expect(v.status == .errors);
    try testing.expect(v.result.errors.items.len >= 1);
    try testing.expect(v.result.warnings.items.len >= 1);
}

test "validate: both schemas validated in one pass" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const html = valid_og_html ++
        \\
        \\<meta name="twitter:card" content="summary">
    ;

    const v = try runValidate(arena.allocator(), html, &.{ .opengraph, .twitter });
    try testing.expect(v.status == .success);
}

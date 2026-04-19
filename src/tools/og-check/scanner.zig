pub const Meta = struct {
    raw: []const u8 = "",
    key: []const u8 = "",
    value: Value = .empty,
    namespace: Namespace = .html,

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

    pub const MetaKey = enum {
        name,
        property,
        content,
    };

    const key_map: StaticStringMap(MetaKey) = .initComptime(&.{
        .{ "name", MetaKey.name },
        .{ "property", MetaKey.property },
        .{ "content", MetaKey.content },
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
                if (std.meta.stringToEnum(MetaKey, k)) |meta_key| switch (meta_key) {
                    .name, .property => {
                        key_state = .key;
                    },
                    .content => {
                        key_state = .value;
                        has_content = true;
                    },
                };

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

            pub fn label(self: Tag) []const u8 {
                return switch (self) {
                    .missing_required => "missing required field",
                    .invalid_url => "invalid URL",
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

    pub fn validate(self: *ScanResult, allocator: Allocator, schemas: []const Schema) !ValidateResult {
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
                });
                return;
            };

            // URLs must be http or https scheme
            if (!(std.mem.eql(u8, url.scheme, "http") or std.mem.eql(u8, url.scheme, "https"))) {
                try self.appendIssue(allocator, .{
                    .tag = .invalid_url,
                    .schema = schema,
                    .field = key,
                });
                return;
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

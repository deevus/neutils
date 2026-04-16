pub const Meta = struct {
    raw: []const u8 = "",
    key: []const u8 = "",
    value: Value = .{},
    namespace: Namespace = .html,

    const init: Meta = .{};

    pub const Value = struct {
        raw: []const u8 = "",

        pub fn init(value: []const u8) Value {
            return .{
                .raw = value,
            };
        }

        pub fn format(self: Value, writer: *Writer) !void {
            const html_entities = std.StaticStringMap(u8).initComptime(.{
                .{ "lt", '<' },
                .{ "gt", '>' },
                .{ "amp", '&' },
                .{ "apos", '\'' },
                .{ "quot", '"' },
            });

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
                    } else if (html_entities.get(slice)) |d| {
                        try writer.writeByte(d);
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

                        if (std.mem.startsWith(u8, v, "og:")) {
                            result.namespace = .og;
                        } else if (std.mem.startsWith(u8, v, "twitter:")) {
                            result.namespace = .twitter;
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
    issues: ArrayList(Issue) = .empty,

    pub const Issue = struct {
        tag: Tag,
        severity: Severity = .err,
        schema: ?Schema = null,
        field: []const u8,

        pub const Severity = enum {
            err,
            warn,
        };

        pub const Tag = enum {
            missing_required,
        };
    };

    pub const Schema = enum {
        opengraph,
        twitter,
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
        self.issues.deinit(allocator);
    }

    pub const ValidateResult = enum {
        success,
        failure,
    };

    pub fn validate(self: *ScanResult, allocator: Allocator, schemas: []const Schema) !ValidateResult {
        for (schemas) |schema| {
            switch (schema) {
                .opengraph => {
                    try self.requireKey(allocator, .opengraph, "og:title");
                    try self.requireKey(allocator, .opengraph, "og:image");
                    try self.requireKey(allocator, .opengraph, "og:type");
                    try self.requireKey(allocator, .opengraph, "og:url");
                },
                .twitter => {
                    try self.requireKey(allocator, .twitter, "twitter:card");
                    try self.requireAnyKey(allocator, .twitter, &.{ "twitter:title", "og:title" });
                    try self.requireAnyKey(allocator, .twitter, &.{ "twitter:image", "og:image" });
                },
            }
        }

        return if (self.issues.items.len > 0) .failure else .success;
    }

    fn requireKey(self: *ScanResult, gpa: Allocator, schema: Schema, key: []const u8) !void {
        if (self.findByKey(key) == null) {
            try self.issues.append(gpa, .{
                .tag = .missing_required,
                .schema = schema,
                .field = key,
            });
        }
    }

    fn requireAnyKey(self: *ScanResult, gpa: Allocator, schema: Schema, keys: []const []const u8) !void {
        for (keys) |k| if (self.findByKey(k) != null) return;
        try self.issues.append(gpa, .{
            .tag = .missing_required,
            .schema = schema,
            .field = keys[0], // report the preferred key
        });
    }

    pub fn findByKey(self: *const ScanResult, key: []const u8) ?*const Meta {
        for (self.meta_tags.items) |*meta| {
            if (std.mem.eql(u8, meta.key, key)) {
                return meta;
            }
        }

        return null;
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const StaticStringMap = std.StaticStringMap;
const Writer = std.Io.Writer;

const Config = @import("Config.zig");

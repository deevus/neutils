const MarkdownBuilder = @This();

writer: AllocatingWriter,

pub const RenderFormat = enum {
    plain,
    pretty,
};

pub fn init(allocator: Allocator) MarkdownBuilder {
    return .{
        .writer = AllocatingWriter.init(allocator),
    };
}

pub fn deinit(self: *MarkdownBuilder) void {
    self.writer.deinit();
}

pub fn writeAll(self: *MarkdownBuilder, str: []const u8) !void {
    const writer = &self.writer.writer;
    try writer.writeAll(str);
}

pub fn print(self: *MarkdownBuilder, comptime fmt: []const u8, args: anytype) !void {
    const writer = &self.writer.writer;
    try writer.print(fmt, args);
}

pub fn render(self: *MarkdownBuilder, allocator: Allocator, comptime format: RenderFormat, writer: *Writer) !void {
    const markdown_text = self.writer.written();

    if (format == .plain) {
        try writer.writeAll(markdown_text);
        return;
    }

    var parser: Parser = .init(allocator, .{});
    defer parser.deinit();
    try parser.parseMarkdown(markdown_text);

    const terminal_size: TermSize = zigdown.gfx.getTerminalSize() catch .{};

    var renderer: ConsoleRenderer = .init(writer, allocator, .{
        .termsize = terminal_size,
    });
    defer renderer.deinit();

    try renderer.renderBlock(parser.document);
    try writer.flush();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const AllocatingWriter = Writer.Allocating;

const zigdown = @import("zigdown");
const Parser = zigdown.Parser;
const TermSize = zigdown.gfx.TermSize;
const ConsoleRenderer = zigdown.ConsoleRenderer;

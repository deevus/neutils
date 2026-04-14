pub fn renderMarkdownToTerminal(allocator: Allocator, markdown: []const u8, writer: *Writer) !void {
    var parser: Parser = .init(allocator, .{});
    defer parser.deinit();
    try parser.parseMarkdown(markdown);

    const terminal_size: TermSize = zigdown.gfx.getTerminalSize() catch .{};

    var renderer: ConsoleRenderer = .init(writer, allocator, .{
        .termsize = terminal_size,
    });
    defer renderer.deinit();

    try renderer.renderBlock(parser.document);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const zigdown = @import("zigdown");
const Parser = zigdown.Parser;
const TermSize = zigdown.gfx.TermSize;
const ConsoleRenderer = zigdown.ConsoleRenderer;

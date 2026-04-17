//! Terminal rendering for accumulated markdown text via zigdown. Kept separate
//! from `Document` so `Document` has no renderer dependency.

pub fn renderPretty(allocator: Allocator, markdown_text: []const u8, writer: *Writer) !void {
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

const zigdown = @import("zigdown");
const Parser = zigdown.Parser;
const TermSize = zigdown.gfx.TermSize;
const ConsoleRenderer = zigdown.ConsoleRenderer;

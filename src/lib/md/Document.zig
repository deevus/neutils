//! Builds a markdown document into a caller-supplied `std.Io.Writer` with
//! context-aware escaping for user-controlled content. Mirrors the shape of
//! `std.json.Stringify`: the caller owns the writer, this struct only holds
//! transient grammar state.
//!
//! The sequence of method calls must follow this grammar:
//!
//! ```
//! <document>  = <block>*
//! <block>     = <heading> | <paragraph> | <list> | <table> | writeRaw | print
//! <heading>   = heading | ( beginHeading <inline>* endHeading )
//! <paragraph> = beginParagraph <inline>* endParagraph
//! <list>      = beginBulletList <list_item>* endBulletList
//! <list_item> = beginListItem <inline>* endListItem
//! <table>     = beginTable ( beginRow <inline>* endRow )* endTable
//! <inline>    = write | writeRaw | print | writeFormatted
//!             | bold | code | link | image | cell
//! ```
//!
//! `write` and `writeFormatted` escape their input according to the current
//! context (table cell, inline prose, code span). `writeRaw` and `print` pass
//! bytes through unchanged and are intended for callers that are constructing
//! their own markdown syntax. Grammar violations trip a debug assertion.

const Document = @This();

writer: *Writer,
state: State = .document,
block_stack: [16]Block = undefined,
block_depth: u8 = 0,

const State = enum {
    document,
    block_inline,
    table_row,
    code_span,
};

const Block = enum {
    heading,
    paragraph,
    list,
    list_item,
    table,
    table_row,
};

pub fn init(writer: *Writer) Document {
    return .{ .writer = writer };
}

// ---------------------------------------------------------------------------
// Block-level structural methods
// ---------------------------------------------------------------------------

pub fn heading(self: *Document, level: u3, text: []const u8) !void {
    try self.beginHeading(level);
    try self.write(text);
    try self.endHeading();
}

pub fn beginHeading(self: *Document, level: u3) !void {
    assert(self.state == .document);
    assert(level >= 1 and level <= 6);
    for (0..level) |_| try self.writer.writeByte('#');
    try self.writer.writeByte(' ');
    self.pushBlock(.heading);
    self.state = .block_inline;
}

pub fn endHeading(self: *Document) !void {
    assert(self.state == .block_inline);
    assert(self.currentBlock() == .heading);
    try self.writer.writeAll("\n\n");
    self.popBlock(.heading);
    self.state = .document;
}

pub fn beginParagraph(self: *Document) !void {
    assert(self.state == .document);
    self.pushBlock(.paragraph);
    self.state = .block_inline;
}

pub fn endParagraph(self: *Document) !void {
    assert(self.state == .block_inline);
    assert(self.currentBlock() == .paragraph);
    try self.writer.writeAll("\n\n");
    self.popBlock(.paragraph);
    self.state = .document;
}

pub fn beginBulletList(self: *Document) !void {
    assert(self.state == .document);
    self.pushBlock(.list);
}

pub fn endBulletList(self: *Document) !void {
    assert(self.state == .document);
    assert(self.currentBlock() == .list);
    try self.writer.writeByte('\n');
    self.popBlock(.list);
}

pub fn beginListItem(self: *Document) !void {
    assert(self.state == .document);
    assert(self.currentBlock() == .list);
    try self.writer.writeAll(" - ");
    self.pushBlock(.list_item);
    self.state = .block_inline;
}

pub fn endListItem(self: *Document) !void {
    assert(self.state == .block_inline);
    assert(self.currentBlock() == .list_item);
    try self.writer.writeByte('\n');
    self.popBlock(.list_item);
    self.state = .document;
}

pub fn beginTable(self: *Document, headers: []const []const u8) !void {
    assert(self.state == .document);
    self.pushBlock(.table);

    // Header row (escape headers in table-cell context just in case).
    self.state = .table_row;
    try self.writer.writeByte('|');
    for (headers) |h| {
        try self.writeEscaped(h);
        try self.writer.writeByte('|');
    }
    try self.writer.writeByte('\n');
    self.state = .document;

    // Separator row.
    try self.writer.writeByte('|');
    for (headers) |_| try self.writer.writeAll("-|");
    try self.writer.writeByte('\n');
}

pub fn endTable(self: *Document) !void {
    assert(self.state == .document);
    assert(self.currentBlock() == .table);
    try self.writer.writeByte('\n');
    self.popBlock(.table);
}

pub fn beginRow(self: *Document) !void {
    assert(self.state == .document);
    assert(self.currentBlock() == .table);
    try self.writer.writeByte('|');
    self.pushBlock(.table_row);
    self.state = .table_row;
}

pub fn endRow(self: *Document) !void {
    assert(self.state == .table_row);
    assert(self.currentBlock() == .table_row);
    try self.writer.writeByte('\n');
    self.popBlock(.table_row);
    self.state = .document;
}

pub fn cell(self: *Document, text: []const u8) !void {
    assert(self.state == .table_row);
    try self.writeEscaped(text);
    try self.writer.writeByte('|');
}

// ---------------------------------------------------------------------------
// Inline helpers (usable inside block_inline or table_row)
// ---------------------------------------------------------------------------

pub fn bold(self: *Document, text: []const u8) !void {
    assert(self.state == .block_inline or self.state == .table_row);
    try self.writer.writeAll("**");
    try self.writeEscaped(text);
    try self.writer.writeAll("**");
}

pub fn code(self: *Document, text: []const u8) !void {
    assert(self.state == .block_inline or self.state == .table_row);
    try self.writer.writeByte('`');
    const prev = self.state;
    self.state = .code_span;
    try self.writeEscaped(text);
    self.state = prev;
    try self.writer.writeByte('`');
}

pub fn link(self: *Document, label: []const u8, url: []const u8) !void {
    assert(self.state == .block_inline or self.state == .table_row);
    try self.writer.writeByte('[');
    try self.writeEscaped(label);
    try self.writer.writeAll("](");
    try writeUrl(self.writer, url);
    try self.writer.writeByte(')');
}

pub fn image(self: *Document, alt: []const u8, url: []const u8) !void {
    assert(self.state == .block_inline or self.state == .table_row);
    try self.writer.writeAll("![");
    try self.writeEscaped(alt);
    try self.writer.writeAll("](");
    try writeUrl(self.writer, url);
    try self.writer.writeByte(')');
}

// ---------------------------------------------------------------------------
// Content writers
// ---------------------------------------------------------------------------

/// Write user-controlled content with escaping applied per current state.
pub fn write(self: *Document, text: []const u8) !void {
    assert(self.state != .document);
    try self.writeEscaped(text);
}

/// Pass bytes through without escaping. Caller is responsible for any
/// escaping required by surrounding context.
pub fn writeRaw(self: *Document, text: []const u8) !void {
    try self.writer.writeAll(text);
}

/// Format raw bytes into the output without escaping. Mirrors
/// `std.json.Stringify.print`: the caller is responsible for ensuring the
/// formatted result is valid markdown in the current context.
pub fn print(self: *Document, comptime fmt: []const u8, args: anytype) !void {
    try self.writer.print(fmt, args);
}

/// Format a value that implements `format(writer)` and escape its output
/// according to the current context. Streams directly through an escaping
/// writer so no scratch allocation is needed.
pub fn writeFormatted(self: *Document, value: anytype) !void {
    assert(self.state != .document);

    var escaping: EscapingWriter = .init(self.writer, self.state);
    try value.format(&escaping.writer);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn currentBlock(self: *const Document) ?Block {
    if (self.block_depth == 0) return null;
    return self.block_stack[self.block_depth - 1];
}

fn pushBlock(self: *Document, block: Block) void {
    assert(self.block_depth < self.block_stack.len);
    self.block_stack[self.block_depth] = block;
    self.block_depth += 1;
}

fn popBlock(self: *Document, expected: Block) void {
    assert(self.block_depth > 0);
    assert(self.block_stack[self.block_depth - 1] == expected);
    self.block_depth -= 1;
}

fn writeEscaped(self: *Document, text: []const u8) !void {
    try writeEscapedBytes(self.writer, self.state, text);
}

fn writeEscapedBytes(w: *Writer, state: State, text: []const u8) !void {
    switch (state) {
        .document => unreachable,
        .table_row => {
            for (text) |c| switch (c) {
                '|' => try w.writeAll("\\|"),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("<br>"),
                '\r' => {},
                else => try w.writeByte(c),
            };
        },
        .block_inline => {
            for (text) |c| switch (c) {
                '\\', '`', '*', '_', '[', ']', '<', '>', '#', '|', '!' => {
                    try w.writeByte('\\');
                    try w.writeByte(c);
                },
                else => try w.writeByte(c),
            };
        },
        .code_span => {
            for (text) |c| switch (c) {
                '`' => try w.writeByte(' '),
                else => try w.writeByte(c),
            };
        },
    }
}

/// Unbuffered `std.Io.Writer` that applies the active escape set byte-for-byte
/// while forwarding to an underlying writer. Used by `writeFormatted` so a
/// value's `format(writer)` output is escaped inline without a scratch buffer.
const EscapingWriter = struct {
    writer: Writer,
    underlying: *Writer,
    state: State,

    const vtable: Writer.VTable = .{
        .drain = drain,
    };

    fn init(underlying: *Writer, state: State) EscapingWriter {
        return .{
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
            .underlying = underlying,
            .state = state,
        };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *EscapingWriter = @fieldParentPtr("writer", w);

        for (data[0 .. data.len - 1]) |slice| {
            try writeEscapedBytes(self.underlying, self.state, slice);
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try writeEscapedBytes(self.underlying, self.state, last);
        }

        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| total += slice.len;
        total += last.len * splat;
        return total;
    }
};

fn writeUrl(w: *Writer, url: []const u8) !void {
    for (url) |c| switch (c) {
        '(' => try w.writeAll("%28"),
        ')' => try w.writeAll("%29"),
        ' ' => try w.writeAll("%20"),
        else => try w.writeByte(c),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testInit(aw: *Writer.Allocating) Document {
    return .init(&aw.writer);
}

test "heading emits hashes and escapes inline specials" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    try doc.heading(2, "# Hello *world*");
    try testing.expectEqualStrings("## \\# Hello \\*world\\*\n\n", aw.written());
}

test "paragraph with bold, code, link" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    try doc.beginParagraph();
    try doc.bold("Type");
    try doc.write(": ");
    try doc.code("og:image");
    try doc.write(" see ");
    try doc.link("here", "https://example.com/a b");
    try doc.endParagraph();

    try testing.expectEqualStrings(
        "**Type**: `og:image` see [here](https://example.com/a%20b)\n\n",
        aw.written(),
    );
}

test "image emits ![alt](url) with URL encoding" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    try doc.beginParagraph();
    try doc.image("a cat", "https://example.com/cat.png");
    try doc.endParagraph();

    try testing.expectEqualStrings(
        "![a cat](https://example.com/cat.png)\n\n",
        aw.written(),
    );
}

test "bullet list items escape inline specials" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    try doc.beginBulletList();

    try doc.beginListItem();
    try doc.write("first [one]");
    try doc.endListItem();

    try doc.beginListItem();
    try doc.write("second *two*");
    try doc.endListItem();

    try doc.endBulletList();

    try testing.expectEqualStrings(
        " - first \\[one\\]\n - second \\*two\\*\n\n",
        aw.written(),
    );
}

test "table escapes pipe, backslash, and newline in cells" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    try doc.beginTable(&.{ "Type", "Key", "Value" });

    try doc.beginRow();
    try doc.cell("html");
    try doc.cell("desc|ription");
    try doc.cell("line1\nline2\\path");
    try doc.endRow();

    try doc.endTable();

    try testing.expectEqualStrings(
        "|Type|Key|Value|\n" ++
            "|-|-|-|\n" ++
            "|html|desc\\|ription|line1<br>line2\\\\path|\n" ++
            "\n",
        aw.written(),
    );
}

test "table cell drops carriage returns" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    try doc.beginTable(&.{"Col"});
    try doc.beginRow();
    try doc.cell("a\r\nb");
    try doc.endRow();
    try doc.endTable();

    try testing.expectEqualStrings(
        "|Col|\n|-|\n|a<br>b|\n\n",
        aw.written(),
    );
}

test "writeFormatted routes custom format() through escape" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    const Pipey = struct {
        pub fn format(_: @This(), w: *Writer) !void {
            try w.writeAll("a|b|c");
        }
    };

    try doc.beginTable(&.{"V"});
    try doc.beginRow();
    try doc.writeFormatted(Pipey{});
    try doc.writer.writeByte('|');
    try doc.endRow();
    try doc.endTable();

    try testing.expectEqualStrings(
        "|V|\n|-|\n|a\\|b\\|c|\n\n",
        aw.written(),
    );
}

test "code span strips backticks" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    try doc.beginParagraph();
    try doc.code("a`b`c");
    try doc.endParagraph();

    try testing.expectEqualStrings("`a b c`\n\n", aw.written());
}

test "writeRaw and print pass through without escaping" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    try doc.writeRaw("# literal #\n\n");
    try doc.print("|{s}|\n", .{"x|y"});

    try testing.expectEqualStrings("# literal #\n\n|x|y|\n", aw.written());
}

test "heading with mixed inline content" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var doc: Document = testInit(&aw);

    try doc.beginHeading(1);
    try doc.write("Title: ");
    try doc.code("og:title");
    try doc.endHeading();

    try testing.expectEqualStrings("# Title: `og:title`\n\n", aw.written());
}

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Writer = std.Io.Writer;

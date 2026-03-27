pub fn main() !void {
    try cli.execute(std.heap.page_allocator, mboxDelta);
}

const MboxIndex = struct {
    const boundary = "\nFrom ";
    const msg_id_header = "Message-ID:";

    const Location = struct {
        start: usize,
        end: usize,
    };

    messages: std.StringHashMapUnmanaged(Location) = .empty,

    fn deinit(self: *MboxIndex, allocator: Allocator) void {
        var iter = self.messages.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.messages.deinit(allocator);
    }

    fn fillMore(reader: *Reader) !bool {
        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        return true;
    }

    const ExtractResult = struct {
        msg_id: []const u8,
        consumed: usize,
    };

    /// Extract Message-ID value from a header block.
    /// Returns the Message-ID and total bytes consumed from the reader.
    fn extractMessageId(self: *MboxIndex, allocator: Allocator, reader: *Reader) !?ExtractResult {
        var consumed: usize = 0;
        while (true) {
            const buf = reader.buffered();
            if (buf.len == 0) {
                if (!try fillMore(reader)) return null;
                continue;
            }

            // Check for end of headers (blank line)
            if (std.mem.indexOf(u8, buf, "\n\n")) |blank_pos| {
                const headers = buf[0..blank_pos];
                if (self.findMessageIdInSlice(allocator, headers)) |msg_id| {
                    return .{ .msg_id = msg_id, .consumed = consumed };
                }
                return null;
            }

            // Search what we have so far
            if (self.findMessageIdInSlice(allocator, buf)) |msg_id| {
                return .{ .msg_id = msg_id, .consumed = consumed };
            }

            // Haven't found end of headers yet — retain tail for partial match, fill more
            const toss_len = buf.len -| (msg_id_header.len + 256);
            reader.toss(toss_len);
            consumed += toss_len;
            if (!try fillMore(reader)) return null;
        }
    }

    fn findMessageIdInSlice(_: *MboxIndex, allocator: Allocator, slice: []const u8) ?[]const u8 {
        const header_start = std.mem.indexOf(u8, slice, msg_id_header) orelse return null;
        const value_start = header_start + msg_id_header.len;
        const rest = slice[value_start..];

        // Find end of line
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;

        // Trim whitespace around the value
        const raw_value = std.mem.trim(u8, rest[0..line_end], " \t\r");
        if (raw_value.len == 0) return null;

        return allocator.dupe(u8, raw_value) catch null;
    }

    pub fn load(self: *MboxIndex, allocator: Allocator, reader: *Reader) !void {
        var file_offset: usize = 0;
        var msg_start: ?usize = null;
        var current_msg_id: ?[]const u8 = null;

        // Handle first message (mbox files start with "From " without a leading newline)
        if (!try fillMore(reader)) return;
        const initial = reader.buffered();
        if (std.mem.startsWith(u8, initial, "From ")) {
            msg_start = 0; // include the envelope line
            if (std.mem.indexOfScalar(u8, initial, '\n')) |nl| {
                reader.toss(nl + 1);
                file_offset += nl + 1;
                if (try self.extractMessageId(allocator, reader)) |result| {
                    current_msg_id = result.msg_id;
                    file_offset += result.consumed;
                }
            }
        }

        while (true) {
            const buf = reader.buffered();
            if (buf.len == 0) {
                if (!try fillMore(reader)) break;
                continue;
            }

            if (std.mem.indexOf(u8, buf, boundary)) |pos| {
                const msg_end = file_offset + pos;

                // Store the completed message
                if (current_msg_id) |msg_id| {
                    if (msg_start) |start| {
                        try self.messages.put(allocator, msg_id, .{ .start = start, .end = msg_end });
                    }
                }

                // Advance past the \n before "From "
                reader.toss(pos + 1);
                file_offset += pos + 1;

                // msg_start includes the "From " envelope line
                msg_start = file_offset;

                // Skip past the envelope line for header extraction
                while (true) {
                    const rest = reader.buffered();
                    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                        reader.toss(nl + 1);
                        file_offset += nl + 1;
                        break;
                    }
                    reader.toss(rest.len);
                    file_offset += rest.len;
                    if (!try fillMore(reader)) break;
                }
                current_msg_id = null;
                if (try self.extractMessageId(allocator, reader)) |result| {
                    current_msg_id = result.msg_id;
                    file_offset += result.consumed;
                }
            } else {
                // No boundary found — retain tail for partial match
                const toss_len = buf.len -| (boundary.len - 1);
                reader.toss(toss_len);
                file_offset += toss_len;
                if (!try fillMore(reader)) break;
            }
        }

        // Store the last message
        if (current_msg_id) |msg_id| {
            if (msg_start) |start| {
                const remaining = reader.buffered();
                const msg_end = file_offset + remaining.len;
                try self.messages.put(allocator, msg_id, .{ .start = start, .end = msg_end });
            }
        }
    }
};

fn writeDelta(base: MboxIndex, new: MboxIndex, src_file: std.fs.File, writer: *Writer) !usize {
    var count: usize = 0;
    var iter = new.messages.iterator();
    while (iter.next()) |entry| {
        if (!base.messages.contains(entry.key_ptr.*)) {
            const loc = entry.value_ptr.*;
            const len = loc.end - loc.start;

            try src_file.seekTo(loc.start);
            var src_buf: [65536]u8 = undefined;
            var src_reader = src_file.reader(&src_buf);
            try src_reader.interface.streamExact64(writer, len);
            try writer.writeByte('\n');

            count += 1;
        }
    }

    try writer.flush();
    return count;
}

fn mboxDelta() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const base_file = try std.fs.cwd().openFile(cli.config.base_mbox, .{});
    defer base_file.close();

    const new_file = try std.fs.cwd().openFile(cli.config.new_mbox, .{});
    defer new_file.close();

    var read_buf: [65536]u8 = undefined;
    var base_reader = base_file.reader(&read_buf);

    var base_index: MboxIndex = .{};
    defer base_index.deinit(allocator);
    try base_index.load(allocator, &base_reader.interface);

    var new_reader = new_file.reader(&read_buf);
    var new_index: MboxIndex = .{};
    defer new_index.deinit(allocator);
    try new_index.load(allocator, &new_reader.interface);

    // Re-open new file for seeking to message offsets
    const src_file = try std.fs.cwd().openFile(cli.config.new_mbox, .{});
    defer src_file.close();

    const output_file = try std.fs.cwd().createFile(cli.config.output, .{});
    defer output_file.close();
    var out_buf: [65536]u8 = undefined;
    var out_writer = output_file.writer(&out_buf);

    const new_count = try writeDelta(base_index, new_index, src_file, &out_writer.interface);

    const stderr = std.fs.File.stderr();
    var stderr_buf: [256]u8 = undefined;
    var stderr_writer = stderr.writer(&stderr_buf);
    try stderr_writer.interface.print("{d} new messages written to {s}\n", .{ new_count, cli.config.output });
    try stderr_writer.interface.flush();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const cli = @import("cli.zig");

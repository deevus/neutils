pub fn main() !void {
    try cli.execute(std.heap.page_allocator, mboxDelta);
}

const MboxIndex = struct {
    const boundary = "\nFrom ";
    const msg_id_header = "Message-ID:";

    const Location = struct {
        start: u64,
        end: u64,
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

    /// Extract Message-ID value from a header block.
    fn extractMessageId(self: *MboxIndex, allocator: Allocator, reader: *Reader) !?[]const u8 {
        while (true) {
            const buf = reader.buffered();
            if (buf.len == 0) {
                if (!try fillMore(reader)) return null;
                continue;
            }

            // Check for end of headers (blank line)
            if (std.mem.indexOf(u8, buf, "\n\n")) |blank_pos| {
                const headers = buf[0..blank_pos];
                return self.findMessageIdInSlice(allocator, headers);
            }

            // Search what we have so far
            if (self.findMessageIdInSlice(allocator, buf)) |msg_id| {
                return msg_id;
            }

            // Haven't found end of headers yet — retain tail for partial match, fill more
            reader.toss(buf.len -| (msg_id_header.len + 256));
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

    fn filePos(file: File, reader: *Reader) u64 {
        return (file.getPos() catch 0) - reader.bufferedLen();
    }

    pub fn load(self: *MboxIndex, allocator: Allocator, file: File) !void {
        var read_buf: [65536]u8 = undefined;
        var stream = file.readerStreaming(&read_buf);
        const reader = &stream.interface;

        var msg_start: ?u64 = null;
        var current_msg_id: ?[]const u8 = null;

        // Handle first message (mbox files start with "From " without a leading newline)
        if (!try fillMore(reader)) return;
        const initial = reader.buffered();
        if (std.mem.startsWith(u8, initial, boundary[1..])) {
            msg_start = 0;
            if (std.mem.indexOfScalar(u8, initial, '\n')) |nl| {
                reader.toss(nl + 1);
                current_msg_id = try self.extractMessageId(allocator, reader);
            }
        }

        while (true) {
            const buf = reader.buffered();
            if (buf.len == 0) {
                if (!try fillMore(reader)) break;
                continue;
            }

            if (std.mem.indexOf(u8, buf, boundary)) |pos| {
                // End of previous message is at current position + offset to the \n
                const msg_end = filePos(file, reader) + pos;

                if (current_msg_id) |msg_id| {
                    if (msg_start) |start| {
                        try self.messages.put(allocator, msg_id, .{ .start = start, .end = msg_end });
                    }
                }

                // Advance past the \n before "From "
                reader.toss(pos + 1);

                // msg_start includes the "From " envelope line
                msg_start = filePos(file, reader);

                // Skip past the envelope line for header extraction
                while (true) {
                    const rest = reader.buffered();
                    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                        reader.toss(nl + 1);
                        break;
                    }
                    reader.toss(rest.len);
                    if (!try fillMore(reader)) break;
                }
                current_msg_id = try self.extractMessageId(allocator, reader);
            } else {
                // No boundary found — retain tail for partial match
                reader.toss(buf.len -| (boundary.len - 1));
                if (!try fillMore(reader)) break;
            }
        }

        // Store the last message
        if (current_msg_id) |msg_id| {
            if (msg_start) |start| {
                const msg_end = filePos(file, reader) + reader.bufferedLen();
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
            var src_reader = src_file.readerStreaming(&src_buf);
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

    var base_index: MboxIndex = .{};
    defer base_index.deinit(allocator);
    try base_index.load(allocator, base_file);

    var new_index: MboxIndex = .{};
    defer new_index.deinit(allocator);
    try new_index.load(allocator, new_file);

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
const File = std.fs.File;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const cli = @import("cli.zig");

const testing = std.testing;

const single_msg =
    \\From sender@example.com Mon Jan 1 00:00:00 2024
    \\Message-ID: <msg1@example.com>
    \\Subject: Test 1
    \\
    \\Body of message 1
;

const multi_msg =
    \\From sender@example.com Mon Jan 1 00:00:00 2024
    \\Message-ID: <msg1@example.com>
    \\Subject: Test 1
    \\
    \\Body of message 1
    \\
    \\From sender@example.com Tue Jan 2 00:00:00 2024
    \\Message-ID: <msg2@example.com>
    \\Subject: Test 2
    \\
    \\Body of message 2
    \\
    \\From sender@example.com Wed Jan 3 00:00:00 2024
    \\Message-ID: <msg3@example.com>
    \\Subject: Test 3
    \\
    \\Body of message 3
;

fn writeTmpMbox(tmp: *testing.TmpDir, name: []const u8, content: []const u8) !File {
    const file = try tmp.dir.createFile(name, .{ .read = true });
    try file.writeAll(content);
    try file.seekTo(0);
    return file;
}

fn loadTmpIndex(tmp: *testing.TmpDir, name: []const u8, content: []const u8) !struct { MboxIndex, File } {
    const file = try writeTmpMbox(tmp, name, content);
    var index: MboxIndex = .{};
    try index.load(testing.allocator, file);
    return .{ index, file };
}

test "load parses single message" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var index, const file = try loadTmpIndex(&tmp, "single.mbox", single_msg);
    defer index.deinit(testing.allocator);
    defer file.close();

    try testing.expectEqual(1, index.messages.count());
    try testing.expect(index.messages.contains("<msg1@example.com>"));
}

test "load parses multiple messages" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var index, const file = try loadTmpIndex(&tmp, "multi.mbox", multi_msg);
    defer index.deinit(testing.allocator);
    defer file.close();

    try testing.expectEqual(3, index.messages.count());
    try testing.expect(index.messages.contains("<msg1@example.com>"));
    try testing.expect(index.messages.contains("<msg2@example.com>"));
    try testing.expect(index.messages.contains("<msg3@example.com>"));

    // Verify locations don't overlap
    const loc1 = index.messages.get("<msg1@example.com>").?;
    const loc2 = index.messages.get("<msg2@example.com>").?;
    const loc3 = index.messages.get("<msg3@example.com>").?;
    try testing.expect(loc1.end <= loc2.start);
    try testing.expect(loc2.end <= loc3.start);
}

test "load skips message without Message-ID" {
    const mbox =
        \\From sender@example.com Mon Jan 1 00:00:00 2024
        \\Subject: No ID
        \\
        \\Body without message id
        \\
        \\From sender@example.com Tue Jan 2 00:00:00 2024
        \\Message-ID: <has-id@example.com>
        \\Subject: Has ID
        \\
        \\Body with message id
    ;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var index, const file = try loadTmpIndex(&tmp, "noid.mbox", mbox);
    defer index.deinit(testing.allocator);
    defer file.close();

    try testing.expectEqual(1, index.messages.count());
    try testing.expect(index.messages.contains("<has-id@example.com>"));
}

test "writeDelta writes only new messages" {
    const base_mbox =
        \\From sender@example.com Mon Jan 1 00:00:00 2024
        \\Message-ID: <msg1@example.com>
        \\Subject: Test 1
        \\
        \\Body of message 1
        \\
        \\From sender@example.com Tue Jan 2 00:00:00 2024
        \\Message-ID: <msg2@example.com>
        \\Subject: Test 2
        \\
        \\Body of message 2
    ;

    const new_mbox =
        \\From sender@example.com Mon Jan 1 00:00:00 2024
        \\Message-ID: <msg1@example.com>
        \\Subject: Test 1
        \\
        \\Body of message 1
        \\
        \\From sender@example.com Tue Jan 2 00:00:00 2024
        \\Message-ID: <msg2@example.com>
        \\Subject: Test 2
        \\
        \\Body of message 2
        \\
        \\From sender@example.com Wed Jan 3 00:00:00 2024
        \\Message-ID: <msg3@example.com>
        \\Subject: Test 3
        \\
        \\Body of message 3
    ;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_index, const base_file = try loadTmpIndex(&tmp, "base.mbox", base_mbox);
    defer base_index.deinit(testing.allocator);
    defer base_file.close();

    var new_index, const new_file = try loadTmpIndex(&tmp, "new.mbox", new_mbox);
    defer new_index.deinit(testing.allocator);
    defer new_file.close();

    // Re-open for seeking in writeDelta
    const src_file = try tmp.dir.openFile("new.mbox", .{});
    defer src_file.close();

    var out_allocating: Writer.Allocating = .init(testing.allocator);
    defer out_allocating.deinit();

    const count = try writeDelta(base_index, new_index, src_file, &out_allocating.writer);
    const output = out_allocating.written();

    try testing.expectEqual(1, count);
    try testing.expect(std.mem.indexOf(u8, output, "<msg3@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, output, "<msg1@example.com>") == null);
    try testing.expect(std.mem.indexOf(u8, output, "<msg2@example.com>") == null);
}

test "writeDelta with no differences returns zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var index1, const file1 = try loadTmpIndex(&tmp, "a.mbox", single_msg);
    defer index1.deinit(testing.allocator);
    defer file1.close();

    var index2, const file2 = try loadTmpIndex(&tmp, "b.mbox", single_msg);
    defer index2.deinit(testing.allocator);
    defer file2.close();

    const src_file = try tmp.dir.openFile("b.mbox", .{});
    defer src_file.close();

    var out_allocating: Writer.Allocating = .init(testing.allocator);
    defer out_allocating.deinit();

    const count = try writeDelta(index1, index2, src_file, &out_allocating.writer);

    try testing.expectEqual(0, count);
    try testing.expectEqual(0, out_allocating.written().len);
}

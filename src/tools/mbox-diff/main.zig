pub fn main() !void {
    try cli.execute(std.heap.page_allocator, mboxDelta);
}

const State = enum {
    start,
    from,
    headers,
    body,
};

const Event = enum {
    from_line,
    header_line,
    blank_line,
    body_line,
    other_line,
    eof,
};

const MboxIndex = struct {
    const boundary = "\nFrom ";
    const msg_id_header = "Message-ID:";

    const Location = struct {
        start: u64,
        end: u64,
    };

    message_ids: std.ArrayListUnmanaged(u8) = .empty,
    messages: std.StringHashMapUnmanaged(Location) = .empty,

    pub fn deinit(self: *MboxIndex, allocator: Allocator) void {
        self.messages.deinit(allocator);
        self.message_ids.deinit(allocator);
    }

    fn fillMore(reader: *Reader) !bool {
        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        return true;
    }

    /// Extract Message-ID value from a header block.
    pub fn extractMessageId(allocator: Allocator, reader: *Reader) !?[]const u8 {
        while (true) {
            const buf = reader.buffered();
            if (buf.len == 0) {
                if (!try fillMore(reader)) return null;
                continue;
            }

            // Check for end of headers (blank line)
            if (std.mem.indexOf(u8, buf, "\n\n")) |blank_pos| {
                const headers = buf[0..blank_pos];
                return findMessageIdInSlice(allocator, headers);
            }

            // Search what we have so far
            if (findMessageIdInSlice(allocator, buf)) |msg_id| {
                return msg_id;
            }

            // Haven't found end of headers yet — retain tail for partial match, fill more
            reader.toss(buf.len -| (msg_id_header.len + 256));
            if (!try fillMore(reader)) return null;
        }
    }

    pub fn findMessageIdInSlice(allocator: Allocator, slice: []const u8) ?[]const u8 {
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

    pub fn load(allocator: Allocator, file: File) !MboxIndex {
        var read_buf: [65535]u8 = undefined;
        var stream = file.readerStreaming(&read_buf);
        const reader = &stream.interface;

        var fsm = zigfsm.StateMachine(State, Event, .start).init();

        try fsm.addEventAndTransition(.from_line, .start, .from);

        try fsm.addEventAndTransition(.other_line, .from, .headers);

        try fsm.addEventAndTransition(.other_line, .headers, .headers);
        try fsm.addEventAndTransition(.blank_line, .headers, .body);
        try fsm.addEventAndTransition(.from_line, .headers, .from);

        try fsm.addEventAndTransition(.other_line, .body, .body);
        try fsm.addEventAndTransition(.blank_line, .body, .body);
        try fsm.addEventAndTransition(.from_line, .body, .from);

        var count: usize = 0;
        var start: usize = 0;
        var offset: usize = 0;

        var locations: std.ArrayListUnmanaged(Location) = .empty;
        var message_ids: std.ArrayListUnmanaged(u8) = .empty;

        var current_hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        var current_message_id: ?[]const u8 = null;
        var done = false;

        while (!done) {
            const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => blk: {
                    done = true;
                    break :blk reader.buffered()[reader.seek..reader.end];
                },
                else => return err,
            };

            if (std.mem.startsWith(u8, line, boundary[1..])) {
                _ = try fsm.do(.from_line);
            } else if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) {
                _ = try fsm.do(.blank_line);
            } else {
                _ = try fsm.do(.other_line);
            }

            if (done or fsm.currentState() == .from) {
                if (count > 0) {
                    try locations.append(allocator, .{
                        .start = start,
                        .end = offset,
                    });

                    if (done and std.mem.trim(u8, line, &std.ascii.whitespace).len > 0) {
                        current_hash.update(line);
                    }

                    const message_id: []const u8 = if (current_message_id) |id| id else blk: {
                        const hash_bytes = current_hash.finalResult();
                        break :blk &std.fmt.bytesToHex(&hash_bytes, .lower);
                    };

                    try message_ids.ensureUnusedCapacity(allocator, message_id.len + 1);
                    message_ids.appendSliceAssumeCapacity(message_id);
                    message_ids.appendAssumeCapacity(0);
                }

                start = offset;
                count += 1;
                current_hash = .init(.{});
                current_message_id = null;
            } else if (std.mem.trim(u8, line, &std.ascii.whitespace).len > 0) {
                current_hash.update(line);

                if (std.ascii.startsWithIgnoreCase(line, msg_id_header)) {
                    const raw = std.mem.trim(u8, line[msg_id_header.len..], &std.ascii.whitespace);
                    if (raw.len > 0) {
                        current_message_id = try allocator.dupe(u8, raw);
                    }
                }
            }

            offset += line.len;
        }

        var result: MboxIndex = .{};
        result.message_ids = message_ids;

        var this_sentinel: usize = 0;
        var last_sentinel: usize = 0;

        for (locations.items) |location| {
            // find the next sentinel
            this_sentinel = std.mem.indexOfScalarPos(u8, message_ids.items, last_sentinel, 0).?;

            // extract the message id
            const message_id = message_ids.items[last_sentinel..this_sentinel];

            // put the location into the map
            if (!result.messages.contains(message_id)) {
                try result.messages.putNoClobber(allocator, message_id, location);
            }

            last_sentinel = this_sentinel + 1;
        }

        return result;
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

    var base_index: MboxIndex = try .load(allocator, base_file);
    defer base_index.deinit(allocator);

    var new_index: MboxIndex = try .load(allocator, new_file);
    defer new_index.deinit(allocator);

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
const zigfsm = @import("zigfsm");

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

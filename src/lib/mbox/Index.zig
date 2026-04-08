const boundary = "\nFrom ";
const msg_id_header = "Message-ID:";

// Binary index format (v1):
//   [8]    magic
//   [u64]  version
//   [u64]  chunk type 0x01 (message IDs)
//   [u64]  blob length
//   [...]  null-terminated message IDs, concatenated
//   [u64]  chunk type 0x02 (locations)
//   [u64]  entry count
//   [...]  {start: u64, end: u64} per message, ordered to match IDs
//
// All integers are little-endian.
const file_header = [_]u8{ 0x00, 0x08, 0x10, 'm', 'b', 'i', 'd', 'x' };
const file_version: u64 = 0x01;

const chunk_type_message_ids: u64 = 0x01;
const chunk_type_locations: u64 = 0x02;

const State = enum {
    start,
    from,
    headers,
    body,
};

const Event = enum {
    from_line,
    blank_line,
    other_line,
};

pub const Location = struct {
    start: u64,
    end: u64,
};

pub const MessageIdIterator = struct {
    offset: usize,
    list: *const std.ArrayListUnmanaged(u8),

    pub fn init(message_ids: *const std.ArrayListUnmanaged(u8)) MessageIdIterator {
        return .{ .offset = 0, .list = message_ids };
    }

    pub fn next(self: *MessageIdIterator) ?[]const u8 {
        const i = std.mem.indexOfScalarPos(u8, self.list.items, self.offset, 0) orelse return null;
        const message_id = self.list.items[self.offset..i];

        self.offset = i + 1;

        return message_id;
    }
};

message_ids: std.ArrayListUnmanaged(u8) = .empty,
locations: std.StringHashMapUnmanaged(Location) = .empty,

const Index = @This();

pub fn deinit(self: *Index, allocator: Allocator) void {
    self.locations.deinit(allocator);
    self.message_ids.deinit(allocator);
}

pub fn read(allocator: Allocator, reader: *std.io.Reader) !Index {
    const header = try reader.takeArray(8);
    if (!std.mem.eql(u8, header, &file_header)) return error.InvalidFormat;

    const version = try reader.takeInt(u64, .little);
    if (version != file_version) return error.UnsupportedVersion;

    const ids_chunk_type = try reader.takeInt(u64, .little);
    if (ids_chunk_type != chunk_type_message_ids) return error.InvalidFormat;
    const ids_blob_len = try reader.takeInt(u64, .little);

    var message_ids: std.ArrayListUnmanaged(u8) = try .initCapacity(allocator, @intCast(ids_blob_len));
    errdefer message_ids.deinit(allocator);
    message_ids.items.len = @intCast(ids_blob_len);
    try reader.readSliceAll(message_ids.items);

    const locs_chunk_type = try reader.takeInt(u64, .little);
    if (locs_chunk_type != chunk_type_locations) return error.InvalidFormat;
    const entry_count = try reader.takeInt(u64, .little);

    var locations: std.StringHashMapUnmanaged(Location) = .empty;
    errdefer locations.deinit(allocator);
    try locations.ensureTotalCapacity(allocator, @intCast(entry_count));

    var iter: MessageIdIterator = .init(&message_ids);
    var i: u64 = 0;
    while (i < entry_count) : (i += 1) {
        const start = try reader.takeInt(u64, .little);
        const end = try reader.takeInt(u64, .little);
        const id = iter.next() orelse return error.InvalidFormat;
        locations.putAssumeCapacityNoClobber(id, .{ .start = start, .end = end });
    }

    return .{
        .message_ids = message_ids,
        .locations = locations,
    };
}

pub fn write(self: Index, writer: *std.io.Writer) !void {
    try writer.writeAll(&file_header);
    try writer.writeInt(u64, file_version, .little);

    try writer.writeInt(u64, chunk_type_message_ids, .little);
    try writer.writeInt(u64, self.message_ids.items.len, .little);
    try writer.writeAll(self.message_ids.items);

    try writer.writeInt(u64, chunk_type_locations, .little);
    try writer.writeInt(u64, self.locations.count(), .little);

    var iter: MessageIdIterator = .init(&self.message_ids);
    while (iter.next()) |id| {
        const loc = self.locations.get(id) orelse continue;
        try writer.writeInt(u64, loc.start, .little);
        try writer.writeInt(u64, loc.end, .little);
    }

    try writer.flush();
}

pub fn index(allocator: Allocator, file: File) !Index {
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
    defer locations.deinit(allocator);

    var message_ids: std.ArrayListUnmanaged(u8) = .empty;
    var message_count: u32 = 0;

    var seen_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var iter = seen_ids.keyIterator();
        while (iter.next()) |id| {
            allocator.free(id.*);
        }
        seen_ids.deinit(allocator);
    }

    var current_hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var current_message_id: ?[]const u8 = null;
    var done = false;

    while (!done) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => blk: {
                done = true;
                break :blk reader.buffered();
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
                const message_id: []const u8 = if (current_message_id) |id| id else blk: {
                    const hash_bytes = current_hash.finalResult();
                    break :blk &std.fmt.bytesToHex(&hash_bytes, .lower);
                };

                if (!seen_ids.contains(message_id)) {
                    try locations.append(allocator, .{
                        .start = start,
                        .end = offset,
                    });

                    if (done and std.mem.trim(u8, line, &std.ascii.whitespace).len > 0) {
                        current_hash.update(line);
                    }

                    try message_ids.ensureUnusedCapacity(allocator, message_id.len + 1);
                    message_ids.appendSliceAssumeCapacity(message_id);
                    message_ids.appendAssumeCapacity(0);

                    message_count += 1;

                    try seen_ids.putNoClobber(allocator, try allocator.dupe(u8, message_id), {});
                }

                if (current_message_id) |id| allocator.free(id);
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

    var result: Index = .{};
    result.message_ids = message_ids;

    try result.locations.ensureTotalCapacity(allocator, message_count);

    var last_sentinel: usize = 0;
    for (locations.items) |location| {
        const i = std.mem.indexOfScalarPos(u8, message_ids.items, last_sentinel, 0).?;
        const message_id = message_ids.items[last_sentinel..i];

        result.locations.putAssumeCapacityNoClobber(message_id, location);

        last_sentinel = i + 1;
    }

    return result;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Writer = std.io.Writer;

const zigfsm = @import("zigfsm");

test "read roundtrips with write" {
    const allocator = std.testing.allocator;

    var idx: Index = .{};
    defer idx.deinit(allocator);

    // Build message_ids blob: two null-terminated IDs
    for ("<msg1@example.com>\x00<msg2@example.com>\x00") |b| {
        try idx.message_ids.append(allocator, b);
    }

    try idx.locations.put(allocator, "<msg1@example.com>", .{ .start = 0, .end = 100 });
    try idx.locations.put(allocator, "<msg2@example.com>", .{ .start = 100, .end = 250 });

    // Write to buffer
    var buf: [4096]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    try idx.write(&writer);

    // Read back
    const written = writer.buffered();
    var reader = std.io.Reader.fixed(written);
    var restored = try Index.read(allocator, &reader);
    defer restored.deinit(allocator);

    // Verify message IDs blob matches
    try std.testing.expectEqualSlices(u8, idx.message_ids.items, restored.message_ids.items);

    // Verify locations match
    try std.testing.expectEqual(idx.locations.count(), restored.locations.count());

    const loc1 = restored.locations.get("<msg1@example.com>").?;
    try std.testing.expectEqual(@as(u64, 0), loc1.start);
    try std.testing.expectEqual(@as(u64, 100), loc1.end);

    const loc2 = restored.locations.get("<msg2@example.com>").?;
    try std.testing.expectEqual(@as(u64, 100), loc2.start);
    try std.testing.expectEqual(@as(u64, 250), loc2.end);
}

test "index deduplicates messages sharing a Message-ID" {
    const allocator = std.testing.allocator;

    // Three messages, but only two distinct Message-IDs.
    // If `message_count` were tracked incorrectly, the second
    // pass's `putAssumeCapacityNoClobber` would panic on
    // insufficient capacity (under-count) — so this test pins
    // the pre-allocation against the actual insert count.
    const mbox_content =
        "From sender@example.com Mon Jan  1 00:00:00 2024\n" ++
        "Message-ID: <dup@example.com>\n" ++
        "Subject: First\n" ++
        "\n" ++
        "Body one\n" ++
        "\n" ++
        "From sender@example.com Mon Jan  1 00:00:01 2024\n" ++
        "Message-ID: <dup@example.com>\n" ++
        "Subject: Second (duplicate ID)\n" ++
        "\n" ++
        "Body two\n" ++
        "\n" ++
        "From sender@example.com Mon Jan  1 00:00:02 2024\n" ++
        "Message-ID: <unique@example.com>\n" ++
        "Subject: Third\n" ++
        "\n" ++
        "Body three\n";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "dup.mbox", .data = mbox_content });
    var file = try tmp.dir.openFile("dup.mbox", .{});
    defer file.close();

    var idx = try Index.index(allocator, file);
    defer idx.deinit(allocator);

    // Two unique IDs despite three "From " messages.
    try std.testing.expectEqual(@as(u32, 2), idx.locations.count());
    try std.testing.expect(idx.locations.contains("<dup@example.com>"));
    try std.testing.expect(idx.locations.contains("<unique@example.com>"));

    // The message_ids blob should also reflect dedup: exactly two
    // null-terminated entries.
    var sentinel_count: usize = 0;
    for (idx.message_ids.items) |b| {
        if (b == 0) sentinel_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), sentinel_count);

    // First occurrence wins: the location stored for <dup@example.com>
    // must start at byte 0 (the first "From " line).
    const dup_loc = idx.locations.get("<dup@example.com>").?;
    try std.testing.expectEqual(@as(u64, 0), dup_loc.start);
}

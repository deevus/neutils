const boundary = "\nFrom ";
const msg_id_header = "Message-ID:";

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

message_ids: std.ArrayListUnmanaged(u8) = .empty,
messages: std.StringHashMapUnmanaged(Location) = .empty,

const Self = @This();

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.messages.deinit(allocator);
    self.message_ids.deinit(allocator);
}

pub fn load(allocator: Allocator, file: File) !Self {
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

    var result: Self = .{};
    result.message_ids = message_ids;

    var this_sentinel: usize = 0;
    var last_sentinel: usize = 0;

    for (locations.items) |location| {
        this_sentinel = std.mem.indexOfScalarPos(u8, message_ids.items, last_sentinel, 0).?;
        const message_id = message_ids.items[last_sentinel..this_sentinel];

        if (!result.messages.contains(message_id)) {
            try result.messages.putNoClobber(allocator, message_id, location);
        }

        last_sentinel = this_sentinel + 1;
    }

    return result;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const zigfsm = @import("zigfsm");

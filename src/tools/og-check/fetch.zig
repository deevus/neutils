pub const Response = struct {
    body: []u8,
    final_url: []const u8,
    status: u16,
};

pub fn fetch(allocator: Allocator, url: []const u8) !Response {
    _ = allocator;
    _ = url;
    return error.Unimplemented;
}

const std = @import("std");
const Allocator = std.mem.Allocator;

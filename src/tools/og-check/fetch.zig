/// Fetches the body of the given URI using an HTTP GET request.
///
/// Caller is responsible for freeing the returned slice.
pub fn getBodyAlloc(allocator: Allocator, uri: Uri) ![]const u8 {
    var http_client: Client = .{ .allocator = allocator };
    defer http_client.deinit();

    var body: Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try http_client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &body.writer,
        .extra_headers = &.{.{
            .name = "accept",
            .value = "text/html,application/xhtml+xml",
        }},
    });

    if (result.status != .ok) {
        return error.HttpError;
    }

    return try body.toOwnedSlice();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = std.http.Client;
const Uri = std.Uri;
const Writer = std.Io.Writer;

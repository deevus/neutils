const user_agent = "og-check/" ++ build_options.version ++ " (+https://github.com/deevus/neutils)";

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
        .extra_headers = &.{
            .{
                .name = "accept",
                .value = "text/html,application/xhtml+xml",
            },
            .{
                .name = "user-agent",
                .value = user_agent,
            },
        },
    });

    if (result.status != .ok) {
        return error.HttpError;
    }

    return try body.toOwnedSlice();
}

pub fn headStatus(allocator: Allocator, uri: Uri) !std.http.Status {
    var http_client: Client = .{ .allocator = allocator };
    defer http_client.deinit();

    const result = try http_client.fetch(.{
        .location = .{ .uri = uri },
        .method = .HEAD,
        .response_writer = null,
        .extra_headers = &.{
            .{
                .name = "user-agent",
                .value = user_agent,
            },
        },
    });

    return result.status;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = std.http.Client;
const Uri = std.Uri;
const Writer = std.Io.Writer;

const build_options = @import("build_options");

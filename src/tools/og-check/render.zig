pub fn writeMarkdown(writer: *Writer, final_url: []const u8, tags: MetaTags) !void {
    _ = writer;
    _ = final_url;
    _ = tags;
    return error.Unimplemented;
}

pub fn writeJson(writer: *Writer, final_url: []const u8, tags: MetaTags) !void {
    _ = writer;
    _ = final_url;
    _ = tags;
    return error.Unimplemented;
}

const std = @import("std");
const Writer = std.Io.Writer;

const MetaTags = @import("scan.zig").MetaTags;

pub fn main() !void {
    try cli.execute(std.heap.page_allocator, ogCheck);
}

fn ogCheck() !void {
    var arena: ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const uri: Uri = try .parse(cli.config.url);
    const bytes = try fetch.getBodyAlloc(allocator, uri);
    defer allocator.free(bytes);

    var meta_tags = try scan.parseSlice(allocator, bytes);
    defer meta_tags.deinit(allocator);

    const stdout = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_stream = stdout.writer(&stdout_buf);
    const stdout_writer = &stdout_stream.interface;

    const stderr = std.fs.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_stream = stderr.writer(&stderr_buf);
    const stderr_writer = &stderr_stream.interface;

    switch (cli.config.output_format) {
        .opengraph => render.writeOpenGraph(allocator, meta_tags, stdout_writer) catch |err| switch (err) {
            error.MissingTitle, error.MissingType, error.MissingImage, error.MissingUrl => {
                try stderr_writer.print("error: OpenGraph missing required field — {}.\n", .{err});
                try stderr_writer.flush();
                std.process.exit(1);
            },
            else => return err,
        },
        .twitter => render.writeTwitter(allocator, meta_tags, stdout_writer) catch |err| switch (err) {
            error.MissingCard, error.MissingTitle, error.MissingImage => {
                try stderr_writer.print("error: Twitter Card missing required field — {}.\n", .{err});
                try stderr_writer.flush();
                std.process.exit(1);
            },
            else => return err,
        },
        .table => try render.writeTable(allocator, meta_tags, stdout_writer),
        .json => try render.writeJson(meta_tags, stdout_writer),
    }
}

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Uri = std.Uri;

const cli = @import("cli.zig");

const fetch = @import("fetch.zig");
const scan = @import("scan.zig");
const render = @import("render.zig");

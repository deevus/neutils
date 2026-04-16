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

    var scan_result: ScanResult = try .scan(allocator, bytes);
    defer scan_result.deinit(allocator);

    const stdout = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_stream = stdout.writer(&stdout_buf);
    const stdout_writer = &stdout_stream.interface;

    const stderr = std.fs.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_stream = stderr.writer(&stderr_buf);
    const stderr_writer = &stderr_stream.interface;

    const output_format = cli.config.outputFormat();
    switch (output_format) {
        .opengraph => try render.writeOpenGraph(allocator, scan_result, stdout_writer),
        .twitter => try render.writeTwitter(allocator, scan_result, stdout_writer),
        .table => try render.writeTable(allocator, scan_result, stdout_writer),
        .json => try render.writeJson(scan_result, stdout_writer),
        .none => {},
    }

    const validate_result = try scan_result.validate(allocator, output_format.schemas());

    switch (cli.config.issueFormat()) {
        .human => try render.writeIssuesHuman(allocator, scan_result, cli.config, stderr_writer),
        .ci => try render.writeIssuesCi(scan_result, cli.config, stderr_writer),
        .json => {
            // Makes it convenient for pipelines: issues are emitted on stdout when output is suppressed
            const writer = if (output_format == .none) stdout_writer else stderr_writer;

            try render.writeIssuesJson(scan_result, cli.config, writer);
        },
    }

    if (validate_result == .errors) {
        std.process.exit(1);
    }
}

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Uri = std.Uri;

const cli = @import("cli.zig");

const fetch = @import("fetch.zig");

const scanner = @import("scanner.zig");
const ScanResult = scanner.ScanResult;

const render = @import("render.zig");

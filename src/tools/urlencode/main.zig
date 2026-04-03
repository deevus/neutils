pub fn main() !void {
    try cli.execute(std.heap.page_allocator, urlencode);
}

fn urlencode() !void {
    const component: Component = .{ .raw = cli.config.str };

    var stdout: File = .stdout();

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buf);
    var stdout_writer_interface = &stdout_writer.interface;

    try component.formatEscaped(stdout_writer_interface);
    try stdout_writer_interface.writeByte('\n');

    try stdout_writer_interface.flush();
}

const std = @import("std");
const File = std.fs.File;
const Uri = std.Uri;
const Component = Uri.Component;

const cli = @import("cli.zig");

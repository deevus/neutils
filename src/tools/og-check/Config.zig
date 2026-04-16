pub const OutputFormat = enum {
    opengraph,
    twitter,
    table,
    json,
};

url: []const u8,
output_format: OutputFormat = .opengraph,

pub fn schemas(config: @This()) []const Schema {
    return switch (config.output_format) {
        .opengraph => &[_]Schema{.opengraph},
        .twitter => &[_]Schema{.twitter},
        .table => &[_]Schema{ .opengraph, .twitter },
        .json => &[_]Schema{ .opengraph, .twitter },
    };
}

const std = @import("std");

const scanner = @import("scanner.zig");
const Schema = scanner.ScanResult.Schema;

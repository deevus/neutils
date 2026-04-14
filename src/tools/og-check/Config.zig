pub const OutputFormat = enum {
    opengraph,
    twitter,
    table,
    json,
};

url: []const u8,
output_format: OutputFormat = .opengraph,

const std = @import("std");

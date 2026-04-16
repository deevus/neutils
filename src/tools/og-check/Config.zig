const Config = @This();

pub const OutputFormat = enum {
    opengraph,
    twitter,
    table,
    json,
    none,
};

pub const IssueFormat = enum {
    human,
    json,
    ci,
};

url: []const u8,
output_format: OutputFormat = .opengraph,
issue_format: IssueFormat = .human,

pub fn schemas(config: Config) []const Schema {
    return switch (config.output_format) {
        .opengraph => &[_]Schema{.opengraph},
        .twitter => &[_]Schema{.twitter},
        .table, .json, .none => &[_]Schema{ .opengraph, .twitter },
    };
}

const std = @import("std");

const scanner = @import("scanner.zig");
const Schema = scanner.ScanResult.Schema;

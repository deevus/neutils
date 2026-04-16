const Config = @This();

pub const OutputFormat = enum {
    opengraph,
    twitter,
    table,
    json,
    none,

    pub fn schemas(self: OutputFormat) []const Schema {
        return switch (self) {
            .opengraph => &[_]Schema{.opengraph},
            .twitter => &[_]Schema{.twitter},
            .table, .json, .none => &[_]Schema{ .opengraph, .twitter },
        };
    }
};

pub const IssueFormat = enum {
    human,
    json,
    ci,
};

url: []const u8,
output_format: ?OutputFormat = null,
issue_format: ?IssueFormat = null,

pub fn outputFormat(self: Config) OutputFormat {
    if (self.output_format) |format| {
        return format;
    }

    if (std.process.hasEnvVarConstant("GITHUB_ACTIONS") or std.process.hasEnvVarConstant("FORGEJO_ACTIONS")) {
        return .none;
    }

    return .opengraph;
}

pub fn issueFormat(self: Config) IssueFormat {
    if (self.issue_format) |format| {
        return format;
    }

    if (std.process.hasEnvVarConstant("GITHUB_ACTIONS") or std.process.hasEnvVarConstant("FORGEJO_ACTIONS")) {
        return .ci;
    }

    return .human;
}

const std = @import("std");

const scanner = @import("scanner.zig");
const Schema = scanner.ScanResult.Schema;

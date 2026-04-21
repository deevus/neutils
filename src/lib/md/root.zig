pub const Document = @import("Document.zig");
pub const renderPretty = @import("render.zig").renderPretty;
pub const log = @import("log.zig");

comptime {
    @import("std").testing.refAllDeclsRecursive(@This());
}

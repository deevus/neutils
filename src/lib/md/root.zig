pub const Document = @import("Document.zig");
pub const renderPretty = @import("render.zig").renderPretty;

comptime {
    @import("std").testing.refAllDeclsRecursive(@This());
}

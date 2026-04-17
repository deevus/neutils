pub const Document = @import("Document.zig");

comptime {
    @import("std").testing.refAllDeclsRecursive(@This());
}

pub const Index = @import("Index.zig");

comptime {
    @import("std").testing.refAllDeclsRecursive(@This());
}

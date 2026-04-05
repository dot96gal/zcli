const std = @import("std");

pub const ExitStatus = enum(u8) {
    success = 0,
    failure = 1,
    usage_error = 2,

    pub fn toCode(self: ExitStatus) u8 {
        return @intFromEnum(self);
    }

    pub fn exit(self: ExitStatus) noreturn {
        std.process.exit(self.toCode());
    }
};

test "ExitStatus toCode" {
    try std.testing.expectEqual(@as(u8, 0), ExitStatus.success.toCode());
    try std.testing.expectEqual(@as(u8, 1), ExitStatus.failure.toCode());
    try std.testing.expectEqual(@as(u8, 2), ExitStatus.usage_error.toCode());
}

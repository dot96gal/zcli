const std = @import("std");

/// プロセス終了コードを表す列挙型。
pub const ExitStatus = enum(u8) {
    /// 正常終了を示す（終了コード: 0）。
    success = 0,
    /// 処理失敗を示す（終了コード: 1）。
    failure = 1,
    /// 使い方の誤りを示す（終了コード: 2）。不正なフラグ指定などが該当する。
    usage_error = 2,

    /// 対応する `u8` 終了コードを返す。
    pub fn toCode(self: ExitStatus) u8 {
        return @intFromEnum(self);
    }

    /// `std.process.exit()` を呼び出してプロセスを終了する。
    /// `defer` をスキップするため、呼び出し前に writer を明示的にフラッシュしてください。
    pub fn exit(self: ExitStatus) noreturn {
        std.process.exit(self.toCode());
    }
};

test "ExitStatus toCode" {
    try std.testing.expectEqual(@as(u8, 0), ExitStatus.success.toCode());
    try std.testing.expectEqual(@as(u8, 1), ExitStatus.failure.toCode());
    try std.testing.expectEqual(@as(u8, 2), ExitStatus.usage_error.toCode());
}

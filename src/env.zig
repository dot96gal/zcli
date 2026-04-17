const std = @import("std");

/// 実行環境の依存性注入コンテナ。stdout/stderr/allocator を保持するが所有はしない。
/// stdout/stderr は呼び出し元が生成した `*std.Io.Writer` を渡すこと。
/// Commander より先に宣言した writer が Commander の寿命を包むこと。
pub const Env = struct {
    /// メモリアロケータ。所有権は持たない。
    allocator: std.mem.Allocator,
    /// 標準出力 writer へのポインタ。
    stdout: *std.Io.Writer,
    /// 標準エラー出力 writer へのポインタ。
    stderr: *std.Io.Writer,
};

/// テスト用ヘルパー。stdout/stderr を `Allocating` writer に向けた `Env` を提供する。
pub const TestEnv = struct {
    allocator: std.mem.Allocator,
    out_w: std.Io.Writer.Allocating,
    err_w: std.Io.Writer.Allocating,

    /// `allocator` を受け取り `TestEnv` を初期化する。
    pub fn init(allocator: std.mem.Allocator) TestEnv {
        return .{
            .allocator = allocator,
            .out_w = std.Io.Writer.Allocating.init(allocator),
            .err_w = std.Io.Writer.Allocating.init(allocator),
        };
    }

    /// `*self` 経由でライターを生成するため、self が生きている限り常に有効なポインタを持つ。
    /// 呼び出し後に self を移動・再代入してはならない。
    pub fn env(self: *TestEnv) Env {
        return .{
            .allocator = self.allocator,
            .stdout = &self.out_w.writer,
            .stderr = &self.err_w.writer,
        };
    }

    /// stdout/stderr の `Allocating` writer を解放する。
    pub fn deinit(self: *TestEnv) void {
        self.out_w.deinit();
        self.err_w.deinit();
    }
};

test "TestEnv captures stdout" {
    var te = TestEnv.init(std.testing.allocator);
    defer te.deinit();

    const e = te.env();
    try e.stdout.print("hello {s}\n", .{"world"});
    try std.testing.expectEqualStrings("hello world\n", te.out_w.writer.buffered());
}

test "TestEnv captures stderr" {
    var te = TestEnv.init(std.testing.allocator);
    defer te.deinit();

    const e = te.env();
    try e.stderr.print("error: {s}\n", .{"oops"});
    try std.testing.expectEqualStrings("error: oops\n", te.err_w.writer.buffered());
}

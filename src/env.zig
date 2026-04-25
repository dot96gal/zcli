const std = @import("std");
const zctx = @import("zctx");

/// 実行環境の依存性注入コンテナ。stdout/stderr/allocator/io/ctx を保持するが所有はしない。
/// stdout/stderr は呼び出し元が生成した `*std.Io.Writer` を渡してください。
/// App より先に宣言した writer が App の寿命を包むようにしてください。
pub const Env = struct {
    /// メモリアロケータ。所有権は持たない。
    allocator: std.mem.Allocator,
    /// Zig ランタイムの実行プリミティブ。zctx 等が要求する。
    io: std.Io,
    /// 標準出力 writer へのポインタ。
    stdout: *std.Io.Writer,
    /// 標準エラー出力 writer へのポインタ。
    stderr: *std.Io.Writer,
    /// 実行コンテキスト。キャンセルやタイムアウトの伝搬に使う。不要な場合は `zctx.BACKGROUND` を渡す。
    ctx: zctx.Context,
};

/// テスト用ヘルパー。
/// stdout/stderr を `Allocating` writer に向けた `Env` を提供する。
pub const TestEnv = struct {
    allocator: std.mem.Allocator,
    outWriter: std.Io.Writer.Allocating,
    errWriter: std.Io.Writer.Allocating,

    /// `allocator` を受け取り `TestEnv` を初期化する。
    pub fn init(allocator: std.mem.Allocator) TestEnv {
        return .{
            .allocator = allocator,
            .outWriter = std.Io.Writer.Allocating.init(allocator),
            .errWriter = std.Io.Writer.Allocating.init(allocator),
        };
    }

    /// `*self` 経由でライターを生成するため、self が生きている限り常に有効なポインタを持つ。
    /// 呼び出し後に self を移動・再代入してはならない。
    pub fn env(self: *TestEnv) Env {
        return .{
            .allocator = self.allocator,
            .io = std.testing.io,
            .stdout = &self.outWriter.writer,
            .stderr = &self.errWriter.writer,
            .ctx = zctx.BACKGROUND,
        };
    }

    /// stdout/stderr の `Allocating` writer を解放する。
    pub fn deinit(self: *TestEnv) void {
        self.outWriter.deinit();
        self.errWriter.deinit();
    }
};

test "TestEnv captures stdout" {
    var te = TestEnv.init(std.testing.allocator);
    defer te.deinit();

    const e = te.env();
    try e.stdout.print("hello {s}\n", .{"world"});
    try std.testing.expectEqualStrings("hello world\n", te.outWriter.writer.buffered());
}

test "TestEnv captures stderr" {
    var te = TestEnv.init(std.testing.allocator);
    defer te.deinit();

    const e = te.env();
    try e.stderr.print("error: {s}\n", .{"oops"});
    try std.testing.expectEqualStrings("error: oops\n", te.errWriter.writer.buffered());
}

test "TestEnv ctx defaults to not cancelled" {
    var te = TestEnv.init(std.testing.allocator);
    defer te.deinit();
    const e = te.env();

    try std.testing.expect(!e.ctx.done().isFired());
}

test "TestEnv ctx can be overridden to test cancellation" {
    var te = TestEnv.init(std.testing.allocator);
    defer te.deinit();

    var cancelCtx = try zctx.withCancel(std.testing.io, zctx.BACKGROUND, std.testing.allocator);
    defer cancelCtx.deinit(std.testing.io);

    var e = te.env();
    e.ctx = cancelCtx.context;

    try std.testing.expect(!e.ctx.done().isFired());

    cancelCtx.cancel(std.testing.io);

    try std.testing.expect(e.ctx.done().isFired());
}

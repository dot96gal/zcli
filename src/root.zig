//! zcli: シンプルな Zig CLI フレームワーク。
//! このファイルが唯一の公開インポートポイント。

/// vtable ベースのサブコマンドインターフェース。
pub const Command = @import("command.zig").Command;
/// フラグパーサー。`--long`、`-s`、`--key=val`、`--` に対応。
pub const FlagSet = @import("flag_set.zig").FlagSet;
/// フラグ定義（名前、短縮名、型、デフォルト値、説明）。
pub const FlagDef = @import("flag_set.zig").FlagDef;
/// サブコマンドのルーティングと `help` コマンドの処理。
pub const Commander = @import("commander.zig").Commander;
/// 依存性注入コンテナ（allocator、stdout、stderr）。
pub const Env = @import("env.zig").Env;
/// テスト専用ヘルパー。本番コードでは使用しないこと。
pub const TestEnv = @import("env.zig").TestEnv;
/// プロセス終了コード列挙型。
pub const ExitStatus = @import("exit_status.zig").ExitStatus;
/// フラグパース時のエラー集合。
pub const ParseError = @import("flag_set.zig").ParseError;
/// ヘルプテキスト出力ユーティリティ。
pub const help = @import("help.zig");

test {
    _ = @import("command.zig");
    _ = @import("commander.zig");
    _ = @import("env.zig");
    _ = @import("exit_status.zig");
    _ = @import("flag_set.zig");
    _ = @import("help.zig");
}

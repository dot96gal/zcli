//! zcli: シンプルな Zig CLI フレームワーク。

pub const App = @import("app.zig").App;
pub const Command = @import("command.zig").Command;
pub const Env = @import("env.zig").Env;
pub const TestEnv = @import("env.zig").TestEnv;
pub const ExitStatus = @import("exit_status.zig").ExitStatus;
pub const FlagSet = @import("flag_set.zig").FlagSet;
pub const FlagDef = @import("flag_set.zig").FlagDef;
pub const ParseError = @import("flag_set.zig").ParseError;
pub const help = @import("help.zig");
pub const BACKGROUND = @import("zctx").BACKGROUND;

test {
    _ = @import("app.zig");
    _ = @import("command.zig");
    _ = @import("env.zig");
    _ = @import("exit_status.zig");
    _ = @import("flag_set.zig");
    _ = @import("help.zig");
}

//! zcli: シンプルな Zig CLI フレームワーク。

pub const Command = @import("command.zig").Command;
pub const FlagSet = @import("flag_set.zig").FlagSet;
pub const FlagDef = @import("flag_set.zig").FlagDef;
pub const Commander = @import("commander.zig").Commander;
pub const Env = @import("env.zig").Env;
pub const TestEnv = @import("env.zig").TestEnv;
pub const ExitStatus = @import("exit_status.zig").ExitStatus;
pub const ParseError = @import("flag_set.zig").ParseError;
pub const help = @import("help.zig");

test {
    _ = @import("command.zig");
    _ = @import("commander.zig");
    _ = @import("env.zig");
    _ = @import("exit_status.zig");
    _ = @import("flag_set.zig");
    _ = @import("help.zig");
}

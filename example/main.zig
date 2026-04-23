const std = @import("std");
const zcli = @import("zcli");
const GreetCommand = @import("greet_command.zig").GreetCommand;

pub fn main(env: std.process.Init) !void {
    const allocator = env.gpa;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

    // バッファ付き writer を生成。cmdr より先に宣言して寿命を包む。
    var stdoutBuf: [4096]u8 = undefined;
    var stderrBuf: [512]u8 = undefined;
    var stdoutWriter = std.Io.File.stdout().writer(env.io, &stdoutBuf);
    var stderrWriter = std.Io.File.stderr().writer(env.io, &stderrBuf);

    var cmdr = zcli.Commander.init(
        zcli.Env{
            .allocator = allocator,
            .stdout = &stdoutWriter.interface,
            .stderr = &stderrWriter.interface,
        },
        "mytool",
        "A demonstration CLI tool",
    );
    defer cmdr.deinit();

    var greet = GreetCommand{};
    try cmdr.register(zcli.Command.from(GreetCommand, &greet));

    const status = cmdr.run(args) catch |err| blk: {
        try stderrWriter.interface.print("error: {s}\n", .{@errorName(err)});
        break :blk zcli.ExitStatus.failure;
    };
    // std.process.exit はデファーをスキップするため exit() 前に明示的にフラッシュ
    stdoutWriter.interface.flush() catch |err| std.debug.print("stdout flush error: {s}\n", .{@errorName(err)});
    stderrWriter.interface.flush() catch |err| std.debug.print("stderr flush error: {s}\n", .{@errorName(err)});
    status.exit();
}

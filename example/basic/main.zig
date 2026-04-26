const std = @import("std");
const zcli = @import("zcli");
const GreetCommand = @import("greet_command.zig").GreetCommand;

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;
    const rawArgs = try env.minimal.args.toSlice(env.arena.allocator());
    const args: []const []const u8 = @ptrCast(rawArgs);

    var stdoutBuf: [4096]u8 = undefined;
    var stderrBuf: [512]u8 = undefined;
    var stdoutWriter = std.Io.File.stdout().writer(io, &stdoutBuf);
    var stderrWriter = std.Io.File.stderr().writer(io, &stderrBuf);

    var app = zcli.App.init(
        zcli.Env{
            .allocator = allocator,
            .io = io,
            .stdout = &stdoutWriter.interface,
            .stderr = &stderrWriter.interface,
            .ctx = zcli.BACKGROUND,
        },
        "mytool",
        "A demonstration CLI tool",
    );
    defer app.deinit();

    var greet = GreetCommand{};
    try app.register(zcli.Command.from(GreetCommand, &greet));

    const status = app.run(args) catch |err| blk: {
        try stderrWriter.interface.print("error: {s}\n", .{@errorName(err)});
        break :blk zcli.ExitStatus.failure;
    };
    stdoutWriter.interface.flush() catch |err| std.debug.print("stdout flush error: {s}\n", .{@errorName(err)});
    stderrWriter.interface.flush() catch |err| std.debug.print("stderr flush error: {s}\n", .{@errorName(err)});
    status.exit();
}

const std = @import("std");
const zcli = @import("zcli");
const zctx = @import("zctx");
const GreetCommand = @import("greet_command.zig").GreetCommand;

var cancelled = std.atomic.Value(bool).init(false);

fn sigHandler(_: std.posix.SIG) callconv(.c) void {
    cancelled.store(true, .release);
}

fn signalWatcher(io: std.Io, cancelCtx: *zctx.OwnedContext) void {
    while (!cancelled.load(.acquire)) {
        io.sleep(.fromNanoseconds(100_000_000), .awake) catch break;
    }
    cancelCtx.cancel(io);
    std.debug.print("cancelled\n", .{});
}

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

    std.posix.sigaction(.INT, &.{
        .handler = .{ .handler = sigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    std.posix.sigaction(.TERM, &.{
        .handler = .{ .handler = sigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var stdoutBuf: [4096]u8 = undefined;
    var stderrBuf: [512]u8 = undefined;
    var stdoutWriter = std.Io.File.stdout().writer(io, &stdoutBuf);
    var stderrWriter = std.Io.File.stderr().writer(io, &stderrBuf);

    var cancelCtx = try zctx.withCancel(io, zctx.BACKGROUND, allocator);
    defer cancelCtx.deinit(io);

    const sigThread = try std.Thread.spawn(.{}, signalWatcher, .{ io, &cancelCtx });
    sigThread.detach();

    var app = zcli.App.init(
        zcli.Env{
            .allocator = allocator,
            .io = io,
            .stdout = &stdoutWriter.interface,
            .stderr = &stderrWriter.interface,
            .ctx = cancelCtx.context,
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

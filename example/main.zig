const std = @import("std");
const zcli = @import("zcli");
const GreetCommand = @import("greet_command.zig").GreetCommand;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);
    const args: []const []const u8 = raw_args;

    // バッファ付き writer を生成。cmdr より先に宣言して寿命を包む。
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_w = std.fs.File.stderr().writer(&stderr_buf);

    var cmdr = zcli.Commander.init(
        zcli.Env{
            .allocator = allocator,
            .stdout = &stdout_w.interface,
            .stderr = &stderr_w.interface,
        },
        "mytool",
        "A demonstration CLI tool",
    );
    defer cmdr.deinit();

    var greet = GreetCommand{};
    try cmdr.register(zcli.Command.from(GreetCommand, &greet));

    const status = cmdr.run(args) catch |err| blk: {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        break :blk zcli.ExitStatus.failure;
    };
    // std.process.exit はデファーをスキップするため exit() 前に明示的にフラッシュ
    stdout_w.interface.flush() catch |err| std.debug.print("stdout flush error: {s}\n", .{@errorName(err)});
    stderr_w.interface.flush() catch |err| std.debug.print("stderr flush error: {s}\n", .{@errorName(err)});
    status.exit();
}

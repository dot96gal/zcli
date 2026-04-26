const std = @import("std");
const zcli = @import("zcli");

const GREET_FLAGS = [_]zcli.FlagDef{
    .{
        .long = "name",
        .short = 'n',
        .flagType = .{ .string = .{ .default = "World" } },
        .description = "Name to greet",
    },
    .{
        .long = "count",
        .short = 'c',
        .flagType = .{ .int = .{ .default = 1 } },
        .description = "Number of times to greet",
    },
    .{
        .long = "excited",
        .short = 'e',
        .flagType = .{ .bool = .{ .default = false } },
        .description = "Use exclamation mark",
    },
};

pub const GreetCommand = struct {
    pub fn name() []const u8 {
        return "greet";
    }
    pub fn synopsis() []const u8 {
        return "print a greeting message";
    }

    pub fn usage(_: *GreetCommand, w: *std.Io.Writer) !void {
        try w.print("usage: <program> greet [flags]\n\nFlags:\n", .{});
        try zcli.help.printFlagHelp(w, &GREET_FLAGS);
    }

    pub fn run(_: *GreetCommand, args: []const []const u8, env: *zcli.Env) !zcli.ExitStatus {
        var fs = zcli.FlagSet.init(&GREET_FLAGS);
        defer fs.deinit(env.allocator);

        fs.parse(env.allocator, args) catch |err| {
            try env.stderr.print("flag error: {s}\n", .{@errorName(err)});
            return .usageError;
        };

        const target = fs.getString("name") orelse "World";
        const count = fs.getInt("count") orelse 1;
        const excited = fs.getBool("excited") orelse false;
        const punct: u8 = if (excited) '!' else '.';

        var i: i64 = 0;
        while (i < count) : (i += 1) {
            try env.stdout.print("Hello, {s}{c}\n", .{ target, punct });
        }
        return .success;
    }
};

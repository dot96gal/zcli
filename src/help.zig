const std = @import("std");
const FlagDef = @import("flag_set.zig").FlagDef;
const Command = @import("command.zig").Command;

const ITEM_INDENT = "  ";
const DESC_INDENT = "        ";

/// フラグ一覧のヘルプテキストを w に出力する。
pub fn printFlagHelp(w: *std.Io.Writer, comptime defs: []const FlagDef) !void {
    inline for (defs) |def| {
        const defaultStr: []const u8 = switch (def.flagType) {
            .string => |s| s.default,
            .bool => |b| if (b.default) "true" else "false",
            .int => |i| comptime std.fmt.comptimePrint("{d}", .{i.default}),
        };
        try w.print(ITEM_INDENT ++ "--{s}", .{def.long});
        if (def.short) |sh| try w.print(", -{c}", .{sh});
        try w.print("\n" ++ DESC_INDENT ++ "{s} (default: {s})\n", .{ def.description, defaultStr });
    }
}

/// コマンド一覧（name + synopsis）を w に出力する。
pub fn printCommandList(w: *std.Io.Writer, commands: []const Command) !void {
    for (commands) |cmd| {
        try w.print(ITEM_INDENT ++ "{s}\n" ++ DESC_INDENT ++ "{s}\n", .{ cmd.name(), cmd.synopsis() });
    }
}

const testing = std.testing;
const TestEnv = @import("env.zig").TestEnv;
const FlagType = @import("flag_set.zig").FlagType;
const Env = @import("env.zig").Env;
const ExitStatus = @import("exit_status.zig").ExitStatus;

const MockGreetCmd = struct {
    pub fn name() []const u8 {
        return "greet";
    }
    pub fn synopsis() []const u8 {
        return "say hello";
    }
    pub fn usage(_: *MockGreetCmd, _: *std.Io.Writer) !void {}
    pub fn run(_: *MockGreetCmd, _: []const []const u8, _: *Env) !ExitStatus {
        return .success;
    }
};

const TEST_DEFS = [_]FlagDef{
    .{ .long = "name", .short = 'n', .flagType = .{ .string = .{ .default = "World" } }, .description = "Name to greet" },
    .{ .long = "count", .short = 'c', .flagType = .{ .int = .{ .default = 1 } }, .description = "Times" },
    .{ .long = "verbose", .short = null, .flagType = .{ .bool = .{ .default = false } }, .description = "Verbose" },
};

test "printFlagHelp" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    try printFlagHelp(e.stdout, &TEST_DEFS);

    const out = te.outWriter.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "--name, -n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "default: World") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--count, -c") != null);
    try testing.expect(std.mem.indexOf(u8, out, "default: 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--verbose") != null);
    try testing.expect(std.mem.indexOf(u8, out, "default: false") != null);
}

test "printCommandList outputs name and synopsis" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var mc = MockGreetCmd{};
    const cmd = Command.from(MockGreetCmd, &mc);
    const cmds = [_]Command{cmd};

    try printCommandList(e.stdout, &cmds);

    const out = te.outWriter.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "greet") != null);
    try testing.expect(std.mem.indexOf(u8, out, "say hello") != null);
}

test "printCommandList with empty list outputs nothing" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    try printCommandList(e.stdout, &.{});

    const out = te.outWriter.writer.buffered();
    try testing.expectEqualStrings("", out);
}

test "printFlagHelp exact format with short option" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    const defs = [_]FlagDef{
        .{ .long = "name", .short = 'n', .flagType = .{ .string = .{ .default = "World" } }, .description = "Name to greet" },
    };
    try printFlagHelp(e.stdout, &defs);

    try testing.expectEqualStrings("  --name, -n\n        Name to greet (default: World)\n", te.outWriter.writer.buffered());
}

test "printFlagHelp exact format without short option" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    const defs = [_]FlagDef{
        .{ .long = "verbose", .short = null, .flagType = .{ .bool = .{ .default = false } }, .description = "Verbose" },
    };
    try printFlagHelp(e.stdout, &defs);

    try testing.expectEqualStrings("  --verbose\n        Verbose (default: false)\n", te.outWriter.writer.buffered());
}

test "printFlagHelp with no flags outputs nothing" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    try printFlagHelp(e.stdout, &.{});

    try testing.expectEqualStrings("", te.outWriter.writer.buffered());
}

test "printCommandList exact format" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var mc = MockGreetCmd{};
    const cmd = Command.from(MockGreetCmd, &mc);
    const cmds = [_]Command{cmd};

    try printCommandList(e.stdout, &cmds);

    try testing.expectEqualStrings("  greet\n        say hello\n", te.outWriter.writer.buffered());
}

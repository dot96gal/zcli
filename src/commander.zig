const std = @import("std");
const Command = @import("command.zig").Command;
const Env = @import("env.zig").Env;
const ExitStatus = @import("exit_status.zig").ExitStatus;
const help = @import("help.zig");

/// サブコマンドのルーティングと組み込み `help` コマンドの処理を担うルーター。
pub const Commander = struct {
    env: Env,
    program: []const u8,
    description: []const u8,
    commands: std.ArrayListUnmanaged(Command),

    /// `env`、プログラム名、説明文を受け取り `Commander` を初期化する。
    pub fn init(env: Env, program: []const u8, description: []const u8) Commander {
        return .{
            .env = env,
            .program = program,
            .description = description,
            .commands = .empty,
        };
    }

    /// 登録済みコマンドリストを解放する。
    pub fn deinit(self: *Commander) void {
        self.commands.deinit(self.env.allocator);
    }

    /// サブコマンドを登録する。
    /// コマンドインスタンスの寿命は Commander より長くなければならない。
    /// Commander はポインタを保持するが所有権は持たない。
    pub fn register(self: *Commander, cmd: Command) !void {
        try self.commands.append(self.env.allocator, cmd);
    }

    /// `args`（`argv[0]` 含む全引数）を受け取り、サブコマンドへディスパッチする。
    pub fn run(self: *Commander, args: []const []const u8) !ExitStatus {
        const argv = if (args.len > 0) args[1..] else args;

        if (argv.len == 0) {
            try self.printTopLevelHelp();
            return .usage_error;
        }

        const subcmd_name = argv[0];

        if (std.mem.eql(u8, subcmd_name, "help")) {
            return self.handleHelp(argv[1..]);
        }

        for (self.commands.items) |cmd| {
            if (std.mem.eql(u8, cmd.name(), subcmd_name)) {
                return cmd.run(argv[1..], &self.env);
            }
        }

        try self.env.stderr.print("unknown command: {s}\n\n", .{subcmd_name});
        try self.printTopLevelHelp();
        return .usage_error;
    }

    fn printTopLevelHelp(self: *Commander) !void {
        try self.env.stdout.print("{s}: {s}\n\nCommands:\n", .{ self.program, self.description });
        try help.printCommandList(self.env.stdout, self.commands.items);
    }

    fn handleHelp(self: *Commander, argv: []const []const u8) !ExitStatus {
        if (argv.len == 0) {
            try self.printTopLevelHelp();
            return .success;
        }

        const target = argv[0];
        for (self.commands.items) |cmd| {
            if (std.mem.eql(u8, cmd.name(), target)) {
                try cmd.usage(self.env.stdout);
                return .success;
            }
        }

        try self.env.stderr.print("unknown command: {s}\n", .{target});
        return .failure;
    }
};

const testing = std.testing;
const TestEnv = @import("env.zig").TestEnv;

const MockBuildCmd = struct {
    pub fn name() []const u8 {
        return "build";
    }
    pub fn synopsis() []const u8 {
        return "build something";
    }
    pub fn usage(_: *MockBuildCmd, w: *std.Io.Writer) !void {
        try w.print("usage: build\n", .{});
    }
    pub fn run(_: *MockBuildCmd, _: []const []const u8, _: *Env) !ExitStatus {
        return .failure;
    }
};

const MockGreetCmd = struct {
    pub fn name() []const u8 {
        return "greet";
    }
    pub fn synopsis() []const u8 {
        return "say hello";
    }
    pub fn usage(_: *MockGreetCmd, w: *std.Io.Writer) !void {
        try w.print("usage: greet\n", .{});
    }
    pub fn run(_: *MockGreetCmd, _: []const []const u8, env: *Env) !ExitStatus {
        try env.stdout.print("Hello!\n", .{});
        return .success;
    }
};

test "Commander no subcommand returns usage_error" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    const status = try cmdr.run(&.{"mytool"});
    try testing.expectEqual(ExitStatus.usage_error, status);
}

test "Commander runs registered command" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    var mc = MockGreetCmd{};
    try cmdr.register(Command.from(MockGreetCmd, &mc));

    const status = try cmdr.run(&.{ "mytool", "greet" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expectEqualStrings("Hello!\n", te.out_w.writer.buffered());
}

test "Commander unknown command returns usage_error" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    const status = try cmdr.run(&.{ "mytool", "unknown" });
    try testing.expectEqual(ExitStatus.usage_error, status);
    try testing.expect(std.mem.indexOf(u8, te.err_w.writer.buffered(), "unknown command: unknown") != null);
}

test "Commander help with no arg prints top-level" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    var mc = MockGreetCmd{};
    try cmdr.register(Command.from(MockGreetCmd, &mc));

    const status = try cmdr.run(&.{ "mytool", "help" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expect(std.mem.indexOf(u8, te.out_w.writer.buffered(), "greet") != null);
}

test "Commander help <cmd> prints command usage" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    var mc = MockGreetCmd{};
    try cmdr.register(Command.from(MockGreetCmd, &mc));

    const status = try cmdr.run(&.{ "mytool", "help", "greet" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expectEqualStrings("usage: greet\n", te.out_w.writer.buffered());
}

test "Commander help <unknown> returns failure" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    const status = try cmdr.run(&.{ "mytool", "help", "nope" });
    try testing.expectEqual(ExitStatus.failure, status);
}

test "Commander dispatches to correct command among multiple" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    var mc = MockGreetCmd{};
    var mc2 = MockBuildCmd{};
    try cmdr.register(Command.from(MockGreetCmd, &mc));
    try cmdr.register(Command.from(MockBuildCmd, &mc2));

    const status = try cmdr.run(&.{ "mytool", "greet" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expectEqualStrings("Hello!\n", te.out_w.writer.buffered());
}

test "Commander run with empty args slice" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    const status = try cmdr.run(&.{});
    try testing.expectEqual(ExitStatus.usage_error, status);
}

test "Commander propagates command failure status" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    var mc2 = MockBuildCmd{};
    try cmdr.register(Command.from(MockBuildCmd, &mc2));

    const status = try cmdr.run(&.{ "mytool", "build" });
    try testing.expectEqual(ExitStatus.failure, status);
}

const MockArgCapture = struct {
    captured: []const []const u8 = &.{},

    pub fn name() []const u8 {
        return "capture";
    }
    pub fn synopsis() []const u8 {
        return "capture args";
    }
    pub fn usage(_: *MockArgCapture, _: *std.Io.Writer) !void {}
    pub fn run(self: *MockArgCapture, argv: []const []const u8, _: *Env) !ExitStatus {
        self.captured = argv;
        return .success;
    }
};

test "Commander passes args to subcommand" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    var mc = MockArgCapture{};
    try cmdr.register(Command.from(MockArgCapture, &mc));

    _ = try cmdr.run(&.{ "mytool", "capture", "foo", "bar" });
    try testing.expectEqual(@as(usize, 2), mc.captured.len);
    try testing.expectEqualStrings("foo", mc.captured[0]);
    try testing.expectEqualStrings("bar", mc.captured[1]);
}

test "Commander top-level help exact format" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    var mc = MockGreetCmd{};
    try cmdr.register(Command.from(MockGreetCmd, &mc));

    const status = try cmdr.run(&.{ "mytool", "help" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expectEqualStrings("mytool: A test tool\n\nCommands:\n  greet\n        say hello\n", te.out_w.writer.buffered());
}

test "Commander unknown command writes to stderr" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmdr = Commander.init(e, "mytool", "A test tool");
    defer cmdr.deinit();

    _ = try cmdr.run(&.{ "mytool", "unknown" });
    try testing.expectEqualStrings("unknown command: unknown\n\n", te.err_w.writer.buffered());
}

const std = @import("std");
const Command = @import("command.zig").Command;
const Env = @import("env.zig").Env;
const ExitStatus = @import("exit_status.zig").ExitStatus;
const help = @import("help.zig");

/// コマンドを登録し、引数に応じてディスパッチする CLI アプリケーション。
pub const App = struct {
    env: Env,
    name: []const u8,
    description: []const u8,
    commands: std.ArrayListUnmanaged(Command),

    /// `env`、アプリケーション名、説明文を受け取り `App` を初期化する。
    pub fn init(env: Env, name: []const u8, description: []const u8) App {
        return .{
            .env = env,
            .name = name,
            .description = description,
            .commands = .empty,
        };
    }

    /// 登録済みコマンドリストを解放する。
    pub fn deinit(self: *App) void {
        self.commands.deinit(self.env.allocator);
    }

    /// コマンドを登録する。
    /// コマンドインスタンスの寿命は App より長くなければならない。
    /// App はポインタを保持するが所有権は持たない。
    pub fn register(self: *App, cmd: Command) error{OutOfMemory}!void {
        try self.commands.append(self.env.allocator, cmd);
    }

    /// `args`（`argv[0]` 含む全引数）を受け取り、コマンドへディスパッチする。
    pub fn run(self: *App, args: []const []const u8) !ExitStatus {
        const argv = if (args.len > 0) args[1..] else args;

        if (argv.len == 0) {
            try self.printTopLevelHelp();
            return .usageError;
        }

        const cmdName = argv[0];

        if (std.mem.eql(u8, cmdName, "help")) {
            return self.handleHelp(argv[1..]);
        }

        for (self.commands.items) |cmd| {
            if (std.mem.eql(u8, cmd.name(), cmdName)) {
                return cmd.run(argv[1..], &self.env);
            }
        }

        try self.env.stderr.print("unknown command: {s}\n\n", .{cmdName});
        try self.printTopLevelHelp();
        return .usageError;
    }

    fn printTopLevelHelp(self: *App) !void {
        try self.env.stdout.print("{s}: {s}\n\nCommands:\n", .{ self.name, self.description });
        try help.printCommandList(self.env.stdout, self.commands.items);
    }

    fn handleHelp(self: *App, argv: []const []const u8) !ExitStatus {
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

test "App no command returns usageError" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    const status = try app.run(&.{"mytool"});
    try testing.expectEqual(ExitStatus.usageError, status);
}

test "App runs registered command" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    var mc = MockGreetCmd{};
    try app.register(Command.from(MockGreetCmd, &mc));

    const status = try app.run(&.{ "mytool", "greet" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expectEqualStrings("Hello!\n", te.outWriter.writer.buffered());
}

test "App unknown command returns usageError" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    const status = try app.run(&.{ "mytool", "unknown" });
    try testing.expectEqual(ExitStatus.usageError, status);
    try testing.expect(std.mem.indexOf(u8, te.errWriter.writer.buffered(), "unknown command: unknown") != null);
}

test "App help with no arg prints top-level" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    var mc = MockGreetCmd{};
    try app.register(Command.from(MockGreetCmd, &mc));

    const status = try app.run(&.{ "mytool", "help" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expect(std.mem.indexOf(u8, te.outWriter.writer.buffered(), "greet") != null);
}

test "App help <cmd> prints command usage" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    var mc = MockGreetCmd{};
    try app.register(Command.from(MockGreetCmd, &mc));

    const status = try app.run(&.{ "mytool", "help", "greet" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expectEqualStrings("usage: greet\n", te.outWriter.writer.buffered());
}

test "App help <unknown> returns failure" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    const status = try app.run(&.{ "mytool", "help", "nope" });
    try testing.expectEqual(ExitStatus.failure, status);
}

test "App dispatches to correct command among multiple" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    var mc = MockGreetCmd{};
    var mc2 = MockBuildCmd{};
    try app.register(Command.from(MockGreetCmd, &mc));
    try app.register(Command.from(MockBuildCmd, &mc2));

    const status = try app.run(&.{ "mytool", "greet" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expectEqualStrings("Hello!\n", te.outWriter.writer.buffered());
}

test "App run with empty args slice" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    const status = try app.run(&.{});
    try testing.expectEqual(ExitStatus.usageError, status);
}

test "App propagates command failure status" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    var mc2 = MockBuildCmd{};
    try app.register(Command.from(MockBuildCmd, &mc2));

    const status = try app.run(&.{ "mytool", "build" });
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

test "App passes args to command" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    var mc = MockArgCapture{};
    try app.register(Command.from(MockArgCapture, &mc));

    _ = try app.run(&.{ "mytool", "capture", "foo", "bar" });
    try testing.expectEqual(@as(usize, 2), mc.captured.len);
    try testing.expectEqualStrings("foo", mc.captured[0]);
    try testing.expectEqualStrings("bar", mc.captured[1]);
}

test "App top-level help exact format" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    var mc = MockGreetCmd{};
    try app.register(Command.from(MockGreetCmd, &mc));

    const status = try app.run(&.{ "mytool", "help" });
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expectEqualStrings("mytool: A test tool\n\nCommands:\n  greet\n        say hello\n", te.outWriter.writer.buffered());
}

test "App unknown command writes to stderr" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var app = App.init(e, "mytool", "A test tool");
    defer app.deinit();

    _ = try app.run(&.{ "mytool", "unknown" });
    try testing.expectEqualStrings("unknown command: unknown\n\n", te.errWriter.writer.buffered());
}

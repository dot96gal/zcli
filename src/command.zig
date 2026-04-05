const std = @import("std");
const Env = @import("env.zig").Env;
const ExitStatus = @import("exit_status.zig").ExitStatus;

pub const Command = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn () []const u8,
        synopsis: *const fn () []const u8,
        usage: *const fn (*anyopaque, *std.Io.Writer) anyerror!void,
        run: *const fn (*anyopaque, []const []const u8, *Env) anyerror!ExitStatus,
    };

    pub fn name(self: Command) []const u8 {
        return self.vtable.name();
    }

    pub fn synopsis(self: Command) []const u8 {
        return self.vtable.synopsis();
    }

    pub fn usage(self: Command, w: *std.Io.Writer) !void {
        return self.vtable.usage(self.ptr, w);
    }

    pub fn run(self: Command, args: []const []const u8, env: *Env) !ExitStatus {
        return self.vtable.run(self.ptr, args, env);
    }

    /// T型からvtableを自動生成し Command を返す。
    /// T は name/synopsis/usage/run を宣言していなければコンパイルエラー。
    pub fn from(comptime T: type, ptr: *T) Command {
        comptime validateCommand(T);

        const vtable = comptime &VTable{
            .name = struct {
                fn f() []const u8 {
                    return T.name();
                }
            }.f,

            .synopsis = struct {
                fn f() []const u8 {
                    return T.synopsis();
                }
            }.f,

            .usage = struct {
                fn f(p: *anyopaque, w: *std.Io.Writer) anyerror!void {
                    return @as(*T, @ptrCast(@alignCast(p))).usage(w);
                }
            }.f,

            .run = struct {
                fn f(p: *anyopaque, args: []const []const u8, env: *Env) anyerror!ExitStatus {
                    return @as(*T, @ptrCast(@alignCast(p))).run(args, env);
                }
            }.f,
        };

        return .{ .ptr = ptr, .vtable = vtable };
    }
};

/// Command.from() から呼ばれる内部検証関数。直接呼び出し不要。
fn validateCommand(comptime T: type) void {
    const ti = @typeInfo(T);
    if (ti != .@"struct")
        @compileError("Command type must be a struct, got: " ++ @typeName(T));

    if (!@hasDecl(T, "name"))
        @compileError(@typeName(T) ++ " must declare: pub fn name() []const u8");
    if (!@hasDecl(T, "synopsis"))
        @compileError(@typeName(T) ++ " must declare: pub fn synopsis() []const u8");
    if (!@hasDecl(T, "usage"))
        @compileError(@typeName(T) ++ " must declare: pub fn usage(*T, *std.Io.Writer) !void");
    if (!@hasDecl(T, "run"))
        @compileError(@typeName(T) ++ " must declare: pub fn run(*T, []const []const u8, *Env) !ExitStatus");
}

const testing = std.testing;
const TestEnv = @import("env.zig").TestEnv;

const MockCommand = struct {
    pub fn name() []const u8 {
        return "mock";
    }
    pub fn synopsis() []const u8 {
        return "a mock command";
    }
    pub fn usage(_: *MockCommand, w: *std.Io.Writer) !void {
        try w.print("usage: mock\n", .{});
    }
    pub fn run(_: *MockCommand, _: []const []const u8, env: *Env) !ExitStatus {
        try env.stdout.print("mock ran\n", .{});
        return .success;
    }
};

test "Command.from name and synopsis" {
    var m = MockCommand{};
    const cmd = Command.from(MockCommand, &m);
    try testing.expectEqualStrings("mock", cmd.name());
    try testing.expectEqualStrings("a mock command", cmd.synopsis());
}

test "Command.from run" {
    var m = MockCommand{};
    const cmd = Command.from(MockCommand, &m);

    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    const status = try cmd.run(&.{}, @constCast(&e));
    try testing.expectEqual(ExitStatus.success, status);
    try testing.expectEqualStrings("mock ran\n", te.out_w.writer.buffered());
}

test "Command.from usage" {
    var m = MockCommand{};
    const cmd = Command.from(MockCommand, &m);

    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    try cmd.usage(e.stdout);
    try testing.expectEqualStrings("usage: mock\n", te.out_w.writer.buffered());
}

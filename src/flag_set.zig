const std = @import("std");

/// フラグの値型と各型のデフォルト値を保持する union。
pub const FlagType = union(enum) {
    /// 文字列型フラグ。デフォルト値の型は `[]const u8` になる。
    string: struct { default: []const u8 },
    /// 真偽値型フラグ。デフォルト値の型は `bool` になる。
    bool: struct { default: bool },
    /// 整数型フラグ。デフォルト値の型は `i64` になる。
    int: struct { default: i64 },
};

/// フラグの定義を表す構造体。
/// `FlagSet.init` の `comptime defs` に渡してください。
pub const FlagDef = struct {
    /// ロングフラグ名（`--name` の `name` 部分）。
    long: []const u8,
    /// ショートフラグ文字（`-n` の `n`）。不要な場合は `null` を指定する。
    short: ?u8,
    /// フラグの型とデフォルト値を指定する。
    flagType: FlagType,
    /// ヘルプテキストに表示する説明文を指定する。
    description: []const u8,
};

/// 内部で使用する型。
/// 利用者は `getString`/`getBool`/`getInt` 経由でアクセスするため直接使用しないでください。
const FlagValue = union(enum) {
    string: []const u8,
    bool: bool,
    int: i64,
};

/// フラグパース時に発生するエラーの集合。
pub const ParseError = error{
    /// 定義されていないフラグが指定された。
    UnknownFlag,
    /// 値が必要なフラグに値が渡されなかった。
    MissingValue,
    /// 整数フラグに整数として解釈できない値が渡された。
    InvalidIntValue,
    /// メモリ確保に失敗した。
    OutOfMemory,
};

/// フラグパーサー。
/// `--long`、`-s`、`--key=val`、`--` 形式に対応しています。
pub const FlagSet = struct {
    defs: []const FlagDef,
    values: std.StringHashMapUnmanaged(FlagValue),
    /// 内部フィールド。直接アクセスせず `positionals()` メソッドを使用してください。
    positionalsBuf: std.ArrayListUnmanaged([]const u8),

    /// `defs` を受け取り `FlagSet` を初期化する。
    pub fn init(comptime defs: []const FlagDef) FlagSet {
        return .{
            .defs = defs,
            .values = .{},
            .positionalsBuf = .empty,
        };
    }

    /// 所有するメモリをすべて解放する。
    pub fn deinit(self: *FlagSet, allocator: std.mem.Allocator) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .string => |s| allocator.free(s),
                else => {},
            }
        }
        self.values.deinit(allocator);
        for (self.positionalsBuf.items) |p| {
            allocator.free(p);
        }
        self.positionalsBuf.deinit(allocator);
    }

    /// `args` を解析してフラグと位置引数を取り込む。エラー時は `ParseError` を返す。
    pub fn parse(self: *FlagSet, allocator: std.mem.Allocator, args: []const []const u8) ParseError!void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--")) {
                i += 1;
                while (i < args.len) : (i += 1) {
                    const duped = try allocator.dupe(u8, args[i]);
                    try self.positionalsBuf.append(allocator, duped);
                }
                break;
            }

            if (std.mem.startsWith(u8, arg, "--")) {
                const body = arg[2..];
                if (std.mem.indexOf(u8, body, "=")) |eq| {
                    const key = body[0..eq];
                    const val = body[eq + 1 ..];
                    const def = self.findLong(key) orelse return ParseError.UnknownFlag;
                    try self.store(allocator, def, key, val);
                } else {
                    const def = self.findLong(body) orelse return ParseError.UnknownFlag;
                    switch (def.flagType) {
                        .bool => try self.storeBool(allocator, body, true),
                        else => {
                            if (i + 1 >= args.len) return ParseError.MissingValue;
                            i += 1;
                            try self.store(allocator, def, body, args[i]);
                        },
                    }
                }
            } else if (arg.len == 2 and arg[0] == '-') {
                const shortChar = arg[1];
                if (shortChar >= '0' and shortChar <= '9') {
                    const duped = try allocator.dupe(u8, arg);
                    try self.positionalsBuf.append(allocator, duped);
                } else {
                    const def = self.findShort(shortChar) orelse return ParseError.UnknownFlag;
                    switch (def.flagType) {
                        .bool => try self.storeBool(allocator, def.long, true),
                        else => {
                            if (i + 1 >= args.len) return ParseError.MissingValue;
                            i += 1;
                            try self.store(allocator, def, def.long, args[i]);
                        },
                    }
                }
            } else {
                const duped = try allocator.dupe(u8, arg);
                try self.positionalsBuf.append(allocator, duped);
            }
        }

        // 未設定フラグにデフォルト値を挿入
        for (self.defs) |def| {
            if (!self.values.contains(def.long)) {
                const key = try allocator.dupe(u8, def.long);
                errdefer allocator.free(key);
                var dupedString: ?[]u8 = null;
                errdefer if (dupedString) |s| allocator.free(s);
                const val: FlagValue = switch (def.flagType) {
                    .string => |s| blk: {
                        const duped = try allocator.dupe(u8, s.default);
                        dupedString = duped;
                        break :blk .{ .string = duped };
                    },
                    .bool => |b| .{ .bool = b.default },
                    .int => |n| .{ .int = n.default },
                };
                try self.values.put(allocator, key, val);
                dupedString = null;
            }
        }
    }

    /// フラグ以外の位置引数の一覧を返す。
    pub fn positionals(self: *const FlagSet) []const []const u8 {
        return self.positionalsBuf.items;
    }

    /// 文字列フラグ `name` の値を返す。未定義または型不一致の場合は `null` を返す。
    pub fn getString(self: *const FlagSet, name: []const u8) ?[]const u8 {
        const val = self.values.get(name) orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    /// 真偽値フラグ `name` の値を返す。未定義または型不一致の場合は `null` を返す。
    pub fn getBool(self: *const FlagSet, name: []const u8) ?bool {
        const val = self.values.get(name) orelse return null;
        return switch (val) {
            .bool => |b| b,
            else => null,
        };
    }

    /// 整数フラグ `name` の値を返す。未定義または型不一致の場合は `null` を返す。
    pub fn getInt(self: *const FlagSet, name: []const u8) ?i64 {
        const val = self.values.get(name) orelse return null;
        return switch (val) {
            .int => |n| n,
            else => null,
        };
    }

    fn findLong(self: *const FlagSet, name: []const u8) ?FlagDef {
        for (self.defs) |def| {
            if (std.mem.eql(u8, def.long, name)) return def;
        }
        return null;
    }

    fn findShort(self: *const FlagSet, ch: u8) ?FlagDef {
        for (self.defs) |def| {
            if (def.short) |s| {
                if (s == ch) return def;
            }
        }
        return null;
    }

    fn store(self: *FlagSet, allocator: std.mem.Allocator, def: FlagDef, key: []const u8, raw: []const u8) ParseError!void {
        // 後勝ち: 既存キーを置き換える場合は古い値を解放
        if (self.values.getEntry(key)) |entry| {
            const val: FlagValue = switch (def.flagType) {
                .string => .{ .string = try allocator.dupe(u8, raw) },
                .bool => .{ .bool = true },
                .int => blk: {
                    const n = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidIntValue;
                    break :blk .{ .int = n };
                },
            };
            switch (entry.value_ptr.*) {
                .string => |s| allocator.free(s),
                else => {},
            }
            entry.value_ptr.* = val;
        } else {
            const k = try allocator.dupe(u8, key);
            errdefer allocator.free(k);
            var dupedString: ?[]u8 = null;
            errdefer if (dupedString) |s| allocator.free(s);
            const val: FlagValue = switch (def.flagType) {
                .string => v: {
                    const s = try allocator.dupe(u8, raw);
                    dupedString = s;
                    break :v .{ .string = s };
                },
                .bool => .{ .bool = true },
                .int => blk: {
                    const n = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidIntValue;
                    break :blk .{ .int = n };
                },
            };
            try self.values.put(allocator, k, val);
            dupedString = null;
        }
    }

    fn storeBool(self: *FlagSet, allocator: std.mem.Allocator, key: []const u8, val: bool) ParseError!void {
        if (self.values.getEntry(key)) |entry| {
            entry.value_ptr.* = .{ .bool = val };
        } else {
            const k = try allocator.dupe(u8, key);
            errdefer allocator.free(k);
            try self.values.put(allocator, k, .{ .bool = val });
        }
    }
};

const testing = std.testing;

const TEST_DEFS = [_]FlagDef{
    .{ .long = "name", .short = 'n', .flagType = .{ .string = .{ .default = "World" } }, .description = "Name" },
    .{ .long = "count", .short = 'c', .flagType = .{ .int = .{ .default = 1 } }, .description = "Count" },
    .{ .long = "verbose", .short = 'v', .flagType = .{ .bool = .{ .default = false } }, .description = "Verbose" },
};

test "FlagSet defaults" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{});
    try testing.expectEqualStrings("World", fs.getString("name").?);
    try testing.expectEqual(@as(i64, 1), fs.getInt("count").?);
    try testing.expectEqual(false, fs.getBool("verbose").?);
}

test "FlagSet long flag --name Alice" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{ "--name", "Alice" });
    try testing.expectEqualStrings("Alice", fs.getString("name").?);
}

test "FlagSet long flag --name=Alice" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{"--name=Alice"});
    try testing.expectEqualStrings("Alice", fs.getString("name").?);
}

test "FlagSet short flag -n Alice" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{ "-n", "Alice" });
    try testing.expectEqualStrings("Alice", fs.getString("name").?);
}

test "FlagSet bool flag --verbose" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{"--verbose"});
    try testing.expectEqual(true, fs.getBool("verbose").?);
}

test "FlagSet bool flag -v" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{"-v"});
    try testing.expectEqual(true, fs.getBool("verbose").?);
}

test "FlagSet int flag --count 3" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{ "--count", "3" });
    try testing.expectEqual(@as(i64, 3), fs.getInt("count").?);
}

test "FlagSet positional args" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{ "foo", "bar" });
    const pos = fs.positionals();
    try testing.expectEqual(@as(usize, 2), pos.len);
    try testing.expectEqualStrings("foo", pos[0]);
    try testing.expectEqualStrings("bar", pos[1]);
}

test "FlagSet -- passthrough" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{ "--", "--name", "Alice" });
    const pos = fs.positionals();
    try testing.expectEqual(@as(usize, 2), pos.len);
    try testing.expectEqualStrings("--name", pos[0]);
    try testing.expectEqualStrings("Alice", pos[1]);
}

test "FlagSet unknown flag error" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try testing.expectError(ParseError.UnknownFlag, fs.parse(testing.allocator, &.{"--unknown"}));
}

test "FlagSet missing value error" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try testing.expectError(ParseError.MissingValue, fs.parse(testing.allocator, &.{"--name"}));
}

test "FlagSet invalid int error" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try testing.expectError(ParseError.InvalidIntValue, fs.parse(testing.allocator, &.{ "--count", "abc" }));
}

test "FlagSet last wins" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{ "--name", "Alice", "--name", "Bob" });
    try testing.expectEqualStrings("Bob", fs.getString("name").?);
}

test "FlagSet negative int value" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{ "--count", "-5" });
    try testing.expectEqual(@as(i64, -5), fs.getInt("count").?);
}

test "FlagSet single-digit negative number as positional" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{"-5"});
    const pos = fs.positionals();
    try testing.expectEqual(@as(usize, 1), pos.len);
    try testing.expectEqualStrings("-5", pos[0]);
}

test "FlagSet mixed flags and positionals" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{ "--name", "Alice", "foo", "--verbose", "bar" });
    try testing.expectEqualStrings("Alice", fs.getString("name").?);
    try testing.expectEqual(true, fs.getBool("verbose").?);
    const pos = fs.positionals();
    try testing.expectEqual(@as(usize, 2), pos.len);
    try testing.expectEqualStrings("foo", pos[0]);
    try testing.expectEqualStrings("bar", pos[1]);
}

test "FlagSet empty string value" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{ "--name", "" });
    try testing.expectEqualStrings("", fs.getString("name").?);
}

test "FlagSet unknown short flag error" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try testing.expectError(ParseError.UnknownFlag, fs.parse(testing.allocator, &.{"-x"}));
}

test "FlagSet short flag missing value error" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try testing.expectError(ParseError.MissingValue, fs.parse(testing.allocator, &.{"-n"}));
}

test "FlagSet getString returns null for bool flag" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{});
    try testing.expect(fs.getString("verbose") == null);
}

test "FlagSet getBool returns null for string flag" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{});
    try testing.expect(fs.getBool("name") == null);
}

test "FlagSet getInt returns null for string flag" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{});
    try testing.expect(fs.getInt("name") == null);
}

test "FlagSet getString returns null for unknown name" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{});
    try testing.expect(fs.getString("nonexistent") == null);
}

test "FlagSet inline empty value --name=" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{"--name="});
    try testing.expectEqualStrings("", fs.getString("name").?);
}

test "FlagSet storeBool no leak on OOM" {
    var failIndex: usize = 0;
    while (failIndex < 10) : (failIndex += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = failIndex },
        );
        var fs = FlagSet.init(&TEST_DEFS);
        defer fs.deinit(failing.allocator());
        fs.parse(failing.allocator(), &.{"-v"}) catch {};
    }
}

test "FlagSet store string no leak on OOM" {
    var failIndex: usize = 0;
    while (failIndex < 10) : (failIndex += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = failIndex },
        );
        var fs = FlagSet.init(&TEST_DEFS);
        defer fs.deinit(failing.allocator());
        fs.parse(failing.allocator(), &.{ "--name", "Alice" }) catch {};
    }
}

test "FlagSet parse defaults no leak on OOM" {
    var failIndex: usize = 0;
    while (failIndex < 20) : (failIndex += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = failIndex },
        );
        var fs = FlagSet.init(&TEST_DEFS);
        defer fs.deinit(failing.allocator());
        fs.parse(failing.allocator(), &.{}) catch {};
    }
}

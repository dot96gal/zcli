const std = @import("std");

/// フラグの値型と各型のデフォルト値を保持する union。
pub const FlagType = union(enum) {
    /// 文字列フラグ。デフォルト値は `[]const u8`。
    string: struct { default: []const u8 },
    /// 真偽値フラグ。デフォルト値は `bool`。
    bool: struct { default: bool },
    /// 整数フラグ。デフォルト値は `i64`。
    int: struct { default: i64 },
};

/// フラグ定義。`FlagSet.init` の `comptime defs` に渡す。
pub const FlagDef = struct {
    /// ロングフラグ名（`--name` の `name` 部分）。
    long: []const u8,
    /// ショートフラグ文字（`-n` の `n`）。不要な場合は `null`。
    short: ?u8,
    /// フラグの型とデフォルト値。
    flag_type: FlagType,
    /// ヘルプテキストに表示する説明文。
    description: []const u8,
};

/// 内部型。利用者は getString/getBool/getInt 経由でアクセスするため直接使用しないこと。
const FlagValue = union(enum) {
    string: []const u8,
    bool: bool,
    int: i64,
};

/// フラグパース時のエラー集合。
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

/// フラグパーサー。`--long`、`-s`、`--key=val`、`--` に対応。
pub const FlagSet = struct {
    allocator: std.mem.Allocator,
    defs: []const FlagDef,
    values: std.StringHashMapUnmanaged(FlagValue),
    /// 内部フィールド。直接アクセスせず positionals() メソッドを使うこと。
    positionals_buf: std.ArrayListUnmanaged([]const u8),

    /// `defs` を受け取り `FlagSet` を初期化する。
    pub fn init(allocator: std.mem.Allocator, comptime defs: []const FlagDef) FlagSet {
        return .{
            .allocator = allocator,
            .defs = defs,
            .values = .{},
            .positionals_buf = .empty,
        };
    }

    /// 所有するメモリをすべて解放する。
    pub fn deinit(self: *FlagSet) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .string => |s| self.allocator.free(s),
                else => {},
            }
        }
        self.values.deinit(self.allocator);
        for (self.positionals_buf.items) |p| {
            self.allocator.free(p);
        }
        self.positionals_buf.deinit(self.allocator);
    }

    /// `args` を解析してフラグと位置引数を取り込む。エラー時は `ParseError` を返す。
    pub fn parse(self: *FlagSet, args: []const []const u8) ParseError!void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--")) {
                i += 1;
                while (i < args.len) : (i += 1) {
                    const duped = try self.allocator.dupe(u8, args[i]);
                    try self.positionals_buf.append(self.allocator, duped);
                }
                break;
            }

            if (std.mem.startsWith(u8, arg, "--")) {
                const body = arg[2..];
                if (std.mem.indexOf(u8, body, "=")) |eq| {
                    const key = body[0..eq];
                    const val = body[eq + 1 ..];
                    const def = self.findLong(key) orelse return ParseError.UnknownFlag;
                    try self.store(def, key, val);
                } else {
                    const def = self.findLong(body) orelse return ParseError.UnknownFlag;
                    switch (def.flag_type) {
                        .bool => try self.storeBool(body, true),
                        else => {
                            if (i + 1 >= args.len) return ParseError.MissingValue;
                            i += 1;
                            try self.store(def, body, args[i]);
                        },
                    }
                }
            } else if (arg.len == 2 and arg[0] == '-') {
                const short_char = arg[1];
                if (short_char >= '0' and short_char <= '9') {
                    const duped = try self.allocator.dupe(u8, arg);
                    try self.positionals_buf.append(self.allocator, duped);
                } else {
                    const def = self.findShort(short_char) orelse return ParseError.UnknownFlag;
                    switch (def.flag_type) {
                        .bool => try self.storeBool(def.long, true),
                        else => {
                            if (i + 1 >= args.len) return ParseError.MissingValue;
                            i += 1;
                            try self.store(def, def.long, args[i]);
                        },
                    }
                }
            } else {
                const duped = try self.allocator.dupe(u8, arg);
                try self.positionals_buf.append(self.allocator, duped);
            }
        }

        // 未設定フラグにデフォルト値を挿入
        for (self.defs) |def| {
            if (!self.values.contains(def.long)) {
                const key = try self.allocator.dupe(u8, def.long);
                const val: FlagValue = switch (def.flag_type) {
                    .string => |s| blk: {
                        const duped = try self.allocator.dupe(u8, s.default);
                        break :blk .{ .string = duped };
                    },
                    .bool => |b| .{ .bool = b.default },
                    .int => |n| .{ .int = n.default },
                };
                try self.values.put(self.allocator, key, val);
            }
        }
    }

    /// フラグ以外の位置引数の一覧を返す。
    pub fn positionals(self: *const FlagSet) []const []const u8 {
        return self.positionals_buf.items;
    }

    /// 文字列フラグ `name` の値を返す。未定義または型不一致の場合は `null`。
    pub fn getString(self: *const FlagSet, name: []const u8) ?[]const u8 {
        const val = self.values.get(name) orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    /// 真偽値フラグ `name` の値を返す。未定義または型不一致の場合は `null`。
    pub fn getBool(self: *const FlagSet, name: []const u8) ?bool {
        const val = self.values.get(name) orelse return null;
        return switch (val) {
            .bool => |b| b,
            else => null,
        };
    }

    /// 整数フラグ `name` の値を返す。未定義または型不一致の場合は `null`。
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

    fn store(self: *FlagSet, def: FlagDef, key: []const u8, raw: []const u8) ParseError!void {
        const val: FlagValue = switch (def.flag_type) {
            .string => .{ .string = try self.allocator.dupe(u8, raw) },
            .bool => .{ .bool = true },
            .int => blk: {
                const n = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidIntValue;
                break :blk .{ .int = n };
            },
        };
        // 後勝ち: 既存キーを置き換える場合は古い値を解放
        if (self.values.getEntry(key)) |entry| {
            switch (entry.value_ptr.*) {
                .string => |s| self.allocator.free(s),
                else => {},
            }
            entry.value_ptr.* = val;
        } else {
            const k = try self.allocator.dupe(u8, key);
            try self.values.put(self.allocator, k, val);
        }
    }

    fn storeBool(self: *FlagSet, key: []const u8, val: bool) ParseError!void {
        if (self.values.getEntry(key)) |entry| {
            entry.value_ptr.* = .{ .bool = val };
        } else {
            const k = try self.allocator.dupe(u8, key);
            try self.values.put(self.allocator, k, .{ .bool = val });
        }
    }
};

const testing = std.testing;

const TEST_DEFS = [_]FlagDef{
    .{ .long = "name", .short = 'n', .flag_type = .{ .string = .{ .default = "World" } }, .description = "Name" },
    .{ .long = "count", .short = 'c', .flag_type = .{ .int = .{ .default = 1 } }, .description = "Count" },
    .{ .long = "verbose", .short = 'v', .flag_type = .{ .bool = .{ .default = false } }, .description = "Verbose" },
};

test "FlagSet defaults" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{});
    try testing.expectEqualStrings("World", fs.getString("name").?);
    try testing.expectEqual(@as(i64, 1), fs.getInt("count").?);
    try testing.expectEqual(false, fs.getBool("verbose").?);
}

test "FlagSet long flag --name Alice" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{ "--name", "Alice" });
    try testing.expectEqualStrings("Alice", fs.getString("name").?);
}

test "FlagSet long flag --name=Alice" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{"--name=Alice"});
    try testing.expectEqualStrings("Alice", fs.getString("name").?);
}

test "FlagSet short flag -n Alice" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{ "-n", "Alice" });
    try testing.expectEqualStrings("Alice", fs.getString("name").?);
}

test "FlagSet bool flag --verbose" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{"--verbose"});
    try testing.expectEqual(true, fs.getBool("verbose").?);
}

test "FlagSet bool flag -v" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{"-v"});
    try testing.expectEqual(true, fs.getBool("verbose").?);
}

test "FlagSet int flag --count 3" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{ "--count", "3" });
    try testing.expectEqual(@as(i64, 3), fs.getInt("count").?);
}

test "FlagSet positional args" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{ "foo", "bar" });
    const pos = fs.positionals();
    try testing.expectEqual(@as(usize, 2), pos.len);
    try testing.expectEqualStrings("foo", pos[0]);
    try testing.expectEqualStrings("bar", pos[1]);
}

test "FlagSet -- passthrough" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{ "--", "--name", "Alice" });
    const pos = fs.positionals();
    try testing.expectEqual(@as(usize, 2), pos.len);
    try testing.expectEqualStrings("--name", pos[0]);
    try testing.expectEqualStrings("Alice", pos[1]);
}

test "FlagSet unknown flag error" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try testing.expectError(ParseError.UnknownFlag, fs.parse(&.{"--unknown"}));
}

test "FlagSet missing value error" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try testing.expectError(ParseError.MissingValue, fs.parse(&.{"--name"}));
}

test "FlagSet invalid int error" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try testing.expectError(ParseError.InvalidIntValue, fs.parse(&.{ "--count", "abc" }));
}

test "FlagSet last wins" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{ "--name", "Alice", "--name", "Bob" });
    try testing.expectEqualStrings("Bob", fs.getString("name").?);
}

test "FlagSet negative int value" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{ "--count", "-5" });
    try testing.expectEqual(@as(i64, -5), fs.getInt("count").?);
}

test "FlagSet single-digit negative number as positional" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{"-5"});
    const pos = fs.positionals();
    try testing.expectEqual(@as(usize, 1), pos.len);
    try testing.expectEqualStrings("-5", pos[0]);
}

test "FlagSet mixed flags and positionals" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{ "--name", "Alice", "foo", "--verbose", "bar" });
    try testing.expectEqualStrings("Alice", fs.getString("name").?);
    try testing.expectEqual(true, fs.getBool("verbose").?);
    const pos = fs.positionals();
    try testing.expectEqual(@as(usize, 2), pos.len);
    try testing.expectEqualStrings("foo", pos[0]);
    try testing.expectEqualStrings("bar", pos[1]);
}

test "FlagSet empty string value" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{ "--name", "" });
    try testing.expectEqualStrings("", fs.getString("name").?);
}

test "FlagSet unknown short flag error" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try testing.expectError(ParseError.UnknownFlag, fs.parse(&.{"-x"}));
}

test "FlagSet short flag missing value error" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try testing.expectError(ParseError.MissingValue, fs.parse(&.{"-n"}));
}

test "FlagSet getString returns null for bool flag" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{});
    try testing.expect(fs.getString("verbose") == null);
}

test "FlagSet getBool returns null for string flag" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{});
    try testing.expect(fs.getBool("name") == null);
}

test "FlagSet getInt returns null for string flag" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{});
    try testing.expect(fs.getInt("name") == null);
}

test "FlagSet getString returns null for unknown name" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{});
    try testing.expect(fs.getString("nonexistent") == null);
}

test "FlagSet inline empty value --name=" {
    var fs = FlagSet.init(testing.allocator, &TEST_DEFS);
    defer fs.deinit();
    try fs.parse(&.{"--name="});
    try testing.expectEqualStrings("", fs.getString("name").?);
}

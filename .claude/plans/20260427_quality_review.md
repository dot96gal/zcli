# 品質レビュー指摘事項と修正計画（ISO/IEC 25010）

実施日：2026-04-27  
対象：`src/` 以下の全モジュール

---

## 指摘事項と修正案

### 優先度：高

#### 1. `--bool=false` が黙って `true` になるバグ

**ファイル**：`src/flag_set.zig:209`, `src/flag_set.zig:232`  
**品質特性**：機能適合性（機能正確性）/ 信頼性（障害許容性）

**問題**：`store()` の `bool` 分岐が `raw` を無視して常に `true` を設定する。
`--verbose=false` を渡すと `false` でなく `true` として記録される。
テストケースも存在しない。

```zig
// 現状（raw を無視）
.bool => .{ .bool = true },
```

**採用：修正案 B — `true/false/1/0` を解釈する**

手順：

1. `ParseError` に `InvalidBoolValue` を追加する（`src/flag_set.zig:35-44`）

```zig
pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidIntValue,
    InvalidBoolValue,  // 追加
    OutOfMemory,
};
```

2. `store()` の `bool` 分岐を2か所（更新パス・挿入パス）修正する（`src/flag_set.zig:210`, `src/flag_set.zig:232`）

```zig
.bool => blk: {
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1"))
        break :blk .{ .bool = true };
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0"))
        break :blk .{ .bool = false };
    return ParseError.InvalidBoolValue;
},
```

3. 以下のテストを追加する

```zig
test "FlagSet --verbose=false sets false" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{"--verbose=false"});
    try testing.expectEqual(false, fs.getBool("verbose").?);
}

test "FlagSet --verbose=true sets true" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{"--verbose=true"});
    try testing.expectEqual(true, fs.getBool("verbose").?);
}

test "FlagSet --verbose=1 sets true" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{"--verbose=1"});
    try testing.expectEqual(true, fs.getBool("verbose").?);
}

test "FlagSet --verbose=0 sets false" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try fs.parse(testing.allocator, &.{"--verbose=0"});
    try testing.expectEqual(false, fs.getBool("verbose").?);
}

test "FlagSet --verbose=invalid returns InvalidBoolValue" {
    var fs = FlagSet.init(&TEST_DEFS);
    defer fs.deinit(testing.allocator);
    try testing.expectError(ParseError.InvalidBoolValue, fs.parse(testing.allocator, &.{"--verbose=yes"}));
}
```

---

### 優先度：中

#### 2. `FlagSet.parse()` が大きすぎる（75行・3段ネスト）

**ファイル**：`src/flag_set.zig:81-155`  
**品質特性**：保守性（テスト容易性・変更容易性）

**問題**：`--long` 解析・`-s` 解析・デフォルト挿入の3責務が1関数に混在している。

**修正案**：以下の3プライベート関数に分割する。

```zig
fn parseLongFlag(self: *FlagSet, allocator: std.mem.Allocator, arg: []const u8, i: *usize, args: []const []const u8) ParseError!void
fn parseShortFlag(self: *FlagSet, allocator: std.mem.Allocator, arg: []const u8, i: *usize, args: []const []const u8) ParseError!void
fn applyDefaults(self: *FlagSet, allocator: std.mem.Allocator) ParseError!void
```

将来の `--no-verbose` 否定フラグ対応なども局所的な変更で済むようになる。

---

#### 3. `store()` と `storeBool()` にキー確保パターンの重複

**ファイル**：`src/flag_set.zig:221-239`（store）, `src/flag_set.zig:246-250`（storeBool）  
**品質特性**：保守性（変更容易性）

**問題**：「キーを `dupe` して `errdefer` でガード → `put`」というパターンが2か所に重複している。

**修正案**：共通ヘルパーに切り出す。

```zig
fn putEntry(self: *FlagSet, allocator: std.mem.Allocator, key: []const u8, val: FlagValue) ParseError!void {
    const k = try allocator.dupe(u8, key);
    errdefer allocator.free(k);
    try self.values.put(allocator, k, val);
}
```

---

#### 4. デフォルト値挿入で2回ハッシュ計算している

**ファイル**：`src/flag_set.zig:137-153`  
**品質特性**：性能効率性（時間効率性）

**問題**：`values.contains(def.long)` + `values.put(allocator, key, val)` と2回ルックアップしている。

**修正案**：`getOrPut` で1回のルックアップに統合する（CLIスケールでは実害なし、コードの明瞭さ向上）。

```zig
const gop = try self.values.getOrPut(allocator, def.long);
if (!gop.found_existing) {
    // キーとデフォルト値を挿入
    ...
}
```

---

### 優先度：低

#### 5. `TestEnv` が公開 API として re-export されている

**ファイル**：`src/root.zig:6`  
**品質特性**：使用性（識別容易性）

**問題**：テスト専用ヘルパー `TestEnv` がライブラリ公開 API に含まれており、利用者が誤って本番コードで使う可能性がある。

**採用：修正案 B — `testing` 名前空間に移動する**

手順：

1. `src/root.zig` の `TestEnv` re-export を `testing` 名前空間に移動する

```zig
// 変更前
pub const TestEnv = @import("env.zig").TestEnv;

// 変更後
pub const testing = struct {
    pub const TestEnv = @import("env.zig").TestEnv;
};
```

2. 既存の利用箇所（`example/` 配下など）があれば `zcli.TestEnv` → `zcli.testing.TestEnv` に更新する

---

## 対応優先度まとめ

| # | ファイル | 優先度 | 内容 |
|---|---------|--------|------|
| 1 | `src/flag_set.zig:209,232` | 高 | `--bool=false` バグ修正 + テスト追加 |
| 2 | `src/flag_set.zig:81-155` | 中 | `parse()` を3関数に分割 |
| 3 | `src/flag_set.zig:221-250` | 中 | `store`/`storeBool` の重複パターン統合 |
| 4 | `src/flag_set.zig:137-153` | 中 | `getOrPut` による2重ハッシュ解消 |
| 5 | `src/root.zig:6` | 低 | `TestEnv` の公開方針を明示 |

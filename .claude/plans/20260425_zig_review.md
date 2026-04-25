# Zig コードレビュー結果

**日付**：2026-04-25
**バージョン**：Zig 0.16.0
**レビュー対象**：12 ファイル（`zig-pkg/` は外部ライブラリのため除外）

---

## 指摘事項

### 問題 1：`FlagSet.store()` insert パスでの OOM 時メモリリーク

**ファイル**：`src/flag_set.zig` 行 218-221

**問題**：
`.string` 型のフラグを insert パス（キーなし）で処理する際、`dupe(raw)` 成功後に `dupe(key)` または `values.put` が OOM すると、先に確保した string がリークする。

ラベル付きブロック式（`blk: { ... break :blk; }`）内の `errdefer` はブロックが正常終了した後の外側のエラーには反応しないため、`errdefer` の登録スコープに注意が必要。

**修正案**：

```zig
} else {
    const k = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(k);

    // string 値の dupe をブロック外に出し、errdefer で管理
    var duped_string: ?[]u8 = null;
    errdefer if (duped_string) |s| self.allocator.free(s);

    const val: FlagValue = switch (def.flagType) {
        .string => v: {
            const s = try self.allocator.dupe(u8, raw);
            duped_string = s;      // errdefer に渡す
            break :v .{ .string = s };
        },
        .bool => .{ .bool = true },
        .int => blk: {
            const n = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidIntValue;
            break :blk .{ .int = n };
        },
    };
    try self.values.put(self.allocator, k, val);
    duped_string = null;           // put 成功 → map が所有権を持つ
}
```

---

### 問題 2：`FlagSet.parse()` デフォルト挿入ループでの OOM 時メモリリーク

**ファイル**：`src/flag_set.zig` 行 138-151

**問題**：
デフォルト値挿入ループで `dupe(def.long)` 成功後に `dupe(s.default)` や `values.put` が OOM すると、確保済みの `key`・duped string がリークする。

**修正案**：

```zig
for (self.defs) |def| {
    if (!self.values.contains(def.long)) {
        const key = try self.allocator.dupe(u8, def.long);
        errdefer self.allocator.free(key);  // ← 追加

        var duped_string: ?[]u8 = null;
        errdefer if (duped_string) |s| self.allocator.free(s);  // ← 追加

        const val: FlagValue = switch (def.flagType) {
            .string => |s| blk: {
                const duped = try self.allocator.dupe(u8, s.default);
                duped_string = duped;  // errdefer に渡す
                break :blk .{ .string = duped };
            },
            .bool => |b| .{ .bool = b.default },
            .int => |n| .{ .int = n.default },
        };
        try self.values.put(self.allocator, key, val);
        duped_string = null;  // put 成功 → map が所有権を持つ
    }
}
```

---

### 問題 3：`FlagSet.storeBool()` insert パスでの OOM 時メモリリーク

**ファイル**：`src/flag_set.zig` 行 227-230

**問題**：
`dupe(key)` 成功後に `values.put` が OOM すると `k` がリークする。3 件の中で最も修正が簡単。

**修正案**：

```zig
fn storeBool(self: *FlagSet, key: []const u8, val: bool) ParseError!void {
    if (self.values.getEntry(key)) |entry| {
        entry.value_ptr.* = .{ .bool = val };
    } else {
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);   // ← 追加
        try self.values.put(self.allocator, k, .{ .bool = val });
    }
}
```

---

## サマリ

- **3 件**の問題を **1 ファイル**（`src/flag_set.zig`）で検出
- 問題カテゴリ：**メモリ管理**（OOM 発生時の errdefer 漏れによるリーク）
- 重篤度：**低** — CLI フレームワークの文脈では実害は小さい（後述）

共通パターン：`allocator.dupe()` で確保した値を `errdefer` なしに後続の `try` の前に置いている。

---

## 重篤度の判断根拠（ディスカッション 2026-04-25）

### CLI フレームワークにおける OOM リークの位置づけ

- CLI プロセスは**短命**（コマンド実行 → 終了）なので、リークしたメモリは OS がプロセス終了時に即座に回収する
- フラグ解析中に OOM が起きるのは「システム全体がメモリ枯渇」という状態であり、コマンドが有意義な処理を続けられない
- ユーザーの対応は「再実行」で完結する

→ **修正優先度：低（対応任意）**

### `std.testing.allocator` で検出できるか

- **できない。** `std.testing.allocator` は OOM を注入しないため、当該コードパスが実行されずリークも発生しない
- 検出には `std.testing.FailingAllocator` で特定の確保タイミングに OOM を注入する必要がある

### 重要度が上がるケース

| 用途 | 理由 |
|------|------|
| 標準ライブラリ | あらゆる用途に組み込まれ、OOM 後の継続動作が求められることがある |
| 長時間実行サーバ | リーク量が時間とともに蓄積する |
| `zcli` がループ内で繰り返し呼ばれる場合 | 同上 |

---

## 実装計画（TDD アプローチ）

技術的興味から `std.testing.FailingAllocator` を使って問題を再現してから修正する。

### ステップ 1：FailingAllocator テストを追加して問題を再現する

`src/flag_set.zig` に以下の形式でテストを追加する。`FailingAllocator`（`std.heap.FailingAllocator`）の `fail_index` を変えることで各確保ポイントで OOM を注入し、`std.testing.allocator` がリークを検出することを確認する。

> **API 注記**：Zig 0.16 での正式名称は `std.heap.FailingAllocator`。`std.testing.FailingAllocator` として再エクスポートされているかは実行時に確認すること。

```zig
test "FlagSet storeBool no leak on OOM" {
    // fail_index を 0, 1, ... と増やして確保ポイントを網羅する。
    // 上限は実際の確保回数を超えていれば十分（parse が OOM なしで成功する
    // fail_index が現れた時点で網羅完了）。
    var fail_index: usize = 0;
    while (fail_index < 10) : (fail_index += 1) {
        var failing = std.heap.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var fs = FlagSet.init(failing.allocator(), &TEST_DEFS);
        defer fs.deinit();

        // OOM が返るか成功するかを問わずリークがないことを確認
        fs.parse(&.{ "-v" }) catch {};
    }
}

test "FlagSet store string no leak on OOM" {
    var fail_index: usize = 0;
    while (fail_index < 10) : (fail_index += 1) {
        var failing = std.heap.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var fs = FlagSet.init(failing.allocator(), &TEST_DEFS);
        defer fs.deinit();

        fs.parse(&.{ "--name", "Alice" }) catch {};
    }
}

test "FlagSet parse defaults no leak on OOM" {
    // デフォルト挿入ループは defs の数（3件）× 確保数（最大3回/件）で
    // 最大9〜12回の確保が発生しうるため上限を多めに設定する。
    var fail_index: usize = 0;
    while (fail_index < 20) : (fail_index += 1) {
        var failing = std.heap.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var fs = FlagSet.init(failing.allocator(), &TEST_DEFS);
        defer fs.deinit();

        fs.parse(&.{}) catch {};
    }
}
```

**期待結果（修正前）**：`mise test` でリーク検出エラーが出ることを確認する。

### ステップ 2：`errdefer` で修正する

各関数に `errdefer` を追加して問題を修正する。指摘事項の問題番号と対応する修正内容は以下の通り。

**修正対象**（指摘事項の問題番号順）：
1. **問題 1** `store()` insert パス — `duped_string` 変数を switch 外に出して `errdefer` で管理（修正案参照）
2. **問題 2** `parse()` デフォルト挿入ループ — 同様のパターンで修正（修正案参照）
3. **問題 3** `storeBool()` — `dupe(key)` 直後に `errdefer self.allocator.free(k)` を追加（修正案参照）

### ステップ 3：テストが通ることを確認する

**期待結果（修正後）**：`mise test` でリーク検出エラーが出ないことを確認する。

---

## 合格カテゴリ（問題なし）

| カテゴリ | 確認結果 |
|---------|---------|
| 命名規約（PascalCase / camelCase / SCREAMING_SNAKE_CASE） | 全ファイル準拠 |
| エラーハンドリング（`catch {}` 握り潰しなし） | 問題なし |
| `anyerror` の使用 | vtable（動的ディスパッチ）のみ。公開 API は推論エラー集合を使用 |
| Optional 処理（`.?` 強制 unwrap） | テスト内の論理的に非 null な箇所のみ |
| メモリ：`defer deinit` の対称性 | 全テストで正しく使用 |
| テスト：`std.testing.allocator` 使用 | 全テストで使用（リーク自動検出有効） |
| v0.15→v0.16 破壊的変更 | `std.Io.Writer`・`std.ArrayListUnmanaged`・`std.Io.File.stdout().writer(io, &buf)` 等、すべて 0.16 対応済み |
| `main` シグネチャ | `std.process.Init` フォームを正しく使用 |
| flush 管理 | `status.exit()` が `defer` をスキップすることを踏まえ、明示的に flush → exit の順序を守っている |

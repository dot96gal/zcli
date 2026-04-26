# Zig レビュー指摘事項と修正計画

**実施日**：2026-04-26  
**対象バージョン**：Zig 0.16.0  
**レビュー対象**：12 ファイル（src/ 7、example/ 4、build.zig 1）

---

## 指摘事項

### 1. 命名違反（`snake_case` → `camelCase`）

#### `src/flag_set.zig` — `duped_string`

| 行 | 現状 | 修正後 |
|----|------|--------|
| 142 | `var duped_string: ?[]u8 = null;` | `var dupedString: ?[]u8 = null;` |
| 226 | `var duped_string: ?[]u8 = null;` | `var dupedString: ?[]u8 = null;` |

関連する `errdefer if (duped_string) |s|` も `dupedString` に統一する。  
`duped_string = null;` の行も同様に修正。

#### `src/flag_set.zig` — `fail_index`（テストコード）

| 行 | 現状 | 修正後 |
|----|------|--------|
| 443 | `var fail_index: usize = 0;` | `var failIndex: usize = 0;` |
| 444 | `while (fail_index < 10) : (fail_index += 1)` | `while (failIndex < 10) : (failIndex += 1)` |
| 447 | `.{ .fail_index = fail_index }` | `.{ .fail_index = failIndex }` |
| 456 | `var fail_index: usize = 0;` | `var failIndex: usize = 0;` |
| 457 | `while (fail_index < 10) : (fail_index += 1)` | `while (failIndex < 10) : (failIndex += 1)` |
| 460 | `.{ .fail_index = fail_index }` | `.{ .fail_index = failIndex }` |
| 469 | `var fail_index: usize = 0;` | `var failIndex: usize = 0;` |
| 470 | `while (fail_index < 20) : (fail_index += 1)` | `while (failIndex < 20) : (failIndex += 1)` |
| 473 | `.{ .fail_index = fail_index }` | `.{ .fail_index = failIndex }` |

> `FailingAllocator` の初期化オプションのフィールド名 `.fail_index` は標準ライブラリ側の名前なので変更しない。

#### `example/basic/main.zig` / `example/signal/main.zig` — `raw_args`

| 行 | ファイル | 現状 | 修正後 |
|----|---------|------|--------|
| 8 | `example/basic/main.zig` | `const raw_args = ...` | `const rawArgs = ...` |
| 23 | `example/signal/main.zig` | `const raw_args = ...` | `const rawArgs = ...` |

> ホックスクリプト（`post_tool_use_zig_standard.sh`）の統合テスト中に発見。初回レビュー時の見落とし。

---

### 2. 公開 API のエラー集合（`anyerror` のまま）

#### 調査結果

`std.Io.Writer.Error` = `error{ WriteFailed }` — 具体的な単一エラー集合であることを確認済み（`anyerror` ではない）。

これにより、関数ごとに以下の対応が可能：

| ファイル | 関数 | 現状 | 修正可否 | 修正後の型 |
|---------|------|------|---------|-----------|
| `src/app.zig:32` | `App.register` | `!void` | ✅ 可能 | `error{OutOfMemory}!void` |
| `src/app.zig:37` | `App.run` | `!ExitStatus` | ❌ 不可 | vtable が `anyerror!ExitStatus` を返すため |
| `src/help.zig:9` | `printFlagHelp` | `!void` | ✅ 可能 | `std.Io.Writer.Error!void` |
| `src/help.zig:23` | `printCommandList` | `!void` | ✅ 可能 | `std.Io.Writer.Error!void` |

`App.run` は vtable 経由で `cmd.run()` を呼び出し、vtable の関数型が `anyerror!ExitStatus` のため、明示化は不可。

#### 修正方針

```zig
// src/help.zig
pub fn printFlagHelp(w: *std.Io.Writer, comptime defs: []const FlagDef) std.Io.Writer.Error!void { ... }
pub fn printCommandList(w: *std.Io.Writer, commands: []const Command) std.Io.Writer.Error!void { ... }

// src/app.zig
pub fn register(self: *App, cmd: Command) error{OutOfMemory}!void { ... }
// run は anyerror のまま維持（vtable 制約）
```

---

## 修正優先順位

| 優先度 | 項目 | 作業量 |
|--------|------|--------|
| 高 | `duped_string` → `dupedString`（2箇所） | 小 |
| 高 | `fail_index` → `failIndex`（テスト 3関数） | 小 |
| 高 | `raw_args` → `rawArgs`（example 2ファイル） | 小 |
| 中 | `printFlagHelp`・`printCommandList`：`std.Io.Writer.Error!void` に変更 | 小 |
| 中 | `App.register`：`error{OutOfMemory}!void` に変更 | 小 |
| 対応不要 | `App.run`：vtable 制約により `anyerror` のまま | — |

---

## 問題なし（確認済みカテゴリ）

- メモリ管理：`defer` によるクリーンアップ、`errdefer` の活用、`std.testing.allocator` 使用
- Optional 扱い：`orelse` / `if (opt) |val|` の正しい使用
- バージョン別 NG パターン（v0.16）：削除・非推奨 API の使用なし
- vtable の `anyerror`：動的ディスパッチのため許容
- テストカバレッジ：各公開関数に対応するテストあり

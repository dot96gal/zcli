# リファクタリング前テスト補完計画

## 目的

リファクタリング時に動作仕様の変化をテストで検出できるようにする。
既存テストが「動く」ことを確認しているのに対し、本計画は**「今の出力・挙動が変わっていないこと」を精密に固定**することを目的とする。

## 現状のテスト数（2026-04-06時点）

| モジュール | テスト数 |
|---|---|
| `exit_status.zig` | 1 |
| `env.zig` | 2 |
| `flag_set.zig` | 19 |
| `command.zig` | 4 |
| `help.zig` | 3 |
| `commander.zig` | 9 |
| **合計** | **38** |

## 残存するテストギャップの分析

### 問題1: 出力フォーマットが `indexOf` でしか検証されていない

`help.zig` と `commander.zig` のテストは `std.mem.indexOf(u8, out, "...")` で部分一致を確認するのみ。
リファクタリングでインデントや改行が変わっても検出できない。

### 問題2: フラグのゲッター型不一致時の挙動が未テスト

`getString` に bool フラグ名を渡すと `null` が返る仕様は未テスト。
リファクタリングでゲッター実装を変えた際にサイレントに壊れる可能性がある。

### 問題3: `short = null` のフラグの help 出力が未テスト

`printFlagHelp` は `short` が `null` のとき `, -X` を出力しない分岐があるが、この出力を精密に確認するテストがない（`test_defs` に `short = null` のフラグがあるが `--verbose` の出力確認が部分一致のみ）。

### 問題4: サブコマンドへの引数パススルーが未テスト

`Commander.run` はサブコマンド名の後ろの引数を `cmd.run(argv[1..], ...)` で渡す仕様だが、
「渡った引数が正しいこと」を検証するテストがない。

### 問題5: `--name=` (空インライン値) が未テスト

`--name=Alice` は tested だが `--name=` (値が空文字列) は未テスト。
パーサーの inline `=` 処理を変えた場合に見落とす可能性がある。

### 問題6: `printFlagHelp` を空フラグ定義で呼んだ場合が未テスト

`defs = &.{}` で何も出力しないことを確認するテストがない。

---

## 追加するテストケース

### 1. `help.zig` — 出力フォーマットの精密固定（優先度: 高）

**方針:** `indexOf` による部分一致を排除し `expectEqualStrings` で完全一致を検証する新テストを追加する。

| テスト名 | 検証内容 |
|---|---|
| `printFlagHelp exact format with short option` | `--name, -n\n        Name to greet (default: World)\n` の完全一致 |
| `printFlagHelp exact format without short option` | `--verbose\n        Verbose (default: false)\n` の完全一致（`, -X` が出ないこと） |
| `printFlagHelp with no flags outputs nothing` | 空 `defs` で空文字列が出力されること |
| `printCommandList exact format` | `  greet\n        say hello\n` の完全一致 |

---

### 2. `flag_set.zig` — ゲッターの型安全性（優先度: 高）

**方針:** 型不一致時に `null` が返ることを仕様として固定する。

| テスト名 | 検証内容 |
|---|---|
| `FlagSet getString returns null for bool flag` | `getString("verbose")` が `null` を返すこと |
| `FlagSet getBool returns null for string flag` | `getBool("name")` が `null` を返すこと |
| `FlagSet getInt returns null for string flag` | `getInt("name")` が `null` を返すこと |
| `FlagSet getString returns null for unknown name` | 存在しないフラグ名へのアクセスが `null` を返すこと |

---

### 3. `flag_set.zig` — `--key=` 空インライン値（優先度: 中）

| テスト名 | 検証内容 |
|---|---|
| `FlagSet inline empty value --name=` | `--name=` で空文字列がセットされること（`getString("name")` が `""` を返す） |

---

### 4. `commander.zig` — 引数パススルーと出力フォーマット（優先度: 中）

| テスト名 | 検証内容 |
|---|---|
| `Commander passes args to subcommand` | サブコマンド名の後ろの引数がそのまま `cmd.run` に渡ること |
| `Commander top-level help exact format` | トップレベル help の出力が `{program}: {description}\n\nCommands:\n...` と完全一致すること |
| `Commander unknown command writes to stderr` | 不明コマンド時に stderr に `unknown command: xxx\n` が書かれること（既存テストは `indexOf` のみ→精密化） |

---

## 実装方針

- 全テストは各モジュールの既存テストの末尾に追記する
- 既存の `MockGreetCmd`/`MockSuccessCmd`/`test_defs` を再利用する
- 引数パススルー検証のため、`commander.zig` に受け取った引数を記録する `MockArgCapture` 構造体を新設する
- 既存の部分一致テストは**削除しない**（追加のみ）。完全一致テストを別名で追加し並存させる

## 実装順序

1. `help.zig` — フォーマット精密固定（依存なし、最も安全）
2. `flag_set.zig` — ゲッター型安全性・空インライン値
3. `commander.zig` — 引数パススルー・フォーマット精密化

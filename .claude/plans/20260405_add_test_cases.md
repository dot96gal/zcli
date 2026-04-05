# テストケース追加計画

## 目的

今後の開発時に動作仕様への影響を検出できるよう、現在のテストカバレッジのギャップを埋める。

## 現状のテスト数

| モジュール | テスト数 | 評価 |
|---|---|---|
| `exit_status.zig` | 1 | 完全 |
| `env.zig` | 2 | 完全 |
| `command.zig` | 3 | 良好（エラーケース未テスト） |
| `flag_set.zig` | 13 | 優秀（一部エッジケース未テスト） |
| `commander.zig` | 6 | 良好（複数コマンド未テスト） |
| `help.zig` | 1 | 部分的（`printCommandList` 未テスト） |

---

## 追加するテストケース

### 1. `help.zig` — `printCommandList` （優先度: 高）

**理由:** `printCommandList` は公開関数かつ `Commander.printTopLevelHelp()` の核心部分だが、1件もテストがない。出力フォーマットが変わった場合に検出できない。

| テスト名 | 検証内容 |
|---|---|
| `printCommandList outputs name and synopsis` | コマンドの name と synopsis が正しく出力されること |
| `printCommandList with empty list outputs nothing` | コマンドなし時に何も出力しないこと |

---

### 2. `flag_set.zig` — エッジケース（優先度: 中〜高）

**理由:** フラグ解析はフレームワークの中核。仕様変更時に既存動作が壊れていないかを確認できるケースが不足している。

| テスト名 | 検証内容 | 補足 |
|---|---|---|
| `FlagSet negative int value` | `--count -5` で負の整数を正しくパースできること | `-5` が短縮フラグと混同されないかの確認 |
| `FlagSet mixed flags and positionals` | `--name Alice foo --verbose bar` のように混在しても正しく分離できること | flags と positionals の混在パターン |
| `FlagSet empty string value` | `--name ""` で空文字列を正しく保持できること | 空文字列のメモリ管理も間接的に検証 |
| `FlagSet unknown short flag error` | `-x`（未定義ショートフラグ）が `UnknownFlag` エラーを返すこと | 長フラグのエラーはテスト済みだが短フラグ版がない |
| `FlagSet short flag missing value error` | `-n` のみ（値なし）が `MissingValue` エラーを返すこと | 長フラグの `--name` 版はテスト済み |

---

### 3. `commander.zig` — エッジケース（優先度: 中〜高）

**理由:** 複数コマンド登録が実用上の主要ユースケースだが、全テストが1コマンドのみ。ディスパッチロジックの正確性が不十分。

| テスト名 | 検証内容 | 補足 |
|---|---|---|
| `Commander dispatches to correct command among multiple` | 複数コマンド登録時に正しいコマンドが呼ばれること | 現在全テストが1コマンドのみ |
| `Commander run with empty args slice` | `args = &.{}` (長さ0) で `usage_error` を返すこと | `args.len > 0` の分岐の境界ケース |
| `Commander propagates command failure status` | コマンドが `.failure` を返した場合、`Commander.run` もそれを返すこと | 成功ケースのみテスト済み |

---

### 4. `command.zig` — 非successステータス（優先度: 低〜中）

**理由:** vtable経由でコマンドが failure/usage_error を返すケースが未確認。

| テスト名 | 検証内容 |
|---|---|
| `Command.from run returns failure` | `run` が `.failure` を返すコマンドのステータスが正しく伝播すること |

---

## 実装方針

- テストは各モジュールの既存テストの末尾に追記する
- `help.zig` の `printCommandList` テストには `Command.from` を使って `MockCmd` インスタンスを作成する
- 各ファイルで既存の `MockCommand`/`MockCmd` 構造体を再利用または拡張する（新たな型はなるべく作らない）

## 実装順序

1. `help.zig` — `printCommandList` テスト（依存がシンプル）
2. `flag_set.zig` — エッジケース（既存の `test_defs` を再利用）
3. `commander.zig` — 複数コマンド・境界ケース
4. `command.zig` — 非successステータス

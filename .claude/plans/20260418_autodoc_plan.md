# autodoc による API ドキュメント生成計画

作成日: 2026-04-18

## 目的

Zig の組み込み autodoc 機能を使い、公開 API のリファレンスドキュメントを自動生成する。
`zig-out/docs/` に HTML を出力し、`mise run build-docs` で生成できるようにする。

## 作業内容

### 1. 各ソースファイルへの doc コメント追加

Zig の autodoc は `///` 形式の doc コメントを読み取る。
以下の全公開 API に doc コメントを追加する。

#### `src/root.zig`
- モジュール全体の概要コメント
- 各 re-export に対するコメント（`Command`, `FlagSet`, `FlagDef`, `Commander`, `Env`, `TestEnv`, `ExitStatus`, `ParseError`, `help`）

#### `src/command.zig`
- `Command` 構造体の説明
- `Command.VTable` — vtable の関数ポインタ定義（内部実装詳細だが `pub` のため autodoc に表示される）
- `Command.name()` — コマンド名を返す
- `Command.synopsis()` — 短い説明を返す
- `Command.usage()` — 使い方を Writer に出力する
- `Command.run()` — コマンドを実行して ExitStatus を返す
- `Command.from()` — 型 T から vtable 付き Command を生成する

#### `src/commander.zig`
- `Commander` 構造体の説明（サブコマンドルーター）
- `Commander.init()` — 初期化
- `Commander.deinit()` — 解放
- `Commander.register()` — コマンドを登録する
- `Commander.run()` — args を受け取りサブコマンドへディスパッチする

#### `src/flag_set.zig`
- `FlagType` union の各バリアント（`string`, `bool`, `int`）
- `FlagDef` 構造体の各フィールド（`long`, `short`, `flag_type`, `description`）
- `ParseError` の各バリアント（`UnknownFlag`, `MissingValue`, `InvalidIntValue`, `OutOfMemory`）
- `FlagSet` 構造体
  - `FlagSet.init()` — 定義を受け取り初期化
  - `FlagSet.deinit()` — 解放
  - `FlagSet.parse()` — argv を解析する
  - `FlagSet.positionals()` — 位置引数の一覧を返す
  - `FlagSet.getString()` — 文字列フラグの値を取得
  - `FlagSet.getInt()` — 整数フラグの値を取得
  - `FlagSet.getBool()` — 真偽フラグの値を取得

#### `src/env.zig`
- `Env` 構造体の説明（DI コンテナ）
- `Env` の各フィールド（`allocator`, `stdout`, `stderr`）
- `TestEnv` 構造体（テスト用ヘルパー）
  - `TestEnv.init()` — 初期化
  - `TestEnv.env()` — `Env` を返す
  - `TestEnv.deinit()` — 解放

#### `src/exit_status.zig`
- `ExitStatus` enum の各バリアント（`success`, `failure`, `usage_error`）と終了コード値
- `ExitStatus.toCode()` — u8 値を返す
- `ExitStatus.exit()` — プロセスを終了する（`std.process.exit()` を呼ぶ）

#### `src/help.zig`
- `printFlagHelp()` — フラグ一覧を整形出力する
- `printCommandList()` — コマンド一覧を整形出力する

---

### 2. `build.zig` への docs ステップ追加

`zig build docs` で HTML ドキュメントを `zig-out/docs/` に出力するステップを追加する。

```zig
// docs ステップ
const lib = b.addLibrary(.{
    .name = "zcli",
    .root_module = zcli_mod,
    .linkage = .static,
});
const install_docs = b.addInstallDirectory(.{
    .source_dir = lib.getEmittedDocs(),
    .install_dir = .prefix,
    .install_subdir = "docs",
});
const docs_step = b.step("docs", "Build API documentation");
docs_step.dependOn(&install_docs.step);
```

> **注意:** Zig 0.16 で `b.addLibrary` の API が変更されている可能性がある。
> `build.zig` 実装時に `zig build docs` を実行して確認し、エラーがあれば修正する。

---

### 3. `mise.toml` へのタスク追加

```toml
[tasks.build-docs]
description = "build API documentation"
run = "zig build docs --summary all"

[tasks.serve-docs]
description = "serve API documentation"
depends = ["build-docs"]
run = "npx --yes serve zig-out/docs"
```

使用方法:
- `mise run build-docs` — ドキュメントを生成する
- `mise run serve-docs` — ドキュメントをローカルサーバーで配信する（Ctrl+C で停止）

---

### 4. `README.md` の更新

開発者向けセクションの「開発タスク」に `build-docs` / `serve-docs` を追記する。

```sh
mise run build-docs  # zig build docs --summary all（API ドキュメントを生成）
mise run serve-docs  # ドキュメントをローカルサーバーで配信しブラウザで開く
```

---

### 5. 動作確認

1. `mise run build-docs` でエラーなく完了すること
2. `zig-out/docs/index.html` が生成されること
3. `mise run serve-docs` でブラウザが開き、全公開 API が表示されること

---

## 対象ファイル一覧

| ファイル | 変更内容 |
|---|---|
| `src/root.zig` | doc コメント追加 |
| `src/command.zig` | doc コメント追加 |
| `src/commander.zig` | doc コメント追加 |
| `src/flag_set.zig` | doc コメント追加 |
| `src/env.zig` | doc コメント追加 |
| `src/exit_status.zig` | doc コメント追加 |
| `src/help.zig` | doc コメント追加 |
| `build.zig` | docs ステップ追加 |
| `mise.toml` | `build-docs`, `serve-docs` タスク追加 |
| `README.md` | 開発タスクに `build-docs`, `serve-docs` を追記 |

## 非対象

- `example/` 配下（公開 API ではない）
- テスト専用の内部実装

## 作業順序

1. `build.zig` と `mise.toml` の変更（docs ステップ動作確認）
2. `src/root.zig` への doc コメント追加
3. 各ソースファイルへの doc コメント追加（command → commander → flag_set → env → exit_status → help の順）
4. `README.md` の更新
5. 最終動作確認

# zcli

## プロジェクトの概要

- シンプルなCLIフレームワークを開発する

## 計画ファイル

- 計画ファイルは`.claude/plans/`ディレクトリに`YYYYMMDD_`の接頭辞を付与したファイル名で保存する

## ツール

- mise（zig のバージョンは `mise.toml` を参照）

## 開発

mise タスクでコマンドを実行する。

- `mise run build`: ビルド（`zig build --summary all`）
- `mise run test`: テスト（`zig build test --summary all`）
- `mise run example`: 実行（`zig build run --summary all -- $@`、引数付き例: `mise run example -- greet --name Alice`）
- `mise run fmt`: フォーマット（`zig fmt src/`）
- `mise run fmt-check`: フォーマットチェック（`zig fmt --check src/`）

## 依存関係

- 外部ライブラリは使用しない。Zig 標準ライブラリ（`std`）のみを使用する

## コーディング規約

~/.claude/rules/zig.md を参照すること。



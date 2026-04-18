# GitHub Pages でAPIドキュメントを公開する

## 目的

`mise run build-docs`（`zig build docs`）で生成される `zig-out/docs/` を GitHub Pages で公開する。

## 方針

GitHub Actions ワークフロー `.github/workflows/deploy-docs.yml` を新規追加する。

- トリガー：`main` ブランチへの push
- ステップ：
  1. `actions/checkout@v6` でチェックアウト
  2. `jdx/mise-action@v4` で mise をセットアップ
  3. `mise run build-docs` でドキュメントをビルド（出力先：`zig-out/docs/`）
  4. `actions/upload-pages-artifact` で成果物をアップロード
  5. `actions/deploy-pages` で GitHub Pages にデプロイ

## リポジトリ設定（手動）

GitHub リポジトリの Settings → Pages → Build and deployment → Source を **「GitHub Actions」** に変更する。

## README.md への追記

`README.md` にAPIドキュメントへのリンクを追加する。

- リンク先：`https://dot96gal.github.io/zcli/`
- 追加箇所：README 冒頭付近（バッジ行またはプロジェクト説明の直後）

## ステータス

- [x] `.github/workflows/deploy-docs.yml` を作成する
- [x] `README.md` にAPIドキュメントへのリンクを追加する
- [x] GitHub リポジトリの Pages 設定を変更する（手動）

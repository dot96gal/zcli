# Zig テストカバレッジ計測の実装計画

作成日: 2026-04-05

## 概要

Zig にはネイティブの `--coverage` フラグが存在しない（[Issue #352](https://github.com/ziglang/zig/issues/352)、2016年から未解決）。
外部ツールを使ってカバレッジを計測する必要がある。

## 調査結果

### 利用可能なアプローチ

| ツール | 方法 | 対応OS | 速度 | 難易度 |
|---|---|---|---|---|
| **kcov** | DWARF + ptrace/dtrace | Linux/macOS | 速い | 低 |
| **grindcov (Valgrind)** | Callgrind | Linux/macOS | 遅い（20〜30倍） | 中 |
| LLVM-cov | コンパイラ内部フラグ | - | - | 不可（未公開） |

**推奨: kcov**（最も広く使われており、HTML レポート生成・Codecov 連携が可能）

## 実装方針

### 前提条件

- Zig バージョン: 0.15.2（新しい build API を使用）
- `setExecCmd` は Zig 0.12 以降で削除済み → `addSystemCommand` を使用

### アプローチ: build.zig に coverage オプションを追加

#### 1. kcov のインストール

```bash
# macOS
brew install kcov

# Ubuntu/Debian
sudo apt-get install -y kcov
```

#### 2. build.zig の修正

`build.zig` に `-Dcoverage` オプションを追加し、有効時は kcov 経由でテストを実行する。

```zig
const coverage = b.option(bool, "coverage", "Generate test coverage report") orelse false;

const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

const test_step = b.step("test", "Run unit tests");

if (coverage) {
    const test_bin = b.addInstallArtifact(tests, .{});

    const kcov_cmd = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-pattern=src/",
        "kcov-output",
    });
    kcov_cmd.addArtifactArg(tests);
    kcov_cmd.step.dependOn(&test_bin.step);
    test_step.dependOn(&kcov_cmd.step);
} else {
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```

#### 3. mise タスクの追加

`mise.toml` に coverage タスクを追加する。

```toml
[tasks.coverage]
description = "run tests with coverage"
run = "zig build test -Dcoverage --summary all"
```

#### 4. 実行方法

```bash
# カバレッジ計測付きテスト実行
mise run coverage

# レポートを開く（macOS）
open kcov-output/index.html
```

### 代替アプローチ: 手動二段階方式

`build.zig` を変更せずに計測する方法（シンプルだが build.zig との統合なし）。

```bash
# Step 1: テストバイナリをビルド（実行しない）
zig test src/root.zig --test-no-exec -femit-bin=zig-out/bin/test-runner

# Step 2: kcov でテストバイナリを実行
kcov --clean --include-pattern=src/ kcov-output zig-out/bin/test-runner

# レポートを確認
open kcov-output/index.html
```

## 制限事項

- **macOS**: kcov は dtrace を使用するため、Linux に比べて機能が限定的な場合がある
- **Docker**: kcov は ptrace アクセスが必要なため、`--security-opt seccomp=unconfined` が必要
- **未使用関数**: 実際にコンパイル・実行されたコードのみカバレッジに含まれる
- **二重実行**: kcov 方式は通常のテスト実行と別に実行が必要

## 実装ステップ

1. [x] kcov をインストール（`brew install kcov`）
2. [x] `build.zig` に `-Dcoverage` オプションを追加
3. [x] `mise.toml` に `coverage` タスクを追加
4. [x] `mise run coverage` で動作確認
5. [x] `kcov-output/` を `.gitignore` に追加
6. [ ] （オプション）GitHub Actions に coverage 計測ステップを追加

## 振り返り（2026-04-06）

### 試したこと

#### macOS（kcov v43）

`build.zig` に `-Dcoverage` オプションを実装し、kcov 経由でテストを実行した。

**結果**: カバレッジ 0%。原因は macOS の SIP（System Integrity Protection）が有効なため、kcov が使用する dtrace に必要な権限がない。`sudo kcov` でも解決しなかった。

#### Docker（Ubuntu 22.04 + kcov v38）

macOS では計測できないため、Docker で Linux 環境を用意して試みた。

試行の過程で以下の問題を順に解決した：

1. Ubuntu 24.04 に kcov パッケージがない → Ubuntu 22.04 に変更
2. zig ダウンロード URL が無効 → コンテナ内で mise 経由でインストールに変更
3. mise の config trust エラー → `mise trust /work/mise.toml` を追加
4. kcov の ptrace 権限エラー（`Can't set personality`）→ `--cap-add=SYS_PTRACE --security-opt seccomp=unconfined` を追加

kcov 自体は起動・実行できるようになったが、結果は依然としてカバレッジ 0%。

**根本原因の調査**:

`readelf --debug-dump=line` でテストバイナリの `.debug_line` セクションを解析したところ、**ユーザーコード（`src/root.zig`）の行情報が一切含まれていない**ことが判明。

```
# .debug_line の File Name Table に root.zig が存在しない
# 含まれるのは std ライブラリと compiler_rt のファイルのみ
```

コンパイル単位（Compilation Unit）の `DW_AT_comp_dir` は `/work/src` を指しているが、対応する `.debug_line` エントリが存在しない。kcov はこの情報を元にブレークポイントを設定するため、ユーザーコードの行を計測できない。

#### Valgrind/Callgrind（Docker内）

kcov と異なりバイナリを動的変換してトレースするため、`.debug_line` 非依存で動作することを期待して試みた。

**結果**: `callgrind_annotate` の出力に `/work/src/root.zig` の関数・行が一切現れなかった。DWARF の `.debug_info` にもユーザーコードの関数帰属情報が不十分なため、Callgrind でも計測不可。

### 結論

**Zig 0.15.2 では `zig test` でビルドされたバイナリにユーザーコードの DWARF デバッグ情報が出力されない**。これは Zig コンパイラ側の仕様であり、kcov・Valgrind を問わず外部ツールによるカバレッジ計測は現時点で不可能。

| ツール | 結果 | 理由 |
|---|---|---|
| kcov（macOS） | 0% | SIP により dtrace 権限なし |
| kcov（Docker/Linux） | 0% | `.debug_line` にユーザーコードなし |
| Valgrind/Callgrind（Docker/Linux） | 計測不可 | DWARF にユーザー関数の帰属なし |

根本解決は [Zig Issue #352](https://github.com/ziglang/zig/issues/352) の対応を待つ必要がある。

## 参考資料

- [Zig Issue #352 - support code coverage when testing](https://github.com/ziglang/zig/issues/352)
- [Code Coverage for Zig with Callgrind](https://www.ryanliptak.com/blog/code-coverage-zig-callgrind/)
- [Using kcov with zig test - Ziggit](https://ziggit.dev/t/using-kcov-with-zig-test/3421)
- [allyourcodebase/kcov](https://github.com/allyourcodebase/kcov)

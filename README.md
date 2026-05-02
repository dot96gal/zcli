# zcli

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zcli/)
[![CI](https://github.com/dot96gal/zcli/actions/workflows/ci.yml/badge.svg)](https://github.com/dot96gal/zcli/actions/workflows/ci.yml)
[![Release](https://github.com/dot96gal/zcli/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zcli/actions/workflows/release.yml)

Zig のシンプルな CLI フレームワーク。

> **注意:** このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でフォークし、独自に管理されることをおすすめします。

## 要件

- Zig 0.16.0 以上

## 利用者向け

### インストール

#### 1. `build.zig.zon` に zcli を追加する。

最新のタグは [GitHub Releases](https://github.com/dot96gal/zcli/releases) で確認できる。

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される。

```sh
zig fetch --save https://github.com/dot96gal/zcli/archive/refs/tags/<version>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .zcli = .{
        .url = "https://github.com/dot96gal/zcli/archive/refs/tags/<version>.tar.gz",
        .hash = "<hash>",
    },
},
```

#### 2. `build.zig` で zcli モジュールをインポートする。

```zig
const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
const zcli_mod = zcli_dep.module("zcli");

exe.root_module.addImport("zcli", zcli_mod);
```

キャンセルやタイムアウトを使う場合は、zctx も合わせてインポートする。zctx は zcli の依存として同梱されているため `zcli_dep.module("zctx")` で取得できる。

```zig
const zctx_mod = zcli_dep.module("zctx");
exe.root_module.addImport("zctx", zctx_mod);
```

#### 3. コマンドを定義する

```zig
const std = @import("std");
const zcli = @import("zcli");

const GREET_FLAGS = [_]zcli.FlagDef{
    .{
        .long = "name",
        .short = 'n',
        .flagType = .{ .string = .{ .default = "World" } },
        .description = "挨拶する相手の名前",
    },
    .{
        .long = "excited",
        .short = 'e',
        .flagType = .{ .bool = .{ .default = false } },
        .description = "感嘆符を使う",
    },
};

pub const GreetCommand = struct {
    pub fn name() []const u8 { return "greet"; }
    pub fn synopsis() []const u8 { return "挨拶メッセージを表示する"; }

    pub fn usage(_: *GreetCommand, w: *std.Io.Writer) !void {
        try w.print("usage: <program> greet [flags]\n\nFlags:\n", .{});
        try zcli.help.printFlagHelp(w, &GREET_FLAGS);
    }

    pub fn run(_: *GreetCommand, args: []const []const u8, env: *zcli.Env) !zcli.ExitStatus {
        var fs = zcli.FlagSet.init(&GREET_FLAGS);
        defer fs.deinit(env.allocator);

        fs.parse(env.allocator, args) catch |err| {
            try env.stderr.print("flag error: {s}\n", .{@errorName(err)});
            return .usageError;
        };

        const target = fs.getString("name") orelse "World";
        const punct: u8 = if (fs.getBool("excited") orelse false) '!' else '.';
        try env.stdout.print("Hello, {s}{c}\n", .{ target, punct });
        return .success;
    }
};
```

#### 4. `main` に組み込む

```zig
const std = @import("std");
const zcli = @import("zcli");
const GreetCommand = @import("greet_command.zig").GreetCommand;

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;
    const rawArgs = try env.minimal.args.toSlice(env.arena.allocator());
    const args: []const []const u8 = @ptrCast(rawArgs);

    // App より先にバッファ付き writer を宣言してライフタイムを包む。
    var stdoutBuf: [4096]u8 = undefined;
    var stderrBuf: [512]u8 = undefined;
    var stdoutWriter = std.Io.File.stdout().writer(io, &stdoutBuf);
    var stderrWriter = std.Io.File.stderr().writer(io, &stderrBuf);

    var app = zcli.App.init(
        zcli.Env{
            .allocator = allocator,
            .io = io,
            .stdout = &stdoutWriter.interface,
            .stderr = &stderrWriter.interface,
            .ctx = zcli.BACKGROUND,
        },
        "mytool",
        "デモ用 CLI ツール",
    );
    defer app.deinit();

    var greet = GreetCommand{};
    try app.register(zcli.Command.from(GreetCommand, &greet));

    const status = app.run(args) catch |err| blk: {
        try stderrWriter.interface.print("error: {s}\n", .{@errorName(err)});
        break :blk zcli.ExitStatus.failure;
    };

    // std.process.exit は defer をスキップするため、exit 前に明示的にフラッシュする。
    stdoutWriter.interface.flush() catch |err| std.debug.print("stdout flush error: {s}\n", .{@errorName(err)});
    stderrWriter.interface.flush() catch |err| std.debug.print("stderr flush error: {s}\n", .{@errorName(err)});
    status.exit();
}
```

### 使い方

zcli は CLI アプリケーションを構築するための以下のコンポーネントを提供します。

| 型・定数 | 説明 |
|---------|------|
| `App` | コマンドのルーティングと `help` の処理 |
| `Command` | コマンドの vtable ベースインターフェース |
| `FlagSet` | フラグパーサー（`--long`、`-s`、`--key=val`、`--` に対応） |
| `FlagDef` | フラグ定義（名前、短縮名、型、デフォルト値、説明） |
| `Env` | 依存性注入コンテナ（allocator、io、stdout、stderr、ctx） |
| `BACKGROUND` | キャンセルなしのデフォルトコンテキスト（`Env.ctx` に渡す） |
| `ExitStatus` | 終了コード列挙型（`.success`、`.failure`、`.usageError`） |

### 組み込みコマンド

`App` は `help` コマンドを自動で処理します。

```
mytool help              # トップレベルのコマンド一覧を表示
mytool help greet        # 'greet' の usage を表示
```

### API リファレンス

#### FlagSet API

| メソッド | 説明 |
|---------|------|
| `init(comptime defs)` | FlagSet を生成する |
| `parse(allocator, args)` | 引数スライスをパースする。失敗時は `ParseError` を返す |
| `getString(name)` | 文字列フラグの値を取得する |
| `getInt(name)` | 整数フラグの値を取得する |
| `getBool(name)` | 真偽値フラグの値を取得する |
| `positionals()` | フラグ以外の位置引数を取得する |
| `deinit(allocator)` | 所有するメモリをすべて解放する |

対応するフラグ構文:

```
--name Alice      # 値付き long フラグ
--name=Alice      # インライン値付き long フラグ
-n Alice          # 値付き short フラグ
--verbose         # bool プレゼンスフラグ
--verbose=true    # bool フラグをインライン値で指定（true/false/1/0）
-v                # short bool フラグ
--                # フラグ終端。以降の引数は位置引数になる
```

#### ExitStatus

```zig
.success    // 終了コード 0
.failure    // 終了コード 1
.usageError // 終了コード 2
```

#### コマンドのテストを書く

`zcli.Testing.TestEnv` を使うと、stdout/stderr の出力をユニットテストでキャプチャできます。

```zig
const testing = std.testing;
const zcli = @import("zcli");

test "greet が hello を出力する" {
    var te = zcli.Testing.TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmd = GreetCommand{};
    const status = try cmd.run(&.{"--name", "Alice"}, @constCast(&e));
    try testing.expectEqual(zcli.ExitStatus.success, status);
    try testing.expectEqualStrings("Hello, Alice.\n", te.outWriter.writer.buffered());
}
```

---

## 開発者向け

### 必要なツール

| ツール | 説明 |
|-------|------|
| [mise](https://mise.jdx.dev/) | ツールバージョン管理（Zig・zls を自動インストール） |
| `zig-lint` | Zig 簡易リントスクリプト（`~/.local/bin/` にインストール済み） |
| `zig-release` | バージョン更新・タグ付けスクリプト（`~/.local/bin/` にインストール済み） |

### セットアップ

```sh
git clone https://github.com/dot96gal/zcli
cd zcli
mise install
```

### タスク一覧

| コマンド | 説明 |
|---------|------|
| `mise run fmt` | フォーマット |
| `mise run fmt-check` | フォーマットチェック |
| `mise run lint` | 命名規則チェック（camelCase / PascalCase / SCREAMING_SNAKE_CASE） |
| `mise run build` | ビルド |
| `mise run test` | テスト |
| `mise run example-basic` | キャンセルなしの example を実行（引数は -- 以降に渡す） |
| `mise run example-signal` | OS シグナルキャンセルの example を実行（引数は -- 以降に渡す） |
| `mise run build-docs` | API ドキュメントを生成 |
| `mise run serve-docs` | ドキュメントをローカルサーバーで配信（Ctrl+C で停止） |
| `mise run check-updates` | `build.zig.zon` の依存ライブラリの更新を確認 |
| `mise run release X.Y.Z` | バージョン更新・コミット・タグ・プッシュを一括実行（例: 1.0.0） |

`example-basic` タスクの呼び出し例:

```sh
mise run example-basic
mise run example-basic -- greet --name Alice --count 3 --excited
mise run example-basic -- help greet
```

`example-signal` タスクの呼び出し例:

```sh
mise run example-signal -- greet --name Alice --count 10
```

### ファイル構成

```
zcli/
├── src/
│   ├── root.zig              # 公開 API の再エクスポート（唯一のインポート起点）
│   ├── app.zig               # App: コマンドルーティング
│   ├── command.zig           # Command vtable インターフェース + Command.from()
│   ├── flag_set.zig          # FlagSet: フラグパースエンジン
│   ├── env.zig               # Env、TestEnv
│   ├── exit_status.zig       # ExitStatus 列挙型
│   └── help.zig              # printFlagHelp、printCommandList
├── example/
│   ├── basic/
│   │   ├── main.zig          # サンプル CLI エントリポイント（キャンセルなし）
│   │   └── greet_command.zig # サンプルコマンド
│   └── signal/
│       ├── main.zig          # サンプル CLI エントリポイント（OS シグナルでキャンセル）
│       └── greet_command.zig # サンプルコマンド（キャンセル確認あり）
├── build.zig                 # ビルドスクリプト
├── build.zig.zon             # 依存パッケージ定義
├── mise.toml                 # ツールバージョンとタスク定義
└── .mise/tasks/
    └── check-updates         # 依存ライブラリの更新チェック
```

### 設計方針

- **依存は標準ライブラリと `zctx` のみ** — Zig 標準ライブラリと [zctx](https://github.com/dot96gal/zctx) のみを使用する。
- **`Env` による依存性注入** — allocator、io、stdout、stderr、ctx を明示的に渡すことで、プロセス I/O なしにコマンドをテスト可能にする。
- **コンパイル時 vtable** — `Command.from(T, ptr)` がコンパイル時に vtable を生成し、`comptime validateCommand` でインターフェースを検証する。宣言漏れはコンパイルエラーとして明示される。
- **アンマネージドコレクション** — `std.ArrayList` はアロケータを内部に持たない形式で使用し、アロケータは呼び出し元から明示的に渡す。
- **`*std.Io.Writer` はポインタ渡し** — `std.Io.Writer` は内部で `@fieldParentPtr` を使用するため値コピーが不可。`Env` は `*std.Io.Writer` を保持する。バッキング writer 構造体のライフタイムは参照する `Env` や `App` を包まなければならない。
- **exit 前の明示的フラッシュ** — `std.process.exit()` は defer をスキップするため、`ExitStatus.exit()` を呼ぶ前にバッファ付き writer を手動でフラッシュする必要がある。

### 新しいソースファイルを追加する

1. `src/<name>.zig` を作成する。
2. 同一ファイル内にテストを記述する（`test "..." { ... }`）。
3. 公開する型を `src/root.zig` から再エクスポートする。

### コーディング規約

[Zig スタイルガイド](https://ziglang.org/documentation/master/#Style-Guide) に従う。

- 型: `PascalCase`
- 変数・関数: `camelCase`
- 定数: `SCREAMING_SNAKE_CASE`
- エラーは `try` / `catch` で適切に伝播またはハンドリングする。握り潰し禁止。
- アロケータは呼び出し元から渡す。`defer` で確実に解放する。
- テストはテスト対象コードと同一ファイルに記述する。

---

## ライセンス

[MIT](LICENSE)

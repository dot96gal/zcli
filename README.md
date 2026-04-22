# zcli

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zcli/)
[![test](https://github.com/dot96gal/zcli/actions/workflows/test.yml/badge.svg)](https://github.com/dot96gal/zcli/actions/workflows/test.yml)
[![release](https://github.com/dot96gal/zcli/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zcli/actions/workflows/release.yml)

シンプルな Zig 製 CLI フレームワーク。

## 開発方針

このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、利用者や外部からの意見をもとに変更する義務は負いません。

また、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でこのリポジトリをフォークし、独自に管理されることをおすすめします。

## 動作要件

- Zig 0.16.x

## 利用者向け

### 概要

zcli は CLI アプリケーションを構築するための以下のコンポーネントを提供します。

| 型 | 説明 |
|----|------|
| `Commander` | サブコマンドのルーティングと `help` の処理 |
| `Command` | サブコマンドの vtable ベースインターフェース |
| `FlagSet` | フラグパーサー（`--long`、`-s`、`--key=val`、`--` に対応） |
| `FlagDef` | フラグ定義（名前、短縮名、型、デフォルト値、説明） |
| `Env` | 依存性注入コンテナ（allocator、stdout、stderr） |
| `ExitStatus` | 終了コード列挙型（`.success`、`.failure`、`.usage_error`） |

### クイックスタート

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
const zcli_dep = b.dependency("zcli", .{
    .target = target,
    .optimize = optimize,
});
const zcli_mod = zcli_dep.module("zcli");
exe.root_module.addImport("zcli", zcli_mod);
```

#### 3. コマンドを定義する

```zig
const std = @import("std");
const zcli = @import("zcli");

const greet_flags = [_]zcli.FlagDef{
    .{
        .long = "name",
        .short = 'n',
        .flag_type = .{ .string = .{ .default = "World" } },
        .description = "挨拶する相手の名前",
    },
    .{
        .long = "excited",
        .short = 'e',
        .flag_type = .{ .bool = .{ .default = false } },
        .description = "感嘆符を使う",
    },
};

pub const GreetCommand = struct {
    pub fn name() []const u8 { return "greet"; }
    pub fn synopsis() []const u8 { return "挨拶メッセージを表示する"; }

    pub fn usage(_: *GreetCommand, w: *std.Io.Writer) !void {
        try w.print("usage: <program> greet [flags]\n\nFlags:\n", .{});
        try zcli.help.printFlagHelp(w, &greet_flags);
    }

    pub fn run(_: *GreetCommand, args: []const []const u8, env: *zcli.Env) !zcli.ExitStatus {
        var fs = zcli.FlagSet.init(env.allocator, &greet_flags);
        defer fs.deinit();

        fs.parse(args) catch |err| {
            try env.stderr.print("flag error: {s}\n", .{@errorName(err)});
            return .usage_error;
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
    const allocator = env.gpa;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

    // Commander より先にバッファ付き writer を宣言してライフタイムを包む。
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(env.io, &stdout_buf);
    var stderr_w = std.Io.File.stderr().writer(env.io, &stderr_buf);

    var cmdr = zcli.Commander.init(
        zcli.Env{
            .allocator = allocator,
            .stdout = &stdout_w.interface,
            .stderr = &stderr_w.interface,
        },
        "mytool",
        "デモ用 CLI ツール",
    );
    defer cmdr.deinit();

    var greet = GreetCommand{};
    try cmdr.register(zcli.Command.from(GreetCommand, &greet));

    const status = cmdr.run(args) catch |err| blk: {
        try stderr_w.interface.print("error: {s}\n", .{@errorName(err)});
        break :blk zcli.ExitStatus.failure;
    };

    // std.process.exit は defer をスキップするため、exit 前に明示的にフラッシュする。
    stdout_w.interface.flush() catch |err| std.debug.print("stdout flush error: {s}\n", .{@errorName(err)});
    stderr_w.interface.flush() catch |err| std.debug.print("stderr flush error: {s}\n", .{@errorName(err)});
    status.exit();
}
```

### 組み込みコマンド

`Commander` は `help` サブコマンドを自動で処理します。

```
mytool help              # トップレベルのコマンド一覧を表示
mytool help greet        # 'greet' のusageを表示
```

### FlagSet API

| メソッド | 説明 |
|---------|------|
| `init(allocator, comptime defs)` | FlagSet を生成する |
| `parse(args)` | 引数スライスをパースする。失敗時は `ParseError` を返す |
| `getString(name)` | 文字列フラグの値を取得する |
| `getInt(name)` | 整数フラグの値を取得する |
| `getBool(name)` | 真偽値フラグの値を取得する |
| `positionals()` | フラグ以外の位置引数を取得する |
| `deinit()` | 所有するメモリをすべて解放する |

対応するフラグ構文:

```
--name Alice      # 値付き long フラグ
--name=Alice      # インライン値付き long フラグ
-n Alice          # 値付き short フラグ
--verbose         # bool プレゼンスフラグ
-v                # short bool フラグ
--                # フラグ終端。以降の引数は位置引数になる
```

### ExitStatus

```zig
.success      // 終了コード 0
.failure      // 終了コード 1
.usage_error  // 終了コード 2
```

### コマンドのテストを書く

`zcli.TestEnv` を使うと、stdout/stderr の出力をユニットテストでキャプチャできます。

```zig
const testing = std.testing;
const zcli = @import("zcli");

test "greet が hello を出力する" {
    var te = zcli.TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    var cmd = GreetCommand{};
    const status = try cmd.run(&.{"--name", "Alice"}, @constCast(&e));
    try testing.expectEqual(zcli.ExitStatus.success, status);
    try testing.expectEqualStrings("Hello, Alice.\n", te.out_w.writer.buffered());
}
```

---

## 開発者向け

### リポジトリ構成

```
zcli/
├── src/
│   ├── root.zig          # 公開 API の再エクスポート（唯一のインポート起点）
│   ├── commander.zig     # Commander: サブコマンドルーティング
│   ├── command.zig       # Command vtable インターフェース + Command.from()
│   ├── flag_set.zig      # FlagSet: フラグパースエンジン
│   ├── env.zig           # Env、TestEnv
│   ├── exit_status.zig   # ExitStatus 列挙型
│   └── help.zig          # printFlagHelp、printCommandList
├── example/
│   ├── main.zig          # サンプル CLI エントリポイント
│   └── greet_command.zig # サンプルサブコマンド
├── build.zig
└── mise.toml
```

### 開発タスク

```sh
mise run build          # zig build --summary all
mise run test           # zig build test --summary all
mise run example        # example を実行（引数は -- 以降に渡す）
mise run release X.Y.Z  # バージョン更新・コミット・タグ・プッシュを一括実行（例: 1.0.0）
mise run build-docs     # zig build docs --summary all（API ドキュメントを生成）
mise run serve-docs     # ドキュメントをローカルサーバーで配信する（Ctrl+C で停止）
```

`example` タスクの呼び出し例:

```sh
mise run example
mise run example -- greet --name Alice --count 3 --excited
mise run example -- help greet
```

### 設計方針

- **外部依存なし** — `std` のみを使用する。
- **`Env` による依存性注入** — stdout、stderr、allocator を明示的に渡すことで、プロセス I/O なしにコマンドをテスト可能にする。
- **コンパイル時 vtable** — `Command.from(T, ptr)` がコンパイル時に vtable を生成し、`comptime validateCommand` でインターフェースを検証する。宣言漏れはコンパイルエラーとして明示される。
- **アンマネージドコレクション** — `std.ArrayList` はアロケータを内部に持たない形式で使用し、アロケータは呼び出し元から明示的に渡す。
- **`*std.Io.Writer` はポインタ渡し** — `std.Io.Writer` は内部で `@fieldParentPtr` を使用するため値コピーが不可。`Env` は `*std.Io.Writer` を保持する。バッキング writer 構造体のライフタイムは参照する `Env` や `Commander` を包まなければならない。
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

## ライセンス

[MIT License](LICENSE)

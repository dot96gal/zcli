# Zig v0.15 → v0.16 移行計画

## 概要

`mise.toml` は既に `zig = "0.16.0"` に更新済み。コードの移行を行う。

## 対象ファイル

`example/main.zig` のみ変更が必要。他のファイル（`src/` 配下）は既に v0.16 対応済み。

## 修正内容

### `example/main.zig`

#### 1. `main` シグネチャの変更（行 5）

v0.16 の `main` は `std.process.Init` を第 1 引数として受け取る。
`std.process.Init` は `io`・`gpa`・`arena`・`minimal.args` などを提供する。

```zig
// Before
pub fn main() !void {

// After
pub fn main(env: std.process.Init) !void {
```

#### 2. アロケータ・args の取得方法変更（行 6–12）

`env.gpa` が allocator、`env.minimal.args.toSlice(env.arena.allocator())` で args を取得する。
`std.process.argsAlloc` / `argsFree` は v0.16 で削除済み。

```zig
// Before
var gpa = std.heap.DebugAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

const raw_args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, raw_args);
const args: []const []const u8 = raw_args;

// After
const allocator = env.gpa;
const raw_args = try env.minimal.args.toSlice(env.arena.allocator());
const args: []const []const u8 = @ptrCast(raw_args); // [:0]const u8 → []const u8
```

#### 3. `std.fs.File.stdout()` / `std.fs.File.stderr()` の置き換え（行 17–18）

`std.fs.File.stdout/stderr` は v0.16 で廃止。`std.Io.File.stdout/stderr` に移動し、
`writer()` の第 1 引数に `io` インスタンス（`env.io`）が必要。

```zig
// Before
var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
var stderr_w = std.fs.File.stderr().writer(&stderr_buf);

// After
var stdout_w = std.Io.File.stdout().writer(env.io, &stdout_buf);
var stderr_w = std.Io.File.stderr().writer(env.io, &stderr_buf);
```

#### 修正後の `main` 全体イメージ

```zig
pub fn main(env: std.process.Init) !void {
    const allocator = env.gpa;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

    // バッファ付き writer を生成。cmdr より先に宣言して寿命を包む。
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
        "A demonstration CLI tool",
    );
    defer cmdr.deinit();

    var greet = GreetCommand{};
    try cmdr.register(zcli.Command.from(GreetCommand, &greet));

    const status = cmdr.run(args) catch |err| blk: {
        try stderr_w.interface.print("error: {s}\n", .{@errorName(err)});
        break :blk zcli.ExitStatus.failure;
    };
    // std.process.exit はデファーをスキップするため exit() 前に明示的にフラッシュ
    stdout_w.interface.flush() catch |err| std.debug.print("stdout flush error: {s}\n", .{@errorName(err)});
    stderr_w.interface.flush() catch |err| std.debug.print("stderr flush error: {s}\n", .{@errorName(err)});
    status.exit();
}
```

## API 調査結果（Zig 0.16.0 標準ライブラリより）

- `std/start.zig`：`main` の第 1 引数が `std.process.Init` または `std.process.Init.Minimal` であることを確認
- `std/process.zig`：`std.process.Init` の定義。`io: Io`・`gpa: Allocator`・`arena: *ArenaAllocator`・`minimal.args: Args` を保持
- `std/process/Args.zig`：`Args.toSlice(arena)` で `[]const [:0]const u8` を取得可能
- `std/Io/File.zig`：`std.Io.File.stdout()` / `std.Io.File.stderr()` が v0.16 の正式 API
  - `File.writer()` シグネチャ：`pub fn writer(file: File, io: Io, buffer: []u8) Writer`

### `README.md`

#### 1. 動作要件のバージョン更新（行 7）

```markdown
<!-- Before -->
- Zig 0.15.x

<!-- After -->
- Zig 0.16.x
```

#### 2. クイックスタート「`main` に組み込む」のコード例更新（行 92–130）

`example/main.zig` の修正内容と同様に、`main` シグネチャ・allocator・args・stdout/stderr の取得方法をすべて更新する。

```zig
// Before
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);
    const args: []const []const u8 = raw_args;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
    ...
}

// After
pub fn main(env: std.process.Init) !void {
    const allocator = env.gpa;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(env.io, &stdout_buf);
    var stderr_w = std.Io.File.stderr().writer(env.io, &stderr_buf);
    ...
}
```

#### 3. 設計方針「アンマネージドコレクション」の記述更新（行 237）

"Zig 0.15 デフォルト" という記述を削除し、バージョン依存の表現を除く。

```markdown
<!-- Before -->
- **アンマネージドコレクション** — `std.ArrayList` はアロケータを内部に持たない形式（Zig 0.15 デフォルト）で使用し、アロケータは呼び出し元から明示的に渡す。

<!-- After -->
- **アンマネージドコレクション** — `std.ArrayList` はアロケータを内部に持たない形式で使用し、アロケータは呼び出し元から明示的に渡す。
```

## 変更サマリ

| 対象 | 変更種別 | 内容 |
|------|---------|------|
| `example/main.zig:5` | シグネチャ変更 | `main()` → `main(env: std.process.Init)` |
| `example/main.zig:6–12` | 置き換え | `DebugAllocator` + `argsAlloc` → `env.gpa` + `env.minimal.args.toSlice` |
| `example/main.zig:17–18` | API 置き換え | `std.fs.File.stdout/stderr` → `std.Io.File.stdout/stderr` + `env.io` 引数追加 |
| `README.md:7` | バージョン更新 | `Zig 0.15.x` → `Zig 0.16.x` |
| `README.md:92–130` | コード例更新 | `main` サンプルを v0.16 API に合わせて修正 |
| `README.md:237` | 記述修正 | "Zig 0.15 デフォルト" の記述を削除 |

---

## 振り返り

### 計画外の対応

`mise run test` を実行したところ、テストが 0 件しか実行されていないことが判明した。

**原因**：`src/root.zig` は各サブモジュールを `pub const X = @import("x.zig").X;` の形式でインポートしているが、Zig のテストランナーはこの形式では各ファイルのテストブロックを検出しない。

**対処**：`src/root.zig` に以下のテストブロックを追加し、51 件のテストが全て実行されることを確認した。

```zig
test {
    _ = @import("command.zig");
    _ = @import("commander.zig");
    _ = @import("env.zig");
    _ = @import("exit_status.zig");
    _ = @import("flag_set.zig");
    _ = @import("help.zig");
}
```

### 次回の計画への教訓

- `src/root.zig` に新しいソースファイルを追加する際は、`test { _ = @import(...); }` ブロックへの追記も忘れずに行う。
- 移行作業後は `mise run test` でテスト件数が 0 でないことを確認するステップを計画に含める。

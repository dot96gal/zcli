# zctx 統合計画：キャンセル伝搬のサポート追加

## 目的

zctx（https://github.com/dot96gal/zctx）を zcli に組み込み、`Env` を通じて各コマンドにキャンセル信号を届けられるようにする。
OS シグナル（SIGINT/SIGTERM など）との連携は利用者の責務とし、zcli はキャンセル信号の伝搬経路（`Env.ctx`）のみを提供する。

---

## 現状分析

### `Env` 構造体（`src/env.zig:6`）

```zig
pub const Env = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};
```

`stdout`/`stderr` はテスタビリティのために呼び出し元が生成した `*std.Io.Writer` を受け取る設計。
`io: std.Io` を保持していないため、zctx の API を直接呼べない。

### `Command.run` のシグネチャ（`src/command.zig:36`）

```zig
run: *const fn (ptr: *anyopaque, args: []const []const u8, env: *Env) anyerror!ExitStatus,
```

各コマンドは `*Env` を受け取るため、`Env` にフィールドを追加すればそのまま利用可能。`App`・`Command` 側の変更は不要。

### `example/main.zig` での Env 生成

```zig
pub fn main(env: std.process.Init) !void {
    var stdoutWriter = std.Io.File.stdout().writer(env.io, &stdoutBuf);
    var app = zcli.App.init(
        zcli.Env{ .allocator = allocator, .stdout = &stdoutWriter.interface, ... },
        ...
    );
}
```

`env.io`（`std.Io`）はすでに利用可能だが、`Env` に渡していない。

---

## zctx API 概要（v0.2.0 / Zig 0.16.0）

| 型 | 用途 |
|---|---|
| `zctx.Context` | キャンセル信号を受け取る側（read-only） |
| `zctx.OwnedContext` | キャンセルを発火する側（`cancel(io)` / `deinit(io)`） |
| `zctx.BACKGROUND` | キャンセルされないルートコンテキスト（定数） |

```zig
// コンテキスト生成
const cancelCtx = try zctx.withCancel(io, parent, allocator);
defer cancelCtx.deinit(io);

// キャンセル発火
cancelCtx.cancel(io);

// Context の取得（フィールドアクセス）
const ctx: zctx.Context = cancelCtx.context;

// コマンド側でのキャンセル確認
const signal = ctx.done();
if (signal.isFired()) { ... }           // ノンブロッキング（io 不要）
signal.wait(io);                        // ブロッキング
_ = signal.waitTimeout(io, timeout_ns); // タイムアウト付き
ctx.err(io);                            // ?ContextError
```

---

## 設計方針

### 採用：`io` + `ctx` を追加、`stdout`/`stderr` は現行維持

```zig
pub const Env = struct {
    allocator: std.mem.Allocator,
    io: std.Io,            // 追加
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    ctx: zctx.Context,     // 追加
};
```

### `stdout`/`stderr` を維持する理由

`stdout`/`stderr` はテスタビリティのために存在する。`std.Io.Writer` の vtable は2関数（`drain`/`sendFile`）で `Allocating` writer による出力キャプチャが容易。

一方、`std.Io` の vtable は数十関数に及ぶシステム全体の抽象（ファイル・ネット・タイマー・乱数など）であり、テスト用モックを作るコストが大きい。`std.testing.io` は `Io.Threaded`（本物の IO 実装）であり、`std.testing.allocator` と同様にテスト中の `io` を提供するが、出力キャプチャ機能は持たない。

| 抽象 | テスト用実装 | 出力キャプチャ |
|---|---|---|
| `*std.Io.Writer` | `Writer.Allocating` | `writer.buffered()` で確認可能 |
| `std.Io` | `std.testing.io`（本物） | 不可 |

### `io` と `stdout`/`stderr` の役割の違い

| フィールド | 役割 |
|---|---|
| `io` | Zig ランタイムの実行プリミティブ。zctx 等が要求 |
| `stdout`/`stderr` | アプリケーションの出力チャンネル。テスタビリティのため注入 |

`io` を使って `stdout` writer を生成するが、両者は抽象のレベルが異なる。`Env` に両方を持つことで各層の関心を分離できる。

### `Env` のスコープ定義（将来の肥大化防止）

`Env` に追加するフィールドは「CLI コマンドの実行環境そのもの」に限定する。

- **含めるべきもの**：`allocator`（メモリ）、`io`（実行プリミティブ）、`ctx`（キャンセルスコープ）、`stdout`/`stderr`（出力チャンネル）
- **含めるべきでないもの**：ビジネスロジック固有の依存（logger、DB 接続など）

### 却下した案

**`io` を `app.run` の引数にする案**：`ctx` も同時に渡す必要が生じてシグネチャが重くなり、`ctx` と `io` を異なる経路で受け取る非対称な設計になるため却下。

**`Env` が Writer+バッファを内包する案（Option B）**：`std.Io.File.writer()` が返す `Writer` はバッファへの参照を内部に持つため、`Env` の値コピー時にバッファ参照が壊れる（自己参照問題）。`App` を `*Env` 保持に変える大きな API 破壊変更が必要になるため却下。この問題は `std.Io` 自体も「バッファを外部に置く」設計で回避しており、Option A がその設計思想と一致する。

### OS シグナル処理は zcli のスコープ外

zcli はシグナル処理ユーティリティを提供しない。

- **キャンセル不要**：`Env.ctx` に `zctx.BACKGROUND` を渡す
- **キャンセル必要**：利用者が自前で実装する（`example/signal/main.zig` を参照）

この方針の理由：
- SIGINT/SIGTERM によるキャンセルと SIGHUP による設定リロードなど、シグナルに対するアクションはアプリケーションによって異なる
- zcli がシグナル処理を抽象化すると「汎用 OS シグナルライブラリ」になり、「シンプルな CLI フレームワーク」の責務を超える
- 利用者に完全な制御を委ねる方が柔軟性が高い

---

## 必要な変更箇所

### 1. `build.zig.zon` — zctx 依存関係追加

```zig
.dependencies = .{
    .zctx = .{
        .url = "https://github.com/dot96gal/zctx/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

`zig fetch --save <url>` で取得・ハッシュ自動記入。

### 2. `build.zig` — モジュール連携・2 つの実行ステップ追加

```zig
const zctx_dep = b.dependency("zctx", .{ .target = target, .optimize = optimize });
const zctx_mod = zctx_dep.module("zctx");

zcli_mod.addImport("zctx", zctx_mod);

// テスト用モジュール（tests の root_module）にも addImport

// basic example（既存の run ステップを置き換え）
const basic_exe = b.addExecutable(.{
    .name = "example-basic",
    .root_module = b.createModule(.{
        .root_source_file = b.path("example/basic/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcli", .module = zcli_mod },
            .{ .name = "zctx", .module = zctx_mod },
        },
    }),
});
b.installArtifact(basic_exe);
const run_basic = b.addRunArtifact(basic_exe);
run_basic.step.dependOn(b.getInstallStep());
if (b.args) |args| run_basic.addArgs(args);
const run_basic_step = b.step("run-basic", "Run basic example (no cancellation)");
run_basic_step.dependOn(&run_basic.step);

// signal example（新規）
const signal_exe = b.addExecutable(.{
    .name = "example-signal",
    .root_module = b.createModule(.{
        .root_source_file = b.path("example/signal/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcli", .module = zcli_mod },
            .{ .name = "zctx", .module = zctx_mod },
        },
    }),
});
b.installArtifact(signal_exe);
const run_signal = b.addRunArtifact(signal_exe);
run_signal.step.dependOn(b.getInstallStep());
if (b.args) |args| run_signal.addArgs(args);
const run_signal_step = b.step("run-signal", "Run signal cancel example");
run_signal_step.dependOn(&run_signal.step);
```

### 3. `mise.toml` — 2 つの example タスク追加

既存の `example` タスクを `example-basic` / `example-signal` に置き換える。

```toml
[tasks."example-basic"]
description = "run basic example (no cancellation)"
run = "zig build run-basic --summary all -- $@"

[tasks."example-signal"]
description = "run signal cancel example"
run = "zig build run-signal --summary all -- $@"
```

呼び出し例：
```sh
mise run example-basic -- greet --name Alice
mise run example-signal -- greet --name Alice
```

### 4. `src/env.zig` — `Env` に `io` / `ctx` 追加

```zig
const zctx = @import("zctx");

pub const Env = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    ctx: zctx.Context,
};
```

`TestEnv.env()` の変更：引数なしのまま、内部で `std.testing.io` と `zctx.BACKGROUND` を使う。

```zig
pub fn env(self: *TestEnv) Env {
    return .{
        .allocator = self.allocator,
        .io = std.testing.io,      // テスト用本物 io（std.testing.allocator と同等）
        .stdout = &self.outWriter.writer,
        .stderr = &self.errWriter.writer,
        .ctx = zctx.BACKGROUND,    // テストではキャンセルなしがデフォルト
    };
}
```

キャンセル挙動をテストしたい場合は、`te.env()` 後に `e.ctx` を上書きするか、`Env` を直接構築する。

既存のテスト呼び出し（`te.env()` の引数なし）は変更不要。

#### テストケース

キャンセルのあり・なし両方を `src/env.zig` のテストで担保する。

```zig
test "TestEnv のデフォルトはキャンセルなし" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();
    const e = te.env();

    try testing.expect(!e.ctx.done().isFired());
}

test "ctx を上書きしてキャンセル済み状態をテストできる" {
    var te = TestEnv.init(testing.allocator);
    defer te.deinit();

    var cancelCtx = try zctx.withCancel(std.testing.io, zctx.BACKGROUND, testing.allocator);
    defer cancelCtx.deinit(std.testing.io);

    var e = te.env();
    e.ctx = cancelCtx.context;

    // キャンセル前
    try testing.expect(!e.ctx.done().isFired());

    cancelCtx.cancel(std.testing.io);

    // キャンセル後
    try testing.expect(e.ctx.done().isFired());
}
```

### 5. `example/basic/` — 新規作成（`example/main.zig` から移行）

#### `example/basic/greet_command.zig`

```zig
pub fn run(self: *GreetCommand, args: []const []const u8, env: *zcli.Env) !zcli.ExitStatus {
    _ = self;
    _ = args;
    try env.stdout.print("Hello!\n", .{});
    return .success;
}
```

キャンセル確認は行わない。

#### `example/basic/main.zig`

```zig
pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

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
            .ctx = zctx.BACKGROUND,  // キャンセル不要
        },
        "mytool",
        "A demonstration CLI tool",
    );
    defer app.deinit();

    var greet = GreetCommand{};
    try app.register(zcli.Command.from(GreetCommand, &greet));

    const status = app.run(args) catch |err| blk: {
        try stderrWriter.interface.print("error: {s}\n", .{@errorName(err)});
        break :blk zcli.ExitStatus.failure;
    };
    stdoutWriter.interface.flush() catch |err| std.debug.print("stdout flush error: {s}\n", .{@errorName(err)});
    stderrWriter.interface.flush() catch |err| std.debug.print("stderr flush error: {s}\n", .{@errorName(err)});
    status.exit();
}
```

### 6. `example/signal/` — 新規作成

#### `example/signal/greet_command.zig`

```zig
pub fn run(self: *GreetCommand, args: []const []const u8, env: *zcli.Env) !zcli.ExitStatus {
    _ = self;
    _ = args;
    if (env.ctx.done().isFired()) return .failure;
    try env.stdout.print("Hello!\n", .{});
    return .success;
}
```

コマンド実行前にキャンセル済みかを確認し、キャンセル済みなら `failure` を返す。

#### `example/signal/main.zig`

```zig
var cancelled = std.atomic.Value(bool).init(false);

fn sigHandler(_: std.posix.SIG) callconv(.c) void {
    cancelled.store(true, .release);
}

fn signalWatcher(io: std.Io, cancelCtx: *zctx.OwnedContext) void {
    while (!cancelled.load(.acquire)) {
        std.Thread.sleep(100_000_000); // 100ms: 人間が知覚できない遅延かつ CPU 消費を抑える
    }
    cancelCtx.cancel(io);
}

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

    // SIGINT/SIGTERM のハンドラを登録（libc 不要）
    std.posix.sigaction(.INT, &.{
        .handler = .{ .handler = sigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    std.posix.sigaction(.TERM, &.{
        .handler = .{ .handler = sigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var stdoutBuf: [4096]u8 = undefined;
    var stderrBuf: [512]u8 = undefined;
    var stdoutWriter = std.Io.File.stdout().writer(io, &stdoutBuf);
    var stderrWriter = std.Io.File.stderr().writer(io, &stderrBuf);

    var cancelCtx = try zctx.withCancel(io, zctx.BACKGROUND, allocator);
    defer cancelCtx.deinit(io);

    const sigThread = try std.Thread.spawn(.{}, signalWatcher, .{ io, &cancelCtx });
    sigThread.detach();

    var app = zcli.App.init(
        zcli.Env{
            .allocator = allocator,
            .io = io,
            .stdout = &stdoutWriter.interface,
            .stderr = &stderrWriter.interface,
            .ctx = cancelCtx.context,
        },
        "mytool",
        "A demonstration CLI tool",
    );
    defer app.deinit();

    var greet = GreetCommand{};
    try app.register(zcli.Command.from(GreetCommand, &greet));

    const status = app.run(args) catch |err| blk: {
        try stderrWriter.interface.print("error: {s}\n", .{@errorName(err)});
        break :blk zcli.ExitStatus.failure;
    };
    stdoutWriter.interface.flush() catch |err| std.debug.print("stdout flush error: {s}\n", .{@errorName(err)});
    stderrWriter.interface.flush() catch |err| std.debug.print("stderr flush error: {s}\n", .{@errorName(err)});
    status.exit();
}
```

---

## example ディレクトリ構造

```
example/
  basic/
    main.zig             新規：キャンセルなし（zctx.BACKGROUND）
    greet_command.zig    新規：キャンセル確認なし
  signal/
    main.zig             新規：OS シグナルでキャンセル
    greet_command.zig    新規：キャンセル確認あり（env.ctx.done().isFired()）
```

各サンプルは自己完結した実装とし、`greet_command.zig` はそれぞれに配置する。
キャンセルのあり・なしで実装の対比を明確に示す。
既存の `example/main.zig` と `example/greet_command.zig` は移行後に削除する。

---

## 影響範囲まとめ

| ファイル | 変更内容 | 優先度 |
|---|---|---|
| `build.zig.zon` | zctx 依存関係追加 | 必須 |
| `build.zig` | zctx モジュール連携・2 つの実行ステップ追加 | 必須 |
| `mise.toml` | 2 つの example タスク追加 | 必須 |
| `src/env.zig` | `Env` に `io`/`ctx` 追加、`TestEnv.env()` 更新 | 必須 |
| `example/main.zig` | `example/basic/main.zig` に移行・削除 | 必須 |
| `example/greet_command.zig` | `example/basic/greet_command.zig` に移行・削除 | 必須 |
| `example/basic/main.zig` | 新規作成（キャンセルなし） | 必須 |
| `example/basic/greet_command.zig` | 新規作成（キャンセル確認なし） | 必須 |
| `example/signal/main.zig` | 新規作成（OS シグナルキャンセル） | 必須 |
| `example/signal/greet_command.zig` | 新規作成（キャンセル確認あり） | 必須 |
| `src/app.zig` | 変更不要 | 不要 |
| `src/command.zig` | 変更不要 | 不要 |

zctx の型（`Context`、`OwnedContext` 等）は zcli からは再エクスポートしない。利用者が直接 `@import("zctx")` して使う。

---

## 実装順序

1. `build.zig.zon` — zctx を依存関係として追加
2. `build.zig` — zctx モジュール連携・2 つの実行ステップを追加
3. `mise.toml` — 2 つの example タスクを追加
4. `src/env.zig` — `Env` 構造体の変更・`TestEnv` 更新・テスト追加
5. `example/basic/main.zig` + `example/basic/greet_command.zig` — 新規作成（`example/main.zig` から移行）
6. `example/signal/main.zig` + `example/signal/greet_command.zig` — 新規作成
7. `example/main.zig` + `example/greet_command.zig` — 削除

---

## 利用者向けリファレンス：OS シグナル連携の実装パターン

### 制約：async-signal-safe

OS シグナルはプログラムの**どの命令の間にでも割り込む**可能性があり、シグナルハンドラは割り込まれた**同じスレッド**で実行される。

```
通常スレッドの実行:
  mutex.lock()
  ← ここで SIGINT が割り込む
  シグナルハンドラ: cancelCtx.cancel(io) を呼ぶ
    → cancel の内部でも mutex.lock() を試みる
    → 同じスレッドが mutex を持ったままロック取得 → デッドロック
```

POSIX は「シグナルハンドラから呼んでも安全」な関数（async-signal-safe）を定義している。
`write()` などのシステムコール直呼びや atomic 操作は安全だが、
`malloc`・`mutex.lock`・`cancelCtx.cancel(io)` のようにロックやアロケーションを内部で行う関数は安全でない。

### 採用方針：`std.posix.sigaction` + atomic + ポーリングスレッド

`std.c.sigwait` は libc のリンクが必要になるため採用しない。
zcli は libc 非依存（現状 `.dependencies = .{}`）であり、ユーザーの `build.zig` に `linkLibC()` を強制すべきでない。

atomic store は async-signal-safe であるため、シグナルハンドラ内で安全に呼べる。
ポーリング間隔 100ms の遅延は CLI ツールとして体感不可能な範囲。

1. `std.posix.sigaction` で SIGINT/SIGTERM のハンドラを登録
2. ハンドラは `std.atomic.Value(bool)` に `true` を store（async-signal-safe）
3. ウォッチャースレッドが 100ms 間隔でフラグをポーリング
4. フラグ検出後 `cancelCtx.cancel(io)` を呼ぶ（通常スレッドなので安全）
5. `status.exit()` → `std.process.exit()` でプロセス終了
   → detach 済みのウォッチャースレッドも一緒に終了

```
main スレッド
  ├─ sigaction で SIGINT/SIGTERM → cancelled.store(true)
  ├─ cancelCtx = zctx.withCancel(...)
  ├─ signalWatcher スレッドを spawn・detach
  │     └─ cancelled をポーリング（100ms 間隔）
  │           ↓ true を検出
  │           └─ cancelCtx.cancel(io) → ctx に伝搬
  ├─ app.run(args)  ← env.ctx.done().isFired() でキャンセル確認
  └─ status.exit()  → std.process.exit() でプロセス終了
```

サンプルコードは「必要な変更箇所」セクションの 5・6 を参照。

### コマンド側でのキャンセル確認パターン

```zig
pub fn run(self: *GreetCommand, args: []const []const u8, env: *zcli.Env) !zcli.ExitStatus {
    // ノンブロッキング確認（ループの先頭など）
    if (env.ctx.done().isFired()) return .failure;

    // ブロッキング待機（完了を待つ処理と組み合わせる場合）
    // env.ctx.done().wait(env.io);

    _ = args;
    try env.stdout.print("Hello!\n", .{});
    return .success;
}
```

### API 確認済み事項

- `.INT` / `.TERM`：`std.posix.SIG` enum の variant → `std.posix.sigaction(.INT, ...)` の構文で使用可
- `std.posix.sigaction`：`std.posix` に存在。libc 不要
- `std.atomic.Value(bool).store`：async-signal-safe。シグナルハンドラから安全に呼べる
- `std.c.sigwait`・`std.c.pthread_sigmask`：libc が必要なため不採用

---

## 振り返り：計画との差分

### 必須修正（Zig 0.16 API 差異）

**`std.Thread.sleep` の廃止**

計画では `std.Thread.sleep(100_000_000)` を使う想定だったが、Zig 0.16 では同関数が削除されていた。
代替として `io.sleep(.fromNanoseconds(100_000_000), .awake)` を使用。

- `std.Io.sleep(io, duration, clock)` の clock 引数には `std.Io.Clock` enum を渡す
- `monotonic` に相当するのは `.awake`（Linux: `CLOCK_MONOTONIC`、macOS: `CLOCK_UPTIME_RAW`）
- 戻り値は `error{Canceled}!void` のため `catch break` でエラーを処理

### 計画外の追加（動作確認のしやすさ向上）

**`example/signal/greet_command.zig` への追加**

計画のサンプルはキャンセル確認の最小実装だったが、以下を追加した。

| 追加内容 | 理由 |
|---|---|
| ループ内での `env.ctx.done().isFired()` チェック | sleep 中にキャンセルされた場合も次ループ先頭で即検出できるようにするため |
| `try env.stdout.flush()` | バッファされたまま Ctrl+C すると出力がまとめて表示されてしまい動作確認しづらいため |
| `env.io.sleep(.fromNanoseconds(500_000_000), .awake) catch return .failure` | ループが速すぎてキャンセル操作が間に合わないため、各挨拶の間に 500ms の遅延を挿入 |

**`example/signal/main.zig` への追加**

| 追加内容 | 理由 |
|---|---|
| `std.debug.print("cancelled\n", .{})` | キャンセルが発火したタイミングを端末で確認できるようにするため |

---

## 振り返り：依存ライブラリを持つライブラリ設計で学んだこと

### 問題：公開 API への依存型の露出

`Env.ctx: zctx.Context` が公開フィールドであるため、利用者は `Env` を構築するために `zctx.Context` 型の値（`zctx.BACKGROUND` など）を渡す必要がある。
これは **「ライブラリ A の公開 API に依存ライブラリ B の型が露出している」** 状態であり、利用者が B を直接 `@import` せざるを得ないという摩擦を生む。

### 採用した解決策

**`zcli.BACKGROUND` の再エクスポート（`src/root.zig`）**

```zig
pub const BACKGROUND = @import("zctx").BACKGROUND;
```

キャンセル不要な利用者が zctx を知らずに `zcli.BACKGROUND` を渡せるようにした。
`OwnedContext` や `withCancel` など発火側 API は zctx を直接使う必要があるため、そちらは再エクスポートしない。

**`b.modules.put` による zctx モジュールの公開（`build.zig`）**

```zig
b.modules.put(b.allocator, "zctx", zctx_mod) catch @panic("OOM");
```

`Dependency.module()` が `d.builder.modules.get(name)` を参照することを Zig 標準ライブラリのソースから確認し、この方法で zctx を公開。
利用者は `build.zig.zon` に zcli だけ追加すれば `zcli_dep.module("zctx")` で zctx モジュールを取得できる。

### 一般的な設計原則

**「公開 API に依存ライブラリの型が露出しているなら、その型へのアクセス手段を提供する。」**

対処の選択肢：

| アプローチ | 内容 | 今回の判断 |
|---|---|---|
| 必要最小限の定数を再エクスポート | `BACKGROUND` のみ公開 | 採用 |
| 型エイリアスで全型を再エクスポート | `pub const Context = zctx.Context` | 不採用（過剰） |
| ラッパー型で依存を完全隠蔽 | 自前の `Context` 型を定義 | 不採用（複雑化） |
| ライブラリを統合 | zcli と zctx を一体化 | 不採用（zctx の独立性を失う） |

### ドキュメントの状況

これらのパターンは Zig の公式ドキュメントには記載がなく、以下から導いた。

- `b.modules.put` の挙動 → Zig 標準ライブラリ（`std/Build.zig`）のソースを直接読んで確認
- 設計原則 → Go・Rust 等の他言語エコシステムで共通して議論されるソフトウェア設計の知識

Zig のパッケージマネージャは 0.12 前後から実用化された比較的新しい仕組みであり、慣習・ベストプラクティスはコミュニティで形成途上。公式ドキュメントよりも実際のライブラリのソースを読む方が参考になるケースが多い。

# zcli

A standalone Zig CLI framework that turns the [Command Line Interface Guidelines](https://clig.dev/) into usable defaults. **zrich is its only external dependency**, pinned to a commit in `build.zig.zon`. zrich remains a separate, unmodified presentation library. Everything else uses Zig's standard library and code in this project.

This is a working first version: typed options and public records, help and examples, predictable errors, stream-aware rendering, configuration layers, guarded prompts, cancellation hooks, and executable conformance tests. Requires Zig 0.17.0 or newer; tested with Zig 0.17 development builds.

## Try it

```sh
zig build run -- inspect --path README.md
zig build run -- inspect --path README.md --json
./zig-out/bin/parcel inspect --path README.md --plain
zig build test conformance
```

`build run` depends on installation, so it refreshes `zig-out/bin/parcel` on every run. The verification script deliberately replaces that installed binary with a stale file and checks that `build run` restores it. An initial build needs network access to fetch the pinned zrich package; subsequent builds use Zig's package cache. No parser package, C package, runtime service, telemetry, or shell command is required by applications. Process tests use Python 3's standard library.

`parcel` inspects a regular file up to 16 MiB and returns its size, line count, and SHA-256. Its other command removes one file or symbolic link:

```sh
parcel remove --path scratch.txt --dry-run
parcel remove --path scratch.txt --yes
```

The preview validates the target and returns `would remove`. Only the separate execution handler deletes it. It never removes directories. A preview is a snapshot, not a reservation: another process can change a path before execution.

## Declare an application

```zig
const cli = @import("zcli");
const Options = struct { name: []const u8, count: u32 = 1 };
const Person = struct { name: []const u8, count: u32 };

fn greet(ctx: *cli.Context, options: Options) ![]const Person {
    const rows = try ctx.allocator.alloc(Person, 1);
    rows[0] = .{ .name = options.name, .count = options.count };
    return rows;
}

const app: cli.App = .{
    .name = "hello",
    .version = "0.1.0",
    .description = "Print a greeting record",
    .commands = &.{cli.command(Options, Person, .{
        .name = "greet",
        .description = "Greet someone",
        .examples = &.{"hello greet --name Ada"},
        .options = &.{
            .{ .name = "name", .help = "Person to greet", .env = "HELLO_NAME" },
            .{ .name = "count", .help = "Number of greetings", .min = 1, .max = 10 },
        },
    }, .{ .run = greet })},
};
```

Use the native adapter in [`examples/parcel.zig`](examples/parcel.zig) for process entry, environment and independent stream detection. In a host or test, call `app.run(allocator, args_without_argv0, runtime)` with injected writers and capabilities. `run` returns an `Exit`; only the process entry point decides when to exit. Keep `App` and its borrowed command descriptors alive for the call (top-level `const` declarations are convenient).

Add zcli to your project with `zig fetch` (a local checkout also works as a path dependency, `.zcli = .{ .path = "../zcli" }`):

```sh
zig fetch --save git+https://github.com/benomahony/zcli#v0.1.0
```

Then add `b.dependency("zcli", .{ .target = target, .optimize = optimize }).module("zcli")` to your executable's imports.

## Rich terminal presentation

Terminal help follows [Typer's Rich help](https://typer.tiangolo.com/tutorial/commands/help/#help-panels): rounded panels, cyan option/command names, green short aliases, yellow value types, red required markers, and subdued defaults, environment names and constraints. Examples lead the help; output and help switches have their own panels. Destructive-operation switches appear in a Safety panel only when supported.

Errors appear in a red frame with the precise problem and repair instructions. Interactive prompts use an input panel. A single public result becomes a field/value card, giving long paths and hashes more space. Multiple results use a zrich table. Empty results get a clear message. These layouts compose zrich's styles, borders, Unicode measurement and tables; zrich itself remains a separate, unchanged dependency.

Use optional metadata to organize larger applications:

```zig
// In OptionInfo:
.{ .name = "path", .short = 'p', .help = "File to inspect",
   .metavar = "PATH", .help_panel = "Input" }

// In CommandSpec:
.help_panel = "File operations", // top-level command grouping
.result_title = "File inspection",
```

`App.theme` is a `cli.Theme` of zrich styles for headings, options, aliases, values, muted annotations, borders, required markers, progress and errors. No application changes are needed to get the default appearance. Labels and values remain literal text; square brackets never activate markup.

Panels adapt to the terminal width up to 100 columns. Below 76 columns, help switches to stacked option descriptions; below 32 columns it uses the undecorated help fallback. Wrapping respects zrich's Unicode display-width rules and prefers word boundaries. ASCII borders are available through injected `capabilities.unicode = false`.

`NO_COLOR`/`--no-color` retain the layout without ANSI colors. `--plain --help` explicitly removes layout and color from help. Redirected help and TERM=dumb also use the plain renderer. Plain records and JSON remain byte-for-byte compatible; richer errors and prompts are chosen independently using stderr's capabilities. No additional dependencies are introduced.

## Types, schemas and output

Options support `[]const u8`, bools, integers, finite floats, enums, and optional versions of those types. Struct defaults are defaults; a nonoptional field without a default is required. Every field has a matching `OptionInfo`. Quoted Zig names such as `@"max-count"` allow dashed flags. `min`, `max`, `env`, `example`, and `prompt` add policy. Metadata mistakes such as missing fields and reserved names fail at compile time.

Declare `CommandSpec.positional` to accept positional arguments. They bind, in order, to the `Options` field of the same name, which must be `[]const []const u8`. `min` sets how many are required and `default` supplies values when none are given (a positional cannot have both). Positionals and options can be mixed. Commands without a positional reject stray arguments with a usage error.

```zig
const ListOptions = struct { paths: []const []const u8, verbose: bool = false };
// In CommandSpec:
.positional = .{ .name = "paths", .metavar = "PATH", .help = "Paths to list", .default = &.{"."} },
```

Flags accept `--path file`, `--path=file`, `-pfile`, and `-p=file`. Short switches group. Boolean options accept `--enabled` or `--enabled=false`; bare `--enabled false` is not accepted. Repeated application options are rejected. `--` ends option recognition; later arguments are positional data, even when they start with a dash. Global presentation switches work before or after the command. Command-specific switches follow the command.

The result struct is a **public interface**. Construct it explicitly from internal data; private application state is never reflected into output. Scalar and optional fields are supported. Each command exposes field names, kinds and nullability in `Command.schema` and in help.

| Mode | Behavior |
| --- | --- |
| Default on a capable terminal | zrich record card for one result, tables for multiple results; automatic color and width-aware layout |
| Default with stdout redirected | Stable plain records |
| `--plain` | One unwrapped record per line, declaration-order `key=JSON-value` fields separated by tabs; no headers, borders, padding, or ANSI |
| `--json` | One JSON array and trailing newline, using public field names and native scalar types |

Plain strings use JSON escaping, so tabs/newlines/control characters cannot split records. Empty plain output has zero records; empty JSON is `[]`. Human formatting may evolve; plain and JSON formats are contracts. Results are validated and rendered into a buffer before writing, preventing serialization errors from leaving malformed partial JSON. A failed pipe can still truncate bytes already sent; it returns the I/O exit status. Invalid UTF-8 and nonfinite result numbers are rejected. Arbitrary nested records and streaming output are future work. Pass a `.human` handler to `cli.command` to replace the default card or table on a terminal; `--plain` and `--json` output is unaffected. A handler can set `ctx.status` (for example to `.failure` when a linter finds problems) to exit non-zero after its results render.

`NO_COLOR` when nonempty, `TERM=dumb`, and `--no-color` suppress color. Output and diagnostics detect their terminals separately. `--plain` and `--json` affect stdout only. Narrow human tables fall back to plain records. Progress is a static snapshot on stderr; there are no animations in this version. `-q` suppresses progress, while essential errors remain visible. No color override or unimplemented pager/verbosity switch is advertised.

## Helpful errors and interaction

Use `return ctx.fail(.failure, "The item no longer exists.", "Refresh the list and choose an existing item.");` for expected application errors. Failure messages explain the problem and a concrete repair; numeric exit statuses are only for the calling process. Expected errors never print Zig error names or stack traces. Unexpected errors return a brief failure and the app's `support` path, if declared.

Framework messages identify missing options, invalid types, allowed enum choices, numeric ranges, unknown options and configuration sources. For example:

```text
--count must be between 1 and 10. The value came from project configuration.
Correct project configuration, or pass --count 1. See --help for allowed values.
```

Exit statuses: success 0; expected operational failure 1; usage 2; unexpected failure 70; output I/O 74; configuration 78; cooperative cancellation 130. An invalid value from the environment or a config layer is a configuration error; an invalid command-line value is a usage error. An invalid developer default is an internal error.

Prompts require both `stdin_tty` and an injected `read_line` callback. `prompt = true` opts a required option into prompting. Otherwise required options fail with supply instructions. `--no-input` appears only for commands with declared prompting or confirmation and always prevents reads, even with terminal stdin. Prompt text goes to stderr and is flushed first. EOF and read failures must be translated by the host callback. A prompt callback must return text owned by the invocation allocator or text valid for the rest of the invocation. Secret prompting is not implemented.

Help (`-h`, `--help`, `help`, `help <command>`) runs before parsing, configuration, validation, hooks, or handlers. Exact help tokens before `--` intentionally override malformed arguments, including a preceding option missing its value. Use `--path=--help` for that literal value. No-argument top-level invocations show help. Missing required command options produce a focused error with supply instructions.

## Configuration and lifecycle

Precedence is **flags > environment > project > user > system > struct defaults**. The winning value is converted and validated once before execution. Overridden invalid values do not cause failure; unknown and duplicate file keys always do. Option environment names are explicit, with no broad ambient configuration reads.

Supply `Runtime.config` as command-local layers or a lazy `load_config(ctx, command_name)` callback. The callback runs only after normal argument parsing; it replaces the injected layers. The framework does not guess filesystem locations or mutate configuration. `parcel` demonstrates a strict JSON object of string values loaded only when `PARCEL_CONFIG` names a file; `PARCEL_PATH` then overrides its `path`, and `--path` overrides both. Host applications choose XDG locations and file formats. Malformed files should call `ctx.fail(.config, ..., ...)`.

`Runtime.hooks` offers an injected cancellation probe, `on_cancel(ctx)` and `cleanup(ctx, exit)`. The framework checks cancellation before loading configuration and around dispatch; long-running handlers call `ctx.checkCancelled()` between units of work. It reports cancellation before calling `on_cancel`, then calls cleanup exactly once for dispatch attempts (including configuration/validation failures). Help/version and parser failures do not start this lifecycle. Cleanup runs before the invocation arena is released. Flush failures discovered after cleanup can change the final exit status to 74. See `src/tests.zig` for executable hook examples.

Applications own signal registration, cancellation of blocking I/O, rollback, and bounded cleanup. The framework does not install process-global handlers or assume arbitrary I/O can be interrupted. `on_cancel` and `cleanup` must not block indefinitely. Ctrl-C reentrancy, cleanup deadlines, native signal bridges and forced second-interrupt exit are future adapter work.

Declare a destructive policy through `CommandSpec.destructive` only when `--yes` is suitable for your operation. This enables confirmation/`--yes`/`--no-input`. Provide `.dry_run = preview_handler` separately to enable `--dry-run`/`-n`; that handler alone runs during previews, with the same typed validation and result schema. The framework cannot enforce absence of side effects inside your preview, infer reversibility, authorize an operation, or implement transactional safety. Severe operations should use application-defined typed confirmation options instead.

All command scratch data and results live in an arena backed by the explicit allocator passed to `run`. Writers, environment, hooks, and user state remain caller-owned. Handlers can use `ctx.allocator` without per-object frees; nothing allocated there may escape the invocation. Diagnostics are escaped as literal text, not interpreted as zrich markup. The core performs no network calls, reads no global environment, and opens no files.

## Verification and scope

```sh
python3 tools/verify.py --zig /absolute/path/to/zig-0.17/zig
```

CI runs the same unit and process tests on Zig master for macOS and Linux.

`cli.conformance.check` runs declarative application cases with captured streams, exit checks, JSON parsing, redirected-output checks and a noninteractive runtime. Import it into downstream tests. `tests/cli_contract.py` supplies a reusable process/PTY harness with a timeout that catches accidental prompts. `tests/process_test.py` applies it to real files, independent terminals, redirected streams, configuration, preview and deletion. Unit tests add cancellation, cleanup, typed validation, source precedence and prompt callback assertions.

See [guideline coverage](docs/guidelines.md) for implementation boundaries and [parser evaluation](docs/parser.md) for the zig-clap assessment. This version supports a single level of commands with named options and one positional list; nested commands, repeated/list options, completion, man pages, pagers, secret-input helpers, schema export, platform signal adapters, streaming results, and native Windows process tests are future work. Tested on macOS ARM64; CI also runs the suite on Linux. Windows is not yet tested.

Remove `zig-out` to uninstall the local example. No files are installed globally.

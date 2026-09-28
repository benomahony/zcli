const std = @import("std");
const cli = @import("root.zig");
const Options = struct { name: []const u8, count: u32 = 1 };
const Row = struct { name: []const u8, count: u32 };
fn greet(ctx: *cli.Context, options: Options) ![]const Row {
    try ctx.progress("Preparing", 1, 1);
    const rows = try ctx.allocator.alloc(Row, 1);
    rows[0] = .{ .name = options.name, .count = options.count };
    return rows;
}
const app: cli.App = .{ .name = "test", .version = "1.0", .description = "Test CLI", .commands = &.{cli.command(Options, Row, .{
    .name = "greet",
    .description = "Greet someone",
    .examples = &.{"test greet --name Ada"},
    .options = &.{ .{ .name = "name", .help = "Name", .env = "TEST_NAME", .prompt = true }, .{ .name = "count", .short = 'c', .help = "Count", .min = 1, .max = 10 } },
}, .{ .run = greet })} };
test "reusable conformance contract" {
    try cli.conformance.check(std.testing.allocator, app, &.{
        .{ .args = &.{}, .stdout_contains = "Usage:", .stderr_empty = true },
        .{ .args = &.{"--version"}, .stdout_contains = "test 1.0", .stderr_empty = true },
        .{ .args = &.{ "greet", "--count", "bogus", "--help" }, .stdout_contains = "Examples:", .stderr_empty = true },
        .{ .args = &.{ "help", "greet" }, .stdout_contains = "--name", .stderr_empty = true },
        .{ .args = &.{ "greet", "--name", "Ada", "--json" }, .json = true, .stderr_contains = "Preparing", .stdout_contains = "Ada" },
        .{ .args = &.{ "greet", "--name=Ada", "--plain", "-c2" }, .stdout_contains = "name=\"Ada\"\tcount=2\n" },
        .{ .args = &.{ "greet", "--no-input" }, .exit = .usage, .stdout_empty = true, .stderr_contains = "Supply --name" },
        .{ .args = &.{ "greet", "--name", "Ada", "--count", "-1" }, .exit = .usage, .stdout_empty = true },
        .{ .args = &.{ "greet", "--name", "Ada", "--count", "11" }, .exit = .usage, .stdout_empty = true },
        .{ .args = &.{ "greet", "--wat" }, .exit = .usage, .stderr_contains = "--help", .stdout_empty = true },
        .{ .args = &.{ "greet", "--dry-run" }, .exit = .usage, .stdout_empty = true },
        .{ .args = &.{ "greet", "--name" }, .exit = .usage, .stderr_contains = "--name needs a value" },
        .{ .args = &.{ "greet", "--", "--help" }, .exit = .usage, .stdout_empty = true },
    });
}

const Capture = struct {
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    fn init() Capture {
        return .{ .out = .init(std.testing.allocator), .err = .init(std.testing.allocator) };
    }
    fn deinit(self: *Capture) void {
        self.out.deinit();
        self.err.deinit();
    }
    fn runtime(self: *Capture) cli.Runtime {
        return .{ .out = .{ .writer = &self.out.writer }, .err = .{ .writer = &self.err.writer } };
    }
};
fn contains(bytes: []const u8, text: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, bytes, text) != null);
}

test "configuration precedence: flags, environment, project, user, system, default" {
    const layers: cli.Config = .{
        .system = &.{.{ .key = "name", .value = "system" }},
        .user = &.{.{ .key = "name", .value = "user" }},
        .project = &.{.{ .key = "name", .value = "project" }},
    };
    for (0..5) |level| {
        var c = Capture.init();
        defer c.deinit();
        var rt = c.runtime();
        rt.config = layers;
        if (level < 4) rt.config.project = &.{};
        if (level < 3) rt.config.user = &.{};
        if (level == 1) rt.environment = .{ .entries = &.{.{ .key = "TEST_NAME", .value = "env" }} };
        const args: []const []const u8 = if (level == 0) &.{ "greet", "--name", "flag" } else &.{"greet"};
        try std.testing.expectEqual(cli.Exit.success, app.run(std.testing.allocator, args, rt));
        try contains(c.out.written(), ([_][]const u8{ "flag", "env", "system", "user", "project" })[level]);
        try contains(c.out.written(), "count=1");
    }
}
test "configuration validation identifies source and repair; overridden invalid values are ignored" {
    var c = Capture.init();
    defer c.deinit();
    var rt = c.runtime();
    rt.config.project = &.{ .{ .key = "name", .value = "Ada" }, .{ .key = "count", .value = "no" } };
    try std.testing.expectEqual(cli.Exit.config, app.run(std.testing.allocator, &.{"greet"}, rt));
    try contains(c.err.written(), "--count must be a whole number");
    try contains(c.err.written(), "project configuration");
    try contains(c.err.written(), "--count 1");
    try std.testing.expectEqual(cli.Exit.success, app.run(std.testing.allocator, &.{ "greet", "--count=2" }, rt));
    rt.config.project = &.{.{ .key = "typo", .value = "x" }};
    try std.testing.expectEqual(cli.Exit.config, app.run(std.testing.allocator, &.{ "greet", "--name=Ada" }, rt));
    rt.config.project = &.{ .{ .key = "name", .value = "x" }, .{ .key = "name", .value = "y" } };
    try std.testing.expectEqual(cli.Exit.config, app.run(std.testing.allocator, &.{"greet"}, rt));
}
const Probe = struct {
    loads: usize = 0,
    prompts: usize = 0,
    cleanup: usize = 0,
    cancelled: usize = 0,
    runs: usize = 0,
    plans: usize = 0,
    stop: bool = false,
    exit: cli.Exit = .internal,
    fn get(ctx: *cli.Context) *Probe {
        return @ptrCast(@alignCast(ctx.runtime.user_data.?));
    }
    fn load(ctx: *cli.Context, _: []const u8) !cli.Config {
        get(ctx).loads += 1;
        return ctx.fail(.config, "Bad configuration.", "Fix the configuration.");
    }
    fn prompt(ctx: *cli.Context) ![]const u8 {
        get(ctx).prompts += 1;
        return "Ada";
    }
    fn cleanupFn(ctx: *cli.Context, exit: cli.Exit) void {
        get(ctx).cleanup += 1;
        get(ctx).exit = exit;
    }
    fn cancelledFn(ctx: *cli.Context) void {
        get(ctx).cancelled += 1;
    }
    fn stopped(ptr: ?*anyopaque) bool {
        const p: *Probe = @ptrCast(@alignCast(ptr.?));
        return p.stop;
    }
    fn hooks(self: *Probe) cli.Hooks {
        return .{ .state = self, .cancelled = stopped, .cleanup = cleanupFn, .on_cancel = cancelledFn };
    }
};
test "help bypasses config loading prompts cleanup and handlers" {
    var c = Capture.init();
    defer c.deinit();
    var p: Probe = .{};
    var rt = c.runtime();
    rt.user_data = &p;
    rt.load_config = Probe.load;
    rt.read_line = Probe.prompt;
    rt.hooks = p.hooks();
    rt.stdin_tty = true;
    for ([_][]const []const u8{ &.{ "greet", "--count", "nonsense", "--help" }, &.{ "help", "greet" }, &.{ "greet", "-qh" }, &.{"--version"} }) |args|
        try std.testing.expectEqual(cli.Exit.success, app.run(std.testing.allocator, args, rt));
    try std.testing.expectEqual(@as(usize, 0), p.loads + p.prompts + p.cleanup);
    try std.testing.expectEqual(@as(usize, 0), c.err.written().len);
}
test "prompts require interactive stdin and permission; --no-input always wins" {
    for (0..3) |mode| {
        var c = Capture.init();
        defer c.deinit();
        var p: Probe = .{};
        var rt = c.runtime();
        rt.user_data = &p;
        rt.read_line = Probe.prompt;
        rt.stdin_tty = mode != 0;
        const args: []const []const u8 = if (mode == 1) &.{ "greet", "--no-input" } else &.{"greet"};
        try std.testing.expectEqual(if (mode == 2) cli.Exit.success else cli.Exit.usage, app.run(std.testing.allocator, args, rt));
        try std.testing.expectEqual(@as(usize, if (mode == 2) 1 else 0), p.prompts);
    }
}
test "cancellation and cleanup are explicit and run exactly once" {
    for (0..2) |mode| {
        var c = Capture.init();
        defer c.deinit();
        var p: Probe = .{ .stop = mode == 0 };
        var rt = c.runtime();
        rt.user_data = &p;
        rt.hooks = p.hooks();
        if (mode == 1) rt.load_config = Probe.load;
        const exit = app.run(std.testing.allocator, &.{ "greet", "--name=Ada" }, rt);
        try std.testing.expectEqual(if (mode == 0) cli.Exit.cancelled else cli.Exit.config, exit);
        try std.testing.expectEqual(exit, p.exit);
        try std.testing.expectEqual(@as(usize, 1), p.cleanup);
        try std.testing.expectEqual(@as(usize, if (mode == 0) 1 else 0), p.cancelled);
        try std.testing.expectEqual(@as(usize, 0), c.out.written().len);
    }
}
test "independent streams, NO_COLOR, TERM=dumb, and plain output" {
    for (0..4) |mode| {
        var c = Capture.init();
        defer c.deinit();
        var rt = c.runtime();
        rt.out.capabilities = .{ .interactive = mode != 1, .color = mode != 1 };
        rt.err.capabilities = .{ .interactive = mode != 0, .color = mode != 0 };
        if (mode == 2) rt.environment.entries = &.{.{ .key = "NO_COLOR", .value = "1" }};
        if (mode == 3) rt.environment.entries = &.{.{ .key = "TERM", .value = "dumb" }};
        try std.testing.expectEqual(cli.Exit.success, app.run(std.testing.allocator, &.{ "greet", "--name=Ada" }, rt));
        try std.testing.expectEqual(mode == 0, std.mem.indexOfScalar(u8, c.out.written(), 27) != null);
        try std.testing.expectEqual(mode == 1, std.mem.indexOfScalar(u8, c.err.written(), 27) != null);
        if (mode == 1 or mode == 3) try contains(c.out.written(), "name=\"Ada\"\tcount=1\n");
    }
}
test "plain records do not wrap and JSON preserves escaped strings" {
    const value = "a very long value with [markup] and tabs\tnewlines\nand an escape\x1b";
    try cli.conformance.check(std.testing.allocator, app, &.{
        .{ .args = &.{ "greet", "--name", value, "--plain" }, .stdout_contains = "tabs\\tnewlines\\nand an escape\\u001b" },
        .{ .args = &.{ "greet", "--name", value, "--json" }, .json = true },
        .{ .args = &.{ "--json", "greet", "--name=Ada", "-q" }, .json = true, .stderr_empty = true },
        .{ .args = &.{ "greet", "--name=Ada", "--plain", "--json" }, .exit = .usage, .stdout_empty = true },
    });
}
const TypedOptions = struct { enabled: bool = false, mode: enum { fast, careful } = .careful, ratio: f64 = 0.5, note: ?[]const u8 = null };
fn typed(ctx: *cli.Context, opts: TypedOptions) ![]const TypedOptions {
    const rows = try ctx.allocator.alloc(TypedOptions, 1);
    rows[0] = opts;
    return rows;
}
const typed_app: cli.App = .{ .name = "typed", .version = "1", .description = "Typed values", .commands = &.{cli.command(TypedOptions, TypedOptions, .{
    .name = "show",
    .description = "Show typed values",
    .options = &.{ .{ .name = "enabled", .help = "Enable" }, .{ .name = "mode", .help = "Mode" }, .{ .name = "ratio", .help = "Ratio", .min = 0, .max = 1 }, .{ .name = "note", .help = "Note" } },
}, .{ .run = typed })} };
test "typed bool enum number optional defaults and public schema" {
    try cli.conformance.check(std.testing.allocator, typed_app, &.{
        .{ .args = &.{ "show", "--json" }, .json = true, .stdout_contains = "\"note\":null" },
        .{ .args = &.{ "show", "--enabled", "--mode=fast", "--ratio=0.75", "--note=hello", "--json" }, .json = true, .stdout_contains = "\"enabled\":true" },
        .{ .args = &.{ "show", "--mode=typo" }, .exit = .usage, .stderr_contains = "must be one of: fast, careful" },
        .{ .args = &.{ "show", "--ratio=NaN" }, .exit = .usage, .stderr_contains = "finite number" },
        .{ .args = &.{ "show", "--ratio=2" }, .exit = .usage, .stderr_contains = "between 0 and 1" },
        .{ .args = &.{ "show", "--enabled=false", "--json" }, .json = true, .stdout_contains = "\"enabled\":false" },
        .{ .args = &.{ "show", "--enabled=maybe" }, .exit = .usage, .stderr_contains = "true or false" },
    });
    try std.testing.expectEqual(@as(usize, 4), typed_app.commands[0].schema.len);
}
fn executeDestructive(ctx: *cli.Context, opts: Options) ![]const Row {
    Probe.get(ctx).runs += 1;
    return greet(ctx, opts);
}
fn previewDestructive(ctx: *cli.Context, opts: Options) ![]const Row {
    Probe.get(ctx).plans += 1;
    return greet(ctx, opts);
}
const destructive_app: cli.App = .{ .name = "danger", .version = "1", .description = "Test conventions", .commands = &.{cli.command(Options, Row, .{
    .name = "remove",
    .description = "Remove",
    .destructive = "Remove the selected resource?",
    .options = &.{ .{ .name = "name", .help = "Name" }, .{ .name = "count", .help = "Count" } },
}, .{ .run = executeDestructive, .dry_run = previewDestructive })} };
test "dry run invokes only the separate preview handler; destructive execution needs confirmation" {
    var c = Capture.init();
    defer c.deinit();
    var p: Probe = .{};
    var rt = c.runtime();
    rt.user_data = &p;
    try std.testing.expectEqual(cli.Exit.success, destructive_app.run(std.testing.allocator, &.{ "remove", "--name=Ada", "--dry-run" }, rt));
    try std.testing.expectEqual(@as(usize, 1), p.plans);
    try std.testing.expectEqual(@as(usize, 0), p.runs);
    try std.testing.expectEqual(cli.Exit.usage, destructive_app.run(std.testing.allocator, &.{ "remove", "--name=Ada", "--no-input" }, rt));
    try std.testing.expectEqual(@as(usize, 0), p.runs);
    try contains(c.err.written(), "--yes");
    try std.testing.expectEqual(cli.Exit.success, destructive_app.run(std.testing.allocator, &.{ "remove", "--name=Ada", "--yes" }, rt));
    try std.testing.expectEqual(@as(usize, 1), p.runs);
}
test "a broken output stream returns an I/O exit status" {
    var c = Capture.init();
    defer c.deinit();
    var fixed = std.Io.Writer.fixed(&.{});
    var rt = c.runtime();
    rt.out.writer = &fixed;
    try std.testing.expectEqual(cli.Exit.io, app.run(std.testing.allocator, &.{ "greet", "--name=Ada" }, rt));
    try contains(c.err.written(), "Could not write output");
}

fn failExpected(ctx: *cli.Context, _: Options) ![]const Row {
    return ctx.fail(.failure, "The item no longer exists.", "Refresh the list and choose an existing item.");
}
fn failUnexpected(_: *cli.Context, _: Options) ![]const Row {
    return error.SensitiveInternalDetail;
}
fn cancelDuring(ctx: *cli.Context, opts: Options) ![]const Row {
    Probe.get(ctx).stop = true;
    return greet(ctx, opts);
}
fn invalidRecord(ctx: *cli.Context, _: Options) ![]const Row {
    const rows = try ctx.allocator.alloc(Row, 1);
    rows[0] = .{ .name = "\xff", .count = 1 };
    return rows;
}
fn variant(comptime handler: *const fn (*cli.Context, Options) anyerror![]const Row) cli.App {
    return comptime .{ .name = "test", .description = "Errors", .version = "1", .commands = &.{cli.command(Options, Row, .{
        .name = "run",
        .description = "Run",
        .options = &.{ .{ .name = "name", .help = "Name" }, .{ .name = "count", .help = "Count" } },
    }, .{ .run = handler })} };
}
test "expected errors are actionable and unexpected failures do not disclose internal details" {
    try cli.conformance.check(std.testing.allocator, variant(failExpected), &.{.{ .args = &.{ "run", "--name=Ada", "--json" }, .exit = .failure, .stdout_empty = true, .stderr_contains = "Refresh the list" }});
    var c = Capture.init();
    defer c.deinit();
    var p: Probe = .{};
    var rt = c.runtime();
    rt.user_data = &p;
    rt.hooks = p.hooks();
    try std.testing.expectEqual(cli.Exit.internal, variant(failUnexpected).run(std.testing.allocator, &.{ "run", "--name=Ada" }, rt));
    try std.testing.expectEqual(@as(usize, 1), p.cleanup);
    try std.testing.expectEqual(cli.Exit.internal, p.exit);
    try std.testing.expect(std.mem.indexOf(u8, c.err.written(), "SensitiveInternalDetail") == null);
}
test "cancellation during execution discards results and notifies before cleanup" {
    var c = Capture.init();
    defer c.deinit();
    var p: Probe = .{};
    var rt = c.runtime();
    rt.user_data = &p;
    rt.hooks = p.hooks();
    try std.testing.expectEqual(cli.Exit.cancelled, variant(cancelDuring).run(std.testing.allocator, &.{ "run", "--name=Ada", "--json" }, rt));
    try std.testing.expectEqual(@as(usize, 1), p.cleanup);
    try std.testing.expectEqual(@as(usize, 1), p.cancelled);
    try std.testing.expectEqual(@as(usize, 0), c.out.written().len);
}
test "invalid public records never produce partial JSON" {
    try cli.conformance.check(std.testing.allocator, variant(invalidRecord), &.{.{ .args = &.{ "run", "--name=Ada", "--json" }, .exit = .internal, .stdout_empty = true }});
}
test "empty JSON is an array and empty plain has no headers" {
    const Empty = struct {
        fn run(_: *cli.Context, _: Options) ![]const Row {
            return &.{};
        }
    };
    try cli.conformance.check(std.testing.allocator, variant(Empty.run), &.{
        .{ .args = &.{ "run", "--name=Ada", "--json" }, .json = true, .stdout_contains = "[]\n" },
        .{ .args = &.{ "run", "--name=Ada", "--plain" }, .stdout_empty = true },
    });
}
test "short groups, duplicate flags, negative values, and argument terminators" {
    try cli.conformance.check(std.testing.allocator, app, &.{
        .{ .args = &.{ "greet", "--name=Ada", "-qc2" }, .stderr_empty = true, .stdout_contains = "count=2" },
        .{ .args = &.{ "greet", "--name", "--help" }, .stdout_contains = "Usage:", .stderr_empty = true },
        .{ .args = &.{ "greet", "--name=Ada", "--name=Bob" }, .exit = .usage, .stderr_contains = "--name was supplied more than once" },
        .{ .args = &.{ "greet", "--name=Ada", "--count=9999999999999999999999" }, .exit = .usage, .stderr_contains = "whole number" },
        .{ .args = &.{ "greet", "--name=Ada", "-z" }, .exit = .usage, .stderr_contains = "-z is not" },
    });
}

test "grouped help bypasses required values and handlers" {
    try cli.conformance.check(std.testing.allocator, app, &.{
        .{ .args = &.{ "greet", "-qh" }, .stdout_contains = "Usage:", .stderr_empty = true },
    });
}

test "rich help groups options, preserves metadata and bypasses execution" {
    var c = Capture.init();
    defer c.deinit();
    var probe: Probe = .{};
    var rt = c.runtime();
    rt.out.capabilities = .{ .interactive = true, .color = true, .width = 90 };
    rt.load_config = Probe.load;
    rt.user_data = &probe;
    rt.read_line = Probe.prompt;
    rt.stdin_tty = true;
    try std.testing.expectEqual(cli.Exit.success, app.run(std.testing.allocator, &.{ "greet", "--count=invalid", "--help" }, rt));
    try contains(c.out.written(), "Examples");
    try contains(c.out.written(), "--name");
    try contains(c.out.written(), "[required]");
    try contains(c.out.written(), "[env: TEST_NAME]");
    try contains(c.out.written(), "[default: 1]");
    try contains(c.out.written(), "[min: 1]");
    try contains(c.out.written(), "[max: 10]");
    try contains(c.out.written(), "\x1b[");
    try contains(c.out.written(), "╭");
    try std.testing.expectEqual(@as(usize, 0), probe.loads + probe.prompts);
    try std.testing.expectEqual(@as(usize, 0), c.err.written().len);
}

test "plain help suppresses decoration, while NO_COLOR preserves rich layout" {
    for (0..3) |mode| {
        var c = Capture.init();
        defer c.deinit();
        var rt = c.runtime();
        rt.out.capabilities = .{ .interactive = true, .color = true };
        if (mode == 1) rt.environment.entries = &.{.{ .key = "NO_COLOR", .value = "1" }};
        if (mode == 2) rt.environment.entries = &.{.{ .key = "TERM", .value = "dumb" }};
        const args: []const []const u8 = if (mode == 0) &.{ "greet", "--plain", "--help" } else &.{ "greet", "--help" };
        try std.testing.expectEqual(cli.Exit.success, app.run(std.testing.allocator, args, rt));
        try std.testing.expect(std.mem.indexOfScalar(u8, c.out.written(), 27) == null);
        try std.testing.expectEqual(mode == 1, std.mem.indexOf(u8, c.out.written(), "╭") != null);
    }
}

test "rich errors use only stderr and preserve actionable text" {
    var c = Capture.init();
    defer c.deinit();
    var rt = c.runtime();
    rt.err.capabilities = .{ .interactive = true, .color = true };
    try std.testing.expectEqual(cli.Exit.usage, app.run(std.testing.allocator, &.{ "greet", "--no-input" }, rt));
    try contains(c.err.written(), "╭");
    try contains(c.err.written(), "Error");
    try contains(c.err.written(), "Supply --name");
    try std.testing.expectEqual(@as(usize, 0), c.out.written().len);
}

test "rich help wraps at terminal width, with Unicode and a narrow fallback" {
    const UnicodeOptions = struct { path: []const u8 };
    const Unicode = struct {
        fn run(_: *cli.Context, _: UnicodeOptions) ![]const Row {
            return &.{};
        }
    };
    const unicode_app: cli.App = .{ .name = "example", .description = "配置 documents for a long descriptive command", .version = "1", .commands = &.{cli.command(UnicodeOptions, Row, .{
        .name = "show",
        .description = "Inspect 配置文件 and show useful information about the selected document",
        .options = &.{.{ .name = "path", .help = "A long description with 配置文件 and enough words to wrap across multiple lines", .metavar = "PATH", .help_panel = "Files", .env = "EXAMPLE_PATH" }},
    }, .{ .run = Unicode.run })} };
    for ([_]usize{ 1, 32, 40, 60, 75, 76, 80, 100, 160 }) |width| {
        var c = Capture.init();
        defer c.deinit();
        var rt = c.runtime();
        rt.out.capabilities = .{ .interactive = true, .width = width };
        try std.testing.expectEqual(cli.Exit.success, unicode_app.run(std.testing.allocator, &.{ "show", "--help" }, rt));
        try contains(c.out.written(), "--path");
        if (width >= 32) {
            var lines = std.mem.splitScalar(u8, c.out.written(), '\n');
            while (lines.next()) |line| {
                const display_width = try cli.zrich.text.width(line);
                try std.testing.expect(display_width <= @min(width, 100));
                if (std.mem.startsWith(u8, line, "│")) try std.testing.expectEqual(@min(width, 100), display_width);
            }
        } else try std.testing.expect(std.mem.indexOf(u8, c.out.written(), "╭") == null);
    }
}

test "single result cards keep long values intact and ASCII borders are available" {
    var c = Capture.init();
    defer c.deinit();
    var rt = c.runtime();
    rt.out.capabilities = .{ .interactive = true, .unicode = false, .width = 100 };
    const value = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectEqual(cli.Exit.success, app.run(std.testing.allocator, &.{ "greet", "--name", value }, rt));
    try contains(c.out.written(), "+- Result");
    try contains(c.out.written(), value);
    try std.testing.expect(std.mem.indexOf(u8, c.out.written(), "╭") == null);
}

const Files = struct {
    const ListOptions = struct { paths: []const []const u8, verbose: bool = false };
    const Path = struct { path: []const u8 };
    fn list(ctx: *cli.Context, options: ListOptions) ![]const Path {
        const rows = try ctx.allocator.alloc(Path, options.paths.len);
        for (options.paths, rows) |path, *row| row.* = .{ .path = path };
        if (options.paths.len > 2) ctx.status = .failure;
        return rows;
    }
    fn human(ctx: *cli.Context, rows: []const Path) !void {
        for (rows) |row| try ctx.runtime.out.writer.print("* {s}\n", .{row.path});
    }
    fn app(comptime min: usize, comptime default: []const []const u8) cli.App {
        return .{ .name = "files", .version = "1", .description = "Files", .commands = &.{cli.command(ListOptions, Path, .{
            .name = "list",
            .description = "List paths",
            .positional = .{ .name = "paths", .metavar = "PATH", .help = "Paths to list", .min = min, .default = default },
            .options = &.{.{ .name = "verbose", .help = "More detail" }},
        }, .{ .run = list, .human = human })} };
    }
};
test "positional arguments bind to their field, keep order, and mix with options" {
    try cli.conformance.check(std.testing.allocator, comptime Files.app(0, &.{"."}), &.{
        .{ .args = &.{ "list", "a", "--verbose", "b" }, .stdout_contains = "path=\"a\"\npath=\"b\"\n" },
        .{ .args = &.{"list"}, .stdout_contains = "path=\".\"\n" },
        .{ .args = &.{ "list", "--", "--verbose" }, .stdout_contains = "path=\"--verbose\"\n" },
        .{ .args = &.{ "list", "a", "--json" }, .json = true, .stdout_contains = "\"a\"" },
        .{ .args = &.{ "list", "--help" }, .stdout_contains = "[PATH...]" },
        .{ .args = &.{ "list", "--help" }, .stdout_contains = "[default: .]" },
    });
    try cli.conformance.check(std.testing.allocator, comptime Files.app(1, &.{}), &.{
        .{ .args = &.{"list"}, .exit = .usage, .stdout_empty = true, .stderr_contains = "needs at least 1 PATH" },
        .{ .args = &.{ "list", "--help" }, .stdout_contains = "list [options] PATH..." },
    });
}
test "a handler can exit non-zero after its results render" {
    try cli.conformance.check(std.testing.allocator, comptime Files.app(0, &.{}), &.{
        .{ .args = &.{ "list", "a", "b", "c" }, .exit = .failure, .stdout_contains = "path=\"c\"", .stderr_empty = true },
        .{ .args = &.{ "list", "a" }, .exit = .success },
    });
}
test "a custom human renderer replaces the table on a terminal only" {
    try cli.conformance.check(std.testing.allocator, comptime Files.app(0, &.{}), &.{
        .{ .args = &.{ "list", "a" }, .redirected = false, .stdout_contains = "* a\n" },
        .{ .args = &.{ "list", "a", "--plain" }, .redirected = false, .stdout_contains = "path=\"a\"" },
    });
}

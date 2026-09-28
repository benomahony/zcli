//! Typed commands and predictable process behavior. No process-global I/O or allocator.
const std = @import("std");
const parser_backend = @import("parser.zig");
pub const zrich = @import("zrich");
const presentation = @import("presentation.zig");
pub const Theme = presentation.Theme;
pub const conformance = @import("conformance.zig");
pub const native = @import("native.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const Exit = enum(u8) { success = 0, failure = 1, usage = 2, internal = 70, io = 74, config = 78, cancelled = 130 };
pub const Format = enum { human, plain, json };
pub const Source = enum { command_line, environment, project, user, system, default };
pub const Pair = struct { key: []const u8, value: []const u8 };
pub const Environment = struct {
    entries: []const Pair = &.{},
    map: ?*const std.process.Environ.Map = null,
    pub fn get(self: Environment, key: []const u8) ?[]const u8 {
        for (self.entries) |p| if (eql(u8, p.key, key)) return p.value;
        return if (self.map) |m| m.get(key) else null;
    }
};
/// Layers are command-local, keyed by long option name. Unknown/duplicate keys fail.
pub const Config = struct { system: []const Pair = &.{}, user: []const Pair = &.{}, project: []const Pair = &.{} };
pub const Stream = struct { writer: *std.Io.Writer, capabilities: zrich.Options = .{} };
pub const Hooks = struct {
    state: ?*anyopaque = null,
    cancelled: ?*const fn (?*anyopaque) bool = null,
    on_cancel: ?*const fn (*Context) void = null,
    cleanup: ?*const fn (*Context, Exit) void = null,
};
pub const Runtime = struct {
    out: Stream,
    err: Stream,
    stdin_tty: bool = false,
    environment: Environment = .{},
    config: Config = .{},
    /// Called after help/version and argument parsing. File discovery belongs to the host.
    load_config: ?*const fn (*Context, []const u8) anyerror!Config = null,
    /// Reads one line only. The framework displays the question on stderr first.
    read_line: ?*const fn (*Context) anyerror![]const u8 = null,
    hooks: Hooks = .{},
    user_data: ?*anyopaque = null,
};
pub const Failure = struct { message: []const u8, hint: []const u8, code: Exit = .failure };
pub const Context = struct {
    allocator: Allocator,
    runtime: Runtime,
    format: Format,
    theme: Theme = .{},
    result_title: []const u8 = "Result",
    no_input: bool = false,
    quiet: bool = false,
    failure: ?Failure = null,
    sources: []const Source = &.{},
    /// Exit status after results render; a linter sets .failure when it found problems.
    status: Exit = .success,
    /// Positional arguments for the running command, after defaults apply.
    arguments: []const []const u8 = &.{},

    pub fn fail(self: *Context, code: Exit, message: []const u8, hint: []const u8) error{UserFailure} {
        self.failure = .{ .code = if (code == .success) .failure else code, .message = message, .hint = hint };
        return error.UserFailure;
    }
    fn invalidOption(self: *Context, index: usize, option: Option, expectation: []const u8) error{UserFailure} {
        const source = if (index < self.sources.len) self.sources[index] else .command_line;
        const code: Exit = switch (source) {
            .command_line => .usage,
            .default => .internal,
            else => .config,
        };
        const location = switch (source) {
            .command_line => "the command line",
            .environment => option.info.env orelse "the environment",
            .project => "project configuration",
            .user => "user configuration",
            .system => "system configuration",
            .default => "the application's default",
        };
        const message = std.fmt.allocPrint(self.allocator, "--{s} {s} The value came from {s}.", .{ option.info.name, expectation, location }) catch "Invalid option value.";
        const hint = std.fmt.allocPrint(self.allocator, "Correct {s}, or pass --{s} {s}. See --help for allowed values.", .{ location, option.info.name, option.info.example orelse option.default orelse if (option.choices.len > 0) option.choices[0] else "<value>" }) catch "Correct the option value; see --help.";
        return self.fail(code, message, hint);
    }
    pub fn checkCancelled(self: *Context) error{Cancelled}!void {
        if (self.runtime.hooks.cancelled) |probe| if (probe(self.runtime.hooks.state)) return error.Cancelled;
    }
    pub fn diagnostic(self: *Context, message: []const u8) !void {
        const terminal = self.console(self.runtime.err);
        try terminal.print(try safeText(self.allocator, message));
        try terminal.flush();
    }
    /// Static progress snapshots: deliberately no cursor movement or animations in v0.1.
    pub fn progress(self: *Context, label: []const u8, completed: u64, total: u64) !void {
        try self.checkCancelled();
        if (self.quiet) return;
        if (self.runtime.err.capabilities.interactive and self.runtime.err.capabilities.width >= 20) {
            try self.console(self.runtime.err).progress(.{ .label = try safeText(self.allocator, label), .completed = completed, .total = total, .style = self.theme.success });
        } else {
            try self.runtime.err.writer.print("{s}: {d}/{d}\n", .{ try safeText(self.allocator, label), completed, total });
        }
        try self.runtime.err.writer.flush();
    }
    pub fn ask(self: *Context, question: []const u8, supply_hint: []const u8) ![]const u8 {
        try self.checkCancelled();
        if (self.no_input or !self.runtime.stdin_tty or self.runtime.read_line == null)
            return self.fail(.usage, "Input is required; prompting is unavailable.", supply_hint);
        if (self.runtime.err.capabilities.interactive and self.runtime.err.capabilities.width >= 32) {
            const panel: presentation.Panel = .{ .console = self.console(self.runtime.err), .theme = self.theme };
            try panel.begin("Input required");
            try panel.text(try safeText(self.allocator, question), self.theme.value);
            try panel.end();
            try self.console(self.runtime.err).styled("> ", self.theme.option);
        } else try self.runtime.err.writer.print("{s} ", .{try safeText(self.allocator, question)});
        try self.runtime.err.writer.flush();
        const answer = try self.runtime.read_line.?(self);
        try self.checkCancelled();
        return answer;
    }
    fn console(self: *Context, stream: Stream) zrich.Console {
        return .{ .writer = stream.writer, .allocator = self.allocator, .options = stream.capabilities };
    }
};

pub const OptionInfo = struct {
    name: []const u8,
    help: []const u8,
    short: ?u8 = null,
    example: ?[]const u8 = null,
    /// A display name such as PATH; used only in help.
    metavar: ?[]const u8 = null,
    help_panel: []const u8 = "Options",
    env: ?[]const u8 = null,
    prompt: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
};
pub const Kind = enum { string, boolean, integer, number, choice };
pub const Option = struct { info: OptionInfo, kind: Kind, required: bool, default: ?[]const u8, choices: []const []const u8 = &.{} };
pub const Field = struct { name: []const u8, kind: Kind, nullable: bool };
/// Positional arguments, bound to the Options field of the same name, typed []const []const u8.
pub const Positional = struct {
    name: []const u8,
    help: []const u8,
    /// A display name such as PATH; used in usage and help.
    metavar: []const u8 = "ARG",
    min: usize = 0,
    /// Used when none are given on the command line.
    default: []const []const u8 = &.{},
};
pub const CommandSpec = struct {
    name: []const u8,
    description: []const u8,
    examples: []const []const u8 = &.{},
    help_panel: []const u8 = "Commands",
    result_title: []const u8 = "Result",
    options: []const OptionInfo = &.{},
    positional: ?Positional = null,
    /// The application promises that --yes is an appropriate confirmation policy.
    destructive: ?[]const u8 = null,
};
pub const Command = struct {
    spec: CommandSpec,
    options: []const Option,
    schema: []const Field,
    supports_dry_run: bool,
    invoke: *const fn (*Context, []const ?[]const u8, bool, bool) anyerror!void,
    fn hasPrompts(self: Command) bool {
        if (self.spec.destructive != null) return true;
        for (self.options) |o| if (o.info.prompt) return true;
        return false;
    }
};

// Reflection changed on Zig main; keep the compatibility boundary in one place.
const StructField = struct {
    name: []const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,
    fn defaultValue(comptime self: @This()) ?self.type {
        const ptr: *const self.type = @ptrCast(@alignCast(self.default_value_ptr orelse return null));
        return ptr.*;
    }
};
fn structFields(comptime T: type) [std.meta.fieldNames(T).len]StructField {
    const info = @typeInfo(T).@"struct";
    var result: [std.meta.fieldNames(T).len]StructField = undefined;
    for (std.meta.fieldNames(T), 0..) |name, i| {
        result[i] = .{ .name = name, .type = @TypeOf(@field(@as(T, undefined), name)), .default_value_ptr = if (@hasField(@TypeOf(info), "field_attrs")) info.field_attrs[i].default_value_ptr else info.fields[i].default_value_ptr };
    }
    return result;
}
fn baseType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}
fn kindOf(comptime T: type) Kind {
    const B = baseType(T);
    if (B == []const u8) return .string;
    return switch (@typeInfo(B)) {
        .bool => .boolean,
        .int => .integer,
        .float => .number,
        .@"enum" => .choice,
        else => @compileError("zcli supports strings, bools, integers, floats, enums, and optional scalars"),
    };
}
fn defaultText(comptime value: anytype) ?[]const u8 {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .optional) return if (value) |v| defaultText(v) else null;
    if (T == []const u8) return value;
    return switch (@typeInfo(T)) {
        .bool => if (value) "true" else "false",
        .@"enum" => @tagName(value),
        .int, .float => std.fmt.comptimePrint("{d}", .{value}),
        else => unreachable,
    };
}
fn choicesOf(comptime T: type) []const []const u8 {
    if (@typeInfo(baseType(T)) != .@"enum") return &.{};
    const fs = std.meta.fieldNames(baseType(T));
    var names: [fs.len][]const u8 = undefined;
    for (fs, 0..) |f, i| names[i] = f;
    const result = names;
    return &result;
}
fn optionInfo(comptime spec: CommandSpec, comptime field: []const u8) OptionInfo {
    for (spec.options) |info| if (eql(u8, info.name, field)) return info;
    @compileError("Each Options field needs matching OptionInfo: " ++ field);
}
fn validName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}
const reserved = [_][]const u8{ "help", "version", "json", "plain", "no-color", "quiet", "no-input", "dry-run", "yes" };

/// Only Row fields become public output. Return a slice allocated from ctx.allocator.
/// Options fields are flag names (quoted Zig identifiers allow hyphens).
pub fn command(comptime Options: type, comptime Row: type, comptime spec: CommandSpec, comptime handlers: struct {
    run: *const fn (*Context, Options) anyerror![]const Row,
    dry_run: ?*const fn (*Context, Options) anyerror![]const Row = null,
    /// Replaces the default table in human mode only; --plain and --json stay framework contracts.
    human: ?*const fn (*Context, []const Row) anyerror!void = null,
}) Command {
    const Impl = struct {
        const all_fields = structFields(Options);
        const of = blk: {
            const name = if (spec.positional) |p| p.name else break :blk all_fields;
            if (!validName(name)) @compileError("Invalid positional name");
            if (spec.positional.?.min > 0 and spec.positional.?.default.len > 0) @compileError("A positional with defaults cannot also be required");
            var result: [all_fields.len - 1]StructField = undefined;
            var n: usize = 0;
            var found = false;
            for (all_fields) |f| {
                if (eql(u8, f.name, name)) {
                    if (f.type != []const []const u8) @compileError("The positional field must be []const []const u8: " ++ name);
                    found = true;
                    continue;
                }
                if (n == result.len) @compileError("Options needs a field for the positional: " ++ name);
                result[n] = f;
                n += 1;
            }
            if (!found) @compileError("Options needs a field for the positional: " ++ name);
            break :blk result;
        };
        const rf = structFields(Row);
        const options = blk: {
            if (!validName(spec.name) or eql(u8, spec.name, "help")) @compileError("Invalid command name");
            if (spec.options.len != of.len) @compileError("OptionInfo must describe every Options field exactly once");
            var result: [of.len]Option = undefined;
            for (of, 0..) |f, i| {
                const info = optionInfo(spec, f.name);
                if (!validName(info.name)) @compileError("Invalid option name");
                for (reserved) |name| if (eql(u8, info.name, name)) @compileError("Reserved option name");
                if (info.short) |s| {
                    if (!std.ascii.isAlphabetic(s) or s == 'h' or s == 'q' or s == 'n') @compileError("Reserved or invalid short option");
                    for (result[0..i]) |o| if (o.info.short == s) @compileError("Duplicate short option");
                }
                const k = kindOf(f.type);
                if (info.min != null or info.max != null) {
                    if (k != .integer and k != .number) @compileError("Ranges require a number");
                    if (info.min != null and info.max != null and info.min.? > info.max.?) @compileError("Invalid option range");
                }
                result[i] = .{ .info = info, .kind = k, .required = f.defaultValue() == null and @typeInfo(f.type) != .optional, .default = if (f.defaultValue()) |v| defaultText(v) else null, .choices = choicesOf(f.type) };
            }
            break :blk result;
        };
        const schema = blk: {
            if (rf.len == 0) @compileError("Public result records must have fields");
            var result: [rf.len]Field = undefined;
            for (rf, 0..) |f, i| {
                if (!validName(f.name)) @compileError("Invalid public field name");
                result[i] = .{ .name = f.name, .kind = kindOf(f.type), .nullable = @typeInfo(f.type) == .optional };
            }
            break :blk result;
        };
        fn invoke(ctx: *Context, raw: []const ?[]const u8, dry_run: bool, yes: bool) !void {
            var opts: Options = undefined;
            inline for (of, 0..) |f, i| {
                var value = raw[i];
                const info = options[i].info;
                const hint = try std.fmt.allocPrint(ctx.allocator, "Supply --{s}{s}.", .{ f.name, if (kindOf(f.type) == .boolean) "" else try std.fmt.allocPrint(ctx.allocator, " {s}", .{info.example orelse "<value>"}) });
                if (value == null and options[i].required and info.prompt) value = try ctx.ask(info.help, hint);
                if (value) |v| {
                    @field(opts, f.name) = parseValue(f.type, v) catch return ctx.invalidOption(i, options[i], switch (comptime kindOf(f.type)) {
                        .integer => "must be a whole number that fits its declared type.",
                        .number => "must be a finite number.",
                        .boolean => "must be true or false.",
                        .string => "must be valid UTF-8 text.",
                        .choice => try std.fmt.allocPrint(ctx.allocator, "must be one of: {s}.", .{try std.mem.join(ctx.allocator, ", ", options[i].choices)}),
                    });
                    if (comptime kindOf(f.type) == .integer or kindOf(f.type) == .number) {
                        const number: f128 = if (comptime kindOf(f.type) == .integer) @floatFromInt(unwrap(@field(opts, f.name))) else @floatCast(unwrap(@field(opts, f.name)));
                        if ((info.min != null and number < info.min.?) or (info.max != null and number > info.max.?))
                            return ctx.invalidOption(i, options[i], if (info.min != null and info.max != null)
                                try std.fmt.allocPrint(ctx.allocator, "must be between {d} and {d}.", .{ info.min.?, info.max.? })
                            else if (info.min) |min| try std.fmt.allocPrint(ctx.allocator, "must be at least {d}.", .{min}) else try std.fmt.allocPrint(ctx.allocator, "must be at most {d}.", .{info.max.?}));
                    }
                } else if (comptime f.defaultValue() != null) {
                    @field(opts, f.name) = f.defaultValue().?;
                } else if (@typeInfo(f.type) == .optional) {
                    @field(opts, f.name) = null;
                } else return ctx.fail(.usage, try std.fmt.allocPrint(ctx.allocator, "Missing required option --{s}.", .{f.name}), hint);
            }
            if (spec.positional) |p| @field(opts, p.name) = ctx.arguments;
            try ctx.checkCancelled();
            if (!dry_run and spec.destructive != null and !yes) {
                const answer = try ctx.ask(spec.destructive.? ++ " Type yes to continue:", "Review the operation, then pass --yes to confirm explicitly.");
                if (!eql(u8, answer, "yes")) return ctx.fail(.usage, "Operation not confirmed.", "Pass --yes only after reviewing the operation.");
            }
            const rows = if (dry_run) try handlers.dry_run.?(ctx, opts) else try handlers.run(ctx, opts);
            try ctx.checkCancelled();
            if (handlers.human != null and ctx.format == .human) return handlers.human.?(ctx, rows);
            try render(Row, ctx, rows);
        }
    };
    return .{ .spec = spec, .options = &Impl.options, .schema = &Impl.schema, .supports_dry_run = handlers.dry_run != null, .invoke = Impl.invoke };
}
fn unwrap(value: anytype) baseType(@TypeOf(value)) {
    return if (@typeInfo(@TypeOf(value)) == .optional) value.? else value;
}
fn parseValue(comptime T: type, raw: []const u8) !T {
    if (@typeInfo(T) == .optional) return try parseValue(baseType(T), raw);
    if (T == []const u8) {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidValue;
        return raw;
    }
    return switch (@typeInfo(T)) {
        .bool => if (eql(u8, raw, "true")) true else if (eql(u8, raw, "false")) false else error.InvalidValue,
        .int => std.fmt.parseInt(T, raw, 10),
        .float => blk: {
            const v = try std.fmt.parseFloat(T, raw);
            if (!std.math.isFinite(v)) return error.InvalidValue;
            break :blk v;
        },
        .@"enum" => std.meta.stringToEnum(T, raw) orelse error.InvalidValue,
        else => unreachable,
    };
}
const safeText = presentation.literal;
fn validateScalar(value: anytype) !void {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .optional) {
        if (value) |v| try validateScalar(v);
        return;
    }
    if (T == []const u8) {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidResult;
    }
    if (@typeInfo(T) == .float) {
        if (!std.math.isFinite(value)) return error.InvalidResult;
    }
}
fn render(comptime Row: type, ctx: *Context, rows: []const Row) !void {
    const fields = structFields(Row);
    for (rows) |row| inline for (fields) |f| try validateScalar(@field(row, f.name));
    var buffer: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &buffer.writer;
    switch (ctx.format) {
        .json => {
            try std.json.Stringify.value(rows, .{}, w);
            try w.writeByte('\n');
        },
        .plain => for (rows) |row| {
            inline for (fields, 0..) |f, i| {
                if (i != 0) try w.writeByte('\t');
                try w.writeAll(f.name ++ "=");
                try std.json.Stringify.value(@field(row, f.name), .{}, w);
            }
            try w.writeByte('\n');
        },
        .human => {
            var cols: [fields.len]zrich.Column = undefined;
            inline for (fields, 0..) |f, i| cols[i] = .{ .header = f.name };
            const cells = try ctx.allocator.alloc([]const zrich.Cell, rows.len);
            for (rows, 0..) |row, ri| {
                const row_cells = try ctx.allocator.alloc(zrich.Cell, fields.len);
                inline for (fields, 0..) |f, i| {
                    var value: std.Io.Writer.Allocating = .init(ctx.allocator);
                    if (@TypeOf(@field(row, f.name)) == []const u8) {
                        try value.writer.writeAll(try safeText(ctx.allocator, @field(row, f.name)));
                    } else try std.json.Stringify.value(@field(row, f.name), .{}, &value.writer);
                    row_cells[i] = .{ .text = value.written() };
                }
                cells[ri] = row_cells;
            }
            const console: zrich.Console = .{ .writer = w, .allocator = ctx.allocator, .options = ctx.runtime.out.capabilities };
            if (rows.len <= 1 and console.options.width >= 32) {
                const panel: presentation.Panel = .{ .console = console, .theme = ctx.theme };
                try panel.begin(try safeText(ctx.allocator, ctx.result_title));
                if (rows.len == 0) {
                    try panel.text("No results.", ctx.theme.muted);
                } else {
                    var label_width: usize = 0;
                    inline for (fields) |f| label_width = @max(label_width, f.name.len);
                    label_width = @min(label_width, panel.inner() / 3);
                    inline for (fields, 0..) |f, i| {
                        try panel.row(&.{
                            .{ .text = f.name, .style = ctx.theme.option },
                            .{ .text = cells[0][i].text, .style = if (comptime kindOf(f.type) == .integer or kindOf(f.type) == .number) ctx.theme.value else .{} },
                        }, &.{ label_width, panel.inner() - label_width - 2 });
                    }
                }
                try panel.end();
                try ctx.runtime.out.writer.writeAll(buffer.written());
                return;
            }
            // Very narrow terminals use stable records instead of failing table layout.
            if (console.options.width < fields.len * 4 + 1) {
                const saved = ctx.format;
                ctx.format = .plain;
                defer ctx.format = saved;
                return render(Row, ctx, rows);
            }
            console.table(.{ .columns = &cols, .rows = cells, .header_style = ctx.theme.option, .border_style = ctx.theme.border }) catch |err| switch (err) {
                error.InvalidWidth, error.CharacterTooWide => {
                    const saved = ctx.format;
                    ctx.format = .plain;
                    defer ctx.format = saved;
                    return render(Row, ctx, rows);
                },
                else => return err,
            };
        },
    }
    try ctx.runtime.out.writer.writeAll(buffer.written());
}

pub const App = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    commands: []const Command,
    support: ?[]const u8 = null,
    theme: Theme = .{},

    /// Args exclude argv[0]. All allocations and result slices live until this call returns.
    pub fn run(self: App, allocator: Allocator, args: []const []const u8, runtime: Runtime) Exit {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx: Context = .{ .theme = self.theme, .allocator = arena.allocator(), .runtime = runtime, .format = if (runtime.out.capabilities.interactive) .human else .plain };
        // Environment policy still applies to injected capabilities.
        const no_color = if (runtime.environment.get("NO_COLOR")) |v| v.len != 0 else false;
        const dumb = if (runtime.environment.get("TERM")) |v| eql(u8, v, "dumb") else false;
        if (no_color or dumb) {
            ctx.runtime.out.capabilities.color = false;
            ctx.runtime.err.capabilities.color = false;
        }
        if (dumb) {
            ctx.runtime.out.capabilities.interactive = false;
            ctx.runtime.err.capabilities.interactive = false;
            ctx.format = .plain;
        }
        const code = self.dispatch(&ctx, args) catch |err| blk: {
            const failure: Failure = ctx.failure orelse switch (err) {
                error.Cancelled => .{ .code = .cancelled, .message = "Cancelled.", .hint = "No further work will be started." },
                error.WriteFailed => .{ .code = .io, .message = "Could not write output.", .hint = "Check the output destination or pipe." },
                else => .{ .code = .internal, .message = "The application could not complete the request.", .hint = self.support orelse "Report this failure to the application maintainer." },
            };
            self.report(&ctx, failure) catch {};
            break :blk failure.code;
        };
        ctx.runtime.out.writer.flush() catch return .io;
        ctx.runtime.err.writer.flush() catch return .io;
        return code;
    }
    fn report(_: App, ctx: *Context, failure: Failure) !void {
        const message = try safeText(ctx.allocator, failure.message);
        const hint = try safeText(ctx.allocator, failure.hint);
        if (ctx.runtime.err.capabilities.interactive and ctx.runtime.err.capabilities.width >= 32) {
            var buffer: std.Io.Writer.Allocating = .init(ctx.allocator);
            var console = ctx.console(ctx.runtime.err);
            console.writer = &buffer.writer;
            var theme = ctx.theme;
            theme.border = theme.error_border;
            theme.heading = theme.required;
            const panel: presentation.Panel = .{ .console = console, .theme = theme };
            try panel.begin(if (failure.code == .cancelled) "Cancelled" else "Error");
            try panel.text(message, ctx.theme.heading);
            if (hint.len != 0) {
                try panel.text("", .{});
                try panel.text(hint, .{});
            }
            try panel.end();
            try ctx.runtime.err.writer.writeAll(buffer.written());
        } else {
            try ctx.console(ctx.runtime.err).styled(message, ctx.theme.required);
            try ctx.runtime.err.writer.writeByte('\n');
            if (hint.len != 0) try ctx.diagnostic(hint);
        }
    }
    fn find(self: App, name: []const u8) ?*const Command {
        for (self.commands) |*cmd| if (eql(u8, cmd.spec.name, name)) return cmd;
        return null;
    }
    fn dispatch(self: App, ctx: *Context, args: []const []const u8) !Exit {
        // This is an intent scan, not a second parser: help overrides malformed arguments.
        // A literal -- terminates the scan, so data named --help remains data.
        var want_help = args.len == 0;
        var want_version = false;
        var help_cmd: ?*const Command = null;
        for (args) |arg| {
            if (eql(u8, arg, "--")) break;
            if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) want_help = true;
            if (eql(u8, arg, "--version")) want_version = true;
            if (eql(u8, arg, "--plain") or eql(u8, arg, "--json")) {
                ctx.format = .plain;
                ctx.runtime.out.capabilities.color = false;
            }
            if (eql(u8, arg, "--no-color")) {
                ctx.runtime.out.capabilities.color = false;
                ctx.runtime.err.capabilities.color = false;
            }
        }
        // Only the first positional command is a help target; skip known option values.
        var scan: usize = 0;
        while (scan < args.len) : (scan += 1) {
            const arg = args[scan];
            if (eql(u8, arg, "--")) break;
            if (eql(u8, arg, "help") and scan == 0) {
                want_help = true;
                if (args.len > 1) help_cmd = self.find(args[1]);
                break;
            }
            if (self.find(arg)) |cmd| {
                help_cmd = cmd;
                break;
            }
            if (arg.len == 0 or arg[0] != '-') break;
        }
        // Help in a short-option group also bypasses parsing and execution.
        // Stop at a value-taking short option so -phelp is a path, not help.
        for (args) |arg| {
            if (eql(u8, arg, "--")) break;
            if (arg.len < 3 or arg[0] != '-' or arg[1] == '-') continue;
            for (arg[1..]) |short| {
                if (short == 'h') {
                    want_help = true;
                    break;
                }
                if (short == '=') break;
                if (help_cmd) |cmd| {
                    var takes_value = false;
                    for (cmd.options) |o| if (o.info.short == short and o.kind != .boolean) {
                        takes_value = true;
                    };
                    if (takes_value) break;
                }
            }
        }
        if (want_help) {
            try self.help(ctx, help_cmd);
            return .success;
        }
        if (want_version) {
            try ctx.runtime.out.writer.print("{s} {s}\n", .{ self.name, self.version });
            return .success;
        }

        // Only implemented global switches may precede the command. Parse those through the same backend too.
        var prefix_iter: parser_backend.SliceIterator = .{ .args = args };
        var diag: parser_backend.Diagnostic = .{};
        const prefix_params = baseParams();
        var prefix: parser_backend.Parser = .{ .params = &prefix_params, .iter = &prefix_iter, .diagnostic = &diag };
        var selected: ?*const Command = null;
        var prefix_flags: [base_count]bool = @splat(false);
        while (prefix.next() catch |err| return self.parseError(ctx, diag, err)) |arg| {
            if (arg.param.id == positional_id) {
                selected = self.find(arg.value.?);
                break;
            }
            prefix_flags[arg.param.id] = true;
        }
        const cmd = selected orelse return ctx.fail(.usage, if (prefix_iter.index > 0) try std.fmt.allocPrint(ctx.allocator, "Unknown command '{s}'.", .{args[prefix_iter.index - 1]}) else "A command is required.", try std.fmt.allocPrint(ctx.allocator, "Run '{s} --help' to list commands.", .{self.name}));
        var params: std.ArrayList(parser_backend.Param) = .empty;
        for (base_params) |p| try params.append(ctx.allocator, p);
        if (cmd.hasPrompts()) try params.append(ctx.allocator, .{ .id = no_input_id, .names = .{ .long = "no-input" }, .takes_value = .none });
        if (cmd.supports_dry_run) try params.append(ctx.allocator, .{ .id = dry_run_id, .names = .{ .long = "dry-run", .short = 'n' }, .takes_value = .none });
        if (cmd.spec.destructive != null) try params.append(ctx.allocator, .{ .id = yes_id, .names = .{ .long = "yes" }, .takes_value = .none });
        for (cmd.options, 0..) |o, i| try params.append(ctx.allocator, .{ .id = option_start + i, .names = .{ .long = o.info.name, .short = o.info.short }, .takes_value = if (o.kind == .boolean) .boolean else .one });
        try params.append(ctx.allocator, .{ .id = positional_id, .names = .{}, .takes_value = .many });
        var iter: parser_backend.SliceIterator = .{ .args = args[prefix_iter.index..] };
        var parser: parser_backend.Parser = .{ .params = params.items, .iter = &iter, .diagnostic = &diag };
        const raw = try ctx.allocator.alloc(?[]const u8, cmd.options.len);
        @memset(raw, null);
        var flags: [option_start]bool = @splat(false);
        @memcpy(flags[0..base_count], &prefix_flags);
        var arguments: std.ArrayList([]const u8) = .empty;
        while (parser.next() catch |err| return self.parseError(ctx, diag, err)) |arg| {
            const id = arg.param.id;
            if (id == positional_id) {
                if (cmd.spec.positional == null) return ctx.fail(.usage, try std.fmt.allocPrint(ctx.allocator, "Unexpected argument '{s}'.", .{arg.value.?}), "Use the named options shown in --help.");
                try arguments.append(ctx.allocator, arg.value.?);
                continue;
            }
            if (id < option_start) {
                flags[id] = true;
                continue;
            }
            if (raw[id - option_start] != null) return ctx.fail(.usage, try std.fmt.allocPrint(ctx.allocator, "--{s} was supplied more than once.", .{cmd.options[id - option_start].info.name}), "Supply each option once; flags override environment and configuration.");
            raw[id - option_start] = arg.value orelse "true";
        }
        if (cmd.spec.positional) |p| {
            if (arguments.items.len < p.min) return ctx.fail(.usage, try std.fmt.allocPrint(ctx.allocator, "{s} needs at least {d} {s}.", .{ cmd.spec.name, p.min, p.metavar }), try std.fmt.allocPrint(ctx.allocator, "Supply {s} after the command; see --help.", .{p.metavar}));
            ctx.arguments = if (arguments.items.len == 0) p.default else arguments.items;
        }
        if (flags[json_id] and flags[plain_id]) return ctx.fail(.usage, "--json and --plain cannot be combined.", "Choose one output format.");
        if (flags[json_id]) ctx.format = .json;
        if (flags[plain_id]) ctx.format = .plain;
        if (flags[no_color_id] or ctx.format != .human) ctx.runtime.out.capabilities.color = false;
        if (flags[no_color_id]) ctx.runtime.err.capabilities.color = false;
        ctx.no_input = flags[no_input_id];
        ctx.quiet = flags[quiet_id];
        var exit_code: Exit = .internal;
        defer if (ctx.runtime.hooks.cleanup) |cleanup| cleanup(ctx, exit_code);
        self.execute(ctx, cmd, raw, flags[dry_run_id], flags[yes_id]) catch |err| {
            exit_code = if (ctx.failure) |f| f.code else switch (err) {
                error.Cancelled => .cancelled,
                error.WriteFailed => .io,
                else => .internal,
            };
            if (err == error.Cancelled) {
                ctx.diagnostic("Cancellation requested; cleaning up.") catch {};
                if (ctx.runtime.hooks.on_cancel) |on_cancel| on_cancel(ctx);
            }
            return err;
        };
        exit_code = ctx.status;
        return ctx.status;
    }
    fn execute(_: App, ctx: *Context, cmd: *const Command, raw: []?[]const u8, dry_run: bool, yes: bool) !void {
        try ctx.checkCancelled();
        const sources = try ctx.allocator.alloc(Source, cmd.options.len);
        @memset(sources, .command_line);
        ctx.sources = sources;
        const config = if (ctx.runtime.load_config) |load_config| try load_config(ctx, cmd.spec.name) else ctx.runtime.config;
        for ([_][]const Pair{ config.system, config.user, config.project }, [_][]const u8{ "system", "user", "project" }) |layer, layer_name| {
            for (layer, 0..) |pair, pi| {
                var known = false;
                for (cmd.options) |o| {
                    if (eql(u8, pair.key, o.info.name)) known = true;
                }
                if (!known) {
                    return ctx.fail(.config, try std.fmt.allocPrint(ctx.allocator, "Unknown key '{s}' in {s} configuration.", .{ pair.key, layer_name }), try std.fmt.allocPrint(ctx.allocator, "Remove '{s}' or consult --help for supported options.", .{pair.key}));
                }
                for (layer[0..pi]) |prior| if (eql(u8, prior.key, pair.key)) {
                    return ctx.fail(.config, try std.fmt.allocPrint(ctx.allocator, "Key '{s}' appears more than once in {s} configuration.", .{ pair.key, layer_name }), "Keep each key only once per configuration layer.");
                };
            }
        }
        for (cmd.options, 0..) |o, i| {
            if (raw[i] != null) continue;
            if (o.info.env) |env_name| {
                if (ctx.runtime.environment.get(env_name)) |v| {
                    raw[i] = v;
                    sources[i] = .environment;
                    continue;
                }
            }
            for ([_][]const Pair{ config.project, config.user, config.system }, [_]Source{ .project, .user, .system }) |layer, source| {
                for (layer) |pair| if (eql(u8, pair.key, o.info.name)) {
                    raw[i] = pair.value;
                    sources[i] = source;
                    break;
                };
                if (raw[i] != null) break;
            }
            if (raw[i] == null) {
                raw[i] = o.default;
                sources[i] = .default;
            }
        }
        ctx.result_title = cmd.spec.result_title;
        try cmd.invoke(ctx, raw, dry_run, yes);
    }
    fn parseError(_: App, ctx: *Context, diag: parser_backend.Diagnostic, err: anyerror) error{UserFailure} {
        const name = if (diag.short) |short| std.fmt.allocPrint(ctx.allocator, "-{c}", .{short}) catch "option" else diag.argument;
        const message = std.fmt.allocPrint(ctx.allocator, "{s} {s}.", .{ name, switch (err) {
            error.MissingValue => "needs a value",
            error.DoesntTakeValue => "does not take a value",
            else => "is not a recognized option or command",
        } }) catch "Invalid arguments.";
        return ctx.fail(.usage, message, "Run --help for supported options and examples.");
    }
    fn richHelp(self: App, ctx: *Context, cmd: ?*const Command) !void {
        try @import("help.zig").render(self, ctx, cmd);
    }
    fn help(self: App, ctx: *Context, cmd: ?*const Command) !void {
        if (ctx.format == .human and ctx.runtime.out.capabilities.interactive and ctx.runtime.out.capabilities.width >= 32) {
            var buffer: std.Io.Writer.Allocating = .init(ctx.allocator);
            var rich_ctx = ctx.*;
            rich_ctx.runtime.out.writer = &buffer.writer;
            try self.richHelp(&rich_ctx, cmd);
            try ctx.runtime.out.writer.writeAll(buffer.written());
        } else try self.plainHelp(ctx, cmd);
    }
    fn plainHelp(self: App, ctx: *Context, cmd: ?*const Command) !void {
        const w = ctx.runtime.out.writer;
        try ctx.console(ctx.runtime.out).styled(self.name, .{ .bold = true, .fg = .{ .named = .cyan } });
        try w.print(" — {s}\n\n", .{if (cmd) |c| c.spec.description else self.description});
        if (cmd) |c| {
            try w.print("Usage: {s} {s} [options]{s}\n", .{ self.name, c.spec.name, try positionalUsage(ctx.allocator, c.spec.positional) });
            if (c.spec.positional) |p| {
                try w.print("\nArguments:\n  {s}  {s}", .{ p.metavar, p.help });
                if (p.default.len > 0) try w.print(" [default: {s}]", .{try std.mem.join(ctx.allocator, " ", p.default)});
                try w.writeByte('\n');
            }
            if (c.spec.examples.len != 0) {
                try w.writeAll("\nExamples:\n");
                for (c.spec.examples) |example| try w.print("  {s}\n", .{example});
            }
            try w.writeAll("\nOptions:\n");
            for (c.options) |o| {
                if (o.info.short) |s| try w.print("  -{c}, ", .{s}) else try w.writeAll("      ");
                try w.print("--{s}{s}  {s}", .{ o.info.name, if (o.kind == .boolean) "[=true|false]" else " <value>", o.info.help });
                if (o.required) try w.writeAll(" (required)");
                if (o.default) |d| try w.print(" [default: {s}]", .{d});
                if (o.info.env) |e| try w.print(" [env: {s}]", .{e});
                if (o.choices.len != 0) {
                    try w.writeAll(" [choices:");
                    for (o.choices) |choice| try w.print(" {s}", .{choice});
                    try w.writeByte(']');
                }
                if (o.info.min) |min| try w.print(" [min: {d}]", .{min});
                if (o.info.max) |max| try w.print(" [max: {d}]", .{max});
                try w.writeByte('\n');
            }
            if (c.hasPrompts()) try w.writeAll("      --no-input  Disable prompting\n");
            if (c.supports_dry_run) try w.writeAll("  -n, --dry-run  Run the application's preview handler\n");
            if (c.spec.destructive != null) try w.writeAll("      --yes  Explicitly confirm this operation\n");
        } else {
            try w.print("Usage: {s} <command> [options]\n\nCommands:\n", .{self.name});
            for (self.commands) |c| try w.print("  {s}  {s}\n", .{ c.spec.name, c.spec.description });
            try w.print("\nRun '{s} help <command>' for examples and options.\n\nOptions:\n", .{self.name});
        }
        try w.writeAll("  -h, --help  Show help without running a handler\n      --version  Show version\n      --json  Emit a JSON array of public records\n      --plain  Emit stable unwrapped key=JSON records\n      --no-color  Disable color on both streams\n  -q, --quiet  Suppress progress\n");
        if (cmd) |c| {
            try w.writeAll("\nPublic result fields:\n");
            for (c.schema) |f| try w.print("  {s}: {s}{s}\n", .{ f.name, @tagName(f.kind), if (f.nullable) "?" else "" });
        }
        if (self.support) |s| try w.print("\nHelp and feedback: {s}\n", .{s});
    }
};
/// " PATH...", " [PATH...]" or "" for a command's usage line.
pub fn positionalUsage(allocator: Allocator, positional: ?Positional) ![]const u8 {
    const p = positional orelse return "";
    return if (p.min > 0) std.fmt.allocPrint(allocator, " {s}...", .{p.metavar}) else std.fmt.allocPrint(allocator, " [{s}...]", .{p.metavar});
}
const help_id = 0;
const version_id = 1;
const json_id = 2;
const plain_id = 3;
const no_color_id = 4;
const quiet_id = 5;
const base_count = 6;
const no_input_id = 6;
const dry_run_id = 7;
const yes_id = 8;
const option_start = 9;
const positional_id = std.math.maxInt(usize);
const base_params = [_]parser_backend.Param{
    .{ .id = help_id, .names = .{ .long = "help", .short = 'h' }, .takes_value = .none },
    .{ .id = version_id, .names = .{ .long = "version" }, .takes_value = .none },
    .{ .id = json_id, .names = .{ .long = "json" }, .takes_value = .none },
    .{ .id = plain_id, .names = .{ .long = "plain" }, .takes_value = .none },
    .{ .id = no_color_id, .names = .{ .long = "no-color" }, .takes_value = .none },
    .{ .id = quiet_id, .names = .{ .long = "quiet", .short = 'q' }, .takes_value = .none },
};
fn baseParams() [base_count + 1]parser_backend.Param {
    return base_params ++ .{parser_backend.Param{ .id = positional_id, .names = .{}, .takes_value = .many }};
}

test {
    _ = @import("tests.zig");
}

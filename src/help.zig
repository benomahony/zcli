//! Declarative help arranged like Typer's Rich help: panels and styled columns.
const std = @import("std");
const cli = @import("root.zig");
const p = @import("presentation.zig");
const eql = std.mem.eql;
const Entry = struct {
    name: []const u8,
    short: ?u8 = null,
    metavar: []const u8 = "",
    help: []const u8,
    details: []const u8 = "",
    required: bool = false,
};
const output_entries = [_]Entry{
    // .{ .name = "json", .help = "Print public results as a JSON array." },
    .{ .name = "plain", .help = "Print stable records without layout or wrapping." },
    .{ .name = "no-color", .help = "Disable color on both output streams." },
    .{ .name = "quiet", .short = 'q', .help = "Suppress progress messages." },
};
const help_entries = [_]Entry{
    .{ .name = "help", .short = 'h', .help = "Show this help and exit." },
    .{ .name = "version", .help = "Show the application version and exit." },
};

pub fn render(app: cli.App, ctx: *cli.Context, cmd: ?*const cli.Command) !void {
    const console: cli.zrich.Console = .{ .allocator = ctx.allocator, .writer = ctx.runtime.out.writer, .options = ctx.runtime.out.capabilities };
    const panel: p.Panel = .{ .console = console, .theme = ctx.theme };
    const usage = if (cmd) |c| try std.fmt.allocPrint(ctx.allocator, "Usage: {s} {s} [OPTIONS]{s}", .{ app.name, c.spec.name, try cli.positionalUsage(ctx.allocator, c.spec.positional) }) else try std.fmt.allocPrint(ctx.allocator, "Usage: {s} COMMAND [OPTIONS]", .{app.name});
    try console.writer.writeByte('\n');
    try p.paragraph(console, try p.literal(ctx.allocator, usage), ctx.theme.heading);
    try console.writer.writeByte('\n');
    try p.paragraph(console, try p.literal(ctx.allocator, if (cmd) |c| c.spec.description else app.description), .{});
    try console.writer.writeByte('\n');
    if (cmd) |c| {
        if (c.spec.examples.len > 0) {
            try panel.begin("Examples");
            for (c.spec.examples) |example| try panel.text(try std.fmt.allocPrint(ctx.allocator, "$ {s}", .{try p.literal(ctx.allocator, example)}), ctx.theme.alias);
            try panel.end();
            try console.writer.writeByte('\n');
        }
        if (c.spec.positional) |positional| {
            try panel.begin("Arguments");
            const help = if (positional.default.len > 0) try std.fmt.allocPrint(ctx.allocator, "{s} [default: {s}]", .{ positional.help, try std.mem.join(ctx.allocator, " ", positional.default) }) else positional.help;
            const name_width = @min(@max(positional.metavar.len, 8), panel.inner() / 3);
            try panel.row(&.{
                .{ .text = try p.literal(ctx.allocator, positional.metavar), .style = ctx.theme.value },
                .{ .text = try p.literal(ctx.allocator, help) },
            }, &.{ name_width, panel.inner() - name_width - 2 });
            try panel.end();
            try console.writer.writeByte('\n');
        }
        // Group options in declaration order, retaining order within each named panel.
        for (c.options, 0..) |option, i| {
            var seen = false;
            for (c.options[0..i]) |prior| if (eql(u8, prior.info.help_panel, option.info.help_panel)) {
                seen = true;
            };
            if (seen) continue;
            var entries: std.ArrayList(Entry) = .empty;
            for (c.options) |o| {
                if (!eql(u8, o.info.help_panel, option.info.help_panel)) continue;
                var annotations: std.Io.Writer.Allocating = .init(ctx.allocator);
                const w = &annotations.writer;
                if (o.required) try w.writeAll("[required] ");
                if (o.default) |d| try w.print("[default: {s}] ", .{d});
                if (o.info.env) |e| try w.print("[env: {s}] ", .{e});
                if (o.choices.len != 0) try w.print("[choices: {s}] ", .{try std.mem.join(ctx.allocator, ", ", o.choices)});
                if (o.info.min) |v| try w.print("[min: {d}] ", .{v});
                if (o.info.max) |v| try w.print("[max: {d}] ", .{v});
                if (o.kind == .boolean) try w.writeAll("[=true|false] ");
                try entries.append(ctx.allocator, .{
                    .name = o.info.name,
                    .short = o.info.short,
                    .help = o.info.help,
                    .required = o.required,
                    .details = std.mem.trimEnd(u8, annotations.written(), " "),
                    .metavar = o.info.metavar orelse switch (o.kind) {
                        .string => "TEXT",
                        .integer => "INTEGER",
                        .number => "NUMBER",
                        .boolean => "",
                        .choice => "CHOICE",
                    },
                });
            }
            try optionPanel(ctx, panel, option.info.help_panel, entries.items);
        }
        var safety: std.ArrayList(Entry) = .empty;
        if (c.supports_dry_run) try safety.append(ctx.allocator, .{ .name = "dry-run", .short = 'n', .help = "Preview changes using the application's preview handler." });
        if (c.spec.destructive != null) try safety.append(ctx.allocator, .{ .name = "yes", .help = "Explicitly confirm this operation." });
        var prompts = c.spec.destructive != null;
        for (c.options) |o| prompts = prompts or o.info.prompt;
        if (prompts) try safety.append(ctx.allocator, .{ .name = "no-input", .help = "Disable prompting; require all input through options." });
        if (safety.items.len != 0) try optionPanel(ctx, panel, "Safety", safety.items);
    } else {
        for (app.commands, 0..) |command, i| {
            var seen = false;
            for (app.commands[0..i]) |prior| if (eql(u8, prior.spec.help_panel, command.spec.help_panel)) {
                seen = true;
            };
            if (seen) continue;
            try panel.begin(try p.literal(ctx.allocator, command.spec.help_panel));
            var names_width: usize = 8;
            for (app.commands) |c| if (eql(u8, c.spec.help_panel, command.spec.help_panel)) {
                names_width = @max(names_width, c.spec.name.len);
            };
            names_width = @min(names_width, panel.inner() / 3);
            for (app.commands) |c| {
                if (!eql(u8, c.spec.help_panel, command.spec.help_panel)) continue;
                try panel.row(&.{
                    .{ .text = try p.literal(ctx.allocator, c.spec.name), .style = ctx.theme.option },
                    .{ .text = try p.literal(ctx.allocator, c.spec.description) },
                }, &.{ names_width, panel.inner() - names_width - 2 });
            }
            try panel.end();
            try console.writer.writeByte('\n');
        }
    }
    try optionPanel(ctx, panel, "Output", &output_entries);
    try optionPanel(ctx, panel, "Help", &help_entries);
    if (cmd) |c| {
        // Keep the public record contract discoverable without another large table.
        var schema: std.Io.Writer.Allocating = .init(ctx.allocator);
        for (c.schema, 0..) |field, i| {
            if (i != 0) try schema.writer.writeAll(", ");
            try schema.writer.print("{s}: {s}{s}", .{ field.name, @tagName(field.kind), if (field.nullable) "?" else "" });
        }
        try panel.begin("Result fields");
        try panel.text(schema.written(), ctx.theme.muted);
        try panel.end();
    } else try p.paragraph(console, try std.fmt.allocPrint(ctx.allocator, "Run '{s} help COMMAND' for examples and command options.", .{try p.literal(ctx.allocator, app.name)}), ctx.theme.muted);
    if (app.support) |support| {
        try console.writer.writeByte('\n');
        try p.paragraph(console, try p.literal(ctx.allocator, support), ctx.theme.muted);
    }
    try console.writer.writeByte('\n');
}

fn optionPanel(ctx: *cli.Context, panel: p.Panel, title: []const u8, entries: []const Entry) !void {
    try panel.begin(try p.literal(ctx.allocator, title));
    var flags: usize = 10;
    var types: usize = 4;
    for (entries) |entry| {
        flags = @max(flags, entry.name.len + 2);
        types = @max(types, try cli.zrich.text.width(try p.literal(ctx.allocator, entry.metavar)));
    }
    flags = @min(flags, 24);
    types = @min(types, 12);
    const wide = panel.width() >= 76;
    for (entries) |entry| {
        const name = try std.fmt.allocPrint(ctx.allocator, "--{s}", .{entry.name});
        const alias = if (entry.short) |s| try std.fmt.allocPrint(ctx.allocator, "-{c}", .{s}) else "";
        const metavar = try p.literal(ctx.allocator, entry.metavar);
        if (wide) {
            const widths = [_]usize{ 1, flags, 2, types, panel.inner() - flags - types - 11 };
            try panel.row(&.{
                .{ .text = if (entry.required) "*" else "", .style = ctx.theme.required },
                .{ .text = name, .style = ctx.theme.option },
                .{ .text = alias, .style = ctx.theme.alias },
                .{ .text = metavar, .style = ctx.theme.value },
                .{ .text = try p.literal(ctx.allocator, entry.help) },
            }, &widths);
            if (entry.details.len != 0) try panel.row(&.{ .{}, .{}, .{}, .{}, .{ .text = try p.literal(ctx.allocator, entry.details), .style = ctx.theme.muted } }, &widths);
        } else {
            const label = try std.fmt.allocPrint(ctx.allocator, "{s}{s}{s}{s}{s}", .{ name, if (alias.len > 0) "  " else "", alias, if (metavar.len > 0) "  " else "", metavar });
            try panel.row(&.{
                .{ .text = if (entry.required) "*" else "", .style = ctx.theme.required },
                .{ .text = label, .style = ctx.theme.option },
            }, &.{ 1, panel.inner() - 3 });
            try panel.row(&.{ .{}, .{ .text = try p.literal(ctx.allocator, entry.help) } }, &.{ 1, panel.inner() - 3 });
            if (entry.details.len != 0) try panel.row(&.{ .{}, .{ .text = try p.literal(ctx.allocator, entry.details), .style = ctx.theme.muted } }, &.{ 1, panel.inner() - 3 });
        }
    }
    try panel.end();
    try panel.console.writer.writeByte('\n');
}

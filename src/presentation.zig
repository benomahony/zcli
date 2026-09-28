//! CLI layouts composed from zrich's styles, borders and Unicode text measurements.
const std = @import("std");
const rich = @import("zrich");

pub const Theme = struct {
    heading: rich.Style = .{ .bold = true },
    option: rich.Style = .{ .bold = true, .fg = .{ .named = .cyan } },
    alias: rich.Style = .{ .fg = .{ .named = .green } },
    value: rich.Style = .{ .fg = .{ .named = .yellow } },
    muted: rich.Style = .{ .dim = true },
    border: rich.Style = .{ .dim = true },
    required: rich.Style = .{ .bold = true, .fg = .{ .named = .red } },
    success: rich.Style = .{ .fg = .{ .named = .green } },
    error_border: rich.Style = .{ .fg = .{ .named = .red } },
};
pub const Cell = struct { text: []const u8 = "", style: rich.Style = .{} };

/// Prefer whitespace boundaries, retaining zrich's Unicode scalar width semantics.
const Lines = struct {
    remaining: []const u8,
    columns: usize,
    done: bool = false,
    fn next(self: *Lines) !?rich.text.Line {
        if (self.done) return null;
        var lines: rich.text.Lines = .{ .text = self.remaining, .columns = self.columns };
        var line = (try lines.next()).?;
        var consumed = lines.offset;
        if (!lines.done and consumed == line.bytes.len and consumed < self.remaining.len and self.remaining[consumed] != '\n') {
            if (std.mem.lastIndexOfScalar(u8, line.bytes, ' ')) |space| {
                if (space > 0) {
                    line.bytes = line.bytes[0..space];
                    line.width = try rich.text.width(line.bytes);
                    consumed = space + 1;
                }
            }
            // Spaces at a soft-wrap boundary are layout, not new content.
            while (consumed < self.remaining.len and self.remaining[consumed] == ' ') consumed += 1;
        }
        self.done = lines.done or consumed == self.remaining.len;
        self.remaining = self.remaining[consumed..];
        return line;
    }
};

/// A border-only help/record panel, without table headers or internal grid lines.
/// Every cell remains literal text. ANSI is generated only by zrich.Style.
pub const Panel = struct {
    console: rich.Console,
    theme: Theme = .{},
    pub fn width(self: Panel) usize {
        return @min(self.console.options.width, 100);
    }
    pub fn inner(self: Panel) usize {
        return self.width() - 4;
    }
    pub fn begin(self: Panel, title: []const u8) !void {
        if (self.width() < 20) return error.InvalidWidth;
        try rich.text.validate(title);
        const ctx = self.console.context();
        const b = ctx.border();
        var titles: rich.text.Lines = .{ .text = title, .columns = self.width() - 6 };
        const line = (try titles.next()).?;
        try ctx.styled(b.tl, self.theme.border);
        try ctx.styled(b.h, self.theme.border);
        try ctx.writer.writeByte(' ');
        try ctx.styled(line.bytes, self.theme.heading);
        try ctx.writer.writeByte(' ');
        try self.theme.border.start(ctx.writer, ctx.options.color);
        try ctx.repeat(b.h, self.width() - line.width - 5);
        try ctx.writer.writeAll(b.tr);
        try rich.Style.reset(ctx.writer, ctx.options.color);
        try ctx.writer.writeByte('\n');
    }
    pub fn row(self: Panel, cells: []const Cell, widths: []const usize) !void {
        if (cells.len != widths.len or cells.len == 0 or cells.len > 5) return error.InvalidLayout;
        var total = (cells.len - 1) * 2;
        var lines: [5]Lines = undefined;
        for (cells, widths, 0..) |cell, columns, i| {
            if (columns == 0) return error.InvalidLayout;
            total += columns;
            try rich.text.validate(cell.text);
            lines[i] = .{ .remaining = cell.text, .columns = columns };
        }
        if (total != self.inner()) return error.InvalidLayout;
        const ctx = self.console.context();
        while (true) {
            var more = false;
            for (lines[0..cells.len]) |line| more = more or !line.done;
            if (!more) break;
            try ctx.styled(ctx.border().v, self.theme.border);
            try ctx.writer.writeByte(' ');
            for (cells, widths, 0..) |cell, columns, i| {
                if (i != 0) try ctx.writer.writeAll("  ");
                const line = (try lines[i].next()) orelse rich.text.Line{ .bytes = "", .width = 0 };
                try ctx.line(line, columns, .left, cell.style);
            }
            try ctx.writer.writeByte(' ');
            try ctx.styled(ctx.border().v, self.theme.border);
            try ctx.writer.writeByte('\n');
        }
    }
    pub fn text(self: Panel, value: []const u8, style: rich.Style) !void {
        try self.row(&.{.{ .text = value, .style = style }}, &.{self.inner()});
    }
    pub fn end(self: Panel) !void {
        const ctx = self.console.context();
        try self.theme.border.start(ctx.writer, ctx.options.color);
        try ctx.writer.writeAll(ctx.border().bl);
        try ctx.repeat(ctx.border().h, self.width() - 2);
        try ctx.writer.writeAll(ctx.border().br);
        try rich.Style.reset(ctx.writer, ctx.options.color);
        try ctx.writer.writeByte('\n');
    }
};

pub fn paragraph(console: rich.Console, value: []const u8, style: rich.Style) !void {
    try rich.text.validate(value);
    var lines: Lines = .{ .remaining = value, .columns = @max(2, @min(console.options.width, 100) -| 2) };
    while (try lines.next()) |line| {
        try console.writer.writeByte(' ');
        try console.styled(line.bytes, style);
        try console.writer.writeByte('\n');
    }
}

pub fn literal(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    // Escape controls and malformed bytes so untrusted data cannot inject terminal commands.
    var w: std.Io.Writer.Allocating = .init(a);
    for (value) |c| {
        switch (c) {
            0...31, 127 => try w.writer.print("\\x{x:0>2}", .{c}),
            else => try w.writer.writeByte(c),
        }
    }
    if (!std.unicode.utf8ValidateSlice(w.written())) return "[invalid UTF-8]";
    // C1 controls are also rejected by rich.
    rich.text.validate(w.written()) catch return "[unsupported control character]";
    return w.written();
}

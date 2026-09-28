//! Reusable in-process contract runner for downstream applications.
const std = @import("std");
const cli = @import("root.zig");
pub const Case = struct {
    args: []const []const u8,
    exit: cli.Exit = .success,
    stdout_contains: ?[]const u8 = null,
    stderr_contains: ?[]const u8 = null,
    stdout_empty: bool = false,
    stderr_empty: bool = false,
    json: bool = false,
    redirected: bool = true,
};
pub fn check(allocator: std.mem.Allocator, app: cli.App, cases: []const Case) !void {
    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(allocator);
        defer err.deinit();
        const result = app.run(allocator, case.args, .{
            .out = .{ .writer = &out.writer, .capabilities = .{ .color = !case.redirected, .interactive = !case.redirected } },
            .err = .{ .writer = &err.writer },
        });
        try std.testing.expectEqual(case.exit, result);
        if (case.stdout_contains) |text| try std.testing.expect(std.mem.indexOf(u8, out.written(), text) != null);
        if (case.stderr_contains) |text| try std.testing.expect(std.mem.indexOf(u8, err.written(), text) != null);
        if (case.stdout_empty) try std.testing.expectEqual(@as(usize, 0), out.written().len);
        if (case.stderr_empty) try std.testing.expectEqual(@as(usize, 0), err.written().len);
        if (case.redirected) {
            try std.testing.expect(std.mem.indexOfAny(u8, out.written(), "\x1b\r") == null);
            try std.testing.expect(std.mem.indexOfAny(u8, err.written(), "\x1b\r") == null);
        }
        if (case.json) {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value == .array);
        }
    }
}

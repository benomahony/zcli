//! Thin process adapter; the core never opens files or installs signal handlers.
const std = @import("std");
const cli = @import("root.zig");

/// Caller owns buffering and flushing. Each stream is detected independently.
pub fn runtime(init: std.process.Init, out: *std.Io.Writer, err: *std.Io.Writer) cli.Runtime {
    return .{
        .out = .{ .writer = out, .capabilities = cli.zrich.Options.detect(init.io, .stdout(), init.environ_map) catch .{} },
        .err = .{ .writer = err, .capabilities = cli.zrich.Options.detect(init.io, .stderr(), init.environ_map) catch .{} },
        .stdin_tty = std.Io.File.stdin().isTty(init.io) catch false,
        .environment = .{ .map = init.environ_map },
    };
}

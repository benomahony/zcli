//! A real file inspection/removal tool. Removal is explicit and preview never mutates.
const std = @import("std");
const cli = @import("zcli");
const FileOptions = struct { path: []const u8 };
const InspectRow = struct { path: []const u8, bytes: u64, lines: u64, sha256: []const u8 };
const RemoveRow = struct { path: []const u8, action: []const u8 };
const State = struct { io: std.Io };
fn state(ctx: *cli.Context) *State {
    return @ptrCast(@alignCast(ctx.runtime.user_data.?));
}
fn fileFailure(ctx: *cli.Context, err: anyerror, path: []const u8, action: []const u8) error{UserFailure} {
    const problem: []const u8 = switch (err) {
        error.FileNotFound => "does not exist",
        error.AccessDenied => "cannot be accessed with your current permissions",
        error.StreamTooLong => "is too large to inspect (the limit is 16 MiB)",
        error.IsDir => "is a directory; this command accepts one file",
        else => "could not be accessed",
    };
    const message = std.fmt.allocPrint(ctx.allocator, "Cannot {s} '{s}': it {s}.", .{ action, path, problem }) catch "Cannot access the selected file.";
    return ctx.fail(.failure, message, switch (err) {
        error.AccessDenied => "Check the file and parent directory permissions, or choose another --path.",
        error.StreamTooLong => "Choose a file smaller than 16 MiB with --path.",
        else => "Check --path and supply the name of an existing file.",
    });
}
fn read(ctx: *cli.Context, path: []const u8) ![]u8 {
    const info = std.Io.Dir.cwd().statFile(state(ctx).io, path, .{}) catch |err| return fileFailure(ctx, err, path, "inspect");
    if (info.kind != .file) return ctx.fail(.failure, "The selected path is not a regular file.", "Supply --path with a regular file; directories, devices, and pipes cannot be inspected.");
    return std.Io.Dir.cwd().readFileAlloc(state(ctx).io, path, ctx.allocator, .limited(16 * 1024 * 1024)) catch |err|
        return fileFailure(ctx, err, path, "inspect");
}
fn validateRemoval(ctx: *cli.Context, path: []const u8) !void {
    const info = std.Io.Dir.cwd().statFile(state(ctx).io, path, .{ .follow_symlinks = false }) catch |err| return fileFailure(ctx, err, path, "remove");
    if (info.kind != .file and info.kind != .sym_link) return ctx.fail(.failure, "The selected path is not a file or symbolic link.", "Supply --path with one file or link. Directories are never removed by parcel.");
}
fn inspect(ctx: *cli.Context, opts: FileOptions) ![]const InspectRow {
    const data = try read(ctx, opts.path);
    try ctx.progress("Inspecting", 1, 1);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const rows = try ctx.allocator.alloc(InspectRow, 1);
    rows[0] = .{ .path = opts.path, .bytes = data.len, .lines = std.mem.count(u8, data, "\n") + @as(u64, if (data.len != 0 and data[data.len - 1] != '\n') 1 else 0), .sha256 = try std.fmt.allocPrint(ctx.allocator, "{x}", .{&digest}) };
    return rows;
}
fn planRemove(ctx: *cli.Context, opts: FileOptions) ![]const RemoveRow {
    // Validate access without deleting anything. The execution handler is never called.
    try validateRemoval(ctx, opts.path);
    const rows = try ctx.allocator.alloc(RemoveRow, 1);
    rows[0] = .{ .path = opts.path, .action = "would remove" };
    return rows;
}
fn remove(ctx: *cli.Context, opts: FileOptions) ![]const RemoveRow {
    try ctx.checkCancelled();
    try validateRemoval(ctx, opts.path);
    std.Io.Dir.cwd().deleteFile(state(ctx).io, opts.path) catch |err| return fileFailure(ctx, err, opts.path, "remove");
    const rows = try ctx.allocator.alloc(RemoveRow, 1);
    rows[0] = .{ .path = opts.path, .action = "removed" };
    return rows;
}
fn loadConfig(ctx: *cli.Context, _: []const u8) !cli.Config {
    const path = ctx.runtime.environment.get("PARCEL_CONFIG") orelse return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(state(ctx).io, path, ctx.allocator, .limited(65536)) catch
        return ctx.fail(.config, "Could not read PARCEL_CONFIG.", "Set PARCEL_CONFIG to a readable JSON file, or unset it.");
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, data, .{ .allocate = .alloc_always }) catch
        return ctx.fail(.config, "PARCEL_CONFIG contains invalid JSON.", "Use a JSON object with string option values, for example {\"path\":\"README.md\"}.");
    if (parsed.value != .object) return ctx.fail(.config, "PARCEL_CONFIG must contain an object.", "Use {\"path\":\"README.md\"}.");
    var pairs: std.ArrayList(cli.Pair) = .empty;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return ctx.fail(.config, "Configuration values must be strings.", "Use {\"path\":\"README.md\"}.");
        try pairs.append(ctx.allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.string });
    }
    return .{ .project = pairs.items };
}
fn readLine(ctx: *cli.Context) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(state(ctx).io, &buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return ctx.fail(.usage, "Could not read confirmation.", "Pass --yes to confirm noninteractively.");
    return ctx.allocator.dupe(u8, std.mem.trim(u8, line, "\r"));
}
pub const app: cli.App = .{
    .name = "parcel",
    .version = "0.1.0",
    .description = "Inspect files and remove them with an explicit preview",
    .commands = &.{
        cli.command(FileOptions, InspectRow, .{
            .name = "inspect",
            .result_title = "File inspection",
            .description = "Show file size, line count, and SHA-256",
            .examples = &.{ "parcel inspect --path README.md", "parcel inspect --path README.md --json" },
            .options = &.{.{ .name = "path", .short = 'p', .metavar = "PATH", .help_panel = "Input", .help = "File to inspect", .example = "README.md", .env = "PARCEL_PATH" }},
        }, .{ .run = inspect }),
        cli.command(FileOptions, RemoveRow, .{
            .name = "remove",
            .help_panel = "Destructive operations",
            .result_title = "File removal",
            .description = "Remove one file after confirmation",
            .examples = &.{ "parcel remove --path scratch.txt --dry-run", "parcel remove --path scratch.txt --yes" },
            .options = &.{.{ .name = "path", .short = 'p', .metavar = "PATH", .help_panel = "Input", .help = "File to remove", .example = "scratch.txt", .env = "PARCEL_PATH" }},
            .destructive = "The selected file will be permanently removed.",
        }, .{ .run = remove, .dry_run = planRemove }),
    },
};
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(70);
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    var err = std.Io.File.stderr().writer(init.io, &err_buffer);
    var host = State{ .io = init.io };
    var rt = cli.native.runtime(init, &out.interface, &err.interface);
    rt.user_data = &host;
    rt.load_config = loadConfig;
    rt.read_line = readLine;
    const code = app.run(init.gpa, args[1..], rt);
    std.process.exit(@backingInt(code));
}

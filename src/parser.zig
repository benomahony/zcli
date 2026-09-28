//! Small owned parser. Exact names, required values, grouped shorts, and --.
const std = @import("std");
pub const Names = struct {
    long: ?[]const u8 = null,
    short: ?u8 = null,
};
pub const Param = struct { id: usize, names: Names, takes_value: enum { none, one, many, boolean } };
pub const Diagnostic = struct { argument: []const u8 = "", short: ?u8 = null };
pub const SliceIterator = struct {
    args: []const []const u8,
    index: usize = 0,
    pub fn next(self: *SliceIterator) ?[]const u8 {
        if (self.index == self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }
};
pub const Arg = struct { param: *const Param, value: ?[]const u8 = null };
pub const Parser = struct {
    params: []const Param,
    iter: *SliceIterator,
    diagnostic: *Diagnostic,
    tail: []const u8 = "",
    ended: bool = false,

    pub fn next(self: *Parser) error{ InvalidArgument, MissingValue, DoesntTakeValue }!?Arg {
        if (self.tail.len != 0) return try self.short();
        const token = self.iter.next() orelse return null;
        self.diagnostic.* = .{ .argument = token };
        if (!self.ended and std.mem.eql(u8, token, "--")) {
            self.ended = true;
            return self.next();
        }
        if (!self.ended and std.mem.startsWith(u8, token, "--")) {
            const end = std.mem.indexOfScalar(u8, token, '=') orelse token.len;
            const name = token[2..end];
            self.diagnostic.* = .{ .argument = token[0..end] };
            for (self.params) |*p| {
                if (p.names.long == null or !std.mem.eql(u8, p.names.long.?, name)) continue;
                if (p.takes_value == .none or p.takes_value == .boolean) {
                    if (end != token.len and p.takes_value == .none) return error.DoesntTakeValue;
                    return .{ .param = p, .value = if (end != token.len) token[end + 1 ..] else null };
                }
                return .{ .param = p, .value = if (end != token.len) token[end + 1 ..] else self.iter.next() orelse return error.MissingValue };
            }
            return error.InvalidArgument;
        }
        if (!self.ended and token.len > 1 and token[0] == '-') {
            self.tail = token[1..];
            return try self.short();
        }
        for (self.params) |*p| if (p.names.long == null and p.names.short == null) return .{ .param = p, .value = token };
        return error.InvalidArgument;
    }
    fn short(self: *Parser) !Arg {
        const name = self.tail[0];
        self.diagnostic.short = name;
        self.tail = self.tail[1..];
        for (self.params) |*p| {
            if (p.names.short == null or p.names.short.? != name) continue;
            if (p.takes_value == .none or p.takes_value == .boolean) {
                if (self.tail.len != 0 and self.tail[0] == '=') {
                    if (p.takes_value == .none) return error.DoesntTakeValue;
                    const value = self.tail[1..];
                    self.tail = "";
                    return .{ .param = p, .value = value };
                }
                return .{ .param = p };
            }
            const value = if (self.tail.len == 0) self.iter.next() orelse return error.MissingValue else if (self.tail[0] == '=') self.tail[1..] else self.tail;
            self.tail = "";
            return .{ .param = p, .value = value };
        }
        return error.InvalidArgument;
    }
};

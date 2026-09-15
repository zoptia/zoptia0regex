//! Regression tests for fixed defects: capture-name ownership, AST height
//! limits, and allocation-failure cleanup across compilation and the result APIs.
const std = @import("std");
const regex = @import("regexp.zig");
const ta = std.testing.allocator;

test "regression: compiled capture names own their source" {
    const pattern = try ta.dupe(u8, "(?P<name>a)");
    defer ta.free(pattern);
    var re = try regex.compile(ta, pattern);
    defer re.deinit();
    @memset(pattern, 'x');
    try std.testing.expectEqualStrings("name", re.subexpNames()[1]);
    try std.testing.expectEqual(@as(?usize, 1), re.subexpIndex("name"));
    const replaced = try re.replaceAllString(ta, "a", "${name}");
    defer ta.free(replaced);
    try std.testing.expectEqualStrings("a", replaced);
}

test "regression: POSIX stacked repetitions enforce AST depth" {
    const pattern = try ta.alloc(u8, 1001);
    defer ta.free(pattern);
    @memset(pattern, '*');
    pattern[0] = 'a';
    if (regex.compilePOSIX(ta, pattern)) |compiled| {
        var re = compiled;
        defer re.deinit();
        return error.ExpectedNestingDepth;
    } else |err| {
        try std.testing.expectEqual(error.NestingDepth, err);
    }
}

fn compileWithFailures(allocator: std.mem.Allocator, pattern: []const u8) !void {
    var re = try regex.compile(allocator, pattern);
    defer re.deinit();
}

fn apiWithFailures(allocator: std.mem.Allocator, re: *const regex.Regexp) !void {
    const input = "a1 bb22 a333";
    const all = try re.findAll(allocator, input, -1);
    defer if (all) |x| allocator.free(x);
    const indices = try re.findAllIndex(allocator, input, -1);
    defer if (indices) |x| allocator.free(x);
    const subs = try re.findSubmatch(allocator, input);
    defer if (subs) |x| allocator.free(x);
    const repl = try re.replaceAllString(allocator, input, "${word}:$2/$$");
    defer allocator.free(repl);
    const literal = try re.replaceAllLiteralString(allocator, input, "$1");
    defer allocator.free(literal);
    const split = try re.split(allocator, input, -1);
    defer if (split) |x| allocator.free(x);
    const quoted = try regex.quoteMeta(allocator, "a+b[0]");
    defer allocator.free(quoted);
}

test "regression: compilation and result APIs survive allocation failures" {
    // Arena growth can resize in place depending on allocator addresses.
    // Force growth through alloc so fault indices stay deterministic.
    var no_resize = std.testing.FailingAllocator.init(ta, .{ .resize_fail_index = 0 });
    const backing = no_resize.allocator();
    for ([_][]const u8{ "(?P<word>[a-z]+)([0-9]+)", "\\A(?i:[a-z]+)([0-9]+)\\z", "(?i)\\p{Lu}{2,4}", "(a?)*b" }) |pattern| {
        try std.testing.checkAllAllocationFailures(backing, compileWithFailures, .{pattern});
    }
    var re = try regex.compile(ta, "(?P<word>[a-z]+)([0-9]+)");
    defer re.deinit();
    try std.testing.checkAllAllocationFailures(backing, apiWithFailures, .{&re});
}

test "regression: redundant noncapturing groups do not consume AST depth" {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(ta);
    for (0..1001) |_| try pattern.appendSlice(ta, "(?:");
    try pattern.append(ta, 'a');
    for (0..1001) |_| try pattern.append(ta, ')');
    var re = try regex.compile(ta, pattern.items);
    defer re.deinit();
    try std.testing.expect(try re.match(ta, "a"));
}

//! Regression tests for fixed defects: capture-name ownership and AST height
//! limits. Allocation-failure cleanup is covered in `oomtest.zig`.
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

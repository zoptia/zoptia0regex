//! Sharing one `Scratch` between interleaved searches: nested
//! `matchesScratch` loops (same and different regexps, any capture count),
//! and `*Scratch` calls inside a loop. Every test runs under
//! `std.testing.allocator`, so a use-after-free, double free or leak of a
//! shared buffer fails it.
const std = @import("std");
const regex = @import("regexp.zig");

const ta = std.testing.allocator;

/// Every match of `re` in `input`, via the allocating API.
fn allMatches(re: *const regex.Regexp, input: []const u8) ![][]i64 {
    return (try re.findAllSubmatchIndex(ta, input, -1)) orelse try ta.alloc([]i64, 0);
}

/// Runs `inner` to exhaustion on `scratch` once per match of `outer`,
/// checking both against the allocating API, and that each outer slice is
/// still intact after the inner loop ran.
fn checkNested(scratch: *regex.Scratch, outer: *const regex.Regexp, inner: *const regex.Regexp, input: []const u8) !void {
    const want_outer = try allMatches(outer, input);
    defer regex.Regexp.freeAllSubmatchIndex(ta, want_outer);
    const want_inner = try allMatches(inner, input);
    defer regex.Regexp.freeAllSubmatchIndex(ta, want_inner);

    var it = try outer.matchesScratch(scratch, input, -1);
    defer it.deinit();
    var k: usize = 0;
    while (try it.next()) |m| : (k += 1) {
        try std.testing.expect(k < want_outer.len);
        try std.testing.expectEqualSlices(i64, want_outer[k], m);
        var inner_it = try inner.matchesScratch(scratch, input, -1);
        defer inner_it.deinit();
        var j: usize = 0;
        while (try inner_it.next()) |x| : (j += 1) {
            try std.testing.expect(j < want_inner.len);
            try std.testing.expectEqualSlices(i64, want_inner[j], x);
            // The outer slice survives inner activity on the same scratch.
            try std.testing.expectEqualSlices(i64, want_outer[k], m);
        }
        try std.testing.expectEqual(want_inner.len, j);
        try std.testing.expectEqualSlices(i64, want_outer[k], m);
    }
    try std.testing.expectEqual(want_outer.len, k);
}

const x20 = "xxxxxxxxxxxxxxxxxxxx";
const x40 = x20 ++ x20;
const many_groups = "(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)(x)";

test "nested matchesScratch over one scratch: same regexp" {
    var re = try regex.compile(ta, "a(b|c)");
    defer re.deinit();
    var scratch = regex.Scratch.init(ta);
    defer scratch.deinit();
    try checkNested(&scratch, &re, &re, "ab ac ab");
    try checkNested(&scratch, &re, &re, "");
}

test "nested matchesScratch over one scratch: different regexps and capture counts" {
    var small = try regex.compile(ta, "(a)(b)");
    defer small.deinit();
    // 20 groups: the inner iterator's buffer (42 slots) is larger than the
    // outer one's (6), which before 0.8.0 reallocated the outer's buffer.
    var big = try regex.compile(ta, many_groups);
    defer big.deinit();
    var anchored = try regex.compile(ta, "\\A(a)(b)"); // one-pass
    defer anchored.deinit();
    var scratch = regex.Scratch.init(ta);
    defer scratch.deinit();
    const input = "ab " ++ x20 ++ " ab " ++ x40;
    try checkNested(&scratch, &small, &big, input);
    try checkNested(&scratch, &big, &small, input);
    try checkNested(&scratch, &anchored, &big, input);
    try checkNested(&scratch, &big, &anchored, input);

    // A long input sends both regexps to the Pike VM, whose thread pool is
    // rebuilt whenever the capture count changes between calls.
    const long = try ta.alloc(u8, 40_000);
    defer ta.free(long);
    for (long, 0..) |*c, i| c.* = if (i % 100 < 20) 'x' else if (i % 100 < 22) "ab"[i % 100 - 20] else ' ';
    try checkNested(&scratch, &small, &big, long[0..2000]);
    var it = try small.matchesScratch(&scratch, long, 3);
    defer it.deinit();
    var inner = try big.matchesScratch(&scratch, long, 3);
    defer inner.deinit();
    // Interleave the two iterators step by step.
    while (true) {
        const x = try it.next();
        const y = try inner.next();
        if (x == null and y == null) break;
        if (x) |m| try std.testing.expectEqual(@as(i64, 20), @mod(m[0], 100));
        if (y) |m| try std.testing.expectEqual(@as(i64, 0), @mod(m[0], 100));
    }
}

test "scratch searches inside a matchesScratch loop leave the iterator intact" {
    var re = try regex.compile(ta, "(\\w+)@(\\w+)");
    defer re.deinit();
    var other = try regex.compile(ta, many_groups);
    defer other.deinit();
    var scratch = regex.Scratch.init(ta);
    defer scratch.deinit();
    const input = "me@example you@test them@there";
    const want = try allMatches(&re, input);
    defer regex.Regexp.freeAllSubmatchIndex(ta, want);

    var it = try re.matchesScratch(&scratch, input, -1);
    defer it.deinit();
    var k: usize = 0;
    while (try it.next()) |m| : (k += 1) {
        const sub = (try re.findSubmatchIndexScratch(&scratch, input[@intCast(m[0])..])).?;
        try std.testing.expectEqual(@as(i64, 0), sub[0]);
        const big = (try other.findSubmatchIndexScratch(&scratch, x20)).?; // grows the result buffer
        try std.testing.expectEqual(@as(usize, 42), big.len);
        try std.testing.expectEqual(regex.Match{ .start = 0, .end = 10 }, (try re.findIndexScratch(&scratch, input)).?);
        try std.testing.expect(try other.matchScratch(&scratch, x20));
        try std.testing.expect(!try other.matchScratch(&scratch, "x"));
        try std.testing.expectEqualSlices(i64, want[k], m);
    }
    try std.testing.expectEqual(want.len, k);

    // The findSubmatchIndexScratch result likewise survives iterators.
    const kept = (try re.findSubmatchIndexScratch(&scratch, input)).?;
    var it2 = try other.matchesScratch(&scratch, x40, -1);
    defer it2.deinit();
    while (try it2.next()) |_| {}
    try std.testing.expectEqualSlices(i64, &.{ 0, 10, 0, 2, 3, 10 }, kept);
}

/// A nested pair of scans: two iterators live at once on one scratch.
fn nestedScans(re_outer: *const regex.Regexp, re_inner: *const regex.Regexp, scratch: *regex.Scratch) !usize {
    var total: usize = 0;
    for ([_][]const u8{ "ab ac ab", "xx", "abab ac" }) |input| {
        var it = try re_outer.matchesScratch(scratch, input, -1);
        defer it.deinit();
        while (try it.next()) |m| {
            var inner = try re_inner.matchesScratch(scratch, input, -1);
            defer inner.deinit();
            while (try inner.next()) |x| total += @intCast(x[1] - x[0]);
            total += @intCast(m[1] - m[0]);
        }
    }
    return total;
}

test "nested matchesScratch allocates nothing once warm" {
    var re = try regex.compile(ta, "a(b|c)");
    defer re.deinit();
    var big = try regex.compile(ta, "(a)(b|c)(x?)(x?)(x?)(x?)(x?)(x?)(x?)(x?)(x?)(x?)(x?)(x?)(x?)(x?)(x?)");
    defer big.deinit();
    const pairs = [_][2]*const regex.Regexp{ .{ &re, &re }, .{ &re, &big }, .{ &big, &re } };
    for (pairs) |pair| {
        var warm = regex.Scratch.init(ta);
        defer warm.deinit();
        const want = try nestedScans(pair[0], pair[1], &warm);
        var failing = std.testing.FailingAllocator.init(ta, .{ .fail_index = 0 });
        warm.allocator = failing.allocator();
        defer warm.allocator = ta;
        try std.testing.expectEqual(want, try nestedScans(pair[0], pair[1], &warm));
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
}

test "a matchesScratch loop run to exhaustion without deinit returns its buffer" {
    // The contract documented before 0.8.0: `deinit` was optional. Such
    // loops must neither grow the buffer pool nor trip `Scratch.deinit`.
    var re = try regex.compile(ta, "(a)(b)?");
    defer re.deinit();
    var scratch = regex.Scratch.init(ta);
    defer scratch.deinit();
    for (0..200) |_| {
        var it = try re.matchesScratch(&scratch, "ab a ab", -1);
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        try std.testing.expectEqual(@as(usize, 3), n);
        try std.testing.expect((try it.next()) == null); // stays exhausted
    }
    try std.testing.expectEqual(@as(usize, 1), scratch.iter_bufs.items.len);

    // An explicit deinit after exhaustion is still fine (no double release),
    // and so is an early break followed by deinit.
    var done = try re.matchesScratch(&scratch, "ab", -1);
    while (try done.next()) |_| {}
    done.deinit();
    var early = try re.matchesScratch(&scratch, "ab ab ab", -1);
    _ = (try early.next()).?;
    early.deinit();
    try std.testing.expectEqual(@as(usize, 1), scratch.iter_bufs.items.len);
}

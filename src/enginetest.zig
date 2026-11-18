//! Engine regression tests. Expected results were recorded from Go 1.27.1's
//! regexp.

const std = @import("std");
const regex = @import("regexp.zig");

const ta = std.testing.allocator;

fn repeated(a: std.mem.Allocator, unit: []const u8, n: usize) ![]u8 {
    const out = try a.alloc(u8, unit.len * n);
    for (0..n) |k| @memcpy(out[k * unit.len ..][0..unit.len], unit);
    return out;
}

fn expectSubmatch(a: std.mem.Allocator, re: *const regex.Regexp, input: []const u8, want: ?[]const i64) !void {
    const got = try re.findSubmatchIndex(a, input);
    defer if (got) |g| a.free(g);
    if (want) |w| {
        try std.testing.expect(got != null);
        try std.testing.expectEqualSlices(i64, w, got.?);
    } else {
        try std.testing.expect(got == null);
    }
}

// --- The Pike VM's epsilon closure must not recurse natively ---
//
// Each program is far past the size that overflowed an 8 MB native stack
// with the recursive `add` (about 21k `a??`, 10k `()`, 20k alternatives in a
// Debug build). Go answers all of them. Inputs longer than the bitstate
// limit are irrelevant here: programs over 500 instructions always run on
// the Pike VM. The deep tests allocate from an arena because a 100k-thread
// run through the checking test allocator alone takes seconds in Debug.

test "deep program: long run of lazy optionals" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var re = try regex.compile(a, try repeated(a, "a??", 150_000));
    try std.testing.expect(re.prog.insts.len > 300_000);
    try expectSubmatch(a, &re, "xyzxyzxyz", &.{ 0, 0 });
    try expectSubmatch(a, &re, "aax", &.{ 0, 0 });
}

test "deep program: long run of empty captures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 60_000;
    var re = try regex.compile(a, try repeated(a, "()", n));
    try std.testing.expect(try re.match(a, "xyzxyzxyz"));
    const got = (try re.findSubmatchIndex(a, "xyzxyzxyz")).?;
    try std.testing.expectEqual(@as(usize, 2 * (n + 1)), got.len);
    for (got) |x| try std.testing.expectEqual(@as(i64, 0), x);
}

test "deep program: wide alternation of distinct runes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    const n = 60_000;
    for (0..n) |k| {
        if (k > 0) try buf.append(a, '|');
        try buf.print(a, "\\x{{{X}}}z", .{0x10000 + k});
    }
    var re = try regex.compile(a, buf.items);
    try std.testing.expect(!try re.match(a, "xyzxyzxyz"));
    // The last alternative, U+1EA5F, preceded by two ASCII bytes.
    try expectSubmatch(a, &re, "ab\u{1EA5F}z", &.{ 2, 7 });
}

// --- Runes UTF-8 cannot encode in a literal prefix ---
//
// Go writes a surrogate in a literal prefix as U+FFFD and keeps collecting.
// The one-pass engine skips its prefix without decoding it, so `^a\x{D800}`
// matches "a\u{FFFD}"; every other engine compares runes and, since no input
// decodes to a surrogate, never matches one. Both behaviours are Go's.

const PrefixCase = struct { p: []const u8, prefix: []const u8, complete: bool };

test "literal prefix with an unencodable rune" {
    const cases = [_]PrefixCase{
        .{ .p = "\\x{D800}", .prefix = "\u{FFFD}", .complete = true },
        .{ .p = "a\\x{D800}b", .prefix = "a\u{FFFD}b", .complete = true },
        .{ .p = "^a\\x{D800}", .prefix = "a\u{FFFD}", .complete = false },
        .{ .p = "^a\\x{D800}$", .prefix = "a\u{FFFD}", .complete = true },
        .{ .p = "[\\x{D800}]", .prefix = "\u{FFFD}", .complete = true },
        .{ .p = "^\\x{D800}\\x{DBFF}", .prefix = "\u{FFFD}\u{FFFD}", .complete = false },
        .{ .p = "^(a)\\x{D800}", .prefix = "", .complete = false },
    };
    for (cases) |c| {
        var re = try regex.compile(ta, c.p);
        defer re.deinit();
        const lp = re.literalPrefix();
        try std.testing.expectEqualStrings(c.prefix, lp.prefix);
        try std.testing.expectEqual(c.complete, lp.complete);
    }
}

const SubmatchCase = struct { p: []const u8, in: []const u8, want: ?[]const i64 };

test "matching with an unencodable rune in the literal prefix" {
    const cases = [_]SubmatchCase{
        .{ .p = "^a\\x{D800}", .in = "a\u{FFFD}", .want = &.{ 0, 4 } },
        .{ .p = "^a\\x{D800}", .in = "a\u{FFFD}b", .want = &.{ 0, 4 } },
        .{ .p = "^a\\x{D800}", .in = "a\xed\xa0\x80", .want = null },
        .{ .p = "^a\\x{D800}$", .in = "a\u{FFFD}", .want = &.{ 0, 4 } },
        .{ .p = "^a\\x{D800}$", .in = "a\u{FFFD}b", .want = null },
        .{ .p = "\\A\\x{DFFF}x\\z", .in = "\u{FFFD}x", .want = &.{ 0, 4 } },
        .{ .p = "^a\\x{D800}(b)", .in = "a\u{FFFD}b", .want = &.{ 0, 5, 4, 5 } },
        .{ .p = "^(a)\\x{D800}", .in = "a\u{FFFD}", .want = null },
        .{ .p = "\\x{D800}", .in = "\u{FFFD}", .want = null },
        .{ .p = "\\x{D800}", .in = "\xed\xa0\x80", .want = null },
        .{ .p = "(?:\\x{D800})", .in = "\u{FFFD}", .want = null },
        .{ .p = "[\\x{D800}]", .in = "\u{FFFD}", .want = null },
        .{ .p = "a\\x{D800}b", .in = "a\u{FFFD}b", .want = null },
        .{ .p = "a\\x{D800}", .in = "xa\u{FFFD}", .want = null },
        .{ .p = "\\x{D800}|\\x{FFFD}", .in = "a\u{FFFD}", .want = &.{ 1, 4 } },
        .{ .p = "^a\\x{D800}|b", .in = "a\u{FFFD}b", .want = &.{ 4, 5 } },
    };
    var scratch = regex.Scratch.init(ta);
    defer scratch.deinit();
    for (cases) |c| {
        var re = try regex.compile(ta, c.p);
        defer re.deinit();
        try expectSubmatch(ta, &re, c.in, c.want);
        try std.testing.expectEqual(c.want != null, try re.match(ta, c.in));
        try std.testing.expectEqual(c.want != null, try re.matchScratch(&scratch, c.in));
        const fi = try re.findIndex(ta, c.in);
        try std.testing.expectEqual(c.want != null, fi != null);
        if (fi) |m| {
            try std.testing.expectEqual(c.want.?[0], @as(i64, @intCast(m.start)));
            try std.testing.expectEqual(c.want.?[1], @as(i64, @intCast(m.end)));
        }
    }
}

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

// --- Every engine agrees with the default dispatch ---
//
// `Engine.mode` forces an engine regardless of Go's dispatch heuristics, so
// each engine is exercised on every pattern below, including the one-pass
// regexps the default always routes to `doOnePass`. The default dispatch
// itself is checked against Go by the differential suites. (One-pass
// regexps whose literal prefix holds a surrogate are left out: there Go's
// own engines disagree, see above.)

const Mode = @import("exec.zig").Mode;

const cross_patterns = [_][]const u8{
    "",                    "a",                      "abc",                "a*",
    "a+?",                 "(a*)+",                  "(a|ab)(c|bcd)(d*)",  "(?:a|b)*c",
    "x(?:a|b)*?c",         "[a-p]x",                 "(?i)abc",            "(?i)k",
    "(?i)ſs",
    "\\d{2,3}-\\d+",       "\\bfoo\\b",              "\\Bo",               "^",
    "$",                   "(?m)^\\w+$",             "(?s).+",             ".*",
    "\\A(a+)",             "\\Aab|cd",               "^abc$",              "^(a|b)c",
    "\\A(\\d+)-(\\d+)\\z", "^(?:(a)|b)*$",           "(a)(b)?(c)",         "(?U)a+",
    "\\p{Greek}+",         "[^a]+",
    "日本?",
    "\\x{FFFD}",           "[\\x{80}-\\x{10FFFF}]+", "(foo|foobar)(bar)?", "a{2,4}?b",
    "(?:(?:a)|(?:ab))+?$", "(?i)performance|bench",  "\\z",                "(|a)*",
    "(a?)((ab)?)(b?)",     "^(?:a?)?$",
};

const cross_inputs = [_][]const u8{
    "",                     "a",              "abcd",              "aaab",
    "xabbac xbc",           "foo foobar fob", "12-345 1-2 123-45", "line1\nline2\n",
    "Kk\u{212A}ſsS",
    "日本語 日本",
    "\xff\xfe a\x80b",
    "αβγ abc",
    "performance BENCH",    "ab",             "cdab",              "ax bx px qx",
    "\u{FFFD}\xed\xa0\x80",
};

const Outcome = struct { m: bool, s: ?[]i64, all: ?[][]i64 };

fn outcome(re: *const regex.Regexp, in: []const u8) !Outcome {
    const s = try re.findSubmatchIndex(ta, in);
    errdefer if (s) |x| ta.free(x);
    return .{
        .m = try re.match(ta, in),
        .s = s,
        .all = try re.findAllSubmatchIndex(ta, in, -1),
    };
}

fn freeOutcome(o: Outcome) void {
    if (o.s) |s| ta.free(s);
    if (o.all) |a| regex.Regexp.freeAllSubmatchIndex(ta, a);
}

fn expectSameOutcome(want: Outcome, got: Outcome) !void {
    try std.testing.expectEqual(want.m, got.m);
    try std.testing.expectEqual(want.s == null, got.s == null);
    if (want.s) |s| try std.testing.expectEqualSlices(i64, s, got.s.?);
    try std.testing.expectEqual(want.all == null, got.all == null);
    if (want.all) |a| {
        try std.testing.expectEqual(a.len, got.all.?.len);
        for (a, got.all.?) |x, y| try std.testing.expectEqualSlices(i64, x, y);
    }
}

test "every engine mode agrees with the default dispatch" {
    var scratch = regex.Scratch.init(ta);
    defer scratch.deinit();
    var onepass_seen: usize = 0;
    for ([_]bool{ false, true }) |posix| {
        for (cross_patterns) |p| {
            var re = (if (posix) regex.compilePOSIX(ta, p) else regex.compile(ta, p)) catch continue;
            defer re.deinit();
            if (re.onepass != null) onepass_seen += 1;
            for (cross_inputs) |in| {
                re.engine.mode = .auto;
                const want = try outcome(&re, in);
                defer freeOutcome(want);
                for ([_]Mode{ .no_onepass, .pike, .bitstate }) |mode| {
                    re.engine.mode = mode;
                    errdefer std.debug.print("mode={t} posix={} pattern={s} input={x}\n", .{ mode, posix, p, in });
                    const got = try outcome(&re, in);
                    defer freeOutcome(got);
                    try expectSameOutcome(want, got);
                    // The scratch-reusing paths share the same dispatch.
                    try std.testing.expectEqual(want.m, try re.matchScratch(&scratch, in));
                    const ss = try re.findSubmatchIndexScratch(&scratch, in);
                    try std.testing.expectEqual(want.s == null, ss == null);
                    if (want.s) |s| try std.testing.expectEqualSlices(i64, s, ss.?);
                }
            }
        }
    }
    try std.testing.expect(onepass_seen >= 4); // the one-pass engine took part
}

test "anchored Pike VM starts threads only at the beginning" {
    // Forced onto the Pike VM, an anchored regexp must not find matches at
    // later positions (findAll restarts the engine at every match end).
    var re = try regex.compile(ta, "\\A(a|ab)(c|bcd)?");
    defer re.deinit();
    re.engine.mode = .pike;
    const all = (try re.findAllSubmatchIndex(ta, "abcdabcd", -1)).?;
    defer regex.Regexp.freeAllSubmatchIndex(ta, all);
    try std.testing.expectEqual(@as(usize, 1), all.len);
    try std.testing.expectEqualSlices(i64, &.{ 0, 4, 0, 1, 1, 4 }, all[0]);
    var it = try re.matches(ta, "xab", -1);
    defer it.deinit();
    try std.testing.expect(try it.next() == null);
}

//! Behaviour tests for the public API, checking match results against the
//! semantics of Go's `regexp` package.

const std = @import("std");
const regex = @import("regexp.zig");

const ta = std.testing.allocator;

fn expectMatch(pattern: []const u8, input: []const u8, want: bool) !void {
    var re = try regex.compile(ta, pattern);
    defer re.deinit();
    try std.testing.expectEqual(want, try re.match(ta, input));
}

fn expectFind(pattern: []const u8, input: []const u8, want: ?[]const u8) !void {
    var re = try regex.compile(ta, pattern);
    defer re.deinit();
    const got = try re.find(ta, input);
    if (want) |wstr| {
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings(wstr, got.?);
    } else {
        try std.testing.expect(got == null);
    }
}

test "literal match" {
    try expectMatch("abc", "abc", true);
    try expectMatch("abc", "xabcy", true);
    try expectMatch("abc", "ab", false);
    try expectMatch("", "anything", true);
}

test "anchors" {
    try expectMatch("^abc$", "abc", true);
    try expectMatch("^abc$", "xabc", false);
    try expectFind("^a", "aa", "a");
    try expectMatch("\\Aabc\\z", "abc", true);
}

test "dot and star" {
    try expectFind("a.c", "axc", "axc");
    try expectFind("a.c", "a\nc", null); // . doesn't match newline by default
    try expectFind("a.*c", "axxxc", "axxxc");
    try expectFind("a.*?c", "axxxcxc", "axxxc"); // non-greedy
}

test "alternation and groups" {
    try expectFind("a(b|c)d", "acd", "acd");
    try expectFind("(abc)+", "abcabc", "abcabc");
    try expectMatch("cat|dog", "I have a dog", true);
}

test "character classes" {
    try expectFind("[a-c]+", "xbcay", "bca");
    try expectFind("[^a-c]+", "abXYZcc", "XYZ");
    try expectFind("[0-9]+", "abc123def", "123");
    try expectFind("\\d+", "abc123", "123");
    try expectFind("\\w+", "  foo_bar ", "foo_bar");
}

test "quantifiers counted" {
    try expectFind("a{2,3}", "aaaa", "aaa");
    try expectFind("a{2}", "aaaa", "aa");
    try expectMatch("a{2,}", "a", false);
    try expectMatch("a{2,}", "aaaaa", true);
}

test "case insensitive" {
    try expectMatch("(?i)abc", "ABC", true);
    try expectMatch("(?i)abc", "AbC", true);
    try expectFind("(?i)[a-z]+", "HELLO", "HELLO");
    try expectMatch("(?i)Σ", "σ", true); // Greek fold
}

test "submatches" {
    var re = try regex.compile(ta, "(\\w+)@(\\w+)");
    defer re.deinit();
    const subs = (try re.findSubmatch(ta, "contact me@example here")).?;
    defer ta.free(subs);
    try std.testing.expectEqualStrings("me@example", subs[0].?);
    try std.testing.expectEqualStrings("me", subs[1].?);
    try std.testing.expectEqualStrings("example", subs[2].?);
}

test "named groups and index" {
    var re = try regex.compile(ta, "(?P<user>\\w+)@(?P<host>\\w+)");
    defer re.deinit();
    try std.testing.expectEqual(@as(?usize, 1), re.subexpIndex("user"));
    try std.testing.expectEqual(@as(?usize, 2), re.subexpIndex("host"));
    try std.testing.expectEqual(@as(?usize, null), re.subexpIndex("nope"));
}

test "find all" {
    var re = try regex.compile(ta, "\\d+");
    defer re.deinit();
    const all = (try re.findAll(ta, "a1b22c333", -1)).?;
    defer ta.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("1", all[0]);
    try std.testing.expectEqualStrings("22", all[1]);
    try std.testing.expectEqualStrings("333", all[2]);
}

test "replace all with expansion" {
    var re = try regex.compile(ta, "(\\w+)@(\\w+)");
    defer re.deinit();
    const out = try re.replaceAllString(ta, "me@here you@there", "$2.$1");
    defer ta.free(out);
    try std.testing.expectEqualStrings("here.me there.you", out);
}

test "replace literal" {
    var re = try regex.compile(ta, "\\s+");
    defer re.deinit();
    const out = try re.replaceAllLiteralString(ta, "a  b   c", "-");
    defer ta.free(out);
    try std.testing.expectEqualStrings("a-b-c", out);
}

test "split" {
    var re = try regex.compile(ta, ",");
    defer re.deinit();
    const parts = (try re.split(ta, "a,b,c", -1)).?;
    defer ta.free(parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("c", parts[2]);
}

test "word boundary" {
    try expectFind("\\bword\\b", "a word here", "word");
    try expectMatch("\\bcat\\b", "category", false);
}

test "quoteMeta" {
    const q = try regex.quoteMeta(ta, "a.b*c");
    defer ta.free(q);
    try std.testing.expectEqualStrings("a\\.b\\*c", q);
}

test "unicode property class" {
    try expectFind("\\p{Greek}+", "abcΑΒΓdef", "ΑΒΓ");
    try expectFind("\\pL+", "  hello  ", "hello");
}

test "matches iterator: limits, empty-match rule, reuse" {
    var re = try regex.compile(ta, "a*");
    defer re.deinit();
    // Same sequence Go's FindAllStringIndex("baaab", -1) yields: [0,0] [1,4] [5,5].
    var it = try re.matches(ta, "baaab", -1);
    defer it.deinit();
    const want = [_][2]i64{ .{ 0, 0 }, .{ 1, 4 }, .{ 5, 5 } };
    for (want) |w| {
        const m = (try it.next()).?;
        try std.testing.expectEqual(w[0], m[0]);
        try std.testing.expectEqual(w[1], m[1]);
    }
    try std.testing.expect((try it.next()) == null);
    try std.testing.expect((try it.next()) == null); // stays exhausted

    // n limits the count; n == 0 yields nothing.
    var two = try re.matches(ta, "baaab", 2);
    defer two.deinit();
    _ = (try two.next()).?;
    _ = (try two.next()).?;
    try std.testing.expect((try two.next()) == null);
    var none = try re.matches(ta, "baaab", 0);
    defer none.deinit();
    try std.testing.expect((try none.next()) == null);

    // Submatch slots are padded to 2*(numSubexp+1) and reused between calls.
    var grp = try regex.compile(ta, "(a)|(b)");
    defer grp.deinit();
    var git = try grp.matches(ta, "ab", -1);
    defer git.deinit();
    const m1 = (try git.next()).?;
    try std.testing.expectEqual(@as(usize, 6), m1.len);
    try std.testing.expectEqual(@as(i64, -1), m1[4]);
    const m2 = (try git.next()).?;
    try std.testing.expectEqual(m1.ptr, m2.ptr);
    try std.testing.expectEqual(@as(i64, 1), m2[4]);
}

test "posix longest" {
    var re = try regex.compilePOSIX(ta, "a|ab");
    defer re.deinit();
    // POSIX leftmost-longest prefers "ab" over "a".
    const got = (try re.find(ta, "ab")).?;
    try std.testing.expectEqualStrings("ab", got);
}

test "leftmost-first vs longest" {
    var re = try regex.compile(ta, "a|ab");
    defer re.deinit();
    // Perl leftmost-first prefers the first alternative "a".
    const got = (try re.find(ta, "ab")).?;
    try std.testing.expectEqualStrings("a", got);
}

test "invalid patterns error (no crash)" {
    const bad = [_][]const u8{
        "(",           "(abc",             ")",           "a)",
        "[",           "[a-",              "a{2,1}",      "a**",
        "\\",          "(?P<>x)",          "[z-a]",       "(?P<a)x)",
        "x{1001}",     "*",                "+",           "?",
        "(?",          "(?<",              "\\x{110000}", "\\xG",
        "[[:bogus:]]", "\\p{Nonexistent}", "{2}",
    };
    for (bad) |p| {
        if (regex.compile(ta, p)) |*re| {
            var r = re.*;
            r.deinit();
            std.debug.print("expected error for pattern: /{s}/\n", .{p});
            return error.ShouldHaveErrored;
        } else |_| {
            // expected: errored cleanly
        }
    }
}

test "linear time on ReDoS-style pattern" {
    // A classic catastrophic-backtracking pattern. The Pike VM is linear-time,
    // so this completes instantly and matches Go's result (no match).
    var re = try regex.compile(ta, "(a*)*$");
    defer re.deinit();
    const input: [201]u8 = @as([200]u8, @splat('a')) ++ "b".*; // no '$' reachable after the trailing b
    try std.testing.expect(try re.match(ta, &input));
    var re2 = try regex.compile(ta, "(a+)+b");
    defer re2.deinit();
    const input2: [500]u8 = @splat('a'); // never a 'b' -> no match, but must not blow up
    try std.testing.expect(!try re2.match(ta, &input2));
}

test "empty and nullable edge cases" {
    try expectFind("(a*)*", "aaa", "aaa");
    // Greedy star of (empty|a): the empty alternative wins -> empty match.
    try expectFind("(|a)*", "aa", "");
    try expectFind("a?", "", "");
    try expectMatch("^$", "", true);
    try expectMatch("(?:)", "", true);
}

test "multiline flag" {
    var re = try regex.compile(ta, "(?m)^\\w+");
    defer re.deinit();
    const all = (try re.findAll(ta, "foo\nbar\nbaz", -1)).?;
    defer ta.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("bar", all[1]);
}

test "submatch padding for compiled-away group" {
    // (a){0} -> the group is simplified away, but the result must still be
    // padded to 2*(numSubexp+1). Go: FindStringSubmatchIndex("bc") == [0,0,-1,-1].
    var re = try regex.compile(ta, "(a){0}");
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 1), re.numSubexp());
    const idx = (try re.findSubmatchIndex(ta, "bc")).?;
    defer ta.free(idx);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 0, 0, -1, -1 }, idx);

    const subs = (try re.findSubmatch(ta, "bc")).?;
    defer ta.free(subs);
    try std.testing.expectEqual(@as(usize, 2), subs.len);
    try std.testing.expectEqualStrings("", subs[0].?);
    try std.testing.expect(subs[1] == null);
}

test "U+FFFD literal matches an invalid input byte" {
    // \x{FFFD} must match a single invalid byte (which decodes to U+FFFD,
    // width 1); minInputLen must not over-reject the 1-byte input.
    var re = try regex.compile(ta, "\\x{FFFD}");
    defer re.deinit();
    try std.testing.expect(try re.match(ta, "\xff"));
    const m = (try re.findIndex(ta, "\xff")).?;
    try std.testing.expectEqual(@as(usize, 0), m.start);
    try std.testing.expectEqual(@as(usize, 1), m.end);
}

test "invalid-UTF-8 error codes match Go" {
    // Named capture with no '>' and invalid UTF-8 -> InvalidUTF8 (not NamedCapture).
    try std.testing.expectError(error.InvalidUTF8, regex.compile(ta, "(?<\xff"));
    // \p{ with invalid UTF-8 inside braces -> InvalidUTF8 (not InvalidCharRange).
    try std.testing.expectError(error.InvalidUTF8, regex.compile(ta, "\\p{\xff}"));
}

test "deep nesting returns NestingDepth (no stack overflow)" {
    const pat: [6001]u8 = @as([3000]u8, @splat('(')) ++ "a".* ++ @as([3000]u8, @splat(')'));
    try std.testing.expectError(error.NestingDepth, regex.compile(ta, &pat));
}

test "unicode names in replacement templates match Go" {
    var re = try regex.compile(ta, "(a)");
    defer re.deinit();
    // "café" is all Unicode letters -> a (missing) group name -> expands empty.
    const a = try re.replaceAllString(ta, "a", "[$café]");
    defer ta.free(a);
    try std.testing.expectEqualStrings("[]", a);
    const b = try re.replaceAllString(ta, "a", "x${café}y");
    defer ta.free(b);
    try std.testing.expectEqualStrings("xy", b);
    // "$1é" -> the name is "1é" (digit+letter), not group 1.
    const c = try re.replaceAllString(ta, "a", "$1é");
    defer ta.free(c);
    try std.testing.expectEqualStrings("", c);
}

test "one-pass engine on anchored patterns" {
    // Anchored regexps qualify for the one-pass engine; results must match the
    // other engines exactly.
    {
        var re = try regex.compile(ta, "\\A(?i)performance\\z");
        defer re.deinit();
        try std.testing.expect(re.onepass != null); // one-pass active
        try std.testing.expect(try re.match(ta, "PERFORMANCE"));
        try std.testing.expect(try re.match(ta, "Performance"));
        try std.testing.expect(!try re.match(ta, "performances"));
        try std.testing.expect(!try re.match(ta, "xperformance"));
    }
    {
        var re = try regex.compile(ta, "\\A([\\w.]+)@(\\w+)\\.(\\w+)\\z");
        defer re.deinit();
        try std.testing.expect(re.onepass != null);
        const subs = (try re.findSubmatch(ta, "john.doe@example.com")).?;
        defer ta.free(subs);
        try std.testing.expectEqualStrings("john.doe", subs[1].?);
        try std.testing.expectEqualStrings("example", subs[2].?);
        try std.testing.expectEqualStrings("com", subs[3].?);
        try std.testing.expect((try re.findSubmatch(ta, "not an email")) == null);
    }
    {
        var re = try regex.compile(ta, "\\A\\d{4}-\\d{2}-\\d{2}\\z");
        defer re.deinit();
        try std.testing.expect(re.onepass != null);
        try std.testing.expect(try re.match(ta, "2024-01-15"));
        try std.testing.expect(!try re.match(ta, "2024-1-15"));
    }
}

test "scratch reuse carries no stale state across patterns" {
    var scratch = regex.Scratch.init(ta);
    defer scratch.deinit();

    const Case = struct { p: []const u8, in: []const u8 };
    // One reused scratch, six different patterns (literal/alternation → bitstate,
    // anchored → one-pass, larger → Pike VM) interleaving match / no-match /
    // match. Each result must equal a fresh allocating re.match, proving the
    // reused queues, thread pool and sparse sets carry no state between calls.
    const cases = [_]Case{
        .{ .p = "abc", .in = "xabcy" }, // match
        .{ .p = "abc", .in = "ab" }, // NO match
        .{ .p = "a(b|c)d", .in = "acd" }, // match (alternation)
        .{ .p = "\\A\\d+\\z", .in = "12a45" }, // NO match (one-pass)
        .{ .p = "\\A[a-z]+@[a-z]+\\z", .in = "user@host" }, // match (one-pass)
        .{ .p = "(foo|bar|baz)+", .in = "zzbarfoozz" }, // match
    };
    for (cases) |c| {
        var re = try regex.compile(ta, c.p);
        defer re.deinit();
        const want = try re.match(ta, c.in); // fresh, allocating reference
        try std.testing.expectEqual(want, try re.matchScratch(&scratch, c.in));
        // Repeat to prove steady-state reuse stays stable.
        try std.testing.expectEqual(want, try re.matchScratch(&scratch, c.in));
        try std.testing.expectEqual(want, try re.matchScratch(&scratch, c.in));
    }

    // The same scratch now drives submatch extraction (ncap grows from 0): the
    // borrowed result must match the allocating findSubmatchIndex every time.
    const subcases = [_]Case{
        .{ .p = "(\\w+)@(\\w+)", .in = "me@host" },
        .{ .p = "(\\w+)@(\\w+)", .in = "nope" }, // NO match
        .{ .p = "(a+)(b+)", .in = "aaabb" },
        .{ .p = "(\\w+)@(\\w+)", .in = "x@y" },
    };
    for (subcases) |c| {
        var re = try regex.compile(ta, c.p);
        defer re.deinit();
        const want = try re.findSubmatchIndex(ta, c.in);
        defer if (want) |w| ta.free(w);
        const got = try re.findSubmatchIndexScratch(&scratch, c.in);
        if (want) |w| {
            try std.testing.expect(got != null);
            try std.testing.expectEqualSlices(i64, w, got.?);
        } else {
            try std.testing.expect(got == null);
        }
        // findIndexScratch must agree with the allocating findIndex.
        const want_idx = try re.findIndex(ta, c.in);
        const got_idx = try re.findIndexScratch(&scratch, c.in);
        try std.testing.expectEqual(want_idx, got_idx);
    }
}

test "first-byte acceleration preserves semantics" {
    // Case-insensitive literal: no literal prefix, but first_bytes = {P, p}.
    {
        var re = try regex.compile(ta, "(?i)performance");
        defer re.deinit();
        try std.testing.expectEqual(@as(usize, 2), re.first_bytes.len);
        try std.testing.expect(try re.match(ta, "mid-sentence PERFormance test"));
        try std.testing.expect(!try re.match(ta, "no hit in here at all"));
        const m = (try re.findIndex(ta, "___pErFoRmAnCe")).?;
        try std.testing.expectEqual(@as(usize, 3), m.start);
    }
    // Zero-width assertion before the first rune: the skip must recompute the
    // boundary context, or \b would be evaluated with a stale flag.
    {
        var re = try regex.compile(ta, "\\bfoo");
        defer re.deinit();
        try std.testing.expect(re.first_bytes.len > 0);
        try std.testing.expect(!try re.match(ta, "xxfoo")); // no boundary at 'f'
        try std.testing.expect(try re.match(ta, "xx foo"));
    }
    // A fold cycle that leaves ASCII must disable the acceleration entirely,
    // not silently miss the exotic fold: (?i)k also matches U+212A KELVIN SIGN.
    {
        var re = try regex.compile(ta, "(?i)kilo");
        defer re.deinit();
        try std.testing.expectEqual(@as(usize, 0), re.first_bytes.len);
        try std.testing.expect(try re.match(ta, "\u{212A}ilo"));
    }
}

test "one-pass literal-prefix skip" {
    var re = try regex.compile(ta, "\\Afoobar(\\d+)\\z");
    defer re.deinit();
    try std.testing.expect(re.onepass != null);
    try std.testing.expectEqualStrings("foobar", re.literalPrefix().prefix);
    const subs = (try re.findSubmatch(ta, "foobar123")).?;
    defer ta.free(subs);
    try std.testing.expectEqualStrings("123", subs[1].?);
    try std.testing.expect(!try re.match(ta, "fooba_123"));
    try std.testing.expect(!try re.match(ta, "xfoobar12"));
    try std.testing.expect(!try re.match(ta, "foobar"));
}

test "replace func" {
    var re = try regex.compile(ta, "\\d+");
    defer re.deinit();
    const Ctx = struct {};
    const out = try re.replaceAllStringFunc(ta, "a1b22", Ctx{}, struct {
        fn f(_: Ctx, m: []const u8) []const u8 {
            return if (m.len > 1) "[BIG]" else "[d]";
        }
    }.f);
    defer ta.free(out);
    try std.testing.expectEqualStrings("a[d]b[BIG]", out);
}

fn exerciseExecutionAllocationFailures(allocator: std.mem.Allocator, re: *const regex.Regexp, input: []const u8) !void {
    const matches = try re.findAllSubmatchIndex(allocator, input, -1);
    defer if (matches) |m| regex.Regexp.freeAllSubmatchIndex(allocator, m);
    try std.testing.expect(matches != null);
}

test "execution and collected captures clean up on allocation failure" {
    var re = try regex.compile(ta, "(a|b)+");
    defer re.deinit();
    // Growth must go through alloc: an in-place resize/remap succeeds or not
    // depending on heap layout, which would change the allocation count
    // between runs (NondeterministicMemoryUsage). resize_index only advances
    // on success, so fail index 0 fails every resize.
    var no_resize = std.testing.FailingAllocator.init(ta, .{ .resize_fail_index = 0 });
    const backing = no_resize.allocator();
    try std.testing.checkAllAllocationFailures(backing, exerciseExecutionAllocationFailures, .{ &re, "aa bb aa bb aa bb aa bb aa bb aa bb" });
    const input = try ta.alloc(u8, 40000);
    defer ta.free(input);
    @memset(input, 'a');
    try std.testing.checkAllAllocationFailures(backing, exerciseExecutionAllocationFailures, .{ &re, input });
}

test "literal fast paths agree with engine results without allocations" {
    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "needle", .input = "a needle in text" },
        .{ .pattern = "needle", .input = "absent" },
        .{ .pattern = "", .input = "\xff" },
        .{ .pattern = "日", .input = "\xff日本" },
        .{ .pattern = "a", .input = "\xffa" },
        .{ .pattern = "�", .input = "\xff" },
        .{ .pattern = "^a$", .input = "ba" },
        .{ .pattern = "(a)", .input = "ba" },
    };
    for (cases) |c| {
        var re = try regex.compile(ta, c.pattern);
        defer re.deinit();
        const expected = try re.findSubmatchIndex(ta, c.input);
        defer if (expected) |m| ta.free(m);
        const actual = try re.findIndex(ta, c.input);
        try std.testing.expectEqual(expected != null, actual != null);
        if (actual) |m| {
            try std.testing.expectEqual(@as(usize, @intCast(expected.?[0])), m.start);
            try std.testing.expectEqual(@as(usize, @intCast(expected.?[1])), m.end);
        }
        try std.testing.expectEqual(expected != null, try re.match(ta, c.input));
        var scratch = regex.Scratch.init(ta);
        defer scratch.deinit();
        try std.testing.expectEqual(actual, try re.findIndexScratch(&scratch, c.input));
        try std.testing.expectEqual(expected != null, try re.matchScratch(&scratch, c.input));
    }
    var re = try regex.compile(ta, "needle");
    defer re.deinit();
    var failing = std.testing.FailingAllocator.init(ta, .{ .fail_index = 0 });
    try std.testing.expect(try re.match(failing.allocator(), "find needle"));
    try std.testing.expectEqual(regex.Match{ .start = 5, .end = 11 }, (try re.findIndex(failing.allocator(), "find needle")).?);
}

fn scratchScans(allocator: std.mem.Allocator, re: *const regex.Regexp, scratch: *regex.Scratch) !usize {
    _ = allocator;
    var total: usize = 0;
    for ([_][]const u8{ "ab ac ab", "xx", "abab ac" }) |input| {
        var it = try re.matchesScratch(scratch, input, -1);
        defer it.deinit();
        while (try it.next()) |m| total += @intCast(m[1] - m[0]);
    }
    return total;
}

test "matchesScratch agrees with matches and allocates nothing once warm" {
    var re = try regex.compile(ta, "a(b|c)");
    defer re.deinit();
    const inputs = [_][]const u8{ "ab ac ab", "", "zzz", "acab" };
    var scratch = regex.Scratch.init(ta);
    defer scratch.deinit();
    for (inputs) |input| {
        var a = try re.matches(ta, input, -1);
        defer a.deinit();
        var b = try re.matchesScratch(&scratch, input, -1);
        defer b.deinit();
        while (true) {
            const x = try a.next();
            const y = try b.next();
            try std.testing.expectEqual(x == null, y == null);
            if (x == null) break;
            try std.testing.expectEqualSlices(i64, x.?, y.?);
        }
    }
    // Warm the scratch, then every further scan must succeed with an
    // allocator that fails on first use.
    var warm = regex.Scratch.init(ta);
    defer warm.deinit();
    _ = try scratchScans(ta, &re, &warm);
    var failing = std.testing.FailingAllocator.init(ta, .{ .fail_index = 0 });
    warm.allocator = failing.allocator();
    const n = try scratchScans(failing.allocator(), &re, &warm);
    warm.allocator = ta;
    try std.testing.expectEqual(@as(usize, 12), n);
}

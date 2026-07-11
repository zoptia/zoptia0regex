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
    const input = "a" ** 200 ++ "b"; // no '$' reachable after the trailing b
    try std.testing.expect(try re.match(ta, input));
    var re2 = try regex.compile(ta, "(a+)+b");
    defer re2.deinit();
    const input2 = "a" ** 500; // never a 'b' -> no match, but must not blow up
    try std.testing.expect(!try re2.match(ta, input2));
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
    const pat = ("(" ** 3000) ++ "a" ++ (")" ** 3000);
    try std.testing.expectError(error.NestingDepth, regex.compile(ta, pat));
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

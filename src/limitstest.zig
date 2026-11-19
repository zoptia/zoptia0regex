//! Parser resource limits: Go's checkLimits (rune budget, program-size
//! estimate with its numRegexp / repeats gates, tree height) and the
//! factor recursion. Every expectation was recorded from Go 1.27.1
//! (`regexp.Compile` / `CompilePOSIX`; `ni` is
//! `len(syntax.Compile(syntax.Parse(p, flags).Simplify()).Inst)`).
//!
//! Patterns are built at run time. Accepted multi-million-instruction cases
//! only parse here (compiling them is slow in Debug); their instruction
//! counts were checked against Go in a ReleaseSafe build.

const std = @import("std");
const ast = @import("ast.zig");
const parse = @import("parse.zig");
const regex = @import("regexp.zig");

const ta = std.testing.allocator;

/// Concatenate `parts`, where each part is repeated `.n` times.
const Part = struct { s: []const u8, n: usize = 1 };

/// `unit` repeated `k` times, as one part list.
fn times(comptime k: usize, comptime unit: []const Part) [k * unit.len]Part {
    var out: [k * unit.len]Part = undefined;
    for (0..k) |i| {
        for (unit, 0..) |u, j| out[i * unit.len + j] = u;
    }
    return out;
}

fn build(parts: []const Part) ![]u8 {
    var len: usize = 0;
    for (parts) |p| len += p.s.len * p.n;
    const buf = try ta.alloc(u8, len);
    var k: usize = 0;
    for (parts) |p| {
        for (0..p.n) |_| {
            @memcpy(buf[k..][0..p.s.len], p.s);
            k += p.s.len;
        }
    }
    return buf;
}

const Mode = enum { perl, posix };

fn compileMode(pattern: []const u8, mode: Mode) parse.ParseError!regex.Regexp {
    return switch (mode) {
        .perl => regex.compile(ta, pattern),
        .posix => regex.compilePOSIX(ta, pattern),
    };
}

fn expectOk(parts: []const Part, mode: Mode, ni: usize) !void {
    const pattern = try build(parts);
    defer ta.free(pattern);
    var re = try compileMode(pattern, mode);
    defer re.deinit();
    try std.testing.expectEqual(ni, re.prog.insts.len);
}

fn expectErr(parts: []const Part, mode: Mode, want: parse.ParseError) !void {
    const pattern = try build(parts);
    defer ta.free(pattern);
    var diag: regex.Diagnostic = .{};
    const result = switch (mode) {
        .perl => regex.compileDiagnostic(ta, pattern, &diag),
        .posix => regex.compilePOSIXDiagnostic(ta, pattern, &diag),
    };
    if (result) |compiled| {
        var re = compiled;
        re.deinit();
        return error.TestExpectedError;
    } else |err| try std.testing.expectEqual(want, err);
    try std.testing.expectEqual(@as(?parse.ParseError, want), diag.err);
    if (want == error.TooLarge or want == error.NestingDepth) {
        // Go recovers these from a panic with Expr set to the whole
        // pattern (the caller's bytes, not a copy).
        try std.testing.expectEqual(pattern.ptr, diag.expr.ptr);
        try std.testing.expectEqual(pattern.len, diag.expr.len);
    }
}

/// Parse only (Perl flags); for accepted patterns too large to compile
/// quickly in Debug.
fn expectParses(parts: []const Part) !void {
    const pattern = try build(parts);
    defer ta.free(pattern);
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    _ = try parse.parse(arena.allocator(), pattern, ast.Perl);
}

// --- P1: factor recursion depth ---

test "limits: factor recursion boundary (height 1000)" {
    // '.'*999+'x|'+'.'*999+'y' → Go OK ni=1002; with 1000 dots → NestingDepth.
    try expectOk(&.{ .{ .s = ".", .n = 999 }, .{ .s = "x|" }, .{ .s = ".", .n = 999 }, .{ .s = "y" } }, .perl, 1002);
    try expectErr(&.{ .{ .s = ".", .n = 1000 }, .{ .s = "x|" }, .{ .s = ".", .n = 1000 }, .{ .s = "y" } }, .perl, error.NestingDepth);
    try expectErr(&.{ .{ .s = ".", .n = 1000 }, .{ .s = "x|" }, .{ .s = ".", .n = 1000 }, .{ .s = "y" } }, .posix, error.NestingDepth);
    // '(?:'+'[ab]'*999+'x|'+'[ab]'*999+'y)' → Go OK ni=1002; 1000 → NestingDepth.
    try expectOk(&.{ .{ .s = "(?:" }, .{ .s = "[ab]", .n = 999 }, .{ .s = "x|" }, .{ .s = "[ab]", .n = 999 }, .{ .s = "y)" } }, .perl, 1002);
    try expectErr(&.{ .{ .s = "(?:" }, .{ .s = "[ab]", .n = 1000 }, .{ .s = "x|" }, .{ .s = "[ab]", .n = 1000 }, .{ .s = "y)" } }, .perl, error.NestingDepth);
}

test "limits: deep factor recursion does not overflow the native stack" {
    // Go: NestingDepth after recursing n deep (it used to segfault here).
    try expectErr(&.{ .{ .s = ".", .n = 5000 }, .{ .s = "x|" }, .{ .s = ".", .n = 5000 }, .{ .s = "y" } }, .perl, error.NestingDepth);
    try expectErr(&.{ .{ .s = "(?:" }, .{ .s = "[ab]", .n = 5000 }, .{ .s = "x|" }, .{ .s = "[ab]", .n = 5000 }, .{ .s = "y)" } }, .perl, error.NestingDepth);
}

// --- tree height ---

test "limits: group nesting boundary" {
    // '('*999+'a'+')'*999 → Go OK ni=2001 (Perl and POSIX); 1000 → NestingDepth.
    try expectOk(&.{ .{ .s = "(", .n = 999 }, .{ .s = "a" }, .{ .s = ")", .n = 999 } }, .perl, 2001);
    try expectOk(&.{ .{ .s = "(", .n = 999 }, .{ .s = "a" }, .{ .s = ")", .n = 999 } }, .posix, 2001);
    try expectErr(&.{ .{ .s = "(", .n = 1000 }, .{ .s = "a" }, .{ .s = ")", .n = 1000 } }, .perl, error.NestingDepth);
    try expectErr(&.{ .{ .s = "(", .n = 1000 }, .{ .s = "a" }, .{ .s = ")", .n = 1000 } }, .posix, error.NestingDepth);
    // Non-capturing groups add no height: '(?:'*1000+'a'+')'*1000 → Go OK ni=3.
    try expectOk(&.{ .{ .s = "(?:", .n = 1000 }, .{ .s = "a" }, .{ .s = ")", .n = 1000 } }, .perl, 3);
}

// --- P3/P4: program-size estimate (checkSize) ---

test "limits: size budget boundary via one repeat" {
    // '(?:'+'a'*3355+'){1000}' → Go OK ni=3355002 (size 3355000 <= 3355443);
    // 3356 → TooLarge. The second push of the repeat (by the final concat)
    // squares the repeat product, which is what turns size tracking on.
    try expectParses(&.{ .{ .s = "(?:" }, .{ .s = "a", .n = 3355 }, .{ .s = "){1000}" } });
    try expectErr(&.{ .{ .s = "(?:" }, .{ .s = "a", .n = 3356 }, .{ .s = "){1000}" } }, .perl, error.TooLarge);
    // With the repeats it needs, (a)–(c) of the audit:
    // ('(?:'+'a*'*150+'){1000}')*10 → Go TooLarge (port used to accept).
    const p3a_unit = [_]Part{ .{ .s = "(?:" }, .{ .s = "a*", .n = 150 }, .{ .s = "){1000}" } };
    try expectErr(&times(10, &p3a_unit), .perl, error.TooLarge);
    // '(?:'+'a*'*150+'){1000}' → Go OK ni=300002.
    try expectOk(&p3a_unit, .perl, 300002);
    // '(?:'+'a'*4000+'){1000}' → Go TooLarge, without building the program.
    try expectErr(&.{ .{ .s = "(?:" }, .{ .s = "a", .n = 4000 }, .{ .s = "){1000}" } }, .perl, error.TooLarge);
    // '(?:'+'a'*4000+'){1000})' → Go TooLarge (not UnexpectedParen): the
    // size check runs at the repeat, before the stray ')'.
    try expectErr(&.{ .{ .s = "(?:" }, .{ .s = "a", .n = 4000 }, .{ .s = "){1000})" } }, .perl, error.TooLarge);
}

test "limits: size tracking started early by the repeat product" {
    // x{1000}y{1000} makes repeats = 1e6, so every later node is sized.
    // 'x{1000}y{1000}(?:'+'a'*3355+'){1000}' → Go TooLarge (2000 + 3355000).
    try expectErr(&.{ .{ .s = "x{1000}y{1000}(?:" }, .{ .s = "a", .n = 3355 }, .{ .s = "){1000}" } }, .perl, error.TooLarge);
    // Go's size cache is stale for a literal that grows after it was sized:
    // 'x{1000}y{1000}(?:b'+'a'*4000+'c*){1000}' → Go OK ni=4005002, while
    // '(?:b'+'a'*4000+'c*){1000}' (sized only at the end) → Go TooLarge.
    try expectParses(&.{ .{ .s = "x{1000}y{1000}(?:b" }, .{ .s = "a", .n = 4000 }, .{ .s = "c*){1000}" } });
    try expectErr(&.{ .{ .s = "(?:b" }, .{ .s = "a", .n = 4000 }, .{ .s = "c*){1000}" } }, .perl, error.TooLarge);
}

test "limits: a recycled node keeps its stale size" {
    // collapse recycles the sized group alternation (size ~1.7M) and factor
    // takes it back from the free list as the prefix literal `a`; Go's size
    // map still holds the old entry, so the estimate doubles.
    // 'x{1000}y{1000}(?:(?:'+'a{1000}'*1700+'|q)|ab|ac)' → Go TooLarge;
    // without the common prefix ('...|q)|ab)') → Go OK ni=1702007, and
    // with 1600 repeats ('...|q)|ab|ac)') → Go OK ni=1602007.
    try expectErr(&.{ .{ .s = "x{1000}y{1000}(?:(?:" }, .{ .s = "a{1000}", .n = 1700 }, .{ .s = "|q)|ab|ac)" } }, .perl, error.TooLarge);
    try expectParses(&.{ .{ .s = "x{1000}y{1000}(?:(?:" }, .{ .s = "a{1000}", .n = 1700 }, .{ .s = "|q)|ab)" } });
    try expectParses(&.{ .{ .s = "x{1000}y{1000}(?:(?:" }, .{ .s = "a{1000}", .n = 1600 }, .{ .s = "|q)|ab|ac)" } });
}

test "limits: large flat patterns Go accepts" {
    // Node reuse keeps numRegexp tiny for a long literal, so the size check
    // never starts: 'a'*3400000 → Go OK ni=3400002 (over maxSize).
    try expectParses(&.{.{ .s = "a", .n = 3_400_000 }});
    // '.'*2000001 and '(?:'+'.'*2000001+')' → Go OK ni=2000003 (the port
    // used to cap the parse stack at 2M nodes).
    try expectParses(&.{.{ .s = ".", .n = 2_000_001 }});
    try expectParses(&.{ .{ .s = "(?:" }, .{ .s = ".", .n = 2_000_001 }, .{ .s = ")" } });
}

test "limits: nested repeats" {
    // Go: InvalidRepeatSize (Perl and POSIX), after the size checks pass.
    try expectErr(&.{.{ .s = "(?:(?:a{100}){10}){1000}" }}, .perl, error.InvalidRepeatSize);
    try expectErr(&.{.{ .s = "((((a{2}){2}){2}){2}){1000}" }}, .perl, error.InvalidRepeatSize);
    try expectErr(&.{.{ .s = "((((a{2}){2}){2}){2}){1000}" }}, .posix, error.InvalidRepeatSize);
}

// --- rune budget (maxRunes) ---

test "limits: rune budget boundary" {
    // Each push counts the node's runes again, so a deeply grouped \pL is
    // counted once per level. ('(?:'*908+'\pL'+')'*908)*9 → Go OK ni=11;
    // with 909 levels → TooLarge.
    const unit_ok = [_]Part{ .{ .s = "(?:", .n = 908 }, .{ .s = "\\pL" }, .{ .s = ")", .n = 908 } };
    const unit_big = [_]Part{ .{ .s = "(?:", .n = 909 }, .{ .s = "\\pL" }, .{ .s = ")", .n = 909 } };
    try expectOk(&times(9, &unit_ok), .perl, 11);
    try expectErr(&times(9, &unit_big), .perl, error.TooLarge);
}

// --- P2: class merging stays linear ---

fn appendRune(list: *std.ArrayList(u8), r: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(r, &buf);
    try list.appendSlice(ta, buf[0..n]);
}

test "limits: merging a long alternation into a class is linear" {
    // '|'.join(chr(0x10000+2*i) for i in range(20000)) → Go OK ni=3;
    // '|'.join('x'+chr(0x10000+2*i) for i in range(20000)) → Go OK ni=4.
    // Both used to copy the whole class on every merge (1.5 GB for the
    // first at 20000 alternatives); the parse arena must now stay small.
    for ([_][]const u8{ "", "x" }, [_]usize{ 3, 4 }) |prefix, ni| {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(ta);
        for (0..20000) |i| {
            if (i > 0) try list.append(ta, '|');
            try list.appendSlice(ta, prefix);
            try appendRune(&list, @intCast(0x10000 + 2 * i));
        }
        var arena = std.heap.ArenaAllocator.init(ta);
        defer arena.deinit();
        _ = try parse.parse(arena.allocator(), list.items, ast.Perl);
        try std.testing.expect(arena.queryCapacity() < 16 << 20);

        var re = try regex.compile(ta, list.items);
        defer re.deinit();
        try std.testing.expectEqual(ni, re.prog.insts.len);
    }
}

// --- P5: Literal flag ---

test "limits: Literal flag builds one literal node like Go's literalRegexp" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const al = arena.allocator();
    // Go: Parse("k", Literal|FoldCase) → OpLiteral [107], no minFoldRune.
    const k = try parse.parse(al, "k", ast.Literal | ast.FoldCase);
    try std.testing.expectEqual(ast.Op.literal, k.op);
    try std.testing.expectEqualSlices(u21, &.{'k'}, k.runes);
    try std.testing.expectEqual(ast.Literal | ast.FoldCase, k.flags);
    // Go: Parse("", Literal) → zero-rune OpLiteral.
    const e = try parse.parse(al, "", ast.Literal);
    try std.testing.expectEqual(ast.Op.literal, e.op);
    try std.testing.expectEqual(@as(usize, 0), e.runes.len);
    // Go: Parse("Ka*", Literal) → OpLiteral [75 97 42].
    const s = try parse.parse(al, "Ka*", ast.Literal);
    try std.testing.expectEqualSlices(u21, &.{ 'K', 'a', '*' }, s.runes);
    // Go: Parse("\xff", Literal) → ErrInvalidUTF8.
    try std.testing.expectError(error.InvalidUTF8, parse.parse(al, "\xff", ast.Literal));
}

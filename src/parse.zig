//! The regular-expression parser: turns a pattern string into an AST,
//! faithfully porting Go's `regexp/syntax.parse`.
//!
//! The stack machine, operator precedence, repetition handling, group/flag
//! parsing and character-class construction all mirror Go. We deliberately
//! drop Go's allocation micro-optimizations (the `p.free` free-list, the
//! incremental literal coalescing in `maybeConcat`, and the alternation
//! `factor`/`mergeCharClass` prefix optimizations): none affect the matched
//! language or match priority, and the compiler emits identical instructions.
//! All nodes are allocated from a caller-provided arena.

const std = @import("std");
const ast = @import("ast.zig");
const unicode = @import("unicode.zig");

const Regexp = ast.Regexp;
const Op = ast.Op;
const Flags = ast.Flags;

const max_rune: u21 = unicode.max_rune;

pub const RuneRest = struct { r: u21, rest: []const u8 };

pub const ParseError = error{
    InvalidCharClass,
    InvalidCharRange,
    InvalidEscape,
    InvalidNamedCapture,
    InvalidPerlOp,
    InvalidRepeatOp,
    InvalidRepeatSize,
    InvalidUTF8,
    MissingBracket,
    MissingParen,
    MissingRepeatArgument,
    TrailingBackslash,
    UnexpectedParen,
    NestingDepth,
    TooLarge,
    OutOfMemory,
};

/// Parse `pattern` under `flags` and return the AST root.
pub fn parse(arena: std.mem.Allocator, pattern: []const u8, flags: Flags) ParseError!*Regexp {
    var p = Parser{ .al = arena, .flags = flags, .whole = pattern };

    if (flags & ast.Literal != 0) {
        try checkUTF8(pattern);
        var s = pattern;
        while (s.len != 0) {
            const nr = try nextRune(s);
            try p.literal(nr.r);
            s = nr.rest;
        }
        return try p.finish();
    }

    var lastRepeat: []const u8 = "";
    var t = pattern;
    while (t.len != 0) {
        var repeat: []const u8 = "";
        const ch = t[0];
        switch (ch) {
            '(' => {
                if (p.flags & ast.PerlX != 0 and t.len >= 2 and t[1] == '?') {
                    t = try p.parsePerlFlags(t);
                } else {
                    p.num_cap += 1;
                    (try p.op(.left_paren)).cap = p.num_cap;
                    t = t[1..];
                }
            },
            '|' => {
                try p.parseVerticalBar();
                t = t[1..];
            },
            ')' => {
                try p.parseRightParen();
                t = t[1..];
            },
            '^' => {
                _ = try p.op(if (p.flags & ast.OneLine != 0) .begin_text else .begin_line);
                t = t[1..];
            },
            '$' => {
                if (p.flags & ast.OneLine != 0) {
                    (try p.op(.end_text)).flags |= ast.WasDollar;
                } else {
                    _ = try p.op(.end_line);
                }
                t = t[1..];
            },
            '.' => {
                _ = try p.op(if (p.flags & ast.DotNL != 0) .any_char else .any_char_not_nl);
                t = t[1..];
            },
            '[' => {
                t = try p.parseClass(t);
            },
            '*', '+', '?' => {
                const before = t;
                const o: Op = switch (ch) {
                    '*' => .star,
                    '+' => .plus,
                    else => .quest,
                };
                t = try p.repeat(o, 0, 0, before, t[1..], lastRepeat);
                repeat = before;
            },
            '{' => {
                const before = t;
                const pr = p.parseRepeat(t);
                if (!pr.ok) {
                    // Not a valid repeat: treat { as a literal.
                    try p.literal('{');
                    t = t[1..];
                } else {
                    if (pr.min < 0 or pr.min > 1000 or pr.max > 1000 or (pr.max >= 0 and pr.min > pr.max)) {
                        return error.InvalidRepeatSize;
                    }
                    t = try p.repeat(.repeat, pr.min, pr.max, before, pr.rest, lastRepeat);
                    repeat = before;
                }
            },
            '\\' => {
                t = try p.parseBackslashAtom(t);
            },
            else => {
                const nr = try nextRune(t);
                try p.literal(nr.r);
                t = nr.rest;
            },
        }
        lastRepeat = repeat;
    }
    return try p.finish();
}

const Parser = struct {
    al: std.mem.Allocator,
    flags: Flags,
    whole: []const u8,
    stack: std.ArrayList(*Regexp) = .empty,
    num_cap: i32 = 0,

    fn newRegexp(p: *Parser, o: Op) !*Regexp {
        const re = try p.al.create(Regexp);
        re.* = .{ .op = o };
        return re;
    }

    fn push(p: *Parser, re: *Regexp) !void {
        try p.stack.append(p.al, re);
        if (p.stack.items.len > 2_000_000) return error.TooLarge;
    }

    fn op(p: *Parser, o: Op) !*Regexp {
        const re = try p.newRegexp(o);
        re.flags = p.flags;
        try p.push(re);
        return re;
    }

    fn literal(p: *Parser, r: u21) !void {
        const re = try p.newRegexp(.literal);
        re.flags = p.flags;
        var rr = r;
        if (p.flags & ast.FoldCase != 0) rr = unicode.minFoldRune(r);
        re.runes = try p.al.dupe(u21, &[_]u21{rr});
        try p.push(re);
    }

    /// Finalize parsing: collapse the remaining stack into a single root.
    fn finish(p: *Parser) !*Regexp {
        _ = try p.concat();
        if (try p.swapVerticalBar()) _ = p.stack.pop();
        _ = try p.alternate();
        if (p.stack.items.len != 1) return error.MissingParen;
        return p.stack.items[0];
    }

    // --- repetition ---

    fn repeat(p: *Parser, o: Op, min: i32, max: i32, before: []const u8, after0: []const u8, lastRepeat: []const u8) ![]const u8 {
        _ = before;
        var after = after0;
        var flags = p.flags;
        if (p.flags & ast.PerlX != 0) {
            if (after.len > 0 and after[0] == '?') {
                after = after[1..];
                flags ^= ast.NonGreedy;
            }
            if (lastRepeat.len != 0) {
                // a** is an error in Perl (no stacked repetition operators).
                return error.InvalidRepeatOp;
            }
        }
        const n = p.stack.items.len;
        if (n == 0) return error.MissingRepeatArgument;
        const sub = p.stack.items[n - 1];
        if (sub.op.isPseudo()) return error.MissingRepeatArgument;

        const re = try p.newRegexp(o);
        re.min = min;
        re.max = max;
        re.flags = flags;
        re.sub = try p.al.dupe(*Regexp, &[_]*Regexp{sub});
        p.stack.items[n - 1] = re;

        if (o == .repeat and (min >= 2 or max >= 2) and !repeatIsValid(re, 1000)) {
            return error.InvalidRepeatSize;
        }
        return after;
    }

    const RepeatSpec = struct { min: i32, max: i32, rest: []const u8, ok: bool };

    fn parseRepeat(p: *Parser, s0: []const u8) RepeatSpec {
        var none = RepeatSpec{ .min = 0, .max = 0, .rest = "", .ok = false };
        var s = s0;
        if (s.len == 0 or s[0] != '{') return none;
        s = s[1..];
        const mn = p.parseInt(s);
        if (!mn.ok) return none;
        s = mn.rest;
        var min = mn.n;
        var max: i32 = undefined;
        if (s.len == 0) return none;
        if (s[0] != ',') {
            max = min;
        } else {
            s = s[1..];
            if (s.len == 0) return none;
            if (s[0] == '}') {
                max = -1;
            } else {
                const mx = p.parseInt(s);
                if (!mx.ok) return none;
                s = mx.rest;
                max = mx.n;
                if (max < 0) min = -1; // parseInt overflow
            }
        }
        if (s.len == 0 or s[0] != '}') return none;
        none.min = min;
        none.max = max;
        none.rest = s[1..];
        none.ok = true;
        return none;
    }

    const IntSpec = struct { n: i32, rest: []const u8, ok: bool };

    fn parseInt(p: *Parser, s0: []const u8) IntSpec {
        _ = p;
        var s = s0;
        if (s.len == 0 or s[0] < '0' or s[0] > '9') return .{ .n = 0, .rest = s, .ok = false };
        // Disallow leading zeros.
        if (s.len >= 2 and s[0] == '0' and s[1] >= '0' and s[1] <= '9') {
            return .{ .n = 0, .rest = s, .ok = false };
        }
        const t = s;
        while (s.len != 0 and s[0] >= '0' and s[0] <= '9') s = s[1..];
        const digits = t[0 .. t.len - s.len];
        var n: i32 = 0;
        for (digits) |d| {
            if (n >= 1e8) {
                n = -1;
                break;
            }
            n = n * 10 + @as(i32, d - '0');
        }
        return .{ .n = n, .rest = s, .ok = true };
    }

    // --- stack collapsing ---

    fn concat(p: *Parser) !*Regexp {
        var i = p.stack.items.len;
        while (i > 0 and !p.stack.items[i - 1].op.isPseudo()) i -= 1;
        const subs = p.stack.items[i..];
        const re = if (subs.len == 0)
            try p.newRegexp(.empty_match)
        else
            try p.collapse(subs, .concat);
        p.stack.shrinkRetainingCapacity(i);
        try p.push(re);
        return re;
    }

    fn alternate(p: *Parser) !*Regexp {
        var i = p.stack.items.len;
        while (i > 0 and !p.stack.items[i - 1].op.isPseudo()) i -= 1;
        const subs = p.stack.items[i..];
        const re = if (subs.len == 0)
            try p.newRegexp(.no_match)
        else
            try p.collapse(subs, .alternate);
        p.stack.shrinkRetainingCapacity(i);
        try p.push(re);
        return re;
    }

    /// Apply `o` to `subs`, hoisting nested same-op nodes so there is never a
    /// concat-of-concat or alternate-of-alternate. (Go's `factor` prefix
    /// optimization is intentionally omitted — it does not change semantics.)
    fn collapse(p: *Parser, subs: []*Regexp, o: Op) !*Regexp {
        if (subs.len == 1) return subs[0];
        var list: std.ArrayList(*Regexp) = .empty;
        for (subs) |sub| {
            if (sub.op == o) {
                try list.appendSlice(p.al, sub.sub);
            } else {
                try list.append(p.al, sub);
            }
        }
        const re = try p.newRegexp(o);
        re.sub = try list.toOwnedSlice(p.al);
        return re;
    }

    fn parseVerticalBar(p: *Parser) !void {
        _ = try p.concat();
        if (!try p.swapVerticalBar()) {
            _ = try p.op(.vertical_bar);
        }
    }

    /// If the top of the stack is an element above an opVerticalBar, swap them
    /// and return true. (The char-class merge fast path Go has is omitted.)
    fn swapVerticalBar(p: *Parser) !bool {
        const n = p.stack.items.len;
        if (n >= 2) {
            const re1 = p.stack.items[n - 1];
            const re2 = p.stack.items[n - 2];
            if (re2.op == .vertical_bar) {
                p.stack.items[n - 2] = re1;
                p.stack.items[n - 1] = re2;
                return true;
            }
        }
        return false;
    }

    fn parseRightParen(p: *Parser) !void {
        _ = try p.concat();
        if (try p.swapVerticalBar()) _ = p.stack.pop();
        _ = try p.alternate();

        const n = p.stack.items.len;
        if (n < 2) return error.UnexpectedParen;
        const re1 = p.stack.items[n - 1];
        const re2 = p.stack.items[n - 2];
        p.stack.shrinkRetainingCapacity(n - 2);
        if (re2.op != .left_paren) return error.UnexpectedParen;

        p.flags = re2.flags; // restore flags at time of paren
        if (re2.cap == 0) {
            try p.push(re1);
        } else {
            re2.op = .capture;
            re2.sub = try p.al.dupe(*Regexp, &[_]*Regexp{re1});
            try p.push(re2);
        }
    }

    // --- Perl flags / named groups ---

    fn parsePerlFlags(p: *Parser, s: []const u8) ![]const u8 {
        const t0 = s;
        // Named captures: (?P<name>  or  (?<name>
        const startsWithP = t0.len > 4 and t0[2] == 'P' and t0[3] == '<';
        const startsWithName = t0.len > 3 and t0[2] == '<';
        if (startsWithP or startsWithName) {
            const exprStart: usize = if (startsWithName) 3 else 4;
            const end = std.mem.indexOfScalar(u8, t0, '>') orelse {
                // Go reports invalid UTF-8 before the missing-'>' error.
                try checkUTF8(t0);
                return error.InvalidNamedCapture;
            };
            const name = t0[exprStart..end];
            try checkUTF8(name);
            if (!isValidCaptureName(name)) return error.InvalidNamedCapture;
            p.num_cap += 1;
            const re = try p.op(.left_paren);
            re.cap = p.num_cap;
            re.name = name;
            return t0[end + 1 ..];
        }

        // Non-capturing group and/or flag changes.
        var t = s[2..]; // skip (?
        var flags = p.flags;
        var sign: i32 = 1;
        var sawFlag = false;
        while (t.len != 0) {
            const nr = try nextRune(t);
            const c = nr.r;
            t = nr.rest;
            switch (c) {
                'i' => {
                    flags |= ast.FoldCase;
                    sawFlag = true;
                },
                'm' => {
                    flags &= ~ast.OneLine;
                    sawFlag = true;
                },
                's' => {
                    flags |= ast.DotNL;
                    sawFlag = true;
                },
                'U' => {
                    flags |= ast.NonGreedy;
                    sawFlag = true;
                },
                '-' => {
                    if (sign < 0) return error.InvalidPerlOp;
                    sign = -1;
                    flags = ~flags;
                    sawFlag = false;
                },
                ':', ')' => {
                    if (sign < 0) {
                        if (!sawFlag) return error.InvalidPerlOp;
                        flags = ~flags;
                    }
                    if (c == ':') {
                        _ = try p.op(.left_paren);
                    }
                    p.flags = flags;
                    return t;
                },
                else => return error.InvalidPerlOp,
            }
        }
        return error.InvalidPerlOp;
    }

    // --- escapes ---

    fn parseBackslashAtom(p: *Parser, t0: []const u8) ![]const u8 {
        const t = t0;
        if (p.flags & ast.PerlX != 0 and t.len >= 2) {
            switch (t[1]) {
                'A' => {
                    _ = try p.op(.begin_text);
                    return t[2..];
                },
                'b' => {
                    _ = try p.op(.word_boundary);
                    return t[2..];
                },
                'B' => {
                    _ = try p.op(.no_word_boundary);
                    return t[2..];
                },
                'C' => return error.InvalidEscape, // any byte: unsupported
                'Q' => {
                    var lit = t[2..];
                    var rest: []const u8 = "";
                    if (std.mem.indexOf(u8, lit, "\\E")) |idx| {
                        rest = lit[idx + 2 ..];
                        lit = lit[0..idx];
                    }
                    while (lit.len != 0) {
                        const nr = try nextRune(lit);
                        try p.literal(nr.r);
                        lit = nr.rest;
                    }
                    return rest;
                },
                'z' => {
                    _ = try p.op(.end_text);
                    return t[2..];
                },
                else => {},
            }
        }

        // Character-class escapes: \p{...} and \d \w \s etc.
        var class: std.ArrayList(u21) = .empty;
        if (t.len >= 2 and (t[1] == 'p' or t[1] == 'P')) {
            if (try p.parseUnicodeClass(t, &class)) |nt| {
                return try p.pushClass(&class, nt);
            }
        }
        if (try p.parsePerlClassEscape(t, &class)) |nt| {
            return try p.pushClass(&class, nt);
        }
        class.deinit(p.al);

        // Ordinary single-character escape.
        const esc = try p.parseEscape(t);
        try p.literal(esc.r);
        return esc.rest;
    }

    fn pushClass(p: *Parser, class: *std.ArrayList(u21), rest: []const u8) ![]const u8 {
        const re = try p.newRegexp(.char_class);
        re.flags = p.flags;
        re.runes = try class.toOwnedSlice(p.al);
        try p.push(re);
        return rest;
    }

    // --- escapes ---

    fn parseEscape(p: *Parser, s: []const u8) !RuneRest {
        _ = p;
        var t = s[1..]; // skip backslash
        if (t.len == 0) return error.TrailingBackslash;
        const nr = try nextRune(t);
        const c = nr.r;
        t = nr.rest;
        switch (c) {
            // Octal escapes.
            '0'...'7' => {
                if (c != '0') {
                    // A single non-zero digit is a backreference; unsupported
                    // unless followed by another octal digit.
                    if (t.len == 0 or t[0] < '0' or t[0] > '7') return error.InvalidEscape;
                }
                var r: u21 = @intCast(c - '0');
                var i: usize = 1;
                while (i < 3) : (i += 1) {
                    if (t.len == 0 or t[0] < '0' or t[0] > '7') break;
                    r = r * 8 + @as(u21, t[0] - '0');
                    t = t[1..];
                }
                return .{ .r = r, .rest = t };
            },
            // Hexadecimal escapes.
            'x' => {
                if (t.len == 0) return error.InvalidEscape;
                const nr2 = try nextRune(t);
                const c2 = nr2.r;
                t = nr2.rest;
                if (c2 == '{') {
                    var acc: u32 = 0;
                    var nhex: usize = 0;
                    while (true) {
                        if (t.len == 0) return error.InvalidEscape;
                        const e = try nextRune(t);
                        t = e.rest;
                        if (e.r == '}') break;
                        const v = unhex(e.r);
                        if (v < 0) return error.InvalidEscape;
                        acc = acc * 16 + @as(u32, @intCast(v));
                        if (acc > max_rune) return error.InvalidEscape;
                        nhex += 1;
                    }
                    if (nhex == 0) return error.InvalidEscape;
                    return .{ .r = @intCast(acc), .rest = t };
                }
                // Two hex digits.
                const x = unhex(c2);
                const e3 = try nextRune(t);
                t = e3.rest;
                const y = unhex(e3.r);
                if (x < 0 or y < 0) return error.InvalidEscape;
                return .{ .r = @intCast(x * 16 + y), .rest = t };
            },
            // C escapes (no \b here — that is the word boundary in Perl mode).
            'a' => return .{ .r = 0x07, .rest = t },
            'f' => return .{ .r = 0x0C, .rest = t },
            'n' => return .{ .r = '\n', .rest = t },
            'r' => return .{ .r = '\r', .rest = t },
            't' => return .{ .r = '\t', .rest = t },
            'v' => return .{ .r = 0x0B, .rest = t },
            else => {
                if (c < 0x80 and !isalnum(c)) {
                    // Escaped non-word ASCII characters are themselves.
                    return .{ .r = c, .rest = t };
                }
                return error.InvalidEscape;
            },
        }
    }

    // --- character classes ---

    fn parseClassChar(p: *Parser, s: []const u8) !RuneRest {
        if (s.len == 0) return error.MissingBracket;
        // Allow regular escape sequences inside a class.
        if (s[0] == '\\') return p.parseEscape(s);
        return nextRune(s);
    }

    fn parseClass(p: *Parser, s: []const u8) ![]const u8 {
        var t = s[1..]; // chop [
        const re = try p.newRegexp(.char_class);
        re.flags = p.flags;
        var class: std.ArrayList(u21) = .empty;

        var sign: i32 = 1;
        if (t.len > 0 and t[0] == '^') {
            sign = -1;
            t = t[1..];
            // If the class won't match \n, add it so negation does the right thing.
            if (p.flags & ast.ClassNL == 0) {
                try class.appendSlice(p.al, &[_]u21{ '\n', '\n' });
            }
        }

        var first = true; // ] and - are okay as first char
        while (t.len == 0 or t[0] != ']' or first) {
            // POSIX: '-' is only allowed unescaped as first or last in class.
            if (t.len > 0 and t[0] == '-' and (p.flags & ast.PerlX == 0) and !first and (t.len == 1 or t[1] != ']')) {
                return error.InvalidCharRange;
            }
            first = false;

            // POSIX [:alnum:] etc.
            if (t.len > 2 and t[0] == '[' and t[1] == ':') {
                if (try p.parseNamedClass(t, &class)) |nt| {
                    t = nt;
                    continue;
                }
            }
            // Unicode \p{...}.
            if (try p.parseUnicodeClass(t, &class)) |nt| {
                t = nt;
                continue;
            }
            // Perl \d \w \s.
            if (try p.parsePerlClassEscape(t, &class)) |nt| {
                t = nt;
                continue;
            }

            // Single character or range.
            const lc = try p.parseClassChar(t);
            const lo = lc.r;
            t = lc.rest;
            var hi = lo;
            if (t.len >= 2 and t[0] == '-' and t[1] != ']') {
                t = t[1..];
                const hc = try p.parseClassChar(t);
                hi = hc.r;
                t = hc.rest;
                if (hi < lo) return error.InvalidCharRange;
            }
            if (p.flags & ast.FoldCase == 0) {
                try appendRange(p.al, &class, lo, hi);
            } else {
                try appendFoldedRange(p.al, &class, lo, hi);
            }
        }
        t = t[1..]; // chop ]

        cleanClass(&class);
        if (sign < 0) try negateClass(p.al, &class);
        re.runes = try class.toOwnedSlice(p.al);
        try p.push(re);
        return t;
    }

    fn parseNamedClass(p: *Parser, s: []const u8, class: *std.ArrayList(u21)) !?[]const u8 {
        if (s.len < 2 or s[0] != '[' or s[1] != ':') return null;
        const idx = std.mem.indexOf(u8, s[2..], ":]") orelse return null;
        const i = idx + 2;
        const name = s[0 .. i + 2];
        const rest = s[i + 2 ..];
        const g = posixGroup(name) orelse return error.InvalidCharRange;
        try p.appendGroup(class, g);
        return rest;
    }

    fn parsePerlClassEscape(p: *Parser, s: []const u8, class: *std.ArrayList(u21)) !?[]const u8 {
        if (p.flags & ast.PerlX == 0 or s.len < 2 or s[0] != '\\') return null;
        const g = perlGroup(s[0..2]) orelse return null;
        try p.appendGroup(class, g);
        return s[2..];
    }

    fn parseUnicodeClass(p: *Parser, s: []const u8, class: *std.ArrayList(u21)) !?[]const u8 {
        if (p.flags & ast.UnicodeGroups == 0 or s.len < 2 or s[0] != '\\' or (s[1] != 'p' and s[1] != 'P')) return null;

        var sign: i32 = if (s[1] == 'P') -1 else 1;
        var t = s[2..];
        const nr = try nextRune(t);
        const c = nr.r;
        t = nr.rest;
        var name: []const u8 = undefined;
        if (c != '{') {
            const seq = s[0 .. s.len - t.len];
            name = seq[2..];
        } else {
            const end = std.mem.indexOfScalar(u8, s, '}') orelse {
                try checkUTF8(s);
                return error.InvalidCharRange;
            };
            t = s[end + 1 ..];
            name = s[3..end];
            try checkUTF8(name);
        }
        if (name.len > 0 and name[0] == '^') {
            sign = -sign;
            name = name[1..];
        }
        const tr = (try unicode.unicodeTable(p.al, name)) orelse return error.InvalidCharRange;
        if (tr.sign < 0) sign = -sign;
        // Note: Go merges a fold table here under (?i); our subset has no fold
        // tables (equivalent to Go's fold == nil branch), so we append directly.
        if (sign > 0) {
            try appendTable(p.al, class, tr.ranges);
        } else {
            try appendNegatedTable(p.al, class, tr.ranges);
        }
        return t;
    }

    fn appendGroup(p: *Parser, class: *std.ArrayList(u21), g: CharGroup) !void {
        if (p.flags & ast.FoldCase == 0) {
            if (g.sign < 0) {
                try appendNegatedClass(p.al, class, g.class);
            } else {
                try appendClass(p.al, class, g.class);
            }
        } else {
            var tmp: std.ArrayList(u21) = .empty;
            defer tmp.deinit(p.al);
            try appendFoldedClass(p.al, &tmp, g.class);
            cleanClass(&tmp);
            if (g.sign < 0) {
                try appendNegatedClass(p.al, class, tmp.items);
            } else {
                try appendClass(p.al, class, tmp.items);
            }
        }
    }
};

// --- character-class range helpers ---

fn appendRange(al: std.mem.Allocator, list: *std.ArrayList(u21), lo: u21, hi: u21) !void {
    const n = list.items.len;
    var i: usize = 2;
    while (i <= 4) : (i += 2) {
        if (n >= i) {
            const rlo = list.items[n - i];
            const rhi = list.items[n - i + 1];
            if (@as(i64, lo) <= @as(i64, rhi) + 1 and @as(i64, rlo) <= @as(i64, hi) + 1) {
                if (lo < rlo) list.items[n - i] = lo;
                if (hi > rhi) list.items[n - i + 1] = hi;
                return;
            }
        }
    }
    try list.append(al, lo);
    try list.append(al, hi);
}

fn appendFoldedRange(al: std.mem.Allocator, list: *std.ArrayList(u21), lo0: u21, hi0: u21) !void {
    const minF = unicode.min_fold;
    const maxF = unicode.max_fold;
    if (lo0 <= minF and hi0 >= maxF) {
        try appendRange(al, list, lo0, hi0);
        return;
    }
    if (hi0 < minF or lo0 > maxF) {
        try appendRange(al, list, lo0, hi0);
        return;
    }
    var lo = lo0;
    var hi = hi0;
    if (lo < minF) {
        try appendRange(al, list, lo, minF - 1);
        lo = minF;
    }
    if (hi > maxF) {
        try appendRange(al, list, maxF + 1, hi);
        hi = maxF;
    }
    var c: u32 = lo;
    while (c <= hi) : (c += 1) {
        const cc: u21 = @intCast(c);
        try appendRange(al, list, cc, cc);
        var f = unicode.simpleFold(cc);
        while (f != cc) : (f = unicode.simpleFold(f)) {
            try appendRange(al, list, f, f);
        }
    }
}

fn appendClass(al: std.mem.Allocator, list: *std.ArrayList(u21), x: []const u21) !void {
    var i: usize = 0;
    while (i < x.len) : (i += 2) try appendRange(al, list, x[i], x[i + 1]);
}

fn appendFoldedClass(al: std.mem.Allocator, list: *std.ArrayList(u21), x: []const u21) !void {
    var i: usize = 0;
    while (i < x.len) : (i += 2) try appendFoldedRange(al, list, x[i], x[i + 1]);
}

fn appendNegatedClass(al: std.mem.Allocator, list: *std.ArrayList(u21), x: []const u21) !void {
    var next_lo: i64 = 0;
    var i: usize = 0;
    while (i < x.len) : (i += 2) {
        const lo = x[i];
        const hi = x[i + 1];
        if (next_lo <= @as(i64, lo) - 1) {
            try appendRange(al, list, @intCast(next_lo), lo - 1);
        }
        next_lo = @as(i64, hi) + 1;
    }
    if (next_lo <= max_rune) try appendRange(al, list, @intCast(next_lo), max_rune);
}

fn appendTable(al: std.mem.Allocator, list: *std.ArrayList(u21), ranges: []const unicode.URange) !void {
    for (ranges) |xr| {
        if (xr.stride == 1) {
            try appendRange(al, list, xr.lo, xr.hi);
        } else {
            var c: u32 = xr.lo;
            while (c <= xr.hi) : (c += xr.stride) try appendRange(al, list, @intCast(c), @intCast(c));
        }
    }
}

fn appendNegatedTable(al: std.mem.Allocator, list: *std.ArrayList(u21), ranges: []const unicode.URange) !void {
    var next_lo: i64 = 0;
    for (ranges) |xr| {
        if (xr.stride == 1) {
            if (next_lo <= @as(i64, xr.lo) - 1) try appendRange(al, list, @intCast(next_lo), xr.lo - 1);
            next_lo = @as(i64, xr.hi) + 1;
        } else {
            var c: u32 = xr.lo;
            while (c <= xr.hi) : (c += xr.stride) {
                if (next_lo <= @as(i64, c) - 1) try appendRange(al, list, @intCast(next_lo), @intCast(c - 1));
                next_lo = @as(i64, c) + 1;
            }
        }
    }
    if (next_lo <= max_rune) try appendRange(al, list, @intCast(next_lo), max_rune);
}

/// Sort range pairs (lo ascending, hi descending to break ties), then merge
/// abutting/overlapping ranges. Mirrors Go's `cleanClass`.
fn cleanClass(list: *std.ArrayList(u21)) void {
    const r = list.items;
    if (r.len < 2) return;
    const n2 = r.len / 2;
    const pairs: [][2]u21 = @as([*][2]u21, @ptrCast(@alignCast(r.ptr)))[0..n2];
    std.mem.sort([2]u21, pairs, {}, struct {
        fn lt(_: void, a: [2]u21, b: [2]u21) bool {
            return a[0] < b[0] or (a[0] == b[0] and a[1] > b[1]);
        }
    }.lt);

    var w: usize = 2;
    var i: usize = 2;
    while (i < r.len) : (i += 2) {
        const lo = r[i];
        const hi = r[i + 1];
        if (@as(i64, lo) <= @as(i64, r[w - 1]) + 1) {
            if (hi > r[w - 1]) r[w - 1] = hi;
            continue;
        }
        r[w] = lo;
        r[w + 1] = hi;
        w += 2;
    }
    list.shrinkRetainingCapacity(w);
}

/// Replace the class with its negation. Mirrors Go's `negateClass`.
fn negateClass(al: std.mem.Allocator, list: *std.ArrayList(u21)) !void {
    const r = list.items;
    var next_lo: i64 = 0;
    var w: usize = 0;
    var i: usize = 0;
    while (i < r.len) : (i += 2) {
        const lo = r[i];
        const hi = r[i + 1];
        if (next_lo <= @as(i64, lo) - 1) {
            r[w] = @intCast(next_lo);
            r[w + 1] = lo - 1;
            w += 2;
        }
        next_lo = @as(i64, hi) + 1;
    }
    list.shrinkRetainingCapacity(w);
    if (next_lo <= max_rune) {
        try list.append(al, @intCast(next_lo));
        try list.append(al, max_rune);
    }
}

fn repeatIsValid(re: *const Regexp, n: i32) bool {
    var nn = n;
    if (re.op == .repeat) {
        var m = re.max;
        if (m == 0) return true;
        if (m < 0) m = re.min;
        if (m > n) return false;
        if (m > 0) nn = @divTrunc(n, m);
    }
    for (re.sub) |sub| {
        if (!repeatIsValid(sub, nn)) return false;
    }
    return true;
}

// --- small scanning helpers ---

fn nextRune(s: []const u8) ParseError!RuneRest {
    if (s.len == 0) return .{ .r = 0xFFFD, .rest = s };
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return error.InvalidUTF8;
    if (n > s.len) return error.InvalidUTF8;
    const r = std.unicode.utf8Decode(s[0..n]) catch return error.InvalidUTF8;
    return .{ .r = r, .rest = s[n..] };
}

fn checkUTF8(s0: []const u8) ParseError!void {
    var s = s0;
    while (s.len != 0) {
        const nr = try nextRune(s);
        s = nr.rest;
    }
}

fn isalnum(c: u21) bool {
    return ('0' <= c and c <= '9') or ('A' <= c and c <= 'Z') or ('a' <= c and c <= 'z');
}

fn unhex(c: u21) i32 {
    if ('0' <= c and c <= '9') return @as(i32, @intCast(c)) - '0';
    if ('a' <= c and c <= 'f') return @as(i32, @intCast(c)) - 'a' + 10;
    if ('A' <= c and c <= 'F') return @as(i32, @intCast(c)) - 'A' + 10;
    return -1;
}

fn isValidCaptureName(name: []const u8) bool {
    if (name.len == 0) return false;
    // Names are ASCII [A-Za-z0-9_]+ in practice; validate per byte.
    for (name) |c| {
        if (c != '_' and !(('0' <= c and c <= '9') or ('A' <= c and c <= 'Z') or ('a' <= c and c <= 'z'))) {
            return false;
        }
    }
    return true;
}

// --- Perl/POSIX character group tables (from Go's perl_groups.go) ---

const CharGroup = struct { sign: i32, class: []const u21 };

const code_d = [_]u21{ 0x30, 0x39 };
const code_s = [_]u21{ 0x9, 0xa, 0xc, 0xd, 0x20, 0x20 };
const code_w = [_]u21{ 0x30, 0x39, 0x41, 0x5a, 0x5f, 0x5f, 0x61, 0x7a };

fn perlGroup(s2: []const u8) ?CharGroup {
    if (s2.len < 2 or s2[0] != '\\') return null;
    return switch (s2[1]) {
        'd' => .{ .sign = 1, .class = &code_d },
        'D' => .{ .sign = -1, .class = &code_d },
        's' => .{ .sign = 1, .class = &code_s },
        'S' => .{ .sign = -1, .class = &code_s },
        'w' => .{ .sign = 1, .class = &code_w },
        'W' => .{ .sign = -1, .class = &code_w },
        else => null,
    };
}

const code_alnum = [_]u21{ 0x30, 0x39, 0x41, 0x5a, 0x61, 0x7a };
const code_alpha = [_]u21{ 0x41, 0x5a, 0x61, 0x7a };
const code_ascii = [_]u21{ 0x0, 0x7f };
const code_blank = [_]u21{ 0x9, 0x9, 0x20, 0x20 };
const code_cntrl = [_]u21{ 0x0, 0x1f, 0x7f, 0x7f };
const code_digit = [_]u21{ 0x30, 0x39 };
const code_graph = [_]u21{ 0x21, 0x7e };
const code_lower = [_]u21{ 0x61, 0x7a };
const code_print = [_]u21{ 0x20, 0x7e };
const code_punct = [_]u21{ 0x21, 0x2f, 0x3a, 0x40, 0x5b, 0x60, 0x7b, 0x7e };
const code_space = [_]u21{ 0x9, 0xd, 0x20, 0x20 };
const code_upper = [_]u21{ 0x41, 0x5a };
const code_word = [_]u21{ 0x30, 0x39, 0x41, 0x5a, 0x5f, 0x5f, 0x61, 0x7a };
const code_xdigit = [_]u21{ 0x30, 0x39, 0x41, 0x46, 0x61, 0x66 };

/// Look up a POSIX named class given the full token, e.g. "[:alnum:]" or
/// "[:^alnum:]".
fn posixGroup(token: []const u8) ?CharGroup {
    if (token.len < 4 or token[0] != '[' or token[1] != ':') return null;
    if (!std.mem.endsWith(u8, token, ":]")) return null;
    var inner = token[2 .. token.len - 2];
    var sign: i32 = 1;
    if (inner.len > 0 and inner[0] == '^') {
        sign = -1;
        inner = inner[1..];
    }
    const class: []const u21 =
        if (std.mem.eql(u8, inner, "alnum")) &code_alnum else if (std.mem.eql(u8, inner, "alpha")) &code_alpha else if (std.mem.eql(u8, inner, "ascii")) &code_ascii else if (std.mem.eql(u8, inner, "blank")) &code_blank else if (std.mem.eql(u8, inner, "cntrl")) &code_cntrl else if (std.mem.eql(u8, inner, "digit")) &code_digit else if (std.mem.eql(u8, inner, "graph")) &code_graph else if (std.mem.eql(u8, inner, "lower")) &code_lower else if (std.mem.eql(u8, inner, "print")) &code_print else if (std.mem.eql(u8, inner, "punct")) &code_punct else if (std.mem.eql(u8, inner, "space")) &code_space else if (std.mem.eql(u8, inner, "upper")) &code_upper else if (std.mem.eql(u8, inner, "word")) &code_word else if (std.mem.eql(u8, inner, "xdigit")) &code_xdigit else return null;
    return .{ .sign = sign, .class = class };
}

test "parseInt basics" {
    var p = Parser{ .al = std.testing.allocator, .flags = 0, .whole = "" };
    const a = p.parseInt("123}");
    try std.testing.expect(a.ok and a.n == 123);
    const b = p.parseInt("01");
    try std.testing.expect(!b.ok); // leading zero
}

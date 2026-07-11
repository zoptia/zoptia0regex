//! The public API, mirroring Go's `regexp` package: `compile`, the
//! `find`/`match`/`replace`/`split` families, submatch extraction, and
//! `$`-template expansion.
//!
//! Memory model: a compiled `Regexp` owns a heap-allocated arena that holds
//! its program, capture names and literal prefix; `deinit` frees it. Execution
//! and result-producing methods each take an `allocator` used for transient VM
//! scratch and (where noted) the returned slice, which the caller owns.

const std = @import("std");
const ast = @import("ast.zig");
const parse = @import("parse.zig");
const simplify = @import("simplify.zig");
const compile_ = @import("compile.zig");
const prog = @import("prog.zig");
const exec = @import("exec.zig");
const unicode = @import("unicode.zig");
const onepass = @import("onepass.zig");

pub const ParseError = parse.ParseError;
pub const ExecError = std.mem.Allocator.Error;

/// A matched byte range `input[start..end]`.
pub const Match = struct { start: usize, end: usize };

/// Reusable match storage for the allocation-free `*Scratch` API
/// (`matchScratch` / `findSubmatchIndexScratch`). Allocate once, reuse across
/// many matches on the same compiled `Regexp`. See `exec.Scratch`.
pub const Scratch = exec.Scratch;

pub const Regexp = struct {
    base_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    expr: []const u8,
    prog: prog.Prog,
    num_subexp: usize,
    subexp_names: []const []const u8,
    cond: prog.EmptyOp,
    min_input_len: usize,
    longest: bool,
    prefix: []const u8,
    prefix_complete: bool,
    onepass: ?*onepass.OnePassProg,

    pub fn deinit(re: *Regexp) void {
        const gpa = re.base_allocator;
        re.arena.deinit();
        gpa.destroy(re.arena);
    }

    /// The length Go pads submatch results to: `2*(numSubexp+1)`. This can
    /// exceed `prog.num_cap` when a capturing group is compiled away (e.g.
    /// `(a){0}`); the extra trailing slots stay -1, exactly like Go's `pad`.
    fn padLen(re: *const Regexp) usize {
        return (re.num_subexp + 1) * 2;
    }

    /// Run the engines over `input` starting at `pos` with a per-call scratch.
    /// `caps` receives the submatch offsets (its length bounds how many are
    /// recorded); returns whether a match was found.
    fn execAt(re: *const Regexp, allocator: std.mem.Allocator, input: exec.Input, pos: usize, caps: []i64) ExecError!bool {
        return exec.execute(allocator, &re.prog, re.onepass, re.longest, re.cond, re.prefix, input, pos, caps);
    }

    /// `execAt` borrowing all engine storage from a caller-owned `Scratch`.
    fn execAtScratch(re: *const Regexp, scratch: *Scratch, input: exec.Input, pos: usize, caps: []i64) ExecError!bool {
        return exec.executeReuse(scratch, &re.prog, re.onepass, re.longest, re.cond, re.prefix, input, pos, caps);
    }

    // --- introspection ---

    /// The source text the regexp was compiled from.
    pub fn string(re: *const Regexp) []const u8 {
        return re.expr;
    }

    /// Number of parenthesized subexpressions.
    pub fn numSubexp(re: *const Regexp) usize {
        return re.num_subexp;
    }

    /// Names of the capturing groups; `subexpNames()[0]` is always "".
    pub fn subexpNames(re: *const Regexp) []const []const u8 {
        return re.subexp_names;
    }

    /// Index of the first subexpression with the given name, or null.
    pub fn subexpIndex(re: *const Regexp, name: []const u8) ?usize {
        if (name.len == 0) return null;
        for (re.subexp_names, 0..) |s, i| {
            if (std.mem.eql(u8, name, s)) return i;
        }
        return null;
    }

    /// A literal string that must begin any match, and whether it is the whole
    /// regexp.
    pub fn literalPrefix(re: *const Regexp) struct { prefix: []const u8, complete: bool } {
        return .{ .prefix = re.prefix, .complete = re.prefix_complete };
    }

    /// Switch to leftmost-longest (POSIX) matching for future searches.
    pub fn setLongest(re: *Regexp) void {
        re.longest = true;
    }

    // --- boolean match ---

    /// Reports whether `input` contains any match.
    pub fn match(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!bool {
        if (input.len < re.min_input_len) return false;
        var caps: [0]i64 = .{};
        return try re.execAt(allocator, .{ .s = input }, 0, &caps);
    }

    /// Alias of `match` (Go distinguishes `[]byte` and `string`; here both are
    /// `[]const u8`).
    pub fn matchString(re: *const Regexp, allocator: std.mem.Allocator, s: []const u8) ExecError!bool {
        return re.match(allocator, s);
    }

    /// Like `match`, but reuses a caller-owned `Scratch` instead of allocating
    /// per call. Allocate one `Scratch` (`Scratch.init(gpa)` / `deinit`) and
    /// reuse it across many matches on the same compiled `Regexp`; after it has
    /// warmed up, each call does zero heap allocation. Single-threaded: do not
    /// share one `Scratch` between concurrent matches.
    pub fn matchScratch(re: *const Regexp, scratch: *Scratch, input: []const u8) ExecError!bool {
        if (input.len < re.min_input_len) return false;
        var caps: [0]i64 = .{};
        return try re.execAtScratch(scratch, .{ .s = input }, 0, &caps);
    }

    /// Like `findIndex`, but reuses a caller-owned `Scratch` instead of
    /// allocating per call. See `matchScratch` for the reuse contract.
    pub fn findIndexScratch(re: *const Regexp, scratch: *Scratch, input: []const u8) ExecError!?Match {
        if (input.len < re.min_input_len) return null;
        var caps: [2]i64 = .{ -1, -1 };
        const matched = try re.execAtScratch(scratch, .{ .s = input }, 0, &caps);
        if (!matched) return null;
        return Match{ .start = @intCast(caps[0]), .end = @intCast(caps[1]) };
    }

    /// Like `findSubmatchIndex`, but reuses a caller-owned `Scratch`. The
    /// returned slice is owned by `scratch` and valid only until the next call
    /// that reuses it — copy it if you need to keep it. Do NOT free it. Null if
    /// there is no match.
    pub fn findSubmatchIndexScratch(re: *const Regexp, scratch: *Scratch, input: []const u8) ExecError!?[]i64 {
        if (input.len < re.min_input_len) return null;
        const caps = try scratch.resultBuf(re.padLen());
        const matched = try re.execAtScratch(scratch, .{ .s = input }, 0, caps);
        if (!matched) return null;
        return caps;
    }

    // --- find leftmost ---

    /// Leftmost match location, or null.
    pub fn findIndex(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!?Match {
        if (input.len < re.min_input_len) return null;
        var caps: [2]i64 = .{ -1, -1 };
        const matched = try re.execAt(allocator, .{ .s = input }, 0, &caps);
        if (!matched) return null;
        return Match{ .start = @intCast(caps[0]), .end = @intCast(caps[1]) };
    }

    /// Text of the leftmost match (a sub-slice of `input`), or null.
    pub fn find(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!?[]const u8 {
        const m = (try re.findIndex(allocator, input)) orelse return null;
        return input[m.start..m.end];
    }

    // --- find with submatches ---

    /// Submatch byte offsets [start0,end0,start1,end1,...] (length
    /// `2*(numSubexp+1)`; -1 for groups that did not participate). Caller owns
    /// the returned slice. Null if there is no match.
    pub fn findSubmatchIndex(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!?[]i64 {
        if (input.len < re.min_input_len) return null;
        const caps = try allocator.alloc(i64, re.padLen());
        errdefer allocator.free(caps);
        const matched = try re.execAt(allocator, .{ .s = input }, 0, caps);
        if (!matched) {
            allocator.free(caps);
            return null;
        }
        return caps;
    }

    /// Submatch texts (sub-slices of `input`; null for non-participating
    /// groups). Caller owns the outer slice. Null if there is no match.
    pub fn findSubmatch(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!?[]?[]const u8 {
        const caps = (try re.findSubmatchIndex(allocator, input)) orelse return null;
        defer allocator.free(caps);
        const n = caps.len / 2;
        const out = try allocator.alloc(?[]const u8, n);
        for (0..n) |k| {
            if (caps[2 * k] < 0 or caps[2 * k + 1] < 0) {
                out[k] = null;
            } else {
                out[k] = input[@intCast(caps[2 * k])..@intCast(caps[2 * k + 1])];
            }
        }
        return out;
    }

    // --- find all ---

    /// Collect up to `n` (n < 0 means all) successive match cap-arrays, each of
    /// length `re.prog.num_cap`. Mirrors Go's `allMatches`, including the
    /// empty-match advancement rule.
    fn allMatches(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64) ExecError!std.ArrayList([]i64) {
        var matches: std.ArrayList([]i64) = .empty;
        errdefer {
            for (matches.items) |c| allocator.free(c);
            matches.deinit(allocator);
        }
        const end = input.len;
        const limit: i64 = if (n < 0) std.math.maxInt(i64) else n;
        var pos: usize = 0;
        var count: i64 = 0;
        var prev_match_end: i64 = -1;
        const in = exec.Input{ .s = input };

        while (count < limit and pos <= end) {
            const caps = try allocator.alloc(i64, re.padLen());
            errdefer allocator.free(caps);
            const matched = try re.execAt(allocator, in, pos, caps);
            if (!matched) {
                allocator.free(caps);
                break;
            }
            var accept = true;
            if (caps[1] == @as(i64, @intCast(pos))) {
                // Empty match: don't allow it right after a previous match.
                if (caps[0] == prev_match_end) accept = false;
                const w = in.step(pos).w;
                if (w > 0) pos += w else pos = end + 1;
            } else {
                pos = @intCast(caps[1]);
            }
            prev_match_end = caps[1];
            if (accept) {
                try matches.append(allocator, caps);
                count += 1;
            } else {
                allocator.free(caps);
            }
        }
        return matches;
    }

    /// Locations of all successive matches (n < 0: all). Caller owns the slice.
    /// Null if there are no matches.
    pub fn findAllIndex(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64) ExecError!?[]Match {
        var matches = try re.allMatches(allocator, input, n);
        defer {
            for (matches.items) |c| allocator.free(c);
            matches.deinit(allocator);
        }
        if (matches.items.len == 0) return null;
        const out = try allocator.alloc(Match, matches.items.len);
        for (matches.items, 0..) |c, i| out[i] = .{ .start = @intCast(c[0]), .end = @intCast(c[1]) };
        return out;
    }

    /// Texts of all successive matches (sub-slices of `input`). Caller owns the
    /// outer slice. Null if there are no matches.
    pub fn findAll(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64) ExecError!?[][]const u8 {
        var matches = try re.allMatches(allocator, input, n);
        defer {
            for (matches.items) |c| allocator.free(c);
            matches.deinit(allocator);
        }
        if (matches.items.len == 0) return null;
        const out = try allocator.alloc([]const u8, matches.items.len);
        for (matches.items, 0..) |c, i| out[i] = input[@intCast(c[0])..@intCast(c[1])];
        return out;
    }

    /// Submatch offsets of all successive matches. Each inner slice has length
    /// `2*(numSubexp+1)`. Caller owns every inner slice and the outer slice;
    /// free with `freeAllSubmatchIndex`. Null if there are no matches.
    pub fn findAllSubmatchIndex(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64) ExecError!?[][]i64 {
        var matches = try re.allMatches(allocator, input, n);
        errdefer {
            for (matches.items) |c| allocator.free(c);
            matches.deinit(allocator);
        }
        if (matches.items.len == 0) {
            matches.deinit(allocator);
            return null;
        }
        return try matches.toOwnedSlice(allocator);
    }

    pub fn freeAllSubmatchIndex(allocator: std.mem.Allocator, x: [][]i64) void {
        for (x) |c| allocator.free(c);
        allocator.free(x);
    }

    // --- replace ---

    /// Replace every match with `repl`, expanding `$1` / `${name}` references
    /// (see `expand`). Caller owns the result.
    pub fn replaceAllString(re: *const Regexp, allocator: std.mem.Allocator, src: []const u8, repl: []const u8) ExecError![]u8 {
        const ncap: usize = if (std.mem.indexOfScalar(u8, repl, '$') != null) re.padLen() else 2;
        const Ctx = struct { re: *const Regexp, repl: []const u8 };
        return re.replaceAllCore(allocator, src, ncap, Ctx{ .re = re, .repl = repl }, struct {
            fn f(ctx: Ctx, al: std.mem.Allocator, buf: *std.ArrayList(u8), m: []i64, source: []const u8) ExecError!void {
                try ctx.re.expandInto(al, buf, ctx.repl, source, m);
            }
        }.f);
    }

    /// Replace every match with `repl` literally (no `$` expansion).
    pub fn replaceAllLiteralString(re: *const Regexp, allocator: std.mem.Allocator, src: []const u8, repl: []const u8) ExecError![]u8 {
        const Ctx = struct { repl: []const u8 };
        return re.replaceAllCore(allocator, src, 2, Ctx{ .repl = repl }, struct {
            fn f(ctx: Ctx, al: std.mem.Allocator, buf: *std.ArrayList(u8), m: []i64, source: []const u8) ExecError!void {
                _ = m;
                _ = source;
                try buf.appendSlice(al, ctx.repl);
            }
        }.f);
    }

    /// Replace every match with the result of `func` applied to the matched
    /// text. `func` returns a slice valid for the duration of the call.
    pub fn replaceAllStringFunc(
        re: *const Regexp,
        allocator: std.mem.Allocator,
        src: []const u8,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx), []const u8) []const u8,
    ) ExecError![]u8 {
        const Ctx = struct { inner: @TypeOf(ctx) };
        return re.replaceAllCore(allocator, src, 2, Ctx{ .inner = ctx }, struct {
            fn f(c: Ctx, al: std.mem.Allocator, buf: *std.ArrayList(u8), m: []i64, source: []const u8) ExecError!void {
                const matched = source[@intCast(m[0])..@intCast(m[1])];
                try buf.appendSlice(al, func(c.inner, matched));
            }
        }.f);
    }

    fn replaceAllCore(
        re: *const Regexp,
        allocator: std.mem.Allocator,
        src: []const u8,
        ncap: usize,
        ctx: anytype,
        comptime replFn: fn (@TypeOf(ctx), std.mem.Allocator, *std.ArrayList(u8), []i64, []const u8) ExecError!void,
    ) ExecError![]u8 {
        var last_match_end: usize = 0;
        var search_pos: usize = 0;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        const end_pos = src.len;
        const caps = try allocator.alloc(i64, ncap);
        defer allocator.free(caps);
        const in = exec.Input{ .s = src };

        while (search_pos <= end_pos) {
            const matched = try re.execAt(allocator, in, search_pos, caps);
            if (!matched) break;
            const a0: usize = @intCast(caps[0]);
            const a1: usize = @intCast(caps[1]);

            try buf.appendSlice(allocator, src[last_match_end..a0]);
            // Skip the replacement for an empty match right after another match.
            if (a1 > last_match_end or a0 == 0) {
                try replFn(ctx, allocator, &buf, caps, src);
            }
            last_match_end = a1;

            const w = in.step(search_pos).w;
            if (search_pos + w > a1) {
                search_pos += w;
            } else if (search_pos + 1 > a1) {
                search_pos += 1;
            } else {
                search_pos = a1;
            }
        }
        try buf.appendSlice(allocator, src[last_match_end..]);
        return try buf.toOwnedSlice(allocator);
    }

    /// Append `template` to `buf`, expanding `$name` / `${name}` / `$1`
    /// references using `match` (submatch offsets into `src`). Mirrors Go's
    /// `expand`.
    pub fn expand(re: *const Regexp, allocator: std.mem.Allocator, buf: *std.ArrayList(u8), template: []const u8, src: []const u8, m: []i64) ExecError!void {
        return re.expandInto(allocator, buf, template, src, m);
    }

    fn expandInto(re: *const Regexp, allocator: std.mem.Allocator, dst: *std.ArrayList(u8), template0: []const u8, src: []const u8, m: []i64) ExecError!void {
        var template = template0;
        while (template.len > 0) {
            const dollar = std.mem.indexOfScalar(u8, template, '$') orelse break;
            try dst.appendSlice(allocator, template[0..dollar]);
            template = template[dollar + 1 ..];
            if (template.len > 0 and template[0] == '$') {
                try dst.append(allocator, '$');
                template = template[1..];
                continue;
            }
            const ext = extract(template);
            if (!ext.ok) {
                // Malformed: emit a literal '$'.
                try dst.append(allocator, '$');
                continue;
            }
            template = ext.rest;
            if (ext.num >= 0) {
                const num: usize = @intCast(ext.num);
                if (2 * num + 1 < m.len and m[2 * num] >= 0) {
                    try dst.appendSlice(allocator, src[@intCast(m[2 * num])..@intCast(m[2 * num + 1])]);
                }
            } else {
                for (re.subexp_names, 0..) |namei, i| {
                    if (std.mem.eql(u8, ext.name, namei) and 2 * i + 1 < m.len and m[2 * i] >= 0) {
                        try dst.appendSlice(allocator, src[@intCast(m[2 * i])..@intCast(m[2 * i + 1])]);
                        break;
                    }
                }
            }
        }
        try dst.appendSlice(allocator, template);
    }

    // --- split ---

    /// Split `src` around matches (Go's `Split`). n < 0: all pieces; n == 0:
    /// none (empty); n > 0: at most n pieces. Caller owns the outer slice; the
    /// pieces are sub-slices of `src`.
    pub fn split(re: *const Regexp, allocator: std.mem.Allocator, src: []const u8, n: i64) ExecError!?[][]const u8 {
        if (n == 0) return null; // Go returns nil
        if (re.expr.len > 0 and src.len == 0) {
            const out = try allocator.alloc([]const u8, 1);
            out[0] = "";
            return out;
        }

        var matches = try re.allMatches(allocator, src, n);
        defer {
            for (matches.items) |c| allocator.free(c);
            matches.deinit(allocator);
        }

        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(allocator);
        var beg: usize = 0;
        var end: usize = 0;
        for (matches.items) |c| {
            if (n > 0 and out.items.len >= @as(usize, @intCast(n - 1))) break;
            end = @intCast(c[0]);
            // Skip a zero-length match (does not contribute a split point).
            if (c[1] != 0) try out.append(allocator, src[beg..end]);
            beg = @intCast(c[1]);
        }
        // Append the trailing piece, unless the last match ended the string.
        if (end != src.len) try out.append(allocator, src[beg..]);
        return try out.toOwnedSlice(allocator);
    }
};

const Extracted = struct { name: []const u8, num: i64, rest: []const u8, ok: bool };

/// Parse a leading `name` or `{name}` from a `$`-template. Mirrors Go's
/// `extract`.
fn extract(str0: []const u8) Extracted {
    var none = Extracted{ .name = "", .num = -1, .rest = "", .ok = false };
    var str = str0;
    if (str.len == 0) return none;
    var brace = false;
    if (str[0] == '{') {
        brace = true;
        str = str[1..];
    }
    var i: usize = 0;
    while (i < str.len) {
        const n = std.unicode.utf8ByteSequenceLength(str[i]) catch break;
        if (i + n > str.len) break;
        const r = std.unicode.utf8Decode(str[i .. i + n]) catch break;
        if (!isLetterDigitUnderscore(r)) break;
        i += n;
    }
    if (i == 0) return none; // empty name is not okay
    const name = str[0..i];
    if (brace) {
        if (i >= str.len or str[i] != '}') return none; // missing closing brace
        i += 1;
    }
    // Parse as a number if it is all digits with no leading zero.
    var num: i64 = 0;
    var isnum = true;
    for (name) |c| {
        if (c < '0' or c > '9' or num >= 100_000_000) {
            isnum = false;
            break;
        }
        num = num * 10 + @as(i64, c - '0');
    }
    if (name.len > 1 and name[0] == '0') isnum = false;
    none.name = name;
    none.num = if (isnum) num else -1;
    none.rest = str[i..];
    none.ok = true;
    return none;
}

fn isLetterDigitUnderscore(r: u21) bool {
    // Matches Go's extract: unicode.IsLetter(r) || unicode.IsDigit(r) || '_'.
    return r == '_' or unicode.isLetterOrDigit(r);
}

// --- compilation ---

fn compileInternal(gpa: std.mem.Allocator, expr: []const u8, mode: ast.Flags, longest: bool) ParseError!Regexp {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const al = arena.allocator();

    const re_ast = try parse.parse(al, expr, mode);
    const max_cap = re_ast.maxCap();

    const names = try al.alloc([]const u8, @intCast(max_cap + 1));
    for (names) |*nm| nm.* = "";
    re_ast.capNamesInto(names);

    const simplified = try simplify.simplify(al, re_ast);
    const p = try compile_.compile(al, simplified);

    const pfx = try p.prefix(al);
    const expr_owned = try al.dupe(u8, expr);

    // Build the one-pass program if the regexp qualifies (anchored, unambiguous).
    const op_prog: ?*onepass.OnePassProg = blk: {
        if (try onepass.compileOnePass(gpa, al, &p)) |opp| {
            const ptr = try al.create(onepass.OnePassProg);
            ptr.* = opp;
            break :blk ptr;
        }
        break :blk null;
    };

    return Regexp{
        .base_allocator = gpa,
        .arena = arena,
        .expr = expr_owned,
        .prog = p,
        .num_subexp = @intCast(max_cap),
        .subexp_names = names,
        .cond = p.startCond(),
        .min_input_len = minInputLen(simplified),
        .longest = longest,
        .prefix = pfx.str,
        .prefix_complete = pfx.complete,
        .onepass = op_prog,
    };
}

/// Compile `expr` with Perl (leftmost-first) semantics.
pub fn compile(gpa: std.mem.Allocator, expr: []const u8) ParseError!Regexp {
    return compileInternal(gpa, expr, ast.Perl, false);
}

/// Compile `expr` with POSIX ERE syntax and leftmost-longest semantics.
pub fn compilePOSIX(gpa: std.mem.Allocator, expr: []const u8) ParseError!Regexp {
    return compileInternal(gpa, expr, ast.POSIX, true);
}

/// Like `compile` but panics on a malformed pattern.
pub fn mustCompile(gpa: std.mem.Allocator, expr: []const u8) Regexp {
    return compile(gpa, expr) catch |e| {
        std.debug.panic("regexp: compile({s}): {s}", .{ expr, @errorName(e) });
    };
}

fn minInputLen(re: *const ast.Regexp) usize {
    switch (re.op) {
        .any_char, .any_char_not_nl, .char_class => return 1,
        .literal => {
            var l: usize = 0;
            for (re.runes) |r| {
                // An invalid input byte decodes to U+FFFD with width 1, so a
                // U+FFFD literal needs only 1 byte of input (matches Go).
                if (r == 0xFFFD) {
                    l += 1;
                } else {
                    l += std.unicode.utf8CodepointSequenceLength(r) catch 1;
                }
            }
            return l;
        },
        .capture, .plus => return minInputLen(re.sub[0]),
        .repeat => return @as(usize, @intCast(@max(re.min, 0))) * minInputLen(re.sub[0]),
        .concat => {
            var l: usize = 0;
            for (re.sub) |sub| l += minInputLen(sub);
            return l;
        },
        .alternate => {
            if (re.sub.len == 0) return 0;
            var l = minInputLen(re.sub[0]);
            for (re.sub[1..]) |sub| {
                const ln = minInputLen(sub);
                if (ln < l) l = ln;
            }
            return l;
        },
        else => return 0,
    }
}

/// Return `s` with all regular-expression metacharacters escaped. Caller owns
/// the result. Mirrors Go's `QuoteMeta`.
pub fn quoteMeta(allocator: std.mem.Allocator, s: []const u8) ExecError![]u8 {
    const special = "\\.+*?()|[]{}^$";
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, special, c) != null) {
            try buf.append(allocator, '\\');
        }
        try buf.append(allocator, c);
    }
    return try buf.toOwnedSlice(allocator);
}

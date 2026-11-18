//! The regular-expression parser: turns a pattern string into an AST,
//! faithfully porting Go's `regexp/syntax.parse`.
//!
//! The stack machine, operator precedence, repetition handling, group/flag
//! parsing and character-class construction all mirror Go, including the
//! AST-shaping passes: `maybeConcat` literal coalescing, single-rune class
//! rewriting in `push`, the `swapVerticalBar` class merge, and the
//! alternation `factor` (common-prefix extraction and class introduction).
//!
//! Go's resource limits (`checkLimits`: rune budget, program-size estimate,
//! tree height) are ported exactly, including the parts that make them
//! observable: the `p.free` node free list (it keeps `numRegexp`, which gates
//! the size and height checks, small for long literals) and the lazily
//! populated `p.size` / `p.height` caches. Nodes are allocated from the
//! caller's arena inside a parser-private `Node` wrapper that carries the
//! free-list link, both cache entries and the owned capacity of the rune list
//! (Go gets amortised growth from `append`); the public AST never sees them.
//! Go's recursive `collapse` ↔ `factor` is driven by an explicit frame stack
//! here, because Go's growable goroutine stack has no native counterpart.

const std = @import("std");
const ast = @import("ast.zig");
const unicode = @import("unicode.zig");

const Regexp = ast.Regexp;
const Op = ast.Op;
const Flags = ast.Flags;

const max_rune: u21 = unicode.max_rune;

// Resource limits, exactly Go's (parse.go).
const max_height: u32 = 1000; // Go's maxHeight: max parse-tree height
const max_size: i64 = (128 << 20) / inst_size; // Go's maxSize: program-size budget in Insts
const inst_size = 5 * 8; // Go's instSize
const max_runes: usize = (128 << 20) / rune_size; // Go's maxRunes: 128 MB budget of runes
const rune_size = 4; // Go's runeSize: bytes per rune

const RuneRest = struct { r: u21, rest: []const u8 };

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
    if (flags & ast.Literal != 0) {
        // Trivial parser for a literal string (Go's literalRegexp).
        try checkUTF8(pattern);
        return literalRegexp(arena, pattern, flags);
    }

    var p = Parser{ .al = arena, .flags = flags };

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
                    // WasDollar is read by `Regexp.equal` (as Go's Equal does).
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
                t = try p.repeat(o, 0, 0, t[1..], lastRepeat);
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
                    t = try p.repeat(.repeat, pr.min, pr.max, pr.rest, lastRepeat);
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

/// One OpLiteral node holding every rune of `s`, without case folding; the
/// empty string yields a zero-rune literal (Go's `literalRegexp`).
fn literalRegexp(al: std.mem.Allocator, s: []const u8, flags: Flags) ParseError!*Regexp {
    const n = std.unicode.utf8CountCodepoints(s) catch return error.InvalidUTF8;
    const runes = try al.alloc(u21, n);
    var i: usize = 0;
    var t = s;
    while (t.len != 0) : (i += 1) {
        const nr = try nextRune(t);
        runes[i] = nr.r;
        t = nr.rest;
    }
    const re = try al.create(Regexp);
    re.* = .{ .op = .literal, .flags = flags, .runes = runes };
    return re;
}

/// A parser-allocated AST node plus the parser-private state Go keeps beside
/// it: the free-list link (Go reuses `Sub0[0]`), the entries of Go's lazily
/// built `p.size` and `p.height` maps, and the owned capacity of `re.runes`.
/// Every `*Regexp` the parser handles is the `re` field of one of these.
const Node = struct {
    re: Regexp,
    next_free: ?*Node = null,
    /// Elements available at `re.runes.ptr` (Go's `cap(re.Rune)`); 0 when the
    /// rune list is empty or not owned.
    rune_cap: usize = 0,
    /// Go's `p.size[re]`. Like Go's map, the entry survives `reuse`, so a
    /// recycled node can report a stale size (observable; kept on purpose).
    size: i64 = 0,
    has_size: bool = false,
    /// Go's `p.height[re]`; `reuse` deletes it.
    height: u32 = 0,
    has_height: bool = false,

    fn of(re: *Regexp) *Node {
        return @fieldParentPtr("re", re);
    }
};

/// A pending `collapse(sub, OpAlternate)` → `factor` call (see
/// `Parser.factorAlternate`).
const FactorFrame = struct {
    re: *Regexp, // the alternation whose subexpressions are being factored
    sub: []*Regexp, // Go's `sub`; `out` reuses its storage, as in Go
    out: usize = 0, // len(out)
    round: u8 = 1, // 1 or 2; rounds 3 and 4 never recurse
    i: usize = 0,
    start: usize = 0,
    // Round 1 state.
    str: []const u21 = &.{},
    strflags: Flags = 0,
    istr: []const u21 = &.{},
    iflags: Flags = 0,
    prefix: ?*Regexp = null,
    // Round 2 state.
    first: ?*Regexp = null,
    ifirst: ?*Regexp = null,
};

const SizeFrame = struct { re: *Regexp, i: usize, acc: i64 };

const Parser = struct {
    al: std.mem.Allocator,
    flags: Flags,
    stack: std.ArrayList(*Regexp) = .empty,
    free: ?*Node = null,
    num_cap: i32 = 0,
    num_regexp: usize = 0, // nodes allocated (not recycled), as Go counts
    num_runes: usize = 0, // runes pushed, as Go counts
    repeats: i64 = 0, // product of all repetitions seen
    size_tracking: bool = false, // Go's p.size != nil
    height_tracking: bool = false, // Go's p.height != nil
    factor_frames: std.ArrayList(FactorFrame) = .empty,
    size_frames: std.ArrayList(SizeFrame) = .empty,

    fn newRegexp(p: *Parser, o: Op) !*Regexp {
        if (p.free) |n| {
            p.free = n.next_free;
            // Reset the node, but keep its size-cache entry like Go's map.
            n.re = .{ .op = o };
            n.next_free = null;
            n.rune_cap = 0;
            return &n.re;
        }
        const n = try p.al.create(Node);
        n.* = .{ .re = .{ .op = o } };
        p.num_regexp += 1;
        return &n.re;
    }

    fn reuse(p: *Parser, re: *Regexp) void {
        const n = Node.of(re);
        n.has_height = false;
        n.next_free = p.free;
        p.free = n;
    }

    // --- resource limits (Go's checkLimits / checkSize / checkHeight) ---

    fn checkLimits(p: *Parser, re: *Regexp) ParseError!void {
        if (p.num_runes > max_runes) return error.TooLarge;
        try p.checkSize(re);
        try p.checkHeight(re);
    }

    fn checkSize(p: *Parser, re: *Regexp) ParseError!void {
        if (!p.size_tracking) {
            // Not tracking sizes yet. Maintain the product of all repeats
            // seen and start only once nodes × repeats could exceed the
            // budget.
            if (p.repeats == 0) p.repeats = 1;
            if (re.op == .repeat) {
                var n: i64 = re.max;
                if (n == -1) n = re.min;
                if (n <= 0) n = 1;
                if (n > @divTrunc(max_size, p.repeats)) {
                    p.repeats = max_size;
                } else {
                    p.repeats *= n;
                }
            }
            if (@as(i64, @intCast(p.num_regexp)) < @divTrunc(max_size, p.repeats)) return;

            // Start tracking, belatedly covering everything on the stack.
            p.size_tracking = true;
            for (p.stack.items) |s| try p.checkSize(s);
        }
        if (try p.calcSize(re) > max_size) return error.TooLarge;
    }

    /// Go's `calcSize(re, true)`: recompute `re`'s estimated program size,
    /// using cached sizes for its descendants. Iterative, because the tree
    /// may be arbitrarily deep before the height check rejects it.
    fn calcSize(p: *Parser, root: *Regexp) !i64 {
        const frames = &p.size_frames;
        frames.clearRetainingCapacity();
        try frames.append(p.al, .{ .re = root, .i = 0, .acc = 0 });
        while (true) {
            const f = &frames.items[frames.items.len - 1];
            const re = f.re;
            const has_subs = switch (re.op) {
                .capture, .star, .plus, .quest, .concat, .alternate, .repeat => true,
                else => false,
            };
            if (has_subs and f.i < re.sub.len) {
                const child = re.sub[f.i];
                f.i += 1;
                const cn = Node.of(child);
                if (cn.has_size) {
                    f.acc +%= cn.size;
                } else {
                    try frames.append(p.al, .{ .re = child, .i = 0, .acc = 0 });
                }
                continue;
            }
            const sub = f.acc; // sum of the subexpression sizes
            var size: i64 = switch (re.op) {
                .literal => @intCast(re.runes.len),
                // star can be 1+ or 2+; assume 2 pessimistically
                .capture, .star => 2 +% sub,
                .plus, .quest => 1 +% sub,
                .concat => sub,
                .alternate => if (re.sub.len > 1) sub +% @as(i64, @intCast(re.sub.len - 1)) else sub,
                .repeat => blk: {
                    if (re.max == -1) {
                        break :blk if (re.min == 0) 2 +% sub else 1 +% @as(i64, re.min) *% sub;
                    }
                    // x{2,5} = xx(x(x(x)?)?)?
                    break :blk @as(i64, re.max) *% sub +% @as(i64, re.max - re.min);
                },
                else => 0,
            };
            size = @max(1, size);
            const n = Node.of(re);
            n.size = size;
            n.has_size = true;
            _ = frames.pop();
            if (frames.items.len == 0) return size;
            const parent = &frames.items[frames.items.len - 1];
            parent.acc +%= size;
        }
    }

    fn checkHeight(p: *Parser, re: *Regexp) ParseError!void {
        if (p.num_regexp < max_height) return;
        if (!p.height_tracking) {
            p.height_tracking = true;
            for (p.stack.items) |s| try p.checkHeight(s);
        }
        if (try calcHeight(re, true, 1) > max_height) return error.NestingDepth;
    }

    /// Go's `calcHeight`. Reaching recursion depth > max_height proves the
    /// root's height exceeds it (each level adds at least one; cached
    /// heights never under-report, since nodes only shrink in place), so the
    /// walk stops there with Go's eventual error instead of recursing on.
    fn calcHeight(re: *Regexp, force: bool, depth: u32) error{NestingDepth}!u32 {
        const n = Node.of(re);
        if (!force and n.has_height) return n.height;
        if (depth > max_height) return error.NestingDepth;
        var h: u32 = 1;
        for (re.sub) |sub| h = @max(h, 1 + try calcHeight(sub, false, depth + 1));
        n.height = h;
        n.has_height = true;
        return h;
    }

    // --- rune lists with amortised growth ---

    /// `re.runes` as a growable list over its owned capacity.
    fn runeList(p: *Parser, re: *Regexp) !std.ArrayList(u21) {
        const n = Node.of(re);
        if (n.rune_cap < re.runes.len) {
            // Not owned (defensive): copy before growing.
            var list: std.ArrayList(u21) = .empty;
            try list.appendSlice(p.al, re.runes);
            return list;
        }
        var list: std.ArrayList(u21) = .empty;
        list.items = re.runes;
        list.capacity = n.rune_cap;
        return list;
    }

    fn setRunes(re: *Regexp, list: std.ArrayList(u21)) void {
        re.runes = list.items;
        Node.of(re).rune_cap = list.capacity;
    }

    // --- stack manipulation ---

    /// Push `re` onto the stack, first coalescing literals (Go's `push`).
    /// A single-rune class becomes a literal and a case-fold pair like
    /// `[Aa]` a case-insensitive literal; either may be absorbed into the
    /// literal on top of the stack instead of being pushed.
    fn push(p: *Parser, re: *Regexp) !void {
        p.num_runes += re.runes.len;
        const rs = re.runes;
        if (re.op == .char_class and rs.len == 2 and rs[0] == rs[1]) {
            // Single rune.
            if (try p.maybeConcat(rs[0], p.flags & ~ast.FoldCase)) return;
            re.op = .literal;
            re.runes = rs[0..1];
            re.flags = p.flags & ~ast.FoldCase;
        } else if (re.op == .char_class and
            ((rs.len == 4 and rs[0] == rs[1] and rs[2] == rs[3] and
                unicode.simpleFold(rs[0]) == rs[2] and unicode.simpleFold(rs[2]) == rs[0]) or
                (rs.len == 2 and @as(u32, rs[0]) + 1 == rs[1] and
                    unicode.simpleFold(rs[0]) == rs[1] and unicode.simpleFold(rs[1]) == rs[0])))
        {
            // Case-insensitive rune like [Aa] or [Δδ].
            if (try p.maybeConcat(rs[0], p.flags | ast.FoldCase)) return;
            re.op = .literal;
            re.runes = rs[0..1];
            re.flags = p.flags | ast.FoldCase;
        } else {
            _ = try p.maybeConcat(null, 0);
        }
        try p.stack.append(p.al, re);
        try p.checkLimits(re);
    }

    /// Incremental concatenation of literal runes into string nodes (Go's
    /// `maybeConcat`). Called before each push, so only the top two stack
    /// entries can need merging; the topmost literal stays separate until the
    /// next push, so a following operator still applies to one rune (`ab*`).
    /// When `r` is non-null and the top literal was absorbed, its node is
    /// reused to hold `r` and true is returned (`r` was pushed).
    fn maybeConcat(p: *Parser, r: ?u21, flags: Flags) !bool {
        const n = p.stack.items.len;
        if (n < 2) return false;
        const re1 = p.stack.items[n - 1];
        const re2 = p.stack.items[n - 2];
        if (re1.op != .literal or re2.op != .literal or
            re1.flags & ast.FoldCase != re2.flags & ast.FoldCase) return false;

        // Push re1 into re2.
        var list = try p.runeList(re2);
        try list.appendSlice(p.al, re1.runes);
        setRunes(re2, list);

        // Reuse re1 if possible.
        if (r) |rr| {
            re1.runes = re1.runes[0..1];
            re1.runes[0] = rr;
            re1.flags = flags;
            return true;
        }
        p.stack.shrinkRetainingCapacity(n - 1);
        p.reuse(re1);
        return false;
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
        re.runes = try p.al.alloc(u21, 1);
        re.runes[0] = rr;
        Node.of(re).rune_cap = 1;
        try p.push(re);
    }

    /// Finalize parsing: collapse the remaining stack into a single root.
    fn finish(p: *Parser) !*Regexp {
        try p.concat();
        if (try p.swapVerticalBar()) _ = p.stack.pop();
        try p.alternate();
        if (p.stack.items.len != 1) return error.MissingParen;
        return p.stack.items[0];
    }

    // --- repetition ---

    // Go's repeat additionally takes `before` to slice the pattern text into
    // its positional error messages; this port's errors carry no position, so
    // the parameter is dropped.
    fn repeat(p: *Parser, o: Op, min: i32, max: i32, after0: []const u8, lastRepeat: []const u8) ![]const u8 {
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
        try p.checkLimits(re);

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
            if (n >= 100_000_000) {
                n = -1;
                break;
            }
            n = n * 10 + @as(i32, d - '0');
        }
        return .{ .n = n, .rest = s, .ok = true };
    }

    // --- stack collapsing ---

    fn concat(p: *Parser) !void {
        _ = try p.maybeConcat(null, 0);
        var i = p.stack.items.len;
        while (i > 0 and !p.stack.items[i - 1].op.isPseudo()) i -= 1;
        // Truncate first, as Go does: the limit checks inside `collapse`
        // walk the stack. Nothing is pushed until `subs` has been consumed.
        const subs = p.stack.items[i..];
        p.stack.items.len = i; // not shrinkRetainingCapacity: that may poison `subs`
        const re = if (subs.len == 0)
            try p.newRegexp(.empty_match)
        else
            try p.collapse(subs, .concat);
        try p.push(re);
    }

    fn alternate(p: *Parser) !void {
        var i = p.stack.items.len;
        while (i > 0 and !p.stack.items[i - 1].op.isPseudo()) i -= 1;
        const subs = p.stack.items[i..];
        p.stack.items.len = i; // not shrinkRetainingCapacity: that may poison `subs`
        // Make sure top class is clean; the others already are (see
        // swapVerticalBar).
        if (subs.len > 0) cleanAlt(subs[subs.len - 1]);
        const re = if (subs.len == 0)
            try p.newRegexp(.no_match)
        else
            try p.collapse(subs, .alternate);
        try p.push(re);
    }

    /// Apply `o` to `subs`, hoisting nested same-op nodes so there is never a
    /// concat-of-concat or alternate-of-alternate, and factoring alternations
    /// (Go's `collapse`).
    fn collapse(p: *Parser, subs: []const *Regexp, o: Op) ParseError!*Regexp {
        if (subs.len == 1) return subs[0];
        const re = try p.collapseNode(subs, o);
        if (o != .alternate) return re;
        return p.factorAlternate(re);
    }

    /// The flattening half of `collapse`: a new `o` node over `subs`, with
    /// same-op children spliced in and recycled.
    fn collapseNode(p: *Parser, subs: []const *Regexp, o: Op) !*Regexp {
        const re = try p.newRegexp(o);
        var n: usize = 0;
        for (subs) |sub| n += if (sub.op == o) sub.sub.len else 1;
        const list = try p.al.alloc(*Regexp, n);
        var k: usize = 0;
        for (subs) |sub| {
            if (sub.op == o) {
                @memcpy(list[k..][0..sub.sub.len], sub.sub);
                k += sub.sub.len;
                p.reuse(sub);
            } else {
                list[k] = sub;
                k += 1;
            }
        }
        re.sub = list;
        return re;
    }

    /// Run `factor` on the alternation `root` and finish Go's `collapse`
    /// (an alternation left with one subexpression is replaced by it).
    ///
    /// Go recurses `factor` → `collapse` → `factor` once per factored
    /// prefix, so a pattern like `.{n}x|.{n}y` (written out) recurses n deep
    /// before the height check can fail. Go's stack grows; ours does not, so
    /// each pending `collapse` is a heap frame here, executing the same steps
    /// in the same order.
    fn factorAlternate(p: *Parser, root: *Regexp) ParseError!*Regexp {
        const frames = &p.factor_frames;
        std.debug.assert(frames.items.len == 0);
        errdefer frames.clearRetainingCapacity();
        try frames.append(p.al, .{ .re = root, .sub = root.sub });
        var ret: ?*Regexp = null;
        while (true) {
            if (try p.factorStep(&frames.items[frames.items.len - 1], ret)) |child| {
                ret = null;
                try frames.append(p.al, .{ .re = child, .sub = child.sub });
                continue;
            }
            const f = frames.pop().?;
            var re = f.re;
            re.sub = f.sub;
            if (re.sub.len == 1) {
                const old = re;
                re = re.sub[0];
                p.reuse(old);
            }
            if (frames.items.len == 0) return re;
            ret = re;
        }
    }

    /// Advance Go's `factor` for frame `f`. Returns a new alternation whose
    /// collapse must finish first (its result is passed back as `ret` on the
    /// next call), or null once `f.sub` holds the factored list.
    ///
    /// Go's `factor` factors common prefixes out of an alternation list: for
    /// example `ABC|ABD|AEF|BCX|BCY` becomes, by literal prefix extraction,
    /// `A(B(C|D)|EF)|BC(X|Y)` and then, by character class introduction,
    /// `A(B[CD]|EF)|BC[XY]`. Leftmost-first priority is preserved: only
    /// adjacent alternatives are merged, in order.
    fn factorStep(p: *Parser, f: *FactorFrame, ret_in: ?*Regexp) ParseError!?*Regexp {
        var ret = ret_in;
        if (f.round == 1) {
            if (f.sub.len < 2) return null; // Go: nothing to factor
            // Round 1: factor out common literal prefixes.
            if (ret) |suffix| {
                f.sub[f.out] = try p.concat2(f.prefix.?, suffix);
                f.out += 1;
                f.start = f.i;
                f.str = f.istr;
                f.strflags = f.iflags;
                f.i += 1;
            }
            while (f.i <= f.sub.len) : (f.i += 1) {
                // Invariant: f.sub[f.start..f.i] all begin with f.str (under
                // f.strflags); f.out <= f.start.
                var istr: []const u21 = &.{};
                var iflags: Flags = 0;
                if (f.i < f.sub.len) {
                    const ls = leadingString(f.sub[f.i]);
                    istr = ls.runes;
                    iflags = ls.flags;
                    if (iflags == f.strflags) {
                        var same: usize = 0;
                        while (same < f.str.len and same < istr.len and f.str[same] == istr[same]) same += 1;
                        if (same > 0) {
                            // Matches at least one rune in current range.
                            f.str = f.str[0..same];
                            continue;
                        }
                    }
                }
                // f.sub[f.start..f.i] all begin with f.str, but f.sub[f.i]
                // does not even begin with f.str[0]: factor out the string.
                if (f.i == f.start) {
                    // Nothing to do: run of length 0.
                } else if (f.i == f.start + 1) {
                    f.sub[f.out] = f.sub[f.start];
                    f.out += 1;
                } else {
                    const prefix = try p.newRegexp(.literal);
                    prefix.flags = f.strflags;
                    var list: std.ArrayList(u21) = .empty;
                    try list.appendSlice(p.al, f.str);
                    setRunes(prefix, list);
                    for (f.start..f.i) |j| {
                        f.sub[j] = try p.removeLeadingString(f.sub[j], f.str.len);
                        try p.checkLimits(f.sub[j]);
                    }
                    // Recurse: collapse(sub[start:i], OpAlternate); the run
                    // has at least two entries.
                    f.prefix = prefix;
                    f.istr = istr;
                    f.iflags = iflags;
                    return try p.collapseNode(f.sub[f.start..f.i], .alternate);
                }
                f.start = f.i;
                f.str = istr;
                f.strflags = iflags;
            }
            f.sub = f.sub[0..f.out];
            f.round = 2;
            f.out = 0;
            f.i = 0;
            f.start = 0;
            ret = null;
        }

        // Round 2: factor out common simple prefixes — just the first piece
        // of each concatenation, and only a character class or a fixed repeat
        // of one: factoring anything with a quantifier would merge distinct
        // paths through the automaton and change results.
        if (ret) |suffix| {
            f.sub[f.out] = try p.concat2(f.first.?, suffix);
            f.out += 1;
            f.start = f.i;
            f.first = f.ifirst;
            f.i += 1;
        }
        while (f.i <= f.sub.len) : (f.i += 1) {
            // Invariant: f.sub[f.start..f.i] all begin with f.first.
            var ifirst: ?*Regexp = null;
            if (f.i < f.sub.len) {
                ifirst = leadingRegexp(f.sub[f.i]);
                if (f.first) |first| {
                    if (ifirst != null and first.equal(ifirst.?) and
                        (isCharClass(first) or (first.op == .repeat and first.min == first.max and isCharClass(first.sub[0]))))
                    {
                        continue;
                    }
                }
            }
            if (f.i == f.start) {
                // Nothing to do: run of length 0.
            } else if (f.i == f.start + 1) {
                f.sub[f.out] = f.sub[f.start];
                f.out += 1;
            } else {
                for (f.start..f.i) |j| {
                    // The prefix itself came from f.sub[f.start]: keep it.
                    f.sub[j] = try p.removeLeadingRegexp(f.sub[j], j != f.start);
                    try p.checkLimits(f.sub[j]);
                }
                f.ifirst = ifirst;
                return try p.collapseNode(f.sub[f.start..f.i], .alternate);
            }
            f.start = f.i;
            f.first = ifirst;
        }
        var sub = f.sub[0..f.out];

        // Round 3: collapse runs of single literals into character classes.
        {
            var out: usize = 0;
            var start: usize = 0;
            var i: usize = 0;
            while (i <= sub.len) : (i += 1) {
                if (i < sub.len and isCharClass(sub[i])) continue;
                // sub[i] is not a char or char class; emit a class for
                // sub[start..i] ...
                if (i == start) {
                    // Nothing to do: run of length 0.
                } else if (i == start + 1) {
                    sub[out] = sub[start];
                    out += 1;
                } else {
                    // Start with the most complex regexp in sub[start..i].
                    var max = start;
                    for (start + 1..i) |j| {
                        const a = @backingInt(sub[max].op);
                        const b = @backingInt(sub[j].op);
                        if (a < b or (a == b and sub[max].runes.len < sub[j].runes.len)) max = j;
                    }
                    std.mem.swap(*Regexp, &sub[start], &sub[max]);
                    for (start + 1..i) |j| {
                        try p.mergeCharClass(sub[start], sub[j]);
                        p.reuse(sub[j]);
                    }
                    cleanAlt(sub[start]);
                    sub[out] = sub[start];
                    out += 1;
                }
                // ... and then emit sub[i].
                if (i < sub.len) {
                    sub[out] = sub[i];
                    out += 1;
                }
                start = i + 1;
            }
            sub = sub[0..out];
        }

        // Round 4: collapse runs of empty matches into a single empty match.
        {
            var out: usize = 0;
            for (0..sub.len) |i| {
                if (i + 1 < sub.len and sub[i].op == .empty_match and sub[i + 1].op == .empty_match) continue;
                sub[out] = sub[i];
                out += 1;
            }
            sub = sub[0..out];
        }
        f.sub = sub;
        return null;
    }

    fn concat2(p: *Parser, a: *Regexp, b: *Regexp) !*Regexp {
        const re = try p.newRegexp(.concat);
        re.sub = try p.al.dupe(*Regexp, &.{ a, b });
        return re;
    }

    /// Remove the first `n` runes from the leading literal of `re` (Go's
    /// `removeLeadingString`); returns the replacement for `re`.
    fn removeLeadingString(p: *Parser, re: *Regexp, n: usize) !*Regexp {
        if (re.op == .concat and re.sub.len > 0) {
            // Removing a leading string in a concatenation might simplify it.
            const s0 = try p.removeLeadingString(re.sub[0], n);
            re.sub[0] = s0;
            if (s0.op == .empty_match) {
                p.reuse(s0);
                switch (re.sub.len) {
                    0, 1 => {
                        // Impossible but handle.
                        re.op = .empty_match;
                        re.sub = &.{};
                    },
                    2 => {
                        const old = re;
                        const r = re.sub[1];
                        p.reuse(old);
                        return r;
                    },
                    else => re.sub = re.sub[1..],
                }
            }
            return re;
        }
        if (re.op == .literal) {
            std.mem.copyForwards(u21, re.runes, re.runes[n..]);
            re.runes = re.runes[0 .. re.runes.len - n];
            if (re.runes.len == 0) re.op = .empty_match;
        }
        return re;
    }

    /// Remove the leading regexp of `re` (Go's `removeLeadingRegexp`);
    /// returns the replacement for `re`. With `recycle`, the removed regexp
    /// (if no longer needed) goes back to the free list.
    fn removeLeadingRegexp(p: *Parser, re: *Regexp, recycle: bool) !*Regexp {
        if (re.op == .concat and re.sub.len > 0) {
            if (recycle) p.reuse(re.sub[0]);
            re.sub = re.sub[1..];
            switch (re.sub.len) {
                0 => {
                    re.op = .empty_match;
                    re.sub = &.{};
                },
                1 => {
                    const old = re;
                    const r = re.sub[0];
                    p.reuse(old);
                    return r;
                },
                else => {},
            }
            return re;
        }
        if (recycle) p.reuse(re);
        return p.newRegexp(.empty_match);
    }

    /// Clean `re` for eventual inclusion in an alternation (Go's `cleanAlt`;
    /// its storage-reclaiming copy is unobservable and omitted).
    fn cleanAlt(re: *Regexp) void {
        if (re.op != .char_class) return;
        re.runes = cleanRunes(re.runes);
        const r = re.runes;
        if (r.len == 2 and r[0] == 0 and r[1] == max_rune) {
            re.runes = &.{};
            Node.of(re).rune_cap = 0;
            re.op = .any_char;
        } else if (r.len == 4 and r[0] == 0 and r[1] == '\n' - 1 and r[2] == '\n' + 1 and r[3] == max_rune) {
            re.runes = &.{};
            Node.of(re).rune_cap = 0;
            re.op = .any_char_not_nl;
        }
    }

    /// dst = dst|src (Go's `mergeCharClass`). The caller ensures
    /// dst.op >= src.op, so src is a literal or a simpler class. The class
    /// grows in place with amortised capacity, like Go's `append`.
    fn mergeCharClass(p: *Parser, dst: *Regexp, src: *const Regexp) !void {
        switch (dst.op) {
            .any_char => {}, // src doesn't add anything
            .any_char_not_nl => {
                // src might add \n
                if (matchRuneNode(src, '\n')) dst.op = .any_char;
            },
            .char_class => {
                var list = try p.runeList(dst);
                if (src.op == .literal) {
                    try appendLiteral(p.al, &list, src.runes[0], src.flags);
                } else {
                    try appendClass(p.al, &list, src.runes);
                }
                setRunes(dst, list);
            },
            .literal => {
                // Both literal.
                if (src.runes[0] == dst.runes[0] and src.flags == dst.flags) return;
                const r0 = dst.runes[0];
                var list = try p.runeList(dst);
                list.clearRetainingCapacity();
                dst.op = .char_class;
                try appendLiteral(p.al, &list, r0, dst.flags);
                try appendLiteral(p.al, &list, src.runes[0], src.flags);
                setRunes(dst, list);
            },
            else => unreachable,
        }
    }

    fn parseVerticalBar(p: *Parser) !void {
        try p.concat();
        if (!try p.swapVerticalBar()) {
            _ = try p.op(.vertical_bar);
        }
    }

    /// If the top of the stack is an element above an opVerticalBar, swap them
    /// and return true (Go's `swapVerticalBar`). Literals and classes on both
    /// sides of the bar are merged into a single class instead.
    fn swapVerticalBar(p: *Parser) !bool {
        const n = p.stack.items.len;
        const items = p.stack.items;
        if (n >= 3 and items[n - 2].op == .vertical_bar and isCharClass(items[n - 1]) and isCharClass(items[n - 3])) {
            var re1 = items[n - 1];
            var re3 = items[n - 3];
            // Make re3 the more complex of the two.
            if (@backingInt(re1.op) > @backingInt(re3.op)) {
                std.mem.swap(*Regexp, &re1, &re3);
                items[n - 3] = re3;
            }
            try p.mergeCharClass(re3, re1);
            p.reuse(re1);
            p.stack.shrinkRetainingCapacity(n - 1);
            return true;
        }
        if (n >= 2) {
            const re1 = p.stack.items[n - 1];
            const re2 = p.stack.items[n - 2];
            if (re2.op == .vertical_bar) {
                // Now out of reach: clean opportunistically.
                if (n >= 3) cleanAlt(p.stack.items[n - 3]);
                p.stack.items[n - 2] = re1;
                p.stack.items[n - 1] = re2;
                return true;
            }
        }
        return false;
    }

    fn parseRightParen(p: *Parser) !void {
        try p.concat();
        if (try p.swapVerticalBar()) _ = p.stack.pop();
        try p.alternate();

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

        // Character-class escapes: \p{...} and \d \w \s etc. Like Go, the
        // node is allocated up front and recycled if this is not a class.
        const re = try p.newRegexp(.char_class);
        re.flags = p.flags;
        var class: std.ArrayList(u21) = .empty;
        if (t.len >= 2 and (t[1] == 'p' or t[1] == 'P')) {
            if (try p.parseUnicodeClass(t, &class)) |nt| {
                setRunes(re, class);
                try p.push(re);
                return nt;
            }
        }
        if (try p.parsePerlClassEscape(t, &class)) |nt| {
            setRunes(re, class);
            try p.push(re);
            return nt;
        }
        class.deinit(p.al);
        p.reuse(re);

        // Ordinary single-character escape.
        const esc = try p.parseEscape(t);
        try p.literal(esc.r);
        return esc.rest;
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
        setRunes(re, class);
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

        if (p.flags & ast.FoldCase == 0 or tr.fold == null) {
            if (sign > 0) {
                try appendTable(p.al, class, tr.ranges);
            } else {
                try appendNegatedTable(p.al, class, tr.ranges);
            }
        } else {
            // Merge and clean tab and fold in a temporary buffer. This is
            // necessary for the negative case and just tidy for the positive
            // case (Go's parseUnicodeClass).
            var tmp: std.ArrayList(u21) = .empty;
            defer tmp.deinit(p.al);
            try appendTable(p.al, &tmp, tr.ranges);
            try appendTable(p.al, &tmp, tr.fold.?);
            cleanClass(&tmp);
            if (sign > 0) {
                try appendClass(p.al, class, tmp.items);
            } else {
                try appendNegatedClass(p.al, class, tmp.items);
            }
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
    list.shrinkRetainingCapacity(cleanRunes(list.items).len);
}

/// `cleanClass` over a bare range-pair slice, in place; returns the cleaned
/// prefix.
fn cleanRunes(r: []u21) []u21 {
    // A class list is always (lo, hi) pairs; the pair-cast and the i+1 reads
    // below depend on it.
    std.debug.assert(r.len % 2 == 0);
    if (r.len < 2) return r;
    const n2 = r.len / 2;
    // Reinterpret as pairs for sorting; u21 is stored as a 4-byte int, so
    // [2]u21 is exactly two adjacent elements with no padding.
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
    return r[0..w];
}

const LeadingString = struct { runes: []const u21, flags: Flags };

/// The leading literal string `re` begins with (Go's `leadingString`).
fn leadingString(re0: *const Regexp) LeadingString {
    var re = re0;
    if (re.op == .concat and re.sub.len > 0) re = re.sub[0];
    if (re.op != .literal) return .{ .runes = &.{}, .flags = 0 };
    return .{ .runes = re.runes, .flags = re.flags & ast.FoldCase };
}

/// The leading regexp `re` begins with (Go's `leadingRegexp`).
fn leadingRegexp(re: *Regexp) ?*Regexp {
    if (re.op == .empty_match) return null;
    if (re.op == .concat and re.sub.len > 0) {
        const s0 = re.sub[0];
        if (s0.op == .empty_match) return null;
        return s0;
    }
    return re;
}

/// A single rune or a class (Go's `isCharClass`).
fn isCharClass(re: *const Regexp) bool {
    return (re.op == .literal and re.runes.len == 1) or re.op == .char_class or
        re.op == .any_char_not_nl or re.op == .any_char;
}

/// Does `re` (a single rune or class) match `r`? Go's parser-level `matchRune`.
fn matchRuneNode(re: *const Regexp, r: u21) bool {
    switch (re.op) {
        .literal => return re.runes.len == 1 and re.runes[0] == r,
        .char_class => {
            var i: usize = 0;
            while (i < re.runes.len) : (i += 2) {
                if (re.runes[i] <= r and r <= re.runes[i + 1]) return true;
            }
            return false;
        },
        .any_char_not_nl => return r != '\n',
        .any_char => return true,
        else => return false,
    }
}

fn appendLiteral(al: std.mem.Allocator, list: *std.ArrayList(u21), x: u21, flags: Flags) !void {
    if (flags & ast.FoldCase != 0) return appendFoldedRange(al, list, x, x);
    return appendRange(al, list, x, x);
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

test "cleanClass sorts and merges overlapping/abutting ranges" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u21) = .empty;
    defer list.deinit(gpa);
    // Unsorted with overlap: (30,40) (10,20) (15,35) → (10,40).
    try list.appendSlice(gpa, &[_]u21{ 30, 40, 10, 20, 15, 35 });
    cleanClass(&list);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 10, 40 }, list.items);

    // Abutting ranges merge: (10,20) (21,30) → (10,30); (32,40) stays apart.
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, &[_]u21{ 21, 30, 10, 20, 32, 40 });
    cleanClass(&list);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 10, 30, 32, 40 }, list.items);
}

test "negateClass edges at 0 and max_rune" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u21) = .empty;
    defer list.deinit(gpa);

    // Negating a middle range yields both flanks.
    try list.appendSlice(gpa, &[_]u21{ 5, 10 });
    try negateClass(gpa, &list);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0, 4, 11, max_rune }, list.items);

    // Negating everything yields the empty class.
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, &[_]u21{ 0, max_rune });
    try negateClass(gpa, &list);
    try std.testing.expectEqualSlices(u21, &[_]u21{}, list.items);

    // Negating the empty class yields everything.
    list.clearRetainingCapacity();
    try negateClass(gpa, &list);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0, max_rune }, list.items);
}

test "parseInt basics" {
    var p = Parser{ .al = std.testing.allocator, .flags = 0 };
    const a = p.parseInt("123}");
    try std.testing.expect(a.ok and a.n == 123);
    const b = p.parseInt("01");
    try std.testing.expect(!b.ok); // leading zero
}

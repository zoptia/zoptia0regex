//! The compiled program: a list of NFA instructions, mirroring Go's
//! `regexp/syntax.Prog` / `Inst`. The engines in `exec.zig` and
//! `backtrack.zig` interpret this.

const std = @import("std");
const unicode = @import("unicode.zig");
const ast = @import("ast.zig");

/// Instruction opcode. Order matches Go's `InstOp`.
pub const InstOp = enum(u8) {
    alt, // out, arg: two epsilon successors (greedy priority: out first)
    alt_match, // like alt but one side leads directly to a match
    capture, // arg: capture slot, out: successor
    empty_width, // arg: EmptyOp assertion, out: successor
    match, // accept
    fail, // dead end
    nop, // out: successor
    rune, // runes: range-pair list (or single literal w/ optional fold), out
    rune1, // runes[0]: single rune, out
    rune_any, // matches any rune, out
    rune_any_not_nl, // matches any rune except '\n', out
};

/// Zero-width assertion bits. Order/values match Go's `EmptyOp`.
pub const EmptyOp = u8;
pub const empty_begin_line: EmptyOp = 1 << 0;
pub const empty_end_line: EmptyOp = 1 << 1;
pub const empty_begin_text: EmptyOp = 1 << 2;
pub const empty_end_text: EmptyOp = 1 << 3;
pub const empty_word_boundary: EmptyOp = 1 << 4;
pub const empty_no_word_boundary: EmptyOp = 1 << 5;

/// A single instruction. `out` and `arg` are program-counter indices (0 means
/// "unset / fail instruction", which is always at pc 0).
pub const Inst = struct {
    op: InstOp,
    out: u32 = 0,
    arg: u32 = 0,
    runes: []const u21 = &.{},

    /// Reports whether the instruction matches (and would consume) `r`.
    /// Only valid for `rune` (the general case); the VM handles rune1/any
    /// directly. Replicates Go's `Inst.MatchRune`.
    pub fn matchRune(i: *const Inst, r: u21) bool {
        return matchRunePos(i.runes, i.arg, r) >= 0;
    }
};

/// The index of the rune pair that matches `r` in the sorted range-pair list
/// `runes` (with optional `FoldCase` in `arg` for a single-rune literal), or
/// -1 if none. Mirrors Go's `Inst.MatchRunePos`; the index feeds the one-pass
/// `Next` dispatch table.
pub fn matchRunePos(rs: []const u21, arg: u32, r: u21) i32 {
    switch (rs.len) {
        0 => return -1,
        1 => {
            const r0 = rs[0];
            if (r == r0) return 0;
            if (ast.FoldCase & @as(ast.Flags, @intCast(arg)) != 0) {
                var r1 = unicode.simpleFold(r0);
                while (r1 != r0) : (r1 = unicode.simpleFold(r1)) {
                    if (r == r1) return 0;
                }
            }
            return -1;
        },
        2 => return if (r >= rs[0] and r <= rs[1]) 0 else -1,
        else => {
            if (rs.len <= 8) {
                var j: usize = 0;
                while (j < rs.len) : (j += 2) {
                    if (r < rs[j]) return -1;
                    if (r <= rs[j + 1]) return @intCast(j / 2);
                }
                return -1;
            }
            var lo: usize = 0;
            var hi: usize = rs.len / 2;
            while (lo < hi) {
                const m = lo + (hi - lo) / 2;
                if (rs[2 * m] <= r) {
                    if (r <= rs[2 * m + 1]) return @intCast(m);
                    lo = m + 1;
                } else {
                    hi = m;
                }
            }
            return -1;
        },
    }
}

/// A compiled program.
pub const Prog = struct {
    insts: []Inst,
    /// Per-instruction ASCII membership bitmap for `.rune` (bit b set iff
    /// rune b < 0x80 matches); kept out of `Inst` so the instruction stays
    /// 32 bytes. Lets the engines answer the common ASCII case without
    /// walking the range list or the fold orbit.
    ascii: []const u128 = &.{},
    start: u32 = 0,

    /// `Inst.matchRune` for `insts[pc]` with the ASCII fast path.
    pub inline fn matchRuneAt(p: *const Prog, pc: u32, r: u21) bool {
        if (r < 0x80) return (p.ascii[pc] >> @intCast(r)) & 1 != 0;
        return p.insts[pc].matchRune(r);
    }

    /// The leading zero-width conditions that must hold at the start of any
    /// match. Returns `impossible` if no match is possible. Mirrors
    /// Go's `Prog.StartCond`.
    pub fn startCond(p: *const Prog) EmptyOp {
        var flag: EmptyOp = 0;
        var pc = p.start;
        while (true) {
            const i = &p.insts[pc];
            switch (i.op) {
                .empty_width => flag |= @as(EmptyOp, @intCast(i.arg)),
                .fail => return impossible,
                .capture, .nop => {},
                else => return flag,
            }
            pc = i.out;
        }
    }

    /// A literal string that every match must start with, plus whether that
    /// prefix is the entire match. Mirrors Go's `Prog.Prefix`, including its
    /// treatment of runes UTF-8 cannot encode (surrogates): they are written
    /// as U+FFFD and the walk goes on. `lossy` reports that this happened;
    /// the prefix is then not the literal the program matches (the engines
    /// compare runes, and no input decodes to a surrogate), only the bytes
    /// Go's one-pass prefix skip and `LiteralPrefix` use.
    pub fn prefix(p: *const Prog, allocator: std.mem.Allocator) !struct { str: []u8, complete: bool, lossy: bool } {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var lossy = false;
        var i = p.skipNop(p.start);
        // Avoid building when there is no single-rune prefix.
        if (mergedOp(i.op) != .rune or i.runes.len != 1) {
            return .{ .str = try buf.toOwnedSlice(allocator), .complete = i.op == .match, .lossy = false };
        }
        while (mergedOp(i.op) == .rune and i.runes.len == 1 and
            (@as(ast.Flags, @intCast(i.arg)) & ast.FoldCase) == 0 and i.runes[0] != 0xFFFD)
        {
            if (try appendRune(allocator, &buf, i.runes[0])) lossy = true;
            i = p.skipNop(i.out);
        }
        return .{ .str = try buf.toOwnedSlice(allocator), .complete = i.op == .match, .lossy = lossy };
    }

    fn skipNop(p: *const Prog, pc0: u32) *Inst {
        var i = &p.insts[pc0];
        while (i.op == .nop or i.op == .capture) {
            i = &p.insts[i.out];
        }
        return i;
    }
};

/// Append the UTF-8 encoding of `r` to `buf` like Go's `utf8.AppendRune`:
/// a rune that cannot be encoded (a surrogate, or past U+10FFFF) is written
/// as U+FFFD. Returns whether that substitution happened.
pub fn appendRune(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), r: u21) !bool {
    var tmp: [4]u8 = undefined;
    if (std.unicode.utf8Encode(r, &tmp)) |n| {
        try buf.appendSlice(allocator, tmp[0..n]);
        return false;
    } else |_| {
        try buf.appendSlice(allocator, "\u{FFFD}");
        return true;
    }
}

/// `impossible` start condition: all bits set (Go's `^EmptyOp(0)`).
pub const impossible: EmptyOp = 0xFF;

/// Merge the rune special-cases back into `.rune` (Go's `Inst.op`).
pub fn mergedOp(op: InstOp) InstOp {
    return switch (op) {
        .rune1, .rune_any, .rune_any_not_nl => .rune,
        else => op,
    };
}

test "appendRune writes U+FFFD for unencodable runes" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try std.testing.expect(!try appendRune(a, &buf, 'a'));
    try std.testing.expect(try appendRune(a, &buf, 0xD800));
    try std.testing.expect(!try appendRune(a, &buf, 0x10FFFF));
    try std.testing.expect(try appendRune(a, &buf, 0x110000));
    try std.testing.expectEqualStrings("a\u{FFFD}\u{10FFFF}\u{FFFD}", buf.items);
}

test "matchRune single, range, fold" {
    const i = Inst{ .op = .rune, .runes = &[_]u21{ 'a', 'z' } };
    try std.testing.expect(i.matchRune('m'));
    try std.testing.expect(!i.matchRune('Z'));

    const lit = Inst{ .op = .rune, .arg = ast.FoldCase, .runes = &[_]u21{'A'} };
    try std.testing.expect(lit.matchRune('a'));
    try std.testing.expect(lit.matchRune('A'));
    try std.testing.expect(!lit.matchRune('b'));
}

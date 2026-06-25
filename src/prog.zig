//! The compiled program: a list of NFA instructions, mirroring Go's
//! `regexp/syntax.Prog` / `Inst`. The Pike VM in `exec.zig` interprets this.

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
    start: u32 = 0,
    num_cap: usize = 2, // implicit whole-match capture pair

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
    /// prefix is the entire match. Mirrors Go's `Prog.Prefix`.
    pub fn prefix(p: *const Prog, allocator: std.mem.Allocator) !struct { str: []u8, complete: bool } {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var i = p.skipNop(p.start);
        // Avoid building when there is no single-rune prefix.
        if (mergedOp(i.op) != .rune or i.runes.len != 1) {
            return .{ .str = try buf.toOwnedSlice(allocator), .complete = i.op == .match };
        }
        while (mergedOp(i.op) == .rune and i.runes.len == 1 and
            (@as(ast.Flags, @intCast(i.arg)) & ast.FoldCase) == 0 and i.runes[0] != 0xFFFD)
        {
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(i.runes[0], &tmp) catch break;
            try buf.appendSlice(allocator, tmp[0..n]);
            i = p.skipNop(i.out);
        }
        return .{ .str = try buf.toOwnedSlice(allocator), .complete = i.op == .match };
    }

    fn skipNop(p: *const Prog, pc0: u32) *Inst {
        var i = &p.insts[pc0];
        while (i.op == .nop or i.op == .capture) {
            i = &p.insts[i.out];
        }
        return i;
    }
};

/// `impossible` start condition: all bits set (Go's `^EmptyOp(0)`).
pub const impossible: EmptyOp = 0xFF;

/// Merge the rune special-cases back into `.rune` (Go's `Inst.op`).
pub fn mergedOp(op: InstOp) InstOp {
    return switch (op) {
        .rune1, .rune_any, .rune_any_not_nl => .rune,
        else => op,
    };
}

/// The zero-width assertions satisfied between runes r1 and r2 (each -1 at the
/// text boundary). Mirrors Go's `EmptyOpContext`. Provided for completeness;
/// the Pike VM uses the lazy variant in `exec.zig`.
pub fn emptyOpContext(r1: i32, r2: i32) EmptyOp {
    var op: EmptyOp = empty_no_word_boundary;
    var boundary: u8 = 0;
    if (unicode.isWordChar(r1)) {
        boundary = 1;
    } else if (r1 == '\n') {
        op |= empty_begin_line;
    } else if (r1 < 0) {
        op |= empty_begin_text | empty_begin_line;
    }
    if (unicode.isWordChar(r2)) {
        boundary ^= 1;
    } else if (r2 == '\n') {
        op |= empty_end_line;
    } else if (r2 < 0) {
        op |= empty_end_text | empty_end_line;
    }
    if (boundary != 0) op ^= (empty_word_boundary | empty_no_word_boundary);
    return op;
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

test "emptyOpContext begin/end text" {
    const ctx = emptyOpContext(-1, 'a');
    try std.testing.expect(ctx & empty_begin_text != 0);
    try std.testing.expect(ctx & empty_begin_line != 0);
}

//! The regular-expression syntax tree (AST), mirroring Go's
//! `regexp/syntax.Regexp` node, its `Op` enum, and the `Flags` bitset.
//!
//! Port note: Go's inline storage (`Sub0`, `Rune0`) is dropped; nodes and
//! their slices live in an arena. Parser-only state (Go's node free list and
//! its `p.size` / `p.height` caches) is kept beside each node inside the
//! parser (`parse.zig`), not here. The AST shape matches Go's, including
//! `maybeConcat`'s multi-rune literals and `factor`'s rewritten alternations.

const std = @import("std");

/// A single regular-expression operator. Values match Go's ordering so that
/// `@backingInt` comparisons (used for precedence and the parse-stack
/// pseudo-ops) behave like Go's `Op` integer comparisons.
pub const Op = enum(u8) {
    no_match = 1, // matches no strings
    empty_match, // matches the empty string
    literal, // matches Rune sequence
    char_class, // matches Rune interpreted as range pair list
    any_char_not_nl, // matches any character except newline
    any_char, // matches any character
    begin_line, // matches empty string at beginning of line
    end_line, // matches empty string at end of line
    begin_text, // matches empty string at beginning of text
    end_text, // matches empty string at end of text
    word_boundary, // matches word boundary `\b`
    no_word_boundary, // matches word non-boundary `\B`
    capture, // capturing subexpression with index `cap`, optional `name`
    star, // matches sub[0] zero or more times
    plus, // matches sub[0] one or more times
    quest, // matches sub[0] zero or one times
    repeat, // matches sub[0] at least min, at most max (max == -1: no limit)
    concat, // matches concatenation of subs
    alternate, // matches alternation of subs

    // Pseudo-ops used only on the parse stack (Go's opPseudo == 128).
    left_paren = 128,
    vertical_bar = 129,

    pub inline fn isPseudo(op: Op) bool {
        return @backingInt(op) >= 128;
    }
};

/// Flags control the behaviour of the parser and record context. Values match
/// Go's `syntax.Flags` bit positions. Stored as a raw `u16` because the parser
/// performs bitwise complement/xor on the whole word (see `parsePerlFlags`).
pub const Flags = u16;

pub const FoldCase: Flags = 1 << 0; // case-insensitive match
pub const Literal: Flags = 1 << 1; // treat pattern as literal string
pub const ClassNL: Flags = 1 << 2; // allow [^a-z] / [[:space:]] to match newline
pub const DotNL: Flags = 1 << 3; // allow . to match newline
pub const OneLine: Flags = 1 << 4; // treat ^ and $ as only matching begin/end of text
pub const NonGreedy: Flags = 1 << 5; // make repetition operators default to non-greedy
pub const PerlX: Flags = 1 << 6; // allow Perl extensions
pub const UnicodeGroups: Flags = 1 << 7; // allow \p{Han}, \P{Han}
// WasDollar, Simple, and MatchNL mirror Go's Flags bit layout. WasDollar is
// read by `Regexp.equal`, as Go's `Equal` reads it (so `$` and `\z` never
// factor together) and by Go's printer; Simple is declared but never set or
// read, in Go as here.
pub const WasDollar: Flags = 1 << 8; // OpEndText was $, not \z
pub const Simple: Flags = 1 << 9; // regexp contains no counted repetition

pub const MatchNL: Flags = ClassNL | DotNL;
/// As close to Perl as possible (Go's `syntax.Perl`).
pub const Perl: Flags = ClassNL | OneLine | PerlX | UnicodeGroups;
/// POSIX syntax (Go's `syntax.POSIX`).
pub const POSIX: Flags = 0;

/// A node in the regular-expression syntax tree.
pub const Regexp = struct {
    op: Op,
    flags: Flags = 0,
    /// Subexpressions (concat/alternate children, or the single operand of
    /// capture/star/plus/quest/repeat).
    sub: []*Regexp = &.{},
    /// For `literal`: the literal runes. For `char_class`: range pairs
    /// (lo0, hi0, lo1, hi1, ...).
    runes: []u21 = &.{},
    min: i32 = 0,
    max: i32 = 0,
    cap: i32 = 0, // capturing index, for `capture`
    name: []const u8 = "", // capturing name, for `capture`

    /// Structural equality. Mirrors Go's `Regexp.Equal` (used by `factor`).
    pub fn equal(x: *const Regexp, y: *const Regexp) bool {
        if (x.op != y.op) return false;
        switch (x.op) {
            .end_text => return x.flags & WasDollar == y.flags & WasDollar,
            .literal, .char_class => return x.flags & FoldCase == y.flags & FoldCase and
                std.mem.eql(u21, x.runes, y.runes),
            .alternate, .concat => {
                if (x.sub.len != y.sub.len) return false;
                for (x.sub, y.sub) |a, b| if (!a.equal(b)) return false;
                return true;
            },
            .star, .plus, .quest => return x.flags & NonGreedy == y.flags & NonGreedy and x.sub[0].equal(y.sub[0]),
            .repeat => return x.flags & NonGreedy == y.flags & NonGreedy and x.min == y.min and x.max == y.max and
                x.sub[0].equal(y.sub[0]),
            .capture => return x.cap == y.cap and std.mem.eql(u8, x.name, y.name) and x.sub[0].equal(y.sub[0]),
            else => return true,
        }
    }

    /// Walk the tree to find the maximum capture index.
    pub fn maxCap(re: *const Regexp) i32 {
        var m: i32 = 0;
        if (re.op == .capture) m = re.cap;
        for (re.sub) |sub| {
            const n = sub.maxCap();
            if (m < n) m = n;
        }
        return m;
    }

    /// Collect capture-group names into `names` (indexed by capture number).
    pub fn capNamesInto(re: *const Regexp, names: [][]const u8) void {
        if (re.op == .capture) names[@intCast(re.cap)] = re.name;
        for (re.sub) |sub| sub.capNamesInto(names);
    }
};

test "Op precedence ordering matches Go" {
    try std.testing.expect(@backingInt(Op.literal) < @backingInt(Op.capture));
    try std.testing.expect(!Op.alternate.isPseudo());
    try std.testing.expect(Op.left_paren.isPseudo());
    try std.testing.expect(Op.vertical_bar.isPseudo());
}

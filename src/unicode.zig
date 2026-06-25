//! Unicode helpers mirroring the subset of Go's `unicode` package that the
//! regexp engine relies on: case folding (`SimpleFold`), the ASCII word-char
//! test used by `\b`/`\B`, and `\p{...}` class lookup.
//!
//! The case-fold table (`fold_table.zig`) is generated from Go's
//! `unicode.SimpleFold` and covers all of Unicode, so `(?i)` folding matches
//! Go exactly. The `\p{}` tables (`unicode_tables.zig`) are a curated subset
//! of the most common general categories and scripts.

const std = @import("std");
const fold = @import("fold_table.zig");
const utbl = @import("unicode_tables.zig");

pub const max_rune: u21 = 0x10FFFF;
pub const min_fold = fold.min_fold;
pub const max_fold = fold.max_fold;

pub const URange = utbl.URange;

/// SimpleFold iterates over the Unicode code points equivalent under simple
/// case folding, returning the next code point in `r`'s fold orbit (cycling
/// back to the smallest). Exactly replicates Go's `unicode.SimpleFold`.
pub fn simpleFold(r: u21) u21 {
    // Binary search the generated (from -> to) table.
    var lo: usize = 0;
    var hi: usize = fold.fold_pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const from = fold.fold_pairs[mid].from;
        if (from < r) {
            lo = mid + 1;
        } else if (from > r) {
            hi = mid;
        } else {
            return fold.fold_pairs[mid].to;
        }
    }
    // Not in the table: r is its own fold orbit.
    return r;
}

/// minFoldRune returns the minimum rune that is fold-equivalent to r.
/// Used by the parser when folding literals under `(?i)`.
pub fn minFoldRune(r: u21) u21 {
    if (r < min_fold or r > max_fold) return r;
    var m = r;
    const r0 = r;
    var c = simpleFold(r);
    while (c != r0) : (c = simpleFold(c)) {
        if (c < m) m = c;
    }
    return m;
}

/// IsWordChar reports whether r is an ASCII word character ([A-Za-z0-9_]),
/// as used by the `\b` and `\B` zero-width assertions.
pub fn isWordChar(r: i32) bool {
    return ('a' <= r and r <= 'z') or
        ('A' <= r and r <= 'Z') or
        ('0' <= r and r <= '9') or
        r == '_';
}

/// canonicalName returns the canonical lookup string for a `\p{...}` name:
/// leading uppercase, the rest lowercase, omitting `_`, `-`, and spaces.
/// Caller owns the returned slice.
pub fn canonicalName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var first = true;
    for (name) |c0| {
        var c = c0;
        if (c == '_' or c == '-' or c == ' ') {
            continue; // omit separators
        } else if (first) {
            if ('a' <= c and c <= 'z') c -= 'a' - 'A';
            first = false;
        } else {
            if ('A' <= c and c <= 'Z') c += 'a' - 'A';
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

pub const TableResult = struct {
    ranges: []const URange,
    /// extra sign inversion (Go's tsign): currently only +1 for our subset.
    sign: i2,
};

/// unicodeTable returns the range table identified by `name` (after
/// canonicalization), or null if unknown. Handles the special cases Go does
/// for "Any" and "ASCII"; other names come from the curated subset.
pub fn unicodeTable(allocator: std.mem.Allocator, name: []const u8) !?TableResult {
    const canon = try canonicalName(allocator, name);
    defer allocator.free(canon);

    if (std.mem.eql(u8, canon, "Any")) return TableResult{ .ranges = &any_ranges, .sign = 1 };
    if (std.mem.eql(u8, canon, "Ascii")) return TableResult{ .ranges = &ascii_ranges, .sign = 1 };

    for (utbl.unicode_classes) |cls| {
        if (std.mem.eql(u8, cls.name, canon)) {
            return TableResult{ .ranges = cls.ranges, .sign = 1 };
        }
    }
    return null;
}

const any_ranges = [_]URange{.{ .lo = 0, .hi = max_rune, .stride = 1 }};
const ascii_ranges = [_]URange{.{ .lo = 0, .hi = 0x7F, .stride = 1 }};

test "simpleFold ASCII and Unicode" {
    try std.testing.expectEqual(@as(u21, 'a'), simpleFold('A'));
    try std.testing.expectEqual(@as(u21, 'A'), simpleFold('a'));
    try std.testing.expectEqual(@as(u21, '1'), simpleFold('1'));
    // Kelvin sign K (U+212A) folds with K/k.
    try std.testing.expectEqual(@as(u21, 'A'), minFoldRune('a'));
    // Greek sigma orbit {Σ 0x3a3, ς 0x3c2, σ 0x3c3}: min is Σ.
    try std.testing.expectEqual(@as(u21, 0x3a3), minFoldRune(0x3c3));
    try std.testing.expectEqual(@as(u21, 0x3a3), minFoldRune(0x3a3));
}

test "isWordChar" {
    try std.testing.expect(isWordChar('_'));
    try std.testing.expect(isWordChar('Z'));
    try std.testing.expect(!isWordChar('-'));
    try std.testing.expect(!isWordChar(-1));
}

test "unicodeTable lookup" {
    const a = std.testing.allocator;
    try std.testing.expect((try unicodeTable(a, "Latin")) != null);
    try std.testing.expect((try unicodeTable(a, "Greek")) != null);
    try std.testing.expect((try unicodeTable(a, "Nd")) != null);
    try std.testing.expect((try unicodeTable(a, "NoSuchScript")) == null);
    try std.testing.expect((try unicodeTable(a, "Any")) != null);
}

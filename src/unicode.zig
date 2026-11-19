//! Unicode helpers mirroring the subset of Go's `unicode` package that the
//! regexp engine relies on: case folding (`SimpleFold`), the ASCII word-char
//! test used by `\b`/`\B`, and `\p{...}` class lookup.
//!
//! The case-fold table (`fold_table.zig`) is generated from Go's
//! `unicode.SimpleFold` and covers all of Unicode, so `(?i)` folding matches
//! Go exactly. The `\p{}` tables (`unicode_tables.zig`) are the full set of
//! general categories, scripts, fold companions and aliases from Go's
//! `unicode` package, so every property name Go accepts is accepted here.

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
fn canonicalName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
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
    /// The class's case-fold companion table (Go's `unicode.FoldCategory` /
    /// `FoldScript`), merged into the class under `(?i)`; null when Go has none.
    fold: ?[]const URange,
    /// Extra sign inversion (Go's tsign): -1 only for `Assigned` (= not `Cn`).
    sign: i2,
};

/// unicodeTable returns the range table identified by `name` (after
/// canonicalization), or null if unknown. Mirrors Go 1.27's `unicodeTable`:
/// the special cases `Any`, `Assigned`, `ASCII` and `LC`, then general
/// categories, scripts (both matched on their canonical name) and finally
/// `unicode.CategoryAliases` such as `Letter` or `Uppercase_Letter`.
pub fn unicodeTable(allocator: std.mem.Allocator, name: []const u8) !?TableResult {
    const canon = try canonicalName(allocator, name);
    defer allocator.free(canon);

    if (std.mem.eql(u8, canon, "Any")) return TableResult{ .ranges = &any_ranges, .fold = &any_ranges, .sign = 1 };
    if (std.mem.eql(u8, canon, "Assigned")) {
        const cn = categoryByName("Cn").?;
        return TableResult{ .ranges = cn.ranges, .fold = cn.ranges, .sign = -1 }; // invert Cn (unassigned)
    }
    if (std.mem.eql(u8, canon, "Ascii")) return TableResult{ .ranges = &ascii_ranges, .fold = &ascii_fold_ranges, .sign = 1 };
    if (std.mem.eql(u8, canon, "Lc")) {
        const lc = categoryByName("LC").?;
        return TableResult{ .ranges = lc.ranges, .fold = lc.fold, .sign = 1 };
    }
    for (utbl.categories) |cls| {
        if (std.mem.eql(u8, cls.canon, canon)) return TableResult{ .ranges = cls.ranges, .fold = cls.fold, .sign = 1 };
    }
    for (utbl.scripts) |cls| {
        if (std.mem.eql(u8, cls.canon, canon)) return TableResult{ .ranges = cls.ranges, .fold = cls.fold, .sign = 1 };
    }
    for (utbl.category_aliases) |alias| {
        if (std.mem.eql(u8, alias.canon, canon)) {
            const cls = categoryByName(alias.actual).?;
            return TableResult{ .ranges = cls.ranges, .fold = cls.fold, .sign = 1 };
        }
    }
    return null;
}

fn categoryByName(name: []const u8) ?utbl.UnicodeClass {
    for (utbl.categories) |cls| {
        if (std.mem.eql(u8, cls.name, name)) return cls;
    }
    return null;
}

const any_ranges = [_]URange{.{ .lo = 0, .hi = max_rune, .stride = 1 }};
const ascii_ranges = [_]URange{.{ .lo = 0, .hi = 0x7F, .stride = 1 }};
// Go's asciiFoldTable: ASCII plus the two non-ASCII runes that fold into it.
const ascii_fold_ranges = [_]URange{
    .{ .lo = 0, .hi = 0x7F, .stride = 1 },
    .{ .lo = 0x017F, .hi = 0x017F, .stride = 1 }, // Old English long s (ſ), folds to S/s.
    .{ .lo = 0x212A, .hi = 0x212A, .stride = 1 }, // Kelvin K, folds to K/k.
};

fn classRanges(comptime name: []const u8) []const URange {
    for (utbl.categories) |cls| {
        if (std.mem.eql(u8, cls.name, name)) return cls.ranges;
    }
    @compileError("missing unicode category: " ++ name);
}

fn inRanges(r: u21, ranges: []const URange) bool {
    for (ranges) |xr| {
        if (r < xr.lo or r > xr.hi) continue;
        if (xr.stride == 1 or (r - xr.lo) % xr.stride == 0) return true;
    }
    return false;
}

/// Go's `unicode.IsPrint` (and `strconv.IsPrint`): letters, marks,
/// numbers, punctuation, symbols (categories L, M, N, P, S) and U+0020.
pub fn isPrint(r: u21) bool {
    if (r < 0x80) return r >= 0x20 and r < 0x7F;
    inline for (.{ "L", "M", "N", "P", "S" }) |cat| {
        if (inRanges(r, comptime classRanges(cat))) return true;
    }
    return false;
}

/// Reports whether r is a Unicode letter (category L) or decimal digit (Nd),
/// matching `unicode.IsLetter(r) || unicode.IsDigit(r)` used by Go's `extract`
/// for `$name` / `${name}` template parsing.
pub fn isLetterOrDigit(r: u21) bool {
    const letters = comptime classRanges("L");
    const digits = comptime classRanges("Nd");
    return inRanges(r, letters) or inRanges(r, digits);
}

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
    // Go 1.27: scripts and category aliases match on their canonical name.
    try std.testing.expect((try unicodeTable(a, "Old_Italic")) != null);
    try std.testing.expect((try unicodeTable(a, "old italic")) != null);
    try std.testing.expect((try unicodeTable(a, "Uppercase_Letter")) != null);
    try std.testing.expect((try unicodeTable(a, "__upper case-let ter")) != null);
    // Special cases and fold companions.
    const assigned = (try unicodeTable(a, "Assigned")).?;
    try std.testing.expectEqual(@as(i2, -1), assigned.sign);
    try std.testing.expect((try unicodeTable(a, "Lc")).?.ranges.len > 0);
    try std.testing.expect((try unicodeTable(a, "Lu")).?.fold != null);
    try std.testing.expect((try unicodeTable(a, "Nd")).?.fold == null);
    try std.testing.expect((try unicodeTable(a, "ASCII")).?.fold.?.len == 3);
}

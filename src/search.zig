//! Substring and byte-set search used by the engines to skip ahead to the
//! next possible match start. Nothing here has a Go `regexp` counterpart: Go
//! calls `bytes.Index`/`strings.Index` for its literal-prefix scan, and it
//! has no first-byte prefilter at all.

const std = @import("std");

/// Max size of the accelerated first-byte set. The SIMD scan's cost grows
/// only slowly with the set size; past ~16 bytes the set stops *filtering*
/// (too many positions qualify) rather than costing too much to scan.
pub const max_first_bytes = 16;

/// Vectorized first-index-of-any-byte — the memchr2/…/memchr16 analogue used
/// by the first-byte prefilter. One portable implementation: `@Vector`
/// compiles to NEON on aarch64, SSE2 on baseline x86_64 (wider with
/// `-Dcpu=native` on AVX2 machines), and degrades to the scalar std search on
/// targets without SIMD registers.
pub fn indexOfAnyByte(haystack: []const u8, set: []const u8) ?usize {
    std.debug.assert(set.len >= 1 and set.len <= max_first_bytes);
    if (set.len == 1) return std.mem.indexOfScalar(u8, haystack, set[0]);
    const width = comptime std.simd.suggestVectorLength(u8) orelse
        return std.mem.indexOfAny(u8, haystack, set);
    const V = @Vector(width, u8);
    const Mask = @Int(.unsigned, width);

    var splats: [max_first_bytes]V = undefined;
    for (set, 0..) |b, k| splats[k] = @splat(b);

    var i: usize = 0;
    while (i + width <= haystack.len) : (i += width) {
        const chunk: V = haystack[i..][0..width].*;
        var mask: Mask = 0;
        for (splats[0..set.len]) |s| mask |= @as(Mask, @bitCast(chunk == s));
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < haystack.len) : (i += 1) {
        const c = haystack[i];
        for (set) |b| {
            if (c == b) return i;
        }
    }
    return null;
}

/// Heuristic byte-frequency ranks (higher = more common in typical text and
/// code). Only the relative order matters: `prefixIndex` anchors its scan on
/// the needle's lowest-ranked byte, the idea behind rust-memmem's rare-byte
/// heuristic — scanning for `-` or `@` false-starts far less often than
/// scanning for `a`.
const byte_rank: [256]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var r: [256]u8 = @splat(15);
    for (0..0x20) |c| r[c] = 3; // control bytes: rare
    r['\n'] = 180;
    r['\t'] = 120;
    r[' '] = 255;
    const order = "etaoinsrhldcumfpgwybvkxjqz"; // approximate English order
    for (order, 0..) |c, idx| {
        const common: u8 = 240 - @as(u8, @intCast(idx)) * 6;
        r[c] = common;
        r[std.ascii.toUpper(c)] = common / 3;
    }
    for ('0'..'9' + 1) |c| r[c] = 100;
    for (".,-_'\"()/:;=") |c| r[c] = 90;
    for (0x80..0x100) |c| r[c] = 30; // UTF-8 lead/continuation bytes
    break :blk r;
};

fn rarestByteOffset(needle: []const u8) usize {
    var best: usize = 0;
    for (needle, 0..) |b, i| {
        if (byte_rank[b] < byte_rank[needle[best]]) best = i;
    }
    return best;
}

/// The scan anchor for a literal prefix: the offset of its rarest byte.
/// Computed once at compile time (`regexp.compileInternal`) and carried in
/// `Accel.prefix_anchor`.
pub fn prefixAnchor(prefix: []const u8) u32 {
    if (prefix.len < 2) return 0;
    return @intCast(rarestByteOffset(prefix));
}

/// Find the first occurrence of `needle` in `haystack`. Scans for the
/// needle's *rarest* byte with a vectorized search (`indexOfScalar`) and
/// verifies the rest around each hit — anchoring on the rarest byte (rust
/// memmem's heuristic) false-starts far less often than anchoring on the
/// first byte when the first byte is common. Like Go's bytes.Index, it
/// switches to Rabin-Karp when the anchor still produces too many false
/// starts (a periodic needle over a periodic haystack is otherwise O(n·m)).
fn prefixIndex(haystack: []const u8, needle: []const u8) ?usize {
    return prefixIndexAnchored(haystack, needle, prefixAnchor(needle));
}

pub fn prefixIndexAnchored(haystack: []const u8, needle: []const u8, anchor: usize) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len == 1) return std.mem.indexOfScalar(u8, haystack, needle[0]);
    if (haystack.len < needle.len) return null;
    const tail = needle.len - anchor; // needle bytes at/after the anchor
    var start: usize = 0; // candidate needle start
    var fails: usize = 0;
    while (start + needle.len <= haystack.len) {
        const found = std.mem.indexOfScalarPos(
            u8,
            haystack[0 .. haystack.len - tail + 1],
            start + anchor,
            needle[anchor],
        ) orelse return null;
        const at = found - anchor;
        if (std.mem.eql(u8, haystack[at .. at + needle.len], needle)) return at;
        start = at + 1;
        fails += 1;
        if (fails > (at + 16) / 8) { // Go's bytes.Index cutover shape
            if (indexRabinKarp(haystack[start..], needle)) |j| return start + j;
            return null;
        }
    }
    return null;
}

/// Rabin-Karp substring search, mirroring Go's `internal/bytealg`: worst-case
/// linear, used as `prefixIndex`'s fallback for pathological inputs.
fn indexRabinKarp(s: []const u8, sep: []const u8) ?usize {
    if (s.len < sep.len) return null;
    const prime_rk: u32 = 16777619;
    var hashsep: u32 = 0;
    for (sep) |b| hashsep = hashsep *% prime_rk +% b;
    var pow: u32 = 1;
    var sq: u32 = prime_rk;
    var i = sep.len;
    while (i > 0) : (i >>= 1) {
        if (i & 1 != 0) pow *%= sq;
        sq *%= sq;
    }
    var h: u32 = 0;
    for (s[0..sep.len]) |b| h = h *% prime_rk +% b;
    if (h == hashsep and std.mem.eql(u8, s[0..sep.len], sep)) return 0;
    var j = sep.len;
    while (j < s.len) {
        h *%= prime_rk;
        h +%= s[j];
        h -%= pow *% s[j - sep.len];
        j += 1;
        if (h == hashsep and std.mem.eql(u8, s[j - sep.len .. j], sep)) return j - sep.len;
    }
    return null;
}

test "prefixIndex finds first occurrence or null" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(?usize, 0), prefixIndex("hello", ""));
    try expectEqual(@as(?usize, 1), prefixIndex("xyz", "y"));
    try expectEqual(@as(?usize, 2), prefixIndex("ababc", "abc")); // first-byte false start
    try expectEqual(@as(?usize, null), prefixIndex("ababab", "abc"));
    try expectEqual(@as(?usize, null), prefixIndex("ab", "abc")); // needle longer than haystack
}

test "indexOfAnyByte agrees with the scalar std search" {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var hay: [300]u8 = undefined;
    for (&hay) |*b| b.* = 'a' + rand.uintLessThan(u8, 20);
    const sets = [_][]const u8{
        "xy",
        "qzv",
        "abcd",
        "abcdefghijklmnop", // max_first_bytes = 16
        "QZ", // absent from the haystack
    };
    // Slide both endpoints so hits land before, inside, and after the last
    // full SIMD chunk, plus empty and sub-width slices.
    for (sets) |set| {
        var lo: usize = 0;
        while (lo < hay.len) : (lo += 37) {
            var hi = lo;
            while (hi <= hay.len) : (hi += 23) {
                const want = std.mem.indexOfAny(u8, hay[lo..hi], set);
                try std.testing.expectEqual(want, indexOfAnyByte(hay[lo..hi], set));
            }
        }
    }
}

test "prefixIndex anchors on the rarest byte" {
    // 'x' is rarer than 'a'/'e'; a common-first-byte needle must still be
    // found correctly wherever it sits.
    try std.testing.expectEqual(@as(?usize, 6), prefixIndex("aeaeaeaext", "aext"));
    try std.testing.expectEqual(@as(?usize, 0), prefixIndex("aext", "aext"));
    try std.testing.expectEqual(@as(?usize, null), prefixIndex("aeaeaeae", "aext"));
}

test "prefixIndex Rabin-Karp fallback on periodic input" {
    const expectEqual = std.testing.expectEqual;
    const hay = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"; // 39 a's + b
    try expectEqual(@as(?usize, 35), prefixIndex(hay, "aaaab"));
    try expectEqual(@as(?usize, null), prefixIndex(hay[0..39], "aaaab"));
    // A needle whose rarest byte is itself the periodic byte: every anchor
    // hit is a false start, so the cutover to Rabin-Karp fires.
    const hay2 = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxy"; // 30 x's + y
    try expectEqual(@as(?usize, 26), prefixIndex(hay2, "xxxxy"));
    try expectEqual(@as(?usize, null), prefixIndex(hay2[0..30], "xxxxy"));
    try expectEqual(@as(?usize, 0), indexRabinKarp("abcabd", "abc"));
    try expectEqual(@as(?usize, 3), indexRabinKarp("abdabc", "abc"));
    try expectEqual(@as(?usize, null), indexRabinKarp("ab", "abc"));
}

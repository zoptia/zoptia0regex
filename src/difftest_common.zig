//! Comparison helpers shared by the differential-test drivers
//! (`difftest.zig`, `fuzztest.zig`, `longesttest.zig`): equality between a
//! recorded Go result (null when Go returned nil) and this engine's result.

pub fn eqOptInts(want: ?[]i64, got: ?[]i64) bool {
    if (want == null) return got == null;
    if (got == null) return false;
    const a = want.?;
    const b = got.?;
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub fn eqOptNested(want: ?[][]i64, got: ?[][]i64) bool {
    if (want == null) return got == null;
    if (got == null) return false;
    const a = want.?;
    const b = got.?;
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.len != y.len) return false;
        for (x, y) |p, q| if (p != q) return false;
    }
    return true;
}

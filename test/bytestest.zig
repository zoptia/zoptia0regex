//! Byte-level differential corpus (`data/bytes.jsonl`,
//! `tools/cmd/genbytes`): inputs with malformed UTF-8 and NULs, in Perl,
//! `setLongest` and `compilePOSIX` modes, with bounded `findAll`/`split`
//! limits and replacement templates, parser depth limits, and surrogate
//! code points whose literal prefix holds U+FFFD. Every accepted pattern's
//! cases also check the find-all family (see `difftest_common.zig`).
//!
//! Run on its own:  zig build difftest-bytes

const common = @import("difftest_common.zig");

test "byte-level differential vs Go regexp" {
    try common.run(.{
        .corpus = .bytes,
        .data = @embedFile("data/bytes.jsonl"),
        .manifest = @embedFile("data/MANIFEST.json"),
        .require_all = true,
    });
}

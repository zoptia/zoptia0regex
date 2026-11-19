//! Randomized Perl-syntax differential corpus (`data/fuzz.jsonl`,
//! `tools/cmd/genfuzz`): grammar-generated patterns (plus an alternation
//! stream, a stream on inputs with NULs and malformed UTF-8, and a stream of
//! patterns with spliced-in syntax errors). Every accepted pattern's cases
//! also check the find-all family, `replaceAll` and `split` (see
//! `difftest_common.zig`).
//!
//! Run on its own:  zig build difftest-fuzz

const common = @import("difftest_common.zig");

test "fuzz differential vs Go regexp" {
    try common.run(.{
        .corpus = .fuzz,
        .data = @embedFile("data/fuzz.jsonl"),
        .manifest = @embedFile("data/MANIFEST.json"),
        .require_all = true,
    });
}

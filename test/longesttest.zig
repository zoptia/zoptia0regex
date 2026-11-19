//! Randomized leftmost-longest differential corpus (`data/longest.jsonl`,
//! `tools/cmd/genlongest`): Perl-syntax patterns switched to `setLongest()`
//! (Go's `Longest()`, isolating the semantics from POSIX syntax), and POSIX
//! ERE patterns through `compilePOSIX` on inputs with NULs and malformed
//! UTF-8. Every accepted pattern's cases also check the find-all family,
//! `replaceAll` and `split` (see `difftest_common.zig`).
//!
//! Run on its own:  zig build difftest-longest

const common = @import("difftest_common.zig");

test "leftmost-longest differential vs Go regexp" {
    try common.run(.{
        .corpus = .longest,
        .data = @embedFile("data/longest.jsonl"),
        .manifest = @embedFile("data/MANIFEST.json"),
        .require_all = true,
    });
}

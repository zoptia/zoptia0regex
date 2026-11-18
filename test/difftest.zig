//! Curated differential corpus (`data/cases.jsonl`, `tools/cmd/gencases`):
//! hand-picked patterns on hand-picked inputs, Go's own invalid / Perl-only /
//! POSIX-only parser test lists in both syntaxes, and the parser
//! resource-limit boundaries. Checks compile outcome and error code, `ni`,
//! the literal prefix, and the leftmost match (see `difftest_common.zig`).
//!
//! Run on its own:  zig build difftest-cases

const common = @import("difftest_common.zig");

test "curated differential vs Go regexp" {
    try common.run(.{
        .corpus = .cases,
        .data = @embedFile("data/cases.jsonl"),
        .manifest = @embedFile("data/MANIFEST.json"),
        .require_all = false,
    });
}

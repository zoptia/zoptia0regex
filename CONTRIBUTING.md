# Contributing

Thanks for your interest! This is a faithful port of Go's `regexp`, so the
guiding rule is simple: **behaviour must match Go exactly** for the supported
feature set.

## Before you open a PR

```sh
zig build test         # unit + behaviour tests (fast)
zig build difftest     # ~30k differential cases vs Go's recorded output
zig fmt --check src/*.zig build.zig
```

All three must pass. CI runs the same on every push.

## Testing philosophy

Correctness is established by **differential testing against the real Go
`regexp` package**, not by hand-written expectations alone:

- `tools/gencases.go`, `tools/genfuzz.go`, `tools/genlongest.go` run patterns
  through Go and record `FindStringSubmatchIndex`, `FindAllStringSubmatchIndex`,
  `ReplaceAllString` and `Split` into the committed `src/*.jsonl` corpora.
- `src/difftest.zig` / `fuzztest.zig` / `longesttest.zig` re-run every case
  through this engine and assert byte-for-byte equality, under
  `std.testing.allocator` (so leaks fail the build).

If you add or fix behaviour, **add patterns that exercise it** to the relevant
generator and regenerate, so the new behaviour is pinned against Go forever.

## Regenerating tables & corpora

The Unicode tables and the test/benchmark corpora are generated from a local Go
toolchain (the golden reference). You only need this when changing them:

```sh
tools/regen.sh
```

This rewrites `src/fold_table.zig`, `src/unicode_tables.zig`, and the
`src/*.jsonl` corpora. Commit the regenerated files.

## Code style

- `zig fmt`-clean; English comments and identifiers.
- Match the surrounding code; reference the corresponding Go function in a
  comment when porting non-obvious logic.
- Keep the public API in `regexp.zig` aligned with Go's semantics.

## Scope

Optimizations that don't change results (e.g. the alternation `factor()` pass)
and a wider `\p{...}` table set are welcome. New *semantics* should first be
shown to match Go (or explicitly documented as a deviation in the README scope
table).

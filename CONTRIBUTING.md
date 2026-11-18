# Contributing

Thanks for your interest! This is a faithful port of Go's `regexp`, so the
guiding rule is simple: **behaviour must match Go exactly** for the supported
feature set — results, error class, and compiled program shape.

## Before you open a PR

```sh
zig build fmt          # formatting gate (the release toolchain's zig fmt)
zig build test         # unit + behaviour tests (fast)
zig build difftest     # differential cases vs Go's recorded output
zig build check        # compile everything, including the benchmarks
```

All must pass with Zig 0.17 (`zig`). CI runs the same on Linux and macOS,
also tests on zvk's nightly (`zig-nightly build test`,
`zig-nightly build difftest`) and cross-compiles with
`zig build check -Dtarget=wasm32-wasi` (and `riscv64-linux`, `x86-linux`).
Never run the nightly's `zig fmt` on the tree; the release toolchain's
formatting is the gate.

## Layout

| Path | What |
|---|---|
| `src/` | The library and its unit tests — the only code the package ships |
| `test/` | Differential drivers (`difftest.zig`, `fuzztest.zig`, `longesttest.zig`, `bytestest.zig`, sharing `difftest_common.zig`) |
| `test/data/` | Corpora recorded from Go, and `MANIFEST.json` (Go/Unicode versions, case counts) |
| `bench/` | Benchmark harnesses and their workloads (`bench/data/`) |
| `tools/` | Go module: generators and the Go benchmark harnesses |

## Testing philosophy

Correctness is established by **differential testing against the real Go
`regexp` package**, not by hand-written expectations alone:

- The generators in `tools/cmd/` run patterns through Go 1.27.1 and record,
  per case, the compile outcome and error code, the compiled program size
  (`ni`), `LiteralPrefix()`, the leftmost match and — for the random and
  byte-level corpora — the find-all family, `ReplaceAllString` and `Split`:
  - `gencases` → `test/data/cases.jsonl`: curated patterns and inputs, Go's
    parser test lists, parser limits;
  - `genfuzz` → `test/data/fuzz.jsonl`: random Perl-syntax patterns,
    inputs with malformed UTF-8, invalid patterns;
  - `genlongest` → `test/data/longest.jsonl`: leftmost-longest and random
    POSIX ERE patterns;
  - `genbytes` → `test/data/bytes.jsonl`: byte-level inputs, all three
    modes, `FindAll`/`Split` limits, `$` templates, surrogate prefixes.
  Shared code (record format, compile/record logic, random grammars) lives
  in `tools/internal/`.
- The drivers in `test/` replay every case through this engine and require
  identical results, under `std.testing.allocator` (so leaks fail too). Run
  one corpus with `zig build difftest-cases` (or `-fuzz`, `-longest`,
  `-bytes`).

If you add or fix behaviour, **add patterns that exercise it** to the
relevant generator and regenerate, so the new behaviour is pinned against Go
forever. Expectations must come from running Go, never typed by hand.

## Regenerating tables & corpora

The Unicode tables, the test corpora and the benchmark workloads are
generated from Go 1.27.1 (the golden reference). You only need this when
changing them:

```sh
tools/regen.sh
```

It forces `GOTOOLCHAIN=go1.27.1` (the go command downloads that toolchain
if needed), checks `go version`, and rewrites `src/fold_table.zig`,
`src/unicode_tables.zig`, `test/data/*` and `bench/data/*` only after every
generator succeeded. Regeneration is deterministic; commit the regenerated
files. In `tools/`, `go vet ./...` and `gofmt -l .` must be clean.

## Benchmarks

`tools/bench.sh` runs the Zig and Go harnesses and rewrites the generated
blocks in `BENCHMARKS.md` and `README.md`. Never edit those numbers by hand.

## Code style

- `zig fmt`-clean; English comments and identifiers.
- Match the surrounding code; reference the corresponding Go function in a
  comment when porting non-obvious logic.
- Keep the public API in `regexp.zig` aligned with Go's semantics.

## Scope

Optimizations that don't change results are welcome; parser, simplifier and
compiler changes must also keep the compiled program instruction-for-
instruction identical to Go's (checked by `ni` in every corpus). New
*semantics* should first be shown to match Go (or explicitly documented as
a deviation in the scope section of [docs/usage.md](docs/usage.md)).

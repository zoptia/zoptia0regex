# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **faithful Zig 0.16 port of Go's standard-library `regexp` package** (RE2
design). The overriding rule: **observable behaviour must match Go exactly** for
the supported feature set. Almost every `src/*.zig` file is a direct port of a
specific Go source file, and correctness is enforced by **differential testing
against Go's actual recorded output** — not hand-written expectations alone.

The Go reference source is on this machine at
`~/.zvk/go/versions/go1.27.1/src/regexp/` (the port tracks **go1.27.1 /
Unicode 17.0**; `tools/regen.sh` must run with that toolchain so the generated
tables and corpora stay in step) — **read the corresponding Go file before
changing any matching/parsing behaviour.** The port-to-Go file map:

| Zig | Go |
|-----|-----|
| `parse.zig` | `syntax/parse.go` |
| `simplify.zig` | `syntax/simplify.go` |
| `compile.zig` + `prog.zig` | `syntax/compile.go` + `prog.go` |
| `exec.zig` | `exec.go` + `backtrack.go` |
| `onepass.zig` | `onepass.go` |
| `regexp.zig` | `regexp.go` (public API: find/replace/split/expand) |
| `ast.zig` | `syntax/regexp.go` |
| `unicode.zig` | the bits of `unicode` the engine needs |

## Commands

```sh
zig build test                          # unit + behaviour tests (fast)
zig build difftest                      # ~48k differential cases vs Go (slow-ish)
zig build bench                         # benchmark, ReleaseFast (stderr TSV)
zig build demo -- '<pattern>' '<input>' # CLI demo
zig fmt --check src/*.zig build.zig     # must be clean; CI enforces it

# Single test file / single test by name:
zig test src/exec.zig                            # one module's tests
zig test src/tests.zig --test-filter "split"     # one test by name substring
zig test src/difftest.zig                         # run the differential test alone

# Go-side benchmark (compare with `zig build bench`):
( cd tools && go run benchgo.go )

# Regenerate the generated Unicode tables AND the test/benchmark corpora from
# the local Go toolchain (the golden reference). Needed only when changing them:
tools/regen.sh
```

Zig 0.16.0 here is a **zvk-managed build, not a plain ziglang.org release** —
`zig` resolves through `~/.zvk/bin`. CI installs it via zvk's `install.sh`
(`.github/workflows/ci.yml`), not `setup-zig`. The 0.16 std differs a lot from
older Zig: `ArrayList` is unmanaged (`.empty`, `.append(allocator, x)`); there
is no `std.time.Timer` / `std.process.argsAlloc` / `std.fs.cwd` (the Io rework);
`main(init: std.process.Init.Minimal)` is how `demo.zig` gets args.

**Must also build on Zig 0.17.0-dev (`zig-nightly`)** — downstream packages
pin it, and a dependency's `build.zig` is compiled into every consumer's build
runner. Run `zig-nightly build test` before releasing. Known 0.16 ↔ 0.17-dev
splits, all handled: `b.args` vs `Run.addPassthruArgs` and `Fmt.Options.paths`
(`[]const u8` vs `LazyPath`) are gated in `build.zig`; array repetition `**`
is a 0.17 parse error (use `@splat` into a typed array); `std.meta.Int` is
gone (use `@Int`). Keep `@intFromEnum` — nightly's `zig fmt` rewrites it to
`@backingInt`, which 0.16 does not compile, so never run nightly `fmt` on the
tree; the fmt gate is 0.16-only.

## Architecture

**Pipeline:** `compile()` runs `parse → simplify → compile (→ Prog) → build
onepass (if it qualifies)`. Matching runs the compiled program through one of
three engines.

**Three execution engines, dispatched in `exec.zig:execute()` exactly as Go
does** (`onepass != null` → one-pass; small prog+input → bitstate; else Pike VM),
all sharing the compile-time acceleration data in `exec.Accel`: a literal
prefix (`prefixIndexAnchored` — scan anchored on the prefix's rarest byte,
precomputed into `Accel.prefix_anchor`, with a Rabin-Karp fallback like Go's
`bytes.Index`; for one-pass regexps `onePassPrefix` also yields the pc to
resume at after the prefix), and — a port-specific addition with no Go
counterpart — a `first_bytes` set (`regexp.zig:firstBytes`): when there is no
literal prefix, a ≤16-byte ASCII set of possible match-start bytes that the
Pike VM / bitstate engines skip ahead to via `exec.indexOfAnyByte`, a portable
`@Vector` SIMD sweep (this is what makes unanchored `(?i)` and `\d`-led scans
fast). `first_bytes` must stay a *superset* of the true start bytes —
e.g. it is disabled when a case-fold cycle leaves ASCII (`(?i)k` matches
U+212A) — and the Pike VM must recompute the boundary `flag` after a
first-bytes skip (`\b` before the first rune). All three engines must produce
identical results; the differential suite routes anchored patterns through
one-pass and small ones through bitstate, so it tests all of them. Match
semantics: leftmost-first (`compile`) vs POSIX leftmost-longest
(`compilePOSIX` / `setLongest`).

**Subtle invariants to preserve when editing the engine/compiler:**
- Greedy vs non-greedy is encoded purely by the **order of an `alt`
  instruction's two successors** (`compile.zig`). Leftmost-first priority falls
  out of the Pike VM's epsilon-closure order in `add()`.
- Character-class rune lists are **sorted, merged `(lo,hi)` pairs**; `MatchRune`
  binary-searches them. Don't produce unsorted classes.
- Submatch results are padded to `2*(numSubexp+1)` (`padLen`), which can exceed
  `prog.num_cap` when a group is compiled away (e.g. `(a){0}`).
- Range arithmetic near `0` and `max_rune` (0x10FFFF) must use a wider int
  (`u21` overflows on `hi+1`).

**Generated, never hand-edited:** `fold_table.zig`, `unicode_tables.zig`, and all
`src/*.jsonl` corpora are produced by `tools/*.go` from Go and `@embedFile`'d
into the engine/tests. To change them, edit the generator in `tools/` and run
`tools/regen.sh`. The corpora are committed, so `zig build difftest` needs no Go
toolchain (only `regen.sh` does).

**Literal fast path:** `match` / `findIndex` (and their Scratch variants) skip
the engines entirely when `Regexp.isLiteral()` holds (`prefix_complete`, no
one-pass program, no capture groups, no start condition): the answer is
`prefixIndexAnchored` alone. Any new shortcut must be covered by the
`difftest.zig` per-case checks of `match`/`findIndex`/Scratch variants.

**Parser limits:** AST height is tracked per node (`ast.Regexp.parse_height`,
parser-only) and checked in `push` and `repeat` like Go's `checkHeight`;
redundant `(?:…)` groups do not add height, POSIX stacked quantifiers do.

**Find-all loops:** `findAll*`, `split` and the `replaceAll*` family run on
`Regexp.Matches` (`regexp.zig`), the port of Go 1.27's `matches` iterator: one
`Scratch` for the whole loop, `ncap = 2` when only the whole-match location is
needed (like Go's `all`/`allIndex`), full `padLen` captures otherwise.

**Memory model:** a compiled `Regexp` owns a heap-allocated arena (`re.arena`)
holding its program, capture names and prefix; `deinit()` frees it. Execution /
result methods each take an `allocator` for transient VM scratch and (where they
return owned memory) the result, which the caller frees. The differential test
runs under `std.testing.allocator`, so any leak fails the build.

## Adding or changing behaviour

1. Consult the corresponding Go source first; mirror its logic.
2. Add patterns exercising the change to the relevant generator
   (`tools/gencases.go` for curated, `genfuzz.go` for random, `genlongest.go`
   for POSIX, `genbytes.go` for byte-level cases whose inputs must carry
   malformed UTF-8 / NULs or exercise `compilePOSIX`, `FindAll`/`Split`
   limits and `$` templates), run `tools/regen.sh`, and commit the
   regenerated `.jsonl`.
3. `zig build test && zig build difftest` must pass; `zig fmt` must be clean.

## Intentional omissions — do not "fix" these

These diverge from Go's *source* but never from its *results*: the alternation
`factor()` pass is omitted (it only changes the compiled program's shape / raw
speed). Backreferences and `\C` are unsupported — **same as Go** (RE2). Inputs
are `[]const u8` only (no `io.RuneReader`), and Go 1.27's `All*` iterator
methods collapse into the single `Regexp.matches` iterator. See the README
"Scope" table.

(Once also omitted, now ported: `onePassCopy`'s Prog-idiom rewrites and
`doOnePass`'s literal-prefix skip. The port also *adds* one accelerator Go
lacks: the `first_bytes` prefilter described above — behaviour-neutral by
construction and covered by the differential suite.)

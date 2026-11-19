# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **faithful Zig port of Go's standard-library `regexp` package** (RE2
design), targeting **Zig 0.17**. The overriding rule: **observable behaviour,
error class and compiled program shape must match Go exactly** for the
supported feature set. Almost every `src/*.zig` file is a direct port of a
specific Go source file, and correctness is enforced by **differential
testing against Go's actual recorded output** — not hand-written
expectations.

The Go reference source is on this machine at
`~/.zvk/go/versions/go1.27.1/src/regexp/` (the port tracks **go1.27.1 /
Unicode 17.0**; `tools/regen.sh` forces that toolchain) — **read the
corresponding Go file before changing any matching/parsing behaviour.** The
port-to-Go file map:

| Zig (`src/`) | Go (`src/regexp/`) |
|-----|-----|
| `parse.zig` | `syntax/parse.go` |
| `ast.zig` | `syntax/regexp.go` |
| `simplify.zig` | `syntax/simplify.go` |
| `compile.zig` + `prog.zig` | `syntax/compile.go` + `syntax/prog.go` |
| `exec.zig` | `exec.go` (Pike VM, one-pass runner, dispatch) |
| `backtrack.zig` | `backtrack.go` |
| `onepass.zig` | `onepass.go` |
| `search.zig` | none (Go calls `bytes.Index`; the first-byte prefilter is port-only) |
| `regexp.zig` | `regexp.go` (public API: find/replace/split/expand) |
| `unicode.zig` | the bits of `unicode` the engine needs |

## Layout

- `src/` — the library and its unit tests (`tests.zig`, `regressiontest.zig`,
  `oomtest.zig`, `limitstest.zig`, `enginetest.zig`, `scratchtest.zig`). The only directory the
  package ships (`build.zig.zon` `.paths`).
- `test/` — differential drivers, one per corpus, all running
  `test/difftest_common.zig`; corpora and `MANIFEST.json` in `test/data/`.
  They import the library as `@import("regex")`.
- `bench/` — benchmark harnesses; workloads in `bench/data/`.
- `tools/` — Go module (`go 1.27`, `toolchain go1.27.1`): `cmd/<name>/` per
  generator or Go harness, shared code in `internal/` (`corpus`: record
  format and compile/record logic; `randre`: random grammars; `gen`:
  fail-loudly I/O). `regen.sh`, `bench.sh`, `check-zig-version.sh`.

## Commands

```sh
zig build test                          # unit + behaviour tests (fast)
zig build test -Doptimize=ReleaseFast   # same, optimized (CI runs both)
zig build difftest                      # all four differential corpora (ReleaseSafe)
zig build difftest-cases                # one corpus: -cases | -fuzz | -longest | -bytes
zig build check                         # compile everything without running (any -Dtarget)
zig build check -Dtarget=wasm32-wasi    # cross-compile smoke (also riscv64-linux, x86-linux)
zig build fmt                           # formatting gate over src/ test/ bench/ build.zig
zig build demo -- '<pattern>' '<input>' # CLI demo
zig build bench                         # throughput benchmark (ReleaseFast, TSV on stdout)
zig build bench-scratch                 # Scratch micro-benchmark

# One library module's tests / one test by name (src/ files only; the
# drivers in test/ need the build's `regex` module, use the steps above):
zig test src/exec.zig
zig test src/tests.zig --test-filter "split"

tools/regen.sh     # regenerate Unicode tables, corpora, manifest, bench workloads
tools/bench.sh     # run Zig + Go benchmarks, rewrite BENCHMARKS.md / README.md blocks
( cd tools && go vet ./... && gofmt -l . )   # must be clean
```

Zig here is **zvk-managed** (`zig` = 0.17.x release, `zig-nightly` =
0.18.0-dev) and resolves through `~/.zvk/bin`; CI installs it with zvk's
`install.sh`, not `setup-zig`. `build.zig.zon` says
`minimum_zig_version = "0.17.0"`; Zig 0.16 is not supported. **The fmt gate
is the release toolchain's `zig fmt`**; never run `zig-nightly fmt` on the
tree. The package must also build and pass on `zig-nightly` (downstream
packages pin it, and a dependency's `build.zig` is compiled into every
consumer's build runner): run `zig-nightly build test` and
`zig-nightly build difftest` before releasing. CI (push to main, PRs,
weekly) runs the release toolchain on Linux and macOS, the cross-compile
smokes, and the nightly as a blocking job.

## Architecture

**Pipeline:** `compile()` runs `parse → simplify → compile (→ Prog) → build
onepass (if it qualifies)`, then precomputes the literal prefix, first-byte
set and literal-fast-path flag. Every search goes through
`Regexp.findAt` (Go's `(*Regexp).find`): minimum-length rejection, the
literal fast path, then `exec.executeReuse`, which dispatches exactly like Go
(`onepass != null` → one-pass; small prog+input → bitstate; else Pike VM).
`exec.Engine` bundles what the engines read (prog, onepass, cond, longest,
`Accel`); its `mode` field is a test hook used by `enginetest.zig` to force
each engine on the same regexps. Engine storage is a `Scratch` (the
caller's, or a temporary one the allocating API creates only when an engine
runs; that one draws its first 2 KB from the stack through
`std.heap.BufferFirstAllocator`, so short searches skip the allocator).

**Scan acceleration** (`exec.Accel`, `search.zig`): a literal prefix
searched by `prefixIndexAnchored` — anchored on the prefix's rarest byte
(`Accel.prefix_anchor`), with a **cost-based** cutover to Rabin-Karp that
keeps it O(n + m) (not Go's `bytes.Index` strategy); for one-pass regexps
`onePassPrefix` also yields the pc to resume at. And — port-only — a
`first_bytes` `ByteSet` (`regexp.zig:firstBytes`): with no literal prefix,
a ≤16-byte ASCII set of possible match-start bytes the Pike VM / bitstate
engines skip to via `search.indexOfAnyByte` (portable `@Vector` sweep,
scalar on targets without vectors). `first_bytes` must stay a *superset* of
the true start bytes — e.g. it is disabled when a case-fold cycle leaves
ASCII (`(?i)k` matches U+212A) — and the Pike VM must recompute the boundary
`flag` after a skip (`\b` before the first rune). Literal prefixes keep
collecting past an unencodable rune (a surrogate) as U+FFFD, like Go's
`strings.Builder.WriteRune`; such a `lossy` prefix disables the literal fast
path.

**Literal fast path:** when `Regexp.literal` holds (complete, non-lossy
prefix; no one-pass program, capture groups or start condition), any search
needing at most the whole-match slots is `prefixIndexAnchored` alone. Any new
shortcut must stay covered by the differential drivers' `match` /
`findIndex` / Scratch / find-all checks.

**Parser limits:** Go's `checkLimits` (rune budget → `checkSize` →
`checkHeight`) is ported exactly, at Go's call sites. Go's per-node size and
height maps and its node free list are observable (a recycled node keeps a
stale size), so the parser keeps them in a parser-private `Node` wrapper
around each `ast.Regexp` (`parse.zig`); the AST carries no parser state.
`factor` / `collapse` run on an explicit heap frame stack (no native
recursion), class rune lists grow with amortised capacity. Boundaries are
pinned in `src/limitstest.zig` and the curated corpus.

**Pike VM `add` is iterative:** Go recurses on `alt.out` and capture
bodies; the port follows `out` immediately and pushes `arg` / capture-restore
frames on `Scratch.add_stack` (≤ one frame per instruction), preserving the
depth-first order and hence match priority.

**Subtle invariants to preserve when editing the engine/compiler:**
- Greedy vs non-greedy is encoded purely by the **order of an `alt`
  instruction's two successors** (`compile.zig`). Leftmost-first priority falls
  out of the Pike VM's epsilon-closure order in `add()`.
- Character-class rune lists are **sorted, merged `(lo,hi)` pairs**;
  `matchRunePos` binary-searches them. Don't produce unsorted classes.
- Submatch results are padded to `2*(numSubexp+1)` (`padLen`), which can
  exceed the capture slots the program actually uses when a group is
  compiled away (e.g. `(a){0}`); the extra slots stay -1.
- Range arithmetic near `0` and `max_rune` (0x10FFFF) must use a wider int
  (`u21` overflows on `hi+1`).
- **Keep `Inst` at 32 bytes.** The per-pc ASCII membership bitmap
  (`Prog.ascii`, built by `compile.zig:asciiBitmap`, read through
  `Prog.matchRuneAt`) is a side table because putting it in `Inst` slowed
  the bitstate engine by ~25%. The bitmap must agree with
  `prog.matchRunePos` for every ASCII rune (unit test in `compile.zig`).

**Find-all and replace loops:** `findAll*` and `split` run on
`Regexp.Matches` (`regexp.zig`), the port of Go 1.27's `matches` iterator:
one `Scratch` for the whole loop, `ncap = 2` when only the whole-match
location is needed, full `padLen` captures otherwise. `replaceAllCore` is
its own loop, like Go's `replaceAll`.

**Memory model:** a compiled `Regexp` owns a heap-allocated arena (`re.arena`)
holding its program, capture names and prefix; `deinit()` frees it. Execution /
result methods take an `allocator` for transient engine storage and (where
they return owned memory) the result, which the caller frees. The tests and
drivers run under `std.testing.allocator`, so any leak fails the build.

**Scratch result buffers:** a `Scratch`'s engine buffers are used only
within one search, so calls may interleave on one thread. Results that
outlive a call each have their own storage: `findSubmatchIndexScratch`
returns `Scratch.result`, and every `matchesScratch` iterator checks out a
buffer from the `Scratch.iter_bufs` pool (`acquireIterBuf`; reused when big
enough, so warm loops allocate nothing) that `Matches.deinit` hands back
(`releaseIterBuf`, never allocates). Never let two live results share a
buffer again: nested iteration over one `Scratch` is supported
(`src/scratchtest.zig`). The buffer also returns on exhaustion (`next()`
→ null), so run-to-completion loops without `deinit` — the pre-0.8.0
contract — do not grow the pool; an iterator abandoned mid-way must be
`deinit`ed before its `Scratch` (Debug builds panic in `Scratch.deinit`
otherwise).

## Differential testing

`tools/cmd/gen{cases,fuzz,longest,bytes}` record Go's behaviour into
`test/data/*.jsonl` (format documented in `tools/internal/corpus`). For
**every** case the drivers check: compile outcome and Go's
`syntax.ErrorCode` text (OOM always fails); for an error case also Go's
`syntax.Error.Expr` against `Diagnostic.expr` (`ee`, or `eeh` length+hash
when long) and Go's `MustCompile`/`MustCompilePOSIX` panic message against
`CompileFailure` (`msg`/`msgh`); `ni` (Go's instruction count of
`syntax.Compile(syntax.Parse(p, flags).Simplify())` — mandatory, so a
parser/simplifier/compiler change that alters program shape fails even when
results agree), `literalPrefix()` (bytes + complete flag), and the leftmost
match via `findSubmatchIndex` / `match` / `findIndex` / Scratch variants;
the fuzz, longest and bytes corpora also check `findAllSubmatchIndex`,
`findAllIndex`, `matchesScratch`, `replaceAll` and `split`. Each
corpus ends with a `{"count":N}` trailer that must match the case count and
`test/data/MANIFEST.json`. The Zig-side error-code table is the public
`regex.errorString` (`src/regexp.zig`). The parser records the fragment at
each error site via `Parser.fail` (`src/parse.zig`); `gencases`'s
`errorSites` list reaches every reachable `&Error{...}` site of Go's
`parse.go` in both syntaxes. Never type expectations by hand: change a
generator and run `tools/regen.sh`.

**Generated, never hand-edited:** `src/fold_table.zig`,
`src/unicode_tables.zig`, everything in `test/data/` and `bench/data/`, and
the `BEGIN/END GENERATED` blocks in `BENCHMARKS.md` / `README.md`
(`tools/bench.sh`).

## Adding or changing behaviour

1. Consult the corresponding Go source first; mirror its logic.
2. Add patterns exercising the change to the relevant generator
   (`gencases` for curated, `genfuzz` for random Perl, `genlongest` for
   leftmost-longest / random POSIX, `genbytes` for byte-level inputs, modes,
   limits and templates), run `tools/regen.sh`, and commit the regenerated
   data.
3. `zig build test && zig build difftest` must pass on `zig` and
   `zig-nightly`; `zig build fmt` must be clean.

## Intentional omissions — do not "fix" these

Backreferences and `\C` are unsupported — **same as Go** (RE2). Inputs
are `[]const u8` only (no `io.RuneReader`), and Go 1.27's `All*` iterator
methods collapse into the single `Regexp.matches` iterator. See
`docs/usage.md` §6 "Scope & differences from Go".

Port-only additions, behaviour-neutral by construction and covered by the
differential suite: the `first_bytes` prefilter, the literal fast path, the
ASCII rune bitmap, and the cost-based prefix search.

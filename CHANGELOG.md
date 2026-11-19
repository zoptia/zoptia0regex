# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.8.1] — 2026-11-19

### Changed

- **Pike VM capture copies are inline.** The Pike VM copies the capture
  registers for every thread it starts; for the 2 slots of a find-all loop
  that was a call into libc `memcpy`. Short register sets are now copied
  inline: the Pike VM find-all rows of the benchmark are 8–13 % faster
  (`[A-Za-z]+`, `\w+`, `\p{L}+`, the e-mail pattern, the keyword list).
- **The allocating API's temporary scratch starts on the stack.** A single
  allocating search (`match`, `find`, `findIndex`, `findSubmatch`, …) gives
  its temporary `Scratch` a 2 KB stack buffer and falls back to the caller's
  allocator only beyond that, so a search over a short input usually does
  no heap allocation: `match` on a 20–60 byte input is 20–35 % faster on
  the bitstate rows of the Scratch benchmark. Results returned to the caller still come from the caller's
  allocator.

### Fixed

- **Benchmark tables.** The harnesses reported a single timed batch, and
  the 0.8.0 tables contained rows inflated by background load (the Scratch
  table's `email_unanchored`, `alternation` and `charclass_plus` rows, and
  Go's `literal_hit`). All four harnesses now time five batches at the
  calibrated iteration count and report the fastest; the tables are
  regenerated. The compile ratio moved from 0.69× to 0.77× with the new
  method: the port's compile times are unchanged, Go's were the noisier
  side.

## [0.8.0] — 2026-11-19

### Fixed

- **Use-after-free in nested `matchesScratch` iteration.** A
  `matchesScratch` iterator took its offsets buffer from the same single
  `Scratch` buffer that `findSubmatchIndexScratch` returns. Two live
  iterators on one `Scratch` (a nested loop), or a
  `findSubmatchIndexScratch` call inside an iterator loop, shared that
  buffer, and an inner call that needed more capture slots reallocated it,
  so the outer iterator read and wrote freed memory. Each iterator now
  checks out an offsets buffer of its own from a small pool in the
  `Scratch` (reused once big enough, so warm loops — nested ones included —
  still allocate nothing) and `Matches.deinit` returns it.
  `findSubmatchIndexScratch` keeps its own buffer, valid until the next
  `findSubmatchIndexScratch`. Nested iteration and interleaved `*Scratch`
  calls on one `Scratch` are now supported.

### Added

- **Compile diagnostics.** `compileDiagnostic` / `compilePOSIXDiagnostic`
  fill a `Diagnostic` with the error and Go's `syntax.Error.Expr` — the
  offending fragment, a sub-slice of the caller's pattern (no allocation) —
  for every parse error site; `{f}` on it prints Go's `Error()` text.
  `compile` / `compilePOSIX` are unchanged.
- The differential corpora record `Error.Expr` and the `MustCompile` panic
  message for every error case (`ee`/`eeh`, `msg`/`msgh`), and the drivers
  compare both in all four corpora; `cases.jsonl` gains patterns that reach
  every reachable error site of Go's `parse.go` in both syntaxes
  (16,280 → 16,599 cases).
- `unicode.isPrint` (Go's `unicode.IsPrint`).

### Changed

- **`matchesScratch` iterators hold a pooled buffer.** It goes back to the
  `Scratch` when the iterator is exhausted (`next()` returns null) or
  `deinit`ed, so loops that run to completion without `deinit` — the
  contract documented before 0.8.0 — keep working and do not grow the pool.
  An iterator abandoned mid-way must be `deinit`ed, before its `Scratch`;
  otherwise its buffer stays checked out until `Scratch.deinit`, which
  panics in Debug builds to flag it. `next()` / `deinit()` after `deinit`
  trip an assertion in safe builds.
- **`mustCompile` / `mustCompilePOSIX` panic with Go's message byte for
  byte**, now including the fragment
  (``regexp: Compile(`a(`): error parsing regexp: missing closing ): `a(` ``)
  and `strconv.Quote`'s exact escapes for non-printable runes.
- **Canonical names drop Go's `String` suffix** (both Go variants take
  `[]const u8` here): `replaceAll`, `replaceAllLiteral`.

### Deprecated

- `Regexp.replaceAllString` → `replaceAll`,
  `Regexp.replaceAllLiteralString` → `replaceAllLiteral`,
  `Regexp.matchString` → `match`, `Regexp.replaceAllStringFunc` →
  `replaceAllFunc`. They remain as thin aliases and keep compiling.

## [0.7.0] — 2026-11-17

### Toolchain

- **Zig 0.17 baseline.** `minimum_zig_version = "0.17.0"`; Zig 0.16 is no
  longer supported, and the 0.16/0.17 gates in `build.zig` are gone. The
  release toolchain's `zig fmt` is the formatting gate. The package is also
  tested on zvk's nightly (0.18.0-dev).
- **Non-SIMD and 32-bit targets build again.** `indexOfAnyByte`'s scalar
  fallback failed to compile on targets without vector registers (wasm32,
  riscv64), and the parser's node cast failed on 32-bit targets, where the
  parser's `Node` is more aligned than the `Regexp` it wraps; the demo now
  uses the args iterator that also compiles for WASI. CI now
  cross-compiles for `wasm32-wasi`, `riscv64-linux` and `x86-linux`.

### Fixed

- **Parser stack overflow in alternation factoring.** Go's `factor`
  recurses once per factored prefix and relies on growable goroutine
  stacks; the port segfaulted on a long common prefix. `factor` /
  `collapse` now run on an explicit heap frame stack in Go's step order,
  and report Go's `NestingDepth` where Go does.
- **Quadratic class merges.** Merging single-rune alternatives into a
  class (`swapVerticalBar`, `factor`) copied the whole rune list on every
  merge (1.5 GB for a 20,000-way alternation); rune lists now grow in
  place with amortised capacity, like Go's `append`.
- **Pike VM stack overflow.** `Machine.add` recursed like Go's
  `machine.add`; programs past roughly 100k instructions (e.g. 21k `a??`
  in a row, 10k empty captures) overflowed the native stack. The epsilon
  closure is now iterative on an explicit stack in `Scratch`, in the same
  order, so match priority is unchanged.
- **Exact Go resource limits.** The parser approximated Go's limits with a
  2M-node stack cap and a 3.3M-instruction compiler cap, disagreeing with
  Go in both directions (and on the error class). Go's `checkLimits` —
  rune budget, then `checkSize`'s program-size estimate, then
  `checkHeight` — is now ported exactly at Go's call sites, including Go's
  node free list and its observable stale size cache.
- **Surrogates in literal prefixes.** A literal prefix stopped at a
  surrogate code point (`\x{D800}`), while Go writes it as U+FFFD and keeps
  going: in Go `^a\x{D800}` matches `"a\u{FFFD}"` through the one-pass
  prefix skip and `LiteralPrefix` of `a\x{D800}b` is `("a\u{FFFD}b",
  true)`. The port now does the same; such a prefix never takes the
  literal fast path.
- **Prefix search worst case.** The rarest-byte prefix search switched to
  Rabin-Karp only after a false-start count that a periodic haystack never
  reached, so a 100 KB needle over a 4 MB periodic input took over a
  second (Go: 5 ms). The cutover is now cost-based, keeping the search
  O(n + m).
- The Literal flag builds one literal node like Go's `literalRegexp`.
- Fix the nondeterministic `NondeterministicMemoryUsage` failure of the
  Pike-VM OOM regression test on nightly (Linux x86_64): every
  `checkAllAllocationFailures` call now uses a backing allocator that
  fails all resizes, so growth always goes through `alloc`. No library
  change.

### Changed

- **Engine files follow Go's layout.** `exec.zig` keeps the input decoding,
  `Scratch`, the Pike VM, the one-pass runner and the dispatch
  (`exec.Engine`); the bitstate backtracker moves to `backtrack.zig` and
  the substring / byte-set scans to `search.zig`. Every search goes through
  one internal entry point, `Regexp.findAt` (Go's `find`), and the
  allocating API sets up engine storage only when an engine runs.
- **The package no longer ships test data.** The differential drivers and
  corpora moved to `test/`, the benchmarks to `bench/`; `src/` holds only
  the library and its unit tests, which shrinks a consumer's download from
  about 7.6 MB to about 0.8 MB.
- Removed an editor swap file (`src/.exec.zig.swp`) committed by mistake
  after 0.6.0; editor and OS droppings are now ignored.

### API

- **`replaceAllFunc`**: append-style replacement callback
  (`fn(ctx, allocator, *ArrayList(u8), match) ExecError!void`) that can
  allocate and fail; a callback error frees the partial output.
  `replaceAllStringFunc` stays, built on top of it, with its lifetime rule
  documented.
- **`findAllSubmatch`** / `freeAllSubmatch` (text variant of
  `findAllSubmatchIndex`), **`mustCompilePOSIX`**, and a package-level
  one-shot **`match(gpa, pattern, input)`** (Go's `regexp.MatchString`).
- **`errorString(err)`** maps every `ParseError` to Go's `syntax.ErrorCode`
  text; `mustCompile` now panics with Go's message shape
  (``regexp: Compile(`a(`): error parsing regexp: missing closing )``) and
  reports out-of-memory as such instead of as a pattern error.
- **`expand` takes `[]const i64`**, so it composes with the `matches`
  iterator (source-compatible for existing callers).
- `literalPrefix` returns the named type **`LiteralPrefix`**.
- `Regexp.deinit` poisons the value: a second `deinit` of the same variable
  trips an assertion in safe builds. Copy, nested-`matchesScratch` and
  `setLongest` threading rules are documented on the types and in
  `docs/usage.md`.
- Removed the never-read `Prog.num_cap` (visible only through
  `syntax.prog`).

### Testing

- **Every corpus checks the error class.** Generators record Go's
  `syntax.ErrorCode` text and the drivers compare it with the port's error;
  an `OutOfMemory` now fails instead of passing as "errored like Go".
- **Program shape everywhere.** `ni` (Go's instruction count) is recorded
  and mandatory for every accepted pattern in every corpus, including the
  `Longest()` and `CompilePOSIX` modes, which had no shape check.
- **Literal prefixes** (`LiteralPrefix()`, bytes and complete flag) are
  checked for every case.
- **No silent truncation.** Each corpus ends with a `{"count":N}` trailer
  that must equal the cases read and `test/data/MANIFEST.json` (which also
  records the Go and Unicode versions); `tools/regen.sh` writes to a
  temporary directory and installs the results only when every generator
  succeeded.
- **New cases:** Go's `invalidRegexps` / `onlyPerl` / `onlyPOSIX` parser
  lists and `badRe` in both syntaxes; the parser's size, height and
  factor-recursion boundaries; surrogate prefixes; random patterns with
  spliced-in syntax errors; random inputs with NULs and malformed UTF-8; a
  random POSIX ERE stream. `genlongest` records patterns that fail to
  compile instead of dropping them, and the longest corpus now also checks
  `findAllIndex`, `replaceAllString` and `split`.
- One shared driver (`test/difftest_common.zig`) with per-corpus build
  steps (`zig build difftest-cases|fuzz|longest|bytes`); new unit tests for
  the parser limits (`limitstest.zig`) and an engine cross-check that forces
  every engine on the same regexps (`enginetest.zig`).
- **Generators are a Go module** (`tools/go.mod`, one command per
  directory, shared `internal/` packages, every error checked); `regen.sh`
  pins `GOTOOLCHAIN=go1.27.1` and checks `go version`.
- **Benchmarks are generated, not hand-copied.** Both harnesses print TSV
  with a cross-checked per-run result, the Go side is built as a binary,
  and `tools/bench.sh` / `tools/cmd/benchtable` rewrite the tables in
  `BENCHMARKS.md` and the README headline. The Scratch benchmark replaces
  the `needle` case (now a literal fast-path hit) with `needle\d+`.

### CI

- Runs on push to main, pull requests and weekly; least-privilege token;
  timeouts on every job.
- Release toolchain on Linux and macOS: fmt gate (over `src/`, `test/`,
  `bench/`, `build.zig`), build, unit tests in Debug and ReleaseFast,
  differential suite, and `zig build check` (compiles the benchmarks).
- Cross-compile smoke for `wasm32-wasi`, `riscv64-linux`, `x86-linux`.
- The nightly job is blocking (no `continue-on-error`, which had hidden a
  real failure). Every job checks the installed Zig against
  `minimum_zig_version`.
- `actions/checkout@v4` → `@v7` (Node 24 LTS; Node 20 is deprecated on
  GitHub runners).

## [0.6.0] — 2026-09-22

### Performance

- **Alternation factoring, ported from Go.** The parser now runs Go's
  AST-shaping passes that the port had skipped as "result-neutral":
  `maybeConcat` literal coalescing, `push`'s single-rune class rewrite
  (`[a]` → `a`, `[Aa]` → `(?i)a`), the `swapVerticalBar` class merge,
  `cleanAlt`, and `factor` (common literal prefixes, common leading classes
  or fixed repeats, runs of single runes merged into a class, collapsed
  empty alternatives). They are result-neutral but not speed-neutral: a
  40-word keyword list compiled to 342 instructions instead of Go's 194 and
  ran at 3.05× Go; it now runs at **0.38×**. Benchmark geomean over
  22 workloads: **0.45×** Go (0.52× without literal_hit).

### Added

- `Regexp.matchesScratch`: the `matches` iterator borrowing engine buffers
  and the yielded offsets from a caller-owned `Scratch`, so repeated
  find-all scans allocate nothing once warm.

### Testing

- `cases.jsonl` and `fuzz.jsonl` now record `ni`, Go's compiled program
  length per pattern, and the tests require the port to match it exactly —
  AST-shape fidelity, not just result fidelity. Verified to fail on the
  0.5.3 parser.
- Curated corpus gains ~70 factoring patterns (prefix runs, class merges,
  empty alternatives, flag and quantifier boundaries factor must respect);
  the fuzz corpus gains an independent 300-pattern alternation stream.
  Differential suite: ~53.9k cases.
- Benchmarks gain `keyword_list` and `domain_allowlist`.

## [0.5.3] — 2026-09-22

### Performance

- **ASCII bitmap for rune instructions.** Every general `rune` instruction
  gets a compile-time 128-bit ASCII membership bitmap, stored as a side table
  in `Prog` so `Inst` stays 32 bytes (inline, it slowed the bitstate engine
  by ~25%). The Pike VM and bitstate engines answer ASCII input with one bit
  test instead of a range scan, binary search or case-fold orbit walk.
  `(?i)performance` findall 0.13× Go (was 0.23×), `\p{L}+` 0.51× (was
  0.63×); benchmark geomean vs Go **0.45×** (0.52× without literal_hit;
  0.5.2: 0.47× / 0.54×). The bitmap is built from the range list in
  O(ranges), costing ~5–15% of compile time; compile geomean 0.80× Go.

### Testing

- `zig build difftest` always builds in ReleaseSafe: the ~48k cases run in
  about half the Debug time with safety checks still on.
- New unit test: the bitmap agrees with `matchRunePos` on all 128 ASCII
  runes for classes, fold literals, `\pL`, negated and POSIX classes.

## [0.5.2] — 2026-09-15

Merges the `fix/regex-allocation-and-literal` audit branch. No change to
match results; the differential suite grows to ~47.8k cases (four corpora)
and still reports zero mismatches on Zig 0.16.0 and 0.17.0-dev.2131.

### Fixed

- **Capture names borrowed the caller's pattern buffer.** `parsePerlFlags`
  stores names as slices of the pattern, and the pattern was copied into the
  regexp's arena only after parsing, so `subexpNames()` / `${name}` dangled
  once the caller freed or reused its buffer. The copy now happens before
  parsing.
- **AST height limit matched Go only approximately.** Nesting was counted as
  open parentheses; Go measures parse-tree height. POSIX stacked quantifiers
  (`a` + 1000 `*`) were accepted where Go returns `ErrNestingDepth`, and 1001
  redundant `(?:…)` groups were rejected where Go accepts them. Height is now
  cached per node and checked in `push` and `repeat`, like Go's `checkHeight`.
- **Allocation-failure cleanup.** Growing a `Scratch` buffer freed the old
  block before allocating the new one, leaving a dangling pointer for
  `deinit` to free again; a Pike VM thread whose capture array failed to
  allocate leaked; a copied submatch slice leaked when the collecting list
  failed to grow. All three now clean up, verified with
  `checkAllAllocationFailures` over compilation and every result-producing
  API (`src/oomtest.zig`, `src/regressiontest.zig`).
- Freshly allocated Pike VM and one-pass sparse-set index buffers are zeroed
  once on (re)allocation; reading undefined memory is UB in Zig even though
  the dense cross-check made the stale-value case sound. Reuse between
  matches still does no clearing.
- Docs: `find` returns a borrowed sub-slice and `findIndex` a `Match` value —
  neither is freed; README examples free the `findSubmatch` outer slice.

### Performance

- **Complete-literal fast path.** When the regexp is exactly a literal (no
  captures, assertions or case folding), `match`, `findIndex` and their
  `Scratch` variants answer with the prefix search alone. `literal_hit` in
  the benchmark drops from ~200 ns to 5 ns; benchmark geomean vs Go
  **0.47×** (0.54× without that row).

### Testing

- New byte-level corpus `src/bytes.jsonl` (`tools/genbytes.go`, ~12.1k
  cases): inputs and outputs stored as byte arrays so malformed UTF-8 and
  NULs survive JSON; covers Perl / `setLongest` / `compilePOSIX`, bounded
  `findAll` / `split`, `$` templates and parser depth limits. Part of
  `zig build difftest`.
- The curated corpus now also checks `match`, `findIndex` and both `Scratch`
  variants per case, so any engine shortcut is held to the recorded result.

## [0.5.1] — 2026-09-10

### Zig compatibility

Builds on **Zig 0.16.0** (still the `minimum_zig_version`) and on the
**0.17.0-dev** nightlies (verified on 0.17.0-dev.2085+5e36170b5: unit,
behaviour and all ~35.7k differential tests pass, demo and benchmarks build).
No behaviour change; `zig fetch --save` consumers on either toolchain can now
depend on the package.

- `build.zig`: forward demo args via `b.args` on 0.16 and
  `Run.addPassthruArgs` on 0.17-dev (the `args` field is gone there). A
  dependency's `build.zig` is compiled into every consumer's build runner, so
  this line alone broke consumers on nightly. `addFmt` paths likewise switch
  between `[]const u8` and `LazyPath` by inspecting `Fmt.Options`.
- Array repetition `x ** n` (a parse error on 0.17-dev) replaced by
  `@splat` into an explicitly typed array; `std.meta.Int` (removed on
  0.17-dev) replaced by the `@Int` builtin. Both spellings work on 0.16.
- CI gains a non-blocking `test-nightly` job (`zvk zig install nightly`,
  `zig-nightly build test` + `difftest`) so the next std rename is caught
  early. The `zig fmt --check` gate stays on 0.16: nightly's formatter rewrites
  `@intFromEnum` to `@backingInt`, which 0.16 does not compile.

## [0.5.0] — 2026-09-10

### Upstream sync: Go 1.27.1 / Unicode 17.0

The reference toolchain moves from go1.26.4 to go1.27.1. Every generated
table and corpus is regenerated from it; the differential suite grows to
~35.7k cases and still reports zero mismatches.

- **Unicode 17.0 tables.** `fold_table.zig` (`unicode.SimpleFold`) and
  `unicode_tables.zig` now come from Go 1.27's `unicode` package, so `(?i)`
  and `\p{…}` see the Unicode 16/17 additions (e.g. the cased Garay script).
- **Full `\p{…}` name set.** The tables are no longer a curated subset: every
  general category and script Go accepts is included, plus
  `unicode.CategoryAliases` (`\p{Letter}`, `\p{Uppercase_Letter}`, …), the
  special names `Any`, `Assigned`, `ASCII`, `LC`, and — following Go 1.27's
  "apply canonicalization to scripts lookup" — script names matched ignoring
  case, `_`, `-` and spaces (`\p{Old_Italic}`, `\p{old italic}`).
- **`(?i)\p{…}` fold merge (fidelity fix).** Go merges `unicode.FoldCategory` /
  `FoldScript` into the class under `(?i)` (`(?i)\p{Lu}` matches lowercase
  letters too); the port previously skipped that step. Now ported exactly,
  including the negated form and `(?i)\p{ASCII}` (adds `ſ` and `K`).
- **`Regexp.matches` iterator.** Port of Go 1.27's `matches` (the engine
  behind its new `All*` iterators and `FindAll*`): `findAll`, `findAllIndex`,
  `findAllSubmatchIndex`, `split` and the `replaceAll*` family now share one
  engine `Scratch` per call instead of re-allocating it per match, and the
  index/text variants track only the whole-match slots (Go's `ncap = 2`).
  `findAll` over `\w+` on the 256 KB corpus drops from ~14 allocations per
  match to none; benchmark geomean vs Go: **0.56×** (0.4.0: 0.64×).
- Curated corpus (`gencases.go`) gains ~90 `\p{…}` patterns and inputs
  covering aliases, canonical names, fold merges and new Unicode characters.

## [0.4.0] — 2026-07-11

### Performance

Prefilter upgrades, all behaviour-neutral (~30k differential cases still
byte-for-byte identical to Go). Benchmark geomean vs Go: **0.64×**
(0.3.0: 0.73×); details in BENCHMARKS.md.

- **SIMD first-byte scan.** The prefilter now scans with `exec.indexOfAnyByte`,
  a portable `@Vector` sweep (NEON on aarch64, SSE2 on baseline x86_64, wider
  with `-Dcpu=native`, scalar fallback on vector-less targets) instead of the
  scalar `std.mem.indexOfAny`.
- **First-byte set widened from 4 to 16 bytes** — `\d`-led patterns now
  qualify: the `date` and `digits` corpus scans drop from 0.81×/0.87× vs Go
  to **0.21×/0.27×**; unanchored `(?i)performance` reaches **0.25×**.
- **Rarest-byte anchoring for the literal-prefix search** (rust-memmem's
  heuristic): `prefixIndex` scans for the prefix's least-frequent byte rather
  than its first byte, with the anchor offset precomputed at compile time
  (`Accel.prefix_anchor`) so short-input hot loops pay nothing.

## [0.3.0] — 2026-07-11

### Performance

Five behaviour-neutral engine optimizations (all ~30k differential cases still
byte-for-byte identical to Go). New benchmark geomean vs Go: **0.73×**
(was 0.887×); details in BENCHMARKS.md.

- **First-byte prefilter (no Go counterpart).** When a pattern has no literal
  prefix but can only start with ≤ 4 ASCII bytes (case-insensitive literal,
  small leading class, alternation of such), the Pike VM and bitstate engines
  skip ahead with a vectorized byte scan. Disabled whenever it could be unsafe
  (nullable patterns, non-ASCII starts, case-fold cycles that leave ASCII such
  as `(?i)k` ↔ U+212A). Unanchored `(?i)performance` over 256 KB: 1.29× vs Go
  → **0.28×** (3.5× faster than Go); alternation scan 0.81× → **0.37×**.
- **ASCII fast path in the rune decoder** (`Input.step`), a few percent on
  every engine and ~35–50% on short anchored one-pass matches.
- **One-pass literal-prefix skip** (ports Go's `onePassPrefix` / `doOnePass`
  skip): anchored patterns with a literal head check it with one `startsWith`
  and resume past its instructions. Also fixes `literalPrefix()` for one-pass
  regexps to match Go's (capture-safe) prefix.
- **`onePassCopy` Prog-idiom rewrites** (ports the previously-omitted Go
  pass): more anchored patterns qualify for the one-pass engine.
- **Rabin-Karp fallback in `prefixIndex`** (mirrors Go's `bytes.Index`):
  the literal-prefix scan is now worst-case linear instead of O(n·m) on
  periodic inputs.

### Added

- `findIndexScratch`: the `findIndex` companion to `matchScratch` /
  `findSubmatchIndexScratch`, completing the allocation-free family for hot
  loops that need match offsets.
- `zig build fmt`: the CI formatting gate as a build step.
- Unit tests for the delicate internal helpers (`simplify` counted-repeat
  expansion, `cleanClass` / `negateClass`, `mergeRuneSets`, `decodeLastRune`,
  `prefixIndex`); `onepass.zig` is now included in the `zig build test` tree.
- The `Scratch` API is now documented in the usage guide (it shipped in 0.2.0
  undocumented).

### Fixed

- `findSubmatchIndex` and the `findAll*` family no longer leak the caps buffer
  if the engine reports `OutOfMemory` mid-search.
- `mergeRuneSets` no longer leaks its partially-built buffers when the rune
  sets intersect (previously masked by arena allocation).
- One-pass compilation no longer pins its transient analysis state (queues,
  visit maps, intermediate rune sets) in the `Regexp`'s arena for the pattern's
  whole lifetime; a failed qualification now allocates nothing lasting.

### Internal

- Removed dead code: the parser's unused `whole` field and `before` parameter,
  `onepass.iop`, and dead statements in the corpus generators.
- The three differential-test drivers share one comparison-helper module; the
  public exec entry points in `regexp.zig` share `execAt` helpers.
- Documentation/comment drift corrected (stale "single engine" module header in
  `exec.zig`, misplaced difftest comment in `build.zig`, wrong "gitignored"
  claims about committed corpora, `regen.sh` output list).

## [0.2.0] — 2026-06-28

### Added

- **Allocation-free matching via a reusable `Scratch`.** `Regexp.matchScratch`
  and `Regexp.findSubmatchIndexScratch` take a caller-owned `Scratch`
  (`Scratch.init` / `deinit`) and reuse the Pike-VM and bitstate engine buffers
  (sparse-set queues, thread pool, visited bitmap) across calls — the port's
  equivalent of Go's per-`Regexp` `*machine` `sync.Pool`. After warm-up a hot
  match loop does zero heap allocation. The existing `match` / `find` / `replace`
  / `split` API is unchanged; it now wraps the same path with a temporary
  scratch, so the differential suite validates the shared code.

### Performance

- Reusing one `Scratch` across a short-input hot loop is ~1.2–2.8× faster than
  the allocating `match`, closing the per-call allocation gap with Go's pooled
  machine. See BENCHMARKS.md ("Allocation-free matching").
- Pike-VM sparse sets are no longer zeroed on each run — the dense cross-check
  makes a stale sparse index safe — removing two `memset`s from the hot path.

### Validation

- ~30,000 differential cases still byte-for-byte identical to Go, zero leaks
  (the new reuse path is what the suite now exercises).

## [0.1.0] — 2026-06-25

Initial release: a faithful Zig port of Go's `regexp` package.

### Engines

- **Pike VM** (NFA simulation) with submatch capture and leftmost-first
  (and POSIX leftmost-longest) semantics.
- **Bitstate backtracker** for small programs/inputs.
- **One-pass** engine for qualifying anchored regexps.
- **Literal-prefix acceleration** (vectorized first-byte scan + verify).

### Features

- Full `regexp/syntax` parser: literals, alternation, character classes
  (Perl `\d\w\s`, POSIX `[[:…:]]`, Unicode `\p{…}` subset), `.`, anchors
  `^ $ \A \z \b \B`, quantifiers `* + ? {n,m}` (greedy/non-greedy), capturing /
  non-capturing / named groups, inline flags `(?imsU)`, escapes and `\Q…\E`.
- Public API mirroring Go: `compile`, `compilePOSIX`, `mustCompile`, `match`,
  `find` / `findIndex`, `findSubmatch` / `findSubmatchIndex`,
  `findAll` / `findAllIndex` / `findAllSubmatchIndex`, `replaceAllString` /
  `replaceAllLiteralString` / `replaceAllStringFunc`, `expand`, `split`,
  `quoteMeta`, plus introspection (`numSubexp`, `subexpIndex`, `literalPrefix`).
- Unicode case folding via tables generated from Go's `unicode.SimpleFold`
  (correct across all of Unicode).
- Parser resource limits matching Go (`maxHeight`, `maxRunes`, repeat-size).

### Validation

- ~30,000 differential cases vs Go's `regexp` (curated + randomized +
  leftmost-longest), byte-for-byte identical, zero leaks.

### Performance

- ~11% faster than Go on average (geomean 0.887× over 20 workloads), ~1.7×
  faster to compile; faster than Go on anchored validation patterns.

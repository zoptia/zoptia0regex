# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

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

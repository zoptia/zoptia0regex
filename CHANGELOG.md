# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

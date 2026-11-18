# Internals — how zoptia0regex works

This is the architecture / deep-dive document for contributors and the
curious. It explains the theory the engine is built on, the four-stage
pipeline, the three execution engines and how they are dispatched, the
invariants the implementation relies on, and the differential-testing
methodology that keeps the whole thing honest.

zoptia0regex is a faithful port of Go's standard-library `regexp` package —
itself an implementation of the **RE2** design by Russ Cox. The guiding rule
throughout the codebase is *result-identical to Go*: every design decision,
down to the order of two successor instructions, exists to reproduce Go's
observable behaviour byte-for-byte. The port is derived from Go's
BSD-3-Clause sources (attributed in `NOTICE`); it is not affiliated with Go
or Google.

---

## 1. Background: RE2, the Thompson NFA, and the linear-time guarantee

Most "regex" engines you have used — PCRE, and the regexp facilities in Perl,
Python, Java, JavaScript — are **backtracking** matchers. They walk the
pattern recursively and, at every alternation or quantifier, try one branch
and *back up* to try the next if it fails. That model is expressive (it can
support backreferences) but it has a fatal flaw: on adversarial patterns the
number of branch combinations explodes exponentially. The classic example,

```
(a+)+$
```

against a long string of `a`s followed by a non-matching character, makes a
backtracking engine try every way to partition the `a`s between the inner and
outer `+`. That is exponential in the input length: a few dozen characters can
hang the matcher for seconds, minutes, or effectively forever. This is the
**ReDoS** (regular-expression denial of service) vulnerability class.

RE2 takes the other classical path, the one Ken Thompson described in 1968.
A regular expression (in the formal sense — no backreferences) is equivalent
to a **nondeterministic finite automaton (NFA)**. Instead of exploring one
path at a time and backtracking, you simulate the NFA by tracking the *set*
of states the machine could be in simultaneously, and advance that whole set
by one input character at a time. There are at most *N* states (where *N* is
the size of the compiled program), so each input byte does at most *O(N)*
work, and the total run time is *O(N · M)* for input length *M* — **linear in
the input, with no backtracking and no exponential blow-up.** The same
`(a+)+$` that hangs a backtracker runs in linear time here. The engine is
*immune to ReDoS by construction.*

Backreferences (`\1`) fall outside regular-language matching and are
unsupported. The byte escape `\C` is also intentionally unsupported to
match Go's syntax; a single-byte match is not itself a non-regular feature.

The remaining subtlety is *which* match the NFA reports, since a regex can
match a given position in several ways. RE2 reproduces Perl's
**leftmost-first** (greedy, declaration-order) semantics, and optionally
POSIX **leftmost-longest**. Sections 3 and 4 describe how the simulation is
ordered to get this right.

---

## 2. The four-stage pipeline

A pattern goes through four transformations before it can match anything.
This mirrors Go's structure one-to-one.

```
  source text
      │
      ▼
  ┌─────────┐   AST (ast.Regexp tree)
  │  parse  │──────────────────────────────┐
  └─────────┘                               ▼
                                       ┌──────────┐   simplified AST
                                       │ simplify │──────────────────┐
                                       └──────────┘                  ▼
                                                               ┌──────────┐   Prog
                                                               │ compile  │──────────┐
                                                               └──────────┘          ▼
                                                                                ┌──────────┐
                                                                                │ execute  │──▶ match / submatches
                                                                                └──────────┘
```

1. **parse** — turn source text into an AST of `ast.Regexp` nodes (literals,
   alternations, concatenations, char classes, quantifiers, captures,
   assertions), honouring inline flags `(?imsU)`, escapes, `\Q…\E`, Perl and
   POSIX classes, and Go's full `\p{…}` category/script set. The AST shape
   matches Go's node for node: adjacent literals are coalesced into strings
   (`maybeConcat`), single-rune classes become literals, and alternations
   are factored (`factor`: common literal prefixes and leading classes are
   pulled out, runs of single runes become one class), so
   `perform|performer|period` compiles like `per(form(|er)|iod)`. The
   differential corpora record Go's instruction count per pattern and check
   the port compiles to exactly as many.
2. **simplify** — rewrite the AST into a smaller canonical form: counted
   repetitions are expanded (`x{2,4}` → `xx(x(x)?)?`), and idempotent nested
   quantifiers are collapsed (`(?:a+)+` → `a+`). This keeps the compiler simple
   and the program small.
3. **compile** — lower the simplified AST into a `Prog`: a flat array of NFA
   `Inst` instructions, using Go's *patch-list* trick (a fragment's
   not-yet-known exits are threaded into a linked list encoded in the unfilled
   `out`/`arg` fields, then patched in O(1) when the target is known).
4. **execute** — run the program over an input, producing the leftmost match
   and its submatch offsets. This stage owns the three engines of section 3.

The orchestration lives in `regexp.zig`'s `compileInternal`, which runs
parse → simplify → compile, then derives the start condition, the minimum
input length, the one-pass program (if the regexp qualifies), the literal
prefix and first-byte set, and whether the literal fast path applies,
packaging everything into a `Regexp` backed by a single arena.

### Parser resource limits

The parser enforces Go's limits exactly (`checkLimits` in `parse.zig`,
ported from `parse.go`), at the same call sites (`push`, `repeat`, and
twice inside `factor`) and in the same order, so the port accepts and
rejects the same patterns with the same error:

1. a **rune budget** (`maxRunes`, 128 MB of runes counted per push) →
   `TooLarge`;
2. a **program-size estimate** (`checkSize`: `maxSize` instructions,
   gated like Go's on the node count and the product of repeat counts) →
   `TooLarge`;
3. a **tree height** of 1000 (`checkHeight`; redundant `(?:…)` groups add
   no height, POSIX stacked repetitions do) → `NestingDepth`.

Go's size and height caches live in maps keyed by node, and Go recycles
nodes through a free list without clearing the size map, which is
observable (a recycled node can report a stale size). The port keeps the
same state in a parser-private `Node` wrapper around each `ast.Regexp`
(free-list link, size and height cache entries, owned rune capacity), so
the AST itself carries no parser bookkeeping. Go's `factor` and `collapse`
recurse once per factored prefix and rely on growable goroutine stacks;
here they run on an explicit heap frame stack in the same step order, so a
long common prefix cannot overflow the native stack. Character-class rune
lists grow in place with amortised capacity, like Go's `append`, so merging
thousands of single-rune alternatives stays linear. `src/limitstest.zig`
pins the boundaries (recorded from Go), and the curated corpus records
them in both syntaxes.

### Source-file → Go-source map

Each Zig file ports a specific Go source file (or pair of them). The header
comment of every file names its origin; the table collects them:

| Zig file (`src/`)   | Ports from Go                              | Role |
|---------------------|--------------------------------------------|------|
| `parse.zig`         | `regexp/syntax/parse.go`                   | Stage 1: source text → AST, resource limits |
| `ast.zig`           | `regexp/syntax/regexp.go` (the `Regexp`/`Op`/`Flags` types) | The AST node type and operators |
| `simplify.zig`      | `regexp/syntax/simplify.go`                | Stage 2: AST rewrite/canonicalization |
| `compile.zig`       | `regexp/syntax/compile.go`                 | Stage 3: AST → `Prog` (patch-list compiler), ASCII bitmaps |
| `prog.zig`          | `regexp/syntax/prog.go` (`Prog`/`Inst`/`InstOp`/`EmptyOp`, `Prefix`) | The compiled-program data structures |
| `onepass.zig`       | `regexp/onepass.go`                        | One-pass analysis + `Next` dispatch tables |
| `exec.zig`          | `regexp/exec.go`                           | Stage 4: input decoding, `Scratch`, Pike VM, one-pass runner, `Engine` and dispatch |
| `backtrack.zig`     | `regexp/backtrack.go`                      | Bitstate backtracker |
| `search.zig`        | (no Go counterpart; Go calls `bytes.Index`) | Literal-prefix search, first-byte `ByteSet` and SIMD `indexOfAnyByte` |
| `regexp.zig`        | `regexp/regexp.go`                         | Public API: compile / find / replace / split / submatch / `$`-expand; `findAt` ports Go's `find`, `Matches` Go 1.27's `matches` iterator |
| `unicode.zig`       | the subset of Go's `unicode` pkg the engine needs | `SimpleFold`, word-char test, `\p{…}` lookup (Go 1.27's `unicodeTable`) |
| `root.zig`          | (the package entry point / re-exports)     | Public namespace |

`src/` also holds the unit tests (`tests.zig`, `regressiontest.zig`,
`oomtest.zig`, `limitstest.zig`, `enginetest.zig`) and the generated data
files (`fold_table.zig`, `unicode_tables.zig`, section 6). The differential
drivers and their corpora live in `test/` (section 5), the benchmarks in
`bench/`; neither ships with the package.

---

## 3. The three execution engines

Go ships **three** matching engines, and so does this port. All three are
linear-time and produce identical results; the extra two exist purely for
speed on the shapes they specialise in.

Every search goes through one internal entry point, `Regexp.findAt`
(`regexp.zig`, Go's `(*Regexp).find`): it rejects inputs shorter than the
minimum match length, takes the literal fast path described below when it
applies, and otherwise calls `exec.executeReuse`, which chooses the engine
exactly as Go does:

```zig
pub fn executeReuse(scratch: *Scratch, e: *const Engine, input: Input, pos: usize, caps: []i64) !bool {
    const ninst = e.prog.insts.len;
    switch (e.mode) { // .auto outside tests
        .auto => if (e.onepass) |op| return doOnePass(op, e.cond, input, pos, caps),
        ...
    }
    if (ninst <= backtrack_.max_backtrack_prog and input.s.len < backtrack_.max_backtrack_vector / ninst) {
        return backtrack_.backtrack(scratch, e, input, pos, caps);
    }
    return pike(scratch, e, input, pos, caps);
}
```

`exec.Engine` bundles everything the engines read from a compiled regexp
(the program, the one-pass program, the start condition, leftmost-longest
mode and the scan acceleration data). Its `mode` field is a test hook: the
engine cross-check in `src/enginetest.zig` forces the Pike VM, the bitstate
engine or "no one-pass" on the same regexps and requires identical results,
so engine coverage does not depend on the dispatch heuristics. Engine
storage comes from a `Scratch`: the caller's (the `*Scratch` API and the
find-all loops) or a temporary one that the allocating API sets up only when
an engine actually runs.

**(1) One-pass** (`doOnePass` in `exec.zig`, built by `onepass.zig`). Some
*anchored* regexps can be proven at compile time to be unambiguous: at every
step there is exactly one way to proceed given the next input rune.
`(?i)`-folded literals, `\d+`, character classes — anchored with `\A…\z` —
qualify. `compileOnePass` analyses the program and, if it holds, builds a
per-instruction `Next` dispatch table. Matching is then a single
deterministic pass with no thread set and no backtracking. One-pass requires
anchoring because an unanchored search has inherent ambiguity about where
the match begins. Like Go, `onePassPrefix` also records the pc after the
literal prefix, so `doOnePass` checks the prefix with one comparison and
jumps past its instructions.

**(2) Bitstate backtracker** (`backtrack.zig`, porting `backtrack.go`). For a
**small program and small input** — `ninst ≤ 500` and
`input.len < 256·1024 / ninst` — a depth-first backtracking search is faster
than maintaining the Pike VM's thread set. A `(pc, pos)` **visited bitmap**
explores each program-counter / input-position pair at most once, which caps
total work and keeps the engine linear; the bitmap is shared across the start
positions of an unanchored scan. Greedy priority is preserved by the order
jobs are pushed onto the stack.

**(3) Pike VM** (`Machine` in `exec.zig`, porting `exec.go`). The general
engine: the Thompson NFA simulation *with submatch tracking*. It keeps two
thread queues as **sparse sets** (O(1) membership), each thread carrying its
own capture registers. `add` computes the epsilon-closure of a program
counter; `step` advances every thread by one rune into the next queue.

Go's `add` recurses on an alternation's `out` branch and on a capture's
body, which growable goroutine stacks absorb; a native stack would overflow
on large programs (e.g. 100k `a??` in a row). The port's `add` is
**iterative**: like RE2's `AddToThreadq`, it follows `out` at once and
pushes `arg` on an explicit stack (`Scratch.add_stack`, one frame per
instruction at most), and a capture leaves a frame that restores the slot
when its body is done — the same depth-first order, hence the same match
priority. For programs anchored with `\A` the start thread is added only at
position 0 (Go adds it everywhere and lets `\A` fail inside `add`; no result
changes).

### Scan acceleration

The engines never step the NFA through input that cannot start a match.

**Literal prefix** (`search.zig`). At compile time `Prog.prefix` extracts the
longest literal every match must begin with (Go's `Prog.Prefix`; like Go,
an unencodable rune such as a surrogate is written as U+FFFD and the walk
continues). When the Pike VM's thread queue is empty, or before each start
position of the bitstate engine, the search jumps to the prefix's next
occurrence with `prefixIndexAnchored`. That search anchors on the prefix's
*rarest* byte (a fixed byte-frequency rank, precomputed into
`Accel.prefix_anchor`), checks the needle's last and first bytes around each
hit before comparing the whole needle in 64-byte blocks, and charges every
hit a fixed cost plus the bytes compared. Once the charged work exceeds a
few units per haystack byte scanned it switches to Rabin-Karp, so the whole
search is O(n + m) even on periodic inputs built to defeat the anchor. (Go's
`bytes.Index` scans for the *first* byte and counts false starts instead.)

**First-byte set** (no Go counterpart). When there is no literal prefix (a
case-insensitive literal, `\d`, a small leading class, an alternation), the
compiler computes `first_bytes` (`regexp.zig:firstBytes`): the ASCII bytes a
match can start with, from the epsilon-closure of the program start (at most
16, else disabled). It is prepared once into a `search.ByteSet` (members,
a 128-bit membership bitmap, and pre-splatted vectors), and the Pike VM and
bitstate engines skip ahead with `search.indexOfAnyByte`, a portable
`@Vector` sweep that compiles to NEON on aarch64 and SSE2 on baseline x86_64,
with a scalar loop on targets without vector registers. The set must be a
*superset* of the true start bytes: every zero-width assertion is treated as
satisfiable, and the set is disabled when a case-fold orbit leaves ASCII
(`(?i)k` also matches U+212A). After a skip the Pike VM recomputes the
boundary flag, since `\b` can precede the first rune.

**Literal fast path** (no Go counterpart). When a regexp is exactly a
literal — complete prefix, no one-pass program, no capture groups, no start
condition, and no U+FFFD stand-in for an unencodable rune in the prefix
(`Regexp.literal`) — any search that needs at most the whole-match location
(`match`, `findIndex`, find-all, `replaceAll` with a template without `$`)
is answered by the prefix search alone, with no engine and no allocation.

### ASCII rune bitmap

Each general `.rune` instruction gets a compile-time 128-bit ASCII
membership bitmap (`compile.zig:asciiBitmap`), stored as a side table
`Prog.ascii` (one `u128` per pc). The Pike VM and bitstate engines call
`Prog.matchRuneAt`, which answers `r < 0x80` with one bit test instead of a
range scan, binary search or case-fold orbit walk. It is a side table on
purpose: putting it into `Inst` grew the instruction past 32 bytes and
slowed the cache-sensitive bitstate engine by about 25%. **Keep `Inst` at
32 bytes.** A unit test requires the bitmap to agree with
`prog.matchRunePos` for every ASCII rune.

---

## 4. Key invariants

The engines lean on a handful of representation invariants. Break any of them
and results diverge from Go.

**Greedy/non-greedy is encoded by the ORDER of an `alt`'s two successors.**
An `.alt` instruction has two epsilon successors, `out` and `arg`. The
compiler emits them so that `out` is the *higher-priority* branch. For a
greedy `x*`, the "take another `x`" branch is `out`; for a non-greedy `x*?`,
the "stop now" branch is `out`. There is no separate "greedy" flag — greediness
*is* the ordering.

**Leftmost-first priority comes from the Pike VM's epsilon-closure order.**
`Machine.add` follows `i.out` *before* `i.arg` for `.alt`/`.alt_match`
(`arg` waits on the explicit stack), so higher-priority threads are inserted
into the queue *first*. In first-match (non-`longest`) mode, when a thread
reaches `.match`, `step` frees all lower-priority threads behind it — that is
the moment leftmost-first semantics are realized. Setting `longest = true`
(POSIX) keeps exploring and prefers the *longest* match instead.

**Char-class rune lists are sorted, merged `(lo, hi)` pairs.** A `.rune`
instruction's `runes` field is a flat array of inclusive range pairs
`[lo0, hi0, lo1, hi1, …]`, kept sorted and non-overlapping. `matchRunePos`
relies on this: it linear-scans small classes and **binary-searches** larger
ones. The returned pair index also feeds the one-pass `Next` dispatch table.

**Submatch results are padded to `2·(numSubexp+1)`.** Every submatch result
has a `[start, end]` pair per group (group 0 is the whole match, `-1` for
groups that did not participate). `padLen()` in `regexp.zig` computes it, and
it can exceed the program's `num_cap` when a capturing group is compiled
away (e.g. `(a){0}`) — the extra trailing slots stay `-1`, exactly like Go's
`pad`.

**Range arithmetic near 0 and U+10FFFF uses a wider integer** (`u21`
overflows on `hi + 1`).

---

## 5. Differential testing — the project's backbone

The port's central claim is *result-identical to Go*, and that claim is
**checked mechanically**, not asserted:

1. **Go generators record golden results.** The Go module in `tools/`
   (`tools/cmd/gencases`, `genfuzz`, `genlongest`, `genbytes`, sharing
   `tools/internal/corpus`) runs patterns and inputs through the *real* Go
   `regexp` package, pinned to Go 1.27.1, and writes one JSON object per
   case into a committed corpus in `test/data/`. Every case records the
   compile outcome (Go's `syntax.ErrorCode` text on failure), `ni` (the
   instruction count of `syntax.Compile(syntax.Parse(p, flags).Simplify())`
   for the flags the mode compiles with), `LiteralPrefix()`, and
   `FindStringSubmatchIndex`; the random and byte-level corpora also record
   `FindAllStringSubmatchIndex`, `ReplaceAllString` and `Split` with a limit
   and template. Byte strings are JSON strings when valid UTF-8 and byte
   arrays otherwise, so malformed UTF-8 survives. Each corpus ends with a
   `{"count":N}` trailer, and `test/data/MANIFEST.json` records the counts
   with the Go and Unicode versions.
2. **Zig drivers replay.** The drivers in `test/` (`difftest.zig`,
   `fuzztest.zig`, `longesttest.zig`, `bytestest.zig`, all running
   `difftest_common.zig`) `@embedFile` a corpus, compile each pattern with
   this engine in the recorded mode (`compile`, `compile` + `setLongest`, or
   `compilePOSIX`), and require: the same compile outcome and error code
   (an `OutOfMemory` is a failure, never "the same as Go"); the same `ni`,
   which is mandatory, so the AST and program shape are Go's and not just
   the results; the same literal prefix and complete flag; the same leftmost
   match through `findSubmatchIndex`, `match`, `findIndex` and their
   `Scratch` variants; and, where recorded, the same `findAllSubmatchIndex`,
   `findAllIndex`, `matchesScratch` iteration, `replaceAllString` and
   `split`. A missing trailer or a count that disagrees with the manifest
   fails the run.
3. **Under a leak-checking allocator.** Every case runs on
   `std.testing.allocator`, so any byte leaked across the suite fails it.

| Corpus          | Driver            | Generator              | What it exercises |
|-----------------|-------------------|------------------------|-------------------|
| `cases.jsonl`   | `difftest.zig`    | `tools/cmd/gencases`   | Curated patterns × curated inputs; Go's `invalidRegexps` / `onlyPerl` / `onlyPOSIX` parser lists and `badRe` in both syntaxes; the parser's size, height and factor-recursion boundaries |
| `fuzz.jsonl`    | `fuzztest.zig`    | `tools/cmd/genfuzz`    | Random Perl-syntax patterns, an alternation stream for `factor`, a stream on inputs with NULs and malformed UTF-8, and patterns with spliced-in syntax errors; find-all family |
| `longest.jsonl` | `longesttest.zig` | `tools/cmd/genlongest` | Random patterns under `Longest()`, and random POSIX ERE patterns through `CompilePOSIX`; find-all family |
| `bytes.jsonl`   | `bytestest.zig`   | `tools/cmd/genbytes`   | Malformed UTF-8 and NULs in Perl / `Longest()` / `CompilePOSIX` modes, bounded `FindAll`/`Split`, `$` templates, depth limits, surrogates in literal prefixes |

`zig build difftest` runs all four (ReleaseSafe); `zig build
difftest-cases|fuzz|longest|bytes` runs one. A mismatch prints the pattern,
mode, input and Go's recorded result, grouped by which check disagreed.

The benchmark workloads (`bench/data/`, from `tools/cmd/genbench`) drive
`bench/bench.zig` and `bench/bench_scratch.zig` and their Go counterparts
(`tools/cmd/benchgo`, `benchscratchgo`); `tools/bench.sh` runs both and
regenerates the tables in `BENCHMARKS.md`.

---

## 6. Generated data — never hand-edited

These files are generated from Go and must never be edited by hand:

- **`src/fold_table.zig`** — the case-folding table, generated by
  `tools/cmd/genfold` from Go's `unicode.SimpleFold`, covering *all of
  Unicode*. `unicode.zig`'s `simpleFold` is a lookup over it.
- **`src/unicode_tables.zig`** — the `\p{…}` class tables: every general
  category and script in Go's `unicode` package, each with its case-fold
  companion (`unicode.FoldCategory` / `FoldScript`, merged under `(?i)`
  exactly as `regexp/syntax` does) and `unicode.CategoryAliases`, generated by
  `tools/cmd/genuni`. Names are stored with their canonical form so lookups
  ignore case, `_`, `-` and spaces like Go 1.27.
- **`test/data/*`** and **`bench/data/*`** — the differential corpora with
  their manifest, and the benchmark workloads.

All are regenerated by:

```sh
tools/regen.sh
```

which forces the reference toolchain (`GOTOOLCHAIN=go1.27.1`, checked with
`go version`), builds the generators, writes everything into a temporary
directory, and moves it into place only when every generator succeeded.
Regeneration is deterministic: running it twice leaves the tree unchanged.
To change generated data, change the generator (or the pinned Go version)
and re-run `regen.sh`.

---

## Credits

The RE2 design and the Go `regexp` implementation are the work of Russ Cox and
the Go authors; this project is a derivative port of their BSD-3-Clause code,
and its Unicode tables derive from the Unicode Character Database (see
`NOTICE`). zoptia0regex is licensed Apache-2.0 and is not affiliated with Go
or Google.

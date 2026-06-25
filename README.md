# zoptia0regex

A faithful Zig port of Go's standard-library `regexp` package — the same RE2
design (Thompson NFA / Pike VM), the same **leftmost-first** match semantics,
and the same `Find`/`Replace`/`Split`/submatch API surface.

The implementation is validated by **differential testing against the actual Go
`regexp` package**: tens of thousands of (pattern, input) pairs are run through
both engines and the results are required to be byte-for-byte identical (see
[Validation](#validation)). It is also **benchmarked head-to-head against Go** —
~11% faster on average (all three of Go's engines are ported) and ~1.7× faster
to compile (see [BENCHMARKS.md](BENCHMARKS.md)).

```
$ zig build demo -- '(\w+)@(\w+)\.(\w+)' 'contact john@example.com today'
pattern : /(\w+)@(\w+)\.(\w+)/
input   : "contact john@example.com today"
match   : true
find    : [8,24) = "john@example.com"
  group 0: "john@example.com"
  group 1: "john"
  group 2: "example"
  group 3: "com"
```

---

## How Go's `regexp` works (and how this port mirrors it)

Go's `regexp` is a descendant of Russ Cox's RE2. Unlike PCRE-style backtracking
engines, it guarantees **linear-time** matching (no catastrophic backtracking)
by simulating a non-deterministic finite automaton. The pipeline has four
stages, and this port keeps the same stages in the same files:

| Stage | Go source | This port | What it does |
|-------|-----------|-----------|--------------|
| 1. Parse | `syntax/parse.go` | `src/parse.zig` | Pattern string → AST, via a stack machine. |
| 2. Simplify | `syntax/simplify.go` | `src/simplify.zig` | Rewrite counted repetition `x{n,m}` into `*`/`+`/`?`/concat. |
| 3. Compile | `syntax/compile.go` + `prog.go` | `src/compile.zig` + `src/prog.zig` | AST → `Prog`, a flat list of NFA instructions. |
| 4. Execute | `exec.go` + `backtrack.go` + `onepass.go` | `src/exec.zig` + `src/onepass.zig` | Pike VM + bitstate backtracker + one-pass; submatch tracking, prefix accel. |
| Public API | `regexp.go` | `src/regexp.zig` | `compile`, `find*`, `replace*`, `split`, `expand`. |
| Unicode | `unicode` pkg | `src/unicode.zig` + generated tables | `SimpleFold`, `\b` word test, `\p{...}` classes. |
| AST node | `syntax/regexp.go` | `src/ast.zig` | `Regexp` node, `Op` enum, `Flags`. |

### 1. Parsing (`parse.zig`)

A stack of partial `Regexp` nodes. Reading left to right, each literal/class is
pushed; `|` and `(` are pushed as pseudo-ops; `concat()`/`alternate()` collapse
the stack above the nearest pseudo-op when a group closes or the pattern ends.
Postfix quantifiers (`* + ? {n,m}`) rewrite the top-of-stack node. Character
classes are built as sorted, merged `(lo,hi)` range-pair lists (`appendRange`,
`cleanClass`, `negateClass`), exactly like Go.

### 2. Simplify (`simplify.zig`)

Counted repetition is the only thing the executor cannot handle directly, so
`x{2,4}` becomes `xx(x(x)?)?` and `x{2,}` becomes `xx+`, matching Go's
expansion (which is why `(x){1,2}` captures group 1 from the *last* copy, just
as in Go).

### 3. Compilation (`compile.zig` / `prog.zig`)

The AST is compiled to a `Prog`: a flat array of instructions
(`alt`, `capture`, `empty_width`, `rune`/`rune1`/`rune_any`, `match`, `fail`,
`nop`). Greedy vs non-greedy is encoded purely by the **order** of an `alt`
instruction's two successors. The classic patch-list trick threads
not-yet-known jump targets through the unused `out`/`arg` fields so fragments
can be wired together in O(1).

### 4. Execution — the Pike VM (`exec.zig`)

The single execution engine. It keeps a set of NFA "threads" (each a program
counter plus a capture array) and advances them one input rune at a time using
two sparse-set work queues. Priority order is preserved by the epsilon-closure
(`add`) so that, in first-match mode, the moment a `match` instruction is
reached all lower-priority threads are discarded — giving **leftmost-first**
(Perl/RE2) semantics without backtracking. Setting `setLongest()` switches to
**POSIX leftmost-longest**.

> The port ships **all three of Go's engines**, dispatched the same way: a
> **one-pass** engine (`onepass.zig`) for qualifying anchored regexps (the
> fastest path — a single deterministic pass), a **bitstate backtracker**
> (`exec.zig`) for small programs/inputs (a (pc, pos)-visited bitmap keeps it
> linear-time), and the **Pike VM** for everything else — all with
> **literal-prefix acceleration** (a vectorized substring scan). The result is
> on average faster than Go (see [BENCHMARKS.md](BENCHMARKS.md)).

---

## Supported features

- **Literals & concatenation**, UTF-8 throughout (`u21` code points).
- **Alternation** `a|b|c`.
- **Character classes** `[...]`, `[^...]`, ranges `[a-z]`, with:
  - Perl classes `\d \D \w \W \s \S`,
  - POSIX classes `[[:alpha:]] [[:^digit:]] …`,
  - Unicode classes `\pL`, `\p{Greek}`, `\P{Nd}`, `\p{^Han}` (curated subset).
- **Any char** `.` (and `(?s)` dot-matches-newline).
- **Anchors** `^ $ \A \z` and word boundaries `\b \B` (and `(?m)` multi-line).
- **Quantifiers** `* + ? {n} {n,} {n,m}`, each greedy or non-greedy (`*?` etc.).
- **Groups**: capturing `(...)`, non-capturing `(?:...)`, named `(?P<name>...)`
  and `(?<name>...)`.
- **Flags**, global and scoped: `(?i)` fold case, `(?m)` multi-line,
  `(?s)` dot-all, `(?U)` swap greediness; `(?flags:...)`, `(?-flags:...)`.
- **Escapes**: `\n \t \r \f \v \a`, octal `\123`, hex `\x41` and `\x{1F600}`,
  metacharacter escapes, and `\Q...\E` literal spans.
- **Case folding** (`(?i)`) using a table generated from Go's
  `unicode.SimpleFold` — correct across **all** of Unicode, not just ASCII.
- **Two match modes**: leftmost-first (`compile`) and POSIX leftmost-longest
  (`compilePOSIX`).
- Full **API**: match, find, find-all, submatches, replace (with `$1`/`${name}`
  expansion), split, and `quoteMeta`.

---

## API

```zig
const regex = @import("regex"); // the module exported by build.zig

var re = try regex.compile(allocator, "(\\w+)=(\\w+)");
defer re.deinit();

// Boolean
const ok = try re.match(allocator, "key=value");

// Leftmost match
if (try re.findIndex(allocator, "a=b c=d")) |m| {        // ?regex.Match{start,end}
    _ = m;
}
const text = try re.find(allocator, "a=b c=d");          // ?[]const u8 (slice of input)

// Submatches (slice of input; null for non-participating groups). Caller frees.
if (try re.findSubmatch(allocator, "a=b")) |subs| {
    defer allocator.free(subs);                          // subs: []?[]const u8
}

// All matches (n < 0 = all). Caller frees the returned slice.
if (try re.findAll(allocator, "a=1 b=2", -1)) |all| {
    defer allocator.free(all);                           // all: [][]const u8
}

// Replace with $-expansion ($0 = whole match, $1.., ${name}, $$ = literal $)
const out = try re.replaceAllString(allocator, "a=b c=d", "$2:$1");
defer allocator.free(out);                               // "b:a d:c"

// Split. Caller frees the outer slice.
if (try re.split(allocator, "a,b,,c", -1)) |parts| {
    defer allocator.free(parts);
}

// Introspection (no allocation)
_ = re.numSubexp();
_ = re.subexpIndex("name");        // ?usize
_ = re.literalPrefix();            // { prefix, complete }
```

Also available: `compilePOSIX`, `mustCompile`, `matchString`,
`findSubmatchIndex`, `findAllIndex`, `findAllSubmatchIndex`
(+ `freeAllSubmatchIndex`), `replaceAllLiteralString`, `replaceAllStringFunc`,
`expand`, and `quoteMeta`.

### Memory model

A compiled `Regexp` owns a heap-allocated **arena** holding its program,
capture names and literal prefix; `deinit()` frees all of it. Every execution
and result-producing method takes an `allocator` used for transient VM scratch
and (where it returns owned memory) the result, which the caller frees. The
engine is allocation-balanced — the differential test runs under
`std.testing.allocator` and reports **zero leaks**.

---

## Scope — differences from Go

Match results are identical to Go for the supported feature set. The
differences are all either **deferred optimizations** (same observable results)
or **clearly-scoped data limits**:

| Area | Status |
|------|--------|
| Bitstate backtracker | **Implemented** — Go's small-program/small-input engine, dispatched the same way; closes the nested-quantifier gap. |
| One-pass engine | **Implemented** — Go's fastest engine for qualifying anchored regexps; makes this port faster than Go on `\A…\z` validation patterns. See [BENCHMARKS.md](BENCHMARKS.md). |
| Alternation prefix `factor()` | Not ported. A pure AST optimization; does not change the matched language or priority. |
| Literal-prefix search acceleration | **Implemented** (vectorized first-byte scan + verify); closes the literal-search gap with Go. See [BENCHMARKS.md](BENCHMARKS.md). |
| `\p{...}` script/category set | A **curated subset** (common general categories `L,N,P,…` and major scripts: Latin, Greek, Cyrillic, Han, Hiragana, Katakana, Hangul, Arabic, Hebrew, Thai, Devanagari, Armenian, Georgian, Common). Unknown names return `error.InvalidCharRange`. |
| `\p{...}` under `(?i)` | Uses the base table only (no case-fold table merge), equivalent to Go's behavior when a class has no fold table. |
| `io.RuneReader` streaming input | Not ported; inputs are `[]const u8` (covers Go's string and `[]byte`). |
| Backreferences, `\C` (any byte) | Unsupported — **same as Go** (RE2 does not support these). |

These are the same scope choices an independent design review converged on; the
core matcher is faithful.

---

## Validation

The port is checked against the **real Go `regexp` package** as a golden
reference. Go programs in `tools/` emit, for each (pattern, input) pair, the
results of `FindStringSubmatchIndex`, `FindAllStringSubmatchIndex`,
`ReplaceAllString`, and `Split`; the Zig differential tests recompute all four
and assert byte-for-byte equality.

- `src/cases.jsonl` — a **curated** corpus (~5.6k cases) exercising every
  feature, generated by `tools/gencases.go`.
- `src/fuzz.jsonl` — a **randomized** corpus (9k cases) from a grammar-driven
  random regex generator (`tools/genfuzz.go`), with nested groups, quantifiers,
  anchors, flags and Unicode classes.

Current status: **all differential cases pass, zero mismatches, zero leaks**,
across `findSubmatchIndex`, `findAllSubmatchIndex`, `replaceAllString` and
`split`, plus a hand-written behaviour suite in `src/tests.zig`.

The Unicode `SimpleFold` table (`src/fold_table.zig`) and the `\p{...}` class
tables (`src/unicode_tables.zig`) are generated directly from Go's `unicode`
package, so `(?i)` folding matches Go exactly across all of Unicode.

---

## Building & testing

Requires Zig 0.16. (A Go toolchain is only needed to *regenerate* the tables and
corpora.)

```sh
zig build test                 # fast unit + behaviour tests
zig build difftest             # differential tests vs Go's output (curated + fuzz)
zig build demo -- '<pat>' '<input>'

tools/regen.sh                 # regenerate Unicode tables + corpora from Go
```

Use it as a dependency by importing the `regex` module exposed in `build.zig`,
or copy `src/` into your project and `@import("regexp.zig")`.

---

## Layout

```
src/
  ast.zig            AST node, Op enum, Flags
  parse.zig          pattern string -> AST (stack machine, classes, escapes)
  simplify.zig       counted-repetition elimination
  prog.zig           Inst / Prog / EmptyOp, MatchRune
  compile.zig        AST -> Prog (patch-list compiler)
  exec.zig           Pike VM + bitstate backtracker, prefix accel, dispatch
  onepass.zig        one-pass engine (analysis + dispatch tables)
  regexp.zig         public API: find / replace / split / expand
  unicode.zig        SimpleFold, word-char test, \p{} lookup
  fold_table.zig     generated: unicode.SimpleFold (all of Unicode)
  unicode_tables.zig generated: \p{} category/script subset
  root.zig           library root + test aggregator
  demo.zig           CLI demo
  tests.zig          behaviour tests
  difftest.zig       differential test (curated corpus)
  fuzztest.zig       differential test (random corpus)
tools/
  gen*.go            Go generators (tables + corpora)
  regen.sh           regenerate everything from the Go toolchain
```

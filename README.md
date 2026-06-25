# zoptia0regex

[![CI](https://github.com/zoptia/zoptia0regex/actions/workflows/ci.yml/badge.svg)](https://github.com/zoptia/zoptia0regex/actions/workflows/ci.yml)
![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d)
![License](https://img.shields.io/badge/License-Apache_2.0-blue)

A faithful Zig port of Go's standard-library `regexp` package — the same RE2
design (Thompson NFA / Pike VM), the same **leftmost-first** match semantics,
and the same `Find`/`Replace`/`Split`/submatch API surface.

- ✅ **Linear-time** matching — no catastrophic backtracking, ever.
- ✅ **Result-identical to Go**, proven by ~30,000 differential test cases.
- ✅ **Faster than Go on average** (~11%) and ~1.7× faster to compile — all three
  of Go's engines are ported (one-pass, bitstate, Pike VM). See
  [BENCHMARKS.md](BENCHMARKS.md).
- ✅ **Zero allocations leaked** (checked under `std.testing.allocator`).

> **Status:** v0.1.0, early but extensively validated. Not affiliated with Go or
> Google; see [Acknowledgements](#acknowledgements--license).

```console
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

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [API](#api)
- [Supported syntax](#supported-syntax)
- [How it works](#how-it-works)
- [Scope — differences from Go](#scope--differences-from-go)
- [Validation](#validation)
- [Benchmarks](#benchmarks)
- [Build & test](#build--test)
- [Project layout](#project-layout)
- [Contributing](#contributing)
- [Acknowledgements & License](#acknowledgements--license)

## Install

Requires **Zig 0.16**. Add it to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/zoptia/zoptia0regex
```

Then wire the `regex` module into your `build.zig`:

```zig
const regex_dep = b.dependency("zoptia0regex", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("regex", regex_dep.module("regex"));
```

and import it:

```zig
const regex = @import("regex");
```

(Or just drop `src/` into your tree and `@import("regexp.zig")`.)

## Quick start

```zig
const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var re = try regex.compile(gpa, "(\\w+)@(\\w+)\\.(\\w+)");
    defer re.deinit();

    if (try re.findSubmatch(gpa, "ping me@example.com")) |subs| {
        defer gpa.free(subs);
        std.debug.print("user={s} host={s} tld={s}\n", .{
            subs[1].?, subs[2].?, subs[3].?,
        }); // user=me host=example tld=com
    }
}
```

## API

```zig
const regex = @import("regex");

var re = try regex.compile(allocator, "(\\w+)=(\\w+)");
defer re.deinit();

// Boolean
const ok = try re.match(allocator, "key=value");

// Leftmost match
if (try re.findIndex(allocator, "a=b c=d")) |m| { _ = m; }   // ?regex.Match{start,end}
const text = try re.find(allocator, "a=b c=d");              // ?[]const u8 (slice of input)

// Submatches (slices of input; null for non-participating groups). Caller frees.
if (try re.findSubmatch(allocator, "a=b")) |subs| {
    defer allocator.free(subs);                              // subs: []?[]const u8
}

// All matches (n < 0 = all). Caller frees the returned slice.
if (try re.findAll(allocator, "a=1 b=2", -1)) |all| {
    defer allocator.free(all);                               // all: [][]const u8
}

// Replace with $-expansion ($0 = whole match, $1.., ${name}, $$ = literal $)
const out = try re.replaceAllString(allocator, "a=b c=d", "$2:$1");
defer allocator.free(out);                                   // "b:a d:c"

// Split. Caller frees the outer slice.
if (try re.split(allocator, "a,b,,c", -1)) |parts| {
    defer allocator.free(parts);
}

// Introspection (no allocation)
_ = re.numSubexp();
_ = re.subexpIndex("name");        // ?usize
_ = re.literalPrefix();            // .{ prefix, complete }
```

Also available: `compilePOSIX` (leftmost-longest), `mustCompile`, `matchString`,
`findSubmatchIndex`, `findAllIndex`, `findAllSubmatchIndex`
(+ `freeAllSubmatchIndex`), `replaceAllLiteralString`, `replaceAllStringFunc`,
`expand`, and `quoteMeta`.

**Memory model.** A compiled `Regexp` owns a heap-allocated **arena** holding
its program, capture names and literal prefix; `deinit()` frees it. Every
execution / result-producing method takes an `allocator` used for transient
scratch and (where it returns owned memory) the result, which the caller frees.

## Supported syntax

- **Literals & concatenation**, UTF-8 throughout (`u21` code points).
- **Alternation** `a|b|c`.
- **Character classes** `[...]`, `[^...]`, ranges `[a-z]`, with Perl classes
  `\d \D \w \W \s \S`, POSIX classes `[[:alpha:]] [[:^digit:]] …`, and Unicode
  classes `\pL`, `\p{Greek}`, `\P{Nd}`, `\p{^Han}` (curated subset).
- **Any char** `.` (and `(?s)` dot-matches-newline).
- **Anchors** `^ $ \A \z` and word boundaries `\b \B` (and `(?m)` multi-line).
- **Quantifiers** `* + ? {n} {n,} {n,m}`, each greedy or non-greedy (`*?` etc.).
- **Groups**: capturing `(...)`, non-capturing `(?:...)`, named `(?P<name>...)`
  / `(?<name>...)`.
- **Flags**, global and scoped: `(?i)` fold case, `(?m)` multi-line, `(?s)`
  dot-all, `(?U)` swap greediness; `(?flags:...)`, `(?-flags:...)`.
- **Escapes**: `\n \t \r \f \v \a`, octal `\123`, hex `\x41` / `\x{1F600}`,
  metacharacter escapes, `\Q...\E` literal spans.
- **Case folding** (`(?i)`) using a table generated from Go's
  `unicode.SimpleFold` — correct across **all** of Unicode, not just ASCII.
- **Two match modes**: leftmost-first (`compile`) and POSIX leftmost-longest
  (`compilePOSIX` / `setLongest`).

The accepted syntax is [Go's `regexp/syntax`](https://pkg.go.dev/regexp/syntax).

## How it works

Go's `regexp` is a descendant of Russ Cox's RE2. Unlike PCRE-style backtracking
engines, it guarantees **linear-time** matching by simulating an NFA. The
pipeline has four stages, and this port keeps the same stages in the same files:

| Stage | Go source | This port | What it does |
|-------|-----------|-----------|--------------|
| 1. Parse | `syntax/parse.go` | `src/parse.zig` | Pattern string → AST, via a stack machine. |
| 2. Simplify | `syntax/simplify.go` | `src/simplify.zig` | Rewrite `x{n,m}` into `*`/`+`/`?`/concat. |
| 3. Compile | `syntax/compile.go` + `prog.go` | `src/compile.zig` + `src/prog.zig` | AST → `Prog`, a flat NFA instruction list. |
| 4. Execute | `exec.go` + `backtrack.go` + `onepass.go` | `src/exec.zig` + `src/onepass.zig` | Pike VM + bitstate + one-pass; submatches, prefix accel. |
| Public API | `regexp.go` | `src/regexp.zig` | `compile`, `find*`, `replace*`, `split`, `expand`. |
| Unicode | `unicode` pkg | `src/unicode.zig` + generated tables | `SimpleFold`, `\b` word test, `\p{...}` classes. |

**Execution** ships all three of Go's engines, dispatched the same way: a
**one-pass** engine (`onepass.zig`) for qualifying anchored regexps (a single
deterministic pass), a **bitstate backtracker** (`exec.zig`) for small
programs/inputs (a `(pc, pos)`-visited bitmap keeps it linear-time), and the
**Pike VM** for everything else — all with **literal-prefix acceleration** (a
vectorized substring scan). Greedy vs non-greedy is encoded purely by the
**order** of an `alt` instruction's two successors, and leftmost-first priority
falls out of the Pike VM's epsilon-closure order — no backtracking.

## Scope — differences from Go

Match results are identical to Go for the supported feature set. The remaining
differences are clearly-scoped data limits, never semantic:

| Area | Status |
|------|--------|
| One-pass / bitstate / Pike VM engines | **All implemented**, dispatched as Go does. |
| Literal-prefix search acceleration | **Implemented** (vectorized first-byte scan + verify). |
| Alternation prefix `factor()` | Not ported — a pure AST optimization; never changes results or priority. |
| `\p{...}` script/category set | A **curated subset** (common general categories `L,N,P,…` and major scripts: Latin, Greek, Cyrillic, Han, Hiragana, Katakana, Hangul, Arabic, Hebrew, Thai, Devanagari, Armenian, Georgian, Common). Unknown names → `error.InvalidCharRange`. |
| `\p{...}` under `(?i)` | Base table only (no fold-table merge), like Go when a class has no fold table. |
| `io.RuneReader` streaming input | Not ported; inputs are `[]const u8` (covers Go's `string` and `[]byte`). |
| Backreferences, `\C` (any byte) | Unsupported — **same as Go** (RE2 does not support these). |

## Validation

The port is checked against the **real Go `regexp` package** as a golden
reference. Go programs in `tools/` emit, for each (pattern, input) pair, the
results of `FindStringSubmatchIndex`, `FindAllStringSubmatchIndex`,
`ReplaceAllString`, and `Split`; the Zig differential tests recompute all four
and assert byte-for-byte equality (and zero leaks):

- `src/cases.jsonl` — a **curated** corpus (~5.9k cases) covering every feature.
- `src/fuzz.jsonl` — a **randomized** corpus (9k cases) from a grammar-driven
  generator: nested groups, quantifiers, anchors, flags, Unicode classes.
- `src/longest.jsonl` — a **leftmost-longest** corpus (15k cases) for POSIX mode.

≈ **30,000 cases, zero mismatches, zero leaks**, across all engines (the
anchored cases exercise one-pass, the small ones bitstate). The Unicode
`SimpleFold` and `\p{...}` tables are generated directly from Go's `unicode`
package, so folding matches Go exactly across all of Unicode.

```sh
zig build difftest    # runs all three corpora (no Go toolchain needed)
```

## Benchmarks

Head-to-head against Go on a shared corpus; **Zig is ~11% faster on average**
(geomean 0.887×) and ~1.7× faster to compile. Anchored "validation" patterns
(one-pass) are up to **1.7× faster** than Go. Full methodology, table and
analysis in **[BENCHMARKS.md](BENCHMARKS.md)**.

```sh
zig build bench                      # Zig results (ReleaseFast)
( cd tools && go run benchgo.go )    # Go results
```

## Build & test

Requires Zig 0.16. (A Go toolchain is only needed to *regenerate* the tables and
corpora, not to build or test.)

```sh
zig build test                    # unit + behaviour tests
zig build difftest                # differential tests vs Go's recorded output
zig build bench                   # benchmark (ReleaseFast)
zig build demo -- '<pat>' '<in>'  # CLI demo

tools/regen.sh                    # regenerate Unicode tables + corpora from Go
```

## Project layout

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
  tests.zig          behaviour tests
  difftest / fuzztest / longesttest.zig   differential tests
  bench.zig, demo.zig                      benchmark + CLI demo
tools/
  gen*.go            Go generators (tables + corpora)
  benchgo.go         Go-side benchmark harness
  regen.sh           regenerate everything from the Go toolchain
```

## Contributing

Issues and PRs welcome. Please run `zig build test` and `zig build difftest`
before submitting; `zig fmt` must be clean. See [CONTRIBUTING.md](CONTRIBUTING.md)
for the testing philosophy (every change is validated against Go's actual
output) and how to regenerate the tables/corpora.

## Acknowledgements & License

This project is a faithful **port of Go's `regexp` / `regexp/syntax` packages**;
its algorithms, instruction set and engine designs are derived from that work,
and the Unicode tables are generated from Go's `unicode` package. Enormous
credit to Russ Cox and the Go authors. The Go source is BSD-3-Clause
(© 2009 The Go Authors); the required notice is reproduced in [NOTICE](NOTICE).
This project is **not affiliated with Go or Google**.

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE).

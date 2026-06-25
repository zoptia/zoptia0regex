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

The price of this guarantee is the one feature it forgets: **backreferences**
(`\1`) and `\C` are not regular and cannot be simulated this way, so — exactly
like Go and RE2 — zoptia0regex does not support them. Everything else in Go's
syntax is supported (see the README for the full grammar).

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
   POSIX classes, and the curated `\p{…}` subset.
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
parse → simplify → compile, then derives the start condition, literal prefix,
and (if the regexp qualifies) the one-pass program, packaging everything into
a `Regexp` backed by a single arena.

### Source-file → Go-source map

Each Zig file ports a specific Go source file (or pair of them). The header
comment of every file names its origin; the table collects them:

| Zig file (`src/`)        | Ports from Go                              | Role |
|--------------------------|--------------------------------------------|------|
| `parse.zig`              | `regexp/syntax/parse.go`                   | Stage 1: source text → AST |
| `ast.zig`                | `regexp/syntax/regexp.go` (the `Regexp`/`Op`/`Flags` types) | The AST node type and operators |
| `simplify.zig`           | `regexp/syntax/simplify.go`                | Stage 2: AST rewrite/canonicalization |
| `compile.zig`            | `regexp/syntax/compile.go`                 | Stage 3: AST → `Prog` (patch-list compiler) |
| `prog.zig`               | `regexp/syntax/prog.go` (`Prog`/`Inst`/`InstOp`/`EmptyOp`) | The compiled-program data structures |
| `onepass.zig`            | `regexp/onepass.go`                        | One-pass analysis + `Next` dispatch tables |
| `exec.zig`               | `regexp/exec.go` + `regexp/backtrack.go`   | Stage 4: Pike VM, bitstate backtracker, one-pass runner, dispatch |
| `regexp.zig`             | `regexp/regexp.go`                         | Public API: compile / find / replace / split / submatch / `$`-expand |
| `unicode.zig`            | the subset of Go's `unicode` pkg the engine needs | `SimpleFold`, word-char test, `\p{…}` lookup |
| `root.zig`               | (the package entry point / re-exports)     | Public namespace |

Generated data files (`fold_table.zig`, `unicode_tables.zig`) are covered in
section 6; the `*.jsonl` corpora and `*test.zig` harnesses in section 5.

---

## 3. The three execution engines

Go ships **three** matching engines, and so does this port. All three are
linear-time and produce identical results; the extra two exist purely for
speed on the shapes they specialise in. `exec.zig`'s `execute()` is the
dispatcher, and it chooses exactly as Go does:

```zig
pub fn execute(allocator, p, op, longest, cond, prefix, input, pos, caps) !bool {
    // 1. one-pass, if the regexp qualified at compile time
    if (op) |onep| return doOnePass(onep, cond, input, pos, caps);

    // 2. bitstate backtracker, for small program AND small input
    const ninst = p.insts.len;
    if (ninst <= max_backtrack_prog and ninst > 0 and
        input.s.len < max_backtrack_vector / ninst)
    {
        return backtrack(allocator, p, longest, cond, prefix, input, pos, caps);
    }

    // 3. Pike VM, the general fallback
    var m = try Machine.init(allocator, p, longest, cond, prefix, caps.len);
    defer m.deinit();
    if (!try m.run(input, pos)) return false;
    @memcpy(caps, m.matchcap);
    return true;
}
```

**(1) One-pass** (`doOnePass`, built by `onepass.zig`). Some *anchored*
regexps can be proven at compile time to be unambiguous: at every step there
is exactly one way to proceed given the next input rune. `(?i)`-folded
literals, `\d+`, character classes — anchored with `\A…\z` — qualify.
`compileOnePass` analyses the program and, if it holds, builds a per-instruction
`Next` dispatch table; otherwise it returns null and the field stays empty.
When present, matching is a single deterministic linear pass with *no thread
set, no backtracking, no allocation* — by far the fastest engine. This is
where the engine most outruns Go (anchored "validation" patterns like
`\A[a-z]+\z` and `\A\d+\z`). One-pass requires anchoring because an unanchored
search has inherent ambiguity about where the match begins.

**(2) Bitstate backtracker** (`backtrack` / `BitState` in `exec.zig`,
porting `backtrack.go`). For a **small program and small input** — concretely
`ninst ≤ 500` and `input.len < 256·1024 / ninst` — a depth-first backtracking
search is faster than maintaining the Pike VM's thread set. The catch that
would normally make backtracking exponential is defused by a `(pc, pos)`
**visited bitmap** (`shouldVisit`): each program-counter / input-position pair
is explored at most once, which caps total work and keeps the engine linear.
The bitmap is shared across the start positions of an unanchored scan, so the
whole scan stays linear too. Greedy priority is preserved by the order jobs
are pushed onto the stack.

**(3) Pike VM** (`Machine` in `exec.zig`, porting `exec.go`). The general
engine, used whenever the first two do not apply. It is the textbook Thompson
NFA simulation *with submatch tracking*: it maintains two thread queues
(`q0`/`q1`) as **sparse sets** for O(1) membership, where each thread carries
its own capture registers. `add` computes the epsilon-closure of a program
counter; `step` advances every thread in the current queue by one rune into
the next queue. This is the engine that delivers the linear-time guarantee in
full generality, and the one whose ordering establishes match priority
(section 4).

### Literal-prefix acceleration

Layered on top of the Pike VM (and the backtracker's unanchored loop) is a
**vectorized first-byte scan**. At compile time, `Prog.prefix` extracts the
longest literal string that *every* match must begin with. During an
unanchored search, when the thread queue empties, instead of stepping the NFA
at every byte the engine fast-forwards to the next occurrence of that prefix:

```zig
// exec.zig, Machine.run — when runq is empty and we have a literal prefix:
if (m.prefix.len > 0 and r1 != m.prefix_rune and pos <= input.s.len) {
    if (prefixIndex(input.s[pos..], m.prefix)) |adv| { pos += adv; ... }
    else break;
}
```

`prefixIndex` finds the prefix's first byte with `std.mem.indexOfScalar` (a
SIMD/`memchr`-class scalar scan) and verifies the rest — exactly Go's
`bytes.Index` strategy, which is dramatically faster than per-byte NFA
stepping for the common "rare first byte" case (literal searches, dates,
`\d+`, etc.).

---

## 4. Key invariants

The engines lean on a handful of representation invariants. Break any of them
and results diverge from Go.

**Greedy/non-greedy is encoded by the ORDER of an `alt`'s two successors.**
An `.alt` instruction has two epsilon successors, `out` and `arg`. The
compiler emits them so that `out` is the *higher-priority* branch. For a
greedy `x*`, the "take another `x`" branch is `out`; for a non-greedy `x*?`,
the "stop now" branch is `out`. There is no separate "greedy" flag — greediness
*is* the ordering. `prog.zig` documents this on `InstOp.alt`
("two epsilon successors (greedy priority: out first)").

**Leftmost-first priority comes from the Pike VM's epsilon-closure order.**
`Machine.add` recurses into `i.out` *before* `i.arg` for `.alt`/`.alt_match`,
so higher-priority threads are inserted into the queue *first*. In first-match
(non-`longest`) mode, when a thread reaches `.match`, `step` *frees all
lower-priority threads behind it and empties the queue* — that is the moment
Perl/RE2 leftmost-first semantics are realized: the first match found in
priority order wins, and nothing lower-priority can override it. Setting
`longest = true` (POSIX) flips this: the engine keeps exploring and prefers the
*longest* match instead of cutting off at the first.

**Char-class rune lists are sorted, merged `(lo, hi)` pairs.** A `.rune`
instruction's `runes` field is a flat array of inclusive range pairs
`[lo0, hi0, lo1, hi1, …]`, kept sorted and non-overlapping. `matchRunePos`
relies on this: it linear-scans for ≤ 8 ranges and **binary-searches** for
larger classes, which is only correct because the pairs are ordered and merged.
The returned pair index also feeds the one-pass `Next` dispatch table.

**Submatch results are padded to `2·(numSubexp+1)`.** Every submatch result
slice has `2·(numSubexp+1)` entries: a `[start, end]` pair per group, group 0
being the whole match, `-1` for groups that did not participate. `padLen()` in
`regexp.zig` computes this, and it can legitimately exceed the program's own
`num_cap` when a capturing group is compiled away (e.g. `(a){0}`) — the extra
trailing slots simply stay `-1`, exactly like Go's `pad`. This is why
`findSubmatchIndex` always returns a fixed-width, Go-shaped vector.

---

## 5. Differential testing — the project's backbone

The port's central claim is *result-identical to Go*, and that claim is
**proven mechanically**, not asserted. The methodology:

1. **Go generators record golden results.** Small Go programs in `tools/`
   (`gencases.go`, `genfuzz.go`, `genlongest.go`) run a large set of
   `(pattern, input)` pairs through the *real* Go `regexp` package and record
   what Go returns. For each case they capture `FindStringSubmatchIndex` (`m`),
   and — in the fuzz corpus — also `FindAllStringSubmatchIndex` (`all`),
   `ReplaceAllString` with a template (`repl`), and `Split` (`split`). Each
   result is written as one JSON object per line into a committed `src/*.jsonl`
   corpus.
2. **Zig tests `@embedFile` and replay.** The `*test.zig` harnesses embed the
   corpus at compile time, parse each line, recompile the pattern with *this*
   engine, run the same operations, and assert the output is **byte-for-byte
   identical** to Go's recorded result (including error parity — we must error
   iff Go errored, and match iff Go matched).
3. **Under a leak-checking allocator.** Every case runs on
   `std.testing.allocator`, so any byte leaked across the whole suite fails the
   test. Parity and zero-leak are checked together.

Three corpora cover three regimes:

| Corpus           | Test harness        | Generator        | What it exercises |
|------------------|---------------------|------------------|-------------------|
| `cases.jsonl`    | `difftest.zig`      | `gencases.go`    | ~5.9k curated `(pattern, input)` pairs — the tricky, hand-chosen edge cases |
| `fuzz.jsonl`     | `fuzztest.zig`      | `genfuzz.go`     | ~9k grammar-driven random patterns/inputs, checking `m` + `all` + `repl` + `split` |
| `longest.jsonl`  | `longesttest.zig`   | `genlongest.go`  | ~15k POSIX leftmost-longest cases (`Regexp.Longest()`), isolating the `longest` branches of the Pike VM |

Together that is roughly **30,000 cases with zero mismatches and zero leaks**,
re-run in full by CI on every push. When a divergence is ever introduced, the
harness prints the offending pattern, input, Go's result, and our result
side-by-side (`reportMismatch`), so the regression is immediately diagnosable.

There is also a benchmark corpus (`bench.jsonl` + `bench_corpus.txt`,
generated by `genbench.go`, driven by `bench.zig`) used for the head-to-head
performance comparison against Go on a shared 256 KB corpus with identical
patterns, inputs, and calibration.

---

## 6. Generated data — never hand-edited

Two source files are **machine-generated from Go's `unicode` package** and
must never be edited by hand:

- **`fold_table.zig`** — the case-folding table, generated by `genfold.go`
  directly from Go's `unicode.SimpleFold`. It covers *all of Unicode*, so
  `(?i)` case-insensitive matching folds correctly across the entire codepoint
  range, not just ASCII. `unicode.zig`'s `simpleFold` is a thin lookup over
  this table.
- **`unicode_tables.zig`** — the `\p{…}` class tables (general categories and
  scripts), generated by `genuni.go` as a curated subset of the most common
  categories/scripts.

Both are regenerated — alongside the differential and benchmark corpora — by:

```sh
tools/regen.sh
```

which shells out to the locally-installed Go toolchain (the golden reference)
and overwrites the generated files. Because they are derived artifacts, hand
edits would be silently clobbered on the next regeneration and, worse, would
break parity with Go. If you need to change them, change the generator (or the
Go version) and re-run `regen.sh`.

---

## Credits

The RE2 design and the Go `regexp` implementation are the work of Russ Cox and
the Go authors; this project is a derivative port of their BSD-3-Clause code
(see `NOTICE`). zoptia0regex is licensed Apache-2.0 and is not affiliated with
Go or Google.

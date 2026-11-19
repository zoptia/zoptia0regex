<div align="center">

# zoptia0regex

### Go's `regexp`, faithfully replicated in Zig — and faster.

A **regular-expression (regex) library for Zig** — a high-fidelity port of the
RE2 engine, with a linear-time guarantee and a differential test suite that
holds it to **byte-for-byte parity with Go**.

[![CI](https://github.com/zoptia/zoptia0regex/actions/workflows/ci.yml/badge.svg)](https://github.com/zoptia/zoptia0regex/actions)
[![Zig](https://img.shields.io/badge/Zig-0.17-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

</div>

---

## ⚡ Faster than Go. Identical to Go. Provably.

Head-to-head against Go's standard-library `regexp`: same patterns, same
inputs, same 256 KB corpus, same calibration, Zig built `ReleaseFast`.

<!-- BEGIN GENERATED: bench-headline -->
Across 22 workloads the port's geometric-mean time is **0.44×** Go's (0.48× without the literal fast-path rows), and it compiles patterns in **0.74×** Go's time.
<!-- END GENERATED: bench-headline -->

And it doesn't trade correctness for speed: tens of thousands of
differential cases recorded from Go (go1.27.1, Unicode 17.0) require the
port's output to be **byte-for-byte identical to Go's**.

Not "inspired by." **Proven identical.**

- 🚀 **Faster than Go at matching.** Anchored "validation" patterns run on
  the one-pass engine, complete literals skip the engines entirely, and a
  SIMD first-byte prefilter Go doesn't have speeds up unanchored `(?i)` and
  `\d`-led scans. The full table is in **[BENCHMARKS.md](BENCHMARKS.md)**.
- 🛡️ **Linear-time. ReDoS-proof.** Thompson NFA simulation means no
  catastrophic backtracking, ever. A pattern like `(a+)+` that hangs PCRE,
  JS, and Python runs in linear time here. Parser resource limits (program
  size, nesting depth, rune budget) are Go's, exactly.
- ✅ **Proven identical to Go.** The differential suite replays Go's
  recorded results — compile errors with their error codes, offending
  fragments and `MustCompile` messages, compiled program
  size, literal prefixes, matches, find-all, replace and split — and
  requires the port to agree on every case. **Zero mismatches. Zero leaks.**
- 🌍 **Unicode-correct.** `(?i)` case folding uses tables generated directly
  from Go's `unicode.SimpleFold`, correct across *all* of Unicode, not just
  ASCII.

## In a nutshell

```zig
var re = try regex.compile(gpa, "(\\w+)@(\\w+)\\.(\\w+)");
defer re.deinit();

const subs = (try re.findSubmatch(gpa, "ping me@example.com")).?;
defer gpa.free(subs);
// subs => "me@example.com" / "me" / "example" / "com"
```

→ Full install & API in the **[usage guide](docs/usage.md)**.

## Why this exists

zoptia0regex is a faithful, high-fidelity replica of Go's standard-library
`regexp` package — the RE2 design by Russ Cox. It mirrors Go's
**leftmost-first** match semantics (plus **POSIX leftmost-longest**), the same
`Find` / `Replace` / `Split` / submatch API surface, and the same four-stage
pipeline: **parse → simplify → compile → execute**. All three of Go's
execution engines are here — the **one-pass** matcher, the **bitstate
backtracker**, and the **Pike VM** — chosen automatically per search exactly
as Go chooses them.

All engines share literal-prefix acceleration (anchored on the prefix's
rarest byte, switching to Rabin-Karp when false starts get expensive), and
the port adds two shortcuts Go doesn't have: a regexp that is exactly a
literal is answered by a substring search without starting an engine, and a
**SIMD first-byte prefilter** lets the unanchored engines skip ahead with a
portable `@Vector` sweep when every match must start with one of ≤ 16 ASCII
bytes (a case-insensitive literal, `\d`, a small class).

For the full design walkthrough, see **[docs/internals.md](docs/internals.md)**.

## Features

- 🧩 Full Go `regexp/syntax`: literals, alternation, character classes (`[...]`,
  `[^...]`, ranges, Perl `\d\w\s`, POSIX `[[:alpha:]]`, every Unicode `\p{...}`
  category, script and alias Go accepts), `.`, anchors `^ $ \A \z \b \B`.
- 🔁 Quantifiers `* + ? {n,m}`, greedy and non-greedy.
- 🏷️ Capturing, non-capturing, and named groups; inline flags `(?imsU)`;
  escapes; `\Q...\E`.
- ⚖️ Two match modes: leftmost-first (Go default) and POSIX leftmost-longest.
- 🛡️ Linear-time guarantee — immune to ReDoS.
- ⚡ Allocation-free hot loops: reuse a `Scratch` across matches
  (`matchScratch`, nested `matchesScratch` loops) for zero-allocation
  steady state, like Go's machine pool.
- 🩺 Go's compile diagnostics: `compileDiagnostic` reports the offending
  fragment (`syntax.Error.Expr`), and `mustCompile` panics with Go's exact
  message.
- 🌍 Full-Unicode case folding via Go-derived tables (Unicode 17.0, in step
  with Go 1.27).
- 🚫 Same intentional limits as RE2/Go: **no backreferences, no `\C`**.

## Install & use

Requires **Zig 0.17** (`minimum_zig_version = "0.17.0"`). CI also builds and
tests on zvk's Zig nightly (`zig-nightly`, currently 0.18.0-dev).

```sh
zig fetch --save git+https://github.com/zoptia/zoptia0regex
```

```zig
const regex = @import("regex");

var re = try regex.compile(gpa, "(\\w+)@(\\w+)\\.(\\w+)");
defer re.deinit();
const subs = (try re.findSubmatch(gpa, "ping me@example.com")).?;
defer gpa.free(subs);
```

That's the taste — the **[full install + API guide lives in docs/usage.md](docs/usage.md)**:
wiring the dependency into `build.zig`, every `Find` / `FindAll` / `Replace` /
`Split` / submatch variant, the memory model, and POSIX mode. The package
ships only the library (`src/`); the test corpora and benchmarks stay in the
repository.

## Trust & validation

CI runs the full differential suite on every push to `main`, on every pull
request, and weekly (to catch toolchain drift): on Linux and macOS with
the release Zig, and on Linux with the nightly. The corpora are recorded from Go 1.27.1 by
the generators in [`tools/`](tools) and committed in [`test/data/`](test/data),
so running them needs no Go toolchain; `test/data/MANIFEST.json` records the
Go and Unicode versions and each corpus's case count.

| Corpus | What it holds |
|---|---|
| Curated (`cases.jsonl`) | Hand-picked patterns × hand-picked inputs across every feature; Go's own invalid / Perl-only / POSIX-only parser test lists and a pattern set reaching every parse error site, in both syntaxes; the parser's size, nesting and factor-recursion limits |
| Random (`fuzz.jsonl`) | Grammar-generated Perl-syntax patterns, an alternation stream for Go's factoring, inputs with NULs and malformed UTF-8, and patterns with spliced-in syntax errors |
| Leftmost-longest (`longest.jsonl`) | Random patterns under `setLongest()`, and random POSIX ERE patterns through `compilePOSIX` |
| Byte-level (`bytes.jsonl`) | Malformed UTF-8 and NUL inputs in Perl, longest and POSIX modes, bounded `findAll`/`split` limits, `$` templates, depth limits, surrogate code points in literal prefixes |

For **every** case the port must match Go's compile outcome (and for a
failure, Go's error code, its `Error.Expr` fragment and the `MustCompile`
panic message), Go's compiled program size (`ni`, so the AST and
program shape are Go's, not just the results) and `LiteralPrefix()`, and
then `FindSubmatchIndex` / `Match` / `FindIndex` and their `Scratch`
variants. The random, longest and byte-level corpora additionally check
`FindAllSubmatchIndex` / `FindAllIndex` / the `matches` iterator,
`ReplaceAll` and `Split`. A truncated corpus or a stale count fails,
and everything runs under `std.testing.allocator`, so a leak fails too.

```sh
zig build test        # unit + behaviour tests
zig build difftest    # the full differential suite (no Go toolchain needed)
zig build bench       # benchmark (ReleaseFast); tools/bench.sh compares with Go
```

## License & acknowledgement

Licensed under **Apache-2.0**.

zoptia0regex is a faithful port of Go's standard-library `regexp` package. Deep
thanks to **Russ Cox** and the **Go authors** — portions are derived from Go's
BSD-3-Clause-licensed code, and the Unicode tables from the Unicode Character
Database; both are attributed in [NOTICE](NOTICE). Not affiliated with Go or
Google.

---

<div align="center">

**[Usage guide](docs/usage.md)** · **[Internals](docs/internals.md)** ·
**[Benchmarks](BENCHMARKS.md)** · **[Contributing](CONTRIBUTING.md)**

</div>

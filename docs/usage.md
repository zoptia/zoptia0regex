# zoptia0regex — Developer Guide

A faithful Zig port of Go's standard-library `regexp` package (the RE2 design by
Russ Cox). It reproduces Go's leftmost-first match semantics (plus POSIX
leftmost-longest), the same `Find`/`Replace`/`Split`/submatch API surface, and
all three of Go's execution engines (one-pass, bitstate backtracker, Pike VM)
with literal-prefix acceleration.

Matching runs in **linear time** via Thompson NFA simulation — there is no
catastrophic backtracking, so the engine is immune to ReDoS. A pattern such as
`(a+)+` that hangs PCRE/JS/Python engines runs in linear time here.

---

## 1. Requirements & install

### Requirements

- **Zig 0.17.0 or newer** (the package declares `minimum_zig_version =
  "0.17.0"`). CI also smoke-tests the 0.18-dev nightly.

### Add the dependency

Fetch the package and record it in your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/zoptia/zoptia0regex
```

This adds an entry under `.dependencies` in your `build.zig.zon` keyed
`zoptia0regex`.

### Wire the `regex` module in `build.zig`

The package exposes a single public module named **`regex`**. Resolve the
dependency and add its module to whatever module needs it:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Pull in zoptia0regex and expose its "regex" module to your code.
    const regex_dep = b.dependency("zoptia0regex", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("regex", regex_dep.module("regex"));

    const exe = b.addExecutable(.{ .name = "myapp", .root_module = exe_mod });
    b.installArtifact(exe);
}
```

### Import it

```zig
const regex = @import("regex");
```

---

## 2. Quick start

Compile a pattern with three capturing groups, then pull the submatches out of
an input string:

```zig
const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Compile once; the Regexp owns a heap arena freed by deinit().
    var re = try regex.compile(gpa, "(\\w+)@(\\w+)\\.(\\w+)");
    defer re.deinit();

    // findSubmatch returns null on no match; the outer slice is caller-owned.
    if (try re.findSubmatch(gpa, "ping me@example.com")) |subs| {
        defer gpa.free(subs);
        // subs[0] is the whole match; subs[1..] are the groups.
        // subs[1] = "me", subs[2] = "example", subs[3] = "com"
        for (subs, 0..) |s, i| {
            if (s) |text| {
                std.debug.print("group {d}: {s}\n", .{ i, text });
            } else {
                std.debug.print("group {d}: <none>\n", .{i});
            }
        }
    } else {
        std.debug.print("no match\n", .{});
    }
}
```

Each submatch element is a sub-slice of the original input (or `null` for a
group that did not participate), so it stays valid as long as the input does.
The outer slice is heap-allocated and must be freed by the caller.

---

## 3. API reference

All functions live on `regex` (the module) or `regex.Regexp` (the compiled
value). Compile errors surface as `regex.ParseError`; all execution and result
methods return `regex.ExecError!...`, which is `std.mem.Allocator.Error` —
allocation failure is the only runtime error.

Small types you will see in signatures:

```zig
pub const Match = struct { start: usize, end: usize };
pub const LiteralPrefix = struct { prefix: []const u8, complete: bool };
pub const ExecError = std.mem.Allocator.Error;
```

### Compilation

| Function | Description |
|---|---|
| `compile` | Compile with Perl (leftmost-first) semantics. |
| `compilePOSIX` | Compile with POSIX ERE syntax and leftmost-longest semantics. |
| `mustCompile` | Like `compile`, but panics if the pattern cannot be compiled. |
| `mustCompilePOSIX` | Like `compilePOSIX`, but panics if the pattern cannot be compiled. |
| `errorString` | Go's `syntax.ErrorCode` text for a `ParseError` (e.g. `"missing closing )"`). |
| `Regexp.setLongest` | Switch an existing `Regexp` to leftmost-longest matching for future searches (Go's `Longest`). |
| `Regexp.deinit` | Free the `Regexp`. |

```zig
pub fn compile(gpa: std.mem.Allocator, expr: []const u8) ParseError!Regexp
pub fn compilePOSIX(gpa: std.mem.Allocator, expr: []const u8) ParseError!Regexp
pub fn mustCompile(gpa: std.mem.Allocator, expr: []const u8) Regexp
pub fn mustCompilePOSIX(gpa: std.mem.Allocator, expr: []const u8) Regexp
pub fn errorString(err: ParseError) []const u8
pub fn Regexp.setLongest(re: *Regexp) void
pub fn Regexp.deinit(re: *Regexp) void
```

The `gpa` passed to `compile`/`compilePOSIX`/`mustCompile*` backs the
`Regexp`'s internal arena; the returned `Regexp` owns that memory until
`deinit` (see §4). All the exec/result methods below take a *separate*
allocator for scratch and results.

`ParseError` has one member per Go `syntax.ErrorCode` (`MissingParen`,
`InvalidRepeatOp`, …, `NestingDepth`, `TooLarge`) plus `OutOfMemory`;
`errorString` returns Go's text for each (and `"out of memory"`).
`mustCompile` panics with Go's message shape,
``regexp: Compile(`a(`): error parsing regexp: missing closing )`` — Go also
appends the offending fragment of the pattern, which the Zig error set does
not carry. Running out of memory panics with `...: out of memory`.

### Boolean match

| Function / method | Description |
|---|---|
| `match` (package level) | Go's `regexp.MatchString(pattern, s)`: compile, match once, free. |
| `Regexp.match` | Reports whether `input` contains any match. |
| `Regexp.matchString` | Alias of `match` (Go splits `[]byte`/`string`; here both are `[]const u8`). |

```zig
pub fn match(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) ParseError!bool
pub fn Regexp.match(re: *const Regexp, allocator, input: []const u8) ExecError!bool
pub fn Regexp.matchString(re: *const Regexp, allocator, s: []const u8) ExecError!bool
```

None allocate anything for the caller to free. The package-level `match`
compiles on every call; `compile` a pattern you use more than once.

### Find — leftmost match

| Method | Description | No match | Owned |
|---|---|---|---|
| `find` | Text of the leftmost match (sub-slice of `input`). | `null` | no (alias into `input`) |
| `findIndex` | Byte offsets of the leftmost match as a `Match`. | `null` | no |

```zig
pub fn Regexp.find(re: *const Regexp, allocator, input: []const u8) ExecError!?[]const u8
pub fn Regexp.findIndex(re: *const Regexp, allocator, input: []const u8) ExecError!?Match
```

**Literal fast path.** When the whole pattern is a plain literal — no
capture groups, no assertions (`^`, `\b`, …), no case folding — `match`,
`findIndex`, `find` and their `*Scratch` variants skip the matching engines
entirely and answer with a substring search, allocating nothing.

### Find with submatches

| Method | Description | No match | Owned |
|---|---|---|---|
| `findSubmatch` | Submatch texts (sub-slices of `input`; `null` per non-participating group). | `null` | outer slice only |
| `findSubmatchIndex` | Submatch byte offsets `[s0,e0,s1,e1,…]`, length `2*(numSubexp+1)`; `-1` for groups that did not participate. | `null` | yes |

```zig
pub fn Regexp.findSubmatch(re: *const Regexp, allocator, input: []const u8) ExecError!?[]?[]const u8
pub fn Regexp.findSubmatchIndex(re: *const Regexp, allocator, input: []const u8) ExecError!?[]i64
```

For `findSubmatch`, free the outer slice with `allocator.free(subs)`; the inner
texts are sub-slices of `input` and are not separately allocated. Index `0` is
always the whole match.

### Find all matches

| Method | Description | No matches | Owned |
|---|---|---|---|
| `findAll` | Texts of all successive matches (sub-slices of `input`). | `null` | outer slice only |
| `findAllIndex` | `Match` locations of all successive matches. | `null` | yes |
| `findAllSubmatch` | Submatch texts for every match; each inner slice has length `numSubexp+1`, elements are sub-slices of `input` or `null`. | `null` | outer **and** every inner slice |
| `freeAllSubmatch` | Frees the result of `findAllSubmatch`. | — | — |
| `findAllSubmatchIndex` | Submatch offsets for every match; each inner slice has length `2*(numSubexp+1)`. | `null` | outer **and** every inner slice |
| `freeAllSubmatchIndex` | Frees the result of `findAllSubmatchIndex`. | — | — |
| `matches` | Iterator over successive matches (Go 1.27's `matches` / `All*`): `next()` yields borrowed submatch offsets, `deinit()` frees it. | `next()` → `null` | the iterator only |

```zig
pub fn Regexp.findAll(re: *const Regexp, allocator, input: []const u8, n: i64) ExecError!?[][]const u8
pub fn Regexp.findAllIndex(re: *const Regexp, allocator, input: []const u8, n: i64) ExecError!?[]Match
pub fn Regexp.findAllSubmatch(re: *const Regexp, allocator, input: []const u8, n: i64) ExecError!?[][]?[]const u8
pub fn Regexp.freeAllSubmatch(allocator: std.mem.Allocator, x: [][]?[]const u8) void
pub fn Regexp.findAllSubmatchIndex(re: *const Regexp, allocator, input: []const u8, n: i64) ExecError!?[][]i64
pub fn Regexp.freeAllSubmatchIndex(allocator: std.mem.Allocator, x: [][]i64) void
pub fn Regexp.matches(re: *const Regexp, allocator, input: []const u8, n: i64) ExecError!Regexp.Matches
pub fn Regexp.Matches.next(it: *Matches) ExecError!?[]const i64
pub fn Regexp.Matches.deinit(it: *Matches) void
```

`n` caps the number of matches: `n < 0` means "all", `n == 0` yields no matches,
`n > 0` returns at most `n`. Free `findAllSubmatch` / `findAllSubmatchIndex`
with `freeAllSubmatch` / `freeAllSubmatchIndex`, which free each inner slice
and the outer slice:

```zig
if (try re.findAllSubmatch(gpa, input, -1)) |all| {
    defer regex.Regexp.freeAllSubmatch(gpa, all);
    for (all) |groups| {
        // groups[0] is the whole match, groups[k] group k (null = unset).
        if (groups[1]) |g1| std.debug.print("{s}\n", .{g1});
    }
}
```

For `findAll` / `findAllIndex`, free the single returned slice with
`allocator.free`.

All of the above are built on `matches`, the port of Go 1.27's `matches`
iterator: it allocates the engine scratch once and reuses it for every match,
so scanning a large input allocates nothing per match. Use it directly when you
want to stream matches instead of collecting them:

```zig
var it = try re.matches(gpa, input, -1);
defer it.deinit();
while (try it.next()) |m| {
    // m[0..2] is the whole match, m[2*k..2*k+2] group k (-1 = unset).
    // m is borrowed: it is overwritten by the next call to next().
    std.debug.print("{s}\n", .{input[@intCast(m[0])..@intCast(m[1])]});
}
```

### Replace

| Method | Description |
|---|---|
| `replaceAllString` | Replace every match with `repl`, expanding `$1` / `${name}` references (see `expand`). |
| `replaceAllLiteralString` | Replace every match with `repl` literally (no `$` expansion). |
| `replaceAllFunc` | Replace every match with whatever a callback appends to the output (Go's `ReplaceAllFunc`). |
| `replaceAllStringFunc` | Replace every match with the slice a callback returns. Kept for compatibility; prefer `replaceAllFunc`. |

```zig
pub fn Regexp.replaceAllString(re: *const Regexp, allocator, src: []const u8, repl: []const u8) ExecError![]u8
pub fn Regexp.replaceAllLiteralString(re: *const Regexp, allocator, src: []const u8, repl: []const u8) ExecError![]u8
pub fn Regexp.replaceAllFunc(
    re: *const Regexp,
    allocator: std.mem.Allocator,
    src: []const u8,
    ctx: anytype,
    comptime func: fn (@TypeOf(ctx), std.mem.Allocator, *std.ArrayList(u8), []const u8) ExecError!void,
) ExecError![]u8
pub fn Regexp.replaceAllStringFunc(
    re: *const Regexp,
    allocator: std.mem.Allocator,
    src: []const u8,
    ctx: anytype,
    comptime func: fn (@TypeOf(ctx), []const u8) []const u8,
) ExecError![]u8
```

All four return a freshly allocated `[]u8` the caller owns (free with
`allocator.free`). `ctx` is passed through to the callback so it can carry
state.

`replaceAllFunc`'s callback gets the allocator, the output buffer and the
matched text; it appends the replacement itself and may allocate (and free)
temporary memory from the allocator. Its errors propagate: the partial output
is freed and the error returned.

```zig
const Upper = struct {
    fn f(_: void, al: std.mem.Allocator, out: *std.ArrayList(u8), m: []const u8) regex.ExecError!void {
        const tmp = try std.ascii.allocUpperString(al, m);
        defer al.free(tmp);
        try out.appendSlice(al, tmp);
    }
};
const out = try re.replaceAllFunc(gpa, src, {}, Upper.f);
defer gpa.free(out);
```

`replaceAllStringFunc`'s callback returns a slice that is copied into the
output immediately, so it only has to stay valid until the callback returns.
But the callback cannot fail and gets no allocator, and the library never
frees what it returns: return a literal, a sub-slice of the match, or memory
`ctx` owns. For text built per match, use `replaceAllFunc`.

```zig
const Mask = struct {
    fn f(_: @This(), m: []const u8) []const u8 {
        return if (m.len > 3) "****" else "*";
    }
};
const masked = try re.replaceAllStringFunc(gpa, src, Mask{}, Mask.f);
defer gpa.free(masked);
```

### Expand

| Method | Description |
|---|---|
| `expand` | Append `template` to `buf`, expanding `$name` / `${name}` / `$1` references using `m` (submatch offsets into `src`). |

```zig
pub fn Regexp.expand(
    re: *const Regexp,
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    template: []const u8,
    src: []const u8,
    m: []const i64,
) ExecError!void
```

`m` is a submatch-offset slice as returned by `findSubmatchIndex` or yielded by
`Matches.next`. The expanded text is appended to the caller-supplied `buf`;
the caller owns `buf` and its backing memory. `$$` emits a literal `$`; a
malformed reference emits a literal `$`.

```zig
var buf: std.ArrayList(u8) = .empty;
defer buf.deinit(gpa);
var it = try re.matches(gpa, input, -1);
defer it.deinit();
while (try it.next()) |m| try re.expand(gpa, &buf, "[$1]", input, m);
```

### Split

| Method | Description | Special cases | Owned |
|---|---|---|---|
| `split` | Split `src` around matches (Go's `Split`). | `n == 0` returns `null`. | outer slice only |

```zig
pub fn Regexp.split(re: *const Regexp, allocator, src: []const u8, n: i64) ExecError!?[][]const u8
```

`n < 0` returns all pieces; `n == 0` returns `null`; `n > 0` returns at most `n`
pieces (the final piece holds the unsplit remainder). Pieces are sub-slices of
`src`; free the outer slice with `allocator.free`.

### quoteMeta

| Function | Description |
|---|---|
| `quoteMeta` | Return `s` with all regex metacharacters escaped (Go's `QuoteMeta`). |

```zig
pub fn quoteMeta(allocator: std.mem.Allocator, s: []const u8) ExecError![]u8
```

Returns a freshly allocated `[]u8` the caller owns (free with `allocator.free`).

### Introspection

These read compiled metadata; none allocate, and their returned slices are
borrowed from the `Regexp` (valid until `deinit`).

| Method | Description |
|---|---|
| `string` | The source text the regexp was compiled from. |
| `numSubexp` | Number of parenthesized subexpressions. |
| `subexpNames` | Names of the capturing groups; `subexpNames()[0]` is always `""`. |
| `subexpIndex` | Index of the first subexpression with the given name, or `null`. |
| `literalPrefix` | A literal string that must begin any match, and whether it is the whole regexp. |

```zig
pub fn Regexp.string(re: *const Regexp) []const u8
pub fn Regexp.numSubexp(re: *const Regexp) usize
pub fn Regexp.subexpNames(re: *const Regexp) []const []const u8
pub fn Regexp.subexpIndex(re: *const Regexp, name: []const u8) ?usize
pub fn Regexp.literalPrefix(re: *const Regexp) LiteralPrefix
```

The fields of `Regexp` and `Regexp.Matches` are public only for tests and the
low-level `syntax` namespace; they are internal. Use the methods above and
never write the fields.

---

### Allocation-free matching (`Scratch`)

The methods above allocate (and free) their engine working memory on every
call. For a hot loop over one compiled pattern, allocate a reusable `Scratch`
once instead — after warm-up each call does zero heap allocation, like Go's
pooled `*machine`:

| Method | Description | No match |
|---|---|---|
| `matchScratch` | `match` reusing a caller-owned `Scratch`. | `false` |
| `findIndexScratch` | `findIndex` reusing a caller-owned `Scratch`. | `null` |
| `findSubmatchIndexScratch` | `findSubmatchIndex` reusing a caller-owned `Scratch`. **The returned slice is borrowed from the scratch** — valid only until the next call that reuses it; copy it to keep it, and do *not* free it. | `null` |
| `matchesScratch` | `matches` iterator borrowing engine buffers *and* the yielded offsets from the `Scratch`: repeated scans allocate nothing once warm. Valid until the next call that reuses the scratch; `deinit` frees nothing. | `next()` → `null` |

```zig
pub fn Regexp.matchScratch(re: *const Regexp, scratch: *Scratch, input: []const u8) ExecError!bool
pub fn Regexp.findIndexScratch(re: *const Regexp, scratch: *Scratch, input: []const u8) ExecError!?Match
pub fn Regexp.findSubmatchIndexScratch(re: *const Regexp, scratch: *Scratch, input: []const u8) ExecError!?[]i64
pub fn Regexp.matchesScratch(re: *const Regexp, scratch: *Scratch, input: []const u8, n: i64) ExecError!Regexp.Matches
```

```zig
var scratch = regex.Scratch.init(gpa);
defer scratch.deinit();

for (lines) |line| {
    if (try re.matchScratch(&scratch, line)) hits += 1;
}
```

A `Scratch` may be reused across different `Regexp`s (its buffers regrow as
needed), but it serves **one match at a time**:

- It carries no synchronisation: never share one `Scratch` between concurrent
  matches.
- **No nested iteration on one `Scratch`.** Every result it hands out — the
  `findSubmatchIndexScratch` slice and the offsets a `matchesScratch` iterator
  yields — lives in one shared buffer. Starting a second `matchesScratch` (or
  any other `*Scratch` call) on the same scratch while an outer
  `matchesScratch` loop is still running overwrites, and may reallocate, the
  outer loop's offsets. Give the inner loop its own `Scratch`, or use
  `matches`, which owns its buffers.

---

## 4. Memory model

The split is deliberate and consistent:

- **`Regexp` owns a heap arena.** `compile` / `compilePOSIX` / `mustCompile*`
  allocate an arena from the `gpa` you pass; the compiled program, subexpression
  names, source text, and prefix all live inside it. Call `re.deinit()` once
  to free everything in one shot:

  ```zig
  var re = try regex.compile(gpa, pattern);
  defer re.deinit();
  ```

- **Do not copy a `Regexp`.** It holds its arena by pointer, so `var b = a;`
  followed by `deinit` on both frees the arena twice. Keep one value, call
  `deinit` on it exactly once, and pass `*const Regexp` everywhere else. In
  safe builds a second `deinit` of the *same* variable trips an assertion; a
  `deinit` of a copy cannot be detected. The same goes for a `Matches`
  iterator: do not copy it and keep using both copies.

- **Every exec/result method takes its own `allocator`.** `match`, `find*`,
  `replaceAll*`, `expand`, `split`, and `quoteMeta` use the allocator you pass
  for both internal scratch and the returned result. It need not be the same
  allocator used to `compile` the `Regexp`.

- **The caller frees returned slices.** Anything a method hands back is
  caller-owned unless the table above says otherwise:
  - `find` returns a borrowed sub-slice of the input; do not free it.
  - `findIndex` returns a `Match` value; there is no result allocation to free.
  - `findAll` / `findSubmatch` / `split` return slices whose *elements*
    are sub-slices of the input (not separately allocated) — free only the
    outer slice with `allocator.free`, and keep the input alive while you use
    them.
  - `findAllIndex` / `findSubmatchIndex` return owned slices of
    offsets — free with `allocator.free`.
  - `findAllSubmatch` / `findAllSubmatchIndex` return a slice-of-slices where
    both levels are owned — free with `freeAllSubmatch` /
    `freeAllSubmatchIndex`. The texts inside `findAllSubmatch`'s result point
    into the input.
  - `replaceAll*` and `quoteMeta` return owned `[]u8` — free with
    `allocator.free`.
  - `expand` appends into a `buf` you own and free yourself.
  - `matches` returns an iterator that owns its buffers — free with
    `deinit`; the offsets `next()` yields are borrowed and overwritten by the
    next call.

- **`Scratch` owns its buffers.** The `*Scratch` variants borrow all working
  memory (and, for `findSubmatchIndexScratch` / `matchesScratch`, the result
  offsets) from the `Scratch` you pass; `scratch.deinit()` frees it all.
  Nothing they return is yours to free.

- **No-match is not an error.** Boolean methods return `false`; find methods
  return `null`. Only allocation failure produces an error (`ExecError`).

The whole library is verified leak-free under `std.testing.allocator` across the
full differential suite, and every allocating API is swept with
`std.testing.checkAllAllocationFailures`.

### Thread safety

- All search methods take `*const Regexp`, so one compiled pattern may be
  shared across threads as long as each call uses its own allocator or its
  own `Scratch`.
- `setLongest` is the one method that mutates a `Regexp`. Call it right after
  `compile`, before the regexp is shared — never while another thread may be
  matching with it.
- A `Scratch` and a `Matches` iterator belong to one thread at a time.

---

## 5. Supported syntax

This is Go's `regexp/syntax`. Both `[]byte` and `string` inputs in Go collapse
to `[]const u8` here.

| Category | Syntax | Notes |
|---|---|---|
| Literals | any non-metacharacter; `\Q...\E` | `\Q...\E` quotes a literal run. |
| Alternation | `a\|b` | Leftmost-first (or leftmost-longest under POSIX). |
| Any char | `.` | Matches any char except newline (`s` flag makes it match newline too). |
| Char class | `[abc]`, `[^abc]`, `[a-z]` | Sets, negation, ranges. |
| Perl classes | `\d \D \w \W \s \S` | Digit / word / space and negations. |
| POSIX classes | `[[:alpha:]]`, `[[:digit:]]`, … | Inside `[...]`. |
| Unicode classes | `\p{L}`, `\P{L}`, `\pL`, `\p{Greek}`, `\p{Letter}` | Every general category, script and alias Go accepts (Unicode 17.0); names are matched like Go 1.27, ignoring case, `_`, `-` and spaces. |
| Anchors | `^ $ \A \z \b \B` | Line/text anchors and word boundaries. |
| Quantifiers | `* + ? {n} {n,} {n,m}` | Greedy by default; suffix `?` makes them non-greedy. |
| Groups | `(...)`, `(?:...)`, `(?P<name>...)`, `(?<name>...)` | Capturing, non-capturing, named. |
| Inline flags | `(?imsU)`, `(?imsU:...)` | `i` case-insensitive, `m` multiline, `s` dot-all, `U` swap greediness. |
| Escapes | `\n \t \\`, `\x41`, `\x{1F600}`, `\0`, … | Standard escapes and hex/octal code points. |

Case-insensitive matching (`(?i)`) folds across **all** of Unicode, using tables
generated from Go's `unicode.SimpleFold` — not just ASCII.

---

## 6. Scope & differences from Go

This is a high-fidelity replica: a differential test suite of tens of
thousands of cases across four corpora (curated, fuzz, POSIX leftmost-longest
and byte-level) requires byte-for-byte identical results against the real Go
`regexp` for `FindSubmatchIndex`, `FindAll`, `ReplaceAll`, and `Split`. The
intentional differences are:

- **Tracks Go 1.27.1 / Unicode 17.0.** The `\p{...}` tables, the
  case-folding table and the differential corpora are generated from that Go
  toolchain. Every property name Go accepts (`\p{Lu}`, `\p{Old_Italic}`,
  `\p{Uppercase_Letter}`, `\p{Assigned}`, …) is accepted here with the same
  `(?i)` fold behaviour; unknown names fail with `InvalidCharRange` as in Go.
- **No backreferences, no `\C` — same as Go.** RE2/`regexp` does not support
  backreferences or the `\C` "any byte" escape, and neither does this library.
  This is what guarantees linear-time matching.
- **`[]const u8` inputs only.** Go has parallel `[]byte` and `string` method
  pairs (`Match`/`MatchString`, `FindAllSubmatch`/`FindAllStringSubmatch`,
  etc.). Here every input is `[]const u8`, so the pairs collapse to a single
  method; `matchString` is kept as an alias of `match` for familiarity.
- **No `io.RuneReader` methods.** `MatchReader`, `FindReaderIndex` and
  `FindReaderSubmatchIndex` (and the package-level `MatchReader`) are not
  provided.
- **Go 1.27's `All*` iterators** (`iter.Seq` forms of `FindAll*`, which the
  1.27 docs name `Regexp.All…` and which go1.27.1 implements as unexported
  `all`, `allIndex`, `allSubmatch`, …) collapse into the single `matches`
  iterator (and `matchesScratch`), which yields submatch offsets.
- **No `Copy`.** Go's `Copy` is deprecated; a `*const Regexp` is safe to share.
  Compile the pattern again if you need an independent value.
- **No `MarshalText` / `UnmarshalText` / `AppendText`.** Store `string()` and
  `compile` it again.
- **`Longest()` is `setLongest()`**, and the package-level `MatchString` is
  `match(gpa, pattern, s)`.
- **Errors are an error set**, not `*syntax.Error`: the offending fragment of
  the pattern is not reported. `errorString` gives Go's `ErrorCode` text.

### Credits & license

Licensed under **Apache-2.0**. This work is derived from Go's `regexp`
implementation (BSD-3-Clause), with credit to **Russ Cox** and the Go authors;
the upstream attribution is in `NOTICE`. Not affiliated with Go or Google.

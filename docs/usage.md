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

- **Zig 0.16** (the package declares `minimum_zig_version = "0.16.0"`).

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

Two small types you will see in signatures:

```zig
pub const Match = struct { start: usize, end: usize };
pub const ExecError = std.mem.Allocator.Error;
```

### Compilation

| Function | Description |
|---|---|
| `compile` | Compile with Perl (leftmost-first) semantics. |
| `compilePOSIX` | Compile with POSIX ERE syntax and leftmost-longest semantics. |
| `mustCompile` | Like `compile`, but panics on a malformed pattern. |
| `Regexp.setLongest` | Switch an existing `Regexp` to leftmost-longest matching for future searches. |

```zig
pub fn compile(gpa: std.mem.Allocator, expr: []const u8) ParseError!Regexp
pub fn compilePOSIX(gpa: std.mem.Allocator, expr: []const u8) ParseError!Regexp
pub fn mustCompile(gpa: std.mem.Allocator, expr: []const u8) Regexp
pub fn Regexp.setLongest(re: *Regexp) void
```

The `gpa` passed to `compile`/`compilePOSIX`/`mustCompile` backs the `Regexp`'s
internal arena; the returned `Regexp` owns that memory until `deinit` (see
§4). All the exec/result methods below take a *separate* allocator for scratch
and results.

### Boolean match

| Method | Description |
|---|---|
| `match` | Reports whether `input` contains any match. |
| `matchString` | Alias of `match` (Go splits `[]byte`/`string`; here both are `[]const u8`). |

```zig
pub fn Regexp.match(re: *const Regexp, allocator, input: []const u8) ExecError!bool
pub fn Regexp.matchString(re: *const Regexp, allocator, s: []const u8) ExecError!bool
```

Allocate nothing for the caller to free.

### Find — leftmost match

| Method | Description | No match | Owned |
|---|---|---|---|
| `find` | Text of the leftmost match (sub-slice of `input`). | `null` | no (alias into `input`) |
| `findIndex` | Byte offsets of the leftmost match as a `Match`. | `null` | no |

```zig
pub fn Regexp.find(re: *const Regexp, allocator, input: []const u8) ExecError!?[]const u8
pub fn Regexp.findIndex(re: *const Regexp, allocator, input: []const u8) ExecError!?Match
```

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
| `findAllSubmatchIndex` | Submatch offsets for every match; each inner slice has length `2*(numSubexp+1)`. | `null` | outer **and** every inner slice |
| `freeAllSubmatchIndex` | Frees the result of `findAllSubmatchIndex`. | — | — |

```zig
pub fn Regexp.findAll(re: *const Regexp, allocator, input: []const u8, n: i64) ExecError!?[][]const u8
pub fn Regexp.findAllIndex(re: *const Regexp, allocator, input: []const u8, n: i64) ExecError!?[]Match
pub fn Regexp.findAllSubmatchIndex(re: *const Regexp, allocator, input: []const u8, n: i64) ExecError!?[][]i64
pub fn Regexp.freeAllSubmatchIndex(allocator: std.mem.Allocator, x: [][]i64) void
```

`n` caps the number of matches: `n < 0` means "all", `n == 0` yields no matches,
`n > 0` returns at most `n`. Free `findAllSubmatchIndex` with
`freeAllSubmatchIndex`, which frees each inner slice and the outer slice:

```zig
if (try re.findAllSubmatchIndex(gpa, input, -1)) |all| {
    defer regex.Regexp.freeAllSubmatchIndex(gpa, all);
    // use all[i] ...
}
```

For `findAll` / `findAllIndex`, free the single returned slice with
`allocator.free`.

### Replace

| Method | Description |
|---|---|
| `replaceAllString` | Replace every match with `repl`, expanding `$1` / `${name}` references (see `expand`). |
| `replaceAllLiteralString` | Replace every match with `repl` literally (no `$` expansion). |
| `replaceAllStringFunc` | Replace every match with the result of a function applied to the matched text. |

```zig
pub fn Regexp.replaceAllString(re: *const Regexp, allocator, src: []const u8, repl: []const u8) ExecError![]u8
pub fn Regexp.replaceAllLiteralString(re: *const Regexp, allocator, src: []const u8, repl: []const u8) ExecError![]u8
pub fn Regexp.replaceAllStringFunc(
    re: *const Regexp,
    allocator: std.mem.Allocator,
    src: []const u8,
    ctx: anytype,
    comptime func: fn (@TypeOf(ctx), []const u8) []const u8,
) ExecError![]u8
```

All three return a freshly allocated `[]u8` the caller owns (free with
`allocator.free`). `func` receives the matched text and returns a slice valid
for the duration of the call; `ctx` is passed through to it so a closure can
carry state:

```zig
const Up = struct {
    fn f(_: @This(), s: []const u8) []const u8 {
        _ = s;
        return "X"; // returned slice must outlive only the call
    }
};
const out = try re.replaceAllStringFunc(gpa, src, Up{}, Up.f);
defer gpa.free(out);
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
    m: []i64,
) ExecError!void
```

`m` is a submatch-offset slice as returned by `findSubmatchIndex`. The expanded
text is appended to the caller-supplied `buf`; the caller owns `buf` and its
backing memory. `$$` emits a literal `$`; a malformed reference emits a literal
`$`.

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
pub fn Regexp.literalPrefix(re: *const Regexp) struct { prefix: []const u8, complete: bool }
```

---

## 4. Memory model

The split is deliberate and consistent:

- **`Regexp` owns a heap arena.** `compile` / `compilePOSIX` / `mustCompile`
  allocate an arena from the `gpa` you pass; the compiled program, subexpression
  names, source text, and prefix all live inside it. Call `re.deinit()` once
  to free everything in one shot:

  ```zig
  var re = try regex.compile(gpa, pattern);
  defer re.deinit();
  ```

- **Every exec/result method takes its own `allocator`.** `match`, `find*`,
  `replaceAll*`, `expand`, `split`, and `quoteMeta` use the allocator you pass
  for both internal scratch and the returned result. It need not be the same
  allocator used to `compile` the `Regexp`. A `*const Regexp` is enough for all
  searching, so a single compiled pattern may be shared across threads as long
  as each call uses its own allocator.

- **The caller frees returned slices.** Anything a method hands back is
  caller-owned unless the table above says otherwise:
  - `find` / `findAll` / `findSubmatch` / `split` return slices whose *elements*
    are sub-slices of the input (not separately allocated) — free only the
    outer slice with `allocator.free`, and keep the input alive while you use
    them.
  - `findIndex` / `findAllIndex` / `findSubmatchIndex` return owned slices of
    offsets — free with `allocator.free`.
  - `findAllSubmatchIndex` returns a slice-of-slices where both levels are
    owned — free with `freeAllSubmatchIndex`.
  - `replaceAll*` and `quoteMeta` return owned `[]u8` — free with
    `allocator.free`.
  - `expand` appends into a `buf` you own and free yourself.

- **No-match is `null`, not an error.** The find/match family return
  `?...`; only allocation failure produces an error (`ExecError`).

The whole library is verified leak-free under `std.testing.allocator` across the
full differential suite.

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
| Unicode classes | `\p{L}`, `\P{L}`, `\pL` | Curated `\p{...}` subset (see §6). |
| Anchors | `^ $ \A \z \b \B` | Line/text anchors and word boundaries. |
| Quantifiers | `* + ? {n} {n,} {n,m}` | Greedy by default; suffix `?` makes them non-greedy. |
| Groups | `(...)`, `(?:...)`, `(?P<name>...)`, `(?<name>...)` | Capturing, non-capturing, named. |
| Inline flags | `(?imsU)`, `(?imsU:...)` | `i` case-insensitive, `m` multiline, `s` dot-all, `U` swap greediness. |
| Escapes | `\n \t \\`, `\x41`, `\x{1F600}`, `\0`, … | Standard escapes and hex/octal code points. |

Case-insensitive matching (`(?i)`) folds across **all** of Unicode, using tables
generated from Go's `unicode.SimpleFold` — not just ASCII.

---

## 6. Scope & differences from Go

This is a high-fidelity replica, and the differential test suite (~30,000 cases
across curated, fuzz, and POSIX-leftmost-longest corpora) requires byte-for-byte
identical results against the real Go `regexp` for `FindSubmatchIndex`,
`FindAll`, `ReplaceAll`, and `Split`. The intentional differences are:

- **`\p{...}` is a curated subset.** The most common Unicode property names and
  general categories are supported; exotic or rarely used property names from
  Go's full `unicode` set may not be. Everything in the curated subset matches
  Go exactly.
- **No backreferences, no `\C` — same as Go.** RE2/`regexp` does not support
  backreferences or the `\C` "any byte" escape, and neither does this library.
  This is what guarantees linear-time matching.
- **`[]const u8` inputs only.** Go has parallel `[]byte` and `string` method
  pairs (`Match`/`MatchString`, etc.). Here every input is `[]const u8`, so the
  pairs collapse to a single method; `matchString` is kept as an alias of
  `match` for familiarity.

### Credits & license

Licensed under **Apache-2.0**. This work is derived from Go's `regexp`
implementation (BSD-3-Clause), with credit to **Russ Cox** and the Go authors;
the upstream attribution is in `NOTICE`. Not affiliated with Go or Google.

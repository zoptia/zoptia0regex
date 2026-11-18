//! The public API, mirroring Go's `regexp` package: `compile`, the
//! `find`/`match`/`replace`/`split` families, submatch extraction, and
//! `$`-template expansion.
//!
//! Memory model: a compiled `Regexp` owns a heap-allocated arena that holds
//! its program, capture names and literal prefix; `deinit` frees it. Execution
//! and result-producing methods each take an `allocator` used for transient VM
//! scratch and (where noted) the returned slice, which the caller owns.
//!
//! Ownership and thread-safety rules (see also `docs/usage.md`):
//! - A `Regexp` is a value that owns its arena through a pointer. Never copy
//!   it and `deinit` both copies (a double free); pass `*const Regexp` around
//!   instead. Exactly one `deinit` per `compile`.
//! - Every search method takes `*const Regexp` and may run concurrently on
//!   one shared `Regexp`, as long as each call has its own allocator or
//!   `Scratch`. `setLongest` mutates the `Regexp`: call it before sharing,
//!   never while another thread is matching.
//! - A `Scratch` serves one match at a time; see `matchesScratch` for the
//!   nested-iteration rule.

const std = @import("std");
const ast = @import("ast.zig");
const parse = @import("parse.zig");
const simplify = @import("simplify.zig");
const compile_ = @import("compile.zig");
const prog = @import("prog.zig");
const exec = @import("exec.zig");
const search = @import("search.zig");
const unicode = @import("unicode.zig");
const onepass = @import("onepass.zig");

pub const ParseError = parse.ParseError;
pub const ExecError = std.mem.Allocator.Error;

/// A matched byte range `input[start..end]`.
pub const Match = struct { start: usize, end: usize };

/// Reusable match storage for the allocation-free `*Scratch` API
/// (`matchScratch` / `findIndexScratch` / `findSubmatchIndexScratch` /
/// `matchesScratch`). Allocate once, reuse across many matches, even on
/// different compiled `Regexp`s. See `exec.Scratch`.
///
/// One `Scratch` serves one match at a time: it carries no synchronisation,
/// and every result it hands out (the `findSubmatchIndexScratch` slice, the
/// offsets a `matchesScratch` iterator yields) lives in a single shared
/// buffer that the next call reusing the `Scratch` overwrites or even
/// reallocates. In particular two live `matchesScratch` iterators on one
/// `Scratch` (nested iteration) clobber each other; give each its own
/// `Scratch`, or use `matches`.
pub const Scratch = exec.Scratch;

/// What `Regexp.literalPrefix` returns: a literal every match must begin
/// with, and whether it is the whole regexp (Go's `LiteralPrefix`).
pub const LiteralPrefix = struct { prefix: []const u8, complete: bool };

/// Stand-in arena `deinit` leaves behind so that a second `deinit` of the
/// same variable trips an assertion in safe builds. Never dereferenced.
var deinitialized_arena: std.heap.ArenaAllocator = undefined;

/// A compiled regular expression, Go's `*regexp.Regexp`.
///
/// Ownership: a `Regexp` owns a heap arena through `arena`, so it must not
/// be copied: `var b = a;` followed by `deinit` on both frees the arena
/// twice. Keep one value, call `deinit` on it exactly once, and pass
/// `*const Regexp` to everything else. A second `deinit` of the same
/// variable is caught by an assertion in safe builds; a `deinit` of a copy
/// is not.
///
/// Thread safety: every search method takes `*const Regexp` and may run
/// concurrently with other searches on the same `Regexp`, given a separate
/// allocator or `Scratch` per call. `setLongest` is the only mutator; do not
/// call it while any other thread may be matching.
///
/// All fields are internal: they are public only so tests and the
/// low-level `syntax` API can inspect them. Read them through the methods
/// (`string`, `numSubexp`, `subexpNames`, `literalPrefix`, ...) and never
/// write them.
pub const Regexp = struct {
    /// Internal: the allocator `arena` was created from.
    base_allocator: std.mem.Allocator,
    /// Internal: owns everything below; freed by `deinit`.
    arena: *std.heap.ArenaAllocator,
    /// Internal: the source text (see `string`).
    expr: []const u8,
    /// Internal: the compiled program.
    prog: *const prog.Prog,
    /// Internal: see `numSubexp`.
    num_subexp: usize,
    /// Internal: see `subexpNames`.
    subexp_names: []const []const u8,
    /// Internal: inputs shorter than this cannot match (Go's `minInputLen`).
    min_input_len: usize,
    /// Internal: Go's `Regexp.prefix` / `prefixComplete` (what
    /// `literalPrefix` reports): `onePassPrefix` for one-pass regexps,
    /// `Prog.prefix` otherwise. The engines read their own copies from
    /// `engine`.
    prefix: []const u8,
    /// Internal: see `prefix`.
    prefix_complete: bool,
    /// Internal: the regexp is a plain literal (`engine.accel.prefix`,
    /// complete): no one-pass program, captures or start condition, and a
    /// prefix that holds no U+FFFD stand-in for an unencodable rune.
    /// Matching is then a substring search (see `findAt`).
    literal: bool,
    /// Internal: same as `engine.accel.first_bytes.bytes`; kept for
    /// introspection in tests.
    first_bytes: []const u8,
    /// Internal: same as `engine.onepass`; kept for introspection in tests.
    onepass: ?*const onepass.OnePassProg,
    /// Internal: everything the matching engines read (see `exec.Engine`).
    engine: exec.Engine,

    /// Frees everything the `Regexp` owns. Call it exactly once, on the
    /// value `compile` returned (not on a copy of it); the `Regexp` is
    /// unusable afterwards.
    pub fn deinit(re: *Regexp) void {
        std.debug.assert(!re.isDeinitialized()); // double deinit
        const gpa = re.base_allocator;
        re.arena.deinit();
        gpa.destroy(re.arena);
        re.* = undefined;
        re.arena = &deinitialized_arena;
    }

    /// Whether `deinit` has run on this variable (the poison it leaves).
    fn isDeinitialized(re: *const Regexp) bool {
        return re.arena == &deinitialized_arena;
    }

    /// The length Go pads submatch results to: `2*(numSubexp+1)`. This can
    /// exceed the program's capture slots when a capturing group is compiled
    /// away (e.g. `(a){0}`); the extra trailing slots stay -1, exactly like
    /// Go's `pad`.
    fn padLen(re: *const Regexp) usize {
        return (re.num_subexp + 1) * 2;
    }

    /// The single entry point every search goes through, Go's
    /// `(*Regexp).find`: find the leftmost match in `input` starting at
    /// byte offset `pos`, writing its submatch offsets into `caps` (whose
    /// length, 0 up to `padLen`, bounds how many are recorded; -1 when
    /// unset). Returns whether there was a match; `caps` is meaningful only
    /// then. Engine storage comes from `storage`.
    ///
    /// Like Go it first rejects inputs shorter than any match. Then, a
    /// port-specific shortcut: a plain literal regexp (see `literal`) needs
    /// no engine when at most the whole-match slots are wanted — the match
    /// is the literal's next occurrence.
    fn findAt(re: *const Regexp, storage: Storage, input: []const u8, pos: usize, caps: []i64) ExecError!bool {
        if (input.len < re.min_input_len) return false;
        if (caps.len <= 2 and re.literal and re.engine.mode == .auto) {
            const a = &re.engine.accel;
            const start = pos + (search.prefixIndexAnchored(input[pos..], a.prefix, a.prefix_anchor) orelse return false);
            if (caps.len == 2) {
                caps[0] = @intCast(start);
                caps[1] = @intCast(start + a.prefix.len);
            }
            return true;
        }
        switch (storage) {
            .scratch => |scratch| return exec.executeReuse(scratch, &re.engine, .{ .s = input }, pos, caps),
            .temporary => |allocator| {
                var scratch = Scratch.init(allocator);
                defer scratch.deinit();
                return exec.executeReuse(&scratch, &re.engine, .{ .s = input }, pos, caps);
            },
        }
    }

    /// Where `findAt` gets engine storage: a caller's `Scratch` (the
    /// `*Scratch` API and the find-all loops), or a temporary one from an
    /// allocator (the allocating API), set up only if an engine runs.
    const Storage = union(enum) {
        scratch: *Scratch,
        temporary: std.mem.Allocator,
    };

    fn findIndexIn(re: *const Regexp, storage: Storage, input: []const u8) ExecError!?Match {
        var caps: [2]i64 = .{ -1, -1 };
        if (!try re.findAt(storage, input, 0, &caps)) return null;
        return Match{ .start = @intCast(caps[0]), .end = @intCast(caps[1]) };
    }

    // --- introspection ---

    /// The source text the regexp was compiled from.
    pub fn string(re: *const Regexp) []const u8 {
        return re.expr;
    }

    /// Number of parenthesized subexpressions.
    pub fn numSubexp(re: *const Regexp) usize {
        return re.num_subexp;
    }

    /// Names of the capturing groups; `subexpNames()[0]` is always "".
    pub fn subexpNames(re: *const Regexp) []const []const u8 {
        return re.subexp_names;
    }

    /// Index of the first subexpression with the given name, or null.
    pub fn subexpIndex(re: *const Regexp, name: []const u8) ?usize {
        if (name.len == 0) return null;
        for (re.subexp_names, 0..) |s, i| {
            if (std.mem.eql(u8, name, s)) return i;
        }
        return null;
    }

    /// A literal string that must begin any match, and whether it is the whole
    /// regexp.
    pub fn literalPrefix(re: *const Regexp) LiteralPrefix {
        return .{ .prefix = re.prefix, .complete = re.prefix_complete };
    }

    /// Switch to leftmost-longest (POSIX) matching for future searches
    /// (Go's `Longest`). This mutates the `Regexp`: call it before the
    /// regexp is shared, never concurrently with a search on it.
    pub fn setLongest(re: *Regexp) void {
        re.engine.longest = true;
    }

    // --- boolean match ---

    /// Reports whether `input` contains any match.
    pub fn match(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!bool {
        return re.findAt(.{ .temporary = allocator }, input, 0, &.{});
    }

    /// Alias of `match` (Go distinguishes `[]byte` and `string`; here both are
    /// `[]const u8`).
    pub fn matchString(re: *const Regexp, allocator: std.mem.Allocator, s: []const u8) ExecError!bool {
        return re.match(allocator, s);
    }

    /// Like `match`, but reuses a caller-owned `Scratch` instead of allocating
    /// per call. Allocate one `Scratch` (`Scratch.init(gpa)` / `deinit`) and
    /// reuse it across many matches on the same compiled `Regexp`; after it has
    /// warmed up, each call does zero heap allocation. Single-threaded: do not
    /// share one `Scratch` between concurrent matches.
    pub fn matchScratch(re: *const Regexp, scratch: *Scratch, input: []const u8) ExecError!bool {
        return re.findAt(.{ .scratch = scratch }, input, 0, &.{});
    }

    /// Like `findIndex`, but reuses a caller-owned `Scratch` instead of
    /// allocating per call. See `matchScratch` for the reuse contract.
    pub fn findIndexScratch(re: *const Regexp, scratch: *Scratch, input: []const u8) ExecError!?Match {
        return re.findIndexIn(.{ .scratch = scratch }, input);
    }

    /// Like `findSubmatchIndex`, but reuses a caller-owned `Scratch`. The
    /// returned slice is owned by `scratch` and valid only until the next call
    /// that reuses it — copy it if you need to keep it. Do NOT free it. Null if
    /// there is no match.
    pub fn findSubmatchIndexScratch(re: *const Regexp, scratch: *Scratch, input: []const u8) ExecError!?[]i64 {
        const caps = try scratch.resultBuf(re.padLen());
        if (!try re.findAt(.{ .scratch = scratch }, input, 0, caps)) return null;
        return caps;
    }

    // --- find leftmost ---

    /// Leftmost match location, or null.
    pub fn findIndex(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!?Match {
        return re.findIndexIn(.{ .temporary = allocator }, input);
    }

    /// Text of the leftmost match (a sub-slice of `input`), or null.
    pub fn find(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!?[]const u8 {
        const m = (try re.findIndex(allocator, input)) orelse return null;
        return input[m.start..m.end];
    }

    // --- find with submatches ---

    /// Submatch byte offsets [start0,end0,start1,end1,...] (length
    /// `2*(numSubexp+1)`; -1 for groups that did not participate). Caller owns
    /// the returned slice. Null if there is no match.
    pub fn findSubmatchIndex(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!?[]i64 {
        if (input.len < re.min_input_len) return null; // skip the allocation
        const caps = try allocator.alloc(i64, re.padLen());
        errdefer allocator.free(caps);
        const matched = try re.findAt(.{ .temporary = allocator }, input, 0, caps);
        if (!matched) {
            allocator.free(caps);
            return null;
        }
        return caps;
    }

    /// Submatch texts (sub-slices of `input`; null for non-participating
    /// groups). Caller owns the outer slice. Null if there is no match.
    pub fn findSubmatch(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8) ExecError!?[]?[]const u8 {
        const caps = (try re.findSubmatchIndex(allocator, input)) orelse return null;
        defer allocator.free(caps);
        const out = try allocator.alloc(?[]const u8, caps.len / 2);
        submatchTexts(input, caps, out);
        return out;
    }

    // --- find all ---

    /// Iterator over successive non-overlapping matches, the engine behind
    /// `findAll*` and `split`. Mirrors Go 1.27's `Regexp.matches` (which backs
    /// Go's `All*` iterators and `FindAll*`), including the empty-match rule:
    /// an empty match abutting the previous match is skipped. The engine
    /// scratch is allocated once and reused for every match, so a long scan
    /// allocates nothing per match. Build one with `Regexp.matches` (owns its
    /// buffers; call `deinit`) or `Regexp.matchesScratch` (borrows them).
    ///
    /// Do not copy a `Matches` and keep using both copies: they share the
    /// offsets buffer and, for `matches`, either copy's `deinit` frees it.
    /// All fields are internal.
    pub const Matches = struct {
        re: *const Regexp,
        input: []const u8,
        /// Engine storage owned by the iterator (`matches`); unused when
        /// `borrowed` is set (`matchesScratch`).
        own: Scratch,
        borrowed: ?*Scratch = null,
        caps: []i64,
        pos: usize = 0,
        prev_match_end: i64 = -1,
        remaining: i64, // matches still to yield; < 0 means unlimited
        done: bool = false,

        /// Frees what the iterator owns. For `matchesScratch` iterators this
        /// is a no-op: every buffer belongs to the caller's `Scratch`.
        pub fn deinit(it: *Matches) void {
            if (it.borrowed == null) {
                it.own.allocator.free(it.caps);
                it.own.deinit();
            }
            it.* = undefined;
        }

        fn scratch(it: *Matches) *Scratch {
            return it.borrowed orelse &it.own;
        }

        /// The next match's submatch byte offsets, or null when exhausted.
        /// The slice is owned by the iterator and overwritten by the next
        /// call; copy it to keep it.
        pub fn next(it: *Matches) ExecError!?[]const i64 {
            const in = exec.Input{ .s = it.input };
            while (!it.done and it.pos <= it.input.len) {
                const matched = try it.re.findAt(.{ .scratch = it.scratch() }, it.input, it.pos, it.caps);
                if (!matched) break;
                var accept = true;
                if (it.caps[1] == @as(i64, @intCast(it.pos))) {
                    // Empty match: don't allow it right after a previous match.
                    if (it.caps[0] == it.prev_match_end) accept = false;
                    const w = in.step(it.pos).w;
                    if (w > 0) it.pos += w else it.pos = it.input.len + 1;
                } else {
                    it.pos = @intCast(it.caps[1]);
                }
                it.prev_match_end = it.caps[1];
                if (accept) {
                    if (it.remaining > 0) {
                        it.remaining -= 1;
                        if (it.remaining == 0) it.done = true;
                    }
                    return it.caps;
                }
            }
            it.done = true;
            return null;
        }
    };

    /// Iterate over at most `n` (n < 0: all) successive matches of `input`,
    /// each reported as submatch offsets of length `2*(numSubexp+1)` (-1 for
    /// groups that did not participate). Free the iterator with `deinit`.
    pub fn matches(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64) ExecError!Matches {
        return re.matchesN(allocator, input, n, re.padLen());
    }

    /// `matches` recording only the first `ncap` capture slots (2 when only
    /// the whole-match location is needed, like Go's `all` / `allIndex`).
    fn matchesN(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64, ncap: usize) ExecError!Matches {
        const caps = try allocator.alloc(i64, ncap);
        return .{
            .re = re,
            .input = input,
            .own = Scratch.init(allocator),
            .caps = caps,
            .remaining = n,
            .done = n == 0,
        };
    }

    /// Like `matches`, but borrows all storage — engine buffers and the
    /// yielded offsets — from a caller-owned `Scratch`, so a warmed-up loop
    /// of scans allocates nothing. The iterator and the slices it yields are
    /// valid until the next call that reuses `scratch` (including another
    /// `findSubmatchIndexScratch`); `deinit` is optional and frees nothing.
    ///
    /// No nesting on one `Scratch`: a second `matchesScratch` (or any other
    /// `*Scratch` call) on the same `scratch` while this iterator is still
    /// in use shares, and may reallocate, the buffer its offsets live in, so
    /// the outer loop reads clobbered or freed results. Give an inner loop
    /// its own `Scratch`, or use `matches`.
    pub fn matchesScratch(re: *const Regexp, scratch: *Scratch, input: []const u8, n: i64) ExecError!Matches {
        const caps = try scratch.resultBuf(re.padLen());
        return .{
            .re = re,
            .input = input,
            .own = undefined,
            .borrowed = scratch,
            .caps = caps,
            .remaining = n,
            .done = n == 0,
        };
    }

    /// Locations of all successive matches (n < 0: all). Caller owns the slice.
    /// Null if there are no matches.
    pub fn findAllIndex(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64) ExecError!?[]Match {
        var it = try re.matchesN(allocator, input, n, 2);
        defer it.deinit();
        var out: std.ArrayList(Match) = .empty;
        errdefer out.deinit(allocator);
        while (try it.next()) |m| {
            try out.append(allocator, .{ .start = @intCast(m[0]), .end = @intCast(m[1]) });
        }
        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Texts of all successive matches (sub-slices of `input`). Caller owns the
    /// outer slice. Null if there are no matches.
    pub fn findAll(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64) ExecError!?[][]const u8 {
        var it = try re.matchesN(allocator, input, n, 2);
        defer it.deinit();
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(allocator);
        while (try it.next()) |m| {
            try out.append(allocator, input[@intCast(m[0])..@intCast(m[1])]);
        }
        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Submatch offsets of all successive matches. Each inner slice has length
    /// `2*(numSubexp+1)`. Caller owns every inner slice and the outer slice;
    /// free with `freeAllSubmatchIndex`. Null if there are no matches.
    pub fn findAllSubmatchIndex(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64) ExecError!?[][]i64 {
        var it = try re.matches(allocator, input, n);
        defer it.deinit();
        var out: std.ArrayList([]i64) = .empty;
        errdefer {
            for (out.items) |c| allocator.free(c);
            out.deinit(allocator);
        }
        while (try it.next()) |m| {
            const copy = try allocator.dupe(i64, m);
            errdefer allocator.free(copy);
            try out.append(allocator, copy);
        }
        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Frees the result of `findAllSubmatchIndex`.
    pub fn freeAllSubmatchIndex(allocator: std.mem.Allocator, x: [][]i64) void {
        for (x) |c| allocator.free(c);
        allocator.free(x);
    }

    /// Submatch texts of all successive matches (Go's `FindAllSubmatch`):
    /// one inner slice of length `numSubexp+1` per match, whose elements are
    /// sub-slices of `input` (null for groups that did not participate).
    /// Caller owns every inner slice and the outer slice; free with
    /// `freeAllSubmatch`. Null if there are no matches.
    pub fn findAllSubmatch(re: *const Regexp, allocator: std.mem.Allocator, input: []const u8, n: i64) ExecError!?[][]?[]const u8 {
        var it = try re.matches(allocator, input, n);
        defer it.deinit();
        var out: std.ArrayList([]?[]const u8) = .empty;
        errdefer {
            for (out.items) |c| allocator.free(c);
            out.deinit(allocator);
        }
        while (try it.next()) |m| {
            const texts = try allocator.alloc(?[]const u8, m.len / 2);
            errdefer allocator.free(texts);
            submatchTexts(input, m, texts);
            try out.append(allocator, texts);
        }
        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Frees the result of `findAllSubmatch`; the texts themselves point
    /// into the input and are not freed.
    pub fn freeAllSubmatch(allocator: std.mem.Allocator, x: [][]?[]const u8) void {
        for (x) |c| allocator.free(c);
        allocator.free(x);
    }

    // --- replace ---

    /// Replace every match with `repl`, expanding `$1` / `${name}` references
    /// (see `expand`). Caller owns the result.
    pub fn replaceAllString(re: *const Regexp, allocator: std.mem.Allocator, src: []const u8, repl: []const u8) ExecError![]u8 {
        const ncap: usize = if (std.mem.indexOfScalar(u8, repl, '$') != null) re.padLen() else 2;
        const Ctx = struct { re: *const Regexp, repl: []const u8 };
        return re.replaceAllCore(allocator, src, ncap, Ctx{ .re = re, .repl = repl }, struct {
            fn f(ctx: Ctx, al: std.mem.Allocator, buf: *std.ArrayList(u8), m: []const i64, source: []const u8) ExecError!void {
                try ctx.re.expandInto(al, buf, ctx.repl, source, m);
            }
        }.f);
    }

    /// Replace every match with `repl` literally (no `$` expansion).
    pub fn replaceAllLiteralString(re: *const Regexp, allocator: std.mem.Allocator, src: []const u8, repl: []const u8) ExecError![]u8 {
        const Ctx = struct { repl: []const u8 };
        return re.replaceAllCore(allocator, src, 2, Ctx{ .repl = repl }, struct {
            fn f(ctx: Ctx, al: std.mem.Allocator, buf: *std.ArrayList(u8), m: []const i64, source: []const u8) ExecError!void {
                _ = m;
                _ = source;
                try buf.appendSlice(al, ctx.repl);
            }
        }.f);
    }

    /// Replace every match with the text `func` appends to `out` (Go's
    /// `ReplaceAllFunc` / `ReplaceAllStringFunc`). `func` receives `ctx`,
    /// `allocator`, the output buffer and the matched text (a sub-slice of
    /// `src`); it appends the replacement with `out.appendSlice(allocator,
    /// ...)` / `out.print(allocator, ...)` and may use `allocator` for
    /// temporary memory of its own, freeing it before it returns. An error
    /// from `func` aborts the replacement: the partial output is freed and
    /// the error returned. Caller owns the result.
    pub fn replaceAllFunc(
        re: *const Regexp,
        allocator: std.mem.Allocator,
        src: []const u8,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx), std.mem.Allocator, *std.ArrayList(u8), []const u8) ExecError!void,
    ) ExecError![]u8 {
        const Ctx = struct { inner: @TypeOf(ctx) };
        return re.replaceAllCore(allocator, src, 2, Ctx{ .inner = ctx }, struct {
            fn f(c: Ctx, al: std.mem.Allocator, buf: *std.ArrayList(u8), m: []const i64, source: []const u8) ExecError!void {
                try func(c.inner, al, buf, source[@intCast(m[0])..@intCast(m[1])]);
            }
        }.f);
    }

    /// Replace every match with the slice `func` returns for the matched
    /// text. Kept for compatibility; prefer `replaceAllFunc`.
    ///
    /// Lifetime rule: the returned slice is copied into the output as soon
    /// as `func` returns, so it only has to stay valid until then. But
    /// `func` cannot fail, gets no allocator, and the library never frees
    /// what it returns: return a literal, a sub-slice of the match, or
    /// memory `ctx` owns and frees. Text built per match (upper-casing,
    /// say) needs `replaceAllFunc`.
    pub fn replaceAllStringFunc(
        re: *const Regexp,
        allocator: std.mem.Allocator,
        src: []const u8,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx), []const u8) []const u8,
    ) ExecError![]u8 {
        return re.replaceAllFunc(allocator, src, ctx, struct {
            fn f(c: @TypeOf(ctx), al: std.mem.Allocator, out: *std.ArrayList(u8), matched: []const u8) ExecError!void {
                try out.appendSlice(al, func(c, matched));
            }
        }.f);
    }

    fn replaceAllCore(
        re: *const Regexp,
        allocator: std.mem.Allocator,
        src: []const u8,
        ncap: usize,
        ctx: anytype,
        comptime replFn: fn (@TypeOf(ctx), std.mem.Allocator, *std.ArrayList(u8), []const i64, []const u8) ExecError!void,
    ) ExecError![]u8 {
        var last_match_end: usize = 0;
        var search_pos: usize = 0;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        const end_pos = src.len;
        const caps = try allocator.alloc(i64, ncap);
        defer allocator.free(caps);
        // One scratch for the whole loop: like Go's pooled machine, no
        // per-match engine allocation.
        var scratch = Scratch.init(allocator);
        defer scratch.deinit();
        const in = exec.Input{ .s = src };

        while (search_pos <= end_pos) {
            const matched = try re.findAt(.{ .scratch = &scratch }, src, search_pos, caps);
            if (!matched) break;
            const a0: usize = @intCast(caps[0]);
            const a1: usize = @intCast(caps[1]);

            try buf.appendSlice(allocator, src[last_match_end..a0]);
            // Skip the replacement for an empty match right after another match.
            if (a1 > last_match_end or a0 == 0) {
                try replFn(ctx, allocator, &buf, caps, src);
            }
            last_match_end = a1;

            const w = in.step(search_pos).w;
            if (search_pos + w > a1) {
                search_pos += w;
            } else if (search_pos + 1 > a1) {
                search_pos += 1;
            } else {
                search_pos = a1;
            }
        }
        try buf.appendSlice(allocator, src[last_match_end..]);
        return try buf.toOwnedSlice(allocator);
    }

    /// Append `template` to `buf`, expanding `$name` / `${name}` / `$1`
    /// references using `match` (submatch offsets into `src`). Mirrors Go's
    /// `expand`.
    pub fn expand(re: *const Regexp, allocator: std.mem.Allocator, buf: *std.ArrayList(u8), template: []const u8, src: []const u8, m: []const i64) ExecError!void {
        return re.expandInto(allocator, buf, template, src, m);
    }

    fn expandInto(re: *const Regexp, allocator: std.mem.Allocator, dst: *std.ArrayList(u8), template0: []const u8, src: []const u8, m: []const i64) ExecError!void {
        var template = template0;
        while (template.len > 0) {
            const dollar = std.mem.indexOfScalar(u8, template, '$') orelse break;
            try dst.appendSlice(allocator, template[0..dollar]);
            template = template[dollar + 1 ..];
            if (template.len > 0 and template[0] == '$') {
                try dst.append(allocator, '$');
                template = template[1..];
                continue;
            }
            const ext = extract(template);
            if (!ext.ok) {
                // Malformed: emit a literal '$'.
                try dst.append(allocator, '$');
                continue;
            }
            template = ext.rest;
            if (ext.num >= 0) {
                const num: usize = @intCast(ext.num);
                if (2 * num + 1 < m.len and m[2 * num] >= 0) {
                    try dst.appendSlice(allocator, src[@intCast(m[2 * num])..@intCast(m[2 * num + 1])]);
                }
            } else {
                for (re.subexp_names, 0..) |namei, i| {
                    if (std.mem.eql(u8, ext.name, namei) and 2 * i + 1 < m.len and m[2 * i] >= 0) {
                        try dst.appendSlice(allocator, src[@intCast(m[2 * i])..@intCast(m[2 * i + 1])]);
                        break;
                    }
                }
            }
        }
        try dst.appendSlice(allocator, template);
    }

    // --- split ---

    /// Split `src` around matches (Go's `Split`). n < 0: all pieces; n == 0:
    /// none (empty); n > 0: at most n pieces. Caller owns the outer slice; the
    /// pieces are sub-slices of `src`.
    pub fn split(re: *const Regexp, allocator: std.mem.Allocator, src: []const u8, n: i64) ExecError!?[][]const u8 {
        if (n == 0) return null; // Go returns nil
        if (re.expr.len > 0 and src.len == 0) {
            const out = try allocator.alloc([]const u8, 1);
            out[0] = "";
            return out;
        }

        var it = try re.matchesN(allocator, src, n, 2);
        defer it.deinit();

        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(allocator);
        var beg: usize = 0;
        var end: usize = 0;
        while (try it.next()) |c| {
            if (n > 0 and out.items.len >= @as(usize, @intCast(n - 1))) break;
            end = @intCast(c[0]);
            // Skip a zero-length match (does not contribute a split point).
            if (c[1] != 0) try out.append(allocator, src[beg..end]);
            beg = @intCast(c[1]);
        }
        // Append the trailing piece, unless the last match ended the string.
        if (end != src.len) try out.append(allocator, src[beg..]);
        return try out.toOwnedSlice(allocator);
    }
};

/// Submatch offsets to texts: `out[k]` is `input[m[2k]..m[2k+1]]`, or null
/// for a group that did not participate.
fn submatchTexts(input: []const u8, m: []const i64, out: []?[]const u8) void {
    for (out, 0..) |*o, k| {
        o.* = if (m[2 * k] < 0 or m[2 * k + 1] < 0) null else input[@intCast(m[2 * k])..@intCast(m[2 * k + 1])];
    }
}

const Extracted = struct { name: []const u8, num: i64, rest: []const u8, ok: bool };

/// Parse a leading `name` or `{name}` from a `$`-template. Mirrors Go's
/// `extract`.
fn extract(str0: []const u8) Extracted {
    var none = Extracted{ .name = "", .num = -1, .rest = "", .ok = false };
    var str = str0;
    if (str.len == 0) return none;
    var brace = false;
    if (str[0] == '{') {
        brace = true;
        str = str[1..];
    }
    var i: usize = 0;
    while (i < str.len) {
        const n = std.unicode.utf8ByteSequenceLength(str[i]) catch break;
        if (i + n > str.len) break;
        const r = std.unicode.utf8Decode(str[i .. i + n]) catch break;
        if (!isLetterDigitUnderscore(r)) break;
        i += n;
    }
    if (i == 0) return none; // empty name is not okay
    const name = str[0..i];
    if (brace) {
        if (i >= str.len or str[i] != '}') return none; // missing closing brace
        i += 1;
    }
    // Parse as a number if it is all digits with no leading zero.
    var num: i64 = 0;
    var isnum = true;
    for (name) |c| {
        if (c < '0' or c > '9' or num >= 100_000_000) {
            isnum = false;
            break;
        }
        num = num * 10 + @as(i64, c - '0');
    }
    if (name.len > 1 and name[0] == '0') isnum = false;
    none.name = name;
    none.num = if (isnum) num else -1;
    none.rest = str[i..];
    none.ok = true;
    return none;
}

fn isLetterDigitUnderscore(r: u21) bool {
    // Matches Go's extract: unicode.IsLetter(r) || unicode.IsDigit(r) || '_'.
    return r == '_' or unicode.isLetterOrDigit(r);
}

// --- compilation ---

fn compileInternal(gpa: std.mem.Allocator, expr: []const u8, mode: ast.Flags, longest: bool) ParseError!Regexp {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const al = arena.allocator();

    const expr_owned = try al.dupe(u8, expr);
    const re_ast = try parse.parse(al, expr_owned, mode);
    const max_cap = re_ast.maxCap();

    const names = try al.alloc([]const u8, @intCast(max_cap + 1));
    for (names) |*nm| nm.* = "";
    re_ast.capNamesInto(names);

    const simplified = try simplify.simplify(al, re_ast);
    const p = try al.create(prog.Prog);
    p.* = try compile_.compile(al, simplified);

    const cond = p.startCond();

    // Build the one-pass program if the regexp qualifies (anchored,
    // unambiguous). It carries its own prefix (Go's onePassPrefix).
    const op_prog: ?*const onepass.OnePassProg = blk: {
        if (try onepass.compileOnePass(gpa, al, p)) |opp| {
            const ptr = try al.create(onepass.OnePassProg);
            ptr.* = opp;
            break :blk ptr;
        }
        break :blk null;
    };

    // The scan prefix for the Pike VM and bitstate engines. Go computes
    // Prog.prefix only for non-one-pass regexps; for one-pass ones it is
    // always empty anyway (their programs start with \A), so computing it
    // unconditionally keeps every engine runnable on every regexp.
    const pfx = try p.prefix(al);

    // With no literal prefix, a small set of possible first bytes still lets
    // the Pike VM / bitstate engines skip ahead (see exec.Accel.first_bytes).
    // Anchored programs never scan.
    var first_bytes: []const u8 = "";
    if (pfx.str.len == 0 and cond != prog.impossible and (cond & prog.empty_begin_text) == 0) {
        if (try firstBytes(gpa, al, p)) |fb| first_bytes = fb;
    }

    return Regexp{
        .base_allocator = gpa,
        .arena = arena,
        .expr = expr_owned,
        .prog = p,
        .num_subexp = @intCast(max_cap),
        .subexp_names = names,
        .min_input_len = minInputLen(simplified),
        .prefix = if (op_prog) |op| op.prefix else pfx.str,
        .prefix_complete = if (op_prog) |op| op.prefix_complete else pfx.complete,
        .literal = pfx.complete and !pfx.lossy and op_prog == null and max_cap == 0 and cond == 0,
        .first_bytes = first_bytes,
        .onepass = op_prog,
        .engine = .{
            .prog = p,
            .onepass = op_prog,
            .cond = cond,
            .longest = longest,
            .accel = .{
                .prefix = pfx.str,
                .prefix_anchor = search.prefixAnchor(pfx.str),
                .prefix_rune = if (pfx.str.len > 0) (exec.Input{ .s = pfx.str }).step(0).r else -1,
                .first_bytes = if (first_bytes.len > 0) search.ByteSet.init(first_bytes) else .{},
            },
        },
    };
}

/// Max size of the accelerated first-byte set (the SIMD scan in search.zig
/// handles up to this many bytes at flat cost; wider sets stop filtering).
const max_first_bytes = search.max_first_bytes;

/// The set of bytes that can begin a match, computed from the epsilon-closure
/// of the program start. Returns null (no acceleration) when the pattern can
/// match empty, can start with a non-ASCII rune or a wide class, or when a
/// case-fold cycle leaves ASCII (e.g. `(?i)k` also matches U+212A). Every
/// zero-width assertion is treated as satisfiable, so the set is a superset of
/// the true first bytes — skipping other bytes can never skip a match.
fn firstBytes(gpa: std.mem.Allocator, al: std.mem.Allocator, p: *const prog.Prog) !?[]const u8 {
    const seen = try gpa.alloc(bool, p.insts.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var set: [0x80]bool = @splat(false);

    try stack.append(gpa, p.start);
    while (stack.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        const i = &p.insts[pc];
        switch (i.op) {
            .fail => {},
            .match => return null, // matches empty: every position is viable
            .nop, .capture, .empty_width => try stack.append(gpa, i.out),
            .alt, .alt_match => {
                try stack.append(gpa, i.out);
                try stack.append(gpa, i.arg);
            },
            .rune_any, .rune_any_not_nl => return null,
            .rune1 => {
                // The engines compare rune1 against runes[0] directly (no
                // folding), so only that rune can begin the match here.
                if (i.runes[0] >= 0x80) return null;
                set[i.runes[0]] = true;
            },
            .rune => {
                if (i.runes.len == 0) continue; // matches nothing
                if (i.runes.len == 1) {
                    // Single rune; FoldCase makes it match its whole fold cycle.
                    const r0 = i.runes[0];
                    if (r0 >= 0x80) return null;
                    set[r0] = true;
                    if ((@as(ast.Flags, @intCast(i.arg)) & ast.FoldCase) != 0) {
                        var r1 = unicode.simpleFold(r0);
                        while (r1 != r0) : (r1 = unicode.simpleFold(r1)) {
                            if (r1 >= 0x80) return null;
                            set[r1] = true;
                        }
                    }
                } else {
                    var j: usize = 0;
                    while (j < i.runes.len) : (j += 2) {
                        const hi = i.runes[j + 1];
                        if (hi >= 0x80) return null;
                        var b = i.runes[j];
                        while (b <= hi) : (b += 1) set[b] = true;
                    }
                }
            },
        }
    }

    var buf: [max_first_bytes]u8 = undefined;
    var n: usize = 0;
    for (set, 0..) |on, b| {
        if (!on) continue;
        if (n == max_first_bytes) return null;
        buf[n] = @intCast(b);
        n += 1;
    }
    if (n == 0) return null;
    return try al.dupe(u8, buf[0..n]);
}

/// Compile `expr` with Perl (leftmost-first) semantics.
pub fn compile(gpa: std.mem.Allocator, expr: []const u8) ParseError!Regexp {
    return compileInternal(gpa, expr, ast.Perl, false);
}

/// Compile `expr` with POSIX ERE syntax and leftmost-longest semantics.
pub fn compilePOSIX(gpa: std.mem.Allocator, expr: []const u8) ParseError!Regexp {
    return compileInternal(gpa, expr, ast.POSIX, true);
}

/// Like `compile` but panics if the pattern cannot be compiled, with Go's
/// message shape: ``regexp: Compile(`a(`): error parsing regexp: missing
/// closing )``. Go also appends the offending fragment of the pattern
/// (``: `a(` ``), which the Zig error set does not carry, so it is omitted.
/// Running out of memory panics with `...: out of memory` instead.
pub fn mustCompile(gpa: std.mem.Allocator, expr: []const u8) Regexp {
    return compile(gpa, expr) catch |e| compilePanic("Compile", expr, e);
}

/// Like `compilePOSIX` but panics if the pattern cannot be compiled (Go's
/// `MustCompilePOSIX`); see `mustCompile` for the message.
pub fn mustCompilePOSIX(gpa: std.mem.Allocator, expr: []const u8) Regexp {
    return compilePOSIX(gpa, expr) catch |e| compilePanic("CompilePOSIX", expr, e);
}

fn compilePanic(func: []const u8, expr: []const u8, err: ParseError) noreturn {
    std.debug.panic("{f}", .{CompileFailure{ .func = func, .expr = expr, .err = err }});
}

/// The `mustCompile` / `mustCompilePOSIX` panic message.
const CompileFailure = struct {
    func: []const u8,
    expr: []const u8,
    err: ParseError,

    pub fn format(f: CompileFailure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const what = if (f.err == error.OutOfMemory) "" else "error parsing regexp: ";
        try w.print("regexp: {s}({f}): {s}{s}", .{ f.func, GoQuote{ .s = f.expr }, what, errorString(f.err) });
    }
};

/// The message text of a compile error. For every parse error it is Go's
/// `syntax.ErrorCode` string (e.g. `error.MissingParen` gives "missing
/// closing )"); `error.OutOfMemory`, which has no Go counterpart, gives
/// "out of memory".
pub fn errorString(err: ParseError) []const u8 {
    return switch (err) {
        error.InvalidCharClass => "invalid character class",
        error.InvalidCharRange => "invalid character class range",
        error.InvalidEscape => "invalid escape sequence",
        error.InvalidNamedCapture => "invalid named capture",
        error.InvalidPerlOp => "invalid or unsupported Perl syntax",
        error.InvalidRepeatOp => "invalid nested repetition operator",
        error.InvalidRepeatSize => "invalid repeat count",
        error.InvalidUTF8 => "invalid UTF-8",
        error.MissingBracket => "missing closing ]",
        error.MissingParen => "missing closing )",
        error.MissingRepeatArgument => "missing argument to repetition operator",
        error.TrailingBackslash => "trailing backslash at end of expression",
        error.UnexpectedParen => "unexpected )",
        error.NestingDepth => "expression nests too deeply",
        error.TooLarge => "expression too large",
        error.OutOfMemory => "out of memory",
    };
}

/// Formats a pattern the way Go's `regexp.quote` does: in backquotes when
/// `strconv.CanBackquote` allows, otherwise double-quoted and escaped like
/// `strconv.Quote`. Used only for panic messages, so non-ASCII runes count
/// as printable except the C1 controls and U+FEFF, an approximation of
/// Go's `strconv.IsPrint`.
const GoQuote = struct {
    s: []const u8,

    pub fn format(q: GoQuote, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (canBackquote(q.s)) return w.print("`{s}`", .{q.s});
        try w.writeByte('"');
        var i: usize = 0;
        while (i < q.s.len) {
            const d = decodeRune(q.s[i..]);
            const bytes = q.s[i .. i + d.width];
            i += d.width;
            const r = d.rune orelse {
                try w.print("\\x{x:0>2}", .{bytes[0]});
                continue;
            };
            switch (r) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                0x07 => try w.writeAll("\\a"),
                0x08 => try w.writeAll("\\b"),
                0x0C => try w.writeAll("\\f"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x0B => try w.writeAll("\\v"),
                0x00...0x06, 0x0E...0x1F, 0x7F => try w.print("\\x{x:0>2}", .{r}),
                0x80...0x9F, 0xFEFF => try w.print("\\u{x:0>4}", .{r}),
                else => try w.writeAll(bytes),
            }
        }
        try w.writeByte('"');
    }

    /// Go's `strconv.CanBackquote`.
    fn canBackquote(s: []const u8) bool {
        var i: usize = 0;
        while (i < s.len) {
            const d = decodeRune(s[i..]);
            i += d.width;
            const r = d.rune orelse return false;
            if (d.width > 1) {
                if (r == 0xFEFF) return false;
                continue;
            }
            if ((r < ' ' and r != '\t') or r == '`' or r == 0x7F) return false;
        }
        return true;
    }

    /// The UTF-8 rune at the start of `s`, or null (width 1) for an invalid
    /// byte.
    fn decodeRune(s: []const u8) struct { rune: ?u21, width: usize } {
        const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return .{ .rune = null, .width = 1 };
        if (n > s.len) return .{ .rune = null, .width = 1 };
        const r = std.unicode.utf8Decode(s[0..n]) catch return .{ .rune = null, .width = 1 };
        return .{ .rune = r, .width = n };
    }
};

/// Go's package-level `regexp.MatchString` / `Match`: compile `pattern`,
/// report whether `input` contains a match, and free the compiled regexp.
/// `gpa` backs both the compilation and the search. To match one pattern
/// repeatedly, `compile` it once instead.
pub fn match(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) ParseError!bool {
    var re = try compile(gpa, pattern);
    defer re.deinit();
    return re.match(gpa, input);
}

fn expectCompileFailure(want: []const u8, func: []const u8, expr: []const u8, err: ParseError) !void {
    var buf: [256]u8 = undefined;
    const got = try std.fmt.bufPrint(&buf, "{f}", .{CompileFailure{ .func = func, .expr = expr, .err = err }});
    try std.testing.expectEqualStrings(want, got);
}

test "mustCompile panic message follows Go" {
    // Go: regexp: Compile(`a(`): error parsing regexp: missing closing ): `a(`
    try expectCompileFailure("regexp: Compile(`a(`): error parsing regexp: missing closing )", "Compile", "a(", error.MissingParen);
    // Go: regexp: Compile("a`("): error parsing regexp: missing closing ): `a`(`
    try expectCompileFailure("regexp: Compile(\"a`(\"): error parsing regexp: missing closing )", "Compile", "a`(", error.MissingParen);
    // Go's strconv.Quote of "\t\n\x00\xff\"\\".
    try expectCompileFailure(
        "regexp: CompilePOSIX(\"\\t\\n\\x00\\xff\\\"\\\\\"): error parsing regexp: invalid UTF-8",
        "CompilePOSIX",
        "\t\n\x00\xff\"\\",
        error.InvalidUTF8,
    );
    // A tab alone still allows backquotes; non-ASCII stays verbatim.
    try expectCompileFailure("regexp: Compile(`\té(`): error parsing regexp: missing closing )", "Compile", "\té(", error.MissingParen);
    try expectCompileFailure("regexp: Compile(`x`): out of memory", "Compile", "x", error.OutOfMemory);
}

test "deinit poisons the Regexp against a second deinit" {
    var re = try compile(std.testing.allocator, "a+b");
    try std.testing.expect(!re.isDeinitialized());
    re.deinit();
    try std.testing.expect(re.isDeinitialized());
}

fn minInputLen(re: *const ast.Regexp) usize {
    switch (re.op) {
        .any_char, .any_char_not_nl, .char_class => return 1,
        .literal => {
            var l: usize = 0;
            for (re.runes) |r| {
                // An invalid input byte decodes to U+FFFD with width 1, so a
                // U+FFFD literal needs only 1 byte of input (matches Go).
                if (r == 0xFFFD) {
                    l += 1;
                } else {
                    l += std.unicode.utf8CodepointSequenceLength(r) catch 1;
                }
            }
            return l;
        },
        .capture, .plus => return minInputLen(re.sub[0]),
        .repeat => return @as(usize, @intCast(@max(re.min, 0))) * minInputLen(re.sub[0]),
        .concat => {
            var l: usize = 0;
            for (re.sub) |sub| l += minInputLen(sub);
            return l;
        },
        .alternate => {
            if (re.sub.len == 0) return 0;
            var l = minInputLen(re.sub[0]);
            for (re.sub[1..]) |sub| {
                const ln = minInputLen(sub);
                if (ln < l) l = ln;
            }
            return l;
        },
        else => return 0,
    }
}

/// Return `s` with all regular-expression metacharacters escaped. Caller owns
/// the result. Mirrors Go's `QuoteMeta`.
pub fn quoteMeta(allocator: std.mem.Allocator, s: []const u8) ExecError![]u8 {
    const special = "\\.+*?()|[]{}^$";
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, special, c) != null) {
            try buf.append(allocator, '\\');
        }
        try buf.append(allocator, c);
    }
    return try buf.toOwnedSlice(allocator);
}

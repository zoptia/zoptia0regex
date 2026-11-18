//! The differential-test driver shared by every corpus (`difftest.zig`,
//! `fuzztest.zig`, `longesttest.zig`, `bytestest.zig`).
//!
//! The corpora in `data/` are recorded from Go's `regexp` by the generators
//! in `tools/cmd/` (see `tools/internal/corpus` for the record format). Each
//! line is one (pattern, mode, input) case; this driver compiles the pattern
//! with the port in the same mode and requires, exactly as Go recorded:
//!
//! - the compile outcome, and for a failure Go's `syntax.ErrorCode` text
//!   (an `OutOfMemory` is never "the same error as Go" and fails the run);
//! - `ni`, the compiled program's instruction count (AST and program shape),
//!   mandatory for every accepted pattern;
//! - `literalPrefix()` (prefix bytes and the complete flag);
//! - `findSubmatchIndex`, `match`, `findIndex` and their `Scratch` variants;
//! - when the case carries the find-all family (`n`): `findAllSubmatchIndex`,
//!   `findAllIndex` and the `matchesScratch` iterator with limit `n`,
//!   `replaceAllString` with template `t`, and `split` with limit `n`.
//!
//! The corpus must end with its `{"count":N}` trailer, and N must equal
//! both the number of cases read and the count in `data/MANIFEST.json`, so a
//! truncated or stale corpus fails. Everything runs under
//! `std.testing.allocator`, so a leak fails the build too.

const std = @import("std");
const regex = @import("regex");

pub const Mode = enum { perl, longest, posix };

/// One corpus line. Defaults stand for fields the generator omits.
pub const Case = struct {
    p: []const u8,
    mode: Mode = .perl,
    err: []const u8 = "",
    ni: usize = 0,
    lp: []const u8 = "",
    /// "LEN:HEX" length and FNV-1a-64 of a literal prefix too long for `lp`.
    lph: []const u8 = "",
    lpc: bool = false,
    i: []const u8,
    m: ?[]const i64,
    n: ?i64 = null,
    t: []const u8 = "",
    all: ?[]const []const i64 = null,
    repl: []const u8 = "",
    split: ?[]const []const u8 = null,
};

pub const Manifest = struct {
    go_version: []const u8,
    unicode_version: []const u8,
    corpora: struct { bytes: usize, cases: usize, fuzz: usize, longest: usize },
};

pub const Corpus = enum { cases, fuzz, longest, bytes };

pub const Options = struct {
    corpus: Corpus,
    /// The corpus file contents.
    data: []const u8,
    /// `data/MANIFEST.json` contents.
    manifest: []const u8,
    /// Every accepted pattern's cases must carry the find-all family.
    require_all: bool,
};

/// What a case can disagree on.
const Kind = enum {
    compile_ok, // Go errored, the port compiled
    compile_err, // Go compiled, the port errored
    err_code,
    ni_missing,
    ni,
    literal_prefix,
    m,
    match,
    find_index,
    scratch,
    all_missing,
    all,
    all_index,
    matches_scratch,
    repl,
    split,
};

/// A compiled pattern, kept while consecutive lines share (pattern, mode).
const Compiled = struct {
    pattern: []u8,
    mode: Mode,
    result: union(enum) { ok: regex.Regexp, err: regex.ParseError },
    scratch: regex.Scratch,

    fn init(gpa: std.mem.Allocator, pattern: []const u8, mode: Mode) !Compiled {
        const owned = try gpa.dupe(u8, pattern);
        errdefer gpa.free(owned);
        const compiled = switch (mode) {
            .perl, .longest => regex.compile(gpa, owned),
            .posix => regex.compilePOSIX(gpa, owned),
        };
        var c: Compiled = .{
            .pattern = owned,
            .mode = mode,
            .result = undefined,
            .scratch = regex.Scratch.init(gpa),
        };
        if (compiled) |re| {
            c.result = .{ .ok = re };
            if (mode == .longest) c.result.ok.setLongest();
        } else |err| {
            if (err == error.OutOfMemory) return err;
            c.result = .{ .err = err };
        }
        return c;
    }

    fn deinit(c: *Compiled, gpa: std.mem.Allocator) void {
        switch (c.result) {
            .ok => |*re| re.deinit(),
            .err => {},
        }
        c.scratch.deinit();
        gpa.free(c.pattern);
    }
};

pub fn run(opts: Options) !void {
    const gpa = std.testing.allocator;

    const manifest = try std.json.parseFromSlice(Manifest, gpa, opts.manifest, .{});
    defer manifest.deinit();
    const want_count = switch (opts.corpus) {
        inline else => |tag| @field(manifest.value.corpora, @tagName(tag)),
    };

    var counts = std.enums.EnumArray(Kind, usize).initFill(0);
    var total: usize = 0;
    var passed: usize = 0;
    var trailer: ?usize = null;
    var shown: usize = 0;
    var cache: ?Compiled = null;
    defer if (cache) |*c| c.deinit(gpa);

    var lines = std.mem.splitScalar(u8, opts.data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (trailer != null) return error.DataAfterTrailer;
        if (std.mem.startsWith(u8, line, "{\"count\":")) {
            const t = try std.json.parseFromSlice(struct { count: usize }, gpa, line, .{});
            defer t.deinit();
            trailer = t.value.count;
            continue;
        }
        total += 1;
        const parsed = try std.json.parseFromSlice(Case, gpa, line, .{});
        defer parsed.deinit();
        const c = parsed.value;

        if (cache == null or cache.?.mode != c.mode or !std.mem.eql(u8, cache.?.pattern, c.p)) {
            if (cache) |*old| old.deinit(gpa);
            cache = null;
            cache = try Compiled.init(gpa, c.p, c.mode);
        }
        if (try checkCase(gpa, &cache.?, c, opts.require_all)) |kind| {
            counts.getPtr(kind).* += 1;
            if (shown < 25) {
                shown += 1;
                report(kind, c);
            }
        } else passed += 1;
    }

    std.debug.print("\n[{s}] total={d} passed={d} (go {s}, unicode {s})\n", .{ @tagName(opts.corpus), total, passed, manifest.value.go_version, manifest.value.unicode_version });
    var mismatches: usize = 0;
    for (std.enums.values(Kind)) |k| {
        if (counts.get(k) != 0) std.debug.print("  {s}: {d}\n", .{ @tagName(k), counts.get(k) });
        mismatches += counts.get(k);
    }
    if (mismatches != 0) {
        std.debug.print("{d} cases disagree with Go\n", .{mismatches});
        return error.MismatchesWithGo;
    }
    // A truncated corpus has no trailer; a stale one disagrees with the
    // manifest written alongside it.
    const count = trailer orelse {
        std.debug.print("corpus has no {{\"count\":N}} trailer (truncated?)\n", .{});
        return error.CorpusTruncated;
    };
    if (count != total or want_count != total or total == 0) {
        std.debug.print("read {d} cases; trailer says {d}, MANIFEST.json says {d}\n", .{ total, count, want_count });
        return error.CorpusCountMismatch;
    }
}

fn report(kind: Kind, c: Case) void {
    const max = 120;
    const p = c.p[0..@min(c.p.len, max)];
    const ellipsis = if (c.p.len > max) "..." else "";
    std.debug.print("MISMATCH[{s}] mode={s} /{f}{s}/ input=\"{f}\"\n   go: err=\"{s}\" ni={d} lp=\"{f}\" lpc={} m={?any}\n", .{
        @tagName(kind),         @tagName(c.mode),
        std.zig.fmtString(p),   ellipsis,
        std.zig.fmtString(c.i), c.err,
        c.ni,                   std.zig.fmtString(c.lp[0..@min(c.lp.len, max)]),
        c.lpc,                  c.m,
    });
}

fn eqOptInts(want: ?[]const i64, got: ?[]const i64) bool {
    if (want == null or got == null) return want == null and got == null;
    return std.mem.eql(i64, want.?, got.?);
}

/// Compares the port's literal prefix with the recorded one (verbatim, or
/// by length and FNV-1a-64 for long prefixes).
fn eqPrefix(c: Case, prefix: []const u8) !bool {
    if (c.lph.len == 0) return std.mem.eql(u8, c.lp, prefix);
    const colon = std.mem.indexOfScalar(u8, c.lph, ':') orelse return error.BadLiteralPrefixHash;
    const len = try std.fmt.parseInt(usize, c.lph[0..colon], 10);
    const hash = try std.fmt.parseInt(u64, c.lph[colon + 1 ..], 16);
    return prefix.len == len and std.hash.Fnv1a_64.hash(prefix) == hash;
}

/// Returns the first disagreement with Go, or null when the case passes.
/// Allocation failures propagate and fail the run.
fn checkCase(gpa: std.mem.Allocator, compiled: *Compiled, c: Case, require_all: bool) !?Kind {
    const re: *regex.Regexp = switch (compiled.result) {
        .err => |err| {
            if (c.err.len == 0) return .compile_err;
            // Running out of memory is a harness failure, never "errored
            // like Go"; every other error must carry Go's ErrorCode text.
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return if (std.mem.eql(u8, regex.errorString(err), c.err)) null else .err_code;
        },
        .ok => |*re| re,
    };
    if (c.err.len != 0) return .compile_ok;

    // Same AST shape as Go => same number of compiled instructions. Every
    // Go program has at least fail + match, so 0 means "not recorded".
    if (c.ni == 0) return .ni_missing;
    if (re.prog.insts.len != c.ni) return .ni;

    const lp = re.literalPrefix();
    if (!try eqPrefix(c, lp.prefix) or lp.complete != c.lpc) return .literal_prefix;

    {
        const got = try re.findSubmatchIndex(gpa, c.i);
        defer if (got) |g| gpa.free(g);
        if (!eqOptInts(c.m, got)) return .m;
    }
    if (try re.match(gpa, c.i) != (c.m != null)) return .match;
    if (!eqLocation(c.m, try re.findIndex(gpa, c.i))) return .find_index;

    const scratch = &compiled.scratch;
    if (try re.matchScratch(scratch, c.i) != (c.m != null)) return .scratch;
    if (!eqLocation(c.m, try re.findIndexScratch(scratch, c.i))) return .scratch;
    if (!eqOptInts(c.m, try re.findSubmatchIndexScratch(scratch, c.i))) return .scratch;

    const n = c.n orelse return if (require_all) .all_missing else null;
    return checkAll(gpa, re, scratch, c, n);
}

fn eqLocation(m: ?[]const i64, got: ?regex.Match) bool {
    if (m == null or got == null) return m == null and got == null;
    return m.?[0] == @as(i64, @intCast(got.?.start)) and m.?[1] == @as(i64, @intCast(got.?.end));
}

fn checkAll(gpa: std.mem.Allocator, re: *regex.Regexp, scratch: *regex.Scratch, c: Case, n: i64) !?Kind {
    {
        const got = try re.findAllSubmatchIndex(gpa, c.i, n);
        defer if (got) |g| regex.Regexp.freeAllSubmatchIndex(gpa, g);
        if (c.all == null or got == null) {
            if (c.all != null or got != null) return .all;
        } else {
            if (c.all.?.len != got.?.len) return .all;
            for (c.all.?, got.?) |w, g| if (!std.mem.eql(i64, w, g)) return .all;
        }
    }
    {
        const got = try re.findAllIndex(gpa, c.i, n);
        defer if (got) |g| gpa.free(g);
        const want_len = if (c.all) |a| a.len else 0;
        const got_len = if (got) |g| g.len else 0;
        if ((c.all == null) != (got == null) or want_len != got_len) return .all_index;
        for (0..got_len) |k| {
            if (!eqLocation(c.all.?[k], got.?[k])) return .all_index;
        }
    }
    {
        var it = try re.matchesScratch(scratch, c.i, n);
        defer it.deinit();
        var k: usize = 0;
        while (try it.next()) |m| : (k += 1) {
            const all = c.all orelse return .matches_scratch;
            if (k >= all.len or !std.mem.eql(i64, all[k], m)) return .matches_scratch;
        }
        if (k != (if (c.all) |a| a.len else 0)) return .matches_scratch;
    }
    {
        const got = try re.replaceAllString(gpa, c.i, c.t);
        defer gpa.free(got);
        if (!std.mem.eql(u8, c.repl, got)) return .repl;
    }
    {
        const got = try re.split(gpa, c.i, n);
        defer if (got) |g| gpa.free(g);
        if ((c.split == null) != (got == null)) return .split;
        if (got) |g| {
            if (c.split.?.len != g.len) return .split;
            for (c.split.?, g) |w, x| if (!std.mem.eql(u8, w, x)) return .split;
        }
    }
    return null;
}

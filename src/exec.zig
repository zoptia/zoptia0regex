//! The execution engines, faithfully porting Go's `regexp/exec.go` and
//! `backtrack.go`. `execute` dispatches exactly like Go: the one-pass engine
//! (see `onepass.zig`) for qualifying anchored regexps, the bitstate
//! backtracker for small programs/inputs, and the Pike VM (an NFA simulation
//! with submatch tracking) for everything else. All three produce identical
//! results; the fast engines exist purely for speed.
//!
//! Match priority is leftmost-first (RE2 / Perl semantics): `add` performs the
//! epsilon-closure in greedy-priority order, and in first-match mode `step`
//! cuts off all lower-priority threads once a match is found. Setting
//! `longest = true` switches to POSIX leftmost-longest.

const std = @import("std");
const prog = @import("prog.zig");
const unicode = @import("unicode.zig");
const onepass = @import("onepass.zig");

const Prog = prog.Prog;
const Inst = prog.Inst;
const EmptyOp = prog.EmptyOp;
const OnePassProg = onepass.OnePassProg;

const end_of_text: i32 = -1;

/// Max size of the accelerated first-byte set. The SIMD scan's cost grows
/// only slowly with the set size; past ~16 bytes the set stops *filtering*
/// (too many positions qualify) rather than costing too much to scan.
pub const max_first_bytes = 16;

/// Match-acceleration data computed at compile time (see `regexp.compileInternal`).
pub const Accel = struct {
    /// Literal string every match must start with ("" = none). For one-pass
    /// regexps this is Go's `onePassPrefix`; otherwise `Prog.prefix`.
    prefix: []const u8 = "",
    /// One-pass only: the pc to resume at after `prefix` has been consumed.
    prefix_end: u32 = 0,
    /// Offset of `prefix`'s rarest byte (see `prefixAnchor`), precomputed at
    /// compile time so the per-call search does not rescan the needle.
    prefix_anchor: u32 = 0,
    /// When `prefix` is empty: the (ASCII) bytes a match can start with
    /// (at most `max_first_bytes`), or empty when no such small set exists.
    /// A superset of the true first bytes, so skipping to the next
    /// occurrence can never skip a match.
    first_bytes: []const u8 = "",
};

fn inFirstBytes(set: []const u8, r: i32) bool {
    if (r < 0 or r > 0x7F) return false;
    const b: u8 = @intCast(r);
    for (set) |x| {
        if (x == b) return true;
    }
    return false;
}

/// Vectorized first-index-of-any-byte — the memchr2/…/memchr16 analogue used
/// by the first-byte prefilter. One portable implementation: `@Vector`
/// compiles to NEON on aarch64, SSE2 on baseline x86_64 (wider with
/// `-Dcpu=native` on AVX2 machines), and degrades to the scalar std search on
/// targets without SIMD registers.
fn indexOfAnyByte(haystack: []const u8, set: []const u8) ?usize {
    std.debug.assert(set.len >= 1 and set.len <= max_first_bytes);
    if (set.len == 1) return std.mem.indexOfScalar(u8, haystack, set[0]);
    const width = comptime std.simd.suggestVectorLength(u8) orelse
        return std.mem.indexOfAny(u8, haystack, set);
    const V = @Vector(width, u8);
    const Mask = std.meta.Int(.unsigned, width);

    var splats: [max_first_bytes]V = undefined;
    for (set, 0..) |b, k| splats[k] = @splat(b);

    var i: usize = 0;
    while (i + width <= haystack.len) : (i += width) {
        const chunk: V = haystack[i..][0..width].*;
        var mask: Mask = 0;
        for (splats[0..set.len]) |s| mask |= @as(Mask, @bitCast(chunk == s));
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < haystack.len) : (i += 1) {
        const c = haystack[i];
        for (set) |b| {
            if (c == b) return i;
        }
    }
    return null;
}

/// Heuristic byte-frequency ranks (higher = more common in typical text and
/// code). Only the relative order matters: `prefixIndex` anchors its scan on
/// the needle's lowest-ranked byte, the idea behind rust-memmem's rare-byte
/// heuristic — scanning for `-` or `@` false-starts far less often than
/// scanning for `a`.
const byte_rank: [256]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var r = [_]u8{15} ** 256;
    for (0..0x20) |c| r[c] = 3; // control bytes: rare
    r['\n'] = 180;
    r['\t'] = 120;
    r[' '] = 255;
    const order = "etaoinsrhldcumfpgwybvkxjqz"; // approximate English order
    for (order, 0..) |c, idx| {
        const common: u8 = 240 - @as(u8, @intCast(idx)) * 6;
        r[c] = common;
        r[std.ascii.toUpper(c)] = common / 3;
    }
    for ('0'..'9' + 1) |c| r[c] = 100;
    for (".,-_'\"()/:;=") |c| r[c] = 90;
    for (0x80..0x100) |c| r[c] = 30; // UTF-8 lead/continuation bytes
    break :blk r;
};

fn rarestByteOffset(needle: []const u8) usize {
    var best: usize = 0;
    for (needle, 0..) |b, i| {
        if (byte_rank[b] < byte_rank[needle[best]]) best = i;
    }
    return best;
}

/// The scan anchor for a literal prefix: the offset of its rarest byte.
/// Computed once at compile time (`regexp.compileInternal`) and carried in
/// `Accel.prefix_anchor`.
pub fn prefixAnchor(prefix: []const u8) u32 {
    if (prefix.len < 2) return 0;
    return @intCast(rarestByteOffset(prefix));
}

/// A lazily-evaluated pair of boundary runes, for checking zero-width
/// assertions. Mirrors Go's `lazyFlag`.
pub const LazyFlag = struct {
    v: u64,

    pub fn init(r1: i32, r2: i32) LazyFlag {
        const hi: u64 = @as(u32, @bitCast(r1));
        const lo: u64 = @as(u32, @bitCast(r2));
        return .{ .v = (hi << 32) | lo };
    }

    pub fn match(self: LazyFlag, op0: EmptyOp) bool {
        if (op0 == 0) return true;
        var op = op0;
        const r1: i32 = @bitCast(@as(u32, @truncate(self.v >> 32)));
        if (op & prog.empty_begin_line != 0) {
            if (r1 != '\n' and r1 >= 0) return false;
            op &= ~prog.empty_begin_line;
        }
        if (op & prog.empty_begin_text != 0) {
            if (r1 >= 0) return false;
            op &= ~prog.empty_begin_text;
        }
        if (op == 0) return true;
        const r2: i32 = @bitCast(@as(u32, @truncate(self.v)));
        if (op & prog.empty_end_line != 0) {
            if (r2 != '\n' and r2 >= 0) return false;
            op &= ~prog.empty_end_line;
        }
        if (op & prog.empty_end_text != 0) {
            if (r2 >= 0) return false;
            op &= ~prog.empty_end_text;
        }
        if (op == 0) return true;
        if (unicode.isWordChar(r1) != unicode.isWordChar(r2)) {
            op &= ~prog.empty_word_boundary;
        } else {
            op &= ~prog.empty_no_word_boundary;
        }
        return op == 0;
    }
};

/// Input over a byte slice. String and byte-slice inputs decode identically.
pub const Input = struct {
    s: []const u8,

    const Step = struct { r: i32, w: usize };

    /// Decode the rune at `pos`; returns `end_of_text` past the end. Invalid
    /// UTF-8 decodes to U+FFFD with width 1 (matching Go's decoder).
    pub fn step(self: Input, pos: usize) Step {
        if (pos >= self.s.len) return .{ .r = end_of_text, .w = 0 };
        const b = self.s[pos];
        if (b < 0x80) return .{ .r = b, .w = 1 }; // ASCII fast path
        const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .r = 0xFFFD, .w = 1 };
        if (pos + n > self.s.len) return .{ .r = 0xFFFD, .w = 1 };
        const r = std.unicode.utf8Decode(self.s[pos .. pos + n]) catch return .{ .r = 0xFFFD, .w = 1 };
        return .{ .r = @intCast(r), .w = n };
    }

    pub fn context(self: Input, pos: usize) LazyFlag {
        var r1: i32 = end_of_text;
        var r2: i32 = end_of_text;
        if (pos > 0 and pos <= self.s.len) r1 = decodeLastRune(self.s[0..pos]);
        if (pos < self.s.len) r2 = self.step(pos).r;
        return LazyFlag.init(r1, r2);
    }
};

/// Find the first occurrence of `needle` in `haystack`. Scans for the
/// needle's *rarest* byte with a vectorized search (`indexOfScalar`) and
/// verifies the rest around each hit — anchoring on the rarest byte (rust
/// memmem's heuristic) false-starts far less often than anchoring on the
/// first byte when the first byte is common. Like Go's bytes.Index, it
/// switches to Rabin-Karp when the anchor still produces too many false
/// starts (a periodic needle over a periodic haystack is otherwise O(n·m)).
fn prefixIndex(haystack: []const u8, needle: []const u8) ?usize {
    return prefixIndexAnchored(haystack, needle, prefixAnchor(needle));
}

fn prefixIndexAnchored(haystack: []const u8, needle: []const u8, anchor: usize) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len == 1) return std.mem.indexOfScalar(u8, haystack, needle[0]);
    if (haystack.len < needle.len) return null;
    const tail = needle.len - anchor; // needle bytes at/after the anchor
    var start: usize = 0; // candidate needle start
    var fails: usize = 0;
    while (start + needle.len <= haystack.len) {
        const found = std.mem.indexOfScalarPos(
            u8,
            haystack[0 .. haystack.len - tail + 1],
            start + anchor,
            needle[anchor],
        ) orelse return null;
        const at = found - anchor;
        if (std.mem.eql(u8, haystack[at .. at + needle.len], needle)) return at;
        start = at + 1;
        fails += 1;
        if (fails > (at + 16) / 8) { // Go's bytes.Index cutover shape
            if (indexRabinKarp(haystack[start..], needle)) |j| return start + j;
            return null;
        }
    }
    return null;
}

/// Rabin-Karp substring search, mirroring Go's `internal/bytealg`: worst-case
/// linear, used as `prefixIndex`'s fallback for pathological inputs.
fn indexRabinKarp(s: []const u8, sep: []const u8) ?usize {
    if (s.len < sep.len) return null;
    const prime_rk: u32 = 16777619;
    var hashsep: u32 = 0;
    for (sep) |b| hashsep = hashsep *% prime_rk +% b;
    var pow: u32 = 1;
    var sq: u32 = prime_rk;
    var i = sep.len;
    while (i > 0) : (i >>= 1) {
        if (i & 1 != 0) pow *%= sq;
        sq *%= sq;
    }
    var h: u32 = 0;
    for (s[0..sep.len]) |b| h = h *% prime_rk +% b;
    if (h == hashsep and std.mem.eql(u8, s[0..sep.len], sep)) return 0;
    var j = sep.len;
    while (j < s.len) {
        h *%= prime_rk;
        h +%= s[j];
        h -%= pow *% s[j - sep.len];
        j += 1;
        if (h == hashsep and std.mem.eql(u8, s[j - sep.len .. j], sep)) return j - sep.len;
    }
    return null;
}

/// Decode the final rune of `s`, returning U+FFFD on malformed trailing bytes.
fn decodeLastRune(s: []const u8) i32 {
    if (s.len == 0) return end_of_text;
    var start = s.len - 1;
    // Walk back over UTF-8 continuation bytes (0b10xxxxxx), at most 3.
    while (start > 0 and (s[start] & 0xC0) == 0x80 and s.len - start < 4) : (start -= 1) {}
    const n = std.unicode.utf8ByteSequenceLength(s[start]) catch return 0xFFFD;
    if (start + n != s.len) return 0xFFFD;
    const r = std.unicode.utf8Decode(s[start..]) catch return 0xFFFD;
    return @intCast(r);
}

const Thread = struct {
    pc: u32,
    cap: []i64,
};

const Entry = struct { pc: u32, t: ?*Thread };

const Queue = struct {
    sparse: []u32,
    dense: []Entry,
    n: usize = 0,
};

/// Reusable per-call storage for the Pike-VM and bitstate engines — the
/// equivalent of Go's per-`Regexp` `*machine` pool, which this port originally
/// omitted (it allocated a fresh `Machine` on every match). Allocate a `Scratch`
/// once and reuse it across many match calls on the same compiled `Regexp` so
/// steady-state matching does zero heap allocation: every buffer grows to a
/// high-water mark and is never shrunk, and threads stay pooled across runs.
///
/// Single-threaded: a `Scratch` carries no synchronisation and must not be used
/// by two matches concurrently. See `regexp.matchScratch`.
pub const Scratch = struct {
    allocator: std.mem.Allocator,

    // --- Pike VM ---
    s0: []u32 = &.{},
    s1: []u32 = &.{},
    dense0: []Entry = &.{},
    dense1: []Entry = &.{},
    matchcap: []i64 = &.{},
    pool: std.ArrayList(*Thread) = .empty,
    all_threads: std.ArrayList(*Thread) = .empty,
    pike_ninst: usize = 0, // capacity of s0/s1/dense0/dense1 (grow-only)
    thread_ncap: usize = 0, // exact cap-array length of pooled threads + matchcap

    // --- bitstate backtracker ---
    work: []i64 = &.{}, // working capture registers (grow-only)
    visited: []u32 = &.{}, // (pc,pos) visited bitmap (grow-only)
    jobs: std.ArrayList(Job) = .empty,

    // --- borrowed result buffer for findSubmatchIndexScratch ---
    result: []i64 = &.{},

    pub fn init(allocator: std.mem.Allocator) Scratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scratch) void {
        const a = self.allocator;
        for (self.all_threads.items) |t| {
            if (t.cap.len > 0) a.free(t.cap);
            a.destroy(t);
        }
        self.all_threads.deinit(a);
        self.pool.deinit(a);
        self.jobs.deinit(a);
        if (self.s0.len > 0) a.free(self.s0);
        if (self.s1.len > 0) a.free(self.s1);
        if (self.dense0.len > 0) a.free(self.dense0);
        if (self.dense1.len > 0) a.free(self.dense1);
        if (self.matchcap.len > 0) a.free(self.matchcap);
        if (self.work.len > 0) a.free(self.work);
        if (self.visited.len > 0) a.free(self.visited);
        if (self.result.len > 0) a.free(self.result);
        self.* = undefined;
    }

    /// Grow the Pike-VM buffers to fit `ninst` instructions and `ncap` capture
    /// slots. The sparse/dense buffers grow monotonically (oversized buffers are
    /// harmless — only `[0, ninst)`/`[0, q.n)` are ever touched). When `ncap`
    /// changes, the pooled threads (whose cap arrays are sized to the previous
    /// `ncap`) are discarded so fresh ones are allocated at the new size; a hot
    /// loop keeps `ncap` constant, so this fires only on the first call.
    fn ensurePike(self: *Scratch, ninst: usize, ncap: usize) !void {
        const a = self.allocator;
        if (ninst > self.pike_ninst) {
            if (self.s0.len > 0) a.free(self.s0);
            if (self.s1.len > 0) a.free(self.s1);
            if (self.dense0.len > 0) a.free(self.dense0);
            if (self.dense1.len > 0) a.free(self.dense1);
            self.s0 = try a.alloc(u32, ninst);
            self.s1 = try a.alloc(u32, ninst);
            self.dense0 = try a.alloc(Entry, ninst);
            self.dense1 = try a.alloc(Entry, ninst);
            self.pike_ninst = ninst;
        }
        if (ncap != self.thread_ncap) {
            for (self.all_threads.items) |t| {
                if (t.cap.len > 0) a.free(t.cap);
                a.destroy(t);
            }
            self.all_threads.clearRetainingCapacity();
            self.pool.clearRetainingCapacity();
            if (self.matchcap.len > 0) a.free(self.matchcap);
            self.matchcap = if (ncap > 0) try a.alloc(i64, ncap) else &.{};
            self.thread_ncap = ncap;
        }
    }

    /// Borrow bitstate work/visited buffers, growing each to a high-water mark
    /// and reslicing to the lengths this call needs. `visited` is a per-run set
    /// and is zeroed by the caller every run; only its allocation is reused.
    fn bitBufs(self: *Scratch, ncap: usize, visited_size: usize) !struct { work: []i64, visited: []u32 } {
        const a = self.allocator;
        if (ncap > self.work.len) {
            if (self.work.len > 0) a.free(self.work);
            self.work = try a.alloc(i64, ncap);
        }
        if (visited_size > self.visited.len) {
            if (self.visited.len > 0) a.free(self.visited);
            self.visited = try a.alloc(u32, visited_size);
        }
        return .{ .work = self.work[0..ncap], .visited = self.visited[0..visited_size] };
    }

    /// A scratch-owned result buffer of length `n`, grown to a high-water mark.
    /// The returned slice is valid only until the next call that reuses this
    /// scratch — see `regexp.findSubmatchIndexScratch`.
    pub fn resultBuf(self: *Scratch, n: usize) ![]i64 {
        if (n > self.result.len) {
            if (self.result.len > 0) self.allocator.free(self.result);
            self.result = try self.allocator.alloc(i64, n);
        }
        return self.result[0..n];
    }
};

const Machine = struct {
    scratch: *Scratch,
    p: *const Prog,
    longest: bool,
    cond: EmptyOp,
    ncap: usize,
    accel: Accel,
    prefix_rune: i32,
    q0: Queue,
    q1: Queue,
    matched: bool = false,
    matchcap: []i64,

    /// Build a Machine view over `scratch`. Buffers are borrowed from `scratch`
    /// (grown as needed); nothing here is freed at the end of a run — the
    /// scratch outlives the Machine. Sparse sets are deliberately NOT zeroed:
    /// the membership test in `add` is `sp < q.n and dense[sp].pc == pc`, which
    /// the dense cross-check makes sound against any stale/indeterminate
    /// `sparse[pc]` (the defining property of a sparse set — Go zeroes the
    /// buffer only because `make` does, never for correctness).
    fn init(scratch: *Scratch, p: *const Prog, longest: bool, cond: EmptyOp, accel: Accel, ncap: usize) !Machine {
        const ninst = p.insts.len;
        try scratch.ensurePike(ninst, ncap);
        var prune: i32 = -1;
        const prefix = accel.prefix;
        if (prefix.len > 0) {
            const n = std.unicode.utf8ByteSequenceLength(prefix[0]) catch 1;
            prune = if (n <= prefix.len)
                @intCast(std.unicode.utf8Decode(prefix[0..n]) catch 0xFFFD)
            else
                0xFFFD;
        }
        return .{
            .scratch = scratch,
            .p = p,
            .longest = longest,
            .cond = cond,
            .ncap = ncap,
            .accel = accel,
            .prefix_rune = prune,
            .q0 = .{ .sparse = scratch.s0, .dense = scratch.dense0 },
            .q1 = .{ .sparse = scratch.s1, .dense = scratch.dense1 },
            .matchcap = scratch.matchcap,
        };
    }

    fn alloc(m: *Machine, pc: u32) !*Thread {
        const sc = m.scratch;
        if (sc.pool.items.len > 0) {
            const t = sc.pool.pop().?;
            t.pc = pc;
            return t;
        }
        const t = try sc.allocator.create(Thread);
        t.cap = if (m.ncap > 0) try sc.allocator.alloc(i64, m.ncap) else &.{};
        t.pc = pc;
        try sc.all_threads.append(sc.allocator, t);
        // Ensure the free pool can always hold every thread without erroring.
        try sc.pool.ensureTotalCapacity(sc.allocator, sc.all_threads.items.len);
        return t;
    }

    inline fn free(m: *Machine, t: *Thread) void {
        m.scratch.pool.appendAssumeCapacity(t);
    }

    fn clearQueue(m: *Machine, q: *Queue) void {
        var i: usize = 0;
        while (i < q.n) : (i += 1) {
            if (q.dense[i].t) |t| m.free(t);
        }
        q.n = 0;
    }

    /// Add pc (and its epsilon-closure under `cond`) to queue `q`, threading
    /// `cap` through capture instructions. Returns the (possibly reusable)
    /// leftover thread. Mirrors Go's `machine.add`.
    fn add(m: *Machine, q: *Queue, pc_in: u32, pos: usize, cap: []i64, cond: *const LazyFlag, t_in: ?*Thread) !?*Thread {
        var pc = pc_in;
        var t = t_in;
        while (true) {
            if (pc == 0) return t;
            const sp = q.sparse[pc];
            if (sp < q.n and q.dense[sp].pc == pc) return t;

            const j = q.n;
            q.sparse[pc] = @intCast(j);
            q.dense[j] = .{ .pc = pc, .t = null };
            q.n += 1;

            const i = &m.p.insts[pc];
            switch (i.op) {
                .fail => return t,
                .alt, .alt_match => {
                    t = try m.add(q, i.out, pos, cap, cond, t);
                    pc = i.arg;
                    continue;
                },
                .empty_width => {
                    if (cond.match(@intCast(i.arg))) {
                        pc = i.out;
                        continue;
                    }
                    return t;
                },
                .nop => {
                    pc = i.out;
                    continue;
                },
                .capture => {
                    if (i.arg < cap.len) {
                        const opos = cap[i.arg];
                        cap[i.arg] = @intCast(pos);
                        _ = try m.add(q, i.out, pos, cap, cond, null);
                        cap[i.arg] = opos;
                        return t;
                    }
                    pc = i.out;
                    continue;
                },
                .match, .rune, .rune1, .rune_any, .rune_any_not_nl => {
                    var th: *Thread = undefined;
                    if (t) |existing| {
                        existing.pc = pc;
                        th = existing;
                    } else {
                        th = try m.alloc(pc);
                    }
                    if (cap.len > 0 and th.cap.ptr != cap.ptr) {
                        @memcpy(th.cap, cap);
                    }
                    q.dense[j].t = th;
                    return null;
                },
            }
        }
    }

    /// Run one step over `runq`, building `nextq` for the rune `c`.
    /// Mirrors Go's `machine.step`.
    fn step(m: *Machine, runq: *Queue, nextq: *Queue, pos: usize, next_pos: usize, c: i32, next_cond: *const LazyFlag) !void {
        const longest = m.longest;
        var j: usize = 0;
        while (j < runq.n) : (j += 1) {
            const t = runq.dense[j].t orelse continue;
            if (longest and m.matched and t.cap.len > 0 and m.matchcap[0] < t.cap[0]) {
                m.free(t);
                continue;
            }
            const i = &m.p.insts[t.pc];
            var add_it = false;
            switch (i.op) {
                .match => {
                    if (t.cap.len > 0 and (!longest or !m.matched or m.matchcap[1] < @as(i64, @intCast(pos)))) {
                        t.cap[1] = @intCast(pos);
                        @memcpy(m.matchcap, t.cap);
                    }
                    if (!longest) {
                        // First-match mode: cut off all lower-priority threads.
                        var k = j + 1;
                        while (k < runq.n) : (k += 1) {
                            if (runq.dense[k].t) |dt| m.free(dt);
                        }
                        runq.n = 0;
                    }
                    m.matched = true;
                },
                .rune => add_it = (c >= 0 and i.matchRune(@intCast(c))),
                .rune1 => add_it = (c == @as(i32, @intCast(i.runes[0]))),
                .rune_any => add_it = true,
                .rune_any_not_nl => add_it = (c != '\n'),
                else => unreachable,
            }
            var leftover: ?*Thread = t;
            if (add_it) {
                leftover = try m.add(nextq, i.out, next_pos, t.cap, next_cond, t);
            }
            if (leftover) |x| m.free(x);
        }
        runq.n = 0;
    }

    /// Run the machine over `input` starting at `pos`; returns whether a match
    /// was found, leaving the submatch positions in `m.matchcap`.
    /// Mirrors Go's `machine.match`.
    fn run(m: *Machine, input: Input, pos_in: usize) !bool {
        var pos = pos_in;
        if (m.cond == prog.impossible) return false;
        m.matched = false;
        for (m.matchcap) |*x| x.* = -1;

        var runq = &m.q0;
        var nextq = &m.q1;
        var r: i32 = end_of_text;
        var r1: i32 = end_of_text;
        var width: usize = 0;
        var width1: usize = 0;
        const s0 = input.step(pos);
        r = s0.r;
        width = s0.w;
        if (r != end_of_text) {
            const s1 = input.step(pos + width);
            r1 = s1.r;
            width1 = s1.w;
        }
        var flag: LazyFlag = if (pos == 0) LazyFlag.init(-1, r) else input.context(pos);

        while (true) {
            if (runq.n == 0) {
                if (m.cond & prog.empty_begin_text != 0 and pos != 0) break; // anchored, past start
                if (m.matched) break; // have match, done exploring
                // Literal-prefix acceleration: every match must start with the
                // prefix, so fast-forward to its next occurrence (memchr-class
                // substring search) instead of stepping the NFA at every byte.
                if (m.accel.prefix.len > 0 and r1 != m.prefix_rune and pos <= input.s.len) {
                    if (prefixIndexAnchored(input.s[pos..], m.accel.prefix, m.accel.prefix_anchor)) |adv| {
                        pos += adv;
                        const sa = input.step(pos);
                        r = sa.r;
                        width = sa.w;
                        const sb = input.step(pos + width);
                        r1 = sb.r;
                        width1 = sb.w;
                    } else break;
                } else if (m.accel.first_bytes.len > 0 and !inFirstBytes(m.accel.first_bytes, r) and pos <= input.s.len) {
                    // First-byte acceleration: no literal prefix, but every
                    // match starts with one of a few ASCII bytes (e.g. a
                    // case-insensitive literal or a small leading class), so
                    // scan ahead to the next candidate. Unlike the prefix
                    // path, the closure may pass zero-width assertions, so
                    // the boundary flag must be recomputed for the new pos.
                    if (indexOfAnyByte(input.s[pos..], m.accel.first_bytes)) |adv| {
                        if (adv > 0) {
                            pos += adv;
                            const sa = input.step(pos);
                            r = sa.r;
                            width = sa.w;
                            const sb = input.step(pos + width);
                            r1 = sb.r;
                            width1 = sb.w;
                            flag = input.context(pos);
                        }
                    } else break;
                }
            }
            if (!m.matched) {
                if (m.matchcap.len > 0) m.matchcap[0] = @intCast(pos);
                _ = try m.add(runq, m.p.start, pos, m.matchcap, &flag, null);
            }
            flag = LazyFlag.init(r, r1);
            try m.step(runq, nextq, pos, pos + width, r, &flag);
            if (width == 0) break;
            if (m.matchcap.len == 0 and m.matched) break; // match-only, any match will do
            pos += width;
            r = r1;
            width = width1;
            if (r != end_of_text) {
                const sc = input.step(pos + width);
                r1 = sc.r;
                width1 = sc.w;
            }
            const tmp = runq;
            runq = nextq;
            nextq = tmp;
        }
        m.clearQueue(nextq);
        return m.matched;
    }
};

// --- bitstate backtracker (Go's backtrack.go) ---
//
// For small programs and inputs, a backtracking search with a (pc, pos)
// visited bitmap is faster than the Pike VM while staying linear-time. This is
// the engine Go dispatches to for these cases; porting it closes the one
// remaining performance gap (small nested-quantifier patterns).

const max_backtrack_prog = 500; // only programs with <= this many insts
const max_backtrack_vector = 256 * 1024; // visited bitmap size cap, in bits
const visited_bits = 32;

const Job = struct { pc: u32, arg: bool, pos: i64 };

const BitState = struct {
    allocator: std.mem.Allocator,
    p: *const Prog,
    input: Input,
    longest: bool,
    end: usize,
    cap: []i64, // working capture registers
    matchcap: []i64, // best match captures (the result)
    jobs: *std.ArrayList(Job), // borrowed from Scratch, reused across calls
    visited: []u32,

    fn shouldVisit(b: *BitState, pc: u32, pos: i64) bool {
        const n: usize = @as(usize, pc) * (b.end + 1) + @as(usize, @intCast(pos));
        const word = n / visited_bits;
        const bit = @as(u32, 1) << @intCast(n & (visited_bits - 1));
        if (b.visited[word] & bit != 0) return false;
        b.visited[word] |= bit;
        return true;
    }

    fn push(b: *BitState, pc: u32, pos: i64, arg: bool) !void {
        if (b.p.insts[pc].op != .fail and (arg or b.shouldVisit(pc, pos))) {
            try b.jobs.append(b.allocator, .{ .pc = pc, .arg = arg, .pos = pos });
        }
    }

    fn tryBacktrack(b: *BitState, start_pc: u32, start_pos: i64) !bool {
        const longest = b.longest;
        try b.push(start_pc, start_pos, false);
        while (b.jobs.items.len > 0) {
            const j = b.jobs.pop().?;
            var pc = j.pc;
            var pos = j.pos;
            var arg = j.arg;
            var need_check = false; // first processing of a popped job skips the visit check
            process: while (true) {
                if (need_check and !b.shouldVisit(pc, pos)) break :process;
                need_check = true;
                const inst = &b.p.insts[pc];
                switch (inst.op) {
                    .fail => unreachable,
                    .alt => {
                        if (arg) {
                            arg = false;
                            pc = inst.arg;
                            continue :process;
                        }
                        try b.push(pc, pos, true); // revisit to try inst.arg later
                        pc = inst.out;
                        continue :process;
                    },
                    .alt_match => {
                        const oop = b.p.insts[inst.out].op;
                        if (oop == .rune or oop == .rune1 or oop == .rune_any or oop == .rune_any_not_nl) {
                            try b.push(inst.arg, pos, false);
                            pc = inst.arg;
                            pos = @intCast(b.end);
                            continue :process;
                        }
                        try b.push(inst.out, @intCast(b.end), false);
                        pc = inst.out;
                        continue :process;
                    },
                    .rune => {
                        const s = b.input.step(@intCast(pos));
                        if (s.r < 0 or !inst.matchRune(@intCast(s.r))) break :process;
                        pos += @intCast(s.w);
                        pc = inst.out;
                        continue :process;
                    },
                    .rune1 => {
                        const s = b.input.step(@intCast(pos));
                        if (s.r != @as(i32, @intCast(inst.runes[0]))) break :process;
                        pos += @intCast(s.w);
                        pc = inst.out;
                        continue :process;
                    },
                    .rune_any_not_nl => {
                        const s = b.input.step(@intCast(pos));
                        if (s.r == '\n' or s.r == end_of_text) break :process;
                        pos += @intCast(s.w);
                        pc = inst.out;
                        continue :process;
                    },
                    .rune_any => {
                        const s = b.input.step(@intCast(pos));
                        if (s.r == end_of_text) break :process;
                        pos += @intCast(s.w);
                        pc = inst.out;
                        continue :process;
                    },
                    .capture => {
                        if (arg) {
                            // Finished inst.out; restore the saved value.
                            b.cap[inst.arg] = pos;
                            break :process;
                        }
                        if (inst.arg < b.cap.len) {
                            try b.push(pc, b.cap[inst.arg], true); // come back to restore
                            b.cap[inst.arg] = pos;
                        }
                        pc = inst.out;
                        continue :process;
                    },
                    .empty_width => {
                        const flag = b.input.context(@intCast(pos));
                        if (!flag.match(@intCast(inst.arg))) break :process;
                        pc = inst.out;
                        continue :process;
                    },
                    .nop => {
                        pc = inst.out;
                        continue :process;
                    },
                    .match => {
                        if (b.cap.len == 0) return true;
                        if (b.cap.len > 1) b.cap[1] = pos;
                        const old = b.matchcap[1];
                        if (old == -1 or (longest and pos > 0 and pos > old)) {
                            @memcpy(b.matchcap, b.cap);
                        }
                        if (!longest) return true;
                        if (pos == @as(i64, @intCast(b.end))) return true;
                        break :process; // hope for a longer match
                    },
                }
            }
        }
        return longest and b.matchcap.len > 1 and b.matchcap[1] >= 0;
    }
};

fn backtrack(scratch: *Scratch, p: *const Prog, longest: bool, cond: EmptyOp, accel: Accel, input: Input, pos: usize, caps: []i64) !bool {
    if (cond == prog.impossible) return false;
    if (cond & prog.empty_begin_text != 0 and pos != 0) return false;

    const ninst = p.insts.len;
    const end = input.s.len;
    const visited_size = (ninst * (end + 1) + visited_bits - 1) / visited_bits;

    // Reuse work/visited from the scratch; only the allocation is amortised —
    // both are reset below, so no stale state carries between calls.
    const bufs = try scratch.bitBufs(caps.len, visited_size);
    const work = bufs.work;
    const visited = bufs.visited;
    @memset(work, -1);
    @memset(caps, -1);
    @memset(visited, 0);

    scratch.jobs.clearRetainingCapacity();
    var b = BitState{
        .allocator = scratch.allocator,
        .p = p,
        .input = input,
        .longest = longest,
        .end = end,
        .cap = work,
        .matchcap = caps,
        .visited = visited,
        .jobs = &scratch.jobs,
    };

    if (cond & prog.empty_begin_text != 0) {
        if (b.cap.len > 0) b.cap[0] = @intCast(pos);
        return try b.tryBacktrack(p.start, @intCast(pos));
    }

    // Unanchored: try each start position. The visited bitmap is shared across
    // calls (never cleared), so total work stays linear.
    var p_pos: i64 = @intCast(pos);
    var width: i64 = -1;
    const end_i: i64 = @intCast(end);
    while (p_pos <= end_i and width != 0) {
        if (accel.prefix.len > 0) {
            const adv = prefixIndexAnchored(input.s[@intCast(p_pos)..], accel.prefix, accel.prefix_anchor) orelse return false;
            p_pos += @intCast(adv);
        } else if (accel.first_bytes.len > 0) {
            // No literal prefix, but every match starts with one of a few
            // ASCII bytes: jump to the next candidate start.
            const adv = indexOfAnyByte(input.s[@intCast(p_pos)..], accel.first_bytes) orelse return false;
            p_pos += @intCast(adv);
        }
        if (b.cap.len > 0) b.cap[0] = p_pos;
        if (try b.tryBacktrack(p.start, p_pos)) return true; // leftmost match, done
        width = @intCast(input.step(@intCast(p_pos)).w);
        p_pos += width;
    }
    return false;
}

/// The one-pass engine: a single deterministic pass following per-instruction
/// `Next` dispatch tables. Used only for qualifying anchored regexps. Mirrors
/// Go's `doOnePass`.
fn doOnePass(op: *const OnePassProg, cond: EmptyOp, accel: Accel, input: Input, pos0: usize, caps: []i64) bool {
    if (cond == prog.impossible) return false;
    var pos = pos0;
    for (caps) |*c| c.* = -1;

    var r: i32 = end_of_text;
    var r1: i32 = end_of_text;
    var width: usize = 0;
    var width1: usize = 0;
    const s0 = input.step(pos);
    r = s0.r;
    width = s0.w;
    if (r != end_of_text) {
        const s1 = input.step(pos + width);
        r1 = s1.r;
        width1 = s1.w;
    }
    var flag: LazyFlag = if (pos == 0) LazyFlag.init(-1, r) else input.context(pos);
    var pc = op.start;
    var matched = false;

    // If there is a simple literal prefix, skip over it and resume at
    // `accel.prefix_end` (the prefix crosses no capture instructions, so no
    // recorded state is lost). Mirrors Go's `doOnePass`.
    if (pos == 0 and flag.match(@intCast(op.insts[pc].arg)) and accel.prefix.len > 0) {
        if (!std.mem.startsWith(u8, input.s, accel.prefix)) return false;
        pos += accel.prefix.len;
        const sa = input.step(pos);
        r = sa.r;
        width = sa.w;
        const sb = input.step(pos + width);
        r1 = sb.r;
        width1 = sb.w;
        flag = input.context(pos);
        pc = accel.prefix_end;
    }

    loop: while (true) {
        const inst = &op.insts[pc];
        pc = inst.out;
        switch (inst.op) {
            .match => {
                matched = true;
                if (caps.len > 0) {
                    caps[0] = 0;
                    caps[1] = @intCast(pos);
                }
                break :loop;
            },
            .rune => if (r < 0 or prog.matchRunePos(inst.runes, inst.arg, @intCast(r)) < 0) break :loop,
            .rune1 => if (r != @as(i32, @intCast(inst.runes[0]))) break :loop,
            .rune_any => {},
            .rune_any_not_nl => if (r == '\n') break :loop,
            .alt, .alt_match => {
                pc = onepass.onePassNext(inst, r);
                continue :loop;
            },
            .fail => break :loop,
            .nop => continue :loop,
            .empty_width => {
                if (!flag.match(@intCast(inst.arg))) break :loop;
                continue :loop;
            },
            .capture => {
                if (inst.arg < caps.len) caps[@intCast(inst.arg)] = @intCast(pos);
                continue :loop;
            },
        }
        // Reached only by the rune-consuming instructions: advance one rune.
        if (width == 0) break :loop;
        flag = LazyFlag.init(r, r1);
        pos += width;
        r = r1;
        width = width1;
        if (r != end_of_text) {
            const sc = input.step(pos + width);
            r1 = sc.r;
            width1 = sc.w;
        }
    }
    return matched;
}

/// Execute the program over `input` starting at byte offset `pos`, writing the
/// submatch byte offsets into `caps` (length determines the number of captures
/// recorded; pairs are [start,end], -1 when unset). Returns whether a match was
/// found. `caps` is only meaningful when `true` is returned.
///
/// Dispatches like Go: the one-pass engine if the regexp qualifies, else the
/// bitstate backtracker for small programs/inputs, else the Pike VM.
///
/// Reuse variant: borrows all engine storage from `scratch`, so a steady-state
/// loop over one compiled program allocates nothing. The one-pass path never
/// allocated and ignores the scratch.
pub fn executeReuse(
    scratch: *Scratch,
    p: *const Prog,
    op: ?*const OnePassProg,
    longest: bool,
    cond: EmptyOp,
    accel: Accel,
    input: Input,
    pos: usize,
    caps: []i64,
) !bool {
    if (op) |onep| return doOnePass(onep, cond, accel, input, pos, caps);
    const ninst = p.insts.len;
    if (ninst <= max_backtrack_prog and ninst > 0 and input.s.len < max_backtrack_vector / ninst) {
        return backtrack(scratch, p, longest, cond, accel, input, pos, caps);
    }
    var m = try Machine.init(scratch, p, longest, cond, accel, caps.len);
    if (!try m.run(input, pos)) return false;
    @memcpy(caps, m.matchcap);
    return true;
}

test "decodeLastRune handles ASCII, multibyte, and malformed tails" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(i32, 'a'), decodeLastRune("xa"));
    try expectEqual(@as(i32, 0x65E5), decodeLastRune("ab日")); // 3-byte rune
    try expectEqual(end_of_text, decodeLastRune(""));
    try expectEqual(@as(i32, 0xFFFD), decodeLastRune("\xE6\x97")); // truncated lead
    try expectEqual(@as(i32, 0xFFFD), decodeLastRune("a\x80")); // lone continuation
    try expectEqual(@as(i32, 0xFFFD), decodeLastRune("\xFF")); // invalid byte
}

test "prefixIndex finds first occurrence or null" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(?usize, 0), prefixIndex("hello", ""));
    try expectEqual(@as(?usize, 1), prefixIndex("xyz", "y"));
    try expectEqual(@as(?usize, 2), prefixIndex("ababc", "abc")); // first-byte false start
    try expectEqual(@as(?usize, null), prefixIndex("ababab", "abc"));
    try expectEqual(@as(?usize, null), prefixIndex("ab", "abc")); // needle longer than haystack
}

test "indexOfAnyByte agrees with the scalar std search" {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var hay: [300]u8 = undefined;
    for (&hay) |*b| b.* = 'a' + rand.uintLessThan(u8, 20);
    const sets = [_][]const u8{
        "xy",
        "qzv",
        "abcd",
        "abcdefghijklmnop", // max_first_bytes = 16
        "QZ", // absent from the haystack
    };
    // Slide both endpoints so hits land before, inside, and after the last
    // full SIMD chunk, plus empty and sub-width slices.
    for (sets) |set| {
        var lo: usize = 0;
        while (lo < hay.len) : (lo += 37) {
            var hi = lo;
            while (hi <= hay.len) : (hi += 23) {
                const want = std.mem.indexOfAny(u8, hay[lo..hi], set);
                try std.testing.expectEqual(want, indexOfAnyByte(hay[lo..hi], set));
            }
        }
    }
}

test "prefixIndex anchors on the rarest byte" {
    // 'x' is rarer than 'a'/'e'; a common-first-byte needle must still be
    // found correctly wherever it sits.
    try std.testing.expectEqual(@as(?usize, 6), prefixIndex("aeaeaeaext", "aext"));
    try std.testing.expectEqual(@as(?usize, 0), prefixIndex("aext", "aext"));
    try std.testing.expectEqual(@as(?usize, null), prefixIndex("aeaeaeae", "aext"));
}

test "prefixIndex Rabin-Karp fallback on periodic input" {
    const expectEqual = std.testing.expectEqual;
    const hay = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"; // 39 a's + b
    try expectEqual(@as(?usize, 35), prefixIndex(hay, "aaaab"));
    try expectEqual(@as(?usize, null), prefixIndex(hay[0..39], "aaaab"));
    // A needle whose rarest byte is itself the periodic byte: every anchor
    // hit is a false start, so the cutover to Rabin-Karp fires.
    const hay2 = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxy"; // 30 x's + y
    try expectEqual(@as(?usize, 26), prefixIndex(hay2, "xxxxy"));
    try expectEqual(@as(?usize, null), prefixIndex(hay2[0..30], "xxxxy"));
    try expectEqual(@as(?usize, 0), indexRabinKarp("abcabd", "abc"));
    try expectEqual(@as(?usize, 3), indexRabinKarp("abdabc", "abc"));
    try expectEqual(@as(?usize, null), indexRabinKarp("ab", "abc"));
}

/// Allocating variant: the existing public entry point. Wraps `executeReuse`
/// with a temporary scratch, so each call allocates and frees its engine
/// storage exactly as before — and the differential suite (which routes through
/// here) validates the shared `executeReuse` code path.
pub fn execute(
    allocator: std.mem.Allocator,
    p: *const Prog,
    op: ?*const OnePassProg,
    longest: bool,
    cond: EmptyOp,
    accel: Accel,
    input: Input,
    pos: usize,
    caps: []i64,
) !bool {
    var scratch = Scratch.init(allocator);
    defer scratch.deinit();
    return executeReuse(&scratch, p, op, longest, cond, accel, input, pos, caps);
}

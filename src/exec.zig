//! The execution engines, faithfully porting Go's `regexp/exec.go`: the
//! input decoding, the Pike VM (an NFA simulation with submatch tracking), the
//! one-pass runner, and the dispatch in `executeReuse`. The bitstate
//! backtracker lives in `backtrack.zig` (Go's `backtrack.go`) and the
//! substring / byte-set scans in `search.zig`. `executeReuse` dispatches
//! exactly like Go: the one-pass engine (see `onepass.zig`) for qualifying
//! anchored regexps, the bitstate backtracker for small programs/inputs, and
//! the Pike VM for everything else. All three produce identical results; the
//! fast engines exist purely for speed.
//!
//! Match priority is leftmost-first (RE2 / Perl semantics): `add` performs the
//! epsilon-closure in greedy-priority order, and in first-match mode `step`
//! cuts off all lower-priority threads once a match is found. Setting
//! `longest = true` switches to POSIX leftmost-longest.

const std = @import("std");
const prog = @import("prog.zig");
const unicode = @import("unicode.zig");
const onepass = @import("onepass.zig");
const search = @import("search.zig");
const backtrack_ = @import("backtrack.zig");

const Prog = prog.Prog;
const Inst = prog.Inst;
const EmptyOp = prog.EmptyOp;
const OnePassProg = onepass.OnePassProg;
const Job = backtrack_.Job;

pub const end_of_text: i32 = -1;

pub const max_first_bytes = search.max_first_bytes;

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
            try replaceBuffer(u32, a, &self.s0, ninst);
            @memset(self.s0, 0);
            try replaceBuffer(u32, a, &self.s1, ninst);
            @memset(self.s1, 0);
            try replaceBuffer(Entry, a, &self.dense0, ninst);
            try replaceBuffer(Entry, a, &self.dense1, ninst);
            self.pike_ninst = ninst;
        }
        if (ncap != self.thread_ncap) {
            for (self.all_threads.items) |t| {
                if (t.cap.len > 0) a.free(t.cap);
                a.destroy(t);
            }
            self.all_threads.clearRetainingCapacity();
            self.pool.clearRetainingCapacity();
            try replaceBuffer(i64, a, &self.matchcap, ncap);
            self.thread_ncap = ncap;
        }
    }

    /// Borrow bitstate work/visited buffers, growing each to a high-water mark
    /// and reslicing to the lengths this call needs. `visited` is a per-run set
    /// and is zeroed by the caller every run; only its allocation is reused.
    pub fn bitBufs(self: *Scratch, ncap: usize, visited_size: usize) !struct { work: []i64, visited: []u32 } {
        const a = self.allocator;
        if (ncap > self.work.len) {
            try replaceBuffer(i64, a, &self.work, ncap);
        }
        if (visited_size > self.visited.len) {
            try replaceBuffer(u32, a, &self.visited, visited_size);
        }
        return .{ .work = self.work[0..ncap], .visited = self.visited[0..visited_size] };
    }

    /// A scratch-owned result buffer of length `n`, grown to a high-water mark.
    /// The returned slice is valid only until the next call that reuses this
    /// scratch — see `regexp.findSubmatchIndexScratch`.
    pub fn resultBuf(self: *Scratch, n: usize) ![]i64 {
        if (n > self.result.len) {
            try replaceBuffer(i64, self.allocator, &self.result, n);
        }
        return self.result[0..n];
    }
};

// Allocate before releasing the old buffer so failure leaves valid ownership.
fn replaceBuffer(comptime T: type, allocator: std.mem.Allocator, buffer: *[]T, n: usize) !void {
    const next = try allocator.alloc(T, n);
    allocator.free(buffer.*);
    buffer.* = next;
}

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
    /// scratch outlives the Machine. Fresh sparse storage is initialized because
    /// Zig does not permit reading undefined integers. Reused sparse entries
    /// need no clearing: the dense cross-check rejects stale indices.
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
        // Reserve both lists before transferring ownership of a new thread.
        try sc.all_threads.ensureUnusedCapacity(sc.allocator, 1);
        try sc.pool.ensureTotalCapacity(sc.allocator, sc.all_threads.items.len + 1);
        const t = try sc.allocator.create(Thread);
        errdefer sc.allocator.destroy(t);
        t.cap = if (m.ncap > 0) try sc.allocator.alloc(i64, m.ncap) else &.{};
        t.pc = pc;
        sc.all_threads.appendAssumeCapacity(t);
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
                .rune => add_it = (c >= 0 and m.p.matchRuneAt(t.pc, @intCast(c))),
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
                if (m.accel.prefix.len > 0 and r1 != m.prefix_rune) {
                    if (search.prefixIndexAnchored(input.s[pos..], m.accel.prefix, m.accel.prefix_anchor)) |adv| {
                        pos += adv;
                        const sa = input.step(pos);
                        r = sa.r;
                        width = sa.w;
                        const sb = input.step(pos + width);
                        r1 = sb.r;
                        width1 = sb.w;
                    } else break;
                } else if (m.accel.first_bytes.len > 0 and !inFirstBytes(m.accel.first_bytes, r)) {
                    // First-byte acceleration: no literal prefix, but every
                    // match starts with one of a few ASCII bytes (e.g. a
                    // case-insensitive literal or a small leading class), so
                    // scan ahead to the next candidate. Unlike the prefix
                    // path, the closure may pass zero-width assertions, so
                    // the boundary flag must be recomputed for the new pos.
                    if (search.indexOfAnyByte(input.s[pos..], m.accel.first_bytes)) |adv| {
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
    if (ninst <= backtrack_.max_backtrack_prog and ninst > 0 and input.s.len < backtrack_.max_backtrack_vector / ninst) {
        return backtrack_.backtrack(scratch, p, longest, cond, accel, input, pos, caps);
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

fn exerciseScratchGrowth(allocator: std.mem.Allocator) !void {
    var scratch = Scratch.init(allocator);
    defer scratch.deinit();
    try scratch.ensurePike(4, 2);
    try scratch.ensurePike(16, 6);
    try scratch.ensurePike(8, 0);
    _ = try scratch.bitBufs(2, 8);
    _ = try scratch.bitBufs(6, 32);
    _ = try scratch.resultBuf(2);
    _ = try scratch.resultBuf(8);
}

test "scratch growth cleans up after every allocation failure" {
    // Growth must go through alloc: an in-place resize/remap succeeds or not
    // depending on heap layout, which would change the allocation count
    // between runs (NondeterministicMemoryUsage). resize_index only advances
    // on success, so fail index 0 fails every resize.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), exerciseScratchGrowth, .{});
}

test "scratch remains reusable after partially failed growth" {
    for (0..5) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var scratch = Scratch.init(failing.allocator());
        defer scratch.deinit();
        try scratch.ensurePike(4, 2);
        failing.fail_index = failing.alloc_index + offset;
        try std.testing.expectError(error.OutOfMemory, scratch.ensurePike(16, 6));
        failing.fail_index = std.math.maxInt(usize);
        try scratch.ensurePike(4, 2);
        try scratch.ensurePike(16, 6);
        try std.testing.expectEqual(@as(usize, 6), scratch.matchcap.len);
    }
}

test "fresh Pike sparse indices are initialized" {
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    for ([_]usize{ 8, 16 }) |n| {
        try scratch.ensurePike(n, 2);
        for (scratch.s0) |value| try std.testing.expectEqual(@as(u32, 0), value);
        for (scratch.s1) |value| try std.testing.expectEqual(@as(u32, 0), value);
    }
}

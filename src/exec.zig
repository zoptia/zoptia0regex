//! The Pike VM: an NFA simulation with submatch tracking, faithfully porting
//! Go's `regexp/exec.go`. This is the single execution engine (Go additionally
//! has one-pass and bitstate-backtracking engines purely for speed; the Pike
//! VM alone produces identical results for every supported pattern).
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

/// Find the first occurrence of `needle` in `haystack`. Like Go's bytes.Index,
/// it scans for the first byte with a vectorized search (`indexOfScalar`) and
/// verifies the rest, which is much faster than a generic substring search for
/// the common "rare first byte" case.
fn prefixIndex(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len == 1) return std.mem.indexOfScalar(u8, haystack, needle[0]);
    var start: usize = 0;
    while (start + needle.len <= haystack.len) {
        const rel = std.mem.indexOfScalar(u8, haystack[start..], needle[0]) orelse return null;
        const at = start + rel;
        if (at + needle.len > haystack.len) return null;
        if (std.mem.eql(u8, haystack[at .. at + needle.len], needle)) return at;
        start = at + 1;
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

const Machine = struct {
    allocator: std.mem.Allocator,
    p: *const Prog,
    longest: bool,
    cond: EmptyOp,
    ncap: usize,
    prefix: []const u8,
    prefix_rune: i32,
    q0: Queue,
    q1: Queue,
    pool: std.ArrayList(*Thread) = .empty,
    all_threads: std.ArrayList(*Thread) = .empty,
    matched: bool = false,
    matchcap: []i64,

    fn init(allocator: std.mem.Allocator, p: *const Prog, longest: bool, cond: EmptyOp, prefix: []const u8, ncap: usize) !Machine {
        const ninst = p.insts.len;
        var prune: i32 = -1;
        if (prefix.len > 0) {
            const n = std.unicode.utf8ByteSequenceLength(prefix[0]) catch 1;
            prune = if (n <= prefix.len)
                @intCast(std.unicode.utf8Decode(prefix[0..n]) catch 0xFFFD)
            else
                0xFFFD;
        }
        // The sparse-set membership check reads sparse[pc] before it is written;
        // its correctness relies only on the dense cross-check, but Go's `make`
        // zero-initializes, so we do too to avoid reading indeterminate memory.
        const s0 = try allocator.alloc(u32, ninst);
        @memset(s0, 0);
        const s1 = try allocator.alloc(u32, ninst);
        @memset(s1, 0);
        return .{
            .allocator = allocator,
            .p = p,
            .longest = longest,
            .cond = cond,
            .ncap = ncap,
            .prefix = prefix,
            .prefix_rune = prune,
            .q0 = .{ .sparse = s0, .dense = try allocator.alloc(Entry, ninst) },
            .q1 = .{ .sparse = s1, .dense = try allocator.alloc(Entry, ninst) },
            .matchcap = try allocator.alloc(i64, ncap),
        };
    }

    fn deinit(m: *Machine) void {
        for (m.all_threads.items) |t| {
            m.allocator.free(t.cap);
            m.allocator.destroy(t);
        }
        m.all_threads.deinit(m.allocator);
        m.pool.deinit(m.allocator);
        m.allocator.free(m.q0.sparse);
        m.allocator.free(m.q0.dense);
        m.allocator.free(m.q1.sparse);
        m.allocator.free(m.q1.dense);
        m.allocator.free(m.matchcap);
    }

    fn alloc(m: *Machine, pc: u32) !*Thread {
        if (m.pool.items.len > 0) {
            const t = m.pool.pop().?;
            t.pc = pc;
            return t;
        }
        const t = try m.allocator.create(Thread);
        t.cap = try m.allocator.alloc(i64, m.ncap);
        t.pc = pc;
        try m.all_threads.append(m.allocator, t);
        // Ensure the free pool can always hold every thread without erroring.
        try m.pool.ensureTotalCapacity(m.allocator, m.all_threads.items.len);
        return t;
    }

    inline fn free(m: *Machine, t: *Thread) void {
        m.pool.appendAssumeCapacity(t);
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
                if (m.prefix.len > 0 and r1 != m.prefix_rune and pos <= input.s.len) {
                    if (prefixIndex(input.s[pos..], m.prefix)) |adv| {
                        pos += adv;
                        const sa = input.step(pos);
                        r = sa.r;
                        width = sa.w;
                        const sb = input.step(pos + width);
                        r1 = sb.r;
                        width1 = sb.w;
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
    jobs: std.ArrayList(Job) = .empty,
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

fn backtrack(allocator: std.mem.Allocator, p: *const Prog, longest: bool, cond: EmptyOp, prefix: []const u8, input: Input, pos: usize, caps: []i64) !bool {
    if (cond == prog.impossible) return false;
    if (cond & prog.empty_begin_text != 0 and pos != 0) return false;

    const ninst = p.insts.len;
    const end = input.s.len;
    const visited_size = (ninst * (end + 1) + visited_bits - 1) / visited_bits;

    const work = try allocator.alloc(i64, caps.len);
    defer allocator.free(work);
    const visited = try allocator.alloc(u32, visited_size);
    defer allocator.free(visited);
    @memset(work, -1);
    @memset(caps, -1);
    @memset(visited, 0);

    var b = BitState{
        .allocator = allocator,
        .p = p,
        .input = input,
        .longest = longest,
        .end = end,
        .cap = work,
        .matchcap = caps,
        .visited = visited,
    };
    defer b.jobs.deinit(allocator);

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
        if (prefix.len > 0) {
            const adv = prefixIndex(input.s[@intCast(p_pos)..], prefix) orelse return false;
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
fn doOnePass(op: *const OnePassProg, cond: EmptyOp, input: Input, pos0: usize, caps: []i64) bool {
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
pub fn execute(
    allocator: std.mem.Allocator,
    p: *const Prog,
    op: ?*const OnePassProg,
    longest: bool,
    cond: EmptyOp,
    prefix: []const u8,
    input: Input,
    pos: usize,
    caps: []i64,
) !bool {
    if (op) |onep| return doOnePass(onep, cond, input, pos, caps);
    const ninst = p.insts.len;
    if (ninst <= max_backtrack_prog and ninst > 0 and input.s.len < max_backtrack_vector / ninst) {
        return backtrack(allocator, p, longest, cond, prefix, input, pos, caps);
    }
    var m = try Machine.init(allocator, p, longest, cond, prefix, caps.len);
    defer m.deinit();
    if (!try m.run(input, pos)) return false;
    @memcpy(caps, m.matchcap);
    return true;
}

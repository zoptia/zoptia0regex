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

const Prog = prog.Prog;
const Inst = prog.Inst;
const EmptyOp = prog.EmptyOp;

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
    q0: Queue,
    q1: Queue,
    pool: std.ArrayList(*Thread) = .empty,
    all_threads: std.ArrayList(*Thread) = .empty,
    matched: bool = false,
    matchcap: []i64,

    fn init(allocator: std.mem.Allocator, p: *const Prog, longest: bool, cond: EmptyOp, ncap: usize) !Machine {
        const ninst = p.insts.len;
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

/// Execute the program over `input` starting at byte offset `pos`, writing the
/// submatch byte offsets into `caps` (length determines the number of captures
/// recorded; pairs are [start,end], -1 when unset). Returns whether a match was
/// found. `caps` is only meaningful when `true` is returned.
pub fn execute(
    allocator: std.mem.Allocator,
    p: *const Prog,
    longest: bool,
    cond: EmptyOp,
    input: Input,
    pos: usize,
    caps: []i64,
) !bool {
    var m = try Machine.init(allocator, p, longest, cond, caps.len);
    defer m.deinit();
    if (!try m.run(input, pos)) return false;
    @memcpy(caps, m.matchcap);
    return true;
}

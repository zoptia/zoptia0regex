//! The bitstate backtracker, porting Go's `regexp/backtrack.go`.
//!
//! For small programs and inputs, a backtracking search with a (pc, pos)
//! visited bitmap is faster than the Pike VM while staying linear-time. This is
//! the engine Go dispatches to for these cases; porting it closes the one
//! remaining performance gap (small nested-quantifier patterns).

const std = @import("std");
const prog = @import("prog.zig");
const exec = @import("exec.zig");
const search = @import("search.zig");

const Prog = prog.Prog;
const Input = exec.Input;
const Engine = exec.Engine;
const Scratch = exec.Scratch;
const end_of_text = exec.end_of_text;

pub const max_backtrack_prog = 500; // only programs with <= this many insts
pub const max_backtrack_vector = 256 * 1024; // visited bitmap size cap, in bits
pub const visited_bits = 32;

pub const Job = struct { pc: u32, arg: bool, pos: i64 };

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
                        if (s.r < 0 or !b.p.matchRuneAt(pc, @intCast(s.r))) break :process;
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

/// Run the backtracker over `input` from `pos`, writing submatches to `caps`.
/// Mirrors Go's `(*Regexp).backtrack`.
pub fn backtrack(scratch: *Scratch, e: *const Engine, input: Input, pos: usize, caps: []i64) !bool {
    const p = e.prog;
    const cond = e.cond;
    const accel = &e.accel;
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
        .longest = e.longest,
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
            const adv = search.prefixIndexAnchored(input.s[@intCast(p_pos)..], accel.prefix, accel.prefix_anchor) orelse return false;
            p_pos += @intCast(adv);
        } else if (accel.first_bytes.bytes.len > 0) {
            // No literal prefix, but every match starts with one of a few
            // ASCII bytes: jump to the next candidate start.
            const adv = search.indexOfAnyByte(input.s[@intCast(p_pos)..], &accel.first_bytes) orelse return false;
            p_pos += @intCast(adv);
        }
        if (b.cap.len > 0) b.cap[0] = p_pos;
        if (try b.tryBacktrack(p.start, p_pos)) return true; // leftmost match, done
        width = @intCast(input.step(@intCast(p_pos)).w);
        p_pos += width;
    }
    return false;
}

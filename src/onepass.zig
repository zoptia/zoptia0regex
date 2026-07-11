//! "One-pass" regular-expression analysis, porting Go's `regexp/onepass.go`.
//!
//! Some (always *anchored*) regexps can be analyzed to prove that at every
//! step there is exactly one way to proceed given the next input rune — no
//! ambiguity, no backtracking, no thread set. For those, a single linear pass
//! following a per-instruction `Next` dispatch table is the fastest engine.
//! `compileOnePass` builds that table when possible, else returns null and the
//! caller falls back to the bitstate/Pike VM engines (with identical results).
//!
//! Port notes vs Go: `onePassCopy`'s optional Prog-idiom rewrites (which let a
//! few extra Alt shapes qualify) and `doOnePass`'s literal-prefix skip are
//! omitted — both only affect which programs qualify / how fast, never the
//! match results of those that do.

const std = @import("std");
const prog = @import("prog.zig");
const ast = @import("ast.zig");
const unicode = @import("unicode.zig");

const InstOp = prog.InstOp;
const Prog = prog.Prog;

pub const OnePassInst = struct {
    op: InstOp,
    out: u32 = 0,
    arg: u32 = 0,
    runes: []const u21 = &.{},
    next: []u32 = &.{},
};

pub const OnePassProg = struct {
    insts: []OnePassInst,
    start: u32,
    num_cap: usize,
};

const merge_failed: u32 = 0xffffffff;

/// Select the next pc from an Alt/AltMatch instruction based on the input rune.
/// Mirrors Go's `onePassNext`.
pub fn onePassNext(inst: *const OnePassInst, r: i32) u32 {
    if (r >= 0) {
        const next = prog.matchRunePos(inst.runes, inst.arg, @intCast(r));
        if (next >= 0) return inst.next[@intCast(next)];
    }
    if (inst.op == .alt_match) return inst.out;
    return 0;
}

// --- sparse-set queue ---

const Queue = struct {
    sparse: []u32,
    dense: []u32,
    size: u32 = 0,
    next_index: u32 = 0,

    fn empty(q: *const Queue) bool {
        return q.next_index >= q.size;
    }
    fn next(q: *Queue) u32 {
        const n = q.dense[q.next_index];
        q.next_index += 1;
        return n;
    }
    fn clear(q: *Queue) void {
        q.size = 0;
        q.next_index = 0;
    }
    fn contains(q: *const Queue, u: u32) bool {
        if (u >= q.sparse.len) return false;
        return q.sparse[u] < q.size and q.dense[q.sparse[u]] == u;
    }
    fn insert(q: *Queue, u: u32) void {
        if (!q.contains(u)) q.insertNew(u);
    }
    fn insertNew(q: *Queue, u: u32) void {
        if (u >= q.sparse.len) return;
        q.sparse[u] = q.size;
        q.dense[q.size] = u;
        q.size += 1;
    }
};

fn newQueue(al: std.mem.Allocator, size: usize) !Queue {
    return .{ .sparse = try al.alloc(u32, size), .dense = try al.alloc(u32, size) };
}

const MergeResult = struct { merged: []const u21, next: []u32 };

/// Merge two non-intersecting, ordered rune-pair sets, recording for each
/// merged pair which leg's pc to jump to. Returns `next == [merge_failed]` if
/// the sets intersect (the Alt is then ambiguous and not one-pass). Mirrors
/// Go's `mergeRuneSets`.
fn mergeRuneSets(al: std.mem.Allocator, left: []const u21, right: []const u21, left_pc: u32, right_pc: u32) !MergeResult {
    var lx: usize = 0;
    var rx: usize = 0;
    var merged: std.ArrayList(u21) = .empty;
    var next: std.ArrayList(u32) = .empty;
    var ix: i64 = -1;

    while (lx < left.len or rx < right.len) {
        var take_left: bool = undefined;
        if (rx >= right.len) {
            take_left = true;
        } else if (lx >= left.len) {
            take_left = false;
        } else if (right[rx] < left[lx]) {
            take_left = false;
        } else {
            take_left = true;
        }
        const arr = if (take_left) left else right;
        const idx = if (take_left) &lx else &rx;
        const pc = if (take_left) left_pc else right_pc;
        // extend, detecting overlap with the last appended hi
        if (ix > 0 and arr[idx.*] <= merged.items[@intCast(ix)]) {
            merged.deinit(al);
            next.deinit(al);
            return .{ .merged = &.{}, .next = try al.dupe(u32, &[_]u32{merge_failed}) };
        }
        try merged.append(al, arr[idx.*]);
        try merged.append(al, arr[idx.* + 1]);
        idx.* += 2;
        ix += 2;
        try next.append(al, pc);
    }
    return .{ .merged = try merged.toOwnedSlice(al), .next = try next.toOwnedSlice(al) };
}

test "mergeRuneSets merges disjoint sets and rejects intersecting ones" {
    const gpa = std.testing.allocator;

    // Disjoint: ordering interleaves by lo, next[] records the source pc.
    const ok = try mergeRuneSets(gpa, &[_]u21{ 'd', 'e' }, &[_]u21{ 'a', 'b' }, 1, 2);
    defer {
        gpa.free(ok.merged);
        gpa.free(ok.next);
    }
    try std.testing.expectEqualSlices(u21, &[_]u21{ 'a', 'b', 'd', 'e' }, ok.merged);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 2, 1 }, ok.next);

    // Intersecting: (a,c) overlaps (b,e) → merge_failed sentinel.
    const bad = try mergeRuneSets(gpa, &[_]u21{ 'a', 'c' }, &[_]u21{ 'b', 'e' }, 1, 2);
    defer {
        gpa.free(bad.merged);
        gpa.free(bad.next);
    }
    try std.testing.expectEqual(@as(usize, 1), bad.next.len);
    try std.testing.expectEqual(merge_failed, bad.next[0]);
}

const any_rune = [_]u21{ 0, unicode.max_rune };
const any_rune_not_nl = [_]u21{ 0, '\n' - 1, '\n' + 1, unicode.max_rune };

const Builder = struct {
    al: std.mem.Allocator,
    p: *OnePassProg,
    inst_queue: *Queue,
    visit_queue: *Queue,
    one_pass_runes: [][]const u21,

    fn foldExpand(b: *Builder, r0: u21) ![]const u21 {
        var list: std.ArrayList(u21) = .empty;
        try list.append(b.al, r0);
        try list.append(b.al, r0);
        var r1 = unicode.simpleFold(r0);
        while (r1 != r0) : (r1 = unicode.simpleFold(r1)) {
            try list.append(b.al, r1);
            try list.append(b.al, r1);
        }
        std.mem.sort(u21, list.items, {}, std.sort.asc(u21));
        return try list.toOwnedSlice(b.al);
    }

    fn fill(b: *Builder, pc: u32, runes: []const u21, out: u32) !void {
        const n = runes.len / 2 + 1;
        const nx = try b.al.alloc(u32, n);
        for (nx) |*x| x.* = out;
        b.one_pass_runes[pc] = runes;
        b.p.insts[pc].next = nx;
    }

    fn check(b: *Builder, pc: u32, m: []bool) error{OutOfMemory}!bool {
        if (b.visit_queue.contains(pc)) return true;
        b.visit_queue.insert(pc);
        const inst = &b.p.insts[pc];
        switch (inst.op) {
            .alt, .alt_match => {
                var ok = try b.check(inst.out, m);
                if (ok) ok = try b.check(inst.arg, m);
                var match_out = m[inst.out];
                var match_arg = m[inst.arg];
                if (match_out and match_arg) return false;
                if (match_arg) {
                    const t = inst.out;
                    inst.out = inst.arg;
                    inst.arg = t;
                    const tm = match_out;
                    match_out = match_arg;
                    match_arg = tm;
                }
                if (match_out) {
                    m[pc] = true;
                    inst.op = .alt_match;
                }
                const mr = try mergeRuneSets(b.al, b.one_pass_runes[inst.out], b.one_pass_runes[inst.arg], inst.out, inst.arg);
                b.one_pass_runes[pc] = mr.merged;
                inst.next = mr.next;
                if (mr.next.len > 0 and mr.next[0] == merge_failed) return false;
                return ok;
            },
            .capture, .nop, .empty_width => {
                const ok = try b.check(inst.out, m);
                m[pc] = m[inst.out];
                try b.fill(pc, b.one_pass_runes[inst.out], inst.out);
                return ok;
            },
            .match, .fail => {
                m[pc] = inst.op == .match;
                return true;
            },
            .rune => {
                m[pc] = false;
                if (inst.next.len > 0) return true;
                b.inst_queue.insert(inst.out);
                if (inst.runes.len == 0) {
                    b.one_pass_runes[pc] = &.{};
                    inst.next = try b.al.dupe(u32, &[_]u32{inst.out});
                    return true;
                }
                const runes: []const u21 = if (inst.runes.len == 1 and (@as(ast.Flags, @intCast(inst.arg)) & ast.FoldCase) != 0)
                    try b.foldExpand(inst.runes[0])
                else
                    inst.runes;
                try b.fill(pc, runes, inst.out);
                inst.op = .rune;
                return true;
            },
            .rune1 => {
                m[pc] = false;
                if (inst.next.len > 0) return true;
                b.inst_queue.insert(inst.out);
                const runes: []const u21 = if ((@as(ast.Flags, @intCast(inst.arg)) & ast.FoldCase) != 0)
                    try b.foldExpand(inst.runes[0])
                else
                    try b.al.dupe(u21, &[_]u21{ inst.runes[0], inst.runes[0] });
                try b.fill(pc, runes, inst.out);
                inst.op = .rune;
                return true;
            },
            .rune_any => {
                m[pc] = false;
                if (inst.next.len > 0) return true;
                b.inst_queue.insert(inst.out);
                b.one_pass_runes[pc] = &any_rune;
                inst.next = try b.al.dupe(u32, &[_]u32{inst.out});
                return true;
            },
            .rune_any_not_nl => {
                m[pc] = false;
                if (inst.next.len > 0) return true;
                b.inst_queue.insert(inst.out);
                try b.fill(pc, &any_rune_not_nl, inst.out);
                return true;
            },
        }
    }
};

fn onePassCopy(al: std.mem.Allocator, p: *const Prog) !OnePassProg {
    const insts = try al.alloc(OnePassInst, p.insts.len);
    for (p.insts, 0..) |inst, i| {
        insts[i] = .{ .op = inst.op, .out = inst.out, .arg = inst.arg, .runes = inst.runes };
    }
    return .{ .insts = insts, .start = p.start, .num_cap = p.num_cap };
}

fn cleanupOnePass(p: *OnePassProg, original: *const Prog) void {
    for (original.insts, 0..) |orig, ix| {
        switch (orig.op) {
            .alt, .alt_match, .rune => {},
            .capture, .empty_width, .nop, .match, .fail => p.insts[ix].next = &.{},
            .rune1, .rune_any, .rune_any_not_nl => p.insts[ix] = .{ .op = orig.op, .out = orig.out, .arg = orig.arg, .runes = orig.runes },
        }
    }
}

/// Returns true if `p` could be made one-pass (modifying it in place).
fn makeOnePass(al: std.mem.Allocator, p: *OnePassProg) !bool {
    if (p.insts.len >= 1000) return false;

    var inst_queue = try newQueue(al, p.insts.len);
    var visit_queue = try newQueue(al, p.insts.len);
    const one_pass_runes = try al.alloc([]const u21, p.insts.len);
    for (one_pass_runes) |*r| r.* = &.{};
    const m = try al.alloc(bool, p.insts.len);
    @memset(m, false);

    var b = Builder{
        .al = al,
        .p = p,
        .inst_queue = &inst_queue,
        .visit_queue = &visit_queue,
        .one_pass_runes = one_pass_runes,
    };

    inst_queue.clear();
    inst_queue.insert(p.start);
    while (!inst_queue.empty()) {
        visit_queue.clear();
        const pc = inst_queue.next();
        if (!try b.check(pc, m)) return false;
    }
    for (p.insts, 0..) |*inst, i| inst.runes = one_pass_runes[i];
    return true;
}

/// Build a one-pass program from `prog` if it qualifies (anchored, unambiguous
/// at every Alt), else null. Mirrors Go's `compileOnePass`. The returned
/// program is allocated from `al` (the owning Regexp's arena); `gpa` backs the
/// transient analysis state, which is freed before returning.
pub fn compileOnePass(gpa: std.mem.Allocator, al: std.mem.Allocator, p: *const Prog) !?OnePassProg {
    if (p.start == 0) return null;
    // One-pass regexps are anchored at the beginning of text.
    const start = &p.insts[p.start];
    if (start.op != .empty_width or (@as(prog.EmptyOp, @intCast(start.arg)) & prog.empty_begin_text) != prog.empty_begin_text) {
        return null;
    }

    var has_alt = false;
    for (p.insts) |inst| {
        if (inst.op == .alt or inst.op == .alt_match) {
            has_alt = true;
            break;
        }
    }

    // With alternation, every path to a match must be guarded by EmptyEndText.
    for (p.insts) |inst| {
        const op_out = p.insts[inst.out].op;
        switch (inst.op) {
            .alt, .alt_match => {
                if (op_out == .match or p.insts[inst.arg].op == .match) return null;
            },
            .empty_width => {
                if (op_out == .match) {
                    if ((@as(prog.EmptyOp, @intCast(inst.arg)) & prog.empty_end_text) == prog.empty_end_text) continue;
                    return null;
                }
            },
            else => {
                if (op_out == .match and has_alt) return null;
            },
        }
    }

    // Run the copy + analysis in a temporary arena: makeOnePass allocates
    // queues, visit maps and intermediate rune sets that Go simply leaves to
    // the GC. Under the Regexp's arena they would be pinned for its whole
    // lifetime (and entirely wasted when the program fails to qualify), so
    // only the qualifying program is deep-copied into `al`.
    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    const tal = tmp.allocator();

    var opp = try onePassCopy(tal, p);
    if (!try makeOnePass(tal, &opp)) return null;
    cleanupOnePass(&opp, p);

    const insts = try al.alloc(OnePassInst, opp.insts.len);
    for (opp.insts, 0..) |inst, i| {
        insts[i] = .{
            .op = inst.op,
            .out = inst.out,
            .arg = inst.arg,
            .runes = if (inst.runes.len > 0) try al.dupe(u21, inst.runes) else &.{},
            .next = if (inst.next.len > 0) try al.dupe(u32, inst.next) else &.{},
        };
    }
    return .{ .insts = insts, .start = opp.start, .num_cap = opp.num_cap };
}

//! The compiler: turns a simplified AST into a `Prog` of NFA instructions,
//! faithfully porting Go's `regexp/syntax.Compile` (compile.go).
//!
//! Uses the same "patch list" trick: the not-yet-filled `out`/`arg` fields of
//! instructions are threaded into a linked list (encoded as `pc<<1 | which`)
//! so dangling exits of a fragment can be patched later in O(1).

const std = @import("std");
const ast = @import("ast.zig");
const prog = @import("prog.zig");
const unicode = @import("unicode.zig");

const Regexp = ast.Regexp;
const Inst = prog.Inst;
const Prog = prog.Prog;

pub const Error = error{ OutOfMemory, NestingDepth, TooLarge };

// Backstop against runaway programs, matching Go's maxSize (128 MB / 40-byte
// inst ≈ 3.3M instructions): a flat expression larger than this is rejected
// with TooLarge, just as Go rejects it with ErrLarge.
const max_insts = (128 << 20) / 40;

/// A list of instruction exits awaiting patching. `head`/`tail` encode a
/// program counter and which field (`pc<<1` for `.out`, `pc<<1 | 1` for
/// `.arg`); `head == 0` is the empty list (pc 0 is always the fail inst).
const PatchList = struct {
    head: u32 = 0,
    tail: u32 = 0,

    fn make(n: u32) PatchList {
        return .{ .head = n, .tail = n };
    }

    fn patch(l: PatchList, insts: []Inst, val: u32) void {
        var head = l.head;
        while (head != 0) {
            const i = &insts[head >> 1];
            if (head & 1 == 0) {
                head = i.out;
                i.out = val;
            } else {
                head = i.arg;
                i.arg = val;
            }
        }
    }

    fn append(l1: PatchList, insts: []Inst, l2: PatchList) PatchList {
        if (l1.head == 0) return l2;
        if (l2.head == 0) return l1;
        const i = &insts[l1.tail >> 1];
        if (l1.tail & 1 == 0) {
            i.out = l2.head;
        } else {
            i.arg = l2.head;
        }
        return .{ .head = l1.head, .tail = l2.tail };
    }
};

/// A compiled program fragment: entry instruction `i`, the dangling exits
/// `out`, and whether it can match the empty string.
const Frag = struct {
    i: u32 = 0,
    out: PatchList = .{},
    nullable: bool = false,
};

const any_rune = [_]u21{ 0, unicode.max_rune };
const any_rune_not_nl = [_]u21{ 0, '\n' - 1, '\n' + 1, unicode.max_rune };

const Compiler = struct {
    al: std.mem.Allocator,
    insts: std.ArrayList(Inst) = .empty,
    num_cap: usize = 2, // implicit whole-match pair
    depth: u32 = 0,

    fn inst(c: *Compiler, op: prog.InstOp) Error!Frag {
        const i: u32 = @intCast(c.insts.items.len);
        try c.insts.append(c.al, .{ .op = op });
        if (c.insts.items.len > max_insts) return error.TooLarge;
        return .{ .i = i, .nullable = true };
    }

    fn nop(c: *Compiler) Error!Frag {
        var f = try c.inst(.nop);
        f.out = PatchList.make(f.i << 1);
        return f;
    }

    fn fail(c: *Compiler) Frag {
        _ = c;
        return .{};
    }

    fn cap(c: *Compiler, arg: u32) Error!Frag {
        var f = try c.inst(.capture);
        f.out = PatchList.make(f.i << 1);
        c.insts.items[f.i].arg = arg;
        if (c.num_cap < arg + 1) c.num_cap = arg + 1;
        return f;
    }

    fn cat(c: *Compiler, f1: Frag, f2: Frag) Frag {
        // Concat with a failure fragment is failure.
        if (f1.i == 0 or f2.i == 0) return .{};
        f1.out.patch(c.insts.items, f2.i);
        return .{ .i = f1.i, .out = f2.out, .nullable = f1.nullable and f2.nullable };
    }

    fn alt(c: *Compiler, f1: Frag, f2: Frag) Error!Frag {
        if (f1.i == 0) return f2;
        if (f2.i == 0) return f1;
        var f = try c.inst(.alt);
        c.insts.items[f.i].out = f1.i;
        c.insts.items[f.i].arg = f2.i;
        f.out = f1.out.append(c.insts.items, f2.out);
        f.nullable = f1.nullable or f2.nullable;
        return f;
    }

    fn quest(c: *Compiler, f1: Frag, nongreedy: bool) Error!Frag {
        var f = try c.inst(.alt);
        if (nongreedy) {
            c.insts.items[f.i].arg = f1.i;
            f.out = PatchList.make(f.i << 1);
        } else {
            c.insts.items[f.i].out = f1.i;
            f.out = PatchList.make((f.i << 1) | 1);
        }
        f.out = f.out.append(c.insts.items, f1.out);
        return f;
    }

    /// The main loop instruction shared by plus and (non-nullable) star.
    fn loop(c: *Compiler, f1: Frag, nongreedy: bool) Error!Frag {
        var f = try c.inst(.alt);
        if (nongreedy) {
            c.insts.items[f.i].arg = f1.i;
            f.out = PatchList.make(f.i << 1);
        } else {
            c.insts.items[f.i].out = f1.i;
            f.out = PatchList.make((f.i << 1) | 1);
        }
        f1.out.patch(c.insts.items, f.i);
        return f;
    }

    fn star(c: *Compiler, f1: Frag, nongreedy: bool) Error!Frag {
        if (f1.nullable) {
            // (f1+)? keeps the priority match order correct (golang #46123).
            return c.quest(try c.plus(f1, nongreedy), nongreedy);
        }
        return c.loop(f1, nongreedy);
    }

    fn plus(c: *Compiler, f1: Frag, nongreedy: bool) Error!Frag {
        const l = try c.loop(f1, nongreedy);
        return .{ .i = f1.i, .out = l.out, .nullable = f1.nullable };
    }

    fn empty(c: *Compiler, op: prog.EmptyOp) Error!Frag {
        var f = try c.inst(.empty_width);
        c.insts.items[f.i].arg = op;
        f.out = PatchList.make(f.i << 1);
        return f;
    }

    fn rune(c: *Compiler, runes: []const u21, flags0: ast.Flags) Error!Frag {
        var f = try c.inst(.rune);
        f.nullable = false;
        var flags = flags0 & ast.FoldCase; // only FoldCase is relevant
        if (runes.len != 1 or unicode.simpleFold(runes[0]) == runes[0]) {
            flags &= ~ast.FoldCase;
        }
        c.insts.items[f.i].runes = runes;
        c.insts.items[f.i].arg = flags;
        f.out = PatchList.make(f.i << 1);

        // Specialize for the exec machine.
        if (flags & ast.FoldCase == 0 and (runes.len == 1 or (runes.len == 2 and runes[0] == runes[1]))) {
            c.insts.items[f.i].op = .rune1;
        } else if (runes.len == 2 and runes[0] == 0 and runes[1] == unicode.max_rune) {
            c.insts.items[f.i].op = .rune_any;
        } else if (runes.len == 4 and runes[0] == 0 and runes[1] == '\n' - 1 and runes[2] == '\n' + 1 and runes[3] == unicode.max_rune) {
            c.insts.items[f.i].op = .rune_any_not_nl;
        }
        return f;
    }

    fn compileRe(c: *Compiler, re: *Regexp) Error!Frag {
        c.depth += 1;
        if (c.depth > 4000) return error.NestingDepth;
        defer c.depth -= 1;

        switch (re.op) {
            .no_match => return c.fail(),
            .empty_match => return c.nop(),
            .literal => {
                if (re.runes.len == 0) return c.nop();
                var f: Frag = .{};
                for (re.runes, 0..) |_, j| {
                    const f1 = try c.rune(re.runes[j .. j + 1], re.flags);
                    f = if (j == 0) f1 else c.cat(f, f1);
                }
                return f;
            },
            .char_class => return c.rune(re.runes, re.flags),
            .any_char_not_nl => return c.rune(&any_rune_not_nl, 0),
            .any_char => return c.rune(&any_rune, 0),
            .begin_line => return c.empty(prog.empty_begin_line),
            .end_line => return c.empty(prog.empty_end_line),
            .begin_text => return c.empty(prog.empty_begin_text),
            .end_text => return c.empty(prog.empty_end_text),
            .word_boundary => return c.empty(prog.empty_word_boundary),
            .no_word_boundary => return c.empty(prog.empty_no_word_boundary),
            .capture => {
                const bra = try c.cap(@intCast(re.cap << 1));
                const sub = try c.compileRe(re.sub[0]);
                const ket = try c.cap(@intCast((re.cap << 1) | 1));
                return c.cat(c.cat(bra, sub), ket);
            },
            .star => return c.star(try c.compileRe(re.sub[0]), re.flags & ast.NonGreedy != 0),
            .plus => return c.plus(try c.compileRe(re.sub[0]), re.flags & ast.NonGreedy != 0),
            .quest => return c.quest(try c.compileRe(re.sub[0]), re.flags & ast.NonGreedy != 0),
            .concat => {
                if (re.sub.len == 0) return c.nop();
                var f: Frag = .{};
                for (re.sub, 0..) |sub, i| {
                    const fi = try c.compileRe(sub);
                    f = if (i == 0) fi else c.cat(f, fi);
                }
                return f;
            },
            .alternate => {
                var f: Frag = .{};
                for (re.sub) |sub| {
                    f = try c.alt(f, try c.compileRe(sub));
                }
                return f;
            },
            .repeat => unreachable, // removed by simplify
            else => unreachable, // pseudo-ops are never compiled
        }
    }
};

/// Compile a simplified AST into a program. The returned `Prog.insts` is
/// allocated from `al` (caller/owning Regexp's arena).
pub fn compile(al: std.mem.Allocator, re: *Regexp) Error!Prog {
    var c = Compiler{ .al = al };
    _ = try c.inst(.fail); // inst[0] is always fail
    const f = try c.compileRe(re);
    const m = try c.inst(.match);
    f.out.patch(c.insts.items, m.i);
    const start = f.i;
    return Prog{
        .insts = try c.insts.toOwnedSlice(al),
        .start = start,
        .num_cap = c.num_cap,
    };
}

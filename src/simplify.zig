//! The simplify pass: rewrites the AST to remove counted repetitions
//! (`OpRepeat`) and collapse idempotent unary operators, mirroring Go's
//! `regexp/syntax.Simplify`. For example `x{2,4}` becomes `xx(x(x)?)?` and
//! `(?:a+)+` becomes `a+`. New nodes are allocated from the arena.

const std = @import("std");
const ast = @import("ast.zig");
const Regexp = ast.Regexp;
const Op = ast.Op;
const Flags = ast.Flags;

pub const Error = error{OutOfMemory};

pub fn simplify(al: std.mem.Allocator, re: *Regexp) Error!*Regexp {
    switch (re.op) {
        .capture, .concat, .alternate => {
            // Simplify children; build a new node only if a child changed.
            var nre: ?*Regexp = null;
            for (re.sub, 0..) |sub, i| {
                const nsub = try simplify(al, sub);
                if (nre == null and nsub != sub) {
                    const copy = try al.create(Regexp);
                    copy.* = re.*;
                    copy.runes = &.{};
                    const newsub = try al.alloc(*Regexp, re.sub.len);
                    @memcpy(newsub[0..i], re.sub[0..i]);
                    copy.sub = newsub;
                    nre = copy;
                }
                if (nre) |n| n.sub[i] = nsub;
            }
            return nre orelse re;
        },
        .star, .plus, .quest => {
            const sub = try simplify(al, re.sub[0]);
            return simplify1(al, re.op, re.flags, sub, re);
        },
        .repeat => {
            // x{0,0} matches the empty string.
            if (re.min == 0 and re.max == 0) return try newOp(al, .empty_match);

            const sub = try simplify(al, re.sub[0]);

            // x{n,}: at least n matches of x.
            if (re.max == -1) {
                if (re.min == 0) return simplify1(al, .star, re.flags, sub, null);
                if (re.min == 1) return simplify1(al, .plus, re.flags, sub, null);
                // x{n,} = x...x x+   (n-1 copies of x, then x+)
                var list: std.ArrayList(*Regexp) = .empty;
                var i: i32 = 0;
                while (i < re.min - 1) : (i += 1) try list.append(al, sub);
                try list.append(al, try simplify1(al, .plus, re.flags, sub, null));
                return try concatOf(al, &list);
            }

            // x{1,1} is x.
            if (re.min == 1 and re.max == 1) return sub;

            // General x{n,m}: n copies of x then nested (x(x(x)?)?) for the rest.
            var prefix: ?*Regexp = null;
            if (re.min > 0) {
                var list: std.ArrayList(*Regexp) = .empty;
                var i: i32 = 0;
                while (i < re.min) : (i += 1) try list.append(al, sub);
                prefix = try concatOf(al, &list);
            }
            if (re.max > re.min) {
                var suffix = try simplify1(al, .quest, re.flags, sub, null);
                var i: i32 = re.min + 1;
                while (i < re.max) : (i += 1) {
                    var pair: std.ArrayList(*Regexp) = .empty;
                    try pair.append(al, sub);
                    try pair.append(al, suffix);
                    const cat = try concatOf(al, &pair);
                    suffix = try simplify1(al, .quest, re.flags, cat, null);
                }
                if (prefix) |p| {
                    const newsub = try al.alloc(*Regexp, p.sub.len + 1);
                    @memcpy(newsub[0..p.sub.len], p.sub);
                    newsub[p.sub.len] = suffix;
                    p.sub = newsub;
                } else {
                    return suffix;
                }
            }
            if (prefix) |p| return p;

            // Degenerate (e.g. min > max): matches nothing.
            return try newOp(al, .no_match);
        },
        else => return re,
    }
}

/// simplify1 implements Simplify for the unary star/plus/quest operators,
/// returning the simplest regexp equivalent to {op, flags, [sub]}.
fn simplify1(al: std.mem.Allocator, op: Op, flags: Flags, sub: *Regexp, re: ?*Regexp) Error!*Regexp {
    // Repeating the empty string is still the empty string.
    if (sub.op == .empty_match) return sub;
    // The operators are idempotent when greedy-ness matches.
    if (op == sub.op and (flags & ast.NonGreedy) == (sub.flags & ast.NonGreedy)) return sub;
    if (re) |r| {
        if (r.op == op and (r.flags & ast.NonGreedy) == (flags & ast.NonGreedy) and sub == r.sub[0]) {
            return r;
        }
    }
    const nre = try al.create(Regexp);
    nre.* = .{ .op = op, .flags = flags };
    nre.sub = try al.dupe(*Regexp, &[_]*Regexp{sub});
    return nre;
}

fn newOp(al: std.mem.Allocator, op: Op) Error!*Regexp {
    const re = try al.create(Regexp);
    re.* = .{ .op = op };
    return re;
}

fn concatOf(al: std.mem.Allocator, list: *std.ArrayList(*Regexp)) Error!*Regexp {
    const re = try al.create(Regexp);
    re.* = .{ .op = .concat };
    re.sub = try list.toOwnedSlice(al);
    return re;
}

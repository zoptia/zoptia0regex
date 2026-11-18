//! Engine regression tests. Expected results were recorded from Go 1.27.1's
//! regexp.

const std = @import("std");
const regex = @import("regexp.zig");

const ta = std.testing.allocator;

fn repeated(a: std.mem.Allocator, unit: []const u8, n: usize) ![]u8 {
    const out = try a.alloc(u8, unit.len * n);
    for (0..n) |k| @memcpy(out[k * unit.len ..][0..unit.len], unit);
    return out;
}

fn expectSubmatch(a: std.mem.Allocator, re: *const regex.Regexp, input: []const u8, want: ?[]const i64) !void {
    const got = try re.findSubmatchIndex(a, input);
    defer if (got) |g| a.free(g);
    if (want) |w| {
        try std.testing.expect(got != null);
        try std.testing.expectEqualSlices(i64, w, got.?);
    } else {
        try std.testing.expect(got == null);
    }
}

// --- The Pike VM's epsilon closure must not recurse natively ---
//
// Each program is far past the size that overflowed an 8 MB native stack
// with the recursive `add` (about 21k `a??`, 10k `()`, 20k alternatives in a
// Debug build). Go answers all of them. Inputs longer than the bitstate
// limit are irrelevant here: programs over 500 instructions always run on
// the Pike VM. The deep tests allocate from an arena because a 100k-thread
// run through the checking test allocator alone takes seconds in Debug.

test "deep program: long run of lazy optionals" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var re = try regex.compile(a, try repeated(a, "a??", 150_000));
    try std.testing.expect(re.prog.insts.len > 300_000);
    try expectSubmatch(a, &re, "xyzxyzxyz", &.{ 0, 0 });
    try expectSubmatch(a, &re, "aax", &.{ 0, 0 });
}

test "deep program: long run of empty captures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 60_000;
    var re = try regex.compile(a, try repeated(a, "()", n));
    try std.testing.expect(try re.match(a, "xyzxyzxyz"));
    const got = (try re.findSubmatchIndex(a, "xyzxyzxyz")).?;
    try std.testing.expectEqual(@as(usize, 2 * (n + 1)), got.len);
    for (got) |x| try std.testing.expectEqual(@as(i64, 0), x);
}

test "deep program: wide alternation of distinct runes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    const n = 60_000;
    for (0..n) |k| {
        if (k > 0) try buf.append(a, '|');
        try buf.print(a, "\\x{{{X}}}z", .{0x10000 + k});
    }
    var re = try regex.compile(a, buf.items);
    try std.testing.expect(!try re.match(a, "xyzxyzxyz"));
    // The last alternative, U+1EA5F, preceded by two ASCII bytes.
    try expectSubmatch(a, &re, "ab\u{1EA5F}z", &.{ 2, 7 });
}

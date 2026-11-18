//! Byte-level differential test against Go: `bytes.jsonl` (from
//! `tools/genbytes.go`) stores inputs and outputs as byte arrays, so malformed
//! UTF-8 and NULs are preserved exactly. Each case checks `findSubmatchIndex`,
//! `match`, `findIndex`, `findAllSubmatchIndex` with a limit, `replaceAllString`
//! with a template, and `split`, in Perl, `setLongest` and `compilePOSIX` modes.
//!
//! Run on its own:  zig test src/bytestest.zig
const std = @import("std");
const regex = @import("regexp.zig");
const common = @import("difftest_common.zig");
const Case = struct {
    p: []const u8,
    i: []u8,
    mode: []const u8,
    n: i64,
    t: []const u8,
    err: bool,
    m: ?[]i64,
    all: ?[][]i64,
    repl: ?[]u8,
    split: ?[][]u8,
};

test "byte-level differential vs Go" {
    const allocator = std.testing.allocator;
    var lines = std.mem.tokenizeScalar(u8, @embedFile("bytes.jsonl"), '\n');
    var total: usize = 0;
    var failures: usize = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(Case, allocator, line, .{});
        defer parsed.deinit();
        total += 1;
        checkCase(allocator, parsed.value) catch |err| {
            failures += 1;
            if (failures <= 10) std.debug.print("BYTES-MISMATCH {s}: mode={s} pattern={s} input={any} n={d} template={s}\n", .{ @errorName(err), parsed.value.mode, parsed.value.p, parsed.value.i, parsed.value.n, parsed.value.t });
        };
    }
    std.debug.print("[bytes] total={d} failures={d}\n", .{ total, failures });
    try std.testing.expectEqual(@as(usize, 0), failures);
}

fn checkCase(allocator: std.mem.Allocator, c: Case) !void {
    var re = (if (std.mem.eql(u8, c.mode, "posix")) regex.compilePOSIX(allocator, c.p) else regex.compile(allocator, c.p)) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (!c.err) return error.UnexpectedCompileError;
        return;
    };
    defer re.deinit();
    if (c.err) return error.ExpectedCompileError;
    if (std.mem.eql(u8, c.mode, "longest")) re.setLongest();
    const m = try re.findSubmatchIndex(allocator, c.i);
    defer if (m) |x| allocator.free(x);
    if (!common.eqOptInts(c.m, m)) return error.MatchMismatch;
    if (try re.match(allocator, c.i) != (c.m != null)) return error.BooleanMismatch;
    const index = try re.findIndex(allocator, c.i);
    if ((index != null) != (c.m != null)) return error.IndexMismatch;
    if (index) |x| {
        if (x.start != c.m.?[0] or x.end != c.m.?[1]) return error.IndexMismatch;
    }
    const all = try re.findAllSubmatchIndex(allocator, c.i, c.n);
    defer if (all) |x| regex.Regexp.freeAllSubmatchIndex(allocator, x);
    if (!common.eqOptNested(c.all, all)) return error.AllMismatch;
    const repl = try re.replaceAllString(allocator, c.i, c.t);
    defer allocator.free(repl);
    if (!std.mem.eql(u8, c.repl.?, repl)) return error.ReplaceMismatch;
    const split = try re.split(allocator, c.i, c.n);
    defer if (split) |x| allocator.free(x);
    if ((c.split != null) != (split != null)) return error.SplitMismatch;
    if (split) |actual| {
        if (c.split.?.len != actual.len) return error.SplitMismatch;
        for (c.split.?, actual) |want, got| {
            if (!std.mem.eql(u8, want, got)) return error.SplitMismatch;
        }
    }
}

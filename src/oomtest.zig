//! Allocation-failure tests: every public API that allocates must, at every
//! possible failing allocation, return `error.OutOfMemory` and leak nothing.
//! Run: zig test src/oomtest.zig
const std = @import("std");
const regex = @import("regexp.zig");

const ta = std.testing.allocator;

/// `std.testing.checkAllAllocationFailures` over `test_fn`, on a backing
/// allocator whose resizes always fail. Growth must go through alloc: an
/// in-place resize/remap succeeds or not depending on heap layout, which
/// would change the allocation count between runs
/// (NondeterministicMemoryUsage). `resize_fail_index` only advances on
/// success, so index 0 fails every resize.
fn checkAllocationFailures(test_fn: anytype, extra_args: anytype) !void {
    var no_resize = std.testing.FailingAllocator.init(ta, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), test_fn, extra_args);
}

test "OOM: scratch result growth remains safe to destroy" {
    var failing = std.testing.FailingAllocator.init(ta, .{});
    var scratch = regex.Scratch.init(failing.allocator());
    defer scratch.deinit();
    _ = try scratch.resultBuf(2);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, scratch.resultBuf(8));
}

fn compileBoth(allocator: std.mem.Allocator, pattern: []const u8) !void {
    var re = try regex.compile(allocator, pattern);
    re.deinit();
    var posix = regex.compilePOSIX(allocator, pattern) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return, // not valid POSIX syntax (e.g. \pL); fine
    };
    posix.deinit();
}

test "OOM: compilation" {
    for ([_][]const u8{ "(?P<word>[a-z]+)([0-9]+)", "\\A(?i:[a-z]+)([0-9]+)\\z", "(?i)\\p{Lu}{2,4}", "(a?)*b", "foo|foobar|bar" }) |pattern| {
        try checkAllocationFailures(compileBoth, .{pattern});
    }
}

fn upper(_: void, al: std.mem.Allocator, out: *std.ArrayList(u8), m: []const u8) regex.ExecError!void {
    const tmp = try std.ascii.allocUpperString(al, m);
    defer al.free(tmp);
    try out.appendSlice(al, tmp);
}

fn star(_: void, m: []const u8) []const u8 {
    return if (m.len > 1) "**" else "*";
}

/// Every allocating result method of `Regexp`, plus the package-level
/// helpers, on one input.
fn allApis(allocator: std.mem.Allocator, re: *const regex.Regexp, input: []const u8) !void {
    _ = try re.match(allocator, input);
    _ = try re.matchString(allocator, input);
    _ = try re.find(allocator, input);
    _ = try re.findIndex(allocator, input);

    const sub_idx = try re.findSubmatchIndex(allocator, input);
    defer if (sub_idx) |x| allocator.free(x);
    const subs = try re.findSubmatch(allocator, input);
    defer if (subs) |x| allocator.free(x);

    const all = try re.findAll(allocator, input, -1);
    defer if (all) |x| allocator.free(x);
    const all_idx = try re.findAllIndex(allocator, input, -1);
    defer if (all_idx) |x| allocator.free(x);
    const all_sub_idx = try re.findAllSubmatchIndex(allocator, input, -1);
    defer if (all_sub_idx) |x| regex.Regexp.freeAllSubmatchIndex(allocator, x);
    const all_sub = try re.findAllSubmatch(allocator, input, -1);
    defer if (all_sub) |x| regex.Regexp.freeAllSubmatch(allocator, x);

    const repl = try re.replaceAllString(allocator, input, "${word}:$2/$$");
    defer allocator.free(repl);
    const literal = try re.replaceAllLiteralString(allocator, input, "$1");
    defer allocator.free(literal);
    const func = try re.replaceAllFunc(allocator, input, {}, upper);
    defer allocator.free(func);
    const string_func = try re.replaceAllStringFunc(allocator, input, {}, star);
    defer allocator.free(string_func);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var it = try re.matches(allocator, input, -1);
    defer it.deinit();
    while (try it.next()) |m| try re.expand(allocator, &buf, "<$1|${word}>", input, m);

    const pieces = try re.split(allocator, input, -1);
    defer if (pieces) |x| allocator.free(x);

    var scratch = regex.Scratch.init(allocator);
    defer scratch.deinit();
    _ = try re.matchScratch(&scratch, input);
    _ = try re.findIndexScratch(&scratch, input);
    _ = try re.findSubmatchIndexScratch(&scratch, input);
    var sit = try re.matchesScratch(&scratch, input, -1);
    defer sit.deinit();
    while (try sit.next()) |_| {}

    const quoted = try regex.quoteMeta(allocator, "a+b[0]");
    defer allocator.free(quoted);
    _ = try regex.match(allocator, re.string(), input);
}

test "OOM: every result API, on every engine" {
    const patterns = [_][]const u8{
        "(?P<word>[a-z]+)([0-9]+)", // bitstate on short input
        "\\A(?P<word>[a-z]+)([0-9]+)", // one-pass
        "(?P<word>bb)", // literal prefix
        "a*", // empty matches
    };
    for (patterns) |p| {
        var re = try regex.compile(ta, p);
        defer re.deinit();
        try checkAllocationFailures(allApis, .{ &re, "a1 bb22 a333" });
    }
    var posix = try regex.compilePOSIX(ta, "([a-z]+)([0-9]+)|bb");
    defer posix.deinit();
    try checkAllocationFailures(allApis, .{ &posix, "a1 bb22 a333" });
}

/// Two live `matchesScratch` iterators on one scratch, plus `*Scratch`
/// calls inside the inner loop.
fn nestedScratchIterators(allocator: std.mem.Allocator, outer: *const regex.Regexp, inner: *const regex.Regexp, input: []const u8) !void {
    var scratch = regex.Scratch.init(allocator);
    defer scratch.deinit();
    var it = try outer.matchesScratch(&scratch, input, -1);
    defer it.deinit();
    while (try it.next()) |_| {
        var in = try inner.matchesScratch(&scratch, input, -1);
        defer in.deinit();
        while (try in.next()) |_| {
            _ = try outer.findSubmatchIndexScratch(&scratch, input);
            _ = try inner.findIndexScratch(&scratch, input);
        }
    }
}

test "OOM: nested matchesScratch iterators on one scratch" {
    var a = try regex.compile(ta, "(?P<word>[a-z]+)([0-9]+)");
    defer a.deinit();
    var b = try regex.compile(ta, "(a)(b)?(c)?(d)?(e)?(f)?(g)?(h)?(i)?(j)?(k)?(l)?(m)?(n)?(o)?(p)?(q)?");
    defer b.deinit();
    try checkAllocationFailures(nestedScratchIterators, .{ &a, &b, "a1 bb22 a333" });
    try checkAllocationFailures(nestedScratchIterators, .{ &b, &a, "a1 bb22 a333" });
    try checkAllocationFailures(nestedScratchIterators, .{ &a, &a, "a1 bb22 a333" });
}

fn pikeApis(allocator: std.mem.Allocator, re: *const regex.Regexp, input: []const u8) !void {
    const one = try re.findSubmatchIndex(allocator, input);
    defer if (one) |m| allocator.free(m);
    try std.testing.expect(one != null);
    const all = try re.findAllSubmatchIndex(allocator, input, -1);
    defer if (all) |m| regex.Regexp.freeAllSubmatchIndex(allocator, m);
    try std.testing.expect(all != null);
}

test "OOM: Pike VM thread creation and collected captures do not leak" {
    var re = try regex.compile(ta, "(a|b)+");
    defer re.deinit();
    try std.testing.expect(re.onepass == null);
    try checkAllocationFailures(pikeApis, .{ &re, "aa bb aa bb aa bb aa bb aa bb aa bb" });
    // The long input bypasses bitstate and forces the Pike VM.
    const input = try ta.alloc(u8, 40000);
    defer ta.free(input);
    @memset(input, 'a');
    try checkAllocationFailures(pikeApis, .{ &re, input });
}

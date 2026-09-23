//! Focused allocation-failure regressions. Run: zig test src/oomtest.zig --test-filter "OOM regression"
const std = @import("std");
const regex = @import("regexp.zig");

test "OOM regression: scratch result growth remains safe to destroy" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var scratch = regex.Scratch.init(failing.allocator());
    defer scratch.deinit();
    _ = try scratch.resultBuf(2);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, scratch.resultBuf(8));
}

fn pikeMatch(allocator: std.mem.Allocator, re: *const regex.Regexp, input: []const u8) !void {
    const result = try re.findSubmatchIndex(allocator, input);
    defer if (result) |m| allocator.free(m);
    try std.testing.expect(result != null);
}

test "OOM regression: Pike thread creation does not leak" {
    var re = try regex.compile(std.testing.allocator, "(a|b)+");
    defer re.deinit();
    const input = try std.testing.allocator.alloc(u8, 40000);
    defer std.testing.allocator.free(input);
    @memset(input, 'a');
    // The long input bypasses bitstate and forces the Pike VM.
    try std.testing.expect(re.onepass == null);
    // Growth must go through alloc: an in-place resize/remap succeeds or not
    // depending on heap layout, which would change the allocation count
    // between runs (NondeterministicMemoryUsage). resize_index only advances
    // on success, so fail index 0 fails every resize.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), pikeMatch, .{ &re, input });
}

fn collectMatches(allocator: std.mem.Allocator, re: *const regex.Regexp) !void {
    const result = try re.findAllSubmatchIndex(allocator, "aa bb aa bb aa bb aa bb aa bb aa bb", -1);
    defer if (result) |m| regex.Regexp.freeAllSubmatchIndex(allocator, m);
    try std.testing.expectEqual(@as(usize, 12), result.?.len);
}

test "OOM regression: collected capture append does not leak" {
    var re = try regex.compile(std.testing.allocator, "(a|b)+");
    defer re.deinit();
    // Growth must go through alloc: an in-place resize/remap succeeds or not
    // depending on heap layout, which would change the allocation count
    // between runs (NondeterministicMemoryUsage). resize_index only advances
    // on success, so fail index 0 fails every resize.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), collectMatches, .{&re});
}

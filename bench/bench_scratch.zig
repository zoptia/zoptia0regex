//! Micro-benchmark for the allocation-free `Scratch` reuse API. Per pattern it
//! times `re.match` (which allocates a fresh Machine per call — the original
//! behaviour) against `re.matchScratch` (reusing one caller-owned `Scratch`, so
//! steady-state matching does zero heap allocation). Build/run optimized:
//!
//!   zig build bench-scratch
//!
//! A u64 sink derived from every match result is printed (and fed through
//! `doNotOptimizeAway`) so the optimizer cannot hoist or drop the match calls.
//! Output columns (TSV, to stderr):  name  alloc_ns  scratch_ns  speedup  sink

const std = @import("std");
const regex = @import("regexp.zig");

const calibrate_ns: i128 = 200_000_000;

fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

const Result = struct { ns: f64, sum: u64 };
const Case = struct { name: []const u8, p: []const u8, in: []const u8 };

/// Allocating path: each call builds and frees a temporary Machine (today's
/// `re.match`).
fn calAlloc(io: std.Io, re: *regex.Regexp, gpa: std.mem.Allocator, input: []const u8) Result {
    var iters: u64 = 1;
    while (true) {
        const t0 = nowNs(io);
        var acc: u64 = 0;
        var i: u64 = 0;
        while (i < iters) : (i += 1) acc +%= @intFromBool(re.match(gpa, input) catch false);
        const ns = nowNs(io) - t0;
        if (ns > calibrate_ns) {
            std.mem.doNotOptimizeAway(acc);
            return .{ .ns = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters)), .sum = acc };
        }
        iters *= 2;
    }
}

/// Reuse path: one warmed `Scratch` shared across every call (zero allocation
/// in steady state).
fn calScratch(io: std.Io, re: *regex.Regexp, scratch: *regex.Scratch, input: []const u8) Result {
    var iters: u64 = 1;
    while (true) {
        const t0 = nowNs(io);
        var acc: u64 = 0;
        var i: u64 = 0;
        while (i < iters) : (i += 1) acc +%= @intFromBool(re.matchScratch(scratch, input) catch false);
        const ns = nowNs(io) - t0;
        if (ns > calibrate_ns) {
            std.mem.doNotOptimizeAway(acc);
            return .{ .ns = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters)), .sum = acc };
        }
        iters *= 2;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cases = [_]Case{
        .{ .name = "literal-needle", .p = "needle", .in = "a haystack with a needle hidden somewhere near the end" },
        .{ .name = "alternation", .p = "(foo|bar|baz)+", .in = "zz bar foo baz qux barbaz zz" },
        .{ .name = "email-unanchored", .p = "[a-z]+@[a-z]+\\.[a-z]+", .in = "please contact us at user@example.com today" },
        .{ .name = "charclass-plus", .p = "[0-9]+", .in = "order 12345 shipped on 2024" },
        .{ .name = "anchored-onepass", .p = "\\A\\d+\\z", .in = "1234567890" }, // one-pass: expect ~unchanged
    };

    std.debug.print("name\talloc_ns\tscratch_ns\tspeedup\tsink\n", .{});
    for (cases) |c| {
        var re = try regex.compile(gpa, c.p);
        defer re.deinit();

        var scratch = regex.Scratch.init(gpa);
        defer scratch.deinit();
        _ = re.matchScratch(&scratch, c.in) catch false; // warm the scratch buffers

        const a = calAlloc(io, &re, gpa, c.in);
        const b = calScratch(io, &re, &scratch, c.in);
        const speedup = a.ns / b.ns;
        std.debug.print("{s}\t{d:.0}\t{d:.0}\t{d:.2}x\t{d}\n", .{ c.name, a.ns, b.ns, speedup, a.sum +% b.sum });
    }
}

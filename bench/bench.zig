//! Zig-side benchmark harness: times this regexp port on the shared cases
//! (src/bench.jsonl + corpus), using the same calibration methodology as the
//! Go harness (tools/benchgo.go). Build optimized and run:
//!
//!   zig run -OReleaseFast src/bench.zig
//!
//! Per-iteration scratch uses an arena reset (retain_capacity) so allocation
//! cost is a cheap bump, isolating engine throughput (Go amortizes the same
//! way via its machine sync.Pool). Output columns (TSV, to stderr):
//!   name  compile_ns  op_ns  MB/s  checksum

const std = @import("std");
const regex = @import("regexp.zig");

const cases_data = @embedFile("bench.jsonl");
const corpus = @embedFile("bench_corpus.txt");
const aaa = @embedFile("bench_aaa.txt");

const Case = struct { name: []const u8, p: []const u8, op: []const u8, in: []const u8, lit: []const u8 };
const Op = enum { match, find, findall, submatch };

const calibrate_ns: i128 = 250_000_000;
const compile_target_ns: i128 = 100_000_000;

fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();

    var it = std.mem.tokenizeScalar(u8, cases_data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Case, gpa, line, .{});
        defer parsed.deinit();
        const c = parsed.value;
        const input = if (c.lit.len > 0) c.lit else if (std.mem.eql(u8, c.in, "aaa")) aaa else corpus;
        const op: Op = if (std.mem.eql(u8, c.op, "match")) .match else if (std.mem.eql(u8, c.op, "find")) .find else if (std.mem.eql(u8, c.op, "submatch")) .submatch else .findall;

        const comp_ns = calibrateCompile(io, gpa, c.p);

        var re = try regex.compile(gpa, c.p);
        defer re.deinit();

        const r = calibrate(io, &re, op, input, &scratch);
        const mbps = @as(f64, @floatFromInt(input.len)) * 1000.0 / r.ns;
        std.debug.print("{s}\t{d:.0}\t{d:.1}\t{d:.2}\t{d}\n", .{ c.name, comp_ns, r.ns, mbps, r.sum });
    }
}

fn runOp(re: *regex.Regexp, op: Op, input: []const u8, scratch: *std.heap.ArenaAllocator) u64 {
    _ = scratch.reset(.retain_capacity);
    const a = scratch.allocator();
    switch (op) {
        .match => return @intFromBool(re.match(a, input) catch false),
        .find => {
            const m = re.findIndex(a, input) catch null;
            return if (m) |x| @intCast(x.start + x.end) else 0;
        },
        .findall => {
            const x = re.findAllIndex(a, input, -1) catch null;
            return if (x) |s| s.len else 0;
        },
        .submatch => {
            const x = re.findSubmatchIndex(a, input) catch null;
            return if (x) |s| s.len else 0;
        },
    }
}

const Result = struct { ns: f64, sum: u64 };

fn calibrate(io: std.Io, re: *regex.Regexp, op: Op, input: []const u8, scratch: *std.heap.ArenaAllocator) Result {
    var iters: u64 = 1;
    while (true) {
        const t0 = nowNs(io);
        var acc: u64 = 0;
        var i: u64 = 0;
        while (i < iters) : (i += 1) acc +%= runOp(re, op, input, scratch);
        const ns = nowNs(io) - t0;
        if (ns > calibrate_ns) {
            std.mem.doNotOptimizeAway(acc);
            return .{ .ns = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters)), .sum = acc };
        }
        iters *= 2;
    }
}

fn calibrateCompile(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8) f64 {
    var iters: u64 = 1;
    while (true) {
        const t0 = nowNs(io);
        var acc: u64 = 0;
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            var re = regex.compile(gpa, pattern) catch unreachable;
            acc +%= re.numSubexp();
            re.deinit();
        }
        const ns = nowNs(io) - t0;
        if (ns > compile_target_ns) {
            std.mem.doNotOptimizeAway(acc);
            return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters));
        }
        iters *= 2;
    }
}

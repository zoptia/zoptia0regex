//! Zig-side throughput benchmark: times this regexp port on the shared cases
//! (`data/bench.jsonl` + corpus) with the same calibration as the Go harness
//! (`tools/cmd/benchgo`). Run `zig build bench` (always ReleaseFast), or
//! `tools/bench.sh` to run both sides and regenerate BENCHMARKS.md.
//!
//! Per-iteration scratch uses an arena reset (retain_capacity), so allocation
//! is a cheap bump, the analogue of Go's per-Regexp machine pool.
//!
//! Output (stdout, TSV after a `# key=value` meta line):
//!   name  op  engine  compile_ns  op_ns  mb_s  result
//! `result` is the value of one single run of the operation (see `runOp`),
//! computed exactly like the Go harness's, so the two can be cross-checked.
//! `engine` is the engine the port's dispatch picks for this input.

const std = @import("std");
const builtin = @import("builtin");
const regex = @import("regex");

const cases_data = @embedFile("data/bench.jsonl");
const corpus = @embedFile("data/bench_corpus.txt");
const aaa = @embedFile("data/bench_aaa.txt");

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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    try out.print("# zig={s} target={s}-{s}\n", .{ builtin.zig_version_string, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
    try out.print("name\top\tengine\tcompile_ns\top_ns\tmb_s\tresult\n", .{});

    var it = std.mem.tokenizeScalar(u8, cases_data, '\n');
    while (it.next()) |line| {
        const parsed = try std.json.parseFromSlice(Case, gpa, line, .{});
        defer parsed.deinit();
        const c = parsed.value;
        const input = if (c.lit.len > 0) c.lit else if (std.mem.eql(u8, c.in, "aaa")) aaa else if (std.mem.eql(u8, c.in, "corpus")) corpus else std.debug.panic("{s}: unknown input {s}", .{ c.name, c.in });
        const op = std.meta.stringToEnum(Op, c.op) orelse std.debug.panic("{s}: unknown op {s}", .{ c.name, c.op });

        const comp_ns = calibrateCompile(io, gpa, c.p);

        var re = regex.compile(gpa, c.p) catch |e| std.debug.panic("{s}: compile: {s}", .{ c.name, @errorName(e) });
        defer re.deinit();

        const result = runOp(&re, op, input, &arena);
        const ns = calibrate(io, &re, op, input, &arena);
        const mbps = @as(f64, @floatFromInt(input.len)) * 1000.0 / ns;
        try out.print("{s}\t{s}\t{s}\t{d:.0}\t{d:.1}\t{d:.2}\t{d}\n", .{ c.name, c.op, engineName(&re, op, input), comp_ns, ns, mbps, result });
    }
    try out.flush();
}

/// The engine the port runs for one search of `input` (mirrors
/// `Regexp.findAt` and `exec.executeReuse`), plus the scan accelerator.
fn engineName(re: *const regex.Regexp, op: Op, input: []const u8) []const u8 {
    const whole_match_only = op != .submatch;
    if (re.literal and whole_match_only) return "literal";
    if (re.onepass != null) return "one-pass";
    const ninst = re.prog.insts.len;
    const bt = regex.syntax.backtrack;
    const bitstate = ninst <= bt.max_backtrack_prog and input.len < bt.max_backtrack_vector / ninst;
    if (re.prefix.len > 0) return if (bitstate) "bitstate+prefix" else "Pike VM+prefix";
    if (re.first_bytes.len > 0) return if (bitstate) "bitstate+first-bytes" else "Pike VM+first-bytes";
    return if (bitstate) "bitstate" else "Pike VM";
}

/// One operation; its value derives from the full result and matches the
/// Go harness's `runOp`. Any engine error aborts the benchmark.
fn runOp(re: *regex.Regexp, op: Op, input: []const u8, arena: *std.heap.ArenaAllocator) u64 {
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    switch (op) {
        .match => return @intFromBool(re.match(a, input) catch |e| fail(e)),
        .find => {
            const m = (re.findIndex(a, input) catch |e| fail(e)) orelse return 0;
            return m.start + m.end + 1;
        },
        .findall => {
            const all = (re.findAllIndex(a, input, -1) catch |e| fail(e)) orelse return 0;
            var sum: u64 = 0;
            for (all) |m| sum += m.start + m.end + 1;
            return sum;
        },
        .submatch => {
            const caps = (re.findSubmatchIndex(a, input) catch |e| fail(e)) orelse return 0;
            var sum: u64 = 0;
            for (caps) |x| sum +%= @bitCast(x + 1);
            return sum;
        },
    }
}

fn fail(e: anyerror) noreturn {
    std.debug.panic("benchmark operation failed: {s}", .{@errorName(e)});
}

/// Batches timed at the calibrated iteration count. The fastest one is
/// reported, so a burst of background load cannot inflate a row.
const batches = 5;

/// Doubles the iteration count until one batch of `batch(ctx, iters)`
/// exceeds `target_ns`, times `batches` batches in all at that count and
/// returns the fastest batch's ns per iteration.
fn bestOf(io: std.Io, target_ns: i128, ctx: anytype, comptime batch: fn (@TypeOf(ctx), u64) void) f64 {
    var iters: u64 = 1;
    var best: i128 = undefined;
    while (true) {
        const t0 = nowNs(io);
        batch(ctx, iters);
        best = nowNs(io) - t0;
        if (best > target_ns) break;
        iters *= 2;
    }
    var k: usize = 1;
    while (k < batches) : (k += 1) {
        const t0 = nowNs(io);
        batch(ctx, iters);
        best = @min(best, nowNs(io) - t0);
    }
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(iters));
}

const OpCtx = struct { re: *regex.Regexp, op: Op, input: []const u8, arena: *std.heap.ArenaAllocator };

fn opBatch(c: OpCtx, iters: u64) void {
    var acc: u64 = 0;
    var i: u64 = 0;
    while (i < iters) : (i += 1) acc +%= runOp(c.re, c.op, c.input, c.arena);
    std.mem.doNotOptimizeAway(acc);
}

fn calibrate(io: std.Io, re: *regex.Regexp, op: Op, input: []const u8, arena: *std.heap.ArenaAllocator) f64 {
    return bestOf(io, calibrate_ns, OpCtx{ .re = re, .op = op, .input = input, .arena = arena }, opBatch);
}

const CompileCtx = struct { gpa: std.mem.Allocator, pattern: []const u8 };

fn compileBatch(c: CompileCtx, iters: u64) void {
    var acc: u64 = 0;
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        var re = regex.compile(c.gpa, c.pattern) catch |e| fail(e);
        acc +%= re.numSubexp();
        re.deinit();
    }
    std.mem.doNotOptimizeAway(acc);
}

fn calibrateCompile(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8) f64 {
    return bestOf(io, compile_target_ns, CompileCtx{ .gpa = gpa, .pattern = pattern }, compileBatch);
}

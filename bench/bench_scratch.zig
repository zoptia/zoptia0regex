//! Micro-benchmark for the allocation-free `Scratch` reuse API. Per case in
//! `data/scratch.jsonl` it times `re.match` (which sets up engine storage
//! per call) against `re.matchScratch` (reusing one caller-owned `Scratch`,
//! so steady-state matching does zero heap allocation). The Go side is
//! `tools/cmd/benchscratchgo`. Run `zig build bench-scratch` (ReleaseFast).
//!
//! Output (stdout, TSV):  name  engine  alloc_ns  scratch_ns  result
//! `result` is one single match (1 or 0), comparable with the Go side.

const std = @import("std");
const regex = @import("regex");

const cases_data = @embedFile("data/scratch.jsonl");
const calibrate_ns: i128 = 200_000_000;

const Case = struct { name: []const u8, p: []const u8, in: []const u8 };

fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn fail(e: anyerror) noreturn {
    std.debug.panic("benchmark operation failed: {s}", .{@errorName(e)});
}

/// Batches timed at the calibrated iteration count. The fastest one is
/// reported, so a burst of background load cannot inflate a row.
const batches = 5;

fn timeBatch(io: std.Io, ctx: anytype, comptime f: fn (@TypeOf(ctx)) bool, iters: u64) i128 {
    const t0 = nowNs(io);
    var acc: u64 = 0;
    var i: u64 = 0;
    while (i < iters) : (i += 1) acc +%= @intFromBool(f(ctx));
    const ns = nowNs(io) - t0;
    std.mem.doNotOptimizeAway(acc);
    return ns;
}

/// Doubles the iteration count until one batch exceeds the target, times
/// `batches` batches in all at that count and returns the fastest batch's
/// ns per call of `f(ctx)`.
fn calibrate(io: std.Io, ctx: anytype, comptime f: fn (@TypeOf(ctx)) bool) f64 {
    var iters: u64 = 1;
    var best = timeBatch(io, ctx, f, iters);
    while (best <= calibrate_ns) {
        iters *= 2;
        best = timeBatch(io, ctx, f, iters);
    }
    var k: usize = 1;
    while (k < batches) : (k += 1) best = @min(best, timeBatch(io, ctx, f, iters));
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(iters));
}

const AllocCtx = struct { re: *const regex.Regexp, gpa: std.mem.Allocator, in: []const u8 };
const ScratchCtx = struct { re: *const regex.Regexp, scratch: *regex.Scratch, in: []const u8 };

fn matchAlloc(c: AllocCtx) bool {
    return c.re.match(c.gpa, c.in) catch |e| fail(e);
}

fn matchScratch(c: ScratchCtx) bool {
    return c.re.matchScratch(c.scratch, c.in) catch |e| fail(e);
}

/// The engine `matchScratch` runs (see bench.zig's `engineName`).
fn engineName(re: *const regex.Regexp, input: []const u8) []const u8 {
    if (re.literal) return "literal";
    if (re.onepass != null) return "one-pass";
    const ninst = re.prog.insts.len;
    const bt = regex.syntax.backtrack;
    const bitstate = ninst <= bt.max_backtrack_prog and input.len < bt.max_backtrack_vector / ninst;
    if (re.prefix.len > 0) return if (bitstate) "bitstate+prefix" else "Pike VM+prefix";
    if (re.first_bytes.len > 0) return if (bitstate) "bitstate+first-bytes" else "Pike VM+first-bytes";
    return if (bitstate) "bitstate" else "Pike VM";
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    try out.print("name\tengine\talloc_ns\tscratch_ns\tresult\n", .{});

    var it = std.mem.tokenizeScalar(u8, cases_data, '\n');
    while (it.next()) |line| {
        const parsed = try std.json.parseFromSlice(Case, gpa, line, .{});
        defer parsed.deinit();
        const c = parsed.value;

        var re = regex.compile(gpa, c.p) catch |e| std.debug.panic("{s}: compile: {s}", .{ c.name, @errorName(e) });
        defer re.deinit();
        var scratch = regex.Scratch.init(gpa);
        defer scratch.deinit();

        const result = matchScratch(.{ .re = &re, .scratch = &scratch, .in = c.in }); // also warms the scratch
        if (matchAlloc(.{ .re = &re, .gpa = gpa, .in = c.in }) != result) std.debug.panic("{s}: match and matchScratch disagree", .{c.name});
        const alloc_ns = calibrate(io, AllocCtx{ .re = &re, .gpa = gpa, .in = c.in }, matchAlloc);
        const scratch_ns = calibrate(io, ScratchCtx{ .re = &re, .scratch = &scratch, .in = c.in }, matchScratch);
        try out.print("{s}\t{s}\t{d:.1}\t{d:.1}\t{d}\n", .{ c.name, engineName(&re, c.in), alloc_ns, scratch_ns, @intFromBool(result) });
    }
    try out.flush();
}

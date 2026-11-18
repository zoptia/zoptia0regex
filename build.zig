const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module: a faithful Zig port of Go's regexp package. This is
    // all a consumer gets (`b.dependency(...).module("regex")`); src/ holds
    // only the library and its unit tests.
    const regex_mod = b.addModule("regex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `check` compiles every artifact without running anything, so it works
    // for any -Dtarget (CI cross-compiles wasm32, riscv64 and x86 with it).
    const check_step = b.step("check", "Compile the library, its tests, the differential drivers, the demo and the benchmarks without running them");

    // Unit and behaviour tests over the whole library.
    const tests = b.addTest(.{ .root_module = regex_mod });
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check_step.dependOn(&tests.step);

    // A small demo executable.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("regex", regex_mod);
    const demo = b.addExecutable(.{ .name = "regex-demo", .root_module = demo_mod });
    b.installArtifact(demo);
    check_step.dependOn(&demo.step);
    const run_demo = b.addRunArtifact(demo);
    run_demo.addPassthruArgs(); // `zig build demo -- <pattern> <input>`
    const demo_step = b.step("demo", "Run the regex demo (pass: <pattern> <input>)");
    demo_step.dependOn(&run_demo.step);

    // Differential tests against Go's regexp (the golden reference): test/
    // drivers replaying the corpora in test/data/, which tools/regen.sh
    // records from Go 1.27.1. The corpora are committed, so running them
    // needs no Go toolchain. Always ReleaseSafe: the cases take about half
    // the Debug time with safety checks still on.
    const safe_regex = libModule(b, target, .ReleaseSafe);
    const difftest_step = b.step("difftest", "Differential tests vs Go's regexp, all four corpora (ReleaseSafe)");
    const corpora = [_]struct { name: []const u8, src: []const u8, desc: []const u8 }{
        .{ .name = "cases", .src = "test/difftest.zig", .desc = "curated corpus" },
        .{ .name = "fuzz", .src = "test/fuzztest.zig", .desc = "randomized Perl-syntax corpus" },
        .{ .name = "longest", .src = "test/longesttest.zig", .desc = "leftmost-longest / POSIX corpus" },
        .{ .name = "bytes", .src = "test/bytestest.zig", .desc = "byte-level corpus" },
    };
    for (corpora) |corpus| {
        const mod = b.createModule(.{
            .root_source_file = b.path(corpus.src),
            .target = target,
            .optimize = .ReleaseSafe,
        });
        mod.addImport("regex", safe_regex);
        const t = b.addTest(.{ .root_module = mod, .name = b.fmt("difftest-{s}", .{corpus.name}) });
        const run = b.addRunArtifact(t);
        difftest_step.dependOn(&run.step);
        const one = b.step(b.fmt("difftest-{s}", .{corpus.name}), b.fmt("Differential test vs Go: {s} only (ReleaseSafe)", .{corpus.desc}));
        one.dependOn(&run.step);
        check_step.dependOn(&t.step);
    }

    // Benchmarks, always ReleaseFast. Output is TSV on stdout; tools/bench.sh
    // runs them next to the Go harnesses and regenerates BENCHMARKS.md.
    const fast_regex = libModule(b, target, .ReleaseFast);
    const benches = [_]struct { step: []const u8, exe: []const u8, src: []const u8, desc: []const u8 }{
        .{ .step = "bench", .exe = "regex-bench", .src = "bench/bench.zig", .desc = "Run the throughput benchmark on the shared corpus (ReleaseFast, TSV on stdout)" },
        .{ .step = "bench-scratch", .exe = "regex-bench-scratch", .src = "bench/bench_scratch.zig", .desc = "Run the Scratch reuse micro-benchmark (ReleaseFast, TSV on stdout)" },
    };
    for (benches) |bench| {
        const mod = b.createModule(.{
            .root_source_file = b.path(bench.src),
            .target = target,
            .optimize = .ReleaseFast,
        });
        mod.addImport("regex", fast_regex);
        const exe = b.addExecutable(.{ .name = bench.exe, .root_module = mod });
        b.step(bench.step, bench.desc).dependOn(&b.addRunArtifact(exe).step);
        check_step.dependOn(&exe.step);
    }

    // Formatting gate, same as CI: `zig build fmt` fails on unformatted files.
    const fmt_step = b.step("fmt", "Check that all Zig sources are formatted");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{ b.path("src"), b.path("test"), b.path("bench"), b.path("build.zig") },
        .check = true,
    }).step);
}

/// The library as a separate module instance at a fixed optimize mode, for
/// the differential drivers (ReleaseSafe) and benchmarks (ReleaseFast).
fn libModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}

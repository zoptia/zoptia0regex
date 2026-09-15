const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module: a faithful Zig port of Go's regexp package.
    const regex_mod = b.addModule("regex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests over the whole library.
    const tests = b.addTest(.{
        .root_module = regex_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_tests.step);

    // A small demo executable.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("regex", regex_mod);
    const demo = b.addExecutable(.{
        .name = "regex-demo",
        .root_module = demo_mod,
    });
    b.installArtifact(demo);
    const run_demo = b.addRunArtifact(demo);
    // Forward `zig build demo -- <args>`. Zig 0.16 exposes them as `b.args`;
    // 0.17-dev replaced that field with `Run.addPassthruArgs`. A dependency's
    // build.zig is compiled into every consumer's build runner, so both
    // toolchains must compile this file.
    if (@hasField(std.Build, "args")) {
        if (b.args) |args| run_demo.addArgs(args);
    } else {
        run_demo.addPassthruArgs();
    }
    const demo_step = b.step("demo", "Run the regex demo (pass: <pattern> <input>)");
    demo_step.dependOn(&run_demo.step);

    // Benchmark (always ReleaseFast). Compare with `cd tools && go run benchgo.go`.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_exe = b.addExecutable(.{ .name = "regex-bench", .root_module = bench_mod });
    const bench_step = b.step("bench", "Run the Zig benchmark vs the shared corpus (ReleaseFast)");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    // Scratch-reuse micro-benchmark: re.match (allocating) vs re.matchScratch.
    const bench_scratch_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_scratch.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_scratch_exe = b.addExecutable(.{ .name = "regex-bench-scratch", .root_module = bench_scratch_mod });
    const bench_scratch_step = b.step("bench-scratch", "Benchmark the Scratch reuse API vs allocating match (ReleaseFast)");
    bench_scratch_step.dependOn(&b.addRunArtifact(bench_scratch_exe).step);

    // Differential tests against Go's regexp output (golden reference). All
    // four corpora (src/cases.jsonl, src/fuzz.jsonl, src/longest.jsonl,
    // src/bytes.jsonl) are
    // committed — regenerate them with tools/regen.sh only when the generators
    // change; running the tests needs no Go toolchain.
    const difftest_step = b.step("difftest", "Differential test vs Go's regexp (curated + fuzz + POSIX + byte-level corpora)");
    inline for (.{ "src/difftest.zig", "src/fuzztest.zig", "src/longesttest.zig", "src/bytestest.zig" }) |src| {
        const mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
        });
        const t = b.addTest(.{ .root_module = mod });
        difftest_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Formatting gate, same as CI: `zig build fmt` fails on unformatted files.
    const fmt_step = b.step("fmt", "Check that all Zig sources are formatted");
    // Fmt.Options.paths is `[]const []const u8` on 0.16 and `[]const LazyPath`
    // on 0.17-dev; pick the element type the running std expects.
    const FmtPath = @typeInfo(@FieldType(std.Build.Step.Fmt.Options, "paths")).pointer.child;
    const fmt_paths: []const FmtPath = if (FmtPath == std.Build.LazyPath)
        &.{ b.path("src"), b.path("build.zig") }
    else
        &.{ "src", "build.zig" };
    fmt_step.dependOn(&b.addFmt(.{
        .paths = fmt_paths,
        .check = true,
    }).step);
}

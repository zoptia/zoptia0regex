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
    if (b.args) |args| run_demo.addArgs(args);
    const demo_step = b.step("demo", "Run the regex demo (pass: <pattern> <input>)");
    demo_step.dependOn(&run_demo.step);

    // Differential tests against Go's regexp output (golden reference).
    // The curated corpus (src/cases.jsonl) is committed; the large fuzz corpus
    // (src/fuzz.jsonl) is generated on demand by tools/regen.sh.
    const difftest_step = b.step("difftest", "Differential test vs Go's regexp (curated + fuzz corpora)");
    inline for (.{ "src/difftest.zig", "src/fuzztest.zig", "src/longesttest.zig" }) |src| {
        const mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
        });
        const t = b.addTest(.{ .root_module = mod });
        difftest_step.dependOn(&b.addRunArtifact(t).step);
    }
}

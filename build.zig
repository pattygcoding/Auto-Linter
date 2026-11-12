const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The browser module: wasm32-freestanding, no WASI imports, memory exported.
    const wasm = b.addExecutable(.{
        .name = "formatter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = optimize,
            .single_threaded = true,
        }),
    });
    // A reactor-style module: no `_start`, but the exported bridge functions and
    // the linear memory stay visible to `formatter.js`.
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_memory = true;
    b.installArtifact(wasm);

    // The formatter modules are shared by the tests and by the WebAssembly build.
    const formatter_module = b.addModule("formatter", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{ .root_module = formatter_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.setCwd(b.path("."));

    // Regression tests over the committed fixtures.
    const fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "formatter", .module = formatter_module },
            },
        }),
    });
    const run_fixture_tests = b.addRunArtifact(fixture_tests);
    run_fixture_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run the formatter tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_fixture_tests.step);

    // `zig build generate-stress` regenerates the fixtures in test/stress.
    const generator = b.addExecutable(.{
        .name = "generate-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate_stress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_generator = b.addRunArtifact(generator);
    run_generator.setCwd(b.path("."));
    const generate_step = b.step("generate-stress", "Regenerate the stress fixtures");
    generate_step.dependOn(&run_generator.step);
}

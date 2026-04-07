const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "aiverify-zig",
        .root_module = root_mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run AI Verify Zig compatibility runtime").dependOn(&run_cmd.step);

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const metadata_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/metadata.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_metadata_tests = b.addRunArtifact(metadata_tests);

    const python_bridge_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/python_bridge.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_python_bridge_tests = b.addRunArtifact(python_bridge_tests);

    const test_engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/test_engine.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_test_engine_tests = b.addRunArtifact(test_engine_tests);

    const apigw_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/apigw.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_apigw_tests = b.addRunArtifact(apigw_tests);

    const worker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/worker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_worker_tests = b.addRunArtifact(worker_tests);

    const worker_loop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/worker_loop.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_worker_loop_tests = b.addRunArtifact(worker_loop_tests);

    const mojo_metrics_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/mojo_metrics.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_mojo_metrics_tests = b.addRunArtifact(mojo_metrics_tests);

    const test_step = b.step("test", "Run AI Verify Zig unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_metadata_tests.step);
    test_step.dependOn(&run_python_bridge_tests.step);
    test_step.dependOn(&run_test_engine_tests.step);
    test_step.dependOn(&run_apigw_tests.step);
    test_step.dependOn(&run_worker_tests.step);
    test_step.dependOn(&run_worker_loop_tests.step);
    test_step.dependOn(&run_mojo_metrics_tests.step);
}

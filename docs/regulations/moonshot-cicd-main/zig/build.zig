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
        .name = "moonshot-cicd-zig",
        .root_module = root_mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run moonshot Zig compatibility runtime").dependOn(&run_cmd.step);

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const entity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/domain/entities.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_entity_tests = b.addRunArtifact(entity_tests);

    const file_format_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/adapters/file_format.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_file_format_tests = b.addRunArtifact(file_format_tests);

    const storage_provider_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/adapters/storage_provider.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_storage_provider_tests = b.addRunArtifact(storage_provider_tests);

    const connector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/connector_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_connector_tests = b.addRunArtifact(connector_tests);

    const app_config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app_config_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_app_config_tests = b.addRunArtifact(app_config_tests);

    const task_manager_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/task_manager_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_task_manager_tests = b.addRunArtifact(task_manager_tests);

    const test_step = b.step("test", "Run moonshot zig unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_entity_tests.step);
    test_step.dependOn(&run_file_format_tests.step);
    test_step.dependOn(&run_storage_provider_tests.step);
    test_step.dependOn(&run_connector_tests.step);
    test_step.dependOn(&run_app_config_tests.step);
    test_step.dependOn(&run_task_manager_tests.step);
}

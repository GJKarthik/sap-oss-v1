const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main pipeline executable
    const exe = b.addExecutable(.{
        .name = "text2sql-pipeline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the pipeline");
    run_step.dependOn(&run_cmd.step);

    // Tests — add all source modules
    const test_modules = [_][]const u8{
        "src/main.zig",
        "src/csv_parser.zig",
        "src/schema_registry.zig",
        "src/schema_extractor.zig",
        "src/hierarchy_parser.zig",
        "src/json_emitter.zig",
        "src/template_parser.zig",
        "src/hana_sql_builder.zig",
        "src/template_expander.zig",
        "src/spider_formatter.zig",
    };

    const test_step = b.step("test", "Run all unit tests");
    for (test_modules) |mod| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(mod),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
}


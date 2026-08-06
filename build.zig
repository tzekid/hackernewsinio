const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const turso_native_path = b.option(
        []const u8,
        "turso-native-path",
        "Prefix containing a prebuilt Turso SDK Kit",
    );
    const turso_linkage = b.option(
        []const u8,
        "turso-linkage",
        "Turso native linkage: static (default) or dynamic",
    ) orelse "static";
    const turso_native = if (turso_native_path == null) "source" else "system";
    if (turso_native_path == null) ensureCargoOnPath(b);
    const turso_dependency = if (turso_native_path) |prefix|
        b.dependency("turso", .{
            .target = target,
            .optimize = optimize,
            .native = turso_native,
            .linkage = turso_linkage,
            .@"native-path" = prefix,
            .encryption = false,
            .fts = false,
            .sync = false,
        })
    else
        b.dependency("turso", .{
            .target = target,
            .optimize = optimize,
            .native = turso_native,
            .linkage = turso_linkage,
            .encryption = false,
            .fts = false,
            .sync = false,
        });
    const web_dependency = b.dependency("web", .{
        .target = target,
        .optimize = optimize,
    });
    const passcay_module = b.dependency("passcay", .{
        .target = target,
        .optimize = optimize,
    }).module("passcay");
    const zbor_module = b.dependency("zbor", .{
        .target = target,
        .optimize = optimize,
    }).module("zbor");
    const htmx_dependency = b.dependency("htmx", .{});

    const app_module = applicationModule(
        b,
        target,
        optimize,
        turso_dependency.module("turso"),
        web_dependency,
        passcay_module,
        zbor_module,
        htmx_dependency,
        "src/main.zig",
    );
    const executable = b.addExecutable(.{
        .name = "hn-continuity",
        .root_module = app_module,
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    run_command.addPassthruArgs();
    b.step("run", "Run HN Continuity").dependOn(&run_command.step);

    const tests = b.addTest(.{
        .root_module = applicationModule(
            b,
            target,
            optimize,
            turso_dependency.module("turso"),
            web_dependency,
            passcay_module,
            zbor_module,
            htmx_dependency,
            "src/root.zig",
        ),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit and integration tests").dependOn(&run_tests.step);

    const e2e = b.addSystemCommand(&.{ "bash", "tests/e2e.sh" });
    e2e.addArtifactArg(executable);
    const fixture_server = b.addExecutable(.{
        .name = "hn-fixture-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixture_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    e2e.addArtifactArg(fixture_server);
    e2e.step.dependOn(b.getInstallStep());
    b.step("e2e", "Run real-process end-to-end journeys").dependOn(&e2e.step);
}

fn applicationModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    turso_module: *std.Build.Module,
    web_dependency: *std.Build.Dependency,
    passcay_module: *std.Build.Module,
    zbor_module: *std.Build.Module,
    htmx_dependency: *std.Build.Dependency,
    root_path: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "turso", .module = turso_module },
            .{ .name = "web_html", .module = web_dependency.module("web_html") },
            .{ .name = "web_request", .module = web_dependency.module("web_request") },
            .{ .name = "web_response", .module = web_dependency.module("web_response") },
            .{ .name = "web_router", .module = web_dependency.module("web_router") },
            .{ .name = "web_security_headers", .module = web_dependency.module("web_security_headers") },
            .{ .name = "web_server", .module = web_dependency.module("web_server") },
            .{ .name = "passcay", .module = passcay_module },
            .{ .name = "zbor", .module = zbor_module },
        },
    });
    module.addAnonymousImport("htmx_js", .{
        .root_source_file = htmx_dependency.path("dist/htmx.min.js"),
    });
    module.addAnonymousImport("htmx_sse_js", .{
        .root_source_file = htmx_dependency.path("dist/ext/hx-sse.min.js"),
    });
    module.addAnonymousImport("app_css", .{ .root_source_file = b.path("assets/app.css") });
    module.addAnonymousImport("keyboard_js", .{ .root_source_file = b.path("assets/keyboard.js") });
    module.addAnonymousImport("passkeys_js", .{ .root_source_file = b.path("assets/passkeys.js") });
    return module;
}

fn ensureCargoOnPath(b: *std.Build) void {
    if (b.findProgram(.{ .names = &.{"cargo"} }) != null) return;
    const home = b.graph.environ_map.get("HOME") orelse "";
    const directory = b.pathJoin(&.{ home, ".cargo", "bin" });
    const candidate = b.pathJoin(&.{ directory, "cargo" });
    if (b.findProgram(.{ .names = &.{candidate} }) == null) {
        @panic("Turso source build requires cargo; use -Dturso-native-path for a prebuilt SDK Kit");
    }
    const previous = b.graph.environ_map.get("PATH") orelse "";
    const repaired = b.fmt("{s}{c}{s}", .{ directory, std.fs.path.delimiter, previous });
    b.graph.environ_map.put("PATH", repaired) catch @panic("OOM");
}

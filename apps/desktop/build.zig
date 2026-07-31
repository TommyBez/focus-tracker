//! This build belongs to your app, written once by `native eject`:
//! the `native` CLI stops generating a build graph and
//! drives this file through `zig build` instead, and it will
//! never rewrite it. `addApp` wires the complete standard app
//! build — executable, `zig build run`, `zig build test`, and
//! the -Dplatform/-Dweb-engine/-Dautomation/-Doptimize flags —
//! from the framework's build/app.zig, so a framework upgrade
//! still upgrades your build. Extend from here with
//! `addAppArtifacts` when you need extra sources or steps.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const sdk = b.dependency("native_sdk", .{});
    const staged_inputs = stageTypeScriptCore(b, sdk);

    // A custom entry point is the only native seam this app owns. The
    // framework still supplies the complete runner/build/package graph;
    // our entry point only binds the SQLite host service before handing
    // the UiApp to that runner.
    const artifacts = native_sdk.addAppArtifacts(b, sdk, .{
        .name = "focus-tracker",
        .main = "src/native/main.zig",
    });

    addNativeImports(b, artifacts.exe.root_module, staged_inputs);
    addNativeImports(b, artifacts.tests.root_module, staged_inputs);

    // macOS ships libsqlite3. Linking the system library keeps the bundle
    // small and receives Apple's SQLite security/bug-fix updates.
    const sqlite_link_options: std.Build.Module.LinkSystemLibraryOptions = .{
        // Resolve Apple's dynamic libsqlite3; no Homebrew runtime dependency
        // is introduced into the app bundle.
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };
    // Native SDK selects the active Xcode sysroot. Zig 0.16 requires its
    // usr/lib to be an explicit search path for non-libc system libraries.
    if (b.sysroot) |sysroot| {
        // For Darwin targets Zig interprets an absolute -L path relative to
        // --sysroot. Passing the host-expanded SDK path would therefore
        // prepend the sysroot twice.
        const sdk_libraries: std.Build.LazyPath = .{ .cwd_relative = "/usr/lib" };
        artifacts.exe.root_module.addLibraryPath(sdk_libraries);
        artifacts.tests.root_module.addLibraryPath(sdk_libraries);
        // Clang-style header search paths, unlike Darwin linker -L paths,
        // are not made sysroot-relative automatically by Zig 0.16.
        const sdk_headers: std.Build.LazyPath = .{
            .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }),
        };
        artifacts.exe.root_module.addSystemIncludePath(sdk_headers);
        artifacts.tests.root_module.addSystemIncludePath(sdk_headers);
    }
    artifacts.exe.root_module.linkSystemLibrary("sqlite3", sqlite_link_options);
    artifacts.tests.root_module.linkSystemLibrary("sqlite3", sqlite_link_options);

    addSqliteTestStep(b, artifacts.tests.root_module, sqlite_link_options);
}

/// Keep persistence independently testable when a TypeScript checker error
/// prevents the full app graph from reaching native semantic analysis.
fn addSqliteTestStep(
    b: *std.Build,
    app_test_root: *std.Build.Module,
    sqlite_link_options: std.Build.Module.LinkSystemLibraryOptions,
) void {
    const sqlite_module = b.createModule(.{
        .root_source_file = b.path("src/native/sqlite_extension.zig"),
        .target = app_test_root.resolved_target,
        .optimize = app_test_root.optimize,
    });
    const native_sdk_module = app_test_root.import_table.get("native_sdk") orelse
        @panic("Native SDK app module did not expose its native_sdk import");
    sqlite_module.addImport("native_sdk", native_sdk_module);
    if (b.sysroot) |sysroot| {
        sqlite_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        sqlite_module.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }),
        });
    }
    sqlite_module.linkSystemLibrary("sqlite3", sqlite_link_options);

    const tests = b.addTest(.{ .root_module = sqlite_module });
    const run = b.addRunArtifact(tests);
    const step = b.step("sqlite-test", "Run the isolated SQLite extension tests");
    step.dependOn(&run.step);
}

fn addNativeImports(
    b: *std.Build,
    root: *std.Build.Module,
    staged: StagedInputs,
) void {
    root.addImport("core", b.createModule(.{ .root_source_file = staged.core }));
    root.addImport("app_markup", b.createModule(.{ .root_source_file = staged.markup }));
    root.addImport("settings_markup", b.createModule(.{ .root_source_file = staged.settings_markup }));
    root.addImport("quick_markup", b.createModule(.{ .root_source_file = staged.quick_markup }));
    // addAppArtifacts already creates the canonical manifest module for
    // its runner. Reuse that exact module object: Zig rejects loading the
    // same .zon file into two distinct modules in one compilation graph.
    const runner_module = root.import_table.get("runner") orelse
        @panic("Native SDK app module did not expose its runner import");
    const manifest_module = runner_module.import_table.get("app_manifest_zon") orelse
        @panic("Native SDK runner did not expose its manifest import");
    root.addImport("app_manifest_zon", manifest_module);
}

/// Reproduce the SDK's documented TS-core staging step while keeping a
/// custom native entry point. The transpiler remains framework-owned and
/// pinned by the native_sdk dependency; this app does not vendor it.
const StagedInputs = struct {
    core: std.Build.LazyPath,
    markup: std.Build.LazyPath,
    settings_markup: std.Build.LazyPath,
    quick_markup: std.Build.LazyPath,
};

fn stageTypeScriptCore(b: *std.Build, sdk: *std.Build.Dependency) StagedInputs {
    const node = b.findProgram(&.{"node"}, &.{}) catch {
        @panic("building the TypeScript core requires Node.js on PATH");
    };
    const transpile = b.addSystemCommand(&.{node});
    // The Native CLI package ships the pinned TypeScript compiler next to its SDK
    // source and exposes that source as NATIVE_SDK_PATH. A Zig package
    // archive intentionally has no node_modules, so use the active CLI's
    // matching authoring toolchain when available while the runtime/build
    // modules remain locked to build.zig.zon's exact SDK content hash.
    transpile.addFileArg(toolingFile(b, sdk, "build/ts_run.mjs"));
    transpile.addFileArg(toolingFile(b, sdk, "packages/core/src/cli.ts"));
    transpile.addFileArg(b.path("src/core.ts"));
    transpile.addArg("-o");
    const emitted_core = transpile.addOutputFileArg("core.zig");

    addTypeScriptInputs(b, b, transpile, "src");
    addTypeScriptInputs(b, sdk.builder, transpile, "packages/core/sdk");
    const transpiler_sources = [_][]const u8{
        "checker.ts",
        "cli.ts",
        "diagnostics.ts",
        "emitter.ts",
        "infer.ts",
        "modules.ts",
        "transpile.ts",
        "typed_ast.ts",
        "types.ts",
    };
    for (transpiler_sources) |source| {
        transpile.addFileInput(toolingFile(b, sdk, b.fmt("packages/core/src/{s}", .{source})));
    }

    // core.zig imports rt.zig by relative path, so stage the two files as
    // siblings exactly as the standard zero-config runner does.
    const staged = b.addWriteFiles();
    const core_root = staged.addCopyFile(emitted_core, "core.zig");
    _ = staged.addCopyFile(sdk.path("packages/core/rt/rt.zig"), "rt.zig");
    _ = staged.addCopyFile(b.path("src/app.native"), "app.native");
    _ = staged.addCopyFile(b.path("src/settings.native"), "settings.native");
    _ = staged.addCopyFile(b.path("src/quick.native"), "quick.native");
    const markup_root = staged.add("markup.zig", "pub const source = @embedFile(\"app.native\");\n");
    const settings_markup_root = staged.add("settings_markup.zig", "pub const source = @embedFile(\"settings.native\");\n");
    const quick_markup_root = staged.add("quick_markup.zig", "pub const source = @embedFile(\"quick.native\");\n");
    return .{
        .core = core_root,
        .markup = markup_root,
        .settings_markup = settings_markup_root,
        .quick_markup = quick_markup_root,
    };
}

fn toolingFile(b: *std.Build, sdk: *std.Build.Dependency, relative: []const u8) std.Build.LazyPath {
    if (b.graph.environ_map.get("NATIVE_SDK_PATH")) |configured| {
        const root = if (std.fs.path.isAbsolute(configured)) configured else b.pathFromRoot(configured);
        return .{ .cwd_relative = b.pathJoin(&.{ root, relative }) };
    }
    return sdk.path(relative);
}

fn addTypeScriptInputs(
    b: *std.Build,
    owner: *std.Build,
    command: *std.Build.Step.Run,
    directory: []const u8,
) void {
    var dir = owner.build_root.handle.openDir(b.graph.io, directory, .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".ts")) continue;
        const path = owner.path(b.fmt("{s}/{s}", .{ directory, entry.path }));
        command.addFileInput(path);
    }
}

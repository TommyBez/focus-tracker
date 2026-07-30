//! Native entry point for the TypeScript app core.
//!
//! This is intentionally a thin copy of Native SDK's generated TS runner:
//! it resolves manifest assets/environment, creates `TsUiApp(core)`, binds
//! the SQLite host-call service, then hands the app to the stock runner.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const manifest = @import("app_manifest_zon");
const sqlite = @import("sqlite_extension.zig");
pub const core = @import("core");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);
pub const Model = core.Model;
pub const Msg = core.Msg;

const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;
const shell_scene = native_sdk.app_manifest.shellConfigFrom(manifest);
const canvas_label = native_sdk.app_manifest.firstGpuSurfaceLabel(shell_scene);
pub const app_markup = @import("app_markup").source;
pub const settings_markup = @import("settings_markup").source;
pub const quick_markup = @import("quick_markup").source;
const SettingsView = native_sdk.canvas.CompiledMarkupView(Model, Msg, settings_markup);
const QuickView = native_sdk.canvas.CompiledMarkupView(Model, Msg, quick_markup);
const app_permissions = manifestStringList(manifest, "permissions");
const allowed_origins = manifestAllowedOrigins();
const tray_icon_relative_path = "assets/tray-template.png";

/// Native SDK 0.6.2 resolves most packaged assets through NSBundle, but its
/// NSStatusItem icon loader receives the path verbatim. Convert the executable
/// location into the absolute Resources path inside a real .app while keeping
/// repository-relative development launches unchanged.
fn trayIconPathForExecutable(executable_path: []const u8, output: []u8) []const u8 {
    const macos_dir = std.fs.path.dirname(executable_path) orelse return tray_icon_relative_path;
    if (!std.mem.eql(u8, std.fs.path.basename(macos_dir), "MacOS")) return tray_icon_relative_path;
    const contents_dir = std.fs.path.dirname(macos_dir) orelse return tray_icon_relative_path;
    if (!std.mem.eql(u8, std.fs.path.basename(contents_dir), "Contents")) return tray_icon_relative_path;
    const bundle_dir = std.fs.path.dirname(contents_dir) orelse return tray_icon_relative_path;
    if (!std.mem.endsWith(u8, std.fs.path.basename(bundle_dir), ".app")) return tray_icon_relative_path;
    return std.fmt.bufPrint(output, "{s}/Resources/{s}", .{ contents_dir, tray_icon_relative_path }) catch tray_icon_relative_path;
}

fn resolvedTrayIconPath(io: std.Io, executable_buffer: []u8, output: []u8) []const u8 {
    const executable_len = std.process.executablePath(io, executable_buffer) catch return tray_icon_relative_path;
    return trayIconPathForExecutable(executable_buffer[0..executable_len], output);
}

pub fn main(init: std.process.Init) !void {
    var executable_path_buffer: [4096]u8 = undefined;
    var tray_icon_path_buffer: [4096]u8 = undefined;
    const tray_icon_path = resolvedTrayIconPath(init.io, &executable_path_buffer, &tray_icon_path_buffer);

    var options: Adapter.Options = .{
        .name = manifest.name,
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .markup = .{
            .source = app_markup,
            .watch_path = "src/app.native",
            .io = init.io,
        },
        .theme = comptime runner.manifestThemePack(),
        .theme_accent = comptime runner.manifestThemeAccent(),
        .status_item = .{
            .title = "Focus",
            .icon_path = tray_icon_path,
            .tooltip = "Focus Tracker — Quick Focus",
        },
        .status_item_fn = modelStatusItem,
        .windows_fn = modelWindows,
        .window_view = modelWindowView,
    };
    if (comptime @hasDecl(core, "commandMsg")) options.on_command = core.commandMsg;

    var cache_dir_buffer: [512]u8 = undefined;
    const cache_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = manifest.name },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .cache,
        &cache_dir_buffer,
    ) catch "";

    const manifest_images = comptime manifestImages();
    var boot_images_buffer: [manifest_images.len]Adapter.BootImage = undefined;
    var boot_image_count: usize = 0;
    inline for (manifest_images) |asset| {
        if (std.Io.Dir.cwd().readFileAlloc(init.io, asset.path, std.heap.page_allocator, .limited(max_boot_image_bytes))) |bytes| {
            boot_images_buffer[boot_image_count] = .{ .id = asset.id, .bytes = bytes };
            boot_image_count += 1;
        } else |_| {}
    }

    var env_values_buffer: [envMsgsLen()]Adapter.EnvValue = undefined;
    var env_value_count: usize = 0;
    if (comptime @hasDecl(core, "envMsgs")) {
        inline for (core.envMsgs) |entry| {
            if (init.environ_map.get(entry.env)) |value| {
                env_values_buffer[env_value_count] = .{ .msg = entry.msg, .value = value };
                env_value_count += 1;
            }
        }
    }

    const app_state = try Adapter.create(std.heap.page_allocator, .{
        .audio_cache_dir = cache_dir,
        .image_cache_dir = cache_dir,
        .boot_images = boot_images_buffer[0..boot_image_count],
        .env_values = env_values_buffer[0..env_value_count],
    }, options);
    defer app_state.destroy();

    // Replay journals are the complete outside world. Do not open the
    // user's live database or bind a live host service while a recorded
    // session is being replayed; the SDK feeds the journaled host results.
    if (init.environ_map.get("NATIVE_SDK_SESSION_REPLAY") != null) {
        try runner.runWithOptions(app_state.app(), runOptions(), init);
        return;
    }

    var data_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = if (init.environ_map.get("FOCUS_TRACKER_DATA_DIR")) |override|
        if (override.len > 0 and std.fs.path.isAbsolute(override)) override else return error.InvalidDataDirectory
    else
        try native_sdk.app_dirs.resolveOne(
            .{ .name = manifest.name },
            native_sdk.app_dirs.currentPlatform(),
            native_sdk.debug.envFromMap(init.environ_map),
            .data,
            &data_dir_buffer,
        );
    var database = try sqlite.SqliteExtension.init(std.heap.page_allocator, init.io, data_dir);
    defer database.deinit();

    var host = HostContext{
        .database = &database,
        .effects = &app_state.effects,
    };
    app_state.effects.bindHostCalls(host.binding());

    const modules = [_]native_sdk.extensions.Module{database.module()};
    const registry: native_sdk.extensions.ModuleRegistry = .{ .modules = &modules };
    var extended = ExtensionApp{
        .inner = app_state.app(),
        .registry = registry,
    };

    try runner.runWithOptions(extended.app(), runOptions(), init);
}

const settings_window_label = "settings";
const settings_canvas_label = "settings-canvas";
const quick_window_label = "quick";
const quick_canvas_label = "quick-canvas";

fn modelStatusItem(model: *const Model, scratch: *App.StatusItemScratch) App.StatusItemState {
    const dialogs_open = model.purgeDialogOpen or model.endDialogOpen or model.completionDialogOpen;
    const ready = model.loadState == .ready;
    const state = model.sessionState();
    const minutes = model.remainingMinutes();
    const title = switch (state) {
        .running => if (model.isBreak())
            std.fmt.bufPrint(&scratch.title_buffer, "Rest {d}m", .{minutes}) catch "Rest"
        else
            std.fmt.bufPrint(&scratch.title_buffer, "Focus {d}m", .{minutes}) catch "Focus",
        .paused => std.fmt.bufPrint(&scratch.title_buffer, "Paused {d}m", .{minutes}) catch "Paused",
        .complete => "Done",
        .idle => "Focus",
    };

    var count: usize = 0;
    if (!ready) {
        scratch.items[count] = .{
            .id = 1,
            .label = if (model.loadState == .fatal) "Local ledger needs attention" else "Opening local ledger…",
            .command = "app.show",
            .enabled = false,
        };
        count += 1;
    } else {
        scratch.items[count] = .{
            .id = 1,
            .label = if (state == .idle and !model.quickSelectedTaskExists()) "No focus task selected" else model.quickTaskTitle(),
            .command = "app.show",
            .enabled = false,
        };
        count += 1;

        if (model.hasWriteError) {
            scratch.items[count] = .{
                .id = 15,
                .label = "Retry unsaved change",
                .command = "app.retry",
                .enabled = !model.saving,
            };
            count += 1;
        }

        if (state == .running or state == .paused) {
            scratch.items[count] = .{
                .id = 20,
                .label = if (state == .paused)
                    (if (model.isBreak()) "Resume Break" else "Resume Focus")
                else
                    (if (model.isBreak()) "Pause Break" else "Pause Focus"),
                .command = "app.quick-toggle",
                .enabled = !model.saving and !dialogs_open,
            };
            count += 1;
            scratch.items[count] = .{
                .id = 21,
                .label = if (model.isBreak()) "Finish Break…" else "Finish Focus…",
                .command = "app.quick-end",
                .enabled = !model.saving and !dialogs_open,
            };
            count += 1;
        } else if (state == .complete) {
            scratch.items[count] = .{
                .id = 22,
                .label = "Review Completed Block…",
                .command = "app.quick",
                .enabled = !model.saving,
            };
            count += 1;
        } else {
            scratch.items[count] = .{
                .id = 20,
                .label = if (model.quickSelectedTaskExists()) "Start Focus" else "Choose a Task in Quick Focus…",
                .command = if (model.quickSelectedTaskExists()) "app.quick-toggle" else "app.quick",
                .enabled = !model.saving and !dialogs_open,
            };
            count += 1;
        }
    }

    scratch.items[count] = .{ .separator = true };
    count += 1;
    scratch.items[count] = .{
        .id = 30,
        .label = "Open Quick Focus…",
        .command = "app.quick",
        .enabled = ready and !dialogs_open,
    };
    count += 1;
    scratch.items[count] = .{ .id = 31, .label = "Open Focus Tracker", .command = "app.show" };
    count += 1;
    scratch.items[count] = .{
        .id = 32,
        .label = "Settings…",
        .command = "app.settings",
        .enabled = ready and !dialogs_open,
    };
    count += 1;
    scratch.items[count] = .{ .separator = true };
    count += 1;
    scratch.items[count] = .{ .id = 40, .label = "Quit Focus Tracker", .command = "app.tray-quit" };
    count += 1;
    return .{ .title = title, .items = scratch.items[0..count] };
}

fn modelWindows(model: *const Model, scratch: *App.WindowsScratch) []const App.WindowDescriptor {
    var count: usize = 0;
    if (model.settingsWindowOpen) {
        scratch.windows[count] = .{
            .label = settings_window_label,
            .canvas_label = settings_canvas_label,
            .title = "Settings",
            .width = 620,
            .height = 320,
            .resizable = false,
            .activate_on_show = true,
            .on_close = .close_settings,
        };
        count += 1;
    }
    if (model.quickWindowOpen) {
        scratch.windows[count] = .{
            .label = quick_window_label,
            .canvas_label = quick_canvas_label,
            .title = "Quick Focus",
            .width = 392,
            .height = 360,
            .resizable = false,
            .always_on_top = true,
            .activate_on_show = true,
            .on_close = .close_quick,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

fn modelWindowView(ui: *Adapter.Ui, model: *const Model, window_label: []const u8) Adapter.Ui.Node {
    if (std.mem.eql(u8, window_label, settings_window_label)) return SettingsView.build(ui, model);
    if (std.mem.eql(u8, window_label, quick_window_label)) return QuickView.build(ui, model);
    std.debug.assert(false);
    return SettingsView.build(ui, model);
}

fn runOptions() runner.RunOptions {
    return .{
        .app_name = manifest.name,
        .window_title = comptime windowTitle(),
        .bundle_id = manifest.id,
        .icon_path = "assets/icon.png",
        .default_frame = comptime defaultFrame(),
        .restore_state = comptime startupRestoreState(),
        .js_window_api = false,
        .security = .{
            .permissions = app_permissions,
            .navigation = .{ .allowed_origins = allowed_origins },
        },
    };
}

const HostContext = struct {
    database: *sqlite.SqliteExtension,
    effects: *Adapter.Effects,

    fn binding(self: *HostContext) native_sdk.HostCallBinding {
        return .{
            .context = self,
            .send_fn = send,
            .request_fn = request,
            .cancel_fn = cancel,
        };
    }

    fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
        // Persistence is request/response only: a fire-and-forget write
        // could never prove commit to the model. Unknown sends therefore
        // have no observable database consequence.
        _ = context;
        _ = name;
        _ = payload;
    }

    fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        const self: *HostContext = @ptrCast(@alignCast(context));
        const response = self.database.handleRequest(name, payload) catch |err| {
            self.effects.feedHostResult(key, false, self.database.errorBytes(err)) catch {};
            return;
        };
        defer self.database.freeResponse(response);
        self.effects.feedHostResult(key, true, response) catch {};
    }

    fn cancel(context: *anyopaque, key: u64) void {
        // SQLite requests execute synchronously on the app loop and have
        // already committed or rolled back before control returns here.
        _ = context;
        _ = key;
    }
};

/// ModuleRegistry lifecycle/command adapter around the generated UiApp.
/// It mirrors Runtime's documented extension ordering without replacing
/// or copying the SDK runner.
const ExtensionApp = struct {
    inner: native_sdk.App,
    registry: native_sdk.extensions.ModuleRegistry,

    fn app(self: *ExtensionApp) native_sdk.App {
        return .{
            .context = self,
            .name = self.inner.name,
            .source = self.inner.source,
            // Preserve optional capabilities exactly. Merely installing a
            // source callback tells Runtime that a web layer exists, which
            // is false for this native canvas-only scene.
            .source_fn = if (self.inner.source_fn != null) source else null,
            .scene_fn = if (self.inner.scene_fn != null) scene else null,
            .start_fn = start,
            .event_fn = event,
            .stop_fn = stop,
            .replay_fn = if (self.inner.replay_fn != null) replay else null,
        };
    }

    fn runtimeContext(runtime: *native_sdk.Runtime) native_sdk.extensions.RuntimeContext {
        return .{ .platform_name = runtime.options.platform.name };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        return self.inner.webViewSource();
    }

    fn scene(context: *anyopaque) anyerror!native_sdk.app_manifest.ShellConfig {
        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        return (try self.inner.scene()) orelse error.MissingScene;
    }

    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        try self.inner.start(runtime);
        try self.registry.startAll(runtimeContext(runtime));
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, value: native_sdk.Event) anyerror!void {
        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        try self.inner.event(runtime, value);
        switch (value) {
            .command => |command| try self.registry.dispatchCommand(runtimeContext(runtime), .{ .name = command.name }),
            else => {},
        }
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        var module_error: ?anyerror = null;
        self.registry.stopAll(runtimeContext(runtime)) catch |err| {
            module_error = err;
        };
        self.inner.stop(runtime) catch |err| {
            if (module_error == null) return err;
        };
        if (module_error) |err| return err;
    }

    fn replay(context: *anyopaque, control: native_sdk.runtime.ReplayControl) anyerror!void {
        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        try self.inner.replayControl(control);
    }
};

fn windowTitle() []const u8 {
    if (shell_scene.windows.len > 0) {
        if (shell_scene.windows[0].title) |title| return title;
    }
    if (@hasField(@TypeOf(manifest), "display_name")) return manifest.display_name;
    return manifest.name;
}

fn defaultFrame() native_sdk.geometry.RectF {
    if (shell_scene.windows.len > 0) {
        const window = shell_scene.windows[0];
        return native_sdk.geometry.RectF.init(window.x orelse 0, window.y orelse 0, window.width, window.height);
    }
    return native_sdk.geometry.RectF.init(0, 0, 720, 480);
}

fn startupRestoreState() bool {
    if (shell_scene.windows.len > 0) return shell_scene.windows[0].restore_state;
    return true;
}

const ImageAsset = struct {
    id: u64,
    path: []const u8,
};

const max_boot_image_bytes: usize = 4 * 1024 * 1024;

fn manifestImages() []const ImageAsset {
    comptime {
        if (!@hasField(@TypeOf(manifest), "assets")) return &.{};
        if (!@hasField(@TypeOf(manifest.assets), "images")) return &.{};
        var out: []const ImageAsset = &.{};
        for (manifest.assets.images) |entry| {
            out = out ++ &[_]ImageAsset{.{ .id = entry.id, .path = entry.path }};
        }
        return out;
    }
}

fn envMsgsLen() usize {
    comptime {
        if (!@hasDecl(core, "envMsgs")) return 0;
        return core.envMsgs.len;
    }
}

fn manifestStringList(comptime value: anytype, comptime field: []const u8) []const []const u8 {
    comptime {
        if (!@hasField(@TypeOf(value), field)) return &.{};
        var out: []const []const u8 = &.{};
        for (@field(value, field)) |entry| {
            const name: []const u8 = entry;
            out = out ++ &[_][]const u8{name};
        }
        return out;
    }
}

fn manifestAllowedOrigins() []const []const u8 {
    comptime {
        if (!@hasField(@TypeOf(manifest), "security")) return &.{};
        if (!@hasField(@TypeOf(manifest.security), "navigation")) return &.{};
        return manifestStringList(manifest.security.navigation, "allowed_origins");
    }
}

test "deadline completion survives an unrelated database write error" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const running = core.rt.frameCreate(core.DbSession, .{
        .id = 7,
        .taskId = 3,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 0,
        .endsMs = 1_000,
        .remainingMs = 1_000,
        .plannedMs = 1_000,
        .focusedMs = 0,
        .endedMs = 0,
    });
    const task = core.rt.frameCreate(core.DbTask, .{
        .id = 3,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 10,
        .updatedMs = 10,
        .completedMs = 0,
        .title = "Authoritative task",
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = task;
    const before_error = core.rt.frameCreate(core.Model, seed.*);
    before_error.loadState = .ready;
    before_error.revision = 42;
    before_error.tasks = tasks;
    before_error.activeSession = running;
    before_error.nowMs = 900;
    before_error.saving = true;
    before_error.pendingKind = .task_rename;
    before_error.pendingTaskId = 99;
    before_error.retryPayload = "unrelated-write-payload";

    const failed_write = core.update(before_error, .{ .db_err = "sqlite_failure" });
    try std.testing.expect(failed_write.model.hasWriteError);
    try std.testing.expect(!failed_write.model.saving);
    try std.testing.expectEqual(core.PendingKind.task_rename, failed_write.model.pendingKind);
    try std.testing.expect(failed_write.model.activeSession != null);
    try std.testing.expectEqual(@as(i64, 7), failed_write.model.activeSession.?.id);

    const due = core.update(failed_write.model, .{ .focus_due = 1_000 });
    try std.testing.expect(due.cmd.len >= 2);
    try std.testing.expectEqual(@intFromEnum(core.rt.CmdOp.request), due.cmd[0]);
    const name_length: usize = due.cmd[1];
    try std.testing.expect(due.cmd.len >= 2 + name_length);
    try std.testing.expectEqualStrings("focus.db.timer.complete", due.cmd[2..][0..name_length]);

    // The host response remains the only authority: issuing completion does
    // not optimistically remove or rewrite the running session or revision.
    try std.testing.expectEqual(@as(i64, 42), due.model.revision);
    try std.testing.expectEqual(@as(usize, 1), due.model.tasks.len);
    try std.testing.expectEqual(@as(i64, 3), due.model.tasks[0].id);
    try std.testing.expectEqual(core.TaskState.open, due.model.tasks[0].state);
    try std.testing.expectEqualStrings("Authoritative task", due.model.tasks[0].title);
    try std.testing.expect(due.model.activeSession != null);
    try std.testing.expectEqual(@as(i64, 7), due.model.activeSession.?.id);
    try std.testing.expectEqual(core.SessionState.running, due.model.activeSession.?.state);
    try std.testing.expectEqual(@as(i64, 1_000), due.model.activeSession.?.endsMs);
    try std.testing.expect(due.model.hasWriteError);
    try std.testing.expect(due.model.saving);
    try std.testing.expectEqual(core.PendingKind.timer_complete_natural, due.model.pendingKind);
}

test "tray icon path resolves inside a packaged app and stays relative in development" {
    var output: [512]u8 = undefined;
    const packaged = trayIconPathForExecutable(
        "/Applications/Focus Tracker.app/Contents/MacOS/focus-tracker",
        &output,
    );
    try std.testing.expectEqualStrings(
        "/Applications/Focus Tracker.app/Contents/Resources/assets/tray-template.png",
        packaged,
    );

    const development = trayIconPathForExecutable(
        "/Users/developer/focus-tracker/zig-out/bin/focus-tracker",
        &output,
    );
    try std.testing.expectEqualStrings(tray_icon_relative_path, development);
}

test "status item exposes a bounded actionable idle menu" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const task = core.rt.frameCreate(core.DbTask, .{
        .id = 3,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 10,
        .updatedMs = 10,
        .completedMs = 0,
        .title = "Write the launch brief",
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = task;
    model.tasks = tasks;
    model.selectedTaskId = 3;

    var scratch: App.StatusItemScratch = .{};
    const state = modelStatusItem(model, &scratch);
    try std.testing.expectEqualStrings("Focus", state.title);
    try std.testing.expect(state.items.len <= native_sdk.platform.max_tray_items);
    try std.testing.expectEqualStrings("Write the launch brief", state.items[0].label);
    try std.testing.expectEqualStrings("app.quick-toggle", state.items[1].command);

    for (state.items, 0..) |item, index| {
        if (item.separator) continue;
        try std.testing.expect(item.id != 0);
        try std.testing.expect(item.label.len <= native_sdk.platform.max_tray_item_label_bytes);
        for (state.items[0..index]) |previous| {
            if (!previous.separator) try std.testing.expect(previous.id != item.id);
        }
    }
}

test "status item title is minute-granular for running and paused sessions" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const running = core.rt.frameCreate(core.DbSession, .{
        .id = 7,
        .taskId = 0,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 0,
        .endsMs = 1_480_000,
        .remainingMs = 1_480_000,
        .plannedMs = 1_500_000,
        .focusedMs = 20_000,
        .endedMs = 0,
    });
    model.activeSession = running;
    model.nowMs = 0;

    var scratch: App.StatusItemScratch = .{};
    const running_state = modelStatusItem(model, &scratch);
    try std.testing.expectEqualStrings("Focus 24m", running_state.title);
    try std.testing.expectEqualStrings("Pause Focus", running_state.items[1].label);

    running.state = .paused;
    running.remainingMs = 1_079_000;
    const paused_state = modelStatusItem(model, &scratch);
    try std.testing.expectEqualStrings("Paused 17m", paused_state.title);
    try std.testing.expectEqualStrings("Resume Focus", paused_state.items[1].label);
}

test "model-declared secondary windows stay mutually exclusive" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    var scratch: App.WindowsScratch = .{};
    try std.testing.expectEqual(@as(usize, 0), modelWindows(model, &scratch).len);

    model.quickWindowOpen = true;
    var windows = modelWindows(model, &scratch);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings(quick_window_label, windows[0].label);
    try std.testing.expectEqualStrings(quick_canvas_label, windows[0].canvas_label);
    try std.testing.expect(windows[0].always_on_top);
    try std.testing.expect(!windows[0].resizable);

    const opened_settings = core.update(model, .open_settings);
    try std.testing.expect(opened_settings.model.settingsWindowOpen);
    try std.testing.expect(!opened_settings.model.quickWindowOpen);
    windows = modelWindows(opened_settings.model, &scratch);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings(settings_window_label, windows[0].label);

    const reopened_quick = core.update(opened_settings.model, .open_quick);
    try std.testing.expect(reopened_quick.model.quickWindowOpen);
    try std.testing.expect(!reopened_quick.model.settingsWindowOpen);
    windows = modelWindows(reopened_quick.model, &scratch);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings(quick_window_label, windows[0].label);

    const escaped = core.update(reopened_quick.model, .escape_pressed);
    try std.testing.expect(!escaped.model.quickWindowOpen);
    try std.testing.expect(!escaped.model.settingsWindowOpen);
}

test "quick window open close and delayed raise are race safe" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const ready = core.rt.frameCreate(core.Model, seed.*);
    ready.loadState = .ready;

    const opened = core.update(ready, .open_quick);
    try std.testing.expect(opened.model.quickWindowOpen);
    try std.testing.expect(opened.cmd.len > 0);
    try std.testing.expectEqual(@intFromEnum(core.rt.CmdOp.delay), opened.cmd[0]);

    const closed = core.update(opened.model, .close_quick);
    try std.testing.expect(!closed.model.quickWindowOpen);
    const stale_raise = core.update(closed.model, .{ .raise_quick = 1 });
    try std.testing.expect(!stale_raise.model.quickWindowOpen);
    try std.testing.expectEqual(@as(usize, 0), stale_raise.cmd.len);
}

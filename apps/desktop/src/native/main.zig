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
const global_hotkey = @import("global_hotkey.zig");
const cobalt_theme = @import("theme.zig");
pub const core = @import("core");

comptime {
    // The custom token pack is reached indirectly through the runtime callback;
    // force its declarations into the test build so theme.zig's own tests are
    // part of the reported native tally instead of silently remaining dormant.
    std.testing.refAllDecls(cobalt_theme);
}

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
        .tokens_fn = modelTokens,
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
    };
    defer host.deinit();
    app_state.effects.bindHostCalls(host.binding());

    const modules = [_]native_sdk.extensions.Module{database.module()};
    const registry: native_sdk.extensions.ModuleRegistry = .{ .modules = &modules };
    var extended = ExtensionApp{
        .inner = app_state.app(),
        .state = app_state,
        .host = &host,
        .registry = registry,
    };
    host.shortcut_preflight_context = &extended;
    host.shortcut_preflight_fn = ExtensionApp.preflightShortcutRequest;

    try runner.runWithOptions(extended.app(), runOptions(), init);
}

fn modelTokens(model: *const Model) native_sdk.canvas.DesignTokens {
    return cobalt_theme.tokens(.{
        .appearance = .{
            .color_scheme = switch (model.colorScheme) {
                .light => .light,
                .dark => .dark,
            },
            .reduce_motion = model.reduceMotion,
            .high_contrast = model.highContrast,
        },
        .density = .regular,
        .accent = comptime runner.manifestThemeAccent(),
    });
}

const settings_window_label = "settings";
const settings_canvas_label = "settings-canvas";
const quick_window_label = "quick";
const quick_canvas_label = "quick-canvas";

fn modelStatusItem(model: *const Model, scratch: *App.StatusItemScratch) App.StatusItemState {
    // A focus completion is already committed and its task decision is an
    // optional, portable follow-up. Only true confirmations block tray routes.
    const dialogs_open = model.purgeDialogOpen or model.endDialogOpen;
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
                .enabled = !model.saving and !model.hasWriteError and !dialogs_open,
            };
            count += 1;
            scratch.items[count] = .{
                .id = 21,
                .label = if (model.isBreak()) "Finish Break…" else "Finish Focus…",
                .command = "app.quick-end",
                .enabled = !model.saving and !model.hasWriteError and !dialogs_open,
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
                .enabled = !model.saving and !dialogs_open and
                    (!model.quickSelectedTaskExists() or !model.hasWriteError),
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
            // Timer, daily, and global-shortcut preferences all apply live in
            // one fixed native surface; keep enough vertical room for the two
            // shortcut modifier rows and their registration status.
            .width = 800,
            .height = 560,
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
            // The block-length stepper and its presets sit below the task
            // chooser, so the companion needs the extra rows without pushing
            // the list into a two-item scroll.
            .height = 468,
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
    const PendingOwner = enum { none, database, page };
    const ShortcutPreflightFn = *const fn (*anyopaque, []const u8, []const u8) anyerror!void;

    const PendingResult = struct {
        key: u64,
        ok: bool,
        bytes: []u8,
        owner: PendingOwner,
    };

    database: *sqlite.SqliteExtension,
    services: ?native_sdk.platform.PlatformServices = null,
    shortcut_preflight_context: ?*anyopaque = null,
    shortcut_preflight_fn: ?ShortcutPreflightFn = null,
    pending_key: u64 = 0,
    pending_active: bool = false,
    pending_ok: bool = false,
    pending_bytes: []u8 = &.{},
    pending_owner: PendingOwner = .none,
    pending_frame_requested: bool = false,

    fn deinit(self: *HostContext) void {
        self.clearPending();
        self.services = null;
        self.shortcut_preflight_context = null;
        self.shortcut_preflight_fn = null;
    }

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
        self.clearPending();
        if (std.mem.eql(u8, name, sqlite.settings_set_command)) {
            if (self.shortcut_preflight_fn) |preflight| {
                const preflight_context = self.shortcut_preflight_context orelse {
                    self.setPendingError(key, "shortcut_unavailable");
                    return;
                };
                preflight(preflight_context, name, payload) catch {
                    // Carbon rejected the candidate before SQLite saw the write.
                    // Deliver the rejection through the existing request result
                    // so the core unwinds the pending settings intent normally.
                    self.setPendingError(key, "shortcut_unavailable");
                    return;
                };
            }
        }
        const response = self.database.handleRequest(name, payload) catch |err| {
            self.setPendingError(key, self.database.errorBytes(err));
            return;
        };
        self.pending_key = key;
        self.pending_active = true;
        self.pending_ok = true;
        self.pending_bytes = response;
        self.pending_owner = .database;
        self.pending_frame_requested = false;
        self.requestWake();
    }

    fn setPendingError(self: *HostContext, key: u64, error_bytes: []const u8) void {
        self.pending_key = key;
        self.pending_active = true;
        self.pending_ok = false;
        self.pending_frame_requested = false;
        if (std.heap.page_allocator.dupe(u8, error_bytes)) |owned| {
            self.pending_bytes = owned;
            self.pending_owner = .page;
        } else |_| {
            self.pending_bytes = @constCast("out_of_memory");
            self.pending_owner = .none;
        }
        self.requestWake();
    }

    fn cancel(context: *anyopaque, key: u64) void {
        const self: *HostContext = @ptrCast(@alignCast(context));
        // SQLite has already committed or rolled back, but a replacement
        // request must retire the undelivered response for the old key.
        if (self.pending_active and self.pending_key == key) self.clearPending();
    }

    fn requestWake(self: *HostContext) void {
        const services = self.services orelse return;
        services.wake() catch {};
    }

    fn takePending(self: *HostContext, result: *PendingResult) bool {
        if (!self.pending_active) return false;
        result.* = .{
            .key = self.pending_key,
            .ok = self.pending_ok,
            .bytes = self.pending_bytes,
            .owner = self.pending_owner,
        };
        self.pending_key = 0;
        self.pending_active = false;
        self.pending_ok = false;
        self.pending_bytes = &.{};
        self.pending_owner = .none;
        self.pending_frame_requested = false;
        return true;
    }

    fn freeResult(self: *HostContext, result: PendingResult) void {
        switch (result.owner) {
            .none => {},
            .database => self.database.freeResponse(result.bytes),
            .page => std.heap.page_allocator.free(result.bytes),
        }
    }

    fn clearPending(self: *HostContext) void {
        if (self.pending_active) {
            self.freeResult(.{
                .key = self.pending_key,
                .ok = self.pending_ok,
                .bytes = self.pending_bytes,
                .owner = self.pending_owner,
            });
        }
        self.pending_key = 0;
        self.pending_active = false;
        self.pending_ok = false;
        self.pending_bytes = &.{};
        self.pending_owner = .none;
        self.pending_frame_requested = false;
    }
};

/// ModuleRegistry lifecycle/command adapter around the generated UiApp.
/// It mirrors Runtime's documented extension ordering without replacing
/// or copying the SDK runner.
const ExtensionApp = struct {
    const ShortcutReport = enum { unknown, active, disabled, unavailable };

    inner: native_sdk.App,
    state: *App,
    host: *HostContext,
    registry: native_sdk.extensions.ModuleRegistry,
    runtime: ?*native_sdk.Runtime = null,
    hotkey: global_hotkey.Manager = .{},
    hotkey_install_failed: bool = false,
    stopping: bool = false,
    shortcut_report: ShortcutReport = .unknown,
    shortcut_report_config: ?global_hotkey.Config = null,

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
        self.stopping = false;
        self.runtime = runtime;
        self.host.services = runtime.options.platform.services;
        try self.inner.start(runtime);
        try self.registry.startAll(runtimeContext(runtime));
        self.hotkey.install(self, dispatchGlobalQuick) catch {
            // A missing Carbon handler must not make the local ledger or timer
            // unusable. Settings surfaces the unavailable runtime state once
            // the authoritative SQLite snapshot has loaded.
            self.hotkey_install_failed = true;
        };
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, value: native_sdk.Event) anyerror!void {
        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        if (std.meta.activeTag(value) == .gpu_surface_frame) {
            try self.feedHostResultForFrame();
        } else {
            try self.requestHostResultFrame();
        }
        switch (value) {
            .canvas_widget_keyboard => |keyboard_event| {
                if (escapeCommandForKeyboard(keyboard_event)) |command_name| {
                    try self.inner.event(runtime, .{ .command = .{
                        .name = command_name,
                        .source = .native_view,
                        .window_id = keyboard_event.window_id,
                        .view_label = keyboard_event.view_label,
                    } });
                    try self.requestHostResultFrame();
                    return;
                }
            },
            else => {},
        }
        try self.inner.event(runtime, value);
        switch (value) {
            .command => |command| try self.registry.dispatchCommand(runtimeContext(runtime), .{ .name = command.name }),
            else => {},
        }
        // The stop event lets the inner app tear its model down before the
        // extension stop callback releases Carbon. Do not interpret that
        // transient teardown state as a new shortcut configuration.
        const stopping = switch (value) {
            .lifecycle => |lifecycle| lifecycle == .stop,
            else => false,
        };
        if (stopping) self.stopping = true;
        if (!self.stopping) try self.syncGlobalHotKey(runtime);
        try self.requestHostResultFrame();
    }

    fn requestHostResultFrame(self: *ExtensionApp) anyerror!void {
        if (!self.host.pending_active or self.host.pending_frame_requested) return;
        const services = self.host.services orelse return;
        try services.requestGpuSurfaceFrame(self.state.canvas_window_id, canvas_label);
        self.host.pending_frame_requested = true;
    }

    fn feedHostResultForFrame(self: *ExtensionApp) anyerror!void {
        var result: HostContext.PendingResult = undefined;
        if (!self.host.takePending(&result)) return;
        defer self.host.freeResult(result);

        // SQLite executes on the app loop, but its terminal is parked until a
        // drawable frame exists. Feeding the stock effects channel immediately
        // before that frame lets UiApp drain, rebuild, and present atomically;
        // it also preserves the bridge's request table and session journal.
        try self.state.effects.feedHostResult(result.key, result.ok, result.bytes);
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        self.stopping = true;
        self.hotkey.stop();
        self.runtime = null;
        var module_error: ?anyerror = null;
        self.registry.stopAll(runtimeContext(runtime)) catch |err| {
            module_error = err;
        };
        self.inner.stop(runtime) catch |err| {
            if (module_error == null) return err;
        };
        if (module_error) |err| return err;
    }

    fn dispatchGlobalQuick(raw: ?*anyopaque) void {
        const self: *ExtensionApp = @ptrCast(@alignCast(raw orelse return));
        const runtime = self.runtime orelse return;
        runtime.dispatchCommand(self.app(), .{
            .name = "app.quick",
            .source = .shortcut,
        }) catch |err| runtime.recordDispatchError("global_hotkey", err);
    }

    /// Gate shortcut-changing settings writes at the last boundary before
    /// SQLite. During a host call the UiApp mirror still contains the previous
    /// root, while Adapter.Host already owns the model that emitted the
    /// request, so the bridge model is the authoritative candidate here.
    fn preflightShortcutRequest(
        context: *anyopaque,
        name: []const u8,
        payload: []const u8,
    ) anyerror!void {
        _ = payload;
        if (!std.mem.eql(u8, name, sqlite.settings_set_command)) return;

        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        const model = Adapter.Host.model();
        const candidate = shortcutWriteCandidate(model, name) orelse return;
        try self.preflightShortcutCandidate(candidate);
    }

    fn preflightShortcutCandidate(
        self: *ExtensionApp,
        candidate: global_hotkey.Config,
    ) anyerror!void {
        // Disabling does not need a Carbon handler. Keep that escape hatch
        // available when handler installation failed so users can persist an
        // explicit off state instead of being trapped in "unavailable".
        if (self.hotkey_install_failed and candidate.enabled) return error.HotKeyHandlerUnavailable;
        if (self.hotkey.stagedMatches(candidate)) return;
        try self.hotkey.stage(candidate);
    }

    fn reportForMissingHandler(config: global_hotkey.Config) ShortcutReport {
        return if (config.enabled) .unavailable else .disabled;
    }

    fn syncGlobalHotKey(self: *ExtensionApp, runtime: *native_sdk.Runtime) anyerror!void {
        const model = &self.state.model;
        if (model.loadState != .ready) return;

        const committed = hotKeyConfig(model.settings);
        const pending = hotKeyConfig(model.pendingSettings);
        const shortcut_write = model.saving and model.pendingKind == .settings and
            !global_hotkey.Config.eql(committed, pending);

        if (model.hasWriteError) self.hotkey.rollbackStage();

        if (shortcut_write) {
            // HostContext preflighted this candidate synchronously before its
            // SQLite request. Keep the staged registration inert until the
            // corresponding db_ok changes the committed model.
            return;
        }

        if (self.hotkey.hasStage()) {
            if (self.hotkey.stagedMatches(committed)) {
                self.hotkey.promote();
            } else {
                self.hotkey.rollbackStage();
            }
        }

        if (global_hotkey.conflictsWithLocalTransportShortcut(committed)) {
            // The manifest owns Command + Shift + Space for timer transport.
            // A defensive read of an externally-written reserved value must
            // not leave either that chord or a previously active chord live.
            var inactive = committed;
            inactive.enabled = false;
            try self.hotkey.replaceCommitted(inactive);
            try self.reportShortcut(runtime, .unavailable, committed);
            return;
        }

        if (self.hotkey_install_failed) {
            try self.reportShortcut(runtime, reportForMissingHandler(committed), committed);
            return;
        }
        if (!self.hotkey.activeMatches(committed)) {
            self.hotkey.replaceCommitted(committed) catch {
                try self.reportShortcut(runtime, .unavailable, committed);
                return;
            };
        }
        try self.reportShortcut(runtime, if (committed.enabled) .active else .disabled, committed);
    }

    fn reportShortcut(
        self: *ExtensionApp,
        runtime: *native_sdk.Runtime,
        report: ShortcutReport,
        config: global_hotkey.Config,
    ) anyerror!void {
        if (self.shortcut_report == report) {
            if (self.shortcut_report_config) |previous| {
                if (global_hotkey.Config.eql(previous, config)) return;
            }
        }
        // Set the dedupe state before dispatch: the command re-enters this
        // adapter synchronously and must observe the report as delivered.
        self.shortcut_report = report;
        self.shortcut_report_config = config;
        const command = switch (report) {
            .active => "app.shortcut-active",
            .disabled => "app.shortcut-disabled",
            .unavailable => "app.shortcut-unavailable",
            .unknown => return,
        };
        try self.dispatchShortcutCommand(runtime, command);
    }

    fn dispatchShortcutCommand(
        self: *ExtensionApp,
        runtime: *native_sdk.Runtime,
        command: []const u8,
    ) anyerror!void {
        try runtime.dispatchCommand(self.app(), .{
            .name = command,
            .source = .runtime,
        });
    }

    fn replay(context: *anyopaque, control: native_sdk.runtime.ReplayControl) anyerror!void {
        const self: *ExtensionApp = @ptrCast(@alignCast(context));
        try self.inner.replayControl(control);
    }
};

fn hotKeyConfig(settings: *const core.DbSettings) global_hotkey.Config {
    return .{
        .enabled = settings.quickShortcutEnabled,
        .key = switch (settings.quickShortcutKey) {
            .f => .f,
            .q => .q,
            .k => .k,
            .t => .t,
            .p => .p,
            .space => .space,
        },
        .modifiers = switch (settings.quickShortcutModifiers) {
            .command_shift => .command_shift,
            .command_option => .command_option,
            .control_shift => .control_shift,
            .control_option => .control_option,
            .command_control => .command_control,
            .command_control_shift => .command_control_shift,
        },
    };
}

fn shortcutWriteCandidate(model: *const Model, name: []const u8) ?global_hotkey.Config {
    if (!std.mem.eql(u8, name, sqlite.settings_set_command)) return null;
    if (!model.saving or model.pendingKind != .settings) return null;
    const committed = hotKeyConfig(model.settings);
    const candidate = hotKeyConfig(model.pendingSettings);
    return if (global_hotkey.Config.eql(committed, candidate)) null else candidate;
}

/// Escape is a surface command, not text input. The stock app-level key
/// fallback intentionally yields to editors, so this thin app adapter restores
/// the macOS contract before UiApp consumes the focused field event. IME
/// composition keeps first refusal: its initial Escape only cancels preedit.
fn escapeCommandForKeyboard(event: native_sdk.runtime.CanvasWidgetKeyboardEvent) ?[]const u8 {
    if (event.keyboard.phase != .key_down) return null;
    if (!std.ascii.eqlIgnoreCase(event.keyboard.key, "escape")) return null;
    if (event.keyboard.edit) |edit| {
        if (std.meta.activeTag(edit) == .cancel_composition) return null;
    }
    if (std.mem.eql(u8, event.view_label, quick_canvas_label)) return "app.escape-quick";
    if (std.mem.eql(u8, event.view_label, settings_canvas_label)) return "app.escape-settings";
    if (std.mem.eql(u8, event.view_label, canvas_label)) return "app.escape-main";
    return null;
}

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

test "failed writes keep their retry slot across a timer deadline" {
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
    try std.testing.expectEqual(@as(usize, 0), due.cmd.len);

    // The timer remains authoritative at its deadline, but cannot overwrite
    // the failed mutation's single retry slot. A different settings write is
    // ignored for the same reason.
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
    try std.testing.expect(!due.model.saving);
    try std.testing.expectEqual(core.PendingKind.task_rename, due.model.pendingKind);
    try std.testing.expectEqualStrings("unrelated-write-payload", due.model.retryPayload);

    const superseding_write = core.update(due.model, .set_short_break_10);
    try std.testing.expectEqual(@as(usize, 0), superseding_write.cmd.len);
    try std.testing.expect(superseding_write.model.hasWriteError);
    try std.testing.expectEqual(core.PendingKind.task_rename, superseding_write.model.pendingKind);
    try std.testing.expectEqualStrings("unrelated-write-payload", superseding_write.model.retryPayload);

    const discarded = core.update(superseding_write.model, .discard_failed_change);
    try std.testing.expect(!discarded.model.hasWriteError);
    try std.testing.expect(!discarded.model.saving);
    try std.testing.expectEqual(core.PendingKind.none, discarded.model.pendingKind);
    try std.testing.expectEqual(@as(usize, 0), discarded.model.retryPayload.len);
    try std.testing.expect(discarded.model.activeSession != null);
    try std.testing.expectEqual(@as(i64, 7), discarded.model.activeSession.?.id);
    const replacement_write = core.update(discarded.model, .set_short_break_10);
    try std.testing.expectEqual(core.PendingKind.settings, replacement_write.model.pendingKind);
    try std.testing.expect(replacement_write.cmd.len > 0);

    const retry = core.update(superseding_write.model, .retry_save);
    try std.testing.expect(retry.model.saving);
    try std.testing.expect(!retry.model.hasWriteError);
    try std.testing.expectEqual(core.PendingKind.task_rename, retry.model.pendingKind);
    try std.testing.expect(retry.cmd.len >= 2);
    try std.testing.expectEqual(@intFromEnum(core.rt.CmdOp.request), retry.cmd[0]);
    const name_length: usize = retry.cmd[1];
    try std.testing.expect(retry.cmd.len >= 2 + name_length);
    try std.testing.expectEqualStrings("focus.db.task.rename", retry.cmd[2..][0..name_length]);
}

test "start and resume retries acquire a fresh wall clock without retroactive focus" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/timer-retry-rebase-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    const seed = core.initialModel().model;
    const starting = core.rt.frameCreate(core.Model, seed.*);
    starting.loadState = .ready;
    starting.nowMs = 1_000;
    starting.saving = true;
    starting.pendingKind = .timer_start;
    starting.pendingTaskId = 0;
    starting.pendingMode = .focus;
    starting.pendingDurationMinutes = 1;

    const original_start = core.update(starting, .{ .intent_now = 1_000 });
    try std.testing.expectEqual(@as(usize, 41), original_start.model.retryPayload.len);
    const failed_start = core.update(original_start.model, .{ .db_err = "database_busy" });
    const retry_start = core.update(failed_start.model, .retry_save);
    try std.testing.expect(retry_start.model.saving);
    try std.testing.expectEqual(core.PendingKind.timer_start, retry_start.model.pendingKind);
    try std.testing.expectEqual(@as(usize, 0), retry_start.model.retryPayload.len);
    try std.testing.expect(retry_start.cmd.len > 0);

    const rebased_start = core.update(retry_start.model, .{ .intent_now = 5_000 });
    try std.testing.expectEqual(@as(i64, 5_000), rebased_start.model.pendingNowMs);
    try std.testing.expectEqual(@as(usize, 41), rebased_start.model.retryPayload.len);
    try std.testing.expect(!std.mem.eql(u8, original_start.model.retryPayload, rebased_start.model.retryPayload));
    const started_snapshot = try database.handleRequest(
        sqlite.timer_start_command,
        rebased_start.model.retryPayload,
    );
    defer database.freeResponse(started_snapshot);
    const started = core.update(rebased_start.model, .{ .db_ok = started_snapshot });
    try std.testing.expect(started.model.activeSession != null);
    try std.testing.expectEqual(@as(i64, 5_000), started.model.activeSession.?.startedMs);
    try std.testing.expectEqual(@as(i64, 65_000), started.model.activeSession.?.endsMs);
    try std.testing.expectEqual(@as(i64, 0), started.model.activeSession.?.focusedMs);

    var pause_payload: [32]u8 = undefined;
    testMutationPrefix(&pause_payload, 1, 6_000);
    putTestLe(&pause_payload, 24, 1, 8);
    database.freeResponse(try database.handleRequest(sqlite.timer_pause_command, &pause_payload));

    const paused = core.rt.frameCreate(core.Model, seed.*);
    paused.loadState = .ready;
    paused.revision = 2;
    paused.nowMs = 6_000;
    paused.saving = true;
    paused.pendingKind = .timer_resume;
    paused.activeSession = core.rt.frameCreate(core.DbSession, .{
        .id = 1,
        .taskId = 0,
        .mode = .focus,
        .state = .paused,
        .completionReason = .none,
        .startedMs = 5_000,
        .endsMs = 0,
        .remainingMs = 59_000,
        .plannedMs = 60_000,
        .focusedMs = 1_000,
        .endedMs = 0,
    });

    const original_resume = core.update(paused, .{ .intent_now = 7_000 });
    const failed_resume = core.update(original_resume.model, .{ .db_err = "database_busy" });
    const retry_resume = core.update(failed_resume.model, .retry_save);
    try std.testing.expectEqual(core.PendingKind.timer_resume, retry_resume.model.pendingKind);
    try std.testing.expectEqual(@as(usize, 0), retry_resume.model.retryPayload.len);
    const rebased_resume = core.update(retry_resume.model, .{ .intent_now = 20_000 });
    try std.testing.expect(!std.mem.eql(u8, original_resume.model.retryPayload, rebased_resume.model.retryPayload));
    const resumed_snapshot = try database.handleRequest(
        sqlite.timer_resume_command,
        rebased_resume.model.retryPayload,
    );
    defer database.freeResponse(resumed_snapshot);
    const resumed = core.update(rebased_resume.model, .{ .db_ok = resumed_snapshot });
    try std.testing.expect(resumed.model.activeSession != null);
    try std.testing.expectEqual(core.SessionState.running, resumed.model.activeSession.?.state);
    try std.testing.expectEqual(@as(i64, 20_000), resumed.model.nowMs);
    try std.testing.expectEqual(@as(i64, 79_000), resumed.model.activeSession.?.endsMs);
    try std.testing.expectEqual(@as(i64, 59_000), resumed.model.activeSession.?.remainingMs);
    try std.testing.expectEqual(@as(i64, 1_000), resumed.model.activeSession.?.focusedMs);
}

test "retry payload age is not mistaken for a wall clock rollback at the deadline" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/retry-deadline-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    var start_payload: [41]u8 = undefined;
    testMutationPrefix(&start_payload, 0, 1_000);
    putTestLe(&start_payload, 24, 0, 8);
    start_payload[32] = 0;
    putTestLe(&start_payload, 33, 1_000, 8);
    database.freeResponse(try database.handleRequest(sqlite.timer_start_command, &start_payload));

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.revision = 1;
    model.nowMs = 1_900;
    model.activeSession = core.rt.frameCreate(core.DbSession, .{
        .id = 1,
        .taskId = 0,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 1_000,
        .endsMs = 2_000,
        .remainingMs = 1_000,
        .plannedMs = 1_000,
        .focusedMs = 0,
        .endedMs = 0,
    });
    model.saving = true;
    model.pendingKind = .settings;
    const changed_settings = core.rt.frameCreate(core.DbSettings, model.settings.*);
    changed_settings.shortBreakMinutes = 10;
    model.pendingSettings = changed_settings;

    const original = core.update(model, .{ .intent_now = 1_900 });
    const failed = core.update(original.model, .{ .db_err = "database_busy" });
    const expired = core.update(failed.model, .{ .tick = 2_100 });
    try std.testing.expect(expired.model.hasWriteError);
    try std.testing.expectEqual(@as(i64, 2_100), expired.model.nowMs);
    const retry = core.update(expired.model, .retry_save);
    const settings_snapshot = try database.handleRequest(
        sqlite.settings_set_command,
        retry.model.retryPayload,
    );
    defer database.freeResponse(settings_snapshot);
    const committed_settings = core.update(retry.model, .{ .db_ok = settings_snapshot });
    try std.testing.expectEqual(@as(i64, 2_100), committed_settings.model.nowMs);
    try std.testing.expectEqual(core.PendingKind.timer_complete_natural, committed_settings.model.pendingKind);
    try std.testing.expect(committed_settings.model.saving);
    try std.testing.expect(committed_settings.model.activeSession != null);

    const completed_snapshot = try database.handleRequest(
        sqlite.timer_complete_command,
        committed_settings.model.retryPayload,
    );
    defer database.freeResponse(completed_snapshot);
    const completed = core.update(committed_settings.model, .{ .db_ok = completed_snapshot });
    try std.testing.expect(completed.model.activeSession == null);
    try std.testing.expectEqual(@as(usize, 1), completed.model.recentSessions.len);
    try std.testing.expectEqual(core.SessionState.completed, completed.model.recentSessions[0].state);
    try std.testing.expectEqual(@as(i64, 2_000), completed.model.recentSessions[0].endedMs);
}

test "retried mutations refresh Today statistics at the current wall clock" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/retry-stats-refresh-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    const old_now = 1_000_000_000;
    var start_payload: [41]u8 = undefined;
    testMutationPrefix(&start_payload, 0, old_now - 2_000);
    putTestLe(&start_payload, 24, 0, 8);
    start_payload[32] = 0;
    putTestLe(&start_payload, 33, 1_000, 8);
    database.freeResponse(try database.handleRequest(sqlite.timer_start_command, &start_payload));

    var complete_payload: [33]u8 = undefined;
    testMutationPrefix(&complete_payload, 1, old_now - 1_000);
    putTestLe(&complete_payload, 24, 1, 8);
    complete_payload[32] = 0;
    database.freeResponse(try database.handleRequest(sqlite.timer_complete_command, &complete_payload));

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.revision = 2;
    model.nowMs = old_now;
    model.saving = true;
    model.pendingKind = .settings;
    const changed_settings = core.rt.frameCreate(core.DbSettings, model.settings.*);
    changed_settings.dailyGoalMinutes = 180;
    model.pendingSettings = changed_settings;

    const original = core.update(model, .{ .intent_now = old_now });
    const failed = core.update(original.model, .{ .db_err = "database_busy" });
    const retry = core.update(failed.model, .retry_save);
    const old_clock_snapshot = try database.handleRequest(
        sqlite.settings_set_command,
        retry.model.retryPayload,
    );
    defer database.freeResponse(old_clock_snapshot);
    const committed = core.update(retry.model, .{ .db_ok = old_clock_snapshot });
    try std.testing.expectEqual(@as(i64, 1_000), committed.model.stats.todayFocusMs);
    try std.testing.expect(committed.model.saving);
    try std.testing.expect(committed.cmd.len > 0);

    const fresh_now = old_now + 172_800_000;
    const contended_refresh = core.update(committed.model, .{ .refresh_now = fresh_now });
    const refresh_error = core.update(contended_refresh.model, .{ .db_err = "database_busy" });
    try std.testing.expectEqual(core.LoadState.ready, refresh_error.model.loadState);
    try std.testing.expect(!refresh_error.model.saving);
    try std.testing.expect(!refresh_error.model.hasWriteError);
    try std.testing.expectEqual(core.PendingKind.none, refresh_error.model.pendingKind);
    try std.testing.expectEqual(@as(i64, 180), refresh_error.model.settings.dailyGoalMinutes);

    const reload = core.update(committed.model, .{ .refresh_now = fresh_now });
    const fresh_snapshot = try database.handleRequest(sqlite.load_command, reload.model.retryPayload);
    defer database.freeResponse(fresh_snapshot);
    const refreshed = core.update(reload.model, .{ .db_ok = fresh_snapshot });
    try std.testing.expectEqual(@as(i64, fresh_now), refreshed.model.nowMs);
    try std.testing.expectEqual(@as(i64, 0), refreshed.model.stats.todayFocusMs);
    try std.testing.expectEqual(@as(i64, 0), refreshed.model.stats.todayCompletedSessions);
    try std.testing.expect(!refreshed.model.saving);
}

test "post-retry refresh preserves completion UX after sleep crosses the deadline" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/retry-sleep-completion-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    const title = "Wake into the completion review";
    var create_payload: [32 + title.len]u8 = undefined;
    testMutationPrefix(&create_payload, 0, 500);
    putTestLe(&create_payload, 24, 25, 4);
    putTestLe(&create_payload, 28, title.len, 4);
    @memcpy(create_payload[32..], title);
    database.freeResponse(try database.handleRequest(sqlite.task_create_command, &create_payload));

    var start_payload: [41]u8 = undefined;
    testMutationPrefix(&start_payload, 1, 1_000);
    putTestLe(&start_payload, 24, 1, 8);
    start_payload[32] = 0;
    putTestLe(&start_payload, 33, 1_000, 8);
    database.freeResponse(try database.handleRequest(sqlite.timer_start_command, &start_payload));

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.revision = 2;
    model.nowMs = 1_500;
    const task = core.rt.frameCreate(core.DbTask, .{
        .id = 1,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 500,
        .updatedMs = 500,
        .completedMs = 0,
        .title = title,
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = task;
    model.tasks = tasks;
    model.activeSession = core.rt.frameCreate(core.DbSession, .{
        .id = 1,
        .taskId = 1,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 1_000,
        .endsMs = 2_000,
        .remainingMs = 1_000,
        .plannedMs = 1_000,
        .focusedMs = 0,
        .endedMs = 0,
    });
    model.saving = true;
    model.pendingKind = .settings;
    const changed_settings = core.rt.frameCreate(core.DbSettings, model.settings.*);
    changed_settings.shortBreakMinutes = 10;
    model.pendingSettings = changed_settings;

    const original = core.update(model, .{ .intent_now = 1_500 });
    const failed = core.update(original.model, .{ .db_err = "database_busy" });
    const retry = core.update(failed.model, .retry_save);
    const mutation_snapshot = try database.handleRequest(
        sqlite.settings_set_command,
        retry.model.retryPayload,
    );
    defer database.freeResponse(mutation_snapshot);
    const committed = core.update(retry.model, .{ .db_ok = mutation_snapshot });
    try std.testing.expect(committed.model.activeSession != null);
    try std.testing.expect(committed.model.saving);

    const refresh = core.update(committed.model, .{ .refresh_now = 3_000 });
    const recovered_snapshot = try database.handleRequest(sqlite.load_command, refresh.model.retryPayload);
    defer database.freeResponse(recovered_snapshot);
    const recovered = core.update(refresh.model, .{ .db_ok = recovered_snapshot });
    try std.testing.expect(recovered.model.activeSession == null);
    try std.testing.expectEqual(core.SessionViewState.complete, core.sessionState(recovered.model));
    try std.testing.expect(recovered.model.quickWindowOpen);
    try std.testing.expect(recovered.model.completionDialogOpen);
    try std.testing.expectEqual(@as(i64, 1), recovered.model.completionTaskId);
    try std.testing.expectEqual(@as(i64, 1), recovered.model.completionSessionId);
    try std.testing.expect(recovered.cmd.len > 0);
}

test "wall clock rollback pauses and resumes through the authoritative SQLite session" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/wall-clock-rollback-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    var start_payload: [41]u8 = undefined;
    testMutationPrefix(&start_payload, 0, 10_000);
    putTestLe(&start_payload, 24, 0, 8); // unassigned focus block
    start_payload[32] = 0; // focus
    putTestLe(&start_payload, 33, 10_000, 8);
    const started_snapshot = try database.handleRequest(sqlite.timer_start_command, &start_payload);
    defer database.freeResponse(started_snapshot);

    const seed = core.initialModel().model;
    const starting = core.rt.frameCreate(core.Model, seed.*);
    starting.loadState = .ready;
    starting.revision = 0;
    starting.nowMs = 10_000;
    starting.saving = true;
    starting.pendingKind = .timer_start;
    starting.pendingTaskId = 0;
    starting.pendingMode = .focus;
    starting.pendingNowMs = 10_000;
    const started = core.update(starting, .{ .db_ok = started_snapshot });
    try std.testing.expect(started.model.activeSession != null);
    try std.testing.expectEqual(core.SessionState.running, started.model.activeSession.?.state);
    try std.testing.expectEqual(@as(i64, 20_000), started.model.activeSession.?.endsMs);

    const observed = core.update(started.model, .{ .tick = 15_000 });
    try std.testing.expectEqual(@as(i64, 15_000), observed.model.nowMs);
    try std.testing.expectEqual(core.PendingKind.none, observed.model.pendingKind);

    // Invalid runtime timestamps neither move the display clock nor forge a
    // natural completion. Intent/load sampling retains the last valid wall
    // clock instead of serializing an unsafe u64 into SQLite.
    const invalid_tick = core.update(observed.model, .{ .tick = 9_007_199_254_740_992 });
    try std.testing.expectEqual(@as(usize, 0), invalid_tick.cmd.len);
    try std.testing.expectEqual(@as(i64, 15_000), invalid_tick.model.nowMs);
    try std.testing.expectEqual(core.PendingKind.none, invalid_tick.model.pendingKind);
    const invalid_due = core.update(observed.model, .{ .focus_due = -1 });
    try std.testing.expectEqual(@as(usize, 0), invalid_due.cmd.len);
    try std.testing.expectEqual(@as(i64, 15_000), invalid_due.model.nowMs);
    try std.testing.expectEqual(core.PendingKind.none, invalid_due.model.pendingKind);

    const pause_intent = core.update(observed.model, .pause_focus);
    const invalid_intent_now = core.update(pause_intent.model, .{ .intent_now = 9_007_199_254_740_992 });
    try std.testing.expectEqual(@as(i64, 15_000), invalid_intent_now.model.pendingNowMs);
    const invalid_reload_now = core.update(observed.model, .{ .reload_now = 9_007_199_254_740_992 });
    try std.testing.expectEqual(@as(i64, 15_000), invalid_reload_now.model.pendingNowMs);

    // This rollback remains above SQLite's last transition (10_000). The
    // core must therefore request an explicit authoritative pause rather
    // than merely moving its display clock backwards.
    const rollback = core.update(observed.model, .{ .tick = 14_000 });
    try std.testing.expect(rollback.model.saving);
    try std.testing.expectEqual(core.PendingKind.timer_pause, rollback.model.pendingKind);
    try std.testing.expectEqual(@as(i64, 14_000), rollback.model.nowMs);
    try std.testing.expectEqual(@as(i64, 14_000), rollback.model.pendingNowMs);
    try std.testing.expectEqual(@as(usize, 32), rollback.model.retryPayload.len);
    try std.testing.expect(rollback.cmd.len > 0);
    try std.testing.expectEqual(@intFromEnum(core.rt.CmdOp.request), rollback.cmd[0]);

    const concurrent_due = core.update(rollback.model, .{ .focus_due = 20_000 });
    try std.testing.expectEqual(@as(usize, 0), concurrent_due.cmd.len);
    try std.testing.expectEqual(core.PendingKind.timer_pause, concurrent_due.model.pendingKind);
    try std.testing.expectEqualSlices(u8, rollback.model.retryPayload, concurrent_due.model.retryPayload);

    const paused_snapshot = try database.handleRequest(sqlite.timer_pause_command, rollback.model.retryPayload);
    defer database.freeResponse(paused_snapshot);
    const paused = core.update(rollback.model, .{ .db_ok = paused_snapshot });
    try std.testing.expectEqual(@as(i64, 2), paused.model.revision);
    try std.testing.expectEqual(@as(i64, 14_000), paused.model.nowMs);
    try std.testing.expect(paused.model.activeSession != null);
    try std.testing.expectEqual(core.SessionState.paused, paused.model.activeSession.?.state);
    try std.testing.expectEqual(@as(i64, 6_000), paused.model.activeSession.?.remainingMs);
    try std.testing.expectEqual(@as(i64, 4_000), paused.model.activeSession.?.focusedMs);
    try std.testing.expectEqual(@as(i64, 0), paused.model.activeSession.?.endsMs);

    // Resume intentionally rebases to the new wall clock, even though it is
    // earlier than the pause acknowledgement retained by the model.
    const resume_intent = core.update(paused.model, .resume_focus);
    const resume_requested = core.update(resume_intent.model, .{ .intent_now = 13_000 });
    try std.testing.expectEqual(@as(i64, 13_000), resume_requested.model.pendingNowMs);
    const resumed_snapshot = try database.handleRequest(sqlite.timer_resume_command, resume_requested.model.retryPayload);
    defer database.freeResponse(resumed_snapshot);
    const resumed = core.update(resume_requested.model, .{ .db_ok = resumed_snapshot });
    try std.testing.expectEqual(@as(i64, 3), resumed.model.revision);
    try std.testing.expectEqual(@as(i64, 13_000), resumed.model.nowMs);
    try std.testing.expect(resumed.model.activeSession != null);
    try std.testing.expectEqual(core.SessionState.running, resumed.model.activeSession.?.state);
    try std.testing.expectEqual(@as(i64, 6_000), resumed.model.activeSession.?.remainingMs);
    try std.testing.expectEqual(@as(i64, 19_000), resumed.model.activeSession.?.endsMs);

    const early_due = core.update(resumed.model, .{ .focus_due = 18_900 });
    try std.testing.expect(!early_due.model.saving);
    try std.testing.expectEqual(core.PendingKind.none, early_due.model.pendingKind);
    try std.testing.expectEqual(@as(i64, 18_900), early_due.model.nowMs);
    try std.testing.expect(early_due.cmd.len > 0);
    try std.testing.expectEqual(@intFromEnum(core.rt.CmdOp.delay), early_due.cmd[0]);

    const completing = core.update(early_due.model, .{ .focus_due = 19_000 });
    try std.testing.expect(completing.model.saving);
    try std.testing.expectEqual(core.PendingKind.timer_complete_natural, completing.model.pendingKind);
    try std.testing.expect(completing.cmd.len > 0);
    try std.testing.expectEqual(@intFromEnum(core.rt.CmdOp.request), completing.cmd[0]);

    const duplicate_due = core.update(completing.model, .{ .focus_due = 19_001 });
    const duplicate_tick = core.update(completing.model, .{ .tick = 19_001 });
    try std.testing.expectEqual(@as(usize, 0), duplicate_due.cmd.len);
    try std.testing.expectEqual(@as(usize, 0), duplicate_tick.cmd.len);
    try std.testing.expectEqual(core.PendingKind.timer_complete_natural, duplicate_due.model.pendingKind);
    try std.testing.expectEqualSlices(u8, completing.model.retryPayload, duplicate_due.model.retryPayload);

    const completed_snapshot = try database.handleRequest(sqlite.timer_complete_command, completing.model.retryPayload);
    defer database.freeResponse(completed_snapshot);
    const completed = core.update(completing.model, .{ .db_ok = completed_snapshot });
    try std.testing.expectEqual(@as(i64, 4), completed.model.revision);
    try std.testing.expect(completed.model.activeSession == null);
    try std.testing.expectEqual(@as(usize, 1), completed.model.recentSessions.len);
    try std.testing.expectEqual(core.SessionState.completed, completed.model.recentSessions[0].state);
    try std.testing.expectEqual(@as(i64, 10_000), completed.model.recentSessions[0].focusedMs);
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

/// A minimal, valid `FCS2` snapshot body: no tasks, no live session, no
/// history. Tests that only exercise reducer branches use this instead of a
/// live SQLite round trip, so they stay pure model tests.
fn testWriteU32(buffer: []u8, at: *usize, value: u32) void {
    std.mem.writeInt(u32, buffer[at.*..][0..4], value, .little);
    at.* += 4;
}

fn testWriteU64(buffer: []u8, at: *usize, value: u64) void {
    std.mem.writeInt(u64, buffer[at.*..][0..8], value, .little);
    at.* += 8;
}

fn testEmptySnapshot(buffer: []u8, focus_minutes: u32) []const u8 {
    var at: usize = 0;
    @memcpy(buffer[0..4], "FCS2");
    at = 4;
    testWriteU32(buffer, &at, 3); // protocol version
    testWriteU64(buffer, &at, 1); // revision
    testWriteU32(buffer, &at, focus_minutes);
    testWriteU32(buffer, &at, 5); // short break
    testWriteU32(buffer, &at, 15); // long break
    testWriteU32(buffer, &at, 120); // daily goal
    buffer[at] = 1; // completion sound
    at += 1;
    buffer[at] = 1; // global shortcut enabled
    buffer[at + 1] = 0; // Command + Shift
    buffer[at + 2] = 0; // F
    at += 3;
    testWriteU64(buffer, &at, 1); // next task id
    testWriteU32(buffer, &at, 0); // task count
    buffer[at] = 0; // no active session
    at += 1;
    testWriteU32(buffer, &at, 0); // recent session count
    testWriteU64(buffer, &at, 0); // today focus ms
    testWriteU32(buffer, &at, 0); // today completed sessions
    testWriteU32(buffer, &at, 0); // today completed tasks
    testWriteU32(buffer, &at, 7); // week bucket count
    buffer[at] = 0; // today weekday
    at += 1;
    for (0..7) |_| testWriteU64(buffer, &at, 0);
    return buffer[0..at];
}

/// The same shape as `testEmptySnapshot`, plus one open task and the session
/// SQLite recovered at its deadline while handling an unrelated mutation.
fn testRecoveredSnapshot(buffer: []u8) []const u8 {
    const title = "Captured while the block ended";
    var at: usize = 0;
    @memcpy(buffer[0..4], "FCS2");
    at = 4;
    testWriteU32(buffer, &at, 3);
    testWriteU64(buffer, &at, 2); // revision
    testWriteU32(buffer, &at, 25);
    testWriteU32(buffer, &at, 5);
    testWriteU32(buffer, &at, 15);
    testWriteU32(buffer, &at, 120);
    buffer[at] = 1;
    at += 1;
    buffer[at] = 1;
    buffer[at + 1] = 0;
    buffer[at + 2] = 0;
    at += 3;
    testWriteU64(buffer, &at, 4); // next task id
    testWriteU32(buffer, &at, 1); // one task
    testWriteU64(buffer, &at, 3); // task id
    buffer[at] = 0; // open
    at += 1;
    testWriteU32(buffer, &at, 0); // sort order
    testWriteU32(buffer, &at, 25); // estimate minutes
    testWriteU64(buffer, &at, 500); // created
    testWriteU64(buffer, &at, 500); // updated
    testWriteU64(buffer, &at, 0); // completed
    testWriteU32(buffer, &at, title.len);
    @memcpy(buffer[at..][0..title.len], title);
    at += title.len;
    buffer[at] = 0; // no live session: the deadline was recovered
    at += 1;
    testWriteU32(buffer, &at, 1); // one recent session
    testWriteU64(buffer, &at, 9); // session id
    testWriteU64(buffer, &at, 3); // task id
    buffer[at] = 0; // focus
    at += 1;
    buffer[at] = 2; // completed
    at += 1;
    buffer[at] = 3; // recovered
    at += 1;
    testWriteU64(buffer, &at, 1_000); // started
    testWriteU64(buffer, &at, 0); // ends
    testWriteU64(buffer, &at, 0); // remaining
    testWriteU64(buffer, &at, 1_000); // planned
    testWriteU64(buffer, &at, 1_000); // focused
    testWriteU64(buffer, &at, 2_000); // ended
    testWriteU64(buffer, &at, 0); // today focus ms
    testWriteU32(buffer, &at, 1); // today completed sessions
    testWriteU32(buffer, &at, 0); // today completed tasks
    testWriteU32(buffer, &at, 7);
    buffer[at] = 0;
    at += 1;
    for (0..7) |_| testWriteU64(buffer, &at, 0);
    return buffer[0..at];
}

fn testStatusItemById(state: App.StatusItemState, id: u32) ?native_sdk.TrayMenuItem {
    for (state.items) |item| {
        if (!item.separator and item.id == id) return item;
    }
    return null;
}

test "status item disables write transports while a failed write owns retry" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.hasWriteError = true;
    model.pendingKind = .task_rename;
    model.retryPayload = "failed-authoritative-write";
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
    var state = modelStatusItem(model, &scratch);
    var retry_item = testStatusItemById(state, 15);
    var transport_item = testStatusItemById(state, 20);
    try std.testing.expect(retry_item != null);
    try std.testing.expect(transport_item != null);
    try std.testing.expect(retry_item.?.enabled);
    try std.testing.expectEqualStrings("app.retry", retry_item.?.command);
    try std.testing.expectEqualStrings("Start Focus", transport_item.?.label);
    try std.testing.expectEqualStrings("app.quick-toggle", transport_item.?.command);
    try std.testing.expect(!transport_item.?.enabled);

    model.selectedTaskId = -1;
    state = modelStatusItem(model, &scratch);
    transport_item = testStatusItemById(state, 20);
    try std.testing.expect(transport_item != null);
    try std.testing.expectEqualStrings("Choose a Task in Quick Focus…", transport_item.?.label);
    try std.testing.expectEqualStrings("app.quick", transport_item.?.command);
    try std.testing.expect(transport_item.?.enabled);
    model.selectedTaskId = 3;

    const session = core.rt.frameCreate(core.DbSession, .{
        .id = 7,
        .taskId = 3,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 0,
        .endsMs = 1_500_000,
        .remainingMs = 1_500_000,
        .plannedMs = 1_500_000,
        .focusedMs = 0,
        .endedMs = 0,
    });
    model.activeSession = session;

    state = modelStatusItem(model, &scratch);
    transport_item = testStatusItemById(state, 20);
    var finish_item = testStatusItemById(state, 21);
    try std.testing.expect(transport_item != null);
    try std.testing.expect(finish_item != null);
    try std.testing.expectEqualStrings("Pause Focus", transport_item.?.label);
    try std.testing.expect(!transport_item.?.enabled);
    try std.testing.expectEqualStrings("Finish Focus…", finish_item.?.label);
    try std.testing.expect(!finish_item.?.enabled);

    session.mode = .short;
    state = modelStatusItem(model, &scratch);
    transport_item = testStatusItemById(state, 20);
    finish_item = testStatusItemById(state, 21);
    try std.testing.expectEqualStrings("Pause Break", transport_item.?.label);
    try std.testing.expect(!transport_item.?.enabled);
    try std.testing.expectEqualStrings("Finish Break…", finish_item.?.label);
    try std.testing.expect(!finish_item.?.enabled);

    session.state = .paused;
    session.mode = .focus;
    state = modelStatusItem(model, &scratch);
    transport_item = testStatusItemById(state, 20);
    try std.testing.expectEqualStrings("Resume Focus", transport_item.?.label);
    try std.testing.expect(!transport_item.?.enabled);

    session.mode = .long;
    state = modelStatusItem(model, &scratch);
    transport_item = testStatusItemById(state, 20);
    try std.testing.expectEqualStrings("Resume Break", transport_item.?.label);
    try std.testing.expect(!transport_item.?.enabled);

    const quick_toggle = core.update(model, .quick_toggle_command);
    const global_toggle = core.update(model, .toggle_focus_command);
    const main_end = core.update(model, .request_end_focus);
    const quick_end = core.update(model, .request_quick_end_focus);
    const tray_end = core.update(model, .open_quick_end);
    try std.testing.expectEqual(@as(usize, 0), quick_toggle.cmd.len);
    try std.testing.expectEqual(@as(usize, 0), global_toggle.cmd.len);
    try std.testing.expect(quick_toggle.model.hasWriteError);
    try std.testing.expect(global_toggle.model.hasWriteError);
    try std.testing.expectEqual(core.PendingKind.task_rename, quick_toggle.model.pendingKind);
    try std.testing.expectEqual(core.PendingKind.task_rename, global_toggle.model.pendingKind);
    try std.testing.expectEqualSlices(u8, model.retryPayload, quick_toggle.model.retryPayload);
    try std.testing.expectEqualSlices(u8, model.retryPayload, global_toggle.model.retryPayload);
    try std.testing.expect(!main_end.model.endDialogOpen);
    try std.testing.expect(!quick_end.model.endDialogOpen);
    try std.testing.expect(!tray_end.model.endDialogOpen);
    try std.testing.expectEqual(@as(usize, 0), main_end.cmd.len);
    try std.testing.expectEqual(@as(usize, 0), quick_end.cmd.len);
    try std.testing.expectEqual(@as(usize, 0), tray_end.cmd.len);

    // The retry route itself remains actionable while all authoritative
    // transports are projected disabled.
    retry_item = testStatusItemById(state, 15);
    try std.testing.expect(retry_item != null);
    try std.testing.expect(retry_item.?.enabled);
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

test "escape command reaches the same safe dismissal reducer" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.quickWindowOpen = true;

    const message = core.commandMsg("app.escape") orelse {
        try std.testing.expect(false);
        return;
    };
    const escaped = core.update(model, message);
    try std.testing.expect(!escaped.model.quickWindowOpen);
}

test "surface-aware escape does not close a background auxiliary window" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.settingsWindowOpen = true;
    model.editTaskId = 9;

    const main_message = core.commandMsg("app.escape-main") orelse {
        try std.testing.expect(false);
        return;
    };
    const main_escape = core.update(model, main_message);
    try std.testing.expect(main_escape.model.settingsWindowOpen);
    try std.testing.expectEqual(@as(i64, -1), main_escape.model.editTaskId);

    const settings_message = core.commandMsg("app.escape-settings") orelse {
        try std.testing.expect(false);
        return;
    };
    const settings_escape = core.update(main_escape.model, settings_message);
    try std.testing.expect(!settings_escape.model.settingsWindowOpen);
}

test "focus recovery rekeys mounted controls and names a surviving target" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const open_task = core.rt.frameCreate(core.DbTask, .{
        .id = 3,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 10,
        .updatedMs = 10,
        .completedMs = 0,
        .title = "Write the launch brief",
    });
    const archived_task = core.rt.frameCreate(core.DbTask, .{
        .id = 4,
        .state = .archived,
        .sortOrder = 1,
        .estimateMinutes = 25,
        .createdMs = 10,
        .updatedMs = 10,
        .completedMs = 0,
        .title = "Old launch brief",
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 2);
    tasks[0] = open_task;
    tasks[1] = archived_task;
    model.tasks = tasks;

    const main_epoch = model.mainStartFocusEpoch;
    const selected = core.update(model, .{ .select_task = 3 });
    try std.testing.expect(selected.model.startAutofocus);
    try std.testing.expectEqual(main_epoch + 1, selected.model.mainStartFocusEpoch);
    try std.testing.expectEqual(@as(usize, 0), selected.cmd.len);

    const quick_epoch = selected.model.quickStartFocusEpoch;
    const quick_selected = core.update(selected.model, .{ .select_quick_task = 3 });
    try std.testing.expectEqual(main_epoch + 1, quick_selected.model.mainStartFocusEpoch);
    try std.testing.expectEqual(quick_epoch + 1, quick_selected.model.quickStartFocusEpoch);

    const opened_quick = core.update(quick_selected.model, .open_quick);
    try std.testing.expect(opened_quick.model.quickWindowOpen);
    try std.testing.expectEqual(quick_epoch + 2, opened_quick.model.quickStartFocusEpoch);
    try std.testing.expect(opened_quick.cmd.len > 0);

    const rename_epoch = opened_quick.model.editFocusEpoch;
    const renaming = core.update(opened_quick.model, .{ .begin_rename = 3 });
    try std.testing.expectEqual(@as(i64, 3), renaming.model.editTaskId);
    try std.testing.expect(!renaming.model.editAutofocus);
    try std.testing.expect(renaming.cmd.len > 0);
    const rename_armed = core.update(renaming.model, .{ .arm_edit_autofocus = 100 });
    try std.testing.expect(rename_armed.model.editAutofocus);
    try std.testing.expectEqual(rename_epoch + 1, rename_armed.model.editFocusEpoch);

    const rename_cancelled = core.update(rename_armed.model, .cancel_rename);
    try std.testing.expectEqual(core.FocusRecoveryKind.task_row, rename_cancelled.model.focusRecoveryKind);
    try std.testing.expectEqual(@as(i64, 3), rename_cancelled.model.focusRecoveryTaskId);
    const open_rows = core.visibleTasks(rename_cancelled.model);
    try std.testing.expectEqual(@as(usize, 1), open_rows.len);
    try std.testing.expect(open_rows[0].autofocus);

    const archived_model = core.rt.frameCreate(core.Model, rename_cancelled.model.*);
    archived_model.taskFilter = .archived;
    archived_model.actionTaskId = -1;
    const purge_epoch = archived_model.purgeFocusEpoch;
    const purging = core.update(archived_model, .{ .request_purge_task = 4 });
    try std.testing.expect(purging.model.purgeDialogOpen);
    try std.testing.expect(purging.model.purgeAutofocus);
    try std.testing.expectEqual(@as(i64, 4), purging.model.actionTaskId);
    try std.testing.expectEqual(purge_epoch + 1, purging.model.purgeFocusEpoch);
    const purge_cancelled = core.update(purging.model, .cancel_purge_task);
    try std.testing.expectEqual(core.FocusRecoveryKind.purge_trigger, purge_cancelled.model.focusRecoveryKind);
    try std.testing.expectEqual(@as(i64, 4), purge_cancelled.model.focusRecoveryTaskId);
    try std.testing.expect(!core.mainComposerAutofocus(purge_cancelled.model));
    try std.testing.expect(!core.quickComposerAutofocus(purge_cancelled.model));
    const archived_rows = core.visibleTasks(purge_cancelled.model);
    try std.testing.expectEqual(@as(usize, 1), archived_rows.len);
    try std.testing.expect(!archived_rows[0].autofocus);
    try std.testing.expect(archived_rows[0].purgeAutofocus);
}

test "selected task actions menu is model-owned and closes before an action" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const task = core.rt.frameCreate(core.DbTask, .{
        .id = 7,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 10,
        .updatedMs = 10,
        .completedMs = 0,
        .title = "Expose the task actions",
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = task;
    model.tasks = tasks;

    const selected = core.update(model, .{ .select_task = 7 });
    const opened = core.update(selected.model, .{ .toggle_task_actions = 7 });
    try std.testing.expectEqual(@as(i64, 7), opened.model.taskActionsTaskId);

    const dismissed = core.update(opened.model, .dismiss_task_actions);
    try std.testing.expectEqual(@as(i64, -1), dismissed.model.taskActionsTaskId);

    const reopened = core.update(dismissed.model, .{ .toggle_task_actions = 7 });
    const renaming = core.update(reopened.model, .{ .begin_rename = 7 });
    try std.testing.expectEqual(@as(i64, -1), renaming.model.taskActionsTaskId);
    try std.testing.expectEqual(@as(i64, 7), renaming.model.editTaskId);
}

test "restoring an archived task returns to the recovered open row" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/restore-continuity-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    const title = "Recover the launch checklist";
    var create_payload: [32 + title.len]u8 = undefined;
    testMutationPrefix(&create_payload, 0, 1_000);
    putTestLe(&create_payload, 24, 25, 4);
    putTestLe(&create_payload, 28, title.len, 4);
    @memcpy(create_payload[32..], title);
    database.freeResponse(try database.handleRequest(sqlite.task_create_command, &create_payload));

    var state_payload: [33]u8 = undefined;
    testMutationPrefix(&state_payload, 1, 2_000);
    putTestLe(&state_payload, 24, 1, 8);
    state_payload[32] = 2; // archived
    database.freeResponse(try database.handleRequest(sqlite.task_set_state_command, &state_payload));

    testMutationPrefix(&state_payload, 2, 3_000);
    putTestLe(&state_payload, 24, 1, 8);
    state_payload[32] = 0; // restored open
    const restored_snapshot = try database.handleRequest(sqlite.task_set_state_command, &state_payload);
    defer database.freeResponse(restored_snapshot);

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.revision = 2;
    model.taskFilter = .archived;
    model.actionTaskId = 1;
    model.saving = true;
    model.pendingKind = .task_restore;
    model.pendingTaskId = 1;
    const archived = core.rt.frameCreate(core.DbTask, .{
        .id = 1,
        .state = .archived,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 1_000,
        .updatedMs = 2_000,
        .completedMs = 0,
        .title = title,
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = archived;
    model.tasks = tasks;

    const committed = core.update(model, .{ .db_ok = restored_snapshot });
    try std.testing.expectEqual(core.Section.today, committed.model.section);
    try std.testing.expectEqual(core.TaskFilter.open, committed.model.taskFilter);
    try std.testing.expectEqual(@as(i64, 1), committed.model.selectedTaskId);
    try std.testing.expectEqual(@as(i64, 1), committed.model.actionTaskId);
    try std.testing.expectEqual(core.FocusRecoveryKind.task_row, committed.model.focusRecoveryKind);
    try std.testing.expectEqual(@as(i64, 1), committed.model.focusRecoveryTaskId);
    const rows = core.visibleTasks(committed.model);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].autofocus);
}

test "archive undo preserves a completed task's prior state" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/completed-undo-continuity-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    const title = "Ship the completed release";
    var create_payload: [32 + title.len]u8 = undefined;
    testMutationPrefix(&create_payload, 0, 1_000);
    putTestLe(&create_payload, 24, 25, 4);
    putTestLe(&create_payload, 28, title.len, 4);
    @memcpy(create_payload[32..], title);
    database.freeResponse(try database.handleRequest(sqlite.task_create_command, &create_payload));

    var complete_payload: [33]u8 = undefined;
    testMutationPrefix(&complete_payload, 1, 2_000);
    putTestLe(&complete_payload, 24, 1, 8);
    complete_payload[32] = 1;
    database.freeResponse(try database.handleRequest(sqlite.task_set_state_command, &complete_payload));

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.revision = 2;
    model.nowMs = 2_000;
    model.taskFilter = .completed;
    const task = core.rt.frameCreate(core.DbTask, .{
        .id = 1,
        .state = .completed,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 1_000,
        .updatedMs = 2_000,
        .completedMs = 2_000,
        .title = title,
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = task;
    model.tasks = tasks;
    model.actionTaskId = 1;

    const archiving = core.update(model, .{ .delete_task = 1 });
    try std.testing.expectEqual(core.PendingKind.task_archive, archiving.model.pendingKind);
    try std.testing.expectEqual(core.TaskState.archived, archiving.model.pendingTaskState);
    try std.testing.expectEqual(@as(i64, 0), archiving.model.undoTaskId);

    const archive_request = core.update(archiving.model, .{ .intent_now = 3_000 });
    const archived_snapshot = try database.handleRequest(
        sqlite.task_set_state_command,
        archive_request.model.retryPayload,
    );
    defer database.freeResponse(archived_snapshot);
    const committed_archive = core.update(archive_request.model, .{ .db_ok = archived_snapshot });
    try std.testing.expectEqual(@as(i64, 1), committed_archive.model.undoTaskId);
    try std.testing.expectEqual(core.TaskState.completed, committed_archive.model.undoTaskState);
    try std.testing.expectEqual(core.TaskState.archived, committed_archive.model.tasks[0].state);

    const undoing = core.update(committed_archive.model, .undo_delete);
    try std.testing.expectEqual(core.PendingKind.task_undo_archive, undoing.model.pendingKind);
    try std.testing.expectEqual(core.TaskState.completed, undoing.model.pendingTaskState);
    try std.testing.expect(undoing.cmd.len > 0);

    const undo_request = core.update(undoing.model, .{ .intent_now = 4_000 });
    const restored_snapshot = try database.handleRequest(
        sqlite.task_undo_archive_command,
        undo_request.model.retryPayload,
    );
    defer database.freeResponse(restored_snapshot);
    const committed_undo = core.update(undo_request.model, .{ .db_ok = restored_snapshot });
    try std.testing.expectEqual(core.Section.today, committed_undo.model.section);
    try std.testing.expectEqual(core.TaskFilter.completed, committed_undo.model.taskFilter);
    try std.testing.expectEqual(@as(i64, -1), committed_undo.model.selectedTaskId);
    try std.testing.expectEqual(@as(i64, 1), committed_undo.model.actionTaskId);
    try std.testing.expectEqual(@as(i64, 0), committed_undo.model.undoTaskId);
    try std.testing.expectEqual(core.TaskState.completed, committed_undo.model.tasks[0].state);
    try std.testing.expectEqual(@as(i64, 2_000), committed_undo.model.tasks[0].completedMs);
    try std.testing.expectEqual(core.FocusRecoveryKind.task_row, committed_undo.model.focusRecoveryKind);
    try std.testing.expectEqual(@as(i64, 1), committed_undo.model.focusRecoveryTaskId);
    const rows = core.visibleTasks(committed_undo.model);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].autofocus);
}

test "reload clears an Undo whose archived row changed in another instance" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/stale-undo-normalization-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    const title = "Resolve the shared archive";
    var create_payload: [32 + title.len]u8 = undefined;
    testMutationPrefix(&create_payload, 0, 1_000);
    putTestLe(&create_payload, 24, 25, 4);
    putTestLe(&create_payload, 28, title.len, 4);
    @memcpy(create_payload[32..], title);
    database.freeResponse(try database.handleRequest(sqlite.task_create_command, &create_payload));

    var load_payload: [16]u8 = undefined;
    @memcpy(load_payload[0..4], "FCL1");
    putTestLe(&load_payload, 4, 1, 4);
    putTestLe(&load_payload, 8, 2_000, 8);
    const open_snapshot = try database.handleRequest(sqlite.load_command, &load_payload);
    defer database.freeResponse(open_snapshot);

    const seed = core.initialModel().model;
    const stale = core.rt.frameCreate(core.Model, seed.*);
    stale.loadState = .ready;
    stale.saving = true;
    stale.pendingKind = .load;
    stale.undoTaskId = 1;
    stale.undoTaskTitle = title;
    stale.undoTaskState = .open;
    const archived = core.rt.frameCreate(core.DbTask, .{
        .id = 1,
        .state = .archived,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 1_000,
        .updatedMs = 1_500,
        .completedMs = 0,
        .title = title,
    });
    const stale_tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    stale_tasks[0] = archived;
    stale.tasks = stale_tasks;
    try std.testing.expect(core.hasUndo(stale));

    const stale_revision = core.update(stale, .{ .db_err = "stale_revision" });
    try std.testing.expectEqual(@as(i64, 0), stale_revision.model.undoTaskId);
    try std.testing.expect(!core.hasUndo(stale_revision.model));
    try std.testing.expectEqual(core.PendingKind.load, stale_revision.model.pendingKind);

    var archive_payload: [33]u8 = undefined;
    testMutationPrefix(&archive_payload, 1, 2_500);
    putTestLe(&archive_payload, 24, 1, 8);
    archive_payload[32] = 2;
    const externally_rearchived_snapshot = try database.handleRequest(
        sqlite.task_set_state_command,
        &archive_payload,
    );
    defer database.freeResponse(externally_rearchived_snapshot);
    const compatible_but_newer = core.rt.frameCreate(core.Model, stale.*);
    compatible_but_newer.revision = 1;
    compatible_but_newer.pendingKind = .refresh;
    const refreshed_newer = core.update(
        compatible_but_newer,
        .{ .db_ok = externally_rearchived_snapshot },
    );
    try std.testing.expectEqual(@as(i64, 0), refreshed_newer.model.undoTaskId);
    try std.testing.expect(!core.hasUndo(refreshed_newer.model));

    const reloaded = core.update(stale, .{ .db_ok = open_snapshot });
    try std.testing.expectEqual(@as(i64, 0), reloaded.model.undoTaskId);
    try std.testing.expect(!core.hasUndo(reloaded.model));

    const inconsistent = core.rt.frameCreate(core.Model, reloaded.model.*);
    inconsistent.undoTaskId = 1;
    inconsistent.undoTaskTitle = title;
    inconsistent.undoTaskState = .open;
    const ignored = core.update(inconsistent, .undo_delete);
    try std.testing.expectEqual(@as(i64, 0), ignored.model.undoTaskId);
    try std.testing.expectEqual(core.PendingKind.none, ignored.model.pendingKind);
    try std.testing.expectEqual(@as(usize, 0), ignored.cmd.len);
}

test "authoritative reload closes stale task and session confirmations" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/stale-confirmation-normalization-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    const title = "Do not overwrite another window";
    var create_payload: [32 + title.len]u8 = undefined;
    testMutationPrefix(&create_payload, 0, 1_000);
    putTestLe(&create_payload, 24, 25, 4);
    putTestLe(&create_payload, 28, title.len, 4);
    @memcpy(create_payload[32..], title);
    database.freeResponse(try database.handleRequest(sqlite.task_create_command, &create_payload));

    var archive_payload: [33]u8 = undefined;
    testMutationPrefix(&archive_payload, 1, 2_000);
    putTestLe(&archive_payload, 24, 1, 8);
    archive_payload[32] = 2;
    const archived_snapshot = try database.handleRequest(sqlite.task_set_state_command, &archive_payload);
    defer database.freeResponse(archived_snapshot);

    const seed = core.initialModel().model;
    const completion = core.rt.frameCreate(core.Model, seed.*);
    completion.loadState = .ready;
    completion.saving = true;
    completion.pendingKind = .load;
    completion.completionDialogOpen = true;
    completion.completionTaskId = 1;
    completion.completionSessionId = 41;
    const open_task = core.rt.frameCreate(core.DbTask, .{
        .id = 1,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 1_000,
        .updatedMs = 1_000,
        .completedMs = 0,
        .title = title,
    });
    const open_tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    open_tasks[0] = open_task;
    completion.tasks = open_tasks;

    const normalized_completion = core.update(completion, .{ .db_ok = archived_snapshot });
    try std.testing.expect(!normalized_completion.model.completionDialogOpen);
    try std.testing.expectEqual(@as(i64, 0), normalized_completion.model.completionTaskId);
    try std.testing.expectEqual(@as(i64, 0), normalized_completion.model.completionSessionId);

    const inconsistent = core.rt.frameCreate(core.Model, normalized_completion.model.*);
    inconsistent.completionDialogOpen = true;
    inconsistent.completionTaskId = 1;
    const safe_default = core.update(inconsistent, .complete_task_after_focus);
    try std.testing.expect(!safe_default.model.completionDialogOpen);
    try std.testing.expectEqual(core.PendingKind.none, safe_default.model.pendingKind);
    try std.testing.expectEqual(@as(usize, 0), safe_default.cmd.len);

    var start_payload: [41]u8 = undefined;
    testMutationPrefix(&start_payload, 2, 3_000);
    putTestLe(&start_payload, 24, 0, 8);
    start_payload[32] = 0;
    putTestLe(&start_payload, 33, 60_000, 8);
    const replacement_snapshot = try database.handleRequest(sqlite.timer_start_command, &start_payload);
    defer database.freeResponse(replacement_snapshot);

    const ending = core.rt.frameCreate(core.Model, seed.*);
    ending.loadState = .ready;
    ending.saving = true;
    ending.pendingKind = .load;
    ending.endDialogOpen = true;
    ending.transportAutofocus = false;
    ending.activeSession = core.rt.frameCreate(core.DbSession, .{
        .id = 99,
        .taskId = 0,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 2_000,
        .endsMs = 62_000,
        .remainingMs = 60_000,
        .plannedMs = 60_000,
        .focusedMs = 0,
        .endedMs = 0,
    });
    const normalized_session = core.update(ending, .{ .db_ok = replacement_snapshot });
    try std.testing.expect(normalized_session.model.activeSession != null);
    try std.testing.expectEqual(@as(i64, 1), normalized_session.model.activeSession.?.id);
    try std.testing.expect(!normalized_session.model.endDialogOpen);
    try std.testing.expect(normalized_session.model.transportAutofocus);
}

test "new task command focuses the composer without dropping task selection" {
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
        .title = "Keep the selected task",
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = task;
    model.tasks = tasks;
    model.selectedTaskId = 3;
    model.actionTaskId = 3;
    const composer_key = model.composerKey;

    const commanded = core.update(model, .new_task_command);
    try std.testing.expectEqual(@as(i64, 3), commanded.model.selectedTaskId);
    try std.testing.expectEqual(@as(i64, 3), commanded.model.actionTaskId);
    try std.testing.expectEqual(composer_key, commanded.model.composerKey);
    try std.testing.expectEqual(core.FocusRecoveryKind.composer_pending, commanded.model.focusRecoveryKind);
    try std.testing.expect(!core.mainComposerAutofocus(commanded.model));
    try std.testing.expect(!core.quickComposerAutofocus(commanded.model));
    try std.testing.expect(commanded.cmd.len > 0);

    const armed = core.update(commanded.model, .{ .arm_composer_autofocus = 100 });
    try std.testing.expectEqual(composer_key + 1, armed.model.composerKey);
    try std.testing.expectEqual(core.FocusRecoveryKind.composer, armed.model.focusRecoveryKind);
    try std.testing.expect(core.mainComposerAutofocus(armed.model));
    try std.testing.expect(!core.quickComposerAutofocus(armed.model));

    const typed = core.update(armed.model, .{ .task_draft_edit = .{ .insert_text = "A new task" } });
    try std.testing.expectEqual(core.FocusRecoveryKind.none, typed.model.focusRecoveryKind);
    try std.testing.expect(!core.mainComposerAutofocus(typed.model));
    try std.testing.expect(!core.quickComposerAutofocus(typed.model));
    try std.testing.expectEqual(@as(i64, 3), typed.model.selectedTaskId);
    try std.testing.expectEqualStrings("A new task", typed.model.taskDraftEditor.text);

    const quick_model = core.rt.frameCreate(core.Model, model.*);
    quick_model.quickWindowOpen = true;
    const quick_commanded = core.update(quick_model, .new_task_command);
    const quick_armed = core.update(quick_commanded.model, .{ .arm_composer_autofocus = 101 });
    try std.testing.expect(!core.mainComposerAutofocus(quick_armed.model));
    try std.testing.expect(core.quickComposerAutofocus(quick_armed.model));
}

test "settings keep the persisted default visible during an active session" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const settings = core.rt.frameCreate(core.DbSettings, model.settings.*);
    settings.focusMinutes = 50;
    model.settings = settings;
    model.activeSession = core.rt.frameCreate(core.DbSession, .{
        .id = 12,
        .taskId = 0,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 1_000,
        .endsMs = 1_501_000,
        .remainingMs = 1_500_000,
        .plannedMs = 1_500_000,
        .focusedMs = 0,
        .endedMs = 0,
    });

    try std.testing.expectEqual(@as(i64, 25), core.focusLengthMinutes(model));
    try std.testing.expectEqual(@as(i64, 50), core.settingsFocusMinutes(model));

    const changed = core.update(model, .set_duration_90);
    try std.testing.expectEqual(core.PendingKind.settings, changed.model.pendingKind);
    try std.testing.expectEqual(@as(i64, 90), changed.model.pendingSettings.focusMinutes);
    try std.testing.expect(changed.cmd.len > 0);
}

test "failed sound toggle rekeys the native switch back to persisted truth" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    try std.testing.expect(core.soundEnabled(model));
    const initial_key = core.soundSwitchKey(model);

    const toggling = core.update(model, .toggle_sound);
    try std.testing.expectEqual(core.PendingKind.settings, toggling.model.pendingKind);
    try std.testing.expect(!toggling.model.pendingSettings.soundEnabled);
    const requested = core.update(toggling.model, .{ .intent_now = 1_000 });
    const failed = core.update(requested.model, .{ .db_err = "database_busy" });
    try std.testing.expect(failed.model.hasWriteError);
    try std.testing.expect(core.soundEnabled(failed.model));
    const failed_key = core.soundSwitchKey(failed.model);
    try std.testing.expect(failed_key != initial_key);

    const discarded = core.update(failed.model, .discard_failed_change);
    try std.testing.expect(!discarded.model.hasWriteError);
    try std.testing.expect(core.soundEnabled(discarded.model));
    try std.testing.expect(core.soundSwitchKey(discarded.model) != failed_key);
    try std.testing.expectEqual(initial_key, core.soundSwitchKey(discarded.model));
}

test "shortcut preferences preserve the committed combo when native preflight rejects a change" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const active = core.update(model, .shortcut_active);
    try std.testing.expect(core.quickShortcutEnabled(active.model));
    try std.testing.expectEqual(core.QuickShortcutKey.f, core.quickShortcutKey(active.model));
    try std.testing.expectEqual(core.QuickShortcutModifiers.command_shift, core.quickShortcutModifiers(active.model));
    try std.testing.expectEqualStrings(
        "Command + Shift + US F position",
        core.quickShortcutLabel(active.model),
    );
    try std.testing.expect(core.quickShortcutSpaceUnavailable(active.model));
    try std.testing.expect(!core.quickShortcutCommandShiftUnavailable(active.model));

    const changing = core.update(active.model, .set_quick_shortcut_key_q);
    try std.testing.expect(changing.model.saving);
    try std.testing.expectEqual(core.PendingKind.settings, changing.model.pendingKind);
    try std.testing.expectEqual(core.QuickShortcutKey.q, changing.model.pendingSettings.quickShortcutKey);

    const requested = core.update(changing.model, .{ .intent_now = 1_000 });
    try std.testing.expect(requested.model.retryPayload.len > 0);
    const rejected = core.update(requested.model, .{ .db_err = "shortcut_unavailable" });
    try std.testing.expect(!rejected.model.saving);
    try std.testing.expect(!rejected.model.hasWriteError);
    try std.testing.expectEqual(core.PendingKind.none, rejected.model.pendingKind);
    try std.testing.expectEqual(core.QuickShortcutKey.f, core.quickShortcutKey(rejected.model));
    try std.testing.expect(rejected.model.quickShortcutActive);
    try std.testing.expect(core.quickShortcutHasError(rejected.model));
    try std.testing.expectEqualStrings(
        "That combination is unavailable. Your saved shortcut was not changed.",
        core.quickShortcutStatusText(rejected.model),
    );

    const disabled = core.rt.frameCreate(core.Model, active.model.*);
    const disabled_settings = core.rt.frameCreate(core.DbSettings, active.model.settings.*);
    disabled_settings.quickShortcutEnabled = false;
    disabled.settings = disabled_settings;
    disabled.quickShortcutActive = false;
    try std.testing.expect(!core.quickShortcutSpaceUnavailable(disabled));
    try std.testing.expect(!core.quickShortcutCommandShiftUnavailable(disabled));

    const choosing_while_disabled = core.update(disabled, .set_quick_shortcut_key_q);
    try std.testing.expect(choosing_while_disabled.model.saving);
    try std.testing.expect(!choosing_while_disabled.model.pendingSettings.quickShortcutEnabled);
    try std.testing.expectEqual(
        core.QuickShortcutKey.q,
        choosing_while_disabled.model.pendingSettings.quickShortcutKey,
    );

    const enabling = core.update(disabled, .toggle_quick_shortcut);
    try std.testing.expect(enabling.model.pendingSettings.quickShortcutEnabled);
    const enabling_requested = core.update(enabling.model, .{ .intent_now = 1_500 });
    const enabling_rejected = core.update(enabling_requested.model, .{ .db_err = "shortcut_unavailable" });
    try std.testing.expect(!core.quickShortcutEnabled(enabling_rejected.model));
    try std.testing.expect(core.quickShortcutHasError(enabling_rejected.model));
    try std.testing.expectEqualStrings(
        "That combination is unavailable. Your saved shortcut was not changed.",
        core.quickShortcutStatusText(enabling_rejected.model),
    );

    const switch_key_before = core.quickShortcutSwitchKey(active.model);
    const disabling = core.update(active.model, .toggle_quick_shortcut);
    try std.testing.expect(!disabling.model.pendingSettings.quickShortcutEnabled);
    try std.testing.expectEqual(core.QuickShortcutKey.f, disabling.model.pendingSettings.quickShortcutKey);
    try std.testing.expectEqual(core.QuickShortcutModifiers.command_shift, disabling.model.pendingSettings.quickShortcutModifiers);
    const disabling_requested = core.update(disabling.model, .{ .intent_now = 2_000 });
    const disabling_rejected = core.update(disabling_requested.model, .{ .db_err = "shortcut_unavailable" });
    try std.testing.expect(core.quickShortcutEnabled(disabling_rejected.model));
    try std.testing.expect(core.quickShortcutSwitchKey(disabling_rejected.model) != switch_key_before);
}

test "missing Carbon handler still permits and reports an explicit disabled shortcut" {
    var extended: ExtensionApp = undefined;
    extended.hotkey = .{};
    extended.hotkey_install_failed = true;

    const disabled: global_hotkey.Config = .{
        .enabled = false,
        .key = .f,
        .modifiers = .command_shift,
    };
    try extended.preflightShortcutCandidate(disabled);
    try std.testing.expect(extended.hotkey.stagedMatches(disabled));
    try std.testing.expectEqual(
        ExtensionApp.ShortcutReport.disabled,
        ExtensionApp.reportForMissingHandler(disabled),
    );

    const enabled: global_hotkey.Config = .{
        .enabled = true,
        .key = .f,
        .modifiers = .command_shift,
    };
    try std.testing.expectError(
        error.HotKeyHandlerUnavailable,
        extended.preflightShortcutCandidate(enabled),
    );
    try std.testing.expectEqual(
        ExtensionApp.ShortcutReport.unavailable,
        ExtensionApp.reportForMissingHandler(enabled),
    );
}

test "global Quick Focus shortcut reserves the local timer transport chord" {
    var extended: ExtensionApp = undefined;
    extended.hotkey = .{};
    extended.hotkey_install_failed = false;

    const previous: global_hotkey.Config = .{
        .enabled = false,
        .key = .f,
        .modifiers = .command_shift,
    };
    try extended.preflightShortcutCandidate(previous);

    const reserved: global_hotkey.Config = .{
        .enabled = true,
        .key = .space,
        .modifiers = .command_shift,
    };
    try std.testing.expect(global_hotkey.conflictsWithLocalTransportShortcut(reserved));
    try std.testing.expectError(
        error.HotKeyUnavailable,
        extended.preflightShortcutCandidate(reserved),
    );
    try std.testing.expect(extended.hotkey.stagedMatches(previous));

    var disabled = reserved;
    disabled.enabled = false;
    try std.testing.expect(!global_hotkey.conflictsWithLocalTransportShortcut(disabled));
    try extended.preflightShortcutCandidate(disabled);
    try std.testing.expect(extended.hotkey.stagedMatches(disabled));

    var alternate = reserved;
    alternate.modifiers = .command_option;
    try std.testing.expect(!global_hotkey.conflictsWithLocalTransportShortcut(alternate));
}

test "shortcut preflight classification ignores ordinary settings and blocks SQLite on rejection" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;

    const sound_change = core.update(model, .toggle_sound);
    try std.testing.expect(shortcutWriteCandidate(sound_change.model, sqlite.settings_set_command) == null);

    const shortcut_change = core.update(model, .set_quick_shortcut_key_q);
    const candidate = shortcutWriteCandidate(shortcut_change.model, sqlite.settings_set_command) orelse
        return error.TestExpectedShortcutCandidate;
    try std.testing.expectEqual(global_hotkey.Key.q, candidate.key);
    const requested = core.update(shortcut_change.model, .{ .intent_now = 1_000 });
    try std.testing.expect(requested.model.retryPayload.len > 0);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/shortcut-preflight-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    const RejectingPreflight = struct {
        calls: usize = 0,
        saw_settings_command: bool = false,
        payload_len: usize = 0,

        fn run(raw: *anyopaque, name: []const u8, payload: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.saw_settings_command = std.mem.eql(u8, name, sqlite.settings_set_command);
            self.payload_len = payload.len;
            return error.HotKeyUnavailable;
        }
    };
    var rejector = RejectingPreflight{};
    var host = HostContext{
        .database = &database,
        .shortcut_preflight_context = &rejector,
        .shortcut_preflight_fn = RejectingPreflight.run,
    };
    defer host.deinit();

    var load_payload: [16]u8 = undefined;
    @memcpy(load_payload[0..4], "FCL1");
    putTestLe(&load_payload, 4, 1, 4);
    putTestLe(&load_payload, 8, 900, 8);
    HostContext.request(&host, sqlite.load_command, 76, &load_payload);
    try std.testing.expectEqual(@as(usize, 0), rejector.calls);
    try std.testing.expect(host.pending_active);
    try std.testing.expect(host.pending_ok);

    HostContext.request(
        &host,
        sqlite.settings_set_command,
        77,
        requested.model.retryPayload,
    );
    try std.testing.expectEqual(@as(usize, 1), rejector.calls);
    try std.testing.expect(rejector.saw_settings_command);
    try std.testing.expect(rejector.payload_len > 0);
    try std.testing.expect(host.pending_active);
    try std.testing.expect(!host.pending_ok);
    try std.testing.expectEqualStrings("shortcut_unavailable", host.pending_bytes);

    // The exact same revision must still be writable. If request() had reached
    // SQLite before the rejecting preflight, this second call would fail with
    // stale_revision instead of committing successfully.
    const committed = try database.handleRequest(
        sqlite.settings_set_command,
        requested.model.retryPayload,
    );
    database.freeResponse(committed);
}

test "native escape interceptor preserves IME cancellation and carries surface identity" {
    const quick_escape: native_sdk.runtime.CanvasWidgetKeyboardEvent = .{
        .view_label = quick_canvas_label,
        .keyboard = .{ .phase = .key_down, .key = "escape" },
    };
    try std.testing.expectEqualStrings("app.escape-quick", escapeCommandForKeyboard(quick_escape).?);

    const main_escape: native_sdk.runtime.CanvasWidgetKeyboardEvent = .{
        .view_label = canvas_label,
        .keyboard = .{ .phase = .key_down, .key = "escape" },
    };
    try std.testing.expectEqualStrings("app.escape-main", escapeCommandForKeyboard(main_escape).?);

    const composing_escape: native_sdk.runtime.CanvasWidgetKeyboardEvent = .{
        .view_label = quick_canvas_label,
        .keyboard = .{
            .phase = .key_down,
            .key = "escape",
            .edit = .cancel_composition,
        },
    };
    try std.testing.expectEqual(@as(?[]const u8, null), escapeCommandForKeyboard(composing_escape));
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

test "escape closes frontmost settings before background completion followups" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const completion = core.rt.frameCreate(core.Model, seed.*);
    completion.loadState = .ready;
    completion.completionDialogOpen = true;
    completion.completionTaskId = 7;
    completion.completionSessionId = 11;

    const settings_over_completion = core.update(completion, .open_settings);
    try std.testing.expect(settings_over_completion.model.settingsWindowOpen);
    try std.testing.expect(settings_over_completion.model.completionDialogOpen);

    const closed_settings = core.update(settings_over_completion.model, .escape_pressed);
    try std.testing.expect(!closed_settings.model.settingsWindowOpen);
    try std.testing.expect(closed_settings.model.completionDialogOpen);
    try std.testing.expectEqual(@as(i64, 7), closed_settings.model.completionTaskId);
    try std.testing.expectEqual(@as(i64, 11), closed_settings.model.completionSessionId);

    const accepted_default = core.update(closed_settings.model, .escape_pressed);
    try std.testing.expect(!accepted_default.model.completionDialogOpen);
    try std.testing.expectEqual(@as(i64, 0), accepted_default.model.completionTaskId);
    try std.testing.expectEqual(@as(i64, 0), accepted_default.model.completionSessionId);

    const acknowledgement = core.rt.frameCreate(core.Model, seed.*);
    acknowledgement.loadState = .ready;
    acknowledgement.breakAcknowledgementOpen = true;
    acknowledgement.completionSessionId = 19;
    const settings_over_ack = core.update(acknowledgement, .open_settings);
    const closed_ack_settings = core.update(settings_over_ack.model, .escape_pressed);
    try std.testing.expect(!closed_ack_settings.model.settingsWindowOpen);
    try std.testing.expect(closed_ack_settings.model.breakAcknowledgementOpen);
    try std.testing.expectEqual(@as(i64, 19), closed_ack_settings.model.completionSessionId);

    const active = core.rt.frameCreate(core.Model, seed.*);
    active.loadState = .ready;
    active.settingsWindowOpen = true;
    active.activeSession = core.rt.frameCreate(core.DbSession, .{
        .id = 23,
        .taskId = 0,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 1_000,
        .endsMs = 1_501_000,
        .remainingMs = 1_500_000,
        .plannedMs = 1_500_000,
        .focusedMs = 0,
        .endedMs = 0,
    });
    const requested_end = core.update(active, .request_end_focus);
    try std.testing.expect(requested_end.model.settingsWindowOpen);
    try std.testing.expect(requested_end.model.endDialogOpen);
    const dismissed_end = core.update(requested_end.model, .escape_pressed);
    try std.testing.expect(dismissed_end.model.settingsWindowOpen);
    try std.testing.expect(!dismissed_end.model.endDialogOpen);
}

test "completion followups do not block tray routes" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.completionDialogOpen = true;
    model.completionTaskId = 3;
    model.completionSessionId = 8;

    var scratch: App.StatusItemScratch = .{};
    const state = modelStatusItem(model, &scratch);
    var quick_enabled = false;
    var settings_enabled = false;
    for (state.items) |item| {
        if (item.separator) continue;
        if (item.id == 30) quick_enabled = item.enabled;
        if (item.id == 32) settings_enabled = item.enabled;
    }
    try std.testing.expect(quick_enabled);
    try std.testing.expect(settings_enabled);
}

test "break cadence chooses a long break after each fourth focus" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const stats = core.rt.frameCreate(core.DbStats, model.stats.*);
    model.stats = stats;
    stats.todayCompletedSessions = 3;
    try std.testing.expectEqual(@as(i64, 5), core.nextBreakMinutes(model));
    const short_break = core.update(model, .start_break);
    try std.testing.expectEqual(core.PendingKind.timer_start, short_break.model.pendingKind);
    try std.testing.expectEqual(core.SessionMode.short, short_break.model.pendingMode);
    try std.testing.expectEqual(@as(i64, 5), short_break.model.pendingDurationMinutes);

    stats.todayCompletedSessions = 4;
    try std.testing.expectEqual(@as(i64, 15), core.nextBreakMinutes(model));
    const long_break = core.update(model, .start_break);
    try std.testing.expectEqual(core.PendingKind.timer_start, long_break.model.pendingKind);
    try std.testing.expectEqual(core.SessionMode.long, long_break.model.pendingMode);
    try std.testing.expectEqual(@as(i64, 15), long_break.model.pendingDurationMinutes);
}

test "ledger badge counts the same completed focus and break blocks as history" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.nowMs = 700_000_000;

    const focus = core.rt.frameCreate(core.DbSession, .{
        .id = 1,
        .taskId = 0,
        .mode = .focus,
        .state = .completed,
        .completionReason = .natural,
        .startedMs = 1_000,
        .endsMs = 0,
        .remainingMs = 0,
        .plannedMs = 1_500_000,
        .focusedMs = 1_500_000,
        .endedMs = 1_501_000,
    });
    const short_break = core.rt.frameCreate(core.DbSession, .{
        .id = 2,
        .taskId = 0,
        .mode = .short,
        .state = .completed,
        .completionReason = .natural,
        .startedMs = 2_000_000,
        .endsMs = 0,
        .remainingMs = 0,
        .plannedMs = 300_000,
        .focusedMs = 300_000,
        .endedMs = 2_300_000,
    });
    const sessions = core.rt.frameAlloc(*const core.DbSession, 2);
    sessions[0] = focus;
    sessions[1] = short_break;

    model.recentSessions = sessions[0..1];
    try std.testing.expectEqualStrings("1 recent block", core.weekSessionText(model));

    model.recentSessions = sessions;
    try std.testing.expectEqualStrings("2 recent blocks", core.weekSessionText(model));
    try std.testing.expectEqual(@as(usize, 2), core.historySessions(model).len);
}

test "fatal load paths clear stale break acknowledgements" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const load_error_model = core.rt.frameCreate(core.Model, seed.*);
    load_error_model.breakAcknowledgementOpen = true;
    load_error_model.completionSessionId = 21;
    const load_error = core.update(load_error_model, .{ .db_err = "sqlite_failure" });
    try std.testing.expectEqual(core.LoadState.fatal, load_error.model.loadState);
    try std.testing.expect(!load_error.model.breakAcknowledgementOpen);
    try std.testing.expectEqual(@as(i64, 0), load_error.model.completionSessionId);

    const decode_error_model = core.rt.frameCreate(core.Model, seed.*);
    decode_error_model.breakAcknowledgementOpen = true;
    decode_error_model.completionSessionId = 34;
    const decode_error = core.update(decode_error_model, .{ .db_ok = "invalid-snapshot" });
    try std.testing.expectEqual(core.LoadState.fatal, decode_error.model.loadState);
    try std.testing.expect(!decode_error.model.breakAcknowledgementOpen);
    try std.testing.expectEqual(@as(i64, 0), decode_error.model.completionSessionId);
}

fn putTestLe(buffer: []u8, offset: usize, input: u64, byte_count: usize) void {
    var value = input;
    for (0..byte_count) |index| {
        buffer[offset + index] = @truncate(value);
        value >>= 8;
    }
}

fn testMutationPrefix(buffer: []u8, revision: u64, now_ms: u64) void {
    @memcpy(buffer[0..4], "FCM1");
    putTestLe(buffer, 4, 1, 4);
    putTestLe(buffer, 8, revision, 8);
    putTestLe(buffer, 16, now_ms, 8);
}

test "manual completion is recorded before the optional task decision" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/manual-completion-data",
        .{tmp.sub_path[0..]},
    );
    var database = try sqlite.SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer database.deinit();
    try database.startModule(.{ .platform_name = "macos" });

    const title = "Write the launch brief";
    var create_payload: [32 + title.len]u8 = undefined;
    testMutationPrefix(&create_payload, 0, 1_000);
    putTestLe(&create_payload, 24, 25, 4);
    putTestLe(&create_payload, 28, title.len, 4);
    @memcpy(create_payload[32..], title);
    database.freeResponse(try database.handleRequest(sqlite.task_create_command, &create_payload));

    var start_payload: [41]u8 = undefined;
    testMutationPrefix(&start_payload, 1, 2_000);
    putTestLe(&start_payload, 24, 1, 8);
    start_payload[32] = 0; // focus
    putTestLe(&start_payload, 33, 1_500_000, 8);
    database.freeResponse(try database.handleRequest(sqlite.timer_start_command, &start_payload));

    var pause_payload: [32]u8 = undefined;
    testMutationPrefix(&pause_payload, 2, 3_000);
    putTestLe(&pause_payload, 24, 1, 8);
    database.freeResponse(try database.handleRequest(sqlite.timer_pause_command, &pause_payload));

    var complete_payload: [33]u8 = undefined;
    testMutationPrefix(&complete_payload, 3, 4_000);
    putTestLe(&complete_payload, 24, 1, 8);
    complete_payload[32] = 1; // manual
    const completed_snapshot = try database.handleRequest(sqlite.timer_complete_command, &complete_payload);
    defer database.freeResponse(completed_snapshot);

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.revision = 3;
    model.nowMs = 3_000;
    model.selectedTaskId = 1;
    model.actionTaskId = 1;
    model.endDialogOpen = true;
    model.dialogSurface = .main;
    const task = core.rt.frameCreate(core.DbTask, .{
        .id = 1,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 1_000,
        .updatedMs = 1_000,
        .completedMs = 0,
        .title = title,
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = task;
    model.tasks = tasks;
    model.activeSession = core.rt.frameCreate(core.DbSession, .{
        .id = 1,
        .taskId = 1,
        .mode = .focus,
        .state = .paused,
        .completionReason = .none,
        .startedMs = 2_000,
        .endsMs = 0,
        .remainingMs = 1_499_000,
        .plannedMs = 1_500_000,
        .focusedMs = 1_000,
        .endedMs = 0,
    });

    const finishing = core.update(model, .finish_focus_now);
    try std.testing.expectEqual(core.PendingKind.timer_complete_manual, finishing.model.pendingKind);
    try std.testing.expect(!finishing.model.endDialogOpen);
    const requested = core.update(finishing.model, .{ .intent_now = 4_000 });
    const committed = core.update(requested.model, .{ .db_ok = completed_snapshot });
    try std.testing.expect(committed.model.activeSession == null);
    try std.testing.expect(committed.model.completionDialogOpen);
    try std.testing.expectEqual(@as(i64, 1), committed.model.completionTaskId);
    try std.testing.expectEqual(@as(i64, 1), committed.model.completionSessionId);
    try std.testing.expectEqual(core.SessionViewState.complete, core.sessionState(committed.model));

    // Timer callbacks queued before the commit cannot undo the record. The
    // confirmation is deliberately non-modal: Ledger remains reachable and
    // Escape accepts the safe default of leaving the task open.
    const ticked = core.update(committed.model, .{ .tick = 4_250 });
    const due = core.update(ticked.model, .{ .focus_due = 5_000 });
    const ledger = core.update(due.model, .ledger_command);
    try std.testing.expectEqual(core.Section.ledger, ledger.model.section);
    try std.testing.expect(ledger.model.completionDialogOpen);

    const escaped = core.update(ledger.model, .escape_pressed);
    try std.testing.expect(!escaped.model.completionDialogOpen);
    try std.testing.expectEqual(@as(i64, 0), escaped.model.completionTaskId);
    try std.testing.expectEqual(@as(i64, 0), escaped.model.completionSessionId);
    try std.testing.expectEqual(core.SessionViewState.idle, core.sessionState(escaped.model));
    try std.testing.expectEqual(core.TaskState.open, escaped.model.tasks[0].state);
}

test "block length is chosen locally and only start commits it" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const task = core.rt.frameCreate(core.DbTask, .{
        .id = 4,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 10,
        .updatedMs = 10,
        .completedMs = 0,
        .title = "Draft the release note",
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = task;
    model.tasks = tasks;
    model.selectedTaskId = 4;

    // Adjusting the next block writes nothing: no pending mutation, no
    // command, and the persisted default is untouched.
    const longer = core.update(model, .lengthen_focus);
    try std.testing.expectEqual(@as(usize, 0), longer.cmd.len);
    try std.testing.expectEqual(core.PendingKind.load, longer.model.pendingKind);
    try std.testing.expect(!longer.model.saving);
    try std.testing.expectEqual(@as(i64, 30), core.focusLengthMinutes(longer.model));
    try std.testing.expectEqual(@as(i64, 25), core.settingsFocusMinutes(longer.model));

    const preset = core.update(longer.model, .use_duration_90);
    try std.testing.expectEqual(@as(i64, 90), core.focusLengthMinutes(preset.model));
    try std.testing.expectEqual(@as(i64, 25), core.settingsFocusMinutes(preset.model));

    // Only the start carries the chosen length into an authoritative write.
    const started = core.update(preset.model, .start_focus);
    try std.testing.expectEqual(core.PendingKind.timer_start, started.model.pendingKind);
    try std.testing.expectEqual(@as(i64, 90), started.model.pendingDurationMinutes);
}

test "block length clamps at both ends of the protocol range" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;

    var shortest = core.update(model, .shorten_focus);
    var guard: usize = 0;
    while (core.canShortenFocus(shortest.model) and guard < 64) : (guard += 1) {
        shortest = core.update(shortest.model, .shorten_focus);
    }
    try std.testing.expectEqual(@as(i64, 5), core.focusLengthMinutes(shortest.model));
    try std.testing.expect(!core.canShortenFocus(shortest.model));
    // A press at the floor is inert rather than out of range.
    const floored = core.update(shortest.model, .shorten_focus);
    try std.testing.expectEqual(@as(i64, 5), core.focusLengthMinutes(floored.model));

    var longest = core.update(model, .lengthen_focus);
    guard = 0;
    while (core.canLengthenFocus(longest.model) and guard < 64) : (guard += 1) {
        longest = core.update(longest.model, .lengthen_focus);
    }
    try std.testing.expectEqual(@as(i64, 180), core.focusLengthMinutes(longest.model));
    try std.testing.expect(!core.canLengthenFocus(longest.model));
    const capped = core.update(longest.model, .lengthen_focus);
    try std.testing.expectEqual(@as(i64, 180), core.focusLengthMinutes(capped.model));
}

test "settings steppers commit clamped defaults through the write slot" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;

    const focus_up = core.update(model, .default_focus_up);
    try std.testing.expectEqual(core.PendingKind.settings, focus_up.model.pendingKind);
    try std.testing.expectEqual(@as(i64, 30), focus_up.model.pendingSettings.focusMinutes);
    try std.testing.expect(focus_up.cmd.len > 0);

    const goal_down = core.update(model, .daily_goal_down);
    try std.testing.expectEqual(@as(i64, 105), goal_down.model.pendingSettings.dailyGoalMinutes);

    const short_up = core.update(model, .short_break_up);
    try std.testing.expectEqual(@as(i64, 6), short_up.model.pendingSettings.shortBreakMinutes);

    const long_down = core.update(model, .long_break_down);
    try std.testing.expectEqual(@as(i64, 10), long_down.model.pendingSettings.longBreakMinutes);

    // A stepper already resting on its bound neither writes nor spins.
    const floor_settings = core.rt.frameCreate(core.DbSettings, model.settings.*);
    floor_settings.shortBreakMinutes = 1;
    model.settings = floor_settings;
    const held = core.update(model, .short_break_down);
    try std.testing.expectEqual(@as(usize, 0), held.cmd.len);
    try std.testing.expect(!held.model.saving);
}

test "the task a block is running against is owned by the transport" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const focused = core.rt.frameCreate(core.DbTask, .{
        .id = 7,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 10,
        .updatedMs = 10,
        .completedMs = 0,
        .title = "Ship the migration",
    });
    const other = core.rt.frameCreate(core.DbTask, .{
        .id = 8,
        .state = .open,
        .sortOrder = 1,
        .estimateMinutes = 25,
        .createdMs = 11,
        .updatedMs = 11,
        .completedMs = 0,
        .title = "Answer the review thread",
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 2);
    tasks[0] = focused;
    tasks[1] = other;
    model.tasks = tasks;
    model.selectedTaskId = 7;
    model.actionTaskId = 7;
    model.activeSession = core.rt.frameCreate(core.DbSession, .{
        .id = 31,
        .taskId = 7,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 1_000,
        .endsMs = 1_501_000,
        .remainingMs = 1_500_000,
        .plannedMs = 1_500_000,
        .focusedMs = 0,
        .endedMs = 0,
    });

    try std.testing.expectEqual(@as(i64, 7), core.activeFocusTaskId(model));
    try std.testing.expect(core.focusing(model));

    const completing = core.update(model, .{ .toggle_task = 7 });
    try std.testing.expectEqual(@as(usize, 0), completing.cmd.len);
    try std.testing.expectEqual(core.PendingKind.load, completing.model.pendingKind);

    const archiving = core.update(model, .{ .delete_task = 7 });
    try std.testing.expectEqual(@as(usize, 0), archiving.cmd.len);
    try std.testing.expectEqual(core.PendingKind.load, archiving.model.pendingKind);

    const menu = core.update(model, .{ .toggle_task_actions = 7 });
    try std.testing.expectEqual(@as(i64, -1), menu.model.taskActionsTaskId);

    // Every other row keeps working, so an interruption can still be cleared
    // or captured without breaking the block.
    const other_menu = core.update(model, .{ .toggle_task_actions = 8 });
    try std.testing.expectEqual(@as(i64, 8), other_menu.model.taskActionsTaskId);

    const other_complete = core.update(model, .{ .toggle_task = 8 });
    try std.testing.expectEqual(core.PendingKind.task_state, other_complete.model.pendingKind);
    try std.testing.expectEqual(core.TaskState.completed, other_complete.model.pendingTaskState);
}

test "window control insets never open a gutter wider than the titlebar" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);

    const leading = core.update(model, .{ .chrome_changed = .{
        .insets = .{ .top = 52, .right = 0, .bottom = 0, .left = 0 },
        .buttons = .{ .x = 20, .y = 0, .width = 54, .height = 16 },
        .tabsProjected = false,
    } });
    try std.testing.expectEqual(@as(i64, 86), leading.model.chromeLeading);

    // Trailing window controls (or an unsettled inset) must not translate
    // into a gutter that pushes the titlebar off its own window.
    const trailing = core.update(model, .{ .chrome_changed = .{
        .insets = .{ .top = 52, .right = 0, .bottom = 0, .left = 0 },
        .buttons = .{ .x = 1_140, .y = 0, .width = 54, .height = 16 },
        .tabsProjected = false,
    } });
    try std.testing.expectEqual(@as(i64, 70), trailing.model.chromeLeading);
}

test "today's panel states the day without contradicting the ledger" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const stats = core.rt.frameCreate(core.DbStats, model.stats.*);
    stats.todayFocusMs = 75 * 60_000;
    stats.todayCompletedSessions = 3;
    const week = core.rt.frameAlloc(*const core.DbDayFocus, 7);
    const zero = core.rt.frameCreate(core.DbDayFocus, .{ .milliseconds = 0 });
    const day = core.rt.frameCreate(core.DbDayFocus, .{ .milliseconds = 50 * 60_000 });
    const best = core.rt.frameCreate(core.DbDayFocus, .{ .milliseconds = 90 * 60_000 });
    const today = core.rt.frameCreate(core.DbDayFocus, .{ .milliseconds = 75 * 60_000 });
    week[0] = zero;
    week[1] = zero;
    week[2] = zero;
    week[3] = zero;
    week[4] = best;
    week[5] = day;
    week[6] = today;
    stats.weekFocusMs = week;
    model.stats = stats;

    try std.testing.expectEqualStrings("1 h 15 min", core.todayFocusText(model));
    try std.testing.expectEqual(@as(i64, 3), core.todayBlockCount(model));
    try std.testing.expectEqualStrings("45 min to go", core.todayGoalRemainingText(model));
    try std.testing.expect(!core.todayGoalReached(model));
    try std.testing.expectEqual(@as(i64, 3), core.weekActiveDays(model));
    try std.testing.expectEqualStrings("1 h 11 min", core.weekAverageText(model));
    try std.testing.expectEqualStrings("1 h 30 min", core.weekBestText(model));

    // A day that has not started yet states zero rather than borrowing from
    // the days around it. The panel carries no streak, score, or grade.
    today.milliseconds = 0;
    stats.todayFocusMs = 0;
    stats.todayCompletedSessions = 0;
    try std.testing.expectEqual(@as(i64, 2), core.weekActiveDays(model));
    try std.testing.expectEqual(@as(i64, 0), core.todayBlockCount(model));
    try std.testing.expectEqualStrings("0 min", core.todayFocusText(model));
    try std.testing.expectEqualStrings("2 h to go", core.todayGoalRemainingText(model));

    stats.todayFocusMs = 200 * 60_000;
    try std.testing.expect(core.todayGoalReached(model));
    try std.testing.expectEqualStrings("Daily goal reached", core.todayGoalRemainingText(model));
}

test "an unclaimed space bar works the transport and never conjures a block" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    const task = core.rt.frameCreate(core.DbTask, .{
        .id = 5,
        .state = .open,
        .sortOrder = 0,
        .estimateMinutes = 25,
        .createdMs = 10,
        .updatedMs = 10,
        .completedMs = 0,
        .title = "Trim the migration script",
    });
    const tasks = core.rt.frameAlloc(*const core.DbTask, 1);
    tasks[0] = task;
    model.tasks = tasks;
    model.selectedTaskId = 5;

    const bare_space = core.keyMsg(.{
        .key = "space",
        .shift = false,
        .control = false,
        .alt = false,
        .super = false,
    });
    try std.testing.expect(bare_space != null);

    // Idle: the shortcut that starts a block is deliberately the explicit
    // one. A stray press on empty canvas must not commit focus time.
    const idle = core.update(model, .space_transport);
    try std.testing.expectEqual(@as(usize, 0), idle.cmd.len);
    try std.testing.expectEqual(core.PendingKind.load, idle.model.pendingKind);

    const running = core.rt.frameCreate(core.DbSession, .{
        .id = 44,
        .taskId = 5,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 1_000,
        .endsMs = 1_501_000,
        .remainingMs = 1_500_000,
        .plannedMs = 1_500_000,
        .focusedMs = 0,
        .endedMs = 0,
    });
    model.activeSession = running;
    const paused = core.update(model, .space_transport);
    try std.testing.expectEqual(core.PendingKind.timer_pause, paused.model.pendingKind);
    try std.testing.expect(paused.cmd.len > 0);

    running.state = .paused;
    const resumed = core.update(model, .space_transport);
    try std.testing.expectEqual(core.PendingKind.timer_resume, resumed.model.pendingKind);

    // Modified space keeps belonging to the platform.
    try std.testing.expect(core.keyMsg(.{
        .key = "space",
        .shift = false,
        .control = false,
        .alt = false,
        .super = true,
    }) == null);
}

test "a break never consumes the length chosen for the next focus block" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;

    // Choose 45 for the next focus block, then resolve a BREAK.
    var chosen = core.update(model, .use_duration_50);
    chosen = core.update(chosen.model, .shorten_focus);
    try std.testing.expectEqual(@as(i64, 45), core.focusLengthMinutes(chosen.model));

    var snapshot_buffer: [256]u8 = undefined;
    const snapshot = testEmptySnapshot(&snapshot_buffer, 25);

    const resolving = core.rt.frameCreate(core.Model, chosen.model.*);
    resolving.pendingKind = .timer_complete_manual;
    resolving.pendingMode = .short;
    const after_break = core.update(resolving, .{ .db_ok = snapshot });
    try std.testing.expectEqual(core.LoadState.ready, after_break.model.loadState);
    try std.testing.expectEqual(@as(i64, 45), core.focusLengthMinutes(after_break.model));

    // Resolving the focus block it was chosen for does return to the default.
    const focus_resolving = core.rt.frameCreate(core.Model, chosen.model.*);
    focus_resolving.pendingKind = .timer_complete_manual;
    focus_resolving.pendingMode = .focus;
    const after_focus = core.update(focus_resolving, .{ .db_ok = snapshot });
    try std.testing.expectEqual(@as(i64, 25), core.focusLengthMinutes(after_focus.model));
}

test "a deadline recovered inside a task write still reaches the completion review" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;
    model.saving = true;
    // The rail composes tasks mid-block, so a create can land on the exact
    // response where SQLite recovered the expired session for it.
    model.pendingKind = .task_create;
    model.pendingTitle = "Captured while the block ended";
    model.activeSession = core.rt.frameCreate(core.DbSession, .{
        .id = 9,
        .taskId = 3,
        .mode = .focus,
        .state = .running,
        .completionReason = .none,
        .startedMs = 1_000,
        .endsMs = 2_000,
        .remainingMs = 1_000,
        .plannedMs = 1_000,
        .focusedMs = 0,
        .endedMs = 0,
    });

    var buffer: [512]u8 = undefined;
    const snapshot = testRecoveredSnapshot(&buffer);
    const recovered = core.update(model, .{ .db_ok = snapshot });

    try std.testing.expectEqual(core.LoadState.ready, recovered.model.loadState);
    try std.testing.expect(recovered.model.activeSession == null);
    try std.testing.expectEqual(core.SessionViewState.complete, core.sessionState(recovered.model));
    try std.testing.expect(recovered.model.completionDialogOpen);
    try std.testing.expectEqual(@as(i64, 3), recovered.model.completionTaskId);
    try std.testing.expectEqual(@as(i64, 9), recovered.model.completionSessionId);
    try std.testing.expect(recovered.model.quickWindowOpen);
    try std.testing.expect(recovered.cmd.len > 0);
    // The create's own follow-up still ran: the composer is empty again.
    try std.testing.expectEqual(@as(usize, 0), recovered.model.taskDraftEditor.text.len);
}

test "an unrelated preference commit leaves the chosen block length alone" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;

    const chosen = core.update(model, .use_duration_90);
    try std.testing.expectEqual(@as(i64, 90), core.focusLengthMinutes(chosen.model));

    var buffer: [256]u8 = undefined;

    // Toggling the sound commits settings without touching the focus default.
    const sound_commit = core.rt.frameCreate(core.Model, chosen.model.*);
    sound_commit.pendingKind = .settings;
    const unchanged = core.update(sound_commit, .{ .db_ok = testEmptySnapshot(&buffer, 25) });
    try std.testing.expectEqual(@as(i64, 90), core.focusLengthMinutes(unchanged.model));

    // Changing the focus default itself does make it authoritative again.
    const default_commit = core.rt.frameCreate(core.Model, chosen.model.*);
    default_commit.pendingKind = .settings;
    const adopted = core.update(default_commit, .{ .db_ok = testEmptySnapshot(&buffer, 45) });
    try std.testing.expectEqual(@as(i64, 45), core.focusLengthMinutes(adopted.model));
}

test "duration steppers span the validator's range and never move the wrong way" {
    core.rt.resetAll();
    defer core.rt.resetAll();

    const seed = core.initialModel().model;
    const model = core.rt.frameCreate(core.Model, seed.*);
    model.loadState = .ready;

    // Every ceiling matches what protocol.ts and the SQLite validator accept.
    const settings = core.rt.frameCreate(core.DbSettings, model.settings.*);
    settings.shortBreakMinutes = 60;
    settings.longBreakMinutes = 120;
    settings.dailyGoalMinutes = 1440;
    model.settings = settings;
    try std.testing.expectEqual(@as(usize, 0), core.update(model, .short_break_up).cmd.len);
    try std.testing.expectEqual(@as(usize, 0), core.update(model, .long_break_up).cmd.len);
    try std.testing.expectEqual(@as(usize, 0), core.update(model, .daily_goal_up).cmd.len);
    try std.testing.expectEqual(@as(i64, 59), core.update(model, .short_break_down).model.pendingSettings.shortBreakMinutes);

    // A stored value beyond a product ceiling is never shortened by the
    // control that is supposed to lengthen it.
    settings.shortBreakMinutes = 45;
    const lengthened = core.update(model, .short_break_up);
    try std.testing.expectEqual(@as(i64, 46), lengthened.model.pendingSettings.shortBreakMinutes);

    // A value below a floor recovers upward instead of being pinned there.
    settings.longBreakMinutes = 3;
    const raised = core.update(model, .long_break_up);
    try std.testing.expectEqual(@as(i64, 5), raised.model.pendingSettings.longBreakMinutes);
    try std.testing.expectEqual(@as(usize, 0), core.update(model, .long_break_down).cmd.len);
}

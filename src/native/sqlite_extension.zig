//! SQLite host service for the TypeScript core.
//!
//! The TypeScript tier never sees SQL. It sends versioned, bounded binary
//! domain commands through `Cmd.request`; every successful mutation commits
//! under `BEGIN IMMEDIATE` and returns a fresh authoritative snapshot.

const std = @import("std");
const native_sdk = @import("native_sdk");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const load_command = "focus.db.load";
pub const task_create_command = "focus.db.task.create";
pub const task_rename_command = "focus.db.task.rename";
pub const task_set_state_command = "focus.db.task.set_state";
pub const task_purge_command = "focus.db.task.purge";
pub const settings_set_command = "focus.db.settings.set";
pub const timer_start_command = "focus.db.timer.start";
pub const timer_pause_command = "focus.db.timer.pause";
pub const timer_resume_command = "focus.db.timer.resume";
pub const timer_complete_command = "focus.db.timer.complete";
pub const timer_cancel_command = "focus.db.timer.cancel";

const request_version: u32 = 1;
const snapshot_version: u32 = 2;
const max_safe_integer: u64 = 9_007_199_254_740_991;
const max_title_bytes: usize = 240;
const max_tasks: u32 = 256;
const max_recent_sessions: u32 = 14;
const max_snapshot_bytes: usize = 96 * 1024;
const sqlite_busy_timeout_ms: c_int = 250;

const Error = error{
    NotStarted,
    UnknownCommand,
    InvalidRequest,
    UnsupportedVersion,
    TrailingBytes,
    UnsafeInteger,
    InvalidTitle,
    InvalidSettings,
    InvalidTaskState,
    InvalidTimer,
    TaskLimitReached,
    TaskNotFound,
    StaleRevision,
    StaleSession,
    TimerAlreadyActive,
    SnapshotTooLarge,
    UnsupportedSchema,
    CorruptDatabase,
    SqliteFailure,
};

pub const SqliteExtension = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []u8,
    db_path: ?[:0]u8 = null,
    db: ?*c.sqlite3 = null,
    startup_error: ?anyerror = null,
    last_error: [512]u8 = @splat(0),
    last_error_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !SqliteExtension {
        return .{
            .allocator = allocator,
            .io = io,
            .data_dir = try allocator.dupe(u8, data_dir),
        };
    }

    pub fn deinit(self: *SqliteExtension) void {
        self.stopModule(.{ .platform_name = "macos" }) catch {};
        if (self.db_path) |path| self.allocator.free(path);
        self.allocator.free(self.data_dir);
        self.db_path = null;
        self.data_dir = &.{};
    }

    pub fn module(self: *SqliteExtension) native_sdk.extensions.Module {
        return .{
            .info = .{
                .id = 0x464f4355_53444231, // "FOCUSDB1"
                .name = "focus-sqlite",
                .capabilities = &.{
                    .{ .kind = .native_module },
                    .{ .kind = .filesystem },
                    .{ .kind = .custom, .name = "sqlite" },
                },
            },
            .context = self,
            .hooks = .{
                .start_fn = startHook,
                .stop_fn = stopHook,
            },
        };
    }

    fn startHook(context: *anyopaque, runtime: native_sdk.extensions.RuntimeContext) anyerror!void {
        const self: *SqliteExtension = @ptrCast(@alignCast(context));
        self.startModule(runtime) catch |err| {
            // A persistence failure must not abort Runtime before the core
            // can render its fatal/retry surface. Preserve the exact first
            // error for the boot load; a later request will retry opening.
            self.startup_error = err;
        };
    }

    fn stopHook(context: *anyopaque, runtime: native_sdk.extensions.RuntimeContext) anyerror!void {
        const self: *SqliteExtension = @ptrCast(@alignCast(context));
        try self.stopModule(runtime);
    }

    pub fn startModule(self: *SqliteExtension, runtime: native_sdk.extensions.RuntimeContext) !void {
        _ = runtime;
        if (self.db != null) return;

        try std.Io.Dir.cwd().createDirPath(self.io, self.data_dir);
        if (self.db_path == null) {
            self.db_path = try std.fmt.allocPrintSentinel(
                self.allocator,
                "{s}{c}focus.sqlite3",
                .{ self.data_dir, native_sdk.app_dirs.platformSeparator(native_sdk.app_dirs.currentPlatform()) },
                0,
            );
        }

        var opened: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        const rc = c.sqlite3_open_v2(self.db_path.?.ptr, &opened, flags, null);
        if (rc != c.SQLITE_OK or opened == null) {
            if (opened) |db| {
                self.captureSqliteError(db, "open");
                _ = c.sqlite3_close_v2(db);
            } else {
                self.setError("sqlite:open_failed");
            }
            return error.SqliteFailure;
        }
        self.db = opened;
        errdefer self.closeDatabase();

        _ = c.sqlite3_extended_result_codes(self.db.?, 1);
        if (c.sqlite3_busy_timeout(self.db.?, sqlite_busy_timeout_ms) != c.SQLITE_OK) {
            return self.sqliteFailure("busy_timeout");
        }
        try self.exec(
            \\PRAGMA foreign_keys=ON;
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA synchronous=FULL;
            \\PRAGMA trusted_schema=OFF;
            \\PRAGMA wal_autocheckpoint=1000;
            \\PRAGMA temp_store=MEMORY;
        );
        try self.migrate();
        try self.quickCheck();
        try self.foreignKeyCheck();
        try self.validateSchema();
        self.startup_error = null;
    }

    pub fn stopModule(self: *SqliteExtension, runtime: native_sdk.extensions.RuntimeContext) !void {
        _ = runtime;
        if (self.db) |db| {
            _ = c.sqlite3_wal_checkpoint_v2(db, null, c.SQLITE_CHECKPOINT_PASSIVE, null, null);
        }
        self.closeDatabase();
    }

    fn closeDatabase(self: *SqliteExtension) void {
        if (self.db) |db| {
            const rc = c.sqlite3_close_v2(db);
            if (rc != c.SQLITE_OK) self.captureSqliteError(db, "close");
        }
        self.db = null;
    }

    pub fn handleRequest(self: *SqliteExtension, name: []const u8, payload: []const u8) ![]u8 {
        if (self.db == null) {
            if (self.startup_error) |err| {
                // Deliver the eager-start failure once. Clearing it arms
                // the next user retry to perform a real reopen/migration/
                // integrity check instead of replaying a stale error.
                self.startup_error = null;
                return err;
            }
            try self.startModule(.{ .platform_name = "host-call-retry" });
            if (self.db == null) return error.NotStarted;
        }
        if (std.mem.eql(u8, name, load_command)) return self.load(payload);
        if (std.mem.eql(u8, name, task_create_command)) return self.mutate(.task_create, payload);
        if (std.mem.eql(u8, name, task_rename_command)) return self.mutate(.task_rename, payload);
        if (std.mem.eql(u8, name, task_set_state_command)) return self.mutate(.task_set_state, payload);
        if (std.mem.eql(u8, name, task_purge_command)) return self.mutate(.task_purge, payload);
        if (std.mem.eql(u8, name, settings_set_command)) return self.mutate(.settings_set, payload);
        if (std.mem.eql(u8, name, timer_start_command)) return self.mutate(.timer_start, payload);
        if (std.mem.eql(u8, name, timer_pause_command)) return self.mutate(.timer_pause, payload);
        if (std.mem.eql(u8, name, timer_resume_command)) return self.mutate(.timer_resume, payload);
        if (std.mem.eql(u8, name, timer_complete_command)) return self.mutate(.timer_complete, payload);
        if (std.mem.eql(u8, name, timer_cancel_command)) return self.mutate(.timer_cancel, payload);
        return error.UnknownCommand;
    }

    pub fn freeResponse(self: *SqliteExtension, response: []u8) void {
        self.allocator.free(response);
    }

    pub fn errorBytes(self: *const SqliteExtension, err: anyerror) []const u8 {
        return switch (err) {
            error.NotStarted => "database_not_started",
            error.UnknownCommand => "unknown_command",
            error.InvalidRequest => "invalid_request",
            error.UnsupportedVersion => "unsupported_version",
            error.TrailingBytes => "trailing_bytes",
            error.UnsafeInteger => "unsafe_integer",
            error.InvalidTitle => "invalid_title",
            error.InvalidSettings => "invalid_settings",
            error.InvalidTaskState => "invalid_task_state",
            error.InvalidTimer => "invalid_timer",
            error.TaskLimitReached => "task_limit_reached",
            error.TaskNotFound => "task_not_found",
            error.StaleRevision => "stale_revision",
            error.StaleSession => "stale_session",
            error.TimerAlreadyActive => "timer_already_active",
            error.SnapshotTooLarge => "snapshot_too_large",
            error.UnsupportedSchema => "unsupported_schema",
            error.CorruptDatabase => "corrupt_database",
            error.SqliteFailure => if (self.last_error_len > 0) self.last_error[0..self.last_error_len] else "sqlite_failure",
            error.OutOfMemory => "out_of_memory",
            else => "database_failure",
        };
    }

    const Mutation = enum {
        task_create,
        task_rename,
        task_set_state,
        task_purge,
        settings_set,
        timer_start,
        timer_pause,
        timer_resume,
        timer_complete,
        timer_cancel,
    };

    fn load(self: *SqliteExtension, payload: []const u8) ![]u8 {
        var reader = Reader.init(payload);
        try reader.expectMagic("FCL1");
        if (try reader.readU32() != request_version) return error.UnsupportedVersion;
        const now_ms = try reader.safeU64();
        try reader.finish();

        try self.beginImmediate();
        var committed = false;
        defer if (!committed) self.rollback();
        if (try self.recoverTimerForClock(now_ms)) try self.incrementRevision();
        const response = try self.snapshot(now_ms);
        errdefer self.allocator.free(response);
        try self.commit();
        committed = true;
        return response;
    }

    fn mutate(self: *SqliteExtension, kind: Mutation, payload: []const u8) ![]u8 {
        var reader = Reader.init(payload);
        try reader.expectMagic("FCM1");
        if (try reader.readU32() != request_version) return error.UnsupportedVersion;
        const expected_revision = try reader.safeU64();
        const now_ms = try reader.safeU64();

        try self.beginImmediate();
        var committed = false;
        defer if (!committed) self.rollback();

        if (try self.currentRevision() != expected_revision) return error.StaleRevision;
        // `timer.complete` owns the natural-vs-manual reason carried by
        // its payload. Every other mutation performs crash/wake recovery
        // before applying its own transition. Clock rollback is always
        // fail-safe: a running timer becomes paused before any mutation.
        if (kind == .timer_complete) {
            _ = try self.pauseOnClockRollback(now_ms);
        } else {
            _ = try self.recoverTimerForClock(now_ms);
        }

        switch (kind) {
            .task_create => try self.createTask(&reader, now_ms),
            .task_rename => try self.renameTask(&reader, now_ms),
            .task_set_state => try self.setTaskState(&reader, now_ms),
            .task_purge => try self.purgeTask(&reader),
            .settings_set => try self.setSettings(&reader),
            .timer_start => try self.startTimer(&reader, now_ms),
            .timer_pause => try self.pauseTimer(&reader, now_ms),
            .timer_resume => try self.resumeTimer(&reader, now_ms),
            .timer_complete => try self.completeTimer(&reader, now_ms),
            .timer_cancel => try self.finishTimer(&reader, now_ms, .cancelled),
        }
        try reader.finish();
        try self.incrementRevision();
        // Encode while the write transaction is still open. A response
        // allocation/size failure therefore rolls the mutation back, and
        // no second process can interleave a newer revision between commit
        // and the authoritative snapshot returned to the TypeScript core.
        const response = try self.snapshot(now_ms);
        errdefer self.allocator.free(response);
        try self.commit();
        committed = true;
        return response;
    }

    fn createTask(self: *SqliteExtension, reader: *Reader, now_ms: u64) !void {
        const estimate_min = try reader.readU32();
        const title = try reader.taskTitle();
        if (estimate_min == 0 or estimate_min > 480) return error.InvalidRequest;
        if (try self.scalarU64("SELECT COUNT(*) FROM tasks;") >= max_tasks) return error.TaskLimitReached;

        const id = try self.nextTaskId();
        const statement = try self.prepare(
            \\INSERT INTO tasks(id,title,state,sort_order,estimate_min,created_ms,updated_ms,completed_ms)
            \\VALUES(?1,?2,0,(SELECT COALESCE(MAX(sort_order),-1)+1 FROM tasks),?3,?4,?4,0);
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, id);
        try self.bindText(statement, 2, title);
        try self.bindU32(statement, 3, estimate_min);
        try self.bindU64(statement, 4, now_ms);
        try self.stepDone(statement);

        const bump = try self.prepare("UPDATE app_meta SET next_task_id=?1 WHERE id=1;");
        defer _ = c.sqlite3_finalize(bump);
        try self.bindU64(bump, 1, id + 1);
        try self.stepDone(bump);
    }

    fn renameTask(self: *SqliteExtension, reader: *Reader, now_ms: u64) !void {
        const id = try reader.safeU64();
        const title = try reader.taskTitle();
        const statement = try self.prepare(
            "UPDATE tasks SET title=?1,updated_ms=MAX(?2,created_ms) WHERE id=?3;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindText(statement, 1, title);
        try self.bindU64(statement, 2, now_ms);
        try self.bindU64(statement, 3, id);
        try self.stepDone(statement);
        if (c.sqlite3_changes(self.db.?) != 1) return error.TaskNotFound;
    }

    fn setTaskState(self: *SqliteExtension, reader: *Reader, now_ms: u64) !void {
        const id = try reader.safeU64();
        const state = try reader.readU8();
        if (state > 2) return error.InvalidTaskState;
        const statement = try self.prepare(
            \\UPDATE tasks SET state=?1,updated_ms=MAX(?2,created_ms),
            \\completed_ms=CASE WHEN ?1=1 AND state!=1 THEN MAX(?2,created_ms)
            \\WHEN ?1=0 THEN 0 ELSE completed_ms END
            \\WHERE id=?3;
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU32(statement, 1, state);
        try self.bindU64(statement, 2, now_ms);
        try self.bindU64(statement, 3, id);
        try self.stepDone(statement);
        if (c.sqlite3_changes(self.db.?) != 1) return error.TaskNotFound;
    }

    fn purgeTask(self: *SqliteExtension, reader: *Reader) !void {
        const id = try reader.safeU64();
        const state = state: {
            const statement = try self.prepare("SELECT state FROM tasks WHERE id=?1;");
            defer _ = c.sqlite3_finalize(statement);
            try self.bindU64(statement, 1, id);
            const rc = c.sqlite3_step(statement);
            if (rc == c.SQLITE_DONE) return error.TaskNotFound;
            if (rc != c.SQLITE_ROW) return self.sqliteFailure("purge_lookup");
            break :state try self.columnU32(statement, 0);
        };
        if (state > 2) return error.CorruptDatabase;
        if (state != 2) return error.InvalidTaskState;

        const statement = try self.prepare("DELETE FROM tasks WHERE id=?1 AND state=2;");
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, id);
        try self.stepDone(statement);
        if (c.sqlite3_changes(self.db.?) != 1) return error.CorruptDatabase;
    }

    fn setSettings(self: *SqliteExtension, reader: *Reader) !void {
        const focus_min = try reader.readU32();
        const short_break_min = try reader.readU32();
        const long_break_min = try reader.readU32();
        const daily_goal_min = try reader.readU32();
        const sound_enabled = try reader.readU8();
        if (focus_min == 0 or focus_min > 180 or
            short_break_min == 0 or short_break_min > 60 or
            long_break_min == 0 or long_break_min > 120 or
            daily_goal_min == 0 or daily_goal_min > 1440 or
            sound_enabled > 1)
        {
            return error.InvalidSettings;
        }
        const statement = try self.prepare(
            \\UPDATE settings SET focus_min=?1,short_break_min=?2,long_break_min=?3,
            \\daily_goal_min=?4,sound_enabled=?5 WHERE id=1;
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU32(statement, 1, focus_min);
        try self.bindU32(statement, 2, short_break_min);
        try self.bindU32(statement, 3, long_break_min);
        try self.bindU32(statement, 4, daily_goal_min);
        try self.bindU32(statement, 5, sound_enabled);
        try self.stepDone(statement);
    }

    fn startTimer(self: *SqliteExtension, reader: *Reader, now_ms: u64) !void {
        const task_id = try reader.safeU64();
        const mode = try reader.readU8();
        const planned_ms = try reader.safeU64();
        if (mode > 2 or planned_ms < 1_000 or planned_ms > 86_400_000) return error.InvalidTimer;
        if (now_ms > max_safe_integer - planned_ms) return error.UnsafeInteger;
        if ((try self.liveTimer()) != null) return error.TimerAlreadyActive;
        if (task_id != 0 and !try self.openTaskExists(task_id)) return error.TaskNotFound;

        const statement = try self.prepare(
            \\INSERT INTO focus_sessions(task_id,mode,state,completion_reason,live_slot,started_ms,last_transition_ms,ends_ms,remaining_ms,planned_ms,focused_ms,ended_ms)
            \\VALUES(?1,?2,0,0,1,?3,?3,?4,?5,?5,0,0);
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindOptionalTask(statement, 1, task_id);
        try self.bindU32(statement, 2, mode);
        try self.bindU64(statement, 3, now_ms);
        try self.bindU64(statement, 4, now_ms + planned_ms);
        try self.bindU64(statement, 5, planned_ms);
        try self.stepDone(statement);
    }

    fn pauseTimer(self: *SqliteExtension, reader: *Reader, now_ms: u64) !void {
        const requested_id = try reader.safeU64();
        const live = (try self.liveTimer()) orelse return error.StaleSession;
        if (live.id != requested_id) return error.StaleSession;
        if (live.state == .paused) return;
        const transition_ms = @max(now_ms, live.last_transition_ms);
        const elapsed = activeElapsed(live, transition_ms);
        const remaining = live.remaining_ms -| elapsed;
        const focused = @min(live.planned_ms, live.focused_ms + elapsed);
        const statement = try self.prepare(
            "UPDATE focus_sessions SET state=1,last_transition_ms=?1,ends_ms=0,remaining_ms=?2,focused_ms=?3 WHERE id=?4 AND state=0;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, transition_ms);
        try self.bindU64(statement, 2, remaining);
        try self.bindU64(statement, 3, focused);
        try self.bindU64(statement, 4, live.id);
        try self.stepDone(statement);
        if (c.sqlite3_changes(self.db.?) != 1) return error.StaleSession;
    }

    fn resumeTimer(self: *SqliteExtension, reader: *Reader, now_ms: u64) !void {
        const requested_id = try reader.safeU64();
        const live = (try self.liveTimer()) orelse return error.StaleSession;
        if (live.id != requested_id) return error.StaleSession;
        if (live.state == .running) return;
        // Resume deliberately rebases from the caller's current wall clock.
        // This is essential after a backward clock adjustment: using MAX
        // would silently extend the session until the old future timestamp.
        const transition_ms = now_ms;
        if (transition_ms > max_safe_integer - live.remaining_ms) return error.UnsafeInteger;
        const statement = try self.prepare(
            "UPDATE focus_sessions SET state=0,last_transition_ms=?1,ends_ms=?2 WHERE id=?3 AND state=1;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, transition_ms);
        try self.bindU64(statement, 2, transition_ms + live.remaining_ms);
        try self.bindU64(statement, 3, live.id);
        try self.stepDone(statement);
        if (c.sqlite3_changes(self.db.?) != 1) return error.StaleSession;
    }

    const TerminalState = enum(u8) { completed = 2, cancelled = 3 };

    fn completeTimer(self: *SqliteExtension, reader: *Reader, now_ms: u64) !void {
        const requested_id = try reader.safeU64();
        const reason = try reader.readU8();
        if (reason > 1) return error.InvalidTimer;
        const live = (try self.liveTimer()) orelse return error.StaleSession;
        if (live.id != requested_id) return error.StaleSession;

        // A manual click can arrive after the absolute deadline but before
        // the next tick/load recovery. It is still a natural completion and
        // must be booked at `ends_ms`, otherwise midnight crossings corrupt
        // the daily ledger.
        if (live.state == .running and live.ends_ms > 0 and live.ends_ms <= now_ms) {
            try self.finishTimerById(requested_id, now_ms, .completed, 1, true);
            return;
        }
        try self.finishTimerById(requested_id, now_ms, .completed, if (reason == 0) 1 else 2, reason == 0);
    }

    fn finishTimer(self: *SqliteExtension, reader: *Reader, now_ms: u64, terminal: TerminalState) !void {
        const requested_id = try reader.safeU64();
        try self.finishTimerById(requested_id, now_ms, terminal, 0, false);
    }

    fn finishTimerById(
        self: *SqliteExtension,
        requested_id: u64,
        now_ms: u64,
        terminal: TerminalState,
        completion_reason: u8,
        require_expired: bool,
    ) !void {
        const live = (try self.liveTimer()) orelse return error.StaleSession;
        if (live.id != requested_id) return error.StaleSession;
        if (require_expired and (live.state != .running or live.ends_ms > now_ms)) return error.InvalidTimer;
        const transition_ms = if (require_expired)
            live.ends_ms
        else
            @max(now_ms, live.last_transition_ms);
        const elapsed = if (live.state == .running) activeElapsed(live, transition_ms) else 0;
        const remaining = live.remaining_ms -| elapsed;
        const focused = if (require_expired)
            live.planned_ms
        else
            @min(live.planned_ms, live.focused_ms + elapsed);
        const stored_remaining: u64 = if (terminal == .completed) 0 else remaining;
        const statement = try self.prepare(
            \\UPDATE focus_sessions SET state=?1,completion_reason=?2,live_slot=NULL,last_transition_ms=?3,
            \\ends_ms=0,remaining_ms=?4,focused_ms=?5,ended_ms=?3 WHERE id=?6 AND state IN (0,1);
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU32(statement, 1, @intFromEnum(terminal));
        try self.bindU32(statement, 2, completion_reason);
        try self.bindU64(statement, 3, transition_ms);
        try self.bindU64(statement, 4, stored_remaining);
        try self.bindU64(statement, 5, focused);
        try self.bindU64(statement, 6, live.id);
        try self.stepDone(statement);
        if (c.sqlite3_changes(self.db.?) != 1) return error.StaleSession;
    }

    fn recoverExpiredTimer(self: *SqliteExtension, now_ms: u64) !bool {
        const statement = try self.prepare(
            \\UPDATE focus_sessions SET state=2,completion_reason=3,live_slot=NULL,
            \\last_transition_ms=ends_ms,ended_ms=ends_ms,ends_ms=0,remaining_ms=0,focused_ms=planned_ms
            \\WHERE state=0 AND ends_ms>0 AND ends_ms<=?1;
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, now_ms);
        try self.stepDone(statement);
        return c.sqlite3_changes(self.db.?) > 0;
    }

    /// Reconcile a live timer against an external wall clock. Expiration is
    /// deterministic at the stored deadline. A backward adjustment is never
    /// treated as extra focus time: the timer is atomically paused with its
    /// authoritative remaining duration intact.
    fn recoverTimerForClock(self: *SqliteExtension, now_ms: u64) !bool {
        if (try self.pauseOnClockRollback(now_ms)) return true;
        return self.recoverExpiredTimer(now_ms);
    }

    fn pauseOnClockRollback(self: *SqliteExtension, now_ms: u64) !bool {
        const live = (try self.liveTimer()) orelse return false;
        if (live.state != .running or now_ms >= live.last_transition_ms) return false;
        const statement = try self.prepare(
            \\UPDATE focus_sessions SET state=1,last_transition_ms=?1,ends_ms=0
            \\WHERE id=?2 AND state=0 AND live_slot=1;
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, now_ms);
        try self.bindU64(statement, 2, live.id);
        try self.stepDone(statement);
        if (c.sqlite3_changes(self.db.?) != 1) return error.StaleSession;
        return true;
    }

    const LiveState = enum(u8) { running = 0, paused = 1 };
    const LiveTimer = struct {
        id: u64,
        state: LiveState,
        last_transition_ms: u64,
        ends_ms: u64,
        remaining_ms: u64,
        planned_ms: u64,
        focused_ms: u64,
    };

    fn liveTimer(self: *SqliteExtension) !?LiveTimer {
        const statement = try self.prepare(
            "SELECT id,state,last_transition_ms,ends_ms,remaining_ms,planned_ms,focused_ms FROM focus_sessions WHERE live_slot=1 LIMIT 1;",
        );
        defer _ = c.sqlite3_finalize(statement);
        const rc = c.sqlite3_step(statement);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return self.sqliteFailure("live_timer");
        const raw_state = try self.columnU64(statement, 1);
        if (raw_state > 1) return error.CorruptDatabase;
        return .{
            .id = try self.columnU64(statement, 0),
            .state = @enumFromInt(@as(u8, @intCast(raw_state))),
            .last_transition_ms = try self.columnU64(statement, 2),
            .ends_ms = try self.columnU64(statement, 3),
            .remaining_ms = try self.columnU64(statement, 4),
            .planned_ms = try self.columnU64(statement, 5),
            .focused_ms = try self.columnU64(statement, 6),
        };
    }

    fn activeElapsed(live: LiveTimer, now_ms: u64) u64 {
        if (now_ms <= live.last_transition_ms) return 0;
        return @min(now_ms - live.last_transition_ms, live.remaining_ms);
    }

    fn openTaskExists(self: *SqliteExtension, id: u64) !bool {
        const statement = try self.prepare("SELECT 1 FROM tasks WHERE id=?1 AND state=0;");
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, id);
        const rc = c.sqlite3_step(statement);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return self.sqliteFailure("task_exists");
    }

    fn snapshot(self: *SqliteExtension, now_ms: u64) ![]u8 {
        var writer = Writer.init(self.allocator);
        errdefer writer.deinit();
        try writer.bytes("FCS2");
        try writer.writeU32(snapshot_version);
        try writer.writeU64(try self.currentRevision());

        const settings = try self.prepare(
            "SELECT focus_min,short_break_min,long_break_min,daily_goal_min,sound_enabled FROM settings WHERE id=1;",
        );
        defer _ = c.sqlite3_finalize(settings);
        if (c.sqlite3_step(settings) != c.SQLITE_ROW) return error.CorruptDatabase;
        const focus_min = try self.columnU32(settings, 0);
        const short_break_min = try self.columnU32(settings, 1);
        const long_break_min = try self.columnU32(settings, 2);
        const daily_goal_min = try self.columnU32(settings, 3);
        const sound_enabled = try self.columnU32(settings, 4);
        if (focus_min == 0 or focus_min > 180 or
            short_break_min == 0 or short_break_min > 60 or
            long_break_min == 0 or long_break_min > 120 or
            daily_goal_min == 0 or daily_goal_min > 1440 or
            sound_enabled > 1)
        {
            return error.CorruptDatabase;
        }
        try writer.writeU32(focus_min);
        try writer.writeU32(short_break_min);
        try writer.writeU32(long_break_min);
        try writer.writeU32(daily_goal_min);
        try writer.writeU8(@intCast(sound_enabled));

        try writer.writeU64(try self.nextTaskId());
        const task_count = try self.scalarU32("SELECT COUNT(*) FROM tasks;");
        if (task_count > max_tasks) return error.CorruptDatabase;
        try writer.writeU32(task_count);
        const tasks = try self.prepare(
            \\SELECT id,state,sort_order,estimate_min,created_ms,updated_ms,completed_ms,title
            \\FROM tasks ORDER BY sort_order ASC,id ASC;
        );
        defer _ = c.sqlite3_finalize(tasks);
        while (true) {
            const rc = c.sqlite3_step(tasks);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return self.sqliteFailure("snapshot_tasks");
            const state = try self.columnU32(tasks, 1);
            const estimate_min = try self.columnU32(tasks, 3);
            const title = try self.columnBytes(tasks, 7);
            if (state > 2 or estimate_min == 0 or estimate_min > 480 or !validTitle(title)) {
                return error.CorruptDatabase;
            }
            try writer.writeU64(try self.columnU64(tasks, 0));
            try writer.writeU8(@intCast(state));
            try writer.writeU32(try self.columnU32(tasks, 2));
            try writer.writeU32(estimate_min);
            try writer.writeU64(try self.columnU64(tasks, 4));
            try writer.writeU64(try self.columnU64(tasks, 5));
            try writer.writeU64(try self.columnU64(tasks, 6));
            try writer.lengthPrefixed(title);
        }

        const active = try self.prepare(
            \\SELECT id,task_id,mode,state,completion_reason,started_ms,ends_ms,remaining_ms,planned_ms,focused_ms,ended_ms
            \\FROM focus_sessions WHERE live_slot=1 LIMIT 1;
        );
        defer _ = c.sqlite3_finalize(active);
        const active_rc = c.sqlite3_step(active);
        if (active_rc == c.SQLITE_ROW) {
            try writer.writeU8(1);
            try self.writeSession(&writer, active);
        } else if (active_rc == c.SQLITE_DONE) {
            try writer.writeU8(0);
        } else {
            return self.sqliteFailure("snapshot_active");
        }

        const recent_count = try self.scalarU32(
            "SELECT COUNT(*) FROM (SELECT 1 FROM focus_sessions WHERE state IN (2,3) ORDER BY ended_ms DESC,id DESC LIMIT 14);",
        );
        if (recent_count > max_recent_sessions) return error.CorruptDatabase;
        try writer.writeU32(recent_count);
        const recent = try self.prepare(
            \\SELECT id,task_id,mode,state,completion_reason,started_ms,ends_ms,remaining_ms,planned_ms,focused_ms,ended_ms
            \\FROM focus_sessions WHERE state IN (2,3) ORDER BY ended_ms DESC,id DESC LIMIT 14;
        );
        defer _ = c.sqlite3_finalize(recent);
        while (true) {
            const rc = c.sqlite3_step(recent);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return self.sqliteFailure("snapshot_recent");
            try self.writeSession(&writer, recent);
        }

        try writer.writeU64(try self.todayFocusMs(now_ms));
        try writer.writeU32(try self.todaySessionCount(now_ms));
        try writer.writeU32(try self.todayTaskCount(now_ms));
        try writer.writeU32(7);
        try writer.writeU8(try self.todayWeekday(now_ms));
        var day: i32 = 6;
        while (day >= 0) : (day -= 1) try writer.writeU64(try self.focusForDayOffset(day, now_ms));

        if (writer.list.items.len > max_snapshot_bytes) return error.SnapshotTooLarge;
        return writer.toOwnedSlice();
    }

    fn writeSession(self: *SqliteExtension, writer: *Writer, statement: *c.sqlite3_stmt) !void {
        const mode = try self.columnU32(statement, 2);
        const state = try self.columnU32(statement, 3);
        const completion_reason = try self.columnU32(statement, 4);
        if (mode > 2 or state > 3 or completion_reason > 3) return error.CorruptDatabase;
        try writer.writeU64(try self.columnU64(statement, 0));
        try writer.writeU64(if (c.sqlite3_column_type(statement, 1) == c.SQLITE_NULL) 0 else try self.columnU64(statement, 1));
        try writer.writeU8(@intCast(mode));
        try writer.writeU8(@intCast(state));
        try writer.writeU8(@intCast(completion_reason));
        inline for (5..11) |index| try writer.writeU64(try self.columnU64(statement, index));
    }

    fn todayFocusMs(self: *SqliteExtension, now_ms: u64) !u64 {
        const sql =
            \\SELECT COALESCE(SUM(focused_ms),0) FROM focus_sessions
            \\WHERE mode=0 AND state=2
            \\AND date(ended_ms/1000,'unixepoch','localtime')=date(?1/1000,'unixepoch','localtime');
        ;
        return self.scalarU64At(sql, now_ms);
    }

    fn todaySessionCount(self: *SqliteExtension, now_ms: u64) !u32 {
        const sql =
            \\SELECT COUNT(*) FROM focus_sessions
            \\WHERE mode=0 AND state=2
            \\AND date(ended_ms/1000,'unixepoch','localtime')=date(?1/1000,'unixepoch','localtime');
        ;
        return self.scalarU32At(sql, now_ms);
    }

    fn todayTaskCount(self: *SqliteExtension, now_ms: u64) !u32 {
        const sql =
            \\SELECT COUNT(*) FROM tasks
            \\WHERE completed_ms>0
            \\AND date(completed_ms/1000,'unixepoch','localtime')=date(?1/1000,'unixepoch','localtime');
        ;
        return self.scalarU32At(sql, now_ms);
    }

    /// SQLite `%w` is Sunday=0. The core protocol uses Monday=0 so labels
    /// remain factual in the user's local timezone without TS date APIs.
    fn todayWeekday(self: *SqliteExtension, now_ms: u64) !u8 {
        const sunday_first = try self.scalarU32At(
            "SELECT CAST(strftime('%w',?1/1000,'unixepoch','localtime') AS INTEGER);",
            now_ms,
        );
        if (sunday_first > 6) return error.CorruptDatabase;
        return @intCast((sunday_first + 6) % 7);
    }

    fn focusForDayOffset(self: *SqliteExtension, offset: i32, now_ms: u64) !u64 {
        var modifier_buffer: [32]u8 = undefined;
        const modifier = if (offset == 0)
            "0 days"
        else
            try std.fmt.bufPrint(&modifier_buffer, "-{d} days", .{offset});
        const statement = try self.prepare(
            \\SELECT COALESCE(SUM(focused_ms),0) FROM focus_sessions
            \\WHERE mode=0 AND state=2
            \\AND date(ended_ms/1000,'unixepoch','localtime')=date(?1/1000,'unixepoch','localtime',?2);
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, now_ms);
        try self.bindText(statement, 2, modifier);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return self.sqliteFailure("stats_day");
        return self.columnU64(statement, 0);
    }

    fn migrate(self: *SqliteExtension) !void {
        const version = try self.scalarU32("PRAGMA user_version;");
        if (version > 1) return error.UnsupportedSchema;
        if (version == 1) return;

        try self.exec("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.rollback();
        try self.exec(
            \\CREATE TABLE settings(
            \\  id INTEGER PRIMARY KEY CHECK(id=1),
            \\  focus_min INTEGER NOT NULL CHECK(focus_min BETWEEN 1 AND 180),
            \\  short_break_min INTEGER NOT NULL CHECK(short_break_min BETWEEN 1 AND 60),
            \\  long_break_min INTEGER NOT NULL CHECK(long_break_min BETWEEN 1 AND 120),
            \\  daily_goal_min INTEGER NOT NULL CHECK(daily_goal_min BETWEEN 1 AND 1440),
            \\  sound_enabled INTEGER NOT NULL CHECK(sound_enabled IN (0,1))
            \\);
            \\CREATE TABLE app_meta(
            \\  id INTEGER PRIMARY KEY CHECK(id=1),
            \\  revision INTEGER NOT NULL CHECK(revision>=0),
            \\  next_task_id INTEGER NOT NULL CHECK(next_task_id>0)
            \\);
            \\CREATE TABLE tasks(
            \\  id INTEGER PRIMARY KEY,
            \\  title TEXT NOT NULL CHECK(length(CAST(title AS BLOB)) BETWEEN 1 AND 240),
            \\  state INTEGER NOT NULL CHECK(state IN (0,1,2)),
            \\  sort_order INTEGER NOT NULL CHECK(sort_order>=0),
            \\  estimate_min INTEGER NOT NULL CHECK(estimate_min BETWEEN 1 AND 480),
            \\  created_ms INTEGER NOT NULL CHECK(created_ms>=0),
            \\  updated_ms INTEGER NOT NULL CHECK(updated_ms>=0),
            \\  completed_ms INTEGER NOT NULL DEFAULT 0 CHECK(completed_ms>=0)
            \\);
            \\CREATE INDEX tasks_state_order ON tasks(state,sort_order,id);
            \\CREATE TABLE focus_sessions(
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
            \\  mode INTEGER NOT NULL CHECK(mode IN (0,1,2)),
            \\  state INTEGER NOT NULL CHECK(state IN (0,1,2,3)),
            \\  completion_reason INTEGER NOT NULL DEFAULT 0 CHECK(completion_reason IN (0,1,2,3)),
            \\  live_slot INTEGER CHECK(live_slot IS NULL OR live_slot=1),
            \\  started_ms INTEGER NOT NULL CHECK(started_ms>=0),
            \\  last_transition_ms INTEGER NOT NULL CHECK(last_transition_ms>=0),
            \\  ends_ms INTEGER NOT NULL DEFAULT 0 CHECK(ends_ms>=0),
            \\  remaining_ms INTEGER NOT NULL CHECK(remaining_ms>=0),
            \\  planned_ms INTEGER NOT NULL CHECK(planned_ms>0),
            \\  focused_ms INTEGER NOT NULL DEFAULT 0 CHECK(focused_ms>=0),
            \\  ended_ms INTEGER NOT NULL DEFAULT 0 CHECK(ended_ms>=0),
            \\  CHECK((state IN (0,1) AND live_slot=1) OR (state IN (2,3) AND live_slot IS NULL))
            \\);
            \\CREATE UNIQUE INDEX one_live_focus_session ON focus_sessions(live_slot) WHERE live_slot=1;
            \\CREATE INDEX focus_sessions_history ON focus_sessions(state,ended_ms DESC,id DESC);
            \\INSERT INTO settings VALUES(1,25,5,15,120,1);
            \\INSERT INTO app_meta VALUES(1,0,1);
            \\PRAGMA user_version=1;
        );
        try self.commit();
        committed = true;
    }

    fn quickCheck(self: *SqliteExtension) !void {
        const statement = try self.prepare("PRAGMA quick_check(1);");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return self.sqliteFailure("quick_check");
        if (!std.mem.eql(u8, try self.columnBytes(statement, 0), "ok")) return error.CorruptDatabase;
    }

    fn foreignKeyCheck(self: *SqliteExtension) !void {
        const statement = try self.prepare("PRAGMA foreign_key_check;");
        defer _ = c.sqlite3_finalize(statement);
        const rc = c.sqlite3_step(statement);
        if (rc == c.SQLITE_ROW) return error.CorruptDatabase;
        if (rc != c.SQLITE_DONE) return self.sqliteFailure("foreign_key_check");
    }

    fn validateSchema(self: *SqliteExtension) !void {
        if (try self.scalarU32("PRAGMA foreign_keys;") != 1) return error.CorruptDatabase;
        if (try self.scalarU32("PRAGMA user_version;") != 1) return error.UnsupportedSchema;

        // V1 intentionally has no programmable schema objects. A trigger can
        // make an otherwise valid mutation lie about what SQLite committed,
        // while a view broadens the executable schema surface. Internal
        // `sqlite_*` objects are owned by SQLite and are not user extensions.
        if ((self.scalarU64(
            "SELECT COUNT(*) FROM sqlite_schema WHERE type IN ('trigger','view') AND name NOT GLOB 'sqlite_*';",
        ) catch return error.CorruptDatabase) != 0) return error.CorruptDatabase;

        // Version numbers are promises, not proof. Validate the v1 shape and
        // its critical constraints so an empty but hostile/partial database
        // cannot masquerade as a supported schema.
        const required_fragments = [_]struct {
            object_type: []const u8,
            name: []const u8,
            compact_fragment: []const u8,
        }{
            .{ .object_type = "table", .name = "settings", .compact_fragment = "check(id=1)" },
            .{ .object_type = "table", .name = "settings", .compact_fragment = "check(focus_minbetween1and180)" },
            .{ .object_type = "table", .name = "settings", .compact_fragment = "check(short_break_minbetween1and60)" },
            .{ .object_type = "table", .name = "settings", .compact_fragment = "check(long_break_minbetween1and120)" },
            .{ .object_type = "table", .name = "settings", .compact_fragment = "check(daily_goal_minbetween1and1440)" },
            .{ .object_type = "table", .name = "settings", .compact_fragment = "check(sound_enabledin(0,1))" },
            .{ .object_type = "table", .name = "app_meta", .compact_fragment = "check(id=1)" },
            .{ .object_type = "table", .name = "app_meta", .compact_fragment = "check(revision>=0)" },
            .{ .object_type = "table", .name = "app_meta", .compact_fragment = "check(next_task_id>0)" },
            .{ .object_type = "table", .name = "tasks", .compact_fragment = "idintegerprimarykey" },
            .{ .object_type = "table", .name = "tasks", .compact_fragment = "check(length(cast(titleasblob))between1and240)" },
            .{ .object_type = "table", .name = "tasks", .compact_fragment = "check(statein(0,1,2))" },
            .{ .object_type = "table", .name = "tasks", .compact_fragment = "check(sort_order>=0)" },
            .{ .object_type = "table", .name = "tasks", .compact_fragment = "check(estimate_minbetween1and480)" },
            .{ .object_type = "table", .name = "focus_sessions", .compact_fragment = "idintegerprimarykeyautoincrement" },
            .{ .object_type = "table", .name = "focus_sessions", .compact_fragment = "check(modein(0,1,2))" },
            .{ .object_type = "table", .name = "focus_sessions", .compact_fragment = "check(statein(0,1,2,3))" },
            .{ .object_type = "table", .name = "focus_sessions", .compact_fragment = "check(completion_reasonin(0,1,2,3))" },
            .{ .object_type = "table", .name = "focus_sessions", .compact_fragment = "check(live_slotisnullorlive_slot=1)" },
            .{ .object_type = "table", .name = "focus_sessions", .compact_fragment = "check((statein(0,1)andlive_slot=1)or(statein(2,3)andlive_slotisnull))" },
            .{ .object_type = "index", .name = "one_live_focus_session", .compact_fragment = "createuniqueindexone_live_focus_sessiononfocus_sessions(live_slot)wherelive_slot=1" },
        };
        for (required_fragments) |required| {
            if (!(self.schemaObjectContains(
                required.object_type,
                required.name,
                required.compact_fragment,
            ) catch return error.CorruptDatabase)) return error.CorruptDatabase;
        }

        // Foreign-key SQL can appear inside a comment in `sqlite_schema`.
        // Require SQLite's parsed FK metadata instead: v1 has exactly one FK,
        // `focus_sessions.task_id -> tasks.id`, with canonical actions.
        if (!(self.hasCanonicalFocusSessionForeignKey() catch return error.CorruptDatabase)) {
            return error.CorruptDatabase;
        }

        // The named partial index must actually be unique and index exactly
        // `live_slot`, not merely carry a plausible SQL string.
        if (try self.scalarU32(
            "SELECT COUNT(*) FROM pragma_index_list('focus_sessions') WHERE name='one_live_focus_session' AND \"unique\"=1 AND partial=1;",
        ) != 1) return error.CorruptDatabase;
        if (try self.scalarU32(
            "SELECT COUNT(*) FROM pragma_index_info('one_live_focus_session') WHERE seqno=0 AND cid>=0 AND name='live_slot';",
        ) != 1) return error.CorruptDatabase;
        if (try self.scalarU32(
            "SELECT COUNT(*) FROM pragma_index_info('one_live_focus_session');",
        ) != 1) return error.CorruptDatabase;

        const invalid_counts = [_][]const u8{
            // Singleton records and bounded scalar domains.
            "SELECT COUNT(*) FROM settings WHERE id!=1 OR focus_min NOT BETWEEN 1 AND 180 OR short_break_min NOT BETWEEN 1 AND 60 OR long_break_min NOT BETWEEN 1 AND 120 OR daily_goal_min NOT BETWEEN 1 AND 1440 OR sound_enabled NOT IN (0,1);",
            "SELECT CASE WHEN COUNT(*)=1 THEN 0 ELSE 1 END FROM settings;",
            "SELECT COUNT(*) FROM app_meta WHERE id!=1 OR revision<0 OR revision>9007199254740991 OR next_task_id<=0 OR next_task_id>9007199254740991;",
            "SELECT CASE WHEN COUNT(*)=1 THEN 0 ELSE 1 END FROM app_meta;",
            "SELECT COUNT(*) FROM app_meta WHERE next_task_id<=(SELECT COALESCE(MAX(id),0) FROM tasks);",

            // Task semantics used by every snapshot and mutation.
            "SELECT CASE WHEN COUNT(*)<=256 THEN 0 ELSE 1 END FROM tasks;",
            "SELECT COUNT(*) FROM tasks WHERE id<=0 OR id>9007199254740991 OR typeof(title)!='text' OR length(CAST(title AS BLOB)) NOT BETWEEN 1 AND 240 OR state NOT IN (0,1,2) OR sort_order<0 OR sort_order>4294967295 OR estimate_min NOT BETWEEN 1 AND 480 OR created_ms<0 OR created_ms>9007199254740991 OR updated_ms<created_ms OR updated_ms>9007199254740991 OR completed_ms<0 OR completed_ms>9007199254740991 OR (state=0 AND completed_ms!=0) OR (state=1 AND completed_ms<created_ms);",

            // Session enum/range invariants and the single live slot.
            "SELECT CASE WHEN COUNT(*)<=1 THEN 0 ELSE 1 END FROM focus_sessions WHERE live_slot=1;",
            "SELECT COUNT(*) FROM focus_sessions WHERE id<=0 OR id>9007199254740991 OR mode NOT IN (0,1,2) OR state NOT IN (0,1,2,3) OR completion_reason NOT IN (0,1,2,3) OR (live_slot IS NOT NULL AND live_slot!=1) OR started_ms<0 OR started_ms>9007199254740991 OR last_transition_ms<0 OR last_transition_ms>9007199254740991 OR ends_ms<0 OR ends_ms>9007199254740991 OR remaining_ms<0 OR remaining_ms>86400000 OR planned_ms NOT BETWEEN 1000 AND 86400000 OR focused_ms<0 OR focused_ms>planned_ms OR ended_ms<0 OR ended_ms>9007199254740991;",
            "SELECT COUNT(*) FROM focus_sessions WHERE (state IN (0,1) AND (live_slot IS NULL OR live_slot!=1)) OR (state IN (2,3) AND live_slot IS NOT NULL);",
            "SELECT COUNT(*) FROM focus_sessions WHERE state=0 AND (completion_reason!=0 OR ended_ms!=0 OR ends_ms<=last_transition_ms OR remaining_ms=0 OR remaining_ms>planned_ms OR focused_ms+remaining_ms!=planned_ms OR ends_ms-last_transition_ms!=remaining_ms);",
            "SELECT COUNT(*) FROM focus_sessions WHERE state=1 AND (completion_reason!=0 OR ended_ms!=0 OR ends_ms!=0 OR remaining_ms=0 OR remaining_ms>planned_ms OR focused_ms+remaining_ms!=planned_ms);",
            "SELECT COUNT(*) FROM focus_sessions WHERE state=2 AND (completion_reason NOT IN (1,2,3) OR remaining_ms!=0 OR (ends_ms!=0 AND NOT(completion_reason=3 AND ends_ms=ended_ms)) OR (completion_reason IN (1,3) AND focused_ms!=planned_ms));",
            "SELECT COUNT(*) FROM focus_sessions WHERE state=3 AND (completion_reason!=0 OR ends_ms!=0);",
        };
        for (invalid_counts) |query| {
            const count = self.scalarU64(query) catch return error.CorruptDatabase;
            if (count != 0) return error.CorruptDatabase;
        }

        // SQLite can store ill-formed text if another writer bypasses this
        // service. Apply the same strict UTF-8/control policy on startup.
        const titles = self.prepare("SELECT title FROM tasks;") catch return error.CorruptDatabase;
        defer _ = c.sqlite3_finalize(titles);
        while (true) {
            const rc = c.sqlite3_step(titles);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW or c.sqlite3_column_type(titles, 0) != c.SQLITE_TEXT) {
                return error.CorruptDatabase;
            }
            if (!validTitle(try self.columnBytes(titles, 0))) return error.CorruptDatabase;
        }
    }

    fn schemaObjectContains(
        self: *SqliteExtension,
        object_type: []const u8,
        name: []const u8,
        compact_fragment: []const u8,
    ) !bool {
        const statement = try self.prepare(
            "SELECT sql FROM sqlite_schema WHERE type=?1 AND name=?2 AND sql IS NOT NULL;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindText(statement, 1, object_type);
        try self.bindText(statement, 2, name);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
        return sqlContainsCompact(try self.columnBytes(statement, 0), compact_fragment);
    }

    fn hasCanonicalFocusSessionForeignKey(self: *SqliteExtension) !bool {
        const statement = try self.prepare("PRAGMA foreign_key_list('focus_sessions');");
        defer _ = c.sqlite3_finalize(statement);

        const first = c.sqlite3_step(statement);
        if (first == c.SQLITE_DONE) return false;
        if (first != c.SQLITE_ROW) return self.sqliteFailure("foreign_key_list");

        const expected_types =
            c.sqlite3_column_type(statement, 0) == c.SQLITE_INTEGER and
            c.sqlite3_column_type(statement, 1) == c.SQLITE_INTEGER and
            c.sqlite3_column_type(statement, 2) == c.SQLITE_TEXT and
            c.sqlite3_column_type(statement, 3) == c.SQLITE_TEXT and
            c.sqlite3_column_type(statement, 4) == c.SQLITE_TEXT and
            c.sqlite3_column_type(statement, 5) == c.SQLITE_TEXT and
            c.sqlite3_column_type(statement, 6) == c.SQLITE_TEXT and
            c.sqlite3_column_type(statement, 7) == c.SQLITE_TEXT;
        const canonical = expected_types and
            try self.columnU32(statement, 0) == 0 and
            try self.columnU32(statement, 1) == 0 and
            std.mem.eql(u8, try self.columnBytes(statement, 2), "tasks") and
            std.mem.eql(u8, try self.columnBytes(statement, 3), "task_id") and
            std.mem.eql(u8, try self.columnBytes(statement, 4), "id") and
            std.mem.eql(u8, try self.columnBytes(statement, 5), "NO ACTION") and
            std.mem.eql(u8, try self.columnBytes(statement, 6), "SET NULL") and
            std.mem.eql(u8, try self.columnBytes(statement, 7), "NONE");

        const after = c.sqlite3_step(statement);
        if (after == c.SQLITE_ROW) return false;
        if (after != c.SQLITE_DONE) return self.sqliteFailure("foreign_key_list");
        return canonical;
    }

    fn beginImmediate(self: *SqliteExtension) !void {
        try self.exec("BEGIN IMMEDIATE;");
    }

    fn commit(self: *SqliteExtension) !void {
        try self.exec("COMMIT;");
    }

    fn rollback(self: *SqliteExtension) void {
        self.exec("ROLLBACK;") catch {};
    }

    fn incrementRevision(self: *SqliteExtension) !void {
        const statement = try self.prepare(
            "UPDATE app_meta SET revision=revision+1 WHERE id=1 AND revision<?1;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, max_safe_integer);
        try self.stepDone(statement);
        if (c.sqlite3_changes(self.db.?) != 1) {
            if (try self.currentRevision() >= max_safe_integer) return error.UnsafeInteger;
            return error.CorruptDatabase;
        }
    }

    fn currentRevision(self: *SqliteExtension) !u64 {
        return self.scalarU64("SELECT revision FROM app_meta WHERE id=1;");
    }

    fn nextTaskId(self: *SqliteExtension) !u64 {
        return self.scalarU64("SELECT next_task_id FROM app_meta WHERE id=1;");
    }

    fn exec(self: *SqliteExtension, sql: [:0]const u8) !void {
        var error_message: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db.?, sql.ptr, null, null, &error_message);
        if (rc == c.SQLITE_OK) return;
        if (error_message != null) {
            const message = std.mem.span(error_message);
            self.setFormattedError("sqlite:exec:{d}:{s}", .{ rc, message });
            c.sqlite3_free(error_message);
        } else {
            self.captureSqliteError(self.db.?, "exec");
        }
        return error.SqliteFailure;
    }

    fn prepare(self: *SqliteExtension, sql: []const u8) !*c.sqlite3_stmt {
        var statement: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db.?, sql.ptr, @intCast(sql.len), &statement, null);
        if (rc != c.SQLITE_OK or statement == null) return self.sqliteFailure("prepare");
        return statement.?;
    }

    fn stepDone(self: *SqliteExtension, statement: *c.sqlite3_stmt) !void {
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return self.sqliteFailure("step");
    }

    fn bindU64(self: *SqliteExtension, statement: *c.sqlite3_stmt, index: c_int, value: u64) !void {
        if (value > max_safe_integer) return error.UnsafeInteger;
        if (c.sqlite3_bind_int64(statement, index, @intCast(value)) != c.SQLITE_OK) return self.sqliteFailure("bind_int64");
    }

    fn bindU32(self: *SqliteExtension, statement: *c.sqlite3_stmt, index: c_int, value: anytype) !void {
        if (c.sqlite3_bind_int64(statement, index, @intCast(value)) != c.SQLITE_OK) return self.sqliteFailure("bind_int");
    }

    fn bindOptionalTask(self: *SqliteExtension, statement: *c.sqlite3_stmt, index: c_int, task_id: u64) !void {
        const rc = if (task_id == 0)
            c.sqlite3_bind_null(statement, index)
        else
            c.sqlite3_bind_int64(statement, index, @intCast(task_id));
        if (rc != c.SQLITE_OK) return self.sqliteFailure("bind_task");
    }

    fn bindText(self: *SqliteExtension, statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
        if (c.sqlite3_bind_text(statement, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
            return self.sqliteFailure("bind_text");
        }
    }

    fn scalarU64(self: *SqliteExtension, sql: []const u8) !u64 {
        const statement = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return self.sqliteFailure("scalar");
        return self.columnU64(statement, 0);
    }

    fn scalarU32(self: *SqliteExtension, sql: []const u8) !u32 {
        const value = try self.scalarU64(sql);
        if (value > std.math.maxInt(u32)) return error.CorruptDatabase;
        return @intCast(value);
    }

    fn scalarU64At(self: *SqliteExtension, sql: []const u8, now_ms: u64) !u64 {
        const statement = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(statement);
        try self.bindU64(statement, 1, now_ms);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return self.sqliteFailure("scalar_at");
        return self.columnU64(statement, 0);
    }

    fn scalarU32At(self: *SqliteExtension, sql: []const u8, now_ms: u64) !u32 {
        const value = try self.scalarU64At(sql, now_ms);
        if (value > std.math.maxInt(u32)) return error.CorruptDatabase;
        return @intCast(value);
    }

    fn columnU64(self: *SqliteExtension, statement: *c.sqlite3_stmt, index: c_int) !u64 {
        _ = self;
        const value = c.sqlite3_column_int64(statement, index);
        if (value < 0) return error.CorruptDatabase;
        const result: u64 = @intCast(value);
        if (result > max_safe_integer) return error.CorruptDatabase;
        return result;
    }

    fn columnU32(self: *SqliteExtension, statement: *c.sqlite3_stmt, index: c_int) !u32 {
        const value = try self.columnU64(statement, index);
        if (value > std.math.maxInt(u32)) return error.CorruptDatabase;
        return @intCast(value);
    }

    fn columnBytes(self: *SqliteExtension, statement: *c.sqlite3_stmt, index: c_int) ![]const u8 {
        _ = self;
        const length = c.sqlite3_column_bytes(statement, index);
        if (length < 0) return error.CorruptDatabase;
        if (length == 0) return "";
        const pointer = c.sqlite3_column_text(statement, index) orelse return error.CorruptDatabase;
        return @as([*]const u8, @ptrCast(pointer))[0..@intCast(length)];
    }

    fn sqliteFailure(self: *SqliteExtension, operation: []const u8) Error {
        self.captureSqliteError(self.db.?, operation);
        return error.SqliteFailure;
    }

    fn captureSqliteError(self: *SqliteExtension, db: *c.sqlite3, operation: []const u8) void {
        const message_pointer = c.sqlite3_errmsg(db);
        const message = if (message_pointer == null) "unknown" else std.mem.span(message_pointer);
        self.setFormattedError("sqlite:{s}:{d}:{s}", .{ operation, c.sqlite3_extended_errcode(db), message });
    }

    fn setError(self: *SqliteExtension, message: []const u8) void {
        const length = @min(message.len, self.last_error.len);
        @memcpy(self.last_error[0..length], message[0..length]);
        self.last_error_len = length;
    }

    fn setFormattedError(self: *SqliteExtension, comptime format: []const u8, args: anytype) void {
        const message = std.fmt.bufPrint(&self.last_error, format, args) catch {
            self.setError("sqlite_failure");
            return;
        };
        self.last_error_len = message.len;
    }
};

fn validateTitle(title: []const u8) !void {
    if (!validTitle(title)) return error.InvalidTitle;
}

fn validTitle(title: []const u8) bool {
    if (title.len == 0 or title.len > max_title_bytes or !std.unicode.utf8ValidateSlice(title)) return false;
    var iterator = std.unicode.Utf8Iterator{ .bytes = title, .i = 0 };
    var has_non_whitespace = false;
    while (iterator.nextCodepoint()) |codepoint| {
        // Reject record/line injection and directional display controls while
        // preserving legitimate format characters such as ZWNJ/ZWJ.
        if (titleCodepointRejected(codepoint)) return false;
        if (!titleCodepointWhitespace(codepoint)) has_non_whitespace = true;
    }
    return has_non_whitespace;
}

fn titleCodepointRejected(codepoint: u21) bool {
    return codepoint <= 0x1f or
        (codepoint >= 0x7f and codepoint <= 0x9f) or
        codepoint == 0x2028 or
        codepoint == 0x2029 or
        codepoint == 0x061c or
        codepoint == 0x200e or
        codepoint == 0x200f or
        (codepoint >= 0x202a and codepoint <= 0x202e) or
        (codepoint >= 0x2066 and codepoint <= 0x2069);
}

fn titleCodepointWhitespace(codepoint: u21) bool {
    return codepoint == 0x20 or
        codepoint == 0x00a0 or
        codepoint == 0x1680 or
        (codepoint >= 0x2000 and codepoint <= 0x200a) or
        codepoint == 0x2028 or
        codepoint == 0x2029 or
        codepoint == 0x202f or
        codepoint == 0x205f or
        codepoint == 0x3000 or
        codepoint == 0xfeff;
}

/// Match a lower-case, whitespace-free schema fragment without allocating.
/// SQLite preserves harmless formatting differences in `sqlite_schema.sql`,
/// so validation compares canonical token streams rather than raw bytes.
fn sqlContainsCompact(sql: []const u8, compact_fragment: []const u8) bool {
    if (compact_fragment.len == 0) return true;
    for (sql, 0..) |byte, start| {
        if (std.ascii.isWhitespace(byte)) continue;
        var sql_index = start;
        var fragment_index: usize = 0;
        while (sql_index < sql.len and fragment_index < compact_fragment.len) : (sql_index += 1) {
            const candidate = sql[sql_index];
            if (std.ascii.isWhitespace(candidate)) continue;
            if (std.ascii.toLower(candidate) != compact_fragment[fragment_index]) break;
            fragment_index += 1;
        }
        if (fragment_index == compact_fragment.len) return true;
    }
    return false;
}

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    fn take(self: *Reader, count: usize) ![]const u8 {
        if (count > self.bytes.len -| self.offset) return error.InvalidRequest;
        const result = self.bytes[self.offset..][0..count];
        self.offset += count;
        return result;
    }

    fn expectMagic(self: *Reader, expected: *const [4]u8) !void {
        if (!std.mem.eql(u8, try self.take(4), expected)) return error.InvalidRequest;
    }

    fn readU8(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }

    fn readU32(self: *Reader) !u32 {
        const input = try self.take(4);
        var result: u32 = 0;
        var factor: u32 = 1;
        for (input, 0..) |byte, index| {
            result += @as(u32, byte) * factor;
            if (index != 3) factor *= 256;
        }
        return result;
    }

    fn readU64(self: *Reader) !u64 {
        const input = try self.take(8);
        var result: u64 = 0;
        var factor: u64 = 1;
        for (input, 0..) |byte, index| {
            result += @as(u64, byte) * factor;
            if (index != 7) factor *= 256;
        }
        return result;
    }

    fn safeU64(self: *Reader) !u64 {
        const value = try self.readU64();
        if (value > max_safe_integer) return error.UnsafeInteger;
        return value;
    }

    fn bytesWithU32Length(self: *Reader, maximum: usize) ![]const u8 {
        const length = try self.readU32();
        if (length > maximum) return error.InvalidRequest;
        return self.take(length);
    }

    fn taskTitle(self: *Reader) ![]const u8 {
        const length = try self.readU32();
        // First prove the declared bytes are present, so a truncated or
        // forged request remains `invalid_request`. A complete value beyond
        // the product limit is a well-formed request with an invalid title.
        const title = try self.take(length);
        if (length > max_title_bytes) return error.InvalidTitle;
        try validateTitle(title);
        return title;
    }

    fn finish(self: *Reader) !void {
        if (self.offset != self.bytes.len) return error.TrailingBytes;
    }
};

const Writer = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Writer) void {
        self.list.deinit(self.allocator);
    }

    fn bytes(self: *Writer, value: []const u8) !void {
        try self.list.appendSlice(self.allocator, value);
    }

    fn writeU8(self: *Writer, value: u8) !void {
        try self.list.append(self.allocator, value);
    }

    fn writeU32(self: *Writer, input: u32) !void {
        var value = input;
        for (0..4) |_| {
            try self.writeU8(@truncate(value));
            value >>= 8;
        }
    }

    fn writeU64(self: *Writer, input: u64) !void {
        var value = input;
        for (0..8) |_| {
            try self.writeU8(@truncate(value));
            value >>= 8;
        }
    }

    fn lengthPrefixed(self: *Writer, value: []const u8) !void {
        if (value.len > std.math.maxInt(u32)) return error.SnapshotTooLarge;
        try self.writeU32(@intCast(value.len));
        try self.bytes(value);
    }

    fn toOwnedSlice(self: *Writer) ![]u8 {
        return self.list.toOwnedSlice(self.allocator);
    }
};

fn testDataDir(tmp: *std.testing.TmpDir, output: []u8) ![]const u8 {
    return std.fmt.bufPrint(output, ".zig-cache/tmp/{s}/focus-data", .{tmp.sub_path[0..]});
}

fn appendLoadRequest(writer: *Writer, now_ms: u64) !void {
    try writer.bytes("FCL1");
    try writer.writeU32(request_version);
    try writer.writeU64(now_ms);
}

fn appendMutationHeader(writer: *Writer, revision: u64, now_ms: u64) !void {
    try writer.bytes("FCM1");
    try writer.writeU32(request_version);
    try writer.writeU64(revision);
    try writer.writeU64(now_ms);
}

fn expectRequestError(
    extension: *SqliteExtension,
    expected: anyerror,
    command: []const u8,
    payload: []const u8,
) !void {
    if (extension.handleRequest(command, payload)) |unexpected| {
        extension.freeResponse(unexpected);
        return error.TestUnexpectedResult;
    } else |actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

const SnapshotProbe = struct {
    revision: u64,
    next_task_id: u64,
    task_count: u32,
    active: bool,
    recent_count: u32,
    today_focus_ms: u64,
    today_session_count: u32,
    today_task_count: u32,
    today_weekday: u8,
};

fn probeSnapshot(bytes: []const u8) !SnapshotProbe {
    var reader = Reader.init(bytes);
    try reader.expectMagic("FCS2");
    if (try reader.readU32() != snapshot_version) return error.UnsupportedVersion;
    const revision = try reader.readU64();
    _ = try reader.take(4 * 4 + 1);
    const next_task_id = try reader.readU64();
    const task_count = try reader.readU32();
    var task_index: u32 = 0;
    while (task_index < task_count) : (task_index += 1) {
        _ = try reader.take(8 + 1 + 4 + 4 + 8 + 8 + 8);
        _ = try reader.bytesWithU32Length(max_title_bytes);
    }
    const active = (try reader.readU8()) == 1;
    if (active) _ = try reader.take(8 + 8 + 1 + 1 + 1 + 8 * 6);
    const recent_count = try reader.readU32();
    var recent_index: u32 = 0;
    while (recent_index < recent_count) : (recent_index += 1) _ = try reader.take(8 + 8 + 1 + 1 + 1 + 8 * 6);
    const today_focus_ms = try reader.readU64();
    const today_session_count = try reader.readU32();
    const today_task_count = try reader.readU32();
    const day_count = try reader.readU32();
    if (day_count != 7) return error.InvalidRequest;
    const today_weekday = try reader.readU8();
    if (today_weekday > 6) return error.InvalidRequest;
    _ = try reader.take(7 * 8);
    try reader.finish();
    return .{
        .revision = revision,
        .next_task_id = next_task_id,
        .task_count = task_count,
        .active = active,
        .recent_count = recent_count,
        .today_focus_ms = today_focus_ms,
        .today_session_count = today_session_count,
        .today_task_count = today_task_count,
        .today_weekday = today_weekday,
    };
}

test "SQLite extension migrates, persists authoritative tasks, and rejects stale revisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);

    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    var request = Writer.init(std.testing.allocator);
    defer request.deinit();
    try appendLoadRequest(&request, 1_000);
    const initial = try extension.handleRequest(load_command, request.list.items);
    defer std.testing.allocator.free(initial);
    const initial_probe = try probeSnapshot(initial);
    try std.testing.expectEqual(@as(u64, 0), initial_probe.revision);
    try std.testing.expectEqual(@as(u32, 0), initial_probe.task_count);

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 0, 2_000);
    try request.writeU32(25);
    try request.lengthPrefixed("Write the launch brief");
    const created = try extension.handleRequest(task_create_command, request.list.items);
    defer std.testing.allocator.free(created);
    const created_probe = try probeSnapshot(created);
    try std.testing.expectEqual(@as(u64, 1), created_probe.revision);
    try std.testing.expectEqual(@as(u64, 2), created_probe.next_task_id);
    try std.testing.expectEqual(@as(u32, 1), created_probe.task_count);

    try std.testing.expectError(error.StaleRevision, extension.handleRequest(task_create_command, request.list.items));
    try extension.stopModule(.{ .platform_name = "macos" });
    try extension.startModule(.{ .platform_name = "macos" });

    request.list.clearRetainingCapacity();
    try appendLoadRequest(&request, 3_000);
    const reopened = try extension.handleRequest(load_command, request.list.items);
    defer std.testing.allocator.free(reopened);
    const reopened_probe = try probeSnapshot(reopened);
    try std.testing.expectEqual(@as(u64, 1), reopened_probe.revision);
    try std.testing.expectEqual(@as(u32, 1), reopened_probe.task_count);
}

test "timer commands use CAS and load recovers an expired running session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    var request = Writer.init(std.testing.allocator);
    defer request.deinit();
    try appendMutationHeader(&request, 0, 10_000);
    try request.writeU64(0);
    try request.writeU8(0);
    try request.writeU64(1_000);
    const started = try extension.handleRequest(timer_start_command, request.list.items);
    defer std.testing.allocator.free(started);
    const started_probe = try probeSnapshot(started);
    try std.testing.expect(started_probe.active);
    try std.testing.expectEqual(@as(u64, 1), started_probe.revision);

    request.list.clearRetainingCapacity();
    try appendLoadRequest(&request, 12_000);
    const recovered = try extension.handleRequest(load_command, request.list.items);
    defer std.testing.allocator.free(recovered);
    const recovered_probe = try probeSnapshot(recovered);
    try std.testing.expect(!recovered_probe.active);
    try std.testing.expectEqual(@as(u64, 2), recovered_probe.revision);
    try std.testing.expectEqual(@as(u32, 1), recovered_probe.recent_count);
    try std.testing.expectEqual(@as(u64, 3), try extension.scalarU64(
        "SELECT completion_reason FROM focus_sessions WHERE id=1;",
    ));
    try std.testing.expectEqual(@as(u64, 1_000), try extension.scalarU64(
        "SELECT focused_ms FROM focus_sessions WHERE id=1;",
    ));
    try std.testing.expectEqual(@as(u64, 11_000), try extension.scalarU64(
        "SELECT ended_ms FROM focus_sessions WHERE id=1;",
    ));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 2, 13_000);
    try request.writeU64(1);
    try std.testing.expectError(error.StaleSession, extension.handleRequest(timer_pause_command, request.list.items));
    try std.testing.expectEqual(@as(u64, 2), try extension.currentRevision());
}

test "wire reader rejects malformed and trailing request bytes" {
    var reader = Reader.init("FCL1\x01\x00");
    try reader.expectMagic("FCL1");
    try std.testing.expectError(error.InvalidRequest, reader.readU32());

    var complete = [_]u8{ 'F', 'C', 'L', '1', 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 99 };
    reader = Reader.init(&complete);
    try reader.expectMagic("FCL1");
    _ = try reader.readU32();
    _ = try reader.readU64();
    try std.testing.expectError(error.TrailingBytes, reader.finish());
}

test "eager startup failure reaches the core once and the next request reopens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();

    // Models the error retained by startHook without needing to damage a
    // real database file. The first load renders the exact failure; Retry
    // performs startModule and returns an authoritative empty snapshot.
    extension.startup_error = error.CorruptDatabase;
    var request = Writer.init(std.testing.allocator);
    defer request.deinit();
    try appendLoadRequest(&request, 1_000);
    try expectRequestError(&extension, error.CorruptDatabase, load_command, request.list.items);
    try std.testing.expect(extension.db == null);

    const retried = try extension.handleRequest(load_command, request.list.items);
    defer std.testing.allocator.free(retried);
    try std.testing.expect(extension.db != null);
    const probe = try probeSnapshot(retried);
    try std.testing.expectEqual(@as(u64, 0), probe.revision);
    try std.testing.expectEqual(@as(u32, 0), probe.task_count);
}

test "paused time is excluded and natural completion uses its scheduled end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    var request = Writer.init(std.testing.allocator);
    defer request.deinit();

    try appendMutationHeader(&request, 0, 1_000);
    try request.writeU64(0);
    try request.writeU8(0);
    try request.writeU64(10_000);
    std.testing.allocator.free(try extension.handleRequest(timer_start_command, request.list.items));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 1, 4_000);
    try request.writeU64(1);
    std.testing.allocator.free(try extension.handleRequest(timer_pause_command, request.list.items));
    try std.testing.expectEqual(@as(u64, 3_000), try extension.scalarU64(
        "SELECT focused_ms FROM focus_sessions WHERE id=1;",
    ));
    try std.testing.expectEqual(@as(u64, 7_000), try extension.scalarU64(
        "SELECT remaining_ms FROM focus_sessions WHERE id=1;",
    ));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 2, 10_000);
    try request.writeU64(1);
    std.testing.allocator.free(try extension.handleRequest(timer_resume_command, request.list.items));
    try std.testing.expectEqual(@as(u64, 17_000), try extension.scalarU64(
        "SELECT ends_ms FROM focus_sessions WHERE id=1;",
    ));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 3, 12_000);
    try request.writeU64(1);
    try request.writeU8(1);
    std.testing.allocator.free(try extension.handleRequest(timer_complete_command, request.list.items));
    try std.testing.expectEqual(@as(u64, 5_000), try extension.scalarU64(
        "SELECT focused_ms FROM focus_sessions WHERE id=1;",
    ));
    try std.testing.expectEqual(@as(u64, 2), try extension.scalarU64(
        "SELECT completion_reason FROM focus_sessions WHERE id=1;",
    ));
    try std.testing.expectEqual(@as(u64, 12_000), try extension.scalarU64(
        "SELECT ended_ms FROM focus_sessions WHERE id=1;",
    ));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 4, 20_000);
    try request.writeU64(0);
    try request.writeU8(0);
    try request.writeU64(1_000);
    std.testing.allocator.free(try extension.handleRequest(timer_start_command, request.list.items));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 5, 21_500);
    try request.writeU64(2);
    // Even if the UI labels this as manual, arrival after the absolute
    // deadline is natural and is booked at 21_000, not at click time.
    try request.writeU8(1);
    const late_manual = try extension.handleRequest(timer_complete_command, request.list.items);
    defer std.testing.allocator.free(late_manual);
    const late_probe = try probeSnapshot(late_manual);
    try std.testing.expectEqual(@as(u64, 1), try extension.scalarU64(
        "SELECT completion_reason FROM focus_sessions WHERE id=2;",
    ));
    try std.testing.expectEqual(@as(u64, 21_000), try extension.scalarU64(
        "SELECT ended_ms FROM focus_sessions WHERE id=2;",
    ));
    try std.testing.expectEqual(@as(u64, 1_000), try extension.scalarU64(
        "SELECT focused_ms FROM focus_sessions WHERE id=2;",
    ));
    try std.testing.expectEqual(@as(u64, 6_000), late_probe.today_focus_ms);
    try std.testing.expectEqual(@as(u32, 2), late_probe.today_session_count);
}

test "maximum task set plus sessions and stats fits the authoritative snapshot budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    try extension.exec(
        \\WITH RECURSIVE sequence(value) AS (
        \\  SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<255
        \\)
        \\INSERT INTO tasks(id,title,state,sort_order,estimate_min,created_ms,updated_ms,completed_ms)
        \\SELECT value,printf('%0240d',value),0,value-1,25,1,1,0 FROM sequence;
        \\WITH RECURSIVE sequence(value) AS (
        \\  SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<14
        \\)
        \\INSERT INTO focus_sessions(
        \\  task_id,mode,state,completion_reason,live_slot,started_ms,last_transition_ms,
        \\  ends_ms,remaining_ms,planned_ms,focused_ms,ended_ms
        \\)
        \\SELECT NULL,0,2,2,NULL,value,value+1000,0,0,1000,1000,value+1000 FROM sequence;
        \\INSERT INTO focus_sessions(
        \\  task_id,mode,state,completion_reason,live_slot,started_ms,last_transition_ms,
        \\  ends_ms,remaining_ms,planned_ms,focused_ms,ended_ms
        \\) VALUES(NULL,0,1,0,1,1,1,0,1000,1000,0,0);
        \\UPDATE app_meta SET next_task_id=256 WHERE id=1;
    );

    var request = Writer.init(std.testing.allocator);
    defer request.deinit();
    try appendLoadRequest(&request, 10);
    const baseline = try extension.handleRequest(load_command, request.list.items);
    defer std.testing.allocator.free(baseline);
    try std.testing.expect(baseline.len <= max_snapshot_bytes);
    try std.testing.expect(baseline.len > 60 * 1024);
    const baseline_probe = try probeSnapshot(baseline);
    try std.testing.expectEqual(@as(u32, 255), baseline_probe.task_count);
    try std.testing.expect(baseline_probe.active);
    try std.testing.expectEqual(@as(u32, max_recent_sessions), baseline_probe.recent_count);

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 0, 20);
    try request.writeU32(25);
    const title: [max_title_bytes]u8 = @splat('x');
    try request.lengthPrefixed(&title);
    const maximum = try extension.handleRequest(task_create_command, request.list.items);
    defer std.testing.allocator.free(maximum);
    try std.testing.expect(maximum.len <= max_snapshot_bytes);
    const maximum_probe = try probeSnapshot(maximum);
    try std.testing.expectEqual(@as(u64, 1), maximum_probe.revision);
    try std.testing.expectEqual(@as(u64, 257), maximum_probe.next_task_id);
    try std.testing.expectEqual(@as(u32, max_tasks), maximum_probe.task_count);
    try std.testing.expect(maximum_probe.active);
    try std.testing.expectEqual(@as(u32, max_recent_sessions), maximum_probe.recent_count);

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 1, 30);
    try request.writeU32(25);
    try request.lengthPrefixed("Task 257 must be rejected");
    try expectRequestError(&extension, error.TaskLimitReached, task_create_command, request.list.items);
    try std.testing.expectEqual(@as(u64, 1), try extension.currentRevision());
    try std.testing.expectEqual(@as(u64, max_tasks), try extension.scalarU64("SELECT COUNT(*) FROM tasks;"));
    try std.testing.expectEqual(@as(u64, 257), try extension.nextTaskId());
}

test "purge is archived-only, frees capacity, preserves sessions, and persists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    try extension.exec(
        \\WITH RECURSIVE sequence(value) AS (
        \\  SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<256
        \\)
        \\INSERT INTO tasks(id,title,state,sort_order,estimate_min,created_ms,updated_ms,completed_ms)
        \\SELECT value,printf('Task %d',value),
        \\  CASE value WHEN 1 THEN 0 WHEN 2 THEN 1 ELSE 2 END,
        \\  value-1,25,1,1,CASE value WHEN 2 THEN 1 ELSE 0 END
        \\FROM sequence;
        \\INSERT INTO focus_sessions(
        \\  task_id,mode,state,completion_reason,live_slot,started_ms,last_transition_ms,
        \\  ends_ms,remaining_ms,planned_ms,focused_ms,ended_ms
        \\) VALUES(3,0,2,2,NULL,1,1001,0,0,1000,1000,1001);
        \\UPDATE app_meta SET next_task_id=257 WHERE id=1;
    );

    var request = Writer.init(std.testing.allocator);
    defer request.deinit();

    try appendMutationHeader(&request, 0, 10);
    try request.writeU32(25);
    try request.lengthPrefixed("At capacity");
    try expectRequestError(&extension, error.TaskLimitReached, task_create_command, request.list.items);
    try std.testing.expectEqual(@as(u64, 0), try extension.currentRevision());

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 0, 20);
    try request.writeU64(1);
    try expectRequestError(&extension, error.InvalidTaskState, task_purge_command, request.list.items);

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 0, 30);
    try request.writeU64(2);
    try expectRequestError(&extension, error.InvalidTaskState, task_purge_command, request.list.items);

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 0, 40);
    try request.writeU64(3);
    const purged = try extension.handleRequest(task_purge_command, request.list.items);
    defer std.testing.allocator.free(purged);
    const purged_probe = try probeSnapshot(purged);
    try std.testing.expectEqual(@as(u64, 1), purged_probe.revision);
    try std.testing.expectEqual(@as(u32, 255), purged_probe.task_count);
    try std.testing.expectEqual(@as(u64, 1), try extension.scalarU64(
        "SELECT COUNT(*) FROM focus_sessions WHERE id=1 AND task_id IS NULL;",
    ));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 1, 50);
    try request.writeU32(25);
    try request.lengthPrefixed("Capacity restored");
    const created = try extension.handleRequest(task_create_command, request.list.items);
    defer std.testing.allocator.free(created);
    const created_probe = try probeSnapshot(created);
    try std.testing.expectEqual(@as(u64, 2), created_probe.revision);
    try std.testing.expectEqual(@as(u64, 258), created_probe.next_task_id);
    try std.testing.expectEqual(@as(u32, 256), created_probe.task_count);

    try extension.stopModule(.{ .platform_name = "macos" });
    try extension.startModule(.{ .platform_name = "macos" });
    request.list.clearRetainingCapacity();
    try appendLoadRequest(&request, 60);
    const reopened = try extension.handleRequest(load_command, request.list.items);
    defer std.testing.allocator.free(reopened);
    try std.testing.expectEqual(@as(u32, 256), (try probeSnapshot(reopened)).task_count);
    try std.testing.expectEqual(@as(u64, 0), try extension.scalarU64(
        "SELECT COUNT(*) FROM tasks WHERE id=3;",
    ));
    try std.testing.expectEqual(@as(u64, 1), try extension.scalarU64(
        "SELECT COUNT(*) FROM tasks WHERE id=257;",
    ));
}

test "title policy rejects malformed UTF-8 separators bidi controls and Unicode whitespace-only input" {
    try std.testing.expect(validTitle("Ship the focused release 🎯"));
    try std.testing.expect(validTitle("Crème brûlée"));
    // ZWNJ and ZWJ are legitimate shaping controls, not Bidi_Control.
    try std.testing.expect(validTitle("A\xe2\x80\x8c\xe2\x80\x8dB"));
    // FEFF matches JavaScript trim semantics only when it is the entire title.
    try std.testing.expect(validTitle("A\xef\xbb\xbfB"));
    const invalid_titles = [_][]const u8{
        "",
        "   ",
        "line\nbreak",
        "carriage\rreturn",
        "tab\tseparated",
        "nul\x00byte",
        "escape\x1bbyte",
        "delete\x7fbyte",
        "c1-\xc2\x85-next-line",
        "c1-\xc2\x9f-control",
        "broken-\xff-utf8",
        "lone-\x80-continuation",
        "overlong-\xc0\xaf-sequence",
        "truncated-\xe2\x82",
        "surrogate-\xed\xa0\x80",
        "too-large-\xf4\x90\x80\x80",
    };
    for (invalid_titles) |title| try std.testing.expect(!validTitle(title));

    const whitespace_codepoints = [_]u21{
        0x0020,
        0x00a0,
        0x1680,
        0x2000,
        0x2001,
        0x2002,
        0x2003,
        0x2004,
        0x2005,
        0x2006,
        0x2007,
        0x2008,
        0x2009,
        0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        0xfeff,
    };
    var encoded_whitespace: [4]u8 = undefined;
    for (whitespace_codepoints) |codepoint| {
        const length: usize = try std.unicode.utf8Encode(codepoint, &encoded_whitespace);
        try std.testing.expect(!validTitle(encoded_whitespace[0..length]));
    }

    const rejected_codepoints = [_]u21{
        0x061c,
        0x200e,
        0x200f,
        0x2028,
        0x2029,
        0x202a,
        0x202b,
        0x202c,
        0x202d,
        0x202e,
        0x2066,
        0x2067,
        0x2068,
        0x2069,
    };
    var embedded_control: [6]u8 = undefined;
    for (rejected_codepoints) |codepoint| {
        embedded_control[0] = 'A';
        const length: usize = try std.unicode.utf8Encode(codepoint, embedded_control[1..5]);
        embedded_control[length + 1] = 'B';
        try std.testing.expect(!validTitle(embedded_control[0 .. length + 2]));
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    var request = Writer.init(std.testing.allocator);
    defer request.deinit();
    for (invalid_titles) |title| {
        request.list.clearRetainingCapacity();
        try appendMutationHeader(&request, 0, 1_000);
        try request.writeU32(25);
        try request.lengthPrefixed(title);
        try expectRequestError(&extension, error.InvalidTitle, task_create_command, request.list.items);
        try std.testing.expectEqual(@as(u64, 0), try extension.currentRevision());
    }

    for (whitespace_codepoints) |codepoint| {
        const length: usize = try std.unicode.utf8Encode(codepoint, &encoded_whitespace);
        request.list.clearRetainingCapacity();
        try appendMutationHeader(&request, 0, 1_000);
        try request.writeU32(25);
        try request.lengthPrefixed(encoded_whitespace[0..length]);
        try expectRequestError(&extension, error.InvalidTitle, task_create_command, request.list.items);
    }
    for (rejected_codepoints) |codepoint| {
        embedded_control[0] = 'A';
        const length: usize = try std.unicode.utf8Encode(codepoint, embedded_control[1..5]);
        embedded_control[length + 1] = 'B';
        request.list.clearRetainingCapacity();
        try appendMutationHeader(&request, 0, 1_000);
        try request.writeU32(25);
        try request.lengthPrefixed(embedded_control[0 .. length + 2]);
        try expectRequestError(&extension, error.InvalidTitle, task_create_command, request.list.items);
    }

    // Both mutation entry points remain authoritative even if a future core
    // accidentally weakens its own validation.
    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 0, 2_000);
    try request.writeU32(25);
    try request.lengthPrefixed("Valid \xef\xbb\xbforiginal title");
    extension.freeResponse(try extension.handleRequest(task_create_command, request.list.items));
    try std.testing.expectEqual(@as(u64, 1), try extension.currentRevision());

    embedded_control[0] = 'A';
    const bidi_length: usize = try std.unicode.utf8Encode(0x200e, embedded_control[1..5]);
    embedded_control[bidi_length + 1] = 'B';
    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 1, 3_000);
    try request.writeU64(1);
    try request.lengthPrefixed(embedded_control[0 .. bidi_length + 2]);
    try expectRequestError(&extension, error.InvalidTitle, task_rename_command, request.list.items);

    const whitespace_length: usize = try std.unicode.utf8Encode(0x3000, &encoded_whitespace);
    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 1, 3_000);
    try request.writeU64(1);
    try request.lengthPrefixed(encoded_whitespace[0..whitespace_length]);
    try expectRequestError(&extension, error.InvalidTitle, task_rename_command, request.list.items);
    try std.testing.expectEqual(@as(u64, 1), try extension.currentRevision());
}

test "create and rename classify complete titles at the 240-byte boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    const create_at_limit: [max_title_bytes]u8 = @splat('a');
    const rename_at_limit: [max_title_bytes]u8 = @splat('b');
    const over_limit: [max_title_bytes + 1]u8 = @splat('c');
    var request = Writer.init(std.testing.allocator);
    defer request.deinit();

    try appendMutationHeader(&request, 0, 1_000);
    try request.writeU32(25);
    try request.lengthPrefixed(&create_at_limit);
    extension.freeResponse(try extension.handleRequest(task_create_command, request.list.items));
    try std.testing.expectEqual(@as(u64, 1), try extension.currentRevision());
    try std.testing.expectEqual(@as(u64, max_title_bytes), try extension.scalarU64(
        "SELECT length(CAST(title AS BLOB)) FROM tasks WHERE id=1;",
    ));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 1, 2_000);
    try request.writeU32(25);
    try request.lengthPrefixed(&over_limit);
    try expectRequestError(&extension, error.InvalidTitle, task_create_command, request.list.items);
    try std.testing.expectEqualStrings("invalid_title", extension.errorBytes(error.InvalidTitle));
    try std.testing.expectEqual(@as(u64, 1), try extension.currentRevision());
    try std.testing.expectEqual(@as(u64, 1), try extension.scalarU64("SELECT COUNT(*) FROM tasks;"));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 1, 2_500);
    try request.writeU32(25);
    try request.writeU32(max_title_bytes + 1);
    try request.bytes(&create_at_limit); // One declared title byte is absent.
    try expectRequestError(&extension, error.InvalidRequest, task_create_command, request.list.items);
    try std.testing.expectEqual(@as(u64, 1), try extension.currentRevision());

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 1, 3_000);
    try request.writeU64(1);
    try request.lengthPrefixed(&rename_at_limit);
    extension.freeResponse(try extension.handleRequest(task_rename_command, request.list.items));
    try std.testing.expectEqual(@as(u64, 2), try extension.currentRevision());
    try std.testing.expectEqual(@as(u64, 'b'), try extension.scalarU64(
        "SELECT unicode(substr(title,1,1)) FROM tasks WHERE id=1;",
    ));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 2, 4_000);
    try request.writeU64(1);
    try request.lengthPrefixed(&over_limit);
    try expectRequestError(&extension, error.InvalidTitle, task_rename_command, request.list.items);
    try std.testing.expectEqual(@as(u64, 2), try extension.currentRevision());
    try std.testing.expectEqual(@as(u64, 'b'), try extension.scalarU64(
        "SELECT unicode(substr(title,1,1)) FROM tasks WHERE id=1;",
    ));
}

test "existing v1 schema fails closed when the required live-session index is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });
    try extension.exec("DROP INDEX one_live_focus_session;");
    try extension.stopModule(.{ .platform_name = "macos" });
    try std.testing.expectError(
        error.CorruptDatabase,
        extension.startModule(.{ .platform_name = "macos" }),
    );
    try std.testing.expect(extension.db == null);
}

test "v1 schema rejects user-defined triggers and views" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    // The canonical v1 schema has neither kind of programmable object.
    try extension.validateSchema();
    try extension.exec(
        \\CREATE TRIGGER hostile_task_insert AFTER INSERT ON tasks
        \\BEGIN
        \\  DELETE FROM tasks WHERE id=NEW.id;
        \\END;
    );
    try std.testing.expectError(error.CorruptDatabase, extension.validateSchema());

    try extension.exec("DROP TRIGGER hostile_task_insert;");
    try extension.validateSchema();
    try extension.exec("CREATE VIEW hostile_task_view AS SELECT id,title FROM tasks;");
    try std.testing.expectError(error.CorruptDatabase, extension.validateSchema());
}

test "v1 schema requires parsed focus-session foreign-key metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    // Canonical v1 exposes exactly the expected parsed relation.
    try std.testing.expect(try extension.hasCanonicalFocusSessionForeignKey());
    try extension.validateSchema();

    // Rebuild a byte-for-byte-shaped table without the FK. The old textual
    // validator can still find the required phrase in this SQL comment, but
    // SQLite's parsed foreign-key list is empty and must fail closed.
    try extension.exec(
        \\PRAGMA foreign_keys=OFF;
        \\DROP TABLE focus_sessions;
        \\CREATE TABLE focus_sessions(
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  task_id INTEGER,
        \\  -- task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL
        \\  mode INTEGER NOT NULL CHECK(mode IN (0,1,2)),
        \\  state INTEGER NOT NULL CHECK(state IN (0,1,2,3)),
        \\  completion_reason INTEGER NOT NULL DEFAULT 0 CHECK(completion_reason IN (0,1,2,3)),
        \\  live_slot INTEGER CHECK(live_slot IS NULL OR live_slot=1),
        \\  started_ms INTEGER NOT NULL CHECK(started_ms>=0),
        \\  last_transition_ms INTEGER NOT NULL CHECK(last_transition_ms>=0),
        \\  ends_ms INTEGER NOT NULL DEFAULT 0 CHECK(ends_ms>=0),
        \\  remaining_ms INTEGER NOT NULL CHECK(remaining_ms>=0),
        \\  planned_ms INTEGER NOT NULL CHECK(planned_ms>0),
        \\  focused_ms INTEGER NOT NULL DEFAULT 0 CHECK(focused_ms>=0),
        \\  ended_ms INTEGER NOT NULL DEFAULT 0 CHECK(ended_ms>=0),
        \\  CHECK((state IN (0,1) AND live_slot=1) OR (state IN (2,3) AND live_slot IS NULL))
        \\);
        \\CREATE UNIQUE INDEX one_live_focus_session ON focus_sessions(live_slot) WHERE live_slot=1;
        \\CREATE INDEX focus_sessions_history ON focus_sessions(state,ended_ms DESC,id DESC);
        \\PRAGMA foreign_keys=ON;
    );
    try std.testing.expect(try extension.schemaObjectContains(
        "table",
        "focus_sessions",
        "task_idintegerreferencestasks(id)ondeletesetnull",
    ));
    try std.testing.expect(!try extension.hasCanonicalFocusSessionForeignKey());
    try std.testing.expectError(error.CorruptDatabase, extension.validateSchema());
}

test "future schema versions are never opened as v1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });
    try extension.exec("PRAGMA user_version=2;");
    try extension.stopModule(.{ .platform_name = "macos" });
    try std.testing.expectError(
        error.UnsupportedSchema,
        extension.startModule(.{ .platform_name = "macos" }),
    );
    try std.testing.expect(extension.db == null);
}

test "semantic validation rejects corrupt metadata tasks and sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    try extension.exec(
        \\INSERT INTO tasks(id,title,state,sort_order,estimate_min,created_ms,updated_ms,completed_ms)
        \\VALUES(5,'Valid task',0,0,25,1,1,0);
        \\UPDATE app_meta SET next_task_id=5 WHERE id=1;
    );
    try std.testing.expectError(error.CorruptDatabase, extension.validateSchema());
    try extension.exec("UPDATE app_meta SET next_task_id=6 WHERE id=1;");
    try extension.validateSchema();

    try extension.exec(
        \\PRAGMA ignore_check_constraints=ON;
        \\UPDATE tasks SET state=9 WHERE id=5;
        \\PRAGMA ignore_check_constraints=OFF;
    );
    try std.testing.expectError(error.CorruptDatabase, extension.validateSchema());
    try extension.exec(
        \\PRAGMA ignore_check_constraints=ON;
        \\UPDATE tasks SET state=0 WHERE id=5;
        \\INSERT INTO focus_sessions(task_id,mode,state,completion_reason,live_slot,started_ms,last_transition_ms,ends_ms,remaining_ms,planned_ms,focused_ms,ended_ms)
        \\VALUES(NULL,9,0,0,1,1,1,1001,1000,1000,0,0);
        \\PRAGMA ignore_check_constraints=OFF;
    );
    try std.testing.expectError(error.CorruptDatabase, extension.validateSchema());
    try extension.exec("DELETE FROM focus_sessions;");
    try extension.validateSchema();

    try extension.exec(
        \\PRAGMA ignore_check_constraints=ON;
        \\INSERT INTO focus_sessions(task_id,mode,state,completion_reason,live_slot,started_ms,last_transition_ms,ends_ms,remaining_ms,planned_ms,focused_ms,ended_ms)
        \\VALUES(NULL,0,0,0,NULL,1,1,1001,1000,1000,0,0);
        \\PRAGMA ignore_check_constraints=OFF;
    );
    try std.testing.expectError(error.CorruptDatabase, extension.validateSchema());
}

test "clock rollback pauses atomically and resume rebases from current time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    var request = Writer.init(std.testing.allocator);
    defer request.deinit();
    try appendMutationHeader(&request, 0, 10_000);
    try request.writeU64(0);
    try request.writeU8(0);
    try request.writeU64(10_000);
    extension.freeResponse(try extension.handleRequest(timer_start_command, request.list.items));

    request.list.clearRetainingCapacity();
    try appendLoadRequest(&request, 9_000);
    const paused = try extension.handleRequest(load_command, request.list.items);
    defer extension.freeResponse(paused);
    try std.testing.expect((try probeSnapshot(paused)).active);
    try std.testing.expectEqual(@as(u64, 2), try extension.currentRevision());
    try std.testing.expectEqual(@as(u64, 1), try extension.scalarU64("SELECT state FROM focus_sessions WHERE id=1;"));
    try std.testing.expectEqual(@as(u64, 0), try extension.scalarU64("SELECT ends_ms FROM focus_sessions WHERE id=1;"));
    try std.testing.expectEqual(@as(u64, 10_000), try extension.scalarU64("SELECT remaining_ms FROM focus_sessions WHERE id=1;"));
    try std.testing.expectEqual(@as(u64, 9_000), try extension.scalarU64("SELECT last_transition_ms FROM focus_sessions WHERE id=1;"));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 2, 8_000);
    try request.writeU64(1);
    extension.freeResponse(try extension.handleRequest(timer_resume_command, request.list.items));
    try std.testing.expectEqual(@as(u64, 8_000), try extension.scalarU64("SELECT last_transition_ms FROM focus_sessions WHERE id=1;"));
    try std.testing.expectEqual(@as(u64, 18_000), try extension.scalarU64("SELECT ends_ms FROM focus_sessions WHERE id=1;"));

    request.list.clearRetainingCapacity();
    try appendLoadRequest(&request, 18_500);
    const recovered = try extension.handleRequest(load_command, request.list.items);
    defer extension.freeResponse(recovered);
    const recovered_probe = try probeSnapshot(recovered);
    try std.testing.expect(!recovered_probe.active);
    try std.testing.expectEqual(@as(u64, 18_000), try extension.scalarU64("SELECT ended_ms FROM focus_sessions WHERE id=1;"));
    try std.testing.expectEqual(@as(u64, 10_000), try extension.scalarU64("SELECT focused_ms FROM focus_sessions WHERE id=1;"));
}

test "late manual completion is attributed to the deadline day across local midnight" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try extension.startModule(.{ .platform_name = "macos" });

    const reference_ms: u64 = 1_700_000_000_000;
    const next_local_midnight_ms = try extension.scalarU64At(
        "SELECT CAST(strftime('%s',date(?1/1000,'unixepoch','localtime','+1 day'),'utc') AS INTEGER)*1000;",
        reference_ms,
    );
    const started_ms = next_local_midnight_ms - 2_000;
    const deadline_ms = next_local_midnight_ms - 1_000;
    const clicked_ms = next_local_midnight_ms + 1_000;

    var request = Writer.init(std.testing.allocator);
    defer request.deinit();
    try appendMutationHeader(&request, 0, started_ms);
    try request.writeU64(0);
    try request.writeU8(0);
    try request.writeU64(1_000);
    extension.freeResponse(try extension.handleRequest(timer_start_command, request.list.items));

    request.list.clearRetainingCapacity();
    try appendMutationHeader(&request, 1, clicked_ms);
    try request.writeU64(1);
    try request.writeU8(1); // UI attempted a manual completion.
    const completed = try extension.handleRequest(timer_complete_command, request.list.items);
    defer extension.freeResponse(completed);
    const probe = try probeSnapshot(completed);

    try std.testing.expectEqual(deadline_ms, try extension.scalarU64("SELECT ended_ms FROM focus_sessions WHERE id=1;"));
    try std.testing.expectEqual(@as(u64, 1), try extension.scalarU64("SELECT completion_reason FROM focus_sessions WHERE id=1;"));
    try std.testing.expectEqual(@as(u64, 0), probe.today_focus_ms);
    try std.testing.expectEqual(@as(u32, 0), probe.today_session_count);
    try std.testing.expectEqual(@as(u64, 1_000), try extension.focusForDayOffset(1, clicked_ms));
}

test "busy lock is bounded and a released database can be retried" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var holder = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer holder.deinit();
    var contender = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer contender.deinit();
    try holder.startModule(.{ .platform_name = "macos" });
    try contender.startModule(.{ .platform_name = "macos" });

    try holder.beginImmediate();
    try std.testing.expectError(error.SqliteFailure, contender.beginImmediate());
    try std.testing.expect(std.mem.indexOf(u8, contender.errorBytes(error.SqliteFailure), "locked") != null);
    holder.rollback();

    // A user retry after the other writer commits/releases must proceed.
    try contender.beginImmediate();
    contender.rollback();
}

test "module lifecycle is idempotent and requests lazy-start after stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try testDataDir(&tmp, &path_buffer);
    var extension = try SqliteExtension.init(std.testing.allocator, std.testing.io, data_dir);
    defer extension.deinit();
    try std.testing.expect(extension.db == null);
    try std.testing.expectEqualStrings("focus-sqlite", extension.module().info.name);

    var request = Writer.init(std.testing.allocator);
    defer request.deinit();
    try appendLoadRequest(&request, 1_000);
    extension.freeResponse(try extension.handleRequest(load_command, request.list.items));
    try std.testing.expect(extension.db != null);
    try extension.startModule(.{ .platform_name = "macos" });
    try extension.stopModule(.{ .platform_name = "macos" });
    try extension.stopModule(.{ .platform_name = "macos" });
    try std.testing.expect(extension.db == null);

    extension.freeResponse(try extension.handleRequest(load_command, request.list.items));
    try std.testing.expect(extension.db != null);
}

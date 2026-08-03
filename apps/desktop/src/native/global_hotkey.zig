//! Carbon-backed global Quick Focus shortcut for macOS.
//!
//! `RegisterEventHotKey` works while Focus Tracker is inactive and does not
//! require Accessibility or Input Monitoring permission. Registrations are
//! exclusive so a rejected candidate can be rolled back without disturbing
//! the shortcut that is already active.

const std = @import("std");

const OSStatus = i32;
const EventTargetRef = ?*anyopaque;
const EventHandlerRef = ?*anyopaque;
const EventHandlerCallRef = ?*anyopaque;
const EventRef = ?*anyopaque;
const EventHotKeyRef = ?*anyopaque;

const EventHotKeyID = extern struct {
    signature: u32,
    id: u32,
};

const EventTypeSpec = extern struct {
    event_class: u32,
    event_kind: u32,
};

const EventHandler = *const fn (EventHandlerCallRef, EventRef, ?*anyopaque) callconv(.c) OSStatus;

extern fn GetApplicationEventTarget() EventTargetRef;
extern fn InstallEventHandler(EventTargetRef, EventHandler, usize, [*]const EventTypeSpec, ?*anyopaque, *EventHandlerRef) OSStatus;
extern fn RemoveEventHandler(EventHandlerRef) OSStatus;
extern fn RegisterEventHotKey(u32, u32, EventHotKeyID, EventTargetRef, u32, *EventHotKeyRef) OSStatus;
extern fn UnregisterEventHotKey(EventHotKeyRef) OSStatus;
extern fn GetEventParameter(EventRef, u32, u32, ?*u32, usize, ?*usize, *anyopaque) OSStatus;

const no_err: OSStatus = 0;
const event_not_handled_err: OSStatus = -9874;
const event_class_keyboard: u32 = 0x6b657962; // 'keyb'
const event_hot_key_pressed: u32 = 5;
const event_param_direct_object: u32 = 0x2d2d2d2d; // '----'
const type_event_hot_key_id: u32 = 0x686b6964; // 'hkid'
const event_hot_key_exclusive: u32 = 1;
const app_signature: u32 = 0x46435452; // 'FCTR'

const command_key: u32 = 1 << 8;
const shift_key: u32 = 1 << 9;
const option_key: u32 = 1 << 11;
const control_key: u32 = 1 << 12;

pub const Key = enum {
    f,
    q,
    k,
    t,
    p,
    space,
};

pub const Modifiers = enum {
    command_shift,
    command_option,
    control_shift,
    control_option,
    command_control,
    command_control_shift,
};

pub const Config = struct {
    enabled: bool,
    key: Key,
    modifiers: Modifiers,

    pub fn eql(a: Config, b: Config) bool {
        return a.enabled == b.enabled and a.key == b.key and a.modifiers == b.modifiers;
    }
};

pub fn carbonKeyCode(key: Key) u32 {
    return switch (key) {
        .f => 0x03,
        .q => 0x0c,
        .k => 0x28,
        .t => 0x11,
        .p => 0x23,
        .space => 0x31,
    };
}

pub fn carbonModifiers(modifiers: Modifiers) u32 {
    return switch (modifiers) {
        .command_shift => command_key | shift_key,
        .command_option => command_key | option_key,
        .control_shift => control_key | shift_key,
        .control_option => control_key | option_key,
        .command_control => command_key | control_key,
        .command_control_shift => command_key | control_key | shift_key,
    };
}

pub const Manager = struct {
    const DispatchFn = *const fn (?*anyopaque) void;

    handler_ref: EventHandlerRef = null,
    target: EventTargetRef = null,
    active_ref: EventHotKeyRef = null,
    active_id: u32 = 0,
    active_config: ?Config = null,
    staged_ref: EventHotKeyRef = null,
    staged_id: u32 = 0,
    staged_config: ?Config = null,
    staged_reuses_active: bool = false,
    retired_refs: [4]EventHotKeyRef = @splat(null),
    retired_count: usize = 0,
    next_id: u32 = 1,
    dispatch_context: ?*anyopaque = null,
    dispatch_fn: ?DispatchFn = null,

    pub fn install(self: *Manager, context: ?*anyopaque, dispatch_fn: DispatchFn) !void {
        if (self.handler_ref != null) return;
        self.dispatch_context = context;
        self.dispatch_fn = dispatch_fn;
        const target = GetApplicationEventTarget() orelse {
            self.dispatch_context = null;
            self.dispatch_fn = null;
            return error.HotKeyHandlerUnavailable;
        };
        self.target = target;
        const event_types = [_]EventTypeSpec{.{
            .event_class = event_class_keyboard,
            .event_kind = event_hot_key_pressed,
        }};
        const status = InstallEventHandler(
            target,
            eventHandler,
            event_types.len,
            &event_types,
            self,
            &self.handler_ref,
        );
        if (status != no_err or self.handler_ref == null) {
            self.dispatch_context = null;
            self.dispatch_fn = null;
            self.target = null;
            return error.HotKeyHandlerUnavailable;
        }
    }

    /// Register a candidate without touching the committed registration.
    /// Only the active ID dispatches; the staged ID remains inert until DB OK.
    pub fn stage(self: *Manager, config: Config) !void {
        self.rollbackStage();
        self.staged_config = config;
        if (self.activeMatches(config)) {
            self.staged_reuses_active = true;
            return;
        }
        if (!config.enabled) return;

        const target = self.target orelse {
            self.staged_config = null;
            return error.HotKeyHandlerUnavailable;
        };
        const id = self.allocateId();
        var hot_key_ref: EventHotKeyRef = null;
        const status = RegisterEventHotKey(
            carbonKeyCode(config.key),
            carbonModifiers(config.modifiers),
            .{ .signature = app_signature, .id = id },
            target,
            event_hot_key_exclusive,
            &hot_key_ref,
        );
        if (status != no_err or hot_key_ref == null) {
            self.staged_config = null;
            return error.HotKeyUnavailable;
        }
        self.staged_ref = hot_key_ref;
        self.staged_id = id;
    }

    pub fn stagedMatches(self: *const Manager, config: Config) bool {
        const staged = self.staged_config orelse return false;
        return Config.eql(staged, config);
    }

    pub fn activeMatches(self: *const Manager, config: Config) bool {
        const active = self.active_config orelse return false;
        if (!Config.eql(active, config)) return false;
        return !config.enabled or self.active_ref != null;
    }

    pub fn hasStage(self: *const Manager) bool {
        return self.staged_config != null;
    }

    pub fn promote(self: *Manager) void {
        const config = self.staged_config orelse return;
        if (self.staged_reuses_active) {
            self.staged_config = null;
            self.staged_reuses_active = false;
            return;
        }
        self.release(self.active_ref);
        self.active_ref = self.staged_ref;
        self.active_id = self.staged_id;
        self.active_config = config;
        self.staged_ref = null;
        self.staged_id = 0;
        self.staged_config = null;
        self.staged_reuses_active = false;
    }

    pub fn replaceCommitted(self: *Manager, config: Config) !void {
        if (self.activeMatches(config)) return;
        try self.stage(config);
        self.promote();
    }

    pub fn rollbackStage(self: *Manager) void {
        self.release(self.staged_ref);
        self.staged_ref = null;
        self.staged_id = 0;
        self.staged_config = null;
        self.staged_reuses_active = false;
    }

    pub fn stop(self: *Manager) void {
        self.rollbackStage();
        self.release(self.active_ref);
        self.active_ref = null;
        self.active_id = 0;
        self.active_config = null;
        for (self.retired_refs[0..self.retired_count]) |reference| unregister(reference);
        self.retired_refs = @splat(null);
        self.retired_count = 0;
        if (self.handler_ref) |handler| _ = RemoveEventHandler(handler);
        self.handler_ref = null;
        self.target = null;
        self.dispatch_context = null;
        self.dispatch_fn = null;
    }

    fn allocateId(self: *Manager) u32 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return id;
    }

    fn release(self: *Manager, reference: EventHotKeyRef) void {
        const hot_key = reference orelse return;
        if (UnregisterEventHotKey(hot_key) == no_err) return;
        // Keep a failed unregister reachable so stop can retry it. The active
        // ID has already moved, therefore an old event can never dispatch.
        if (self.retired_count < self.retired_refs.len) {
            self.retired_refs[self.retired_count] = hot_key;
            self.retired_count += 1;
        }
    }

    fn dispatchActiveId(self: *Manager, id: EventHotKeyID) bool {
        if (id.signature != app_signature or id.id == 0 or id.id != self.active_id) return false;
        const dispatch = self.dispatch_fn orelse return false;
        dispatch(self.dispatch_context);
        return true;
    }

    fn eventHandler(_: EventHandlerCallRef, event: EventRef, user_data: ?*anyopaque) callconv(.c) OSStatus {
        const raw = user_data orelse return event_not_handled_err;
        const self: *Manager = @ptrCast(@alignCast(raw));
        var id: EventHotKeyID = undefined;
        const status = GetEventParameter(
            event,
            event_param_direct_object,
            type_event_hot_key_id,
            null,
            @sizeOf(EventHotKeyID),
            null,
            &id,
        );
        if (status != no_err) return status;
        return if (self.dispatchActiveId(id)) no_err else event_not_handled_err;
    }
};

fn unregister(reference: EventHotKeyRef) void {
    if (reference) |hot_key| _ = UnregisterEventHotKey(hot_key);
}

test "supported keys map to stable macOS virtual key codes" {
    try std.testing.expectEqual(@as(u32, 0x03), carbonKeyCode(.f));
    try std.testing.expectEqual(@as(u32, 0x0c), carbonKeyCode(.q));
    try std.testing.expectEqual(@as(u32, 0x28), carbonKeyCode(.k));
    try std.testing.expectEqual(@as(u32, 0x11), carbonKeyCode(.t));
    try std.testing.expectEqual(@as(u32, 0x23), carbonKeyCode(.p));
    try std.testing.expectEqual(@as(u32, 0x31), carbonKeyCode(.space));
}

test "modifier presets always include command or control" {
    inline for (std.meta.tags(Modifiers)) |modifiers| {
        const mask = carbonModifiers(modifiers);
        try std.testing.expect(mask & (command_key | control_key) != 0);
        try std.testing.expect(@popCount(mask) >= 2);
    }
}

test "only the committed event ID dispatches" {
    const Counter = struct {
        count: usize = 0,
        fn increment(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.count += 1;
        }
    };
    var counter = Counter{};
    var manager = Manager{
        .active_id = 7,
        .staged_id = 8,
        .dispatch_context = &counter,
        .dispatch_fn = Counter.increment,
    };
    try std.testing.expect(!manager.dispatchActiveId(.{ .signature = app_signature, .id = 8 }));
    try std.testing.expect(!manager.dispatchActiveId(.{ .signature = 0, .id = 7 }));
    try std.testing.expect(manager.dispatchActiveId(.{ .signature = app_signature, .id = 7 }));
    try std.testing.expectEqual(@as(usize, 1), counter.count);
}

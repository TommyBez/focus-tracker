import { Cmd, Sub, asciiBytes } from "@native-sdk/core";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";
import {
  type AudioState,
  type ChromeButtons,
  type ChromeInsets,
  type ColorScheme,
  type KeyEvent,
} from "@native-sdk/core/events";
import {
  decodeSnapshot,
  encodeLoad,
  encodeSettings,
  encodeTaskCreate,
  encodeTaskPurge,
  encodeTaskRename,
  encodeTaskState,
  encodeTaskUndoArchive,
  encodeTimerComplete,
  encodeTimerSession,
  encodeTimerStart,
  type Bytes,
  type DbSession,
  type DbSettings,
  type DbStats,
  type DbTask,
  type SessionMode,
  type TaskState,
} from "./protocol.ts";

export type LoadState = "loading" | "ready" | "fatal";
export type Section = "today" | "ledger";
export type TaskFilter = "open" | "completed" | "archived";
export type SessionViewState = "idle" | "running" | "paused" | "complete";
export type HistoryTone = "primary" | "secondary" | "default";
export type DialogSurface = "main" | "quick";
export type FocusRecoveryKind =
  | "none"
  | "composer_pending"
  | "composer"
  | "task_row"
  | "task_filter"
  | "purge_trigger";
export type PendingKind =
  | "none"
  | "load"
  | "refresh"
  | "task_create"
  | "task_rename"
  | "task_state"
  | "task_archive"
  | "task_restore"
  | "task_undo_archive"
  | "task_purge"
  | "settings"
  | "timer_start"
  | "timer_pause"
  | "timer_resume"
  | "timer_complete_natural"
  | "timer_complete_manual"
  | "timer_cancel"
  | "task_after_focus";

export interface TaskRow {
  readonly id: number;
  readonly title: Bytes;
  readonly done: boolean;
  readonly archived: boolean;
  readonly autofocus: boolean;
  readonly purgeAutofocus: boolean;
  readonly toggleLabel: Bytes;
  readonly focusLabel: Bytes;
  readonly renameLabel: Bytes;
  readonly cancelRenameLabel: Bytes;
  readonly saveRenameLabel: Bytes;
  readonly archiveLabel: Bytes;
  readonly restoreLabel: Bytes;
  readonly purgeLabel: Bytes;
}

export interface WeekDayRow {
  readonly id: number;
  readonly label: Bytes;
  readonly valueText: Bytes;
  readonly accessibilityLabel: Bytes;
  readonly today: boolean;
}

export interface HistoryRow {
  readonly id: number;
  readonly taskTitle: Bytes;
  readonly durationLabel: Bytes;
  readonly meta: Bytes;
  readonly tone: HistoryTone;
  readonly connector: boolean;
}

export interface QuickTaskRow {
  readonly id: number;
  readonly title: Bytes;
  readonly selected: boolean;
  readonly accessibilityLabel: Bytes;
}

export interface Model {
  readonly chromeLeading: number;
  readonly headerHeight: number;
  readonly colorScheme: ColorScheme;
  readonly reduceMotion: boolean;
  readonly highContrast: boolean;
  readonly section: Section;
  readonly loadState: LoadState;
  readonly fatalErrorText: Bytes;
  readonly hasWriteError: boolean;
  readonly writeErrorText: Bytes;
  readonly saving: boolean;
  readonly revision: number;
  readonly settings: DbSettings;
  readonly tasks: readonly DbTask[];
  readonly activeSession: DbSession | null;
  readonly recentSessions: readonly DbSession[];
  readonly stats: DbStats;
  readonly taskDraftEditor: TextEditState;
  readonly composerKey: number;
  readonly startAutofocus: boolean;
  readonly mainStartFocusEpoch: number;
  readonly quickStartFocusEpoch: number;
  readonly transportAutofocus: boolean;
  readonly taskFilter: TaskFilter;
  readonly selectedTaskId: number;
  readonly actionTaskId: number;
  readonly taskActionsTaskId: number;
  readonly editTaskId: number;
  readonly editDraftEditor: TextEditState;
  readonly editAutofocus: boolean;
  readonly editFocusEpoch: number;
  readonly paneFraction: number;
  readonly settingsWindowOpen: boolean;
  readonly quickWindowOpen: boolean;
  readonly purgeDialogOpen: boolean;
  readonly purgeAutofocus: boolean;
  readonly purgeFocusEpoch: number;
  readonly purgeTaskId: number;
  readonly focusRecoveryKind: FocusRecoveryKind;
  readonly focusRecoveryTaskId: number;
  readonly endDialogOpen: boolean;
  readonly completionDialogOpen: boolean;
  readonly breakAcknowledgementOpen: boolean;
  readonly dialogSurface: DialogSurface;
  readonly pendingKind: PendingKind;
  readonly pendingTitle: Bytes;
  readonly pendingTaskId: number;
  readonly pendingTaskState: TaskState;
  readonly pendingMode: SessionMode;
  readonly pendingDurationMinutes: number;
  readonly pendingSettings: DbSettings;
  readonly pendingNowMs: number;
  readonly pendingClockRollback: boolean;
  readonly pendingNeedsFreshSnapshot: boolean;
  readonly retryPayload: Bytes;
  readonly undoTaskId: number;
  readonly undoTaskTitle: Bytes;
  readonly undoTaskState: TaskState;
  readonly completionTaskId: number;
  readonly completionSessionId: number;
  readonly nowMs: number;
}

export type Msg =
  | { readonly kind: "show_today" }
  | { readonly kind: "show_ledger" }
  | { readonly kind: "task_draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "add_task" }
  | { readonly kind: "select_task"; readonly id: number }
  | { readonly kind: "toggle_task_actions"; readonly id: number }
  | { readonly kind: "dismiss_task_actions" }
  | { readonly kind: "toggle_task"; readonly id: number }
  | { readonly kind: "start_focus_task"; readonly id: number }
  | { readonly kind: "begin_rename"; readonly id: number }
  | { readonly kind: "edit_draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "commit_rename" }
  | { readonly kind: "cancel_rename" }
  | { readonly kind: "delete_task"; readonly id: number }
  | { readonly kind: "show_open_tasks" }
  | { readonly kind: "show_completed_tasks" }
  | { readonly kind: "show_archived_tasks" }
  | { readonly kind: "restore_task"; readonly id: number }
  | { readonly kind: "request_purge_task"; readonly id: number }
  | { readonly kind: "cancel_purge_task" }
  | { readonly kind: "confirm_purge_task" }
  | { readonly kind: "undo_delete" }
  | { readonly kind: "dismiss_undo" }
  | { readonly kind: "set_duration_25" }
  | { readonly kind: "set_duration_50" }
  | { readonly kind: "set_duration_90" }
  | { readonly kind: "start_focus" }
  | { readonly kind: "pause_focus" }
  | { readonly kind: "resume_focus" }
  | { readonly kind: "request_end_focus" }
  | { readonly kind: "finish_focus_now" }
  | { readonly kind: "confirm_end_focus" }
  | { readonly kind: "cancel_end_focus" }
  | { readonly kind: "complete_task_after_focus" }
  | { readonly kind: "keep_task_open_after_focus" }
  | { readonly kind: "start_break" }
  | { readonly kind: "dismiss_break_acknowledgement" }
  | { readonly kind: "open_settings" }
  | { readonly kind: "raise_settings"; readonly at: number }
  | { readonly kind: "close_settings" }
  | { readonly kind: "open_quick" }
  | { readonly kind: "raise_quick"; readonly at: number }
  | { readonly kind: "close_quick" }
  | { readonly kind: "open_full_app" }
  | { readonly kind: "select_quick_task"; readonly id: number }
  | { readonly kind: "request_quick_end_focus" }
  | { readonly kind: "open_quick_end" }
  | { readonly kind: "set_short_break_5" }
  | { readonly kind: "set_short_break_10" }
  | { readonly kind: "set_short_break_15" }
  | { readonly kind: "set_long_break_15" }
  | { readonly kind: "set_long_break_20" }
  | { readonly kind: "set_long_break_30" }
  | { readonly kind: "set_daily_goal_60" }
  | { readonly kind: "set_daily_goal_120" }
  | { readonly kind: "set_daily_goal_180" }
  | { readonly kind: "toggle_sound" }
  | { readonly kind: "retry_save" }
  | { readonly kind: "discard_failed_change" }
  | { readonly kind: "retry_boot" }
  | { readonly kind: "quit_app" }
  | { readonly kind: "pane_resized"; readonly fraction: number }
  | { readonly kind: "new_task_command" }
  | { readonly kind: "today_command" }
  | { readonly kind: "ledger_command" }
  | { readonly kind: "toggle_focus_command" }
  | { readonly kind: "quick_toggle_command" }
  | { readonly kind: "quit_command" }
  | { readonly kind: "show_window" }
  | { readonly kind: "escape_pressed" }
  | { readonly kind: "escape_main_pressed" }
  | { readonly kind: "escape_quick_pressed" }
  | { readonly kind: "escape_settings_pressed" }
  | { readonly kind: "arm_composer_autofocus"; readonly at: number }
  | { readonly kind: "arm_start_autofocus"; readonly at: number }
  | { readonly kind: "arm_transport_autofocus"; readonly at: number }
  | { readonly kind: "arm_purge_autofocus"; readonly at: number }
  | { readonly kind: "arm_edit_autofocus"; readonly at: number }
  | { readonly kind: "boot_ready"; readonly at: number }
  | { readonly kind: "intent_now"; readonly at: number }
  | { readonly kind: "reload_now"; readonly at: number }
  | { readonly kind: "refresh_now"; readonly at: number }
  | { readonly kind: "db_ok"; readonly body: Bytes }
  | { readonly kind: "db_err"; readonly error: Bytes }
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "focus_due"; readonly at: number }
  | {
      readonly kind: "completion_sound_event";
      readonly state: AudioState;
      readonly positionMs: number;
      readonly durationMs: number;
      readonly playing: boolean;
      readonly buffering: boolean;
      readonly bands: Bytes;
    }
  | {
      readonly kind: "chrome_changed";
      readonly insets: ChromeInsets;
      readonly buttons: ChromeButtons;
      readonly tabsProjected: boolean;
    }
  | {
      readonly kind: "appearance_changed";
      readonly colorScheme: ColorScheme;
      readonly reduceMotion: boolean;
      readonly highContrast: boolean;
    };

export const chromeMsg = "chrome_changed";
export const appearanceMsg = "appearance_changed";

export const viewUnbound = [
  "revision",
  "settings",
  "tasks",
  "activeSession",
  "recentSessions",
  "stats",
  "settingsWindowOpen",
  "quickWindowOpen",
  "selectedTaskId",
  "endDialogOpen",
  "completionDialogOpen",
  "dialogSurface",
  "taskDraftEditor",
  "editDraftEditor",
  "mainStartFocusEpoch",
  "quickStartFocusEpoch",
  "editFocusEpoch",
  "purgeFocusEpoch",
  "focusRecoveryTaskId",
  "purgeTaskId",
  "pendingKind",
  "pendingTitle",
  "pendingTaskId",
  "pendingTaskState",
  "pendingMode",
  "pendingDurationMinutes",
  "pendingSettings",
  "pendingNowMs",
  "pendingClockRollback",
  "pendingNeedsFreshSnapshot",
  "retryPayload",
  "undoTaskId",
  "undoTaskTitle",
  "undoTaskState",
  "completionTaskId",
  "completionSessionId",
  "nowMs",
  "colorScheme",
  "reduceMotion",
  "highContrast",
  "open_settings",
  "raise_settings",
  "close_settings",
  "open_quick",
  "raise_quick",
  "close_quick",
  "open_full_app",
  "open_quick_end",
  "quickSelectedTaskExists",
  "new_task_command",
  "today_command",
  "ledger_command",
  "toggle_focus_command",
  "quick_toggle_command",
  "quit_command",
  "show_window",
  "escape_pressed",
  "escape_main_pressed",
  "escape_quick_pressed",
  "escape_settings_pressed",
  "arm_composer_autofocus",
  "arm_start_autofocus",
  "arm_transport_autofocus",
  "arm_purge_autofocus",
  "arm_edit_autofocus",
  "boot_ready",
  "intent_now",
  "reload_now",
  "refresh_now",
  "db_ok",
  "db_err",
  "tick",
  "focus_due",
  "completion_sound_event",
  "chrome_changed",
  "appearance_changed",
] as const;

const EMPTY = asciiBytes("");
const TITLE_CAPACITY = 240;
const DEFAULT_PANE = 0.27;
const FOCUS_PANE = 0.24;
const MAX_SAFE_TIME = 9007199254740991;

function emptyEditor(): TextEditState {
  return { text: EMPTY, selection: { anchor: 0, focus: 0 }, composition: null };
}

function editorFor(text: Bytes): TextEditState {
  return {
    text: text,
    selection: { anchor: text.length, focus: text.length },
    composition: null,
  };
}

function editApplied(state: TextEditState, edit: TextInputEvent): TextEditState {
  const applied = applyTextInputEvent(state, edit, TITLE_CAPACITY);
  if (applied !== null) return applied;
  const clamped = clampedInsertEvent(state, edit, TITLE_CAPACITY);
  if (clamped === null) return state;
  return applyTextInputEvent(state, clamped, TITLE_CAPACITY) ?? state;
}

function defaultSettings(): DbSettings {
  return {
    focusMinutes: 25,
    shortBreakMinutes: 5,
    longBreakMinutes: 15,
    dailyGoalMinutes: 120,
    soundEnabled: true,
  };
}

function emptyStats(): DbStats {
  return {
    todayFocusMs: 0,
    todayCompletedSessions: 0,
    todayCompletedTasks: 0,
    todayWeekday: 0,
    weekFocusMs: [
      { milliseconds: 0 },
      { milliseconds: 0 },
      { milliseconds: 0 },
      { milliseconds: 0 },
      { milliseconds: 0 },
      { milliseconds: 0 },
      { milliseconds: 0 },
    ],
  };
}

function baseModel(): Model {
  return {
    chromeLeading: 70,
    headerHeight: 52,
    colorScheme: "light",
    reduceMotion: false,
    highContrast: false,
    section: "today",
    loadState: "loading",
    fatalErrorText: asciiBytes("Preparing your local focus ledger."),
    hasWriteError: false,
    writeErrorText: EMPTY,
    saving: false,
    revision: 0,
    settings: defaultSettings(),
    tasks: [],
    activeSession: null,
    recentSessions: [],
    stats: emptyStats(),
    taskDraftEditor: emptyEditor(),
    composerKey: 1,
    startAutofocus: true,
    mainStartFocusEpoch: 1,
    quickStartFocusEpoch: 1,
    transportAutofocus: true,
    taskFilter: "open",
    selectedTaskId: -1,
    actionTaskId: -1,
    taskActionsTaskId: -1,
    editTaskId: -1,
    editDraftEditor: emptyEditor(),
    editAutofocus: false,
    editFocusEpoch: 1,
    paneFraction: DEFAULT_PANE,
    settingsWindowOpen: false,
    quickWindowOpen: false,
    purgeDialogOpen: false,
    purgeAutofocus: false,
    purgeFocusEpoch: 1,
    purgeTaskId: 0,
    focusRecoveryKind: "none",
    focusRecoveryTaskId: -1,
    endDialogOpen: false,
    completionDialogOpen: false,
    breakAcknowledgementOpen: false,
    dialogSurface: "main",
    pendingKind: "load",
    pendingTitle: EMPTY,
    pendingTaskId: 0,
    pendingTaskState: "open",
    pendingMode: "focus",
    pendingDurationMinutes: 25,
    pendingSettings: defaultSettings(),
    pendingNowMs: 0,
    pendingClockRollback: false,
    pendingNeedsFreshSnapshot: false,
    retryPayload: EMPTY,
    undoTaskId: 0,
    undoTaskTitle: EMPTY,
    undoTaskState: "open",
    completionTaskId: 0,
    completionSessionId: 0,
    nowMs: 0,
  };
}

export function initialModel(): [Model, Cmd<Msg>] {
  return [baseModel(), Cmd.delay("db-bootstrap", 24, "boot_ready")];
}

function intDiv(n: number, d: number): number {
  let q = 0;
  let r = n;
  while (r >= d) {
    let step = d;
    let count = 1;
    while (step + step <= r) {
      step += step;
      count += count;
    }
    r -= step;
    q += count;
  }
  return q;
}

function concat2(a: Bytes, b: Bytes): Bytes {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

function concat3(a: Bytes, b: Bytes, c: Bytes): Bytes {
  const out = new Uint8Array(a.length + b.length + c.length);
  out.set(a, 0);
  out.set(b, a.length);
  out.set(c, a.length + b.length);
  return out;
}

function bytesEqual(a: Bytes, b: Bytes): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function exactAscii(value: Bytes, expected: Bytes): boolean {
  return value.length === expected.length && value.startsWith(expected);
}

function taskById(tasks: readonly DbTask[], id: number): DbTask | null {
  const found = tasks.find((task) => task.id === id);
  return found === undefined ? null : found;
}

function taskMatchesUndo(task: DbTask | null, priorState: TaskState): boolean {
  if (task === null || task.state !== "archived") return false;
  if (priorState === "open") return task.completedMs === 0;
  if (priorState === "completed") return task.completedMs > 0;
  return false;
}

function includesCompletedSession(sessions: readonly DbSession[], id: number): boolean {
  return sessions.some((session) => session.id === id && session.state === "completed");
}

function firstOpenTaskId(tasks: readonly DbTask[]): number {
  const sorted = tasks
    .filter((task) => task.state === "open")
    .toSorted((a, b) => a.sortOrder - b.sortOrder);
  return sorted.length === 0 ? -1 : sorted[0].id;
}

function normalizedSelectedTaskId(tasks: readonly DbTask[], selected: number): number {
  const current = taskById(tasks, selected);
  if (current !== null && current.state === "open") return selected;
  return firstOpenTaskId(tasks);
}

function firstTaskIdForFilter(tasks: readonly DbTask[], filter: TaskFilter): number {
  const sorted = tasks
    .filter((task) => task.state === filter)
    .toSorted((a, b) => a.sortOrder - b.sortOrder);
  return sorted.length === 0 ? -1 : sorted[0].id;
}

function normalizedActionTaskId(tasks: readonly DbTask[], filter: TaskFilter, selected: number): number {
  const current = taskById(tasks, selected);
  if (current !== null && current.state === filter) return selected;
  return firstTaskIdForFilter(tasks, filter);
}

function durationMs(minutes: number): number {
  return minutes * 60000;
}

function validWallNow(value: number): boolean {
  return value >= 0 && value <= MAX_SAFE_TIME;
}

function acceptedWallNow(fallback: number, incoming: number): number {
  return validWallNow(incoming) ? incoming : fallback;
}

function authoritativeNow(model: Model, session: DbSession | null, operation: PendingKind): number {
  let base = acceptedWallNow(model.nowMs, model.pendingNowMs);
  // A retry deliberately reuses the original mutation payload. Its encoded
  // timestamp can therefore be older than display ticks observed while the
  // error banner was open; that is staleness, not a wall-clock rollback.
  if (!model.pendingClockRollback && base < model.nowMs) base = model.nowMs;
  if (session === null) return base;
  if (operation === "timer_pause") return base;
  if (operation !== "timer_resume" || session.state !== "running") return base;
  const responseBase = session.endsMs >= session.remainingMs ? session.endsMs - session.remainingMs : 0;
  const acceptedResponseBase = acceptedWallNow(base, responseBase);
  base = !model.pendingClockRollback && acceptedResponseBase < model.nowMs
    ? model.nowMs
    : acceptedResponseBase;
  return base;
}

function remainingMs(model: Model): number {
  if (model.activeSession === null) return 0;
  const stored =
    model.activeSession.remainingMs < model.activeSession.plannedMs
      ? model.activeSession.remainingMs
      : model.activeSession.plannedMs;
  if (model.activeSession.state === "paused") return stored;
  if (model.nowMs >= model.activeSession.endsMs) return 0;
  const untilDeadline = model.activeSession.endsMs - model.nowMs;
  return untilDeadline < stored ? untilDeadline : stored;
}

function naturalCompletionWriteBlocked(model: Model): boolean {
  // A failed write owns the single retry slot until the user retries it. An
  // expired running session stays authoritative at 00:00; once that retry
  // commits, db_ok immediately schedules its natural completion against the
  // new revision. This prevents the deadline from erasing an unrelated retry.
  return model.hasWriteError;
}

function roundedUpSeconds(milliseconds: number): number {
  if (milliseconds <= 0) return 0;
  return intDiv(milliseconds + 999, 1000);
}

function taskTitleFor(tasks: readonly DbTask[], taskId: number): Bytes {
  if (taskId === 0) return asciiBytes("Unassigned focus block");
  const task = taskById(tasks, taskId);
  return task === null ? asciiBytes("Archived task") : task.title;
}

function modeTitle(mode: SessionMode): Bytes {
  if (mode === "short") return asciiBytes("Short break");
  if (mode === "long") return asciiBytes("Long break");
  return asciiBytes("Unassigned focus block");
}

function friendlyWriteError(error: Bytes): Bytes {
  if (exactAscii(error, asciiBytes("task_limit_reached"))) {
    return asciiBytes("The ledger is full. Permanently delete an archived task, then try again.");
  }
  if (exactAscii(error, asciiBytes("snapshot_too_large"))) {
    return asciiBytes("The local ledger has reached its safe size. Permanently delete an archived task, then try again.");
  }
  if (exactAscii(error, asciiBytes("invalid_task_state"))) {
    return asciiBytes("Only an archived task can be permanently deleted. The ledger was left unchanged.");
  }
  if (exactAscii(error, asciiBytes("undo_state_mismatch"))) {
    return asciiBytes("This archived task changed before Undo could finish. The ledger was left unchanged.");
  }
  if (exactAscii(error, asciiBytes("invalid_title"))) {
    return asciiBytes("Give this task a short, concrete title and try again.");
  }
  if (exactAscii(error, asciiBytes("timer_already_active"))) {
    return asciiBytes("Another focus block is already active. Refresh and try again.");
  }
  return concat3(asciiBytes("The change was not committed. Retry when ready ("), error, asciiBytes(")."));
}

function friendlyFatalError(error: Bytes): Bytes {
  if (exactAscii(error, asciiBytes("unsupported_schema"))) {
    return asciiBytes("This focus ledger was created by a newer version of the app.");
  }
  if (exactAscii(error, asciiBytes("corrupt_database"))) {
    return asciiBytes("The local focus ledger is damaged and could not be read safely.");
  }
  return concat3(asciiBytes("The local SQLite ledger could not be opened ("), error, asciiBytes(")."));
}

function hasBlockingSurface(model: Model): boolean {
  return (
    model.settingsWindowOpen ||
    hasBlockingDialog(model)
  );
}

function hasBlockingDialog(model: Model): boolean {
  // A completed focus block is already durable in SQLite. Its task choices
  // are an optional follow-up with "keep open" as the safe default, not a
  // modal gate. Only destructive/active-session confirmations block input.
  return model.purgeDialogOpen || model.endDialogOpen;
}

function keepCompletionTaskOpen(model: Model): Model {
  return {
    ...model,
    completionDialogOpen: false,
    breakAcknowledgementOpen: false,
    completionTaskId: 0,
    completionSessionId: 0,
    paneFraction: DEFAULT_PANE,
    composerKey: model.composerKey + 1,
  };
}

function intentModel(
  model: Model,
  kind: PendingKind,
  taskId: number,
  taskState: TaskState,
  title: Bytes,
  mode: SessionMode,
  durationMinutes: number,
): Model {
  return {
    ...model,
    transportAutofocus:
      kind === "timer_start" || kind === "timer_pause" || kind === "timer_resume"
        ? false
        : model.transportAutofocus,
    saving: true,
    hasWriteError: false,
    writeErrorText: EMPTY,
    pendingKind: kind,
    pendingTaskId: taskId,
    pendingTaskState: taskState,
    pendingTitle: title,
    pendingMode: mode,
    pendingDurationMinutes: durationMinutes,
    pendingClockRollback: false,
    pendingNeedsFreshSnapshot: false,
    retryPayload: EMPTY,
  };
}

function settingsIntentModel(model: Model, settings: DbSettings): Model {
  return {
    ...model,
    saving: true,
    hasWriteError: false,
    writeErrorText: EMPTY,
    pendingKind: "settings",
    pendingSettings: settings,
    pendingClockRollback: false,
    pendingNeedsFreshSnapshot: false,
    retryPayload: EMPTY,
  };
}

function withoutFailedWrite(model: Model): Model {
  return {
    ...model,
    saving: false,
    hasWriteError: false,
    writeErrorText: EMPTY,
    pendingKind: "none",
    pendingTitle: EMPTY,
    pendingTaskId: 0,
    pendingTaskState: "open",
    pendingMode: "focus",
    pendingDurationMinutes: 0,
    pendingSettings: model.settings,
    pendingNowMs: model.nowMs,
    pendingClockRollback: false,
    pendingNeedsFreshSnapshot: false,
    retryPayload: EMPTY,
  };
}

function eligibleTask(model: Model, id: number): boolean {
  const task = taskById(model.tasks, id);
  return task !== null && task.state === "open";
}

function withoutFocusRecovery(model: Model): Model {
  return {
    ...model,
    focusRecoveryKind: "none",
    focusRecoveryTaskId: -1,
  };
}

function withStartFocus(model: Model, surface: DialogSurface): Model {
  return {
    ...withoutFocusRecovery(model),
    startAutofocus: true,
    mainStartFocusEpoch:
      surface === "main" ? model.mainStartFocusEpoch + 1 : model.mainStartFocusEpoch,
    quickStartFocusEpoch:
      surface === "quick" ? model.quickStartFocusEpoch + 1 : model.quickStartFocusEpoch,
  };
}

function withFocusRecovery(model: Model, kind: FocusRecoveryKind, taskId: number): Model {
  return {
    ...model,
    focusRecoveryKind: kind,
    focusRecoveryTaskId: taskId,
  };
}

function withTaskRowOrFilterFocus(model: Model, taskId: number): Model {
  return taskId > 0
    ? withFocusRecovery(model, "task_row", taskId)
    : withFocusRecovery(model, "task_filter", -1);
}

export function mainStartFocusKey(model: Model): number {
  return model.mainStartFocusEpoch;
}

export function quickStartFocusKey(model: Model): number {
  return model.quickStartFocusEpoch;
}

export function editFocusKey(model: Model): number {
  return model.editFocusEpoch;
}

export function purgeFocusKey(model: Model): number {
  return model.purgeFocusEpoch;
}

function shouldAutofocusComposer(model: Model): boolean {
  return (
    !model.purgeDialogOpen &&
    (model.focusRecoveryKind === "composer" ||
      (!selectedTaskExists(model) && model.focusRecoveryKind === "none"))
  );
}

export function mainComposerAutofocus(model: Model): boolean {
  return !model.quickWindowOpen && shouldAutofocusComposer(model);
}

export function quickComposerAutofocus(model: Model): boolean {
  return model.quickWindowOpen && shouldAutofocusComposer(model);
}

export function taskDraft(model: Model): Bytes {
  return model.taskDraftEditor.text;
}

export function canAddTask(model: Model): boolean {
  return (
    model.loadState === "ready" &&
    !model.saving &&
    !model.hasWriteError &&
    model.taskDraftEditor.text.trim().length > 0
  );
}

export function editDraft(model: Model): Bytes {
  return model.editDraftEditor.text;
}

export function canCommitRename(model: Model): boolean {
  return (
    model.editTaskId > 0 &&
    !model.saving &&
    !model.hasWriteError &&
    model.editDraftEditor.text.trim().length > 0
  );
}

export function todayLabel(_model: Model): Bytes {
  return asciiBytes("A quiet ledger for today");
}

function remainingTaskCount(model: Model): number {
  return model.tasks.filter((task) => task.state === "open").length;
}

function completedTaskCount(model: Model): number {
  return model.tasks.filter((task) => task.state === "completed").length;
}

function archivedTaskCount(model: Model): number {
  return model.tasks.filter((task) => task.state === "archived").length;
}

export function filterCountText(model: Model): Bytes {
  if (model.taskFilter === "completed") {
    const count = completedTaskCount(model);
    return count === 1 ? asciiBytes("1 completed") : asciiBytes(`${count} completed`);
  }
  if (model.taskFilter === "archived") {
    const count = archivedTaskCount(model);
    return count === 1 ? asciiBytes("1 archived") : asciiBytes(`${count} archived`);
  }
  const count = remainingTaskCount(model);
  return count === 1 ? asciiBytes("1 open") : asciiBytes(`${count} open`);
}

export function visibleTasks(model: Model): readonly TaskRow[] {
  const state: TaskState = model.taskFilter;
  const tasks = model.tasks
    .filter((task) => task.state === state)
    .toSorted((a, b) => a.sortOrder - b.sortOrder);
  return tasks.map((task) => ({
    id: task.id,
    title: task.title,
    done: task.state === "completed",
    archived: task.state === "archived",
    autofocus: model.focusRecoveryKind === "task_row" && model.focusRecoveryTaskId === task.id,
    purgeAutofocus:
      model.focusRecoveryKind === "purge_trigger" && model.focusRecoveryTaskId === task.id,
    toggleLabel:
      task.state === "completed"
        ? concat2(asciiBytes("Reopen "), task.title)
        : concat3(asciiBytes("Mark "), task.title, asciiBytes(" complete")),
    focusLabel: concat2(asciiBytes("Focus on "), task.title),
    renameLabel: concat2(asciiBytes("Rename "), task.title),
    cancelRenameLabel: concat2(asciiBytes("Cancel renaming "), task.title),
    saveRenameLabel: concat2(asciiBytes("Save new name for "), task.title),
    archiveLabel: concat2(asciiBytes("Archive "), task.title),
    restoreLabel: concat2(asciiBytes("Restore "), task.title),
    purgeLabel: concat2(asciiBytes("Permanently delete "), task.title),
  }));
}

export function quickTasks(model: Model): readonly QuickTaskRow[] {
  const openTasks = model.tasks
    .filter((task) => task.state === "open")
    .toSorted((a, b) => a.sortOrder - b.sortOrder);
  const selected = openTasks.find((task) => task.id === model.selectedTaskId);
  const visible =
    selected === undefined
      ? openTasks.slice(0, 3)
      : [selected, ...openTasks.filter((task) => task.id !== selected.id).slice(0, 2)];
  return visible
    .map((task) => ({
      id: task.id,
      title: task.title,
      selected: task.id === model.selectedTaskId,
      accessibilityLabel:
        task.id === model.selectedTaskId
          ? concat3(asciiBytes("Selected focus task, "), task.title, asciiBytes(". Press to keep selected."))
          : concat2(asciiBytes("Choose focus task "), task.title),
    }));
}

export function quickHasTasks(model: Model): boolean {
  return model.tasks.some((task) => task.state === "open");
}

export function quickHasMoreTasks(model: Model): boolean {
  return model.tasks.filter((task) => task.state === "open").length > 3;
}

export function quickTaskCountText(model: Model): Bytes {
  const count = model.tasks.filter((task) => task.state === "open").length;
  return count === 1 ? asciiBytes("1 open task") : asciiBytes(`${count} open tasks`);
}

export function quickSelectedTaskExists(model: Model): boolean {
  return eligibleTask(model, model.selectedTaskId);
}

export function quickTaskTitle(model: Model): Bytes {
  if (model.activeSession !== null || model.completionTaskId > 0) return focusTaskTitle(model);
  const selected = taskById(model.tasks, model.selectedTaskId);
  return selected === null || selected.state !== "open" ? asciiBytes("Choose a focus task") : selected.title;
}

export function quickCanStart(model: Model): boolean {
  return (
    model.loadState === "ready" &&
    !model.saving &&
    !model.hasWriteError &&
    !hasBlockingDialog(model) &&
    model.activeSession === null &&
    eligibleTask(model, model.selectedTaskId)
  );
}

export function quickControlsDisabled(model: Model): boolean {
  return model.saving || model.hasWriteError || hasBlockingDialog(model);
}

export function quickStartLabel(model: Model): Bytes {
  return asciiBytes(`Start ${model.settings.focusMinutes} minutes`);
}

export function selectedFocusIntervalLabel(model: Model): Bytes {
  return asciiBytes(`Selected focus interval, ${model.settings.focusMinutes} minutes`);
}

export function quickStatusLabel(model: Model): Bytes {
  if (model.breakAcknowledgementOpen) return asciiBytes("Break recorded");
  const state = sessionState(model);
  if (state === "complete") return asciiBytes("Recorded");
  if (state === "paused") return asciiBytes("Paused");
  if (state === "running") return isBreak(model) ? asciiBytes("On break") : asciiBytes("Focusing");
  return asciiBytes("Ready");
}

export function mainEndDialogOpen(model: Model): boolean {
  return model.endDialogOpen && model.dialogSurface === "main";
}

export function quickEndDialogOpen(model: Model): boolean {
  return model.endDialogOpen && model.dialogSurface === "quick";
}

export function quickCompletionDialogOpen(model: Model): boolean {
  return model.completionDialogOpen && model.dialogSurface === "quick";
}

export function selectedTaskExists(model: Model): boolean {
  return model.section === "today" && model.taskFilter === "open" && eligibleTask(model, model.selectedTaskId);
}

export function taskListLabel(model: Model): Bytes {
  if (model.taskFilter === "completed") return asciiBytes("Completed tasks");
  if (model.taskFilter === "archived") return asciiBytes("Archived tasks");
  return asciiBytes("Open tasks for Today");
}

export function hasUndo(model: Model): boolean {
  return model.undoTaskId > 0 && taskMatchesUndo(taskById(model.tasks, model.undoTaskId), model.undoTaskState);
}

export function purgeTaskTitle(model: Model): Bytes {
  const task = taskById(model.tasks, model.purgeTaskId);
  return task !== null && task.state === "archived" ? task.title : asciiBytes("this archived task");
}

export function undoText(model: Model): Bytes {
  if (model.undoTaskId === 0) return EMPTY;
  return concat2(asciiBytes("Archived "), model.undoTaskTitle);
}

export function sessionState(model: Model): SessionViewState {
  if (model.activeSession !== null) {
    return model.activeSession.state === "paused" ? "paused" : "running";
  }
  return model.completionDialogOpen ? "complete" : "idle";
}

export function isBreak(model: Model): boolean {
  if (model.activeSession === null) return false;
  return model.activeSession.mode !== "focus";
}

export function focusTaskTitle(model: Model): Bytes {
  if (model.activeSession !== null) {
    if (model.activeSession.taskId > 0) return taskTitleFor(model.tasks, model.activeSession.taskId);
    return modeTitle(model.activeSession.mode);
  }
  if (model.completionTaskId > 0) return taskTitleFor(model.tasks, model.completionTaskId);
  if (model.taskFilter !== "open") return asciiBytes("Choose a focus task");
  const selected = taskById(model.tasks, model.selectedTaskId);
  return selected === null || selected.state !== "open" ? asciiBytes("Choose a focus task") : selected.title;
}

export function focusLengthMinutes(model: Model): number {
  if (model.activeSession !== null) return intDiv(model.activeSession.plannedMs, 60000);
  return model.settings.focusMinutes;
}

export function settingsFocusMinutes(model: Model): number {
  return model.settings.focusMinutes;
}

export function shortBreakMinutes(model: Model): number {
  return model.settings.shortBreakMinutes;
}

export function longBreakMinutes(model: Model): number {
  return model.settings.longBreakMinutes;
}

function nextBreakIsLong(model: Model): boolean {
  return model.stats.todayCompletedSessions > 0 && model.stats.todayCompletedSessions % 4 === 0;
}

export function nextBreakMinutes(model: Model): number {
  return nextBreakIsLong(model) ? model.settings.longBreakMinutes : model.settings.shortBreakMinutes;
}

export function dailyGoalMinutes(model: Model): number {
  return model.settings.dailyGoalMinutes;
}

export function soundEnabled(model: Model): boolean {
  return model.settings.soundEnabled;
}

// A switch retains the pointer-applied value until its identity changes. Rekey
// it when the persisted setting flips so the model remains the sole source of
// truth immediately after the click, not only after reopening Settings.
export function soundSwitchKey(model: Model): number {
  const persisted = model.settings.soundEnabled ? 1 : 0;
  // Native switches retain their pointer-applied value. A failed sound write
  // must therefore get a new identity so checked= reasserts SQLite/model truth
  // before Retry or Discard; otherwise the control can visually lie.
  if (model.hasWriteError && model.pendingKind === "settings") return persisted + 2;
  return persisted;
}

export function focusProgress(model: Model): number {
  if (model.activeSession === null) return 0.0;
  if (model.activeSession.plannedMs <= 0) return 0.0;
  const rest = remainingMs(model);
  if (rest <= 0) return 1.0;
  const elapsed = model.activeSession.plannedMs - rest;
  const permille = intDiv(elapsed * 1000, model.activeSession.plannedMs);
  let fraction = 0.0;
  let remaining = permille;
  while (remaining > 0) {
    remaining -= 1;
    fraction += 0.001;
  }
  return fraction;
}

export function remainingMinutes(model: Model): number {
  return intDiv(roundedUpSeconds(remainingMs(model)), 60);
}

export function remainingSeconds(model: Model): number {
  return roundedUpSeconds(remainingMs(model)) % 60;
}

export function timerA11y(model: Model): Bytes {
  const minutes = remainingMinutes(model);
  const seconds = remainingSeconds(model);
  if (sessionState(model) === "paused") {
    return isBreak(model)
      ? asciiBytes(`Break paused with ${minutes} minutes and ${seconds} seconds remaining`)
      : asciiBytes(`Focus paused with ${minutes} minutes and ${seconds} seconds remaining`);
  }
  return asciiBytes(`${minutes} minutes and ${seconds} seconds remaining`);
}

export function completionSummary(model: Model): Bytes {
  if (model.recentSessions.length === 0) return asciiBytes("Your focused time is safely recorded.");
  const exact = model.recentSessions.find((session) => session.id === model.completionSessionId);
  const session = exact === undefined ? model.recentSessions[0] : exact;
  const title = session.taskId > 0 ? taskTitleFor(model.tasks, session.taskId) : modeTitle(session.mode);
  return concat3(focusedDurationPhrase(session.focusedMs), concat2(asciiBytes(" recorded for "), title), asciiBytes("."));
}

export function quickCompletionSummary(model: Model): Bytes {
  if (model.recentSessions.length === 0) return asciiBytes("Focused time safely recorded.");
  const exact = model.recentSessions.find((session) => session.id === model.completionSessionId);
  const session = exact === undefined ? model.recentSessions[0] : exact;
  return concat2(focusedDurationPhrase(session.focusedMs), asciiBytes(" recorded."));
}

export function breakCompletionSummary(model: Model): Bytes {
  if (model.recentSessions.length === 0) return asciiBytes("Your break is safely recorded.");
  const exact = model.recentSessions.find((session) => session.id === model.completionSessionId);
  if (exact === undefined || exact.mode === "focus") return asciiBytes("Your break is safely recorded.");
  return concat2(restDurationPhrase(exact.focusedMs), asciiBytes(" recorded."));
}

export function weekMinutes(model: Model): readonly number[] {
  return model.stats.weekFocusMs.map((day) => {
    let tenths = intDiv(day.milliseconds, 6000);
    if (tenths === 0 && day.milliseconds > 0) tenths = 1;
    let value = 0.0;
    let remaining = tenths;
    while (remaining > 0) {
      remaining -= 1;
      value += 0.1;
    }
    return value;
  });
}

function weekdayInitial(day: number): Bytes {
  if (day === 0) return asciiBytes("M");
  if (day === 1) return asciiBytes("T");
  if (day === 2) return asciiBytes("W");
  if (day === 3) return asciiBytes("T");
  if (day === 4) return asciiBytes("F");
  if (day === 5) return asciiBytes("S");
  return asciiBytes("S");
}

function weekdayName(day: number): Bytes {
  if (day === 0) return asciiBytes("Monday");
  if (day === 1) return asciiBytes("Tuesday");
  if (day === 2) return asciiBytes("Wednesday");
  if (day === 3) return asciiBytes("Thursday");
  if (day === 4) return asciiBytes("Friday");
  if (day === 5) return asciiBytes("Saturday");
  return asciiBytes("Sunday");
}

function compactDuration(milliseconds: number): Bytes {
  if (milliseconds === 0) return asciiBytes("0m");
  if (milliseconds < 60000) return asciiBytes("<1m");
  return asciiBytes(`${intDiv(milliseconds, 60000)}m`);
}

function accessibleDayDuration(milliseconds: number): Bytes {
  if (milliseconds === 0) return asciiBytes("no focus recorded");
  if (milliseconds < 60000) return asciiBytes("less than 1 minute of focus");
  const minutes = intDiv(milliseconds, 60000);
  if (minutes === 1) return asciiBytes("1 minute of focus");
  return asciiBytes(`${minutes} minutes of focus`);
}

export function weekDays(model: Model): readonly WeekDayRow[] {
  return model.stats.weekFocusMs.map((day, index) => {
    const weekday = (model.stats.todayWeekday + index + 1) % 7;
    const isToday = index === 6;
    const dayAndValue = concat3(weekdayName(weekday), asciiBytes(", "), accessibleDayDuration(day.milliseconds));
    return {
      id: index + 1,
      label: weekdayInitial(weekday),
      valueText: compactDuration(day.milliseconds),
      accessibilityLabel: isToday ? concat2(dayAndValue, asciiBytes(", today")) : dayAndValue,
      today: isToday,
    };
  });
}

export function weekDayLabels(model: Model): readonly Bytes[] {
  return weekDays(model).map((day) => day.label);
}

export function hasWeekFocus(model: Model): boolean {
  return model.stats.weekFocusMs.some((day) => day.milliseconds > 0);
}

export function hasFullWeekMinute(model: Model): boolean {
  const total = model.stats.weekFocusMs.reduce((sum, day) => sum + day.milliseconds, 0);
  return total >= 60000;
}

export function weekChartMaxMinutes(model: Model): number {
  let maximum = model.settings.dailyGoalMinutes;
  for (const day of model.stats.weekFocusMs) {
    const minutes = day.milliseconds > 0 && day.milliseconds < 60000 ? 1 : intDiv(day.milliseconds, 60000);
    if (minutes > maximum) maximum = minutes;
  }
  return maximum;
}

export function focusedWeekText(model: Model): Bytes {
  const total = model.stats.weekFocusMs.reduce((sum, day) => sum + day.milliseconds, 0);
  if (total > 0 && total < 60000) return asciiBytes("<1 min");
  return asciiBytes(`${intDiv(total, 60000)} min`);
}

export function todayGoalText(model: Model): Bytes {
  if (model.stats.todayFocusMs > 0 && model.stats.todayFocusMs < 60000) {
    return asciiBytes(`<1 of ${model.settings.dailyGoalMinutes} min today`);
  }
  return asciiBytes(`${intDiv(model.stats.todayFocusMs, 60000)} of ${model.settings.dailyGoalMinutes} min today`);
}

export function todayGoalProgress(model: Model): number {
  const goalMs = model.settings.dailyGoalMinutes * 60000;
  if (goalMs <= 0) return 0.0;
  if (model.stats.todayFocusMs >= goalMs) return 1.0;
  const permille = intDiv(model.stats.todayFocusMs * 1000, goalMs);
  let fraction = 0.0;
  let remaining = permille;
  while (remaining > 0) {
    remaining -= 1;
    fraction += 0.001;
  }
  return fraction;
}

export function weekSessionText(model: Model): Bytes {
  const count = historySessions(model).length;
  return count === 1 ? asciiBytes("1 recent block") : asciiBytes(`${count} recent blocks`);
}

function focusedDurationPhrase(milliseconds: number): Bytes {
  if (milliseconds < 60000) return asciiBytes("Less than 1 focused minute");
  const minutes = intDiv(milliseconds, 60000);
  return minutes === 1 ? asciiBytes("1 focused minute") : asciiBytes(`${minutes} focused minutes`);
}

function restDurationPhrase(milliseconds: number): Bytes {
  if (milliseconds < 60000) return asciiBytes("Less than 1 minute of rest");
  const minutes = intDiv(milliseconds, 60000);
  return minutes === 1 ? asciiBytes("1 minute of rest") : asciiBytes(`${minutes} minutes of rest`);
}

function sessionMeta(session: DbSession): Bytes {
  if (session.completionReason === "manual") return asciiBytes("Finished and recorded manually");
  if (session.completionReason === "recovered") return asciiBytes("Recovered safely after relaunch");
  return session.mode === "focus" ? asciiBytes("Completed in full") : asciiBytes("Rest completed");
}

export function historySessions(model: Model): readonly HistoryRow[] {
  const sessions = model.recentSessions.filter((session) => session.state === "completed");
  return sessions.map((session, index) => ({
    id: session.id,
    taskTitle: session.taskId > 0 ? taskTitleFor(model.tasks, session.taskId) : modeTitle(session.mode),
    durationLabel: session.mode === "focus" ? focusedDurationPhrase(session.focusedMs) : restDurationPhrase(session.focusedMs),
    meta: sessionMeta(session),
    tone: session.mode === "focus" ? "primary" : "secondary",
    connector: index + 1 < sessions.length,
  }));
}

export function hasHistory(model: Model): boolean {
  return historySessions(model).length > 0;
}

export function commandMsg(name: string): Msg | null {
  if (name === "app.new-task") return { kind: "new_task_command" };
  if (name === "app.today") return { kind: "today_command" };
  if (name === "app.ledger") return { kind: "ledger_command" };
  if (name === "app.toggle-focus") return { kind: "toggle_focus_command" };
  if (name === "app.settings") return { kind: "open_settings" };
  if (name === "app.escape") return { kind: "escape_pressed" };
  if (name === "app.escape-main") return { kind: "escape_main_pressed" };
  if (name === "app.escape-quick") return { kind: "escape_quick_pressed" };
  if (name === "app.escape-settings") return { kind: "escape_settings_pressed" };
  if (name === "app.quick") return { kind: "open_quick" };
  if (name === "app.quick-toggle") return { kind: "quick_toggle_command" };
  if (name === "app.quick-end") return { kind: "open_quick_end" };
  if (name === "app.retry") return { kind: "retry_save" };
  if (name === "app.tray-quit") return { kind: "quit_app" };
  if (name === "app.show") return { kind: "open_full_app" };
  if (name === "app.quit") return { kind: "quit_command" };
  return null;
}

export function keyMsg(key: KeyEvent): Msg | null {
  if (key.key === "escape") return { kind: "escape_pressed" };
  return null;
}

export function subscriptions(model: Model): Sub<Msg> {
  if (model.loadState !== "ready") return Sub.none;
  if (model.activeSession === null) return Sub.none;
  if (model.activeSession.state !== "running") return Sub.none;
  return Sub.timer("focus-display", 250, "tick");
}

function startsAuthoritativeWrite(msg: Msg): boolean {
  switch (msg.kind) {
    case "add_task":
    case "toggle_task":
    case "start_focus_task":
    case "commit_rename":
    case "delete_task":
    case "restore_task":
    case "confirm_purge_task":
    case "undo_delete":
    case "set_duration_25":
    case "set_duration_50":
    case "set_duration_90":
    case "start_focus":
    case "pause_focus":
    case "resume_focus":
    case "finish_focus_now":
    case "confirm_end_focus":
    case "complete_task_after_focus":
    case "start_break":
    case "set_short_break_5":
    case "set_short_break_10":
    case "set_short_break_15":
    case "set_long_break_15":
    case "set_long_break_20":
    case "set_long_break_30":
    case "set_daily_goal_60":
    case "set_daily_goal_120":
    case "set_daily_goal_180":
    case "toggle_sound":
    case "toggle_focus_command":
    case "quick_toggle_command":
    case "intent_now":
      return true;
    default:
      return false;
  }
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  // The model has one authoritative retry slot. Keep it intact until Retry or
  // a reload resolves the error; navigation, editing, and safe dismissal stay
  // responsive while subsequent writes are ignored deterministically.
  if (model.hasWriteError && startsAuthoritativeWrite(msg)) return model;

  switch (msg.kind) {
    case "show_today":
      return { ...model, section: "today", taskActionsTaskId: -1 };
    case "show_ledger":
      return { ...model, section: "ledger", taskActionsTaskId: -1 };
    case "task_draft_edit":
      return {
        ...withoutFocusRecovery(model),
        taskDraftEditor: editApplied(model.taskDraftEditor, msg.edit),
      };
    case "add_task": {
      if (model.saving || hasBlockingDialog(model) || model.loadState !== "ready") return model;
      const title = model.taskDraftEditor.text.trim();
      if (title.length === 0) return model;
      return [
        intentModel({ ...model, startAutofocus: false }, "task_create", 0, "open", title, "focus", model.settings.focusMinutes),
        Cmd.now("intent_now"),
      ];
    }
    case "select_task": {
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state !== model.taskFilter) return model;
      const selected: Model = {
        ...withoutFocusRecovery(model),
        actionTaskId: msg.id,
        taskActionsTaskId: -1,
        selectedTaskId: task.state === "open" ? msg.id : -1,
      };
      if (task.state !== "open") return selected;
      return withStartFocus(selected, "main");
    }
    case "toggle_task_actions": {
      const task = taskById(model.tasks, msg.id);
      if (
        model.saving ||
        model.hasWriteError ||
        task === null ||
        task.state !== model.taskFilter ||
        task.state === "archived" ||
        sessionState(model) !== "idle"
      ) return model;
      return {
        ...model,
        actionTaskId: task.id,
        taskActionsTaskId: model.taskActionsTaskId === task.id ? -1 : task.id,
      };
    }
    case "dismiss_task_actions":
      return { ...model, taskActionsTaskId: -1 };
    case "select_quick_task": {
      if (model.saving || hasBlockingDialog(model) || model.activeSession !== null) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state !== "open") return model;
      return withStartFocus({
        ...withoutFocusRecovery(model),
        section: "today",
        taskFilter: "open",
        selectedTaskId: task.id,
        actionTaskId: task.id,
      }, "quick");
    }
    case "toggle_task": {
      if (model.saving) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state === "archived") return model;
      const nextState: TaskState = task.state === "completed" ? "open" : "completed";
      return [
        intentModel(withoutFocusRecovery(model), "task_state", task.id, nextState, EMPTY, "focus", 0),
        Cmd.now("intent_now"),
      ];
    }
    case "start_focus_task": {
      if (model.saving || hasBlockingDialog(model) || model.activeSession !== null || !eligibleTask(model, msg.id)) return model;
      const selected: Model = {
        ...model,
        selectedTaskId: msg.id,
        actionTaskId: msg.id,
        taskActionsTaskId: -1,
        taskFilter: "open",
      };
      return [
        intentModel(selected, "timer_start", msg.id, "open", EMPTY, "focus", model.settings.focusMinutes),
        Cmd.now("intent_now"),
      ];
    }
    case "begin_rename": {
      const task = taskById(model.tasks, msg.id);
      if (model.saving || task === null || task.state === "archived") return model;
      return [
        {
          ...withoutFocusRecovery(model),
          taskActionsTaskId: -1,
          editTaskId: task.id,
          editDraftEditor: editorFor(task.title),
          editAutofocus: false,
        },
        Cmd.delay("edit-autofocus", 1, "arm_edit_autofocus"),
      ];
    }
    case "edit_draft_edit":
      return { ...model, editDraftEditor: editApplied(model.editDraftEditor, msg.edit) };
    case "commit_rename": {
      if (model.saving || model.editTaskId < 1) return model;
      const title = model.editDraftEditor.text.trim();
      if (title.length === 0) return model;
      return [
        intentModel(
          { ...withoutFocusRecovery(model), editAutofocus: false },
          "task_rename",
          model.editTaskId,
          "open",
          title,
          "focus",
          0,
        ),
        Cmd.now("intent_now"),
      ];
    }
    case "cancel_rename": {
      const taskId = model.editTaskId;
      return withTaskRowOrFilterFocus(
        { ...model, editTaskId: -1, editDraftEditor: emptyEditor(), editAutofocus: false },
        taskId,
      );
    }
    case "delete_task": {
      if (model.saving) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state === "archived") return model;
      return [
        intentModel(
          { ...withoutFocusRecovery(model), taskActionsTaskId: -1 },
          "task_archive",
          task.id,
          "archived",
          task.title,
          "focus",
          0,
        ),
        Cmd.now("intent_now"),
      ];
    }
    case "show_open_tasks":
      return {
        ...withoutFocusRecovery(model),
        taskFilter: "open",
        selectedTaskId: normalizedSelectedTaskId(model.tasks, model.selectedTaskId),
        actionTaskId: normalizedActionTaskId(model.tasks, "open", model.actionTaskId),
        taskActionsTaskId: -1,
      };
    case "show_completed_tasks":
      return {
        ...withoutFocusRecovery(model),
        taskFilter: "completed",
        selectedTaskId: -1,
        actionTaskId: normalizedActionTaskId(model.tasks, "completed", model.actionTaskId),
        taskActionsTaskId: -1,
      };
    case "show_archived_tasks":
      return {
        ...withoutFocusRecovery(model),
        taskFilter: "archived",
        selectedTaskId: -1,
        actionTaskId: normalizedActionTaskId(model.tasks, "archived", model.actionTaskId),
        taskActionsTaskId: -1,
      };
    case "restore_task": {
      if (model.saving) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state !== "archived") return model;
      return [
        intentModel(withoutFocusRecovery(model), "task_restore", task.id, "open", task.title, "focus", 0),
        Cmd.now("intent_now"),
      ];
    }
    case "request_purge_task": {
      if (model.saving || model.activeSession !== null) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state !== "archived") return model;
      return [
        {
          ...withoutFocusRecovery(model),
          purgeDialogOpen: true,
          purgeAutofocus: true,
          purgeFocusEpoch: model.purgeFocusEpoch + 1,
          purgeTaskId: task.id,
          actionTaskId: task.id,
          settingsWindowOpen: false,
          quickWindowOpen: false,
          endDialogOpen: false,
          completionDialogOpen: false,
          completionTaskId: 0,
          completionSessionId: 0,
        },
        Cmd.delay("purge-autofocus", 1, "arm_purge_autofocus"),
      ];
    }
    case "cancel_purge_task":
      return withFocusRecovery(
        { ...model, purgeDialogOpen: false, purgeAutofocus: false, purgeTaskId: 0 },
        "purge_trigger",
        model.purgeTaskId,
      );
    case "confirm_purge_task": {
      if (model.saving || !model.purgeDialogOpen) return model;
      const task = taskById(model.tasks, model.purgeTaskId);
      if (task === null || task.state !== "archived") {
        return { ...model, purgeDialogOpen: false, purgeAutofocus: false, purgeTaskId: 0 };
      }
      const confirmed: Model = {
        ...withoutFocusRecovery(model),
        purgeDialogOpen: false,
        purgeAutofocus: false,
        purgeTaskId: 0,
      };
      return [intentModel(confirmed, "task_purge", task.id, "archived", task.title, "focus", 0), Cmd.now("intent_now")];
    }
    case "undo_delete": {
      if (model.saving || model.undoTaskId === 0) return model;
      if (!taskMatchesUndo(taskById(model.tasks, model.undoTaskId), model.undoTaskState)) {
        return { ...model, undoTaskId: 0, undoTaskTitle: EMPTY, undoTaskState: "open" };
      }
      return [
        intentModel(
          withoutFocusRecovery(model),
          "task_undo_archive",
          model.undoTaskId,
          model.undoTaskState,
          model.undoTaskTitle,
          "focus",
          0,
        ),
        Cmd.now("intent_now"),
      ];
    }
    case "dismiss_undo":
      return { ...model, undoTaskId: 0, undoTaskTitle: EMPTY, undoTaskState: "open" };
    case "set_duration_25":
      if (model.saving || model.settings.focusMinutes === 25) return model;
      return [
        settingsIntentModel(model, { ...model.settings, focusMinutes: 25 }),
        Cmd.now("intent_now"),
      ];
    case "set_duration_50":
      if (model.saving || model.settings.focusMinutes === 50) return model;
      return [
        settingsIntentModel(model, { ...model.settings, focusMinutes: 50 }),
        Cmd.now("intent_now"),
      ];
    case "set_duration_90":
      if (model.saving || model.settings.focusMinutes === 90) return model;
      return [
        settingsIntentModel(model, { ...model.settings, focusMinutes: 90 }),
        Cmd.now("intent_now"),
      ];
    case "start_focus":
      if (model.saving || hasBlockingDialog(model) || model.activeSession !== null || !eligibleTask(model, model.selectedTaskId)) return model;
      return [
        intentModel(
          { ...model, taskFilter: "open" },
          "timer_start",
          model.selectedTaskId,
          "open",
          EMPTY,
          "focus",
          model.settings.focusMinutes,
        ),
        Cmd.now("intent_now"),
      ];
    case "pause_focus": {
      if (model.saving || hasBlockingDialog(model)) return model;
      if (model.activeSession === null) return model;
      if (model.activeSession.state !== "running") return model;
      const sessionId = model.activeSession.id;
      const mode = model.activeSession.mode;
      return [
        intentModel(model, "timer_pause", sessionId, "open", EMPTY, mode, 0),
        Cmd.now("intent_now"),
      ];
    }
    case "resume_focus": {
      if (model.saving || hasBlockingDialog(model)) return model;
      if (model.activeSession === null) return model;
      if (model.activeSession.state !== "paused") return model;
      const sessionId = model.activeSession.id;
      const mode = model.activeSession.mode;
      return [
        intentModel(model, "timer_resume", sessionId, "open", EMPTY, mode, 0),
        Cmd.now("intent_now"),
      ];
    }
    case "request_end_focus":
      return model.saving || model.hasWriteError || model.activeSession === null
        ? model
        : { ...model, endDialogOpen: true, dialogSurface: "main", transportAutofocus: false };
    case "request_quick_end_focus":
      return model.saving || model.hasWriteError || model.activeSession === null
        ? model
        : { ...model, endDialogOpen: true, dialogSurface: "quick", transportAutofocus: false };
    case "finish_focus_now": {
      if (model.saving) return model;
      if (model.activeSession === null) return model;
      const taskId = model.activeSession.taskId;
      const mode = model.activeSession.mode;
      return [
        intentModel(
          { ...model, endDialogOpen: false },
          "timer_complete_manual",
          taskId,
          "open",
          EMPTY,
          mode,
          0,
        ),
        Cmd.now("intent_now"),
      ];
    }
    case "confirm_end_focus": {
      if (model.saving) return model;
      if (model.activeSession === null) return model;
      const taskId = model.activeSession.taskId;
      const mode = model.activeSession.mode;
      return [
        intentModel(
          { ...model, endDialogOpen: false },
          "timer_cancel",
          taskId,
          "open",
          EMPTY,
          mode,
          0,
        ),
        Cmd.now("intent_now"),
      ];
    }
    case "cancel_end_focus":
      return [
        { ...model, endDialogOpen: false, transportAutofocus: false },
        Cmd.delay("transport-autofocus", 1, "arm_transport_autofocus"),
      ];
    case "complete_task_after_focus":
      if (model.saving) return model;
      if (model.completionTaskId === 0 || !eligibleTask(model, model.completionTaskId)) {
        return keepCompletionTaskOpen(model);
      }
      return [
        intentModel(model, "task_after_focus", model.completionTaskId, "completed", EMPTY, "focus", 0),
        Cmd.now("intent_now"),
      ];
    case "keep_task_open_after_focus":
      return keepCompletionTaskOpen(model);
    case "start_break": {
      if (model.saving || model.activeSession !== null) return model;
      const longBreak = nextBreakIsLong(model);
      const mode: SessionMode = longBreak ? "long" : "short";
      const minutes = nextBreakMinutes(model);
      return [intentModel(model, "timer_start", 0, "open", EMPTY, mode, minutes), Cmd.now("intent_now")];
    }
    case "dismiss_break_acknowledgement":
      return {
        ...model,
        breakAcknowledgementOpen: false,
        completionSessionId: 0,
      };
    case "open_settings":
      if (model.loadState !== "ready" || hasBlockingDialog(model)) return model;
      if (model.settingsWindowOpen) {
        return [
          { ...model, quickWindowOpen: false },
          Cmd.showWindow("settings"),
        ];
      }
      return [
        {
          ...model,
          settingsWindowOpen: true,
          quickWindowOpen: false,
        },
        Cmd.delay("settings-activate", 1, "raise_settings"),
      ];
    case "raise_settings":
      if (!model.settingsWindowOpen || hasBlockingDialog(model)) return model;
      return [model, Cmd.showWindow("settings")];
    case "close_settings":
      return { ...model, settingsWindowOpen: false };
    case "open_quick":
      if (model.loadState !== "ready") return model;
      // A recorded-focus confirmation can move between the main instrument
      // and Quick Focus. True modal dialogs stay on their current surface.
      if (hasBlockingDialog(model)) return model;
      if (model.quickWindowOpen) {
        const raised =
          sessionState(model) === "idle" && eligibleTask(model, model.selectedTaskId)
            ? withStartFocus(model, "quick")
            : model;
        return [
          {
            ...raised,
            settingsWindowOpen: false,
            dialogSurface: model.completionDialogOpen
              ? "quick"
              : model.dialogSurface,
          },
          Cmd.showWindow("quick"),
        ];
      }
      const opened =
        sessionState(model) === "idle" && eligibleTask(model, model.selectedTaskId)
          ? withStartFocus(model, "quick")
          : model;
      return [
        {
          ...opened,
          quickWindowOpen: true,
          settingsWindowOpen: false,
          dialogSurface: model.completionDialogOpen
            ? "quick"
            : model.dialogSurface,
        },
        Cmd.delay("quick-activate", 1, "raise_quick"),
      ];
    case "raise_quick":
      if (!model.quickWindowOpen) return model;
      return [model, Cmd.showWindow("quick")];
    case "close_quick":
      if (model.dialogSurface === "quick" && model.endDialogOpen) {
        return [
          { ...model, quickWindowOpen: false, dialogSurface: "main" },
          Cmd.showWindow("main"),
        ];
      }
      if (model.dialogSurface === "quick" && model.completionDialogOpen) {
        return {
          ...keepCompletionTaskOpen(model),
          quickWindowOpen: false,
          dialogSurface: "main",
        };
      }
      if (model.breakAcknowledgementOpen) {
        return {
          ...model,
          quickWindowOpen: false,
          breakAcknowledgementOpen: false,
          completionSessionId: 0,
        };
      }
      return { ...model, quickWindowOpen: false };
    case "open_full_app":
      return [
        {
          ...model,
          quickWindowOpen: false,
          dialogSurface:
            model.dialogSurface === "quick" &&
            (model.endDialogOpen || model.completionDialogOpen)
              ? "main"
              : model.dialogSurface,
        },
        Cmd.showWindow("main"),
      ];
    case "open_quick_end":
      if (model.saving || model.hasWriteError || model.activeSession === null) return model;
      return [
        {
          ...model,
          quickWindowOpen: true,
          settingsWindowOpen: false,
          endDialogOpen: true,
          dialogSurface: "quick",
          transportAutofocus: false,
        },
        Cmd.delay("quick-activate", 1, "raise_quick"),
      ];
    case "set_short_break_5":
      if (model.saving || model.settings.shortBreakMinutes === 5) return model;
      return [
        settingsIntentModel(model, { ...model.settings, shortBreakMinutes: 5 }),
        Cmd.now("intent_now"),
      ];
    case "set_short_break_10":
      if (model.saving || model.settings.shortBreakMinutes === 10) return model;
      return [
        settingsIntentModel(model, { ...model.settings, shortBreakMinutes: 10 }),
        Cmd.now("intent_now"),
      ];
    case "set_short_break_15":
      if (model.saving || model.settings.shortBreakMinutes === 15) return model;
      return [
        settingsIntentModel(model, { ...model.settings, shortBreakMinutes: 15 }),
        Cmd.now("intent_now"),
      ];
    case "set_long_break_15":
      if (model.saving || model.settings.longBreakMinutes === 15) return model;
      return [
        settingsIntentModel(model, { ...model.settings, longBreakMinutes: 15 }),
        Cmd.now("intent_now"),
      ];
    case "set_long_break_20":
      if (model.saving || model.settings.longBreakMinutes === 20) return model;
      return [
        settingsIntentModel(model, { ...model.settings, longBreakMinutes: 20 }),
        Cmd.now("intent_now"),
      ];
    case "set_long_break_30":
      if (model.saving || model.settings.longBreakMinutes === 30) return model;
      return [
        settingsIntentModel(model, { ...model.settings, longBreakMinutes: 30 }),
        Cmd.now("intent_now"),
      ];
    case "set_daily_goal_60":
      if (model.saving || model.settings.dailyGoalMinutes === 60) return model;
      return [
        settingsIntentModel(model, { ...model.settings, dailyGoalMinutes: 60 }),
        Cmd.now("intent_now"),
      ];
    case "set_daily_goal_120":
      if (model.saving || model.settings.dailyGoalMinutes === 120) return model;
      return [
        settingsIntentModel(model, { ...model.settings, dailyGoalMinutes: 120 }),
        Cmd.now("intent_now"),
      ];
    case "set_daily_goal_180":
      if (model.saving || model.settings.dailyGoalMinutes === 180) return model;
      return [
        settingsIntentModel(model, { ...model.settings, dailyGoalMinutes: 180 }),
        Cmd.now("intent_now"),
      ];
    case "toggle_sound":
      if (model.saving) return model;
      return [
        settingsIntentModel(model, { ...model.settings, soundEnabled: !model.settings.soundEnabled }),
        Cmd.now("intent_now"),
      ];
    case "retry_boot":
      return [
        {
          ...model,
          loadState: "loading",
          fatalErrorText: asciiBytes("Reopening your local focus ledger."),
          hasWriteError: false,
          pendingKind: "load",
        },
        Cmd.now("reload_now"),
      ];
    case "quit_app":
      return [model, Cmd.quitApp()];
    case "pane_resized": {
      const low = msg.fraction < 0.24 ? 0.24 : msg.fraction;
      const high = low > 0.48 ? 0.48 : low;
      return { ...model, paneFraction: high };
    }
    case "new_task_command": {
      if (hasBlockingSurface(model) || model.loadState !== "ready") return model;
      return [
        withFocusRecovery(
          {
            ...(model.completionDialogOpen ? keepCompletionTaskOpen(model) : model),
            section: "today",
            taskFilter: "open",
            selectedTaskId: normalizedSelectedTaskId(model.tasks, model.selectedTaskId),
            actionTaskId: normalizedActionTaskId(model.tasks, "open", model.actionTaskId),
          },
          "composer_pending",
          -1,
        ),
        Cmd.delay("composer-autofocus", 1, "arm_composer_autofocus"),
      ];
    }
    case "today_command":
      if (hasBlockingSurface(model)) return model;
      return { ...model, section: "today" };
    case "ledger_command":
      if (hasBlockingSurface(model)) return model;
      return { ...model, section: "ledger" };
    case "toggle_focus_command": {
      if (hasBlockingSurface(model) || model.saving) return model;
      if (model.activeSession !== null && model.activeSession.state === "running") {
        const sessionId = model.activeSession.id;
        const mode = model.activeSession.mode;
        return [
          intentModel(model, "timer_pause", sessionId, "open", EMPTY, mode, 0),
          Cmd.now("intent_now"),
        ];
      }
      if (model.activeSession !== null && model.activeSession.state === "paused") {
        const sessionId = model.activeSession.id;
        const mode = model.activeSession.mode;
        return [
          intentModel(model, "timer_resume", sessionId, "open", EMPTY, mode, 0),
          Cmd.now("intent_now"),
        ];
      }
      if (model.activeSession === null && eligibleTask(model, model.selectedTaskId)) {
        return [
          intentModel(
            { ...model, section: "today", taskFilter: "open" },
            "timer_start",
            model.selectedTaskId,
            "open",
            EMPTY,
            "focus",
            model.settings.focusMinutes,
          ),
          Cmd.now("intent_now"),
        ];
      }
      return model;
    }
    case "quick_toggle_command": {
      if (hasBlockingDialog(model) || model.saving || model.loadState !== "ready") return model;
      if (model.activeSession !== null && model.activeSession.state === "running") {
        const sessionId = model.activeSession.id;
        const mode = model.activeSession.mode;
        return [
          intentModel(model, "timer_pause", sessionId, "open", EMPTY, mode, 0),
          Cmd.now("intent_now"),
        ];
      }
      if (model.activeSession !== null && model.activeSession.state === "paused") {
        const sessionId = model.activeSession.id;
        const mode = model.activeSession.mode;
        return [
          intentModel(model, "timer_resume", sessionId, "open", EMPTY, mode, 0),
          Cmd.now("intent_now"),
        ];
      }
      if (model.activeSession === null && eligibleTask(model, model.selectedTaskId)) {
        return [
          intentModel(
            { ...model, section: "today", taskFilter: "open" },
            "timer_start",
            model.selectedTaskId,
            "open",
            EMPTY,
            "focus",
            model.settings.focusMinutes,
          ),
          Cmd.now("intent_now"),
        ];
      }
      return model;
    }
    case "quit_command":
      if (hasBlockingDialog(model)) return model;
      return [model, Cmd.quitApp()];
    case "show_window":
      return [model, Cmd.showWindow("main")];
    case "escape_main_pressed":
      if (model.purgeDialogOpen) {
        return withFocusRecovery(
          { ...model, purgeDialogOpen: false, purgeAutofocus: false, purgeTaskId: 0 },
          "purge_trigger",
          model.purgeTaskId,
        );
      }
      if (model.endDialogOpen && model.dialogSurface === "main") {
        return [
          { ...model, endDialogOpen: false, transportAutofocus: false },
          Cmd.delay("transport-autofocus", 1, "arm_transport_autofocus"),
        ];
      }
      if (model.completionDialogOpen) return keepCompletionTaskOpen(model);
      if (model.breakAcknowledgementOpen) {
        return { ...model, breakAcknowledgementOpen: false, completionSessionId: 0 };
      }
      if (model.editTaskId > 0) {
        return withTaskRowOrFilterFocus(
          { ...model, editTaskId: -1, editDraftEditor: emptyEditor(), editAutofocus: false },
          model.editTaskId,
        );
      }
      if (model.taskDraftEditor.text.length > 0) {
        return {
          ...model,
          taskDraftEditor: emptyEditor(),
          composerKey: model.composerKey + 1,
        };
      }
      return model;
    case "escape_quick_pressed":
      if (model.endDialogOpen && model.dialogSurface === "quick") {
        return [
          { ...model, endDialogOpen: false, transportAutofocus: false },
          Cmd.delay("transport-autofocus", 1, "arm_transport_autofocus"),
        ];
      }
      if (model.completionDialogOpen) return keepCompletionTaskOpen(model);
      if (model.breakAcknowledgementOpen) {
        return { ...model, breakAcknowledgementOpen: false, completionSessionId: 0 };
      }
      if (model.quickWindowOpen) return { ...model, quickWindowOpen: false };
      return model;
    case "escape_settings_pressed":
      return model.settingsWindowOpen ? { ...model, settingsWindowOpen: false } : model;
    case "escape_pressed":
      // True confirmations can be raised on the main surface even while the
      // model-declared Settings window remains open; the visible modal owns
      // Escape before any auxiliary window or non-modal follow-up.
      if (model.purgeDialogOpen) {
        return withFocusRecovery(
          { ...model, purgeDialogOpen: false, purgeAutofocus: false, purgeTaskId: 0 },
          "purge_trigger",
          model.purgeTaskId,
        );
      }
      if (model.endDialogOpen) {
        return [
          { ...model, endDialogOpen: false, transportAutofocus: false },
          Cmd.delay("transport-autofocus", 1, "arm_transport_autofocus"),
        ];
      }
      // Settings cannot render completion follow-ups. When there is no true
      // modal, Escape closes that frontmost surface before touching durable
      // background completion state.
      if (model.settingsWindowOpen) return { ...model, settingsWindowOpen: false };
      // The focus record is already durable. Escape takes the safe default:
      // leave its task open and return to the ordinary Today workspace.
      if (model.completionDialogOpen) return keepCompletionTaskOpen(model);
      if (model.breakAcknowledgementOpen) {
        return { ...model, breakAcknowledgementOpen: false, completionSessionId: 0 };
      }
      // The SDK key fallback intentionally has no source-window identity.
      // Secondary windows are mutually exclusive, so dismissing the sole
      // auxiliary surface first can never close a sibling in the background.
      if (model.quickWindowOpen) return { ...model, quickWindowOpen: false };
      if (model.editTaskId > 0) {
        return withTaskRowOrFilterFocus(
          { ...model, editTaskId: -1, editDraftEditor: emptyEditor(), editAutofocus: false },
          model.editTaskId,
        );
      }
      return model;
    case "arm_composer_autofocus":
      if (
        model.loadState !== "ready" ||
        model.focusRecoveryKind !== "composer_pending" ||
        hasBlockingDialog(model)
      ) {
        return model;
      }
      return withFocusRecovery(
        { ...model, composerKey: model.composerKey + 1 },
        "composer",
        -1,
      );
    case "arm_start_autofocus":
      if (model.loadState !== "ready" || sessionState(model) !== "idle" || !eligibleTask(model, model.selectedTaskId)) {
        return model;
      }
      return withStartFocus(model, model.quickWindowOpen ? "quick" : "main");
    case "arm_transport_autofocus":
      if (
        model.loadState !== "ready" ||
        model.activeSession === null ||
        (model.activeSession.state !== "running" && model.activeSession.state !== "paused") ||
        model.endDialogOpen
      ) {
        return model;
      }
      return { ...model, transportAutofocus: true };
    case "arm_purge_autofocus":
      if (model.loadState !== "ready" || !model.purgeDialogOpen) return model;
      return {
        ...model,
        purgeAutofocus: true,
        purgeFocusEpoch: model.purgeFocusEpoch + 1,
      };
    case "arm_edit_autofocus":
      if (model.loadState !== "ready" || model.editTaskId < 1 || model.purgeDialogOpen || model.endDialogOpen) {
        return model;
      }
      return {
        ...model,
        editAutofocus: true,
        editFocusEpoch: model.editFocusEpoch + 1,
      };
    case "boot_ready": {
      const payload = encodeLoad(msg.at);
      return [
        {
          ...model,
          pendingKind: "load",
          pendingNowMs: msg.at,
          pendingClockRollback: validWallNow(msg.at) && msg.at < model.nowMs,
          pendingNeedsFreshSnapshot: false,
          retryPayload: payload,
        },
        Cmd.request("focus.db.load", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
      ];
    }
    case "reload_now": {
      const at = acceptedWallNow(model.nowMs, msg.at);
      const payload = encodeLoad(at);
      return [
        {
          ...model,
          pendingKind: "load",
          pendingNowMs: at,
          pendingClockRollback: at < model.nowMs,
          pendingNeedsFreshSnapshot: false,
          retryPayload: payload,
          saving: true,
        },
        Cmd.request("focus.db.load", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
      ];
    }
    case "refresh_now": {
      const at = acceptedWallNow(model.nowMs, msg.at);
      const payload = encodeLoad(at);
      return [
        {
          ...model,
          pendingKind: "refresh",
          pendingNowMs: at,
          pendingClockRollback: at < model.nowMs,
          pendingNeedsFreshSnapshot: false,
          retryPayload: payload,
          saving: true,
        },
        Cmd.request("focus.db.load", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
      ];
    }
    case "intent_now": {
      const at = acceptedWallNow(model.nowMs, msg.at);
      const pending: Model = {
        ...model,
        pendingNowMs: at,
        pendingClockRollback: at < model.nowMs,
      };
      if (model.pendingKind === "task_create") {
        const payload = encodeTaskCreate(model.revision, at, model.settings.focusMinutes, model.pendingTitle);
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.task.create", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "task_rename") {
        const payload = encodeTaskRename(model.revision, at, model.pendingTaskId, model.pendingTitle);
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.task.rename", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "task_purge") {
        const payload = encodeTaskPurge(model.revision, at, model.pendingTaskId);
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.task.purge", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "task_undo_archive") {
        const payload = encodeTaskUndoArchive(model.revision, at, model.pendingTaskId, model.pendingTaskState);
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.task.undo_archive", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (
        model.pendingKind === "task_state" ||
        model.pendingKind === "task_archive" ||
        model.pendingKind === "task_restore" ||
        model.pendingKind === "task_after_focus"
      ) {
        const payload = encodeTaskState(model.revision, at, model.pendingTaskId, model.pendingTaskState);
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.task.set_state", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "settings") {
        const payload = encodeSettings(model.revision, at, model.pendingSettings);
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.settings.set", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "timer_start") {
        const payload = encodeTimerStart(
          model.revision,
          at,
          model.pendingTaskId,
          model.pendingMode,
          durationMs(model.pendingDurationMinutes),
        );
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.timer.start", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.activeSession === null) return { ...model, saving: false, pendingKind: "none" };
      const sessionId = model.activeSession.id;
      if (model.pendingKind === "timer_pause") {
        const payload = encodeTimerSession(model.revision, at, sessionId);
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.timer.pause", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "timer_resume") {
        const payload = encodeTimerSession(model.revision, at, sessionId);
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.timer.resume", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "timer_cancel") {
        const payload = encodeTimerSession(model.revision, at, sessionId);
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.timer.cancel", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "timer_complete_manual") {
        const payload = encodeTimerComplete(model.revision, at, sessionId, "manual");
        return [
          { ...pending, retryPayload: payload },
          Cmd.request("focus.db.timer.complete", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      return { ...model, saving: false, pendingKind: "none" };
    }
    case "db_ok": {
      const decoded = decodeSnapshot(msg.body);
      if (!decoded.ok) {
        return {
          ...model,
          loadState: "fatal",
          fatalErrorText: decoded.detail,
          saving: false,
          activeSession: null,
          settingsWindowOpen: false,
          quickWindowOpen: false,
          purgeDialogOpen: false,
          purgeAutofocus: false,
          purgeTaskId: 0,
          endDialogOpen: false,
          completionDialogOpen: false,
          breakAcknowledgementOpen: false,
          completionTaskId: 0,
          completionSessionId: 0,
          pendingKind: "none",
        };
      } else {
      const snapshot = decoded.value;
      let operation: PendingKind = model.pendingKind;
      let completedDuringRefresh = false;
      if (operation === "refresh" && snapshot.activeSession === null) {
        if (model.activeSession !== null) {
          if (includesCompletedSession(snapshot.recentSessions, model.activeSession.id)) {
            // A sleep/wake can cross the deadline before the best-effort
            // refresh following Retry. Preserve normal completion UX instead
            // of silently collapsing from running to idle.
            completedDuringRefresh = true;
            operation = "timer_complete_natural";
          }
        }
      }
      let completedMode: SessionMode = model.pendingMode;
      let completedTaskId = model.pendingTaskId;
      if (completedDuringRefresh) {
        if (model.activeSession !== null) {
          completedMode = model.activeSession.mode;
          completedTaskId = model.activeSession.taskId;
        }
      }
      const wallClockRolledBack = model.pendingClockRollback;
      const refreshAfterRetry = model.pendingNeedsFreshSnapshot;
      const loadObservedSameRevision =
        (model.pendingKind !== "load" && model.pendingKind !== "refresh") ||
        snapshot.revision === model.revision;
      const preserveUndo = loadObservedSameRevision && taskMatchesUndo(
        taskById(snapshot.tasks, model.undoTaskId),
        model.undoTaskState,
      );
      let selected =
        model.taskFilter === "open" ? normalizedSelectedTaskId(snapshot.tasks, model.selectedTaskId) : -1;
      let action = normalizedActionTaskId(snapshot.tasks, model.taskFilter, model.actionTaskId);
      let dialogSessionUnchanged = false;
      if (model.activeSession !== null && snapshot.activeSession !== null) {
        dialogSessionUnchanged = model.activeSession.id === snapshot.activeSession.id;
      }
      if (operation === "task_create") {
        const createdId = snapshot.nextTaskId - 1;
        const created = taskById(snapshot.tasks, createdId);
        if (created !== null && created.state === "open") {
          selected = created.id;
          action = created.id;
        }
      }
      let next: Model = {
        ...model,
        loadState: "ready",
        fatalErrorText: EMPTY,
        hasWriteError: false,
        writeErrorText: EMPTY,
        saving: false,
        revision: snapshot.revision,
        settings: snapshot.settings,
        tasks: snapshot.tasks,
        activeSession: snapshot.activeSession,
        recentSessions: snapshot.recentSessions,
        stats: snapshot.stats,
        selectedTaskId: selected,
        actionTaskId: action,
        endDialogOpen: model.endDialogOpen && dialogSessionUnchanged,
        transportAutofocus:
          model.endDialogOpen && !dialogSessionUnchanged ? true : model.transportAutofocus,
        undoTaskId: preserveUndo ? model.undoTaskId : 0,
        undoTaskTitle: preserveUndo ? model.undoTaskTitle : EMPTY,
        undoTaskState: preserveUndo ? model.undoTaskState : "open",
        pendingKind: "none",
        pendingClockRollback: false,
        pendingNeedsFreshSnapshot: false,
        retryPayload: EMPTY,
        nowMs: authoritativeNow(model, snapshot.activeSession, operation),
      };
      const completionTask = taskById(snapshot.tasks, model.completionTaskId);
      if (
        model.completionDialogOpen &&
        (completionTask === null || completionTask.state !== "open")
      ) {
        next = keepCompletionTaskOpen(next);
      }
      if (operation === "task_create" && bytesEqual(model.taskDraftEditor.text.trim(), model.pendingTitle)) {
        next = {
          ...next,
          section: "today",
          taskFilter: "open",
          taskDraftEditor: emptyEditor(),
        };
      }
      if (operation === "task_rename" && bytesEqual(model.editDraftEditor.text.trim(), model.pendingTitle)) {
        next = withTaskRowOrFilterFocus(
          { ...next, editTaskId: -1, editDraftEditor: emptyEditor(), editAutofocus: false },
          model.pendingTaskId,
        );
      }
      if (operation === "task_archive") {
        const archivedTask = taskById(model.tasks, model.pendingTaskId);
        const priorState: TaskState =
          archivedTask !== null && archivedTask.state === "completed" ? "completed" : "open";
        next = {
          ...next,
          undoTaskId: model.pendingTaskId,
          undoTaskTitle: model.pendingTitle,
          undoTaskState: priorState,
          selectedTaskId:
            model.taskFilter === "open" ? normalizedSelectedTaskId(snapshot.tasks, model.pendingTaskId) : -1,
          actionTaskId: firstTaskIdForFilter(snapshot.tasks, model.taskFilter),
        };
        next = withTaskRowOrFilterFocus(next, next.actionTaskId);
      }
      if (operation === "task_restore") {
        next = {
          ...next,
          section: "today",
          taskFilter: "open",
          undoTaskId: 0,
          undoTaskTitle: EMPTY,
          undoTaskState: "open",
          selectedTaskId: model.pendingTaskId,
          actionTaskId: model.pendingTaskId,
        };
        next = withTaskRowOrFilterFocus(next, model.pendingTaskId);
      }
      if (operation === "task_undo_archive") {
        const restoredFilter: TaskFilter = model.pendingTaskState === "completed" ? "completed" : "open";
        next = {
          ...next,
          section: "today",
          taskFilter: restoredFilter,
          undoTaskId: 0,
          undoTaskTitle: EMPTY,
          undoTaskState: "open",
          selectedTaskId: restoredFilter === "open" ? model.pendingTaskId : -1,
          actionTaskId: model.pendingTaskId,
        };
        next = withTaskRowOrFilterFocus(next, model.pendingTaskId);
      }
      if (operation === "task_purge") {
        next = {
          ...next,
          purgeDialogOpen: false,
          purgeAutofocus: false,
          purgeTaskId: 0,
          undoTaskId: model.undoTaskId === model.pendingTaskId ? 0 : model.undoTaskId,
          undoTaskTitle: model.undoTaskId === model.pendingTaskId ? EMPTY : model.undoTaskTitle,
          undoTaskState:
            model.undoTaskId === model.pendingTaskId ? "open" : model.undoTaskState,
          actionTaskId: firstTaskIdForFilter(snapshot.tasks, model.taskFilter),
        };
        next = withTaskRowOrFilterFocus(next, next.actionTaskId);
      }
      if (operation === "task_state") {
        next = {
          ...next,
          selectedTaskId:
            model.taskFilter === "open"
              ? model.pendingTaskState === "completed"
                ? firstOpenTaskId(snapshot.tasks)
                : model.pendingTaskId
              : -1,
          actionTaskId: firstTaskIdForFilter(snapshot.tasks, model.taskFilter),
        };
        next = withTaskRowOrFilterFocus(next, next.actionTaskId);
      }
      if (operation === "timer_start") {
        next = {
          ...next,
          taskFilter: "open",
          actionTaskId: model.pendingTaskId > 0 ? model.pendingTaskId : firstOpenTaskId(snapshot.tasks),
          section: "today",
          paneFraction: FOCUS_PANE,
          completionDialogOpen: false,
          breakAcknowledgementOpen: false,
          completionTaskId: 0,
          completionSessionId: 0,
        };
      }
      if (operation === "timer_cancel") {
        next = {
          ...next,
          paneFraction: DEFAULT_PANE,
          endDialogOpen: false,
          completionDialogOpen: false,
          breakAcknowledgementOpen: false,
          completionTaskId: 0,
          completionSessionId: 0,
          composerKey: next.composerKey + 1,
        };
      }
      if (operation === "timer_complete_natural" || operation === "timer_complete_manual") {
        const wasFocus = completedMode === "focus";
        let completedSessionId = 0;
        const completed = model.activeSession;
        if (completed !== null) completedSessionId = completed.id;
        next = {
          ...next,
          quickWindowOpen:
            operation === "timer_complete_natural" ? true : next.quickWindowOpen,
          settingsWindowOpen:
            operation === "timer_complete_natural" ? false : next.settingsWindowOpen,
          completionDialogOpen: wasFocus,
          breakAcknowledgementOpen: !wasFocus,
          completionTaskId: wasFocus ? completedTaskId : 0,
          completionSessionId: completedSessionId,
          dialogSurface:
            operation === "timer_complete_natural" ? "quick" : model.dialogSurface,
          paneFraction: wasFocus ? FOCUS_PANE : DEFAULT_PANE,
          endDialogOpen: false,
          composerKey: wasFocus ? next.composerKey : next.composerKey + 1,
        };
      }
      if (operation === "task_after_focus") {
        next = {
          ...next,
          completionDialogOpen: false,
          breakAcknowledgementOpen: false,
          completionTaskId: 0,
          completionSessionId: 0,
          paneFraction: DEFAULT_PANE,
          selectedTaskId: firstOpenTaskId(snapshot.tasks),
          actionTaskId: firstOpenTaskId(snapshot.tasks),
          composerKey: next.composerKey + 1,
        };
      }
      if (
        wallClockRolledBack &&
        operation !== "timer_start" &&
        operation !== "timer_resume" &&
        next.activeSession !== null &&
        next.activeSession.state === "running"
      ) {
        const live = next.activeSession;
        const payload = encodeTimerSession(next.revision, next.nowMs, live.id);
        const pending = intentModel(next, "timer_pause", live.id, "open", EMPTY, live.mode, 0);
        return [
          { ...pending, pendingNowMs: next.nowMs, retryPayload: payload },
          Cmd.request("focus.db.timer.pause", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (next.activeSession !== null) {
        if (next.activeSession.state === "running") {
          const sessionId = next.activeSession.id;
          const taskId = next.activeSession.taskId;
          const mode = next.activeSession.mode;
          const delayMs = remainingMs(next);
          if (delayMs > 0) {
            if (refreshAfterRetry) {
              // Preserve the mutation's original intent timestamp, then load
              // once at the actual current wall clock before arming another
              // deadline. This refreshes Today/week without racing a timer.
              return [
                { ...next, saving: true },
                Cmd.batch<Msg>([
                  Cmd.cancel("focus-deadline"),
                  Cmd.now("refresh_now"),
                ]),
              ];
            }
            if (operation === "timer_start" || operation === "timer_resume") {
              return [
                next,
                Cmd.batch<Msg>([
                  Cmd.delay("focus-deadline", delayMs, "focus_due"),
                  Cmd.delay("transport-autofocus", 1, "arm_transport_autofocus"),
                ]),
              ];
            }
            return [next, Cmd.delay("focus-deadline", delayMs, "focus_due")];
          }
          const payload = encodeTimerComplete(next.revision, next.nowMs, sessionId, "natural");
          return [
            {
              ...next,
              saving: true,
              pendingKind: "timer_complete_natural",
              pendingTaskId: taskId,
              pendingMode: mode,
              pendingNowMs: next.nowMs,
              retryPayload: payload,
            },
            Cmd.request("focus.db.timer.complete", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
          ];
        }
      }
      if (operation === "timer_complete_natural") {
        if (completedMode !== "focus" || !next.settings.soundEnabled) {
          if (refreshAfterRetry) {
            return [
              { ...next, saving: true },
              Cmd.batch<Msg>([
                Cmd.cancel("focus-deadline"),
                Cmd.delay<Msg>("quick-activate", 1, "raise_quick"),
                Cmd.now("refresh_now"),
              ]),
            ];
          }
          return [
            next,
            Cmd.batch<Msg>([
              Cmd.cancel("focus-deadline"),
              Cmd.delay<Msg>("quick-activate", 1, "raise_quick"),
            ]),
          ];
        }
        if (refreshAfterRetry) {
          return [
            { ...next, saving: true },
            Cmd.batch([
              Cmd.cancel("focus-deadline"),
              Cmd.delay<Msg>("quick-activate", 1, "raise_quick"),
              Cmd.audioPlay(
                "completion-sound",
                { path: asciiBytes("/System/Library/Sounds/Glass.aiff") },
                { event: "completion_sound_event" },
              ),
              Cmd.now("refresh_now"),
            ]),
          ];
        }
        return [
          next,
          Cmd.batch([
            Cmd.cancel("focus-deadline"),
            Cmd.delay<Msg>("quick-activate", 1, "raise_quick"),
            Cmd.audioPlay(
              "completion-sound",
              { path: asciiBytes("/System/Library/Sounds/Glass.aiff") },
              { event: "completion_sound_event" },
            ),
          ]),
        ];
      }
      if (operation === "task_create") {
        next = withStartFocus(next, model.quickWindowOpen ? "quick" : "main");
        if (refreshAfterRetry) {
          return [
            { ...next, saving: true },
            Cmd.batch<Msg>([
              Cmd.cancel("focus-deadline"),
              Cmd.now("refresh_now"),
            ]),
          ];
        }
        return [next, Cmd.cancel("focus-deadline")];
      }
      if (operation === "timer_pause") {
        if (refreshAfterRetry) {
          return [
            { ...next, saving: true },
            Cmd.batch<Msg>([
              Cmd.cancel("focus-deadline"),
              Cmd.delay("transport-autofocus", 1, "arm_transport_autofocus"),
              Cmd.now("refresh_now"),
            ]),
          ];
        }
        return [
          next,
          Cmd.batch<Msg>([
            Cmd.cancel("focus-deadline"),
            Cmd.delay("transport-autofocus", 1, "arm_transport_autofocus"),
          ]),
        ];
      }
      if (refreshAfterRetry) {
        return [
          { ...next, saving: true },
          Cmd.batch<Msg>([
            Cmd.cancel("focus-deadline"),
            Cmd.now("refresh_now"),
          ]),
        ];
      }
      return [next, Cmd.cancel("focus-deadline")];
      }
    }
    case "db_err": {
      const stale =
        exactAscii(msg.error, asciiBytes("stale_revision")) || exactAscii(msg.error, asciiBytes("stale_session"));
      if (stale) {
        return [
          {
            ...model,
            loadState: "loading",
            saving: false,
            hasWriteError: false,
            pendingKind: "load",
            undoTaskId: 0,
            undoTaskTitle: EMPTY,
            undoTaskState: "open",
          },
          Cmd.now("reload_now"),
        ];
      }
      if (model.pendingKind === "refresh") {
        // The user's mutation already committed. A contended best-effort
        // stats/timer refresh must never turn that success into a fatal boot
        // state; the next write, foreground reload, or relaunch refreshes it.
        return {
          ...model,
          saving: false,
          hasWriteError: false,
          writeErrorText: EMPTY,
          pendingKind: "none",
          pendingClockRollback: false,
          pendingNeedsFreshSnapshot: false,
          retryPayload: EMPTY,
        };
      }
      if (model.pendingKind === "load") {
        return {
          ...model,
          loadState: "fatal",
          fatalErrorText: friendlyFatalError(msg.error),
          saving: false,
          activeSession: null,
          settingsWindowOpen: false,
          quickWindowOpen: false,
          purgeDialogOpen: false,
          purgeAutofocus: false,
          purgeTaskId: 0,
          endDialogOpen: false,
          completionDialogOpen: false,
          breakAcknowledgementOpen: false,
          completionTaskId: 0,
          completionSessionId: 0,
          pendingKind: "none",
        };
      }
      const failed: Model = {
        ...model,
        saving: false,
        hasWriteError: true,
        writeErrorText: friendlyWriteError(msg.error),
      };
      if (model.pendingKind === "timer_pause" || model.pendingKind === "timer_resume") {
        return [failed, Cmd.delay("transport-autofocus", 1, "arm_transport_autofocus")];
      }
      return failed;
    }
    case "retry_save": {
      if (model.saving || model.retryPayload.length === 0) return model;
      const next: Model = {
        ...model,
        saving: true,
        hasWriteError: false,
        writeErrorText: EMPTY,
        pendingNeedsFreshSnapshot: true,
      };
      // Start and resume did not commit, so retrying their old wall-clock
      // timestamp would create retroactive focus time. Re-sample now and
      // rebuild only these payloads from the preserved intent/revision.
      if (model.pendingKind === "timer_start" || model.pendingKind === "timer_resume") {
        return [
          {
            ...next,
            pendingClockRollback: false,
            pendingNeedsFreshSnapshot: false,
            retryPayload: EMPTY,
          },
          Cmd.now("intent_now"),
        ];
      }
      if (model.pendingKind === "task_create") {
        return [next, Cmd.request("focus.db.task.create", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "task_rename") {
        return [next, Cmd.request("focus.db.task.rename", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "task_purge") {
        return [next, Cmd.request("focus.db.task.purge", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "task_undo_archive") {
        return [next, Cmd.request("focus.db.task.undo_archive", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (
        model.pendingKind === "task_state" ||
        model.pendingKind === "task_archive" ||
        model.pendingKind === "task_restore" ||
        model.pendingKind === "task_after_focus"
      ) {
        return [next, Cmd.request("focus.db.task.set_state", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "settings") {
        return [next, Cmd.request("focus.db.settings.set", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "timer_pause") {
        return [next, Cmd.request("focus.db.timer.pause", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "timer_cancel") {
        return [next, Cmd.request("focus.db.timer.cancel", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "timer_complete_natural" || model.pendingKind === "timer_complete_manual") {
        return [next, Cmd.request("focus.db.timer.complete", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      return { ...model, hasWriteError: false, saving: false };
    }
    case "discard_failed_change":
      return model.hasWriteError ? withoutFailedWrite(model) : model;
    case "tick": {
      if (model.saving || !validWallNow(msg.at)) return model;
      const at = msg.at;
      if (at === model.nowMs) return model;
      const live = model.activeSession;
      if (
        at < model.nowMs &&
        live !== null &&
        live.state === "running" &&
        at < live.endsMs
      ) {
        if (model.hasWriteError) return model;
        const payload = encodeTimerSession(model.revision, at, live.id);
        const pending = intentModel({ ...model, nowMs: at }, "timer_pause", live.id, "open", EMPTY, live.mode, 0);
        return [
          { ...pending, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.timer.pause", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      const next: Model = { ...model, nowMs: at };
      if (
        !naturalCompletionWriteBlocked(model) &&
        next.activeSession !== null &&
        next.activeSession.state === "running" &&
        at >= next.activeSession.endsMs
      ) {
        const sessionId = next.activeSession.id;
        const taskId = next.activeSession.taskId;
        const mode = next.activeSession.mode;
        const payload = encodeTimerComplete(next.revision, at, sessionId, "natural");
        return [
          {
            ...next,
            saving: true,
            pendingKind: "timer_complete_natural",
            pendingTaskId: taskId,
            pendingMode: mode,
            pendingNowMs: at,
            retryPayload: payload,
          },
          Cmd.request("focus.db.timer.complete", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      return next;
    }
    case "focus_due": {
      if (model.saving) return model;
      if (naturalCompletionWriteBlocked(model)) return model;
      if (model.activeSession === null) return model;
      if (model.activeSession.state !== "running") return model;
      if (!validWallNow(msg.at)) return model;
      const live = model.activeSession;
      const sessionId = live.id;
      const taskId = live.taskId;
      const mode = live.mode;
      const endsMs = live.endsMs;
      const at = msg.at;
      if (at < model.nowMs && at < endsMs) {
        const payload = encodeTimerSession(model.revision, at, sessionId);
        const pending = intentModel({ ...model, nowMs: at }, "timer_pause", sessionId, "open", EMPTY, mode, 0);
        return [
          { ...pending, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.timer.pause", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (at < endsMs) {
        const next: Model = { ...model, nowMs: at };
        const displayed = remainingMs(next);
        const delayMs = displayed > 0 ? displayed : endsMs - at;
        return [next, Cmd.delay("focus-deadline", delayMs, "focus_due")];
      }
      const payload = encodeTimerComplete(model.revision, at, sessionId, "natural");
      return [
        {
          ...model,
          nowMs: at,
          saving: true,
          pendingKind: "timer_complete_natural",
          pendingTaskId: taskId,
          pendingMode: mode,
          pendingNowMs: at,
          retryPayload: payload,
        },
        Cmd.request("focus.db.timer.complete", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
      ];
    }
    case "completion_sound_event":
      if (msg.state === "completed" || msg.state === "failed" || msg.state === "rejected") {
        return [model, Cmd.audioStop("completion-sound")];
      }
      return model;
    case "chrome_changed": {
      const leading = msg.buttons.x + msg.buttons.width + 12;
      const height = msg.insets.top > 52 ? msg.insets.top : 52;
      return { ...model, chromeLeading: leading > 12 ? leading : 70, headerHeight: height };
    }
    case "appearance_changed":
      return {
        ...model,
        colorScheme: msg.colorScheme,
        reduceMotion: msg.reduceMotion,
        highContrast: msg.highContrast,
      };
  }
}

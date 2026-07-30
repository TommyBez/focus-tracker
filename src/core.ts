import { Cmd, Sub, asciiBytes } from "@native-sdk/core";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";
import { type AudioState, type ChromeButtons, type ChromeInsets, type KeyEvent } from "@native-sdk/core/events";
import {
  decodeSnapshot,
  encodeLoad,
  encodeSettings,
  encodeTaskCreate,
  encodeTaskPurge,
  encodeTaskRename,
  encodeTaskState,
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
export type PendingKind =
  | "none"
  | "load"
  | "task_create"
  | "task_rename"
  | "task_state"
  | "task_archive"
  | "task_restore"
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
  readonly position: number;
  readonly toggleLabel: Bytes;
  readonly focusLabel: Bytes;
  readonly renameLabel: Bytes;
  readonly cancelRenameLabel: Bytes;
  readonly saveRenameLabel: Bytes;
  readonly archiveLabel: Bytes;
  readonly restoreLabel: Bytes;
  readonly purgeLabel: Bytes;
  readonly meta: Bytes;
  readonly hasMeta: boolean;
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
  readonly taskFilter: TaskFilter;
  readonly selectedTaskId: number;
  readonly actionTaskId: number;
  readonly editTaskId: number;
  readonly editDraftEditor: TextEditState;
  readonly paneFraction: number;
  readonly settingsWindowOpen: boolean;
  readonly quickWindowOpen: boolean;
  readonly purgeDialogOpen: boolean;
  readonly purgeTaskId: number;
  readonly endDialogOpen: boolean;
  readonly completionDialogOpen: boolean;
  readonly dialogSurface: DialogSurface;
  readonly pendingKind: PendingKind;
  readonly pendingTitle: Bytes;
  readonly pendingTaskId: number;
  readonly pendingTaskState: TaskState;
  readonly pendingMode: SessionMode;
  readonly pendingDurationMinutes: number;
  readonly pendingSettings: DbSettings;
  readonly pendingNowMs: number;
  readonly retryPayload: Bytes;
  readonly undoTaskId: number;
  readonly undoTaskTitle: Bytes;
  readonly completionTaskId: number;
  readonly completionSessionId: number;
  readonly nowMs: number;
  readonly historyLoadingMore: boolean;
}

export type Msg =
  | { readonly kind: "show_today" }
  | { readonly kind: "show_ledger" }
  | { readonly kind: "task_draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "add_task" }
  | { readonly kind: "select_task"; readonly id: number }
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
  | { readonly kind: "dismiss_completion" }
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
  | { readonly kind: "retry_boot" }
  | { readonly kind: "quit_app" }
  | { readonly kind: "pane_resized"; readonly fraction: number }
  | { readonly kind: "load_more_history" }
  | { readonly kind: "new_task_command" }
  | { readonly kind: "today_command" }
  | { readonly kind: "ledger_command" }
  | { readonly kind: "toggle_focus_command" }
  | { readonly kind: "quick_toggle_command" }
  | { readonly kind: "quit_command" }
  | { readonly kind: "show_window" }
  | { readonly kind: "escape_pressed" }
  | { readonly kind: "boot_ready"; readonly at: number }
  | { readonly kind: "intent_now"; readonly at: number }
  | { readonly kind: "reload_now"; readonly at: number }
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
    };

export const chromeMsg = "chrome_changed";

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
  "purgeTaskId",
  "pendingKind",
  "pendingTitle",
  "pendingTaskId",
  "pendingTaskState",
  "pendingMode",
  "pendingDurationMinutes",
  "pendingSettings",
  "pendingNowMs",
  "retryPayload",
  "undoTaskId",
  "undoTaskTitle",
  "completionTaskId",
  "completionSessionId",
  "nowMs",
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
  "boot_ready",
  "intent_now",
  "reload_now",
  "db_ok",
  "db_err",
  "tick",
  "focus_due",
  "completion_sound_event",
  "chrome_changed",
] as const;

const EMPTY = asciiBytes("");
const TITLE_CAPACITY = 240;
const DEFAULT_PANE = 0.42;
const FOCUS_PANE = 0.34;
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
    taskFilter: "open",
    selectedTaskId: -1,
    actionTaskId: -1,
    editTaskId: -1,
    editDraftEditor: emptyEditor(),
    paneFraction: DEFAULT_PANE,
    settingsWindowOpen: false,
    quickWindowOpen: false,
    purgeDialogOpen: false,
    purgeTaskId: 0,
    endDialogOpen: false,
    completionDialogOpen: false,
    dialogSurface: "main",
    pendingKind: "load",
    pendingTitle: EMPTY,
    pendingTaskId: 0,
    pendingTaskState: "open",
    pendingMode: "focus",
    pendingDurationMinutes: 25,
    pendingSettings: defaultSettings(),
    pendingNowMs: 0,
    retryPayload: EMPTY,
    undoTaskId: 0,
    undoTaskTitle: EMPTY,
    completionTaskId: 0,
    completionSessionId: 0,
    nowMs: 0,
    historyLoadingMore: false,
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

function safeNow(previous: number, incoming: number): number {
  if (incoming < previous || incoming > MAX_SAFE_TIME) return previous;
  return incoming;
}

function authoritativeNow(model: Model, session: DbSession | null, operation: PendingKind): number {
  let base = safeNow(model.nowMs, model.pendingNowMs);
  if (session === null) return base;
  if (operation === "timer_pause") return base;
  if (operation !== "timer_resume" || session.state !== "running") return base;
  const responseBase = session.endsMs >= session.remainingMs ? session.endsMs - session.remainingMs : 0;
  base = safeNow(base, responseBase);
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
  // Keep a failed natural-completion request user-retriable instead of
  // hammering SQLite every display tick. Errors from every other operation
  // must not strand an independently running authoritative session.
  return model.hasWriteError && model.pendingKind === "timer_complete_natural";
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
  return model.purgeDialogOpen || model.endDialogOpen || model.completionDialogOpen;
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
    saving: true,
    hasWriteError: false,
    writeErrorText: EMPTY,
    pendingKind: kind,
    pendingTaskId: taskId,
    pendingTaskState: taskState,
    pendingTitle: title,
    pendingMode: mode,
    pendingDurationMinutes: durationMinutes,
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
    retryPayload: EMPTY,
  };
}

function eligibleTask(model: Model, id: number): boolean {
  const task = taskById(model.tasks, id);
  return task !== null && task.state === "open";
}

export function taskDraft(model: Model): Bytes {
  return model.taskDraftEditor.text;
}

export function canAddTask(model: Model): boolean {
  return model.loadState === "ready" && !model.saving && model.taskDraftEditor.text.trim().length > 0;
}

export function editDraft(model: Model): Bytes {
  return model.editDraftEditor.text;
}

export function canCommitRename(model: Model): boolean {
  return model.editTaskId > 0 && !model.saving && model.editDraftEditor.text.trim().length > 0;
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
  return tasks.map((task, index) => ({
    id: task.id,
    title: task.title,
    done: task.state === "completed",
    archived: task.state === "archived",
    position: index + 1,
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
    meta: task.estimateMinutes > 0 ? asciiBytes(`${task.estimateMinutes} minute estimate`) : EMPTY,
    hasMeta: task.estimateMinutes > 0,
  }));
}

export function quickTasks(model: Model): readonly QuickTaskRow[] {
  return model.tasks
    .filter((task) => task.state === "open")
    .toSorted((a, b) => a.sortOrder - b.sortOrder)
    .slice(0, 3)
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
    !hasBlockingDialog(model) &&
    model.activeSession === null &&
    eligibleTask(model, model.selectedTaskId)
  );
}

export function quickControlsDisabled(model: Model): boolean {
  return model.saving || hasBlockingDialog(model);
}

export function quickStartLabel(model: Model): Bytes {
  return asciiBytes(`Start ${model.settings.focusMinutes} minutes`);
}

export function quickStatusLabel(model: Model): Bytes {
  const state = sessionState(model);
  if (state === "complete") return asciiBytes("RECORDED");
  if (state === "paused") return asciiBytes("PAUSED");
  if (state === "running") return isBreak(model) ? asciiBytes("ON BREAK") : asciiBytes("FOCUSING");
  return asciiBytes("READY");
}

export function mainEndDialogOpen(model: Model): boolean {
  return model.endDialogOpen && model.dialogSurface === "main";
}

export function quickEndDialogOpen(model: Model): boolean {
  return model.endDialogOpen && model.dialogSurface === "quick";
}

export function mainCompletionDialogOpen(model: Model): boolean {
  return model.completionDialogOpen && model.dialogSurface === "main";
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

function actionTask(model: Model): DbTask | null {
  const task = taskById(model.tasks, model.actionTaskId);
  if (task === null || task.state !== model.taskFilter) return null;
  return task;
}

export function hasActionTask(model: Model): boolean {
  return actionTask(model) !== null;
}

export function actionTaskTitle(model: Model): Bytes {
  const task = actionTask(model);
  return task === null ? EMPTY : task.title;
}

export function actionTaskIsOpen(model: Model): boolean {
  const task = actionTask(model);
  return task !== null && task.state === "open";
}

export function actionTaskIsCompleted(model: Model): boolean {
  const task = actionTask(model);
  return task !== null && task.state === "completed";
}

export function actionTaskIsArchived(model: Model): boolean {
  const task = actionTask(model);
  return task !== null && task.state === "archived";
}

export function actionRenameLabel(model: Model): Bytes {
  return concat2(asciiBytes("Rename "), actionTaskTitle(model));
}

export function actionFocusLabel(model: Model): Bytes {
  return concat2(asciiBytes("Focus on "), actionTaskTitle(model));
}

export function actionDoneLabel(model: Model): Bytes {
  return concat3(asciiBytes("Mark "), actionTaskTitle(model), asciiBytes(" complete"));
}

export function actionArchiveLabel(model: Model): Bytes {
  return concat2(asciiBytes("Archive "), actionTaskTitle(model));
}

export function actionReopenLabel(model: Model): Bytes {
  return concat2(asciiBytes("Reopen "), actionTaskTitle(model));
}

export function actionRestoreLabel(model: Model): Bytes {
  return concat2(asciiBytes("Restore "), actionTaskTitle(model));
}

export function actionPurgeLabel(model: Model): Bytes {
  return concat2(asciiBytes("Permanently delete "), actionTaskTitle(model));
}

export function hasUndo(model: Model): boolean {
  return model.undoTaskId > 0;
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

export function shortBreakMinutes(model: Model): number {
  return model.settings.shortBreakMinutes;
}

export function longBreakMinutes(model: Model): number {
  return model.settings.longBreakMinutes;
}

export function dailyGoalMinutes(model: Model): number {
  return model.settings.dailyGoalMinutes;
}

export function soundEnabled(model: Model): boolean {
  return model.settings.soundEnabled;
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

export function endsAtText(model: Model): Bytes {
  if (model.activeSession === null) return EMPTY;
  if (model.activeSession.state === "paused") return asciiBytes("Deadline paused · remaining time is preserved");
  return asciiBytes("Deadline armed · protected across sleep and window close");
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

export function hasWeekFocus(model: Model): boolean {
  return model.stats.weekFocusMs.some((day) => day.milliseconds > 0);
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

function weekSessionCount(model: Model): number {
  const oldest = model.nowMs > 604800000 ? model.nowMs - 604800000 : 0;
  return model.recentSessions.filter(
    (session) => session.state === "completed" && session.mode === "focus" && session.endedMs >= oldest,
  ).length;
}

export function weekSessionText(model: Model): Bytes {
  const count = weekSessionCount(model);
  return count === 1 ? asciiBytes("1 recent session") : asciiBytes(`${count} recent sessions`);
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
  if (model.activeSession === null) return Sub.none;
  if (model.activeSession.state !== "running") return Sub.none;
  return Sub.timer("focus-display", 250, "tick");
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "show_today":
      return { ...model, section: "today" };
    case "show_ledger":
      return { ...model, section: "ledger" };
    case "task_draft_edit":
      return { ...model, taskDraftEditor: editApplied(model.taskDraftEditor, msg.edit) };
    case "add_task": {
      if (model.saving || hasBlockingDialog(model) || model.loadState !== "ready") return model;
      const title = model.taskDraftEditor.text.trim();
      if (title.length === 0) return model;
      return [intentModel(model, "task_create", 0, "open", title, "focus", model.settings.focusMinutes), Cmd.now("intent_now")];
    }
    case "select_task": {
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state !== model.taskFilter) return model;
      return {
        ...model,
        actionTaskId: msg.id,
        selectedTaskId: task.state === "open" ? msg.id : -1,
      };
    }
    case "select_quick_task": {
      if (model.saving || hasBlockingDialog(model) || model.activeSession !== null) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state !== "open") return model;
      return {
        ...model,
        section: "today",
        taskFilter: "open",
        selectedTaskId: task.id,
        actionTaskId: task.id,
      };
    }
    case "toggle_task": {
      if (model.saving) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state === "archived") return model;
      const nextState: TaskState = task.state === "completed" ? "open" : "completed";
      return [intentModel(model, "task_state", task.id, nextState, EMPTY, "focus", 0), Cmd.now("intent_now")];
    }
    case "start_focus_task": {
      if (model.saving || hasBlockingDialog(model) || model.activeSession !== null || !eligibleTask(model, msg.id)) return model;
      const selected: Model = { ...model, selectedTaskId: msg.id, actionTaskId: msg.id, taskFilter: "open" };
      return [
        intentModel(selected, "timer_start", msg.id, "open", EMPTY, "focus", model.settings.focusMinutes),
        Cmd.now("intent_now"),
      ];
    }
    case "begin_rename": {
      const task = taskById(model.tasks, msg.id);
      if (model.saving || task === null || task.state === "archived") return model;
      return { ...model, editTaskId: task.id, editDraftEditor: editorFor(task.title) };
    }
    case "edit_draft_edit":
      return { ...model, editDraftEditor: editApplied(model.editDraftEditor, msg.edit) };
    case "commit_rename": {
      if (model.saving || model.editTaskId < 1) return model;
      const title = model.editDraftEditor.text.trim();
      if (title.length === 0) return model;
      return [intentModel(model, "task_rename", model.editTaskId, "open", title, "focus", 0), Cmd.now("intent_now")];
    }
    case "cancel_rename":
      return { ...model, editTaskId: -1, editDraftEditor: emptyEditor() };
    case "delete_task": {
      if (model.saving) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state === "archived") return model;
      return [intentModel(model, "task_archive", task.id, "archived", task.title, "focus", 0), Cmd.now("intent_now")];
    }
    case "show_open_tasks":
      return {
        ...model,
        taskFilter: "open",
        selectedTaskId: normalizedSelectedTaskId(model.tasks, model.selectedTaskId),
        actionTaskId: normalizedActionTaskId(model.tasks, "open", model.actionTaskId),
      };
    case "show_completed_tasks":
      return {
        ...model,
        taskFilter: "completed",
        selectedTaskId: -1,
        actionTaskId: normalizedActionTaskId(model.tasks, "completed", model.actionTaskId),
      };
    case "show_archived_tasks":
      return {
        ...model,
        taskFilter: "archived",
        selectedTaskId: -1,
        actionTaskId: normalizedActionTaskId(model.tasks, "archived", model.actionTaskId),
      };
    case "restore_task": {
      if (model.saving) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state !== "archived") return model;
      return [
        intentModel(model, "task_restore", task.id, "open", task.title, "focus", 0),
        Cmd.now("intent_now"),
      ];
    }
    case "request_purge_task": {
      if (model.saving || model.activeSession !== null) return model;
      const task = taskById(model.tasks, msg.id);
      if (task === null || task.state !== "archived") return model;
      return {
        ...model,
        purgeDialogOpen: true,
        purgeTaskId: task.id,
        settingsWindowOpen: false,
        quickWindowOpen: false,
        endDialogOpen: false,
        completionDialogOpen: false,
        completionTaskId: 0,
        completionSessionId: 0,
      };
    }
    case "cancel_purge_task":
      return { ...model, purgeDialogOpen: false, purgeTaskId: 0 };
    case "confirm_purge_task": {
      if (model.saving || !model.purgeDialogOpen) return model;
      const task = taskById(model.tasks, model.purgeTaskId);
      if (task === null || task.state !== "archived") {
        return { ...model, purgeDialogOpen: false, purgeTaskId: 0 };
      }
      const confirmed: Model = { ...model, purgeDialogOpen: false, purgeTaskId: 0 };
      return [intentModel(confirmed, "task_purge", task.id, "archived", task.title, "focus", 0), Cmd.now("intent_now")];
    }
    case "undo_delete":
      if (model.saving || model.undoTaskId === 0) return model;
      return [
        intentModel(model, "task_restore", model.undoTaskId, "open", model.undoTaskTitle, "focus", 0),
        Cmd.now("intent_now"),
      ];
    case "dismiss_undo":
      return { ...model, undoTaskId: 0, undoTaskTitle: EMPTY };
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
      return model.saving || model.activeSession === null
        ? model
        : { ...model, endDialogOpen: true, dialogSurface: "main" };
    case "request_quick_end_focus":
      return model.saving || model.activeSession === null
        ? model
        : { ...model, endDialogOpen: true, dialogSurface: "quick" };
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
      return { ...model, endDialogOpen: false };
    case "complete_task_after_focus":
      if (model.saving) return model;
      if (model.completionTaskId === 0) {
        return {
          ...model,
          completionDialogOpen: false,
          completionSessionId: 0,
          paneFraction: DEFAULT_PANE,
          composerKey: model.composerKey + 1,
        };
      }
      return [
        intentModel(model, "task_after_focus", model.completionTaskId, "completed", EMPTY, "focus", 0),
        Cmd.now("intent_now"),
      ];
    case "keep_task_open_after_focus":
      return {
        ...model,
        completionDialogOpen: false,
        completionTaskId: 0,
        completionSessionId: 0,
        paneFraction: DEFAULT_PANE,
        composerKey: model.composerKey + 1,
      };
    case "start_break": {
      if (model.saving || model.activeSession !== null) return model;
      const longBreak = model.stats.todayCompletedSessions > 0 && model.stats.todayCompletedSessions % 4 === 0;
      const mode: SessionMode = longBreak ? "long" : "short";
      const minutes = longBreak ? model.settings.longBreakMinutes : model.settings.shortBreakMinutes;
      return [intentModel(model, "timer_start", 0, "open", EMPTY, mode, minutes), Cmd.now("intent_now")];
    }
    case "dismiss_completion":
      return {
        ...model,
        completionDialogOpen: false,
        completionTaskId: 0,
        completionSessionId: 0,
        paneFraction: DEFAULT_PANE,
        composerKey: model.composerKey + 1,
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
      if (model.loadState !== "ready" || hasBlockingDialog(model)) return model;
      if (model.quickWindowOpen) {
        return [
          { ...model, settingsWindowOpen: false },
          Cmd.showWindow("quick"),
        ];
      }
      return [
        {
          ...model,
          quickWindowOpen: true,
          settingsWindowOpen: false,
        },
        Cmd.delay("quick-activate", 1, "raise_quick"),
      ];
    case "raise_quick":
      if (!model.quickWindowOpen) return model;
      return [model, Cmd.showWindow("quick")];
    case "close_quick":
      if (
        model.dialogSurface === "quick" &&
        (model.endDialogOpen || model.completionDialogOpen)
      ) {
        return [
          { ...model, quickWindowOpen: false, dialogSurface: "main" },
          Cmd.showWindow("main"),
        ];
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
      if (model.saving || model.activeSession === null) return model;
      return [
        {
          ...model,
          quickWindowOpen: true,
          endDialogOpen: true,
          dialogSurface: "quick",
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
      const low = msg.fraction < 0.30 ? 0.30 : msg.fraction;
      const high = low > 0.58 ? 0.58 : low;
      return { ...model, paneFraction: high };
    }
    case "load_more_history":
      return model;
    case "new_task_command":
      if (hasBlockingSurface(model) || model.loadState !== "ready") return model;
      return {
        ...model,
        section: "today",
        taskFilter: "open",
        selectedTaskId: normalizedSelectedTaskId(model.tasks, model.selectedTaskId),
        actionTaskId: normalizedActionTaskId(model.tasks, "open", model.actionTaskId),
        composerKey: model.composerKey + 1,
      };
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
      if (hasBlockingSurface(model)) return model;
      return [model, Cmd.quitApp()];
    case "show_window":
      return [model, Cmd.showWindow("main")];
    case "escape_pressed":
      if (model.purgeDialogOpen) return { ...model, purgeDialogOpen: false, purgeTaskId: 0 };
      if (model.endDialogOpen) return { ...model, endDialogOpen: false };
      if (model.completionDialogOpen) {
        return {
          ...model,
          completionDialogOpen: false,
          completionTaskId: 0,
          completionSessionId: 0,
          paneFraction: DEFAULT_PANE,
          composerKey: model.composerKey + 1,
        };
      }
      // The SDK key fallback intentionally has no source-window identity.
      // Secondary windows are mutually exclusive, so dismissing the sole
      // auxiliary surface first can never close a sibling in the background.
      if (model.quickWindowOpen) return { ...model, quickWindowOpen: false };
      if (model.settingsWindowOpen) return { ...model, settingsWindowOpen: false };
      if (model.editTaskId > 0) return { ...model, editTaskId: -1, editDraftEditor: emptyEditor() };
      return model;
    case "boot_ready": {
      const payload = encodeLoad(msg.at);
      return [
        { ...model, pendingKind: "load", pendingNowMs: msg.at, retryPayload: payload },
        Cmd.request("focus.db.load", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
      ];
    }
    case "reload_now": {
      const at = safeNow(model.nowMs, msg.at);
      const payload = encodeLoad(at);
      return [
        {
          ...model,
          pendingKind: "load",
          pendingNowMs: at,
          retryPayload: payload,
          saving: false,
        },
        Cmd.request("focus.db.load", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
      ];
    }
    case "intent_now": {
      const at = safeNow(model.nowMs, msg.at);
      if (model.pendingKind === "task_create") {
        const payload = encodeTaskCreate(model.revision, at, model.settings.focusMinutes, model.pendingTitle);
        return [
          { ...model, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.task.create", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "task_rename") {
        const payload = encodeTaskRename(model.revision, at, model.pendingTaskId, model.pendingTitle);
        return [
          { ...model, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.task.rename", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "task_purge") {
        const payload = encodeTaskPurge(model.revision, at, model.pendingTaskId);
        return [
          { ...model, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.task.purge", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
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
          { ...model, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.task.set_state", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "settings") {
        const payload = encodeSettings(model.revision, at, model.pendingSettings);
        return [
          { ...model, pendingNowMs: at, retryPayload: payload },
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
          { ...model, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.timer.start", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.activeSession === null) return { ...model, saving: false, pendingKind: "none" };
      const sessionId = model.activeSession.id;
      if (model.pendingKind === "timer_pause") {
        const payload = encodeTimerSession(model.revision, at, sessionId);
        return [
          { ...model, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.timer.pause", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "timer_resume") {
        const payload = encodeTimerSession(model.revision, at, sessionId);
        return [
          { ...model, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.timer.resume", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "timer_cancel") {
        const payload = encodeTimerSession(model.revision, at, sessionId);
        return [
          { ...model, pendingNowMs: at, retryPayload: payload },
          Cmd.request("focus.db.timer.cancel", payload, { key: "focus-db", ok: "db_ok", err: "db_err" }),
        ];
      }
      if (model.pendingKind === "timer_complete_manual") {
        const payload = encodeTimerComplete(model.revision, at, sessionId, "manual");
        return [
          { ...model, pendingNowMs: at, retryPayload: payload },
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
          settingsWindowOpen: false,
          quickWindowOpen: false,
          purgeDialogOpen: false,
          purgeTaskId: 0,
          endDialogOpen: false,
          completionDialogOpen: false,
          completionTaskId: 0,
          completionSessionId: 0,
          pendingKind: "none",
        };
      } else {
      const snapshot = decoded.value;
      const operation = model.pendingKind;
      let selected =
        model.taskFilter === "open" ? normalizedSelectedTaskId(snapshot.tasks, model.selectedTaskId) : -1;
      let action = normalizedActionTaskId(snapshot.tasks, model.taskFilter, model.actionTaskId);
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
        pendingKind: "none",
        retryPayload: EMPTY,
        nowMs: authoritativeNow(model, snapshot.activeSession, operation),
      };
      if (operation === "task_create" && bytesEqual(model.taskDraftEditor.text.trim(), model.pendingTitle)) {
        next = {
          ...next,
          section: "today",
          taskFilter: "open",
          taskDraftEditor: emptyEditor(),
        };
      }
      if (operation === "task_rename" && bytesEqual(model.editDraftEditor.text.trim(), model.pendingTitle)) {
        next = { ...next, editTaskId: -1, editDraftEditor: emptyEditor() };
      }
      if (operation === "task_archive") {
        next = {
          ...next,
          undoTaskId: model.pendingTaskId,
          undoTaskTitle: model.pendingTitle,
          selectedTaskId:
            model.taskFilter === "open" ? normalizedSelectedTaskId(snapshot.tasks, model.pendingTaskId) : -1,
          actionTaskId: firstTaskIdForFilter(snapshot.tasks, model.taskFilter),
        };
      }
      if (operation === "task_restore") {
        const restoredVisible = model.taskFilter === "open";
        next = {
          ...next,
          undoTaskId: 0,
          undoTaskTitle: EMPTY,
          selectedTaskId: restoredVisible ? model.pendingTaskId : -1,
          actionTaskId: restoredVisible
            ? model.pendingTaskId
            : firstTaskIdForFilter(snapshot.tasks, model.taskFilter),
        };
      }
      if (operation === "task_purge") {
        next = {
          ...next,
          purgeDialogOpen: false,
          purgeTaskId: 0,
          undoTaskId: model.undoTaskId === model.pendingTaskId ? 0 : model.undoTaskId,
          undoTaskTitle: model.undoTaskId === model.pendingTaskId ? EMPTY : model.undoTaskTitle,
          actionTaskId: firstTaskIdForFilter(snapshot.tasks, model.taskFilter),
        };
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
      }
      if (operation === "timer_start") {
        next = {
          ...next,
          taskFilter: "open",
          actionTaskId: model.pendingTaskId > 0 ? model.pendingTaskId : firstOpenTaskId(snapshot.tasks),
          section: "today",
          paneFraction: FOCUS_PANE,
          completionDialogOpen: false,
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
          completionTaskId: 0,
          completionSessionId: 0,
          composerKey: next.composerKey + 1,
        };
      }
      if (operation === "timer_complete_natural" || operation === "timer_complete_manual") {
        const wasFocus = model.pendingMode === "focus";
        let completedSessionId = 0;
        if (wasFocus) {
          const completed = model.activeSession;
          if (completed !== null) completedSessionId = completed.id;
        }
        next = {
          ...next,
          quickWindowOpen:
            operation === "timer_complete_natural" ? true : next.quickWindowOpen,
          completionDialogOpen: wasFocus,
          completionTaskId: wasFocus ? model.pendingTaskId : 0,
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
          completionTaskId: 0,
          completionSessionId: 0,
          paneFraction: DEFAULT_PANE,
          selectedTaskId: firstOpenTaskId(snapshot.tasks),
          actionTaskId: firstOpenTaskId(snapshot.tasks),
          composerKey: next.composerKey + 1,
        };
      }
      if (next.activeSession !== null) {
        if (next.activeSession.state === "running") {
          const sessionId = next.activeSession.id;
          const taskId = next.activeSession.taskId;
          const mode = next.activeSession.mode;
          const delayMs = remainingMs(next);
          if (delayMs > 0) return [next, Cmd.delay("focus-deadline", delayMs, "focus_due")];
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
        if (model.pendingMode !== "focus" || !next.settings.soundEnabled) {
          return [
            next,
            Cmd.batch<Msg>([
              Cmd.cancel("focus-deadline"),
              Cmd.delay<Msg>("quick-activate", 1, "raise_quick"),
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
          },
          Cmd.now("reload_now"),
        ];
      }
      if (model.pendingKind === "load") {
        return {
          ...model,
          loadState: "fatal",
          fatalErrorText: friendlyFatalError(msg.error),
          saving: false,
          settingsWindowOpen: false,
          quickWindowOpen: false,
          purgeDialogOpen: false,
          purgeTaskId: 0,
          endDialogOpen: false,
          completionDialogOpen: false,
          completionTaskId: 0,
          completionSessionId: 0,
          pendingKind: "none",
        };
      }
      return {
        ...model,
        saving: false,
        hasWriteError: true,
        writeErrorText: friendlyWriteError(msg.error),
      };
    }
    case "retry_save": {
      if (model.saving || model.retryPayload.length === 0) return model;
      const next: Model = { ...model, saving: true, hasWriteError: false, writeErrorText: EMPTY };
      if (model.pendingKind === "task_create") {
        return [next, Cmd.request("focus.db.task.create", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "task_rename") {
        return [next, Cmd.request("focus.db.task.rename", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "task_purge") {
        return [next, Cmd.request("focus.db.task.purge", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
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
      if (model.pendingKind === "timer_start") {
        return [next, Cmd.request("focus.db.timer.start", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "timer_pause") {
        return [next, Cmd.request("focus.db.timer.pause", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "timer_resume") {
        return [next, Cmd.request("focus.db.timer.resume", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "timer_cancel") {
        return [next, Cmd.request("focus.db.timer.cancel", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      if (model.pendingKind === "timer_complete_natural" || model.pendingKind === "timer_complete_manual") {
        return [next, Cmd.request("focus.db.timer.complete", model.retryPayload, { key: "focus-db", ok: "db_ok", err: "db_err" })];
      }
      return { ...model, hasWriteError: false, saving: false };
    }
    case "tick": {
      const at = safeNow(model.nowMs, msg.at);
      if (at === model.nowMs) return model;
      const next: Model = { ...model, nowMs: at };
      if (
        !model.saving &&
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
      const sessionId = model.activeSession.id;
      const taskId = model.activeSession.taskId;
      const mode = model.activeSession.mode;
      const endsMs = model.activeSession.endsMs;
      const observed = safeNow(model.nowMs, msg.at);
      const at = observed < endsMs ? endsMs : observed;
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
  }
}

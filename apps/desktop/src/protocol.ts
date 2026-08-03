import { asciiBytes } from "@native-sdk/core";

export type Bytes = Uint8Array;
export type TaskState = "open" | "completed" | "archived";
export type SessionMode = "focus" | "short" | "long";
export type SessionState = "running" | "paused" | "completed" | "cancelled";
export type CompletionReason = "none" | "natural" | "manual" | "recovered";
export type TimerCompleteReason = "natural" | "manual";
export type QuickShortcutKey = "f" | "q" | "k" | "t" | "p" | "space";
export type QuickShortcutModifiers =
  | "command_shift"
  | "command_option"
  | "control_shift"
  | "control_option"
  | "command_control"
  | "command_control_shift";

export interface DbSettings {
  readonly focusMinutes: number;
  readonly shortBreakMinutes: number;
  readonly longBreakMinutes: number;
  readonly dailyGoalMinutes: number;
  readonly soundEnabled: boolean;
  readonly quickShortcutEnabled: boolean;
  readonly quickShortcutKey: QuickShortcutKey;
  readonly quickShortcutModifiers: QuickShortcutModifiers;
}

export interface DbTask {
  readonly id: number;
  readonly state: TaskState;
  readonly sortOrder: number;
  readonly estimateMinutes: number;
  readonly createdMs: number;
  readonly updatedMs: number;
  readonly completedMs: number;
  readonly title: Bytes;
}

export interface DbSession {
  readonly id: number;
  readonly taskId: number;
  readonly mode: SessionMode;
  readonly state: SessionState;
  readonly completionReason: CompletionReason;
  readonly startedMs: number;
  readonly endsMs: number;
  readonly remainingMs: number;
  readonly plannedMs: number;
  readonly focusedMs: number;
  readonly endedMs: number;
}

export interface DbStats {
  readonly todayFocusMs: number;
  readonly todayCompletedSessions: number;
  readonly todayCompletedTasks: number;
  readonly todayWeekday: number;
  readonly weekFocusMs: readonly DbDayFocus[];
}

export interface DbDayFocus {
  readonly milliseconds: number;
}

export interface DbSnapshot {
  readonly revision: number;
  readonly settings: DbSettings;
  readonly nextTaskId: number;
  readonly tasks: readonly DbTask[];
  readonly activeSession: DbSession | null;
  readonly recentSessions: readonly DbSession[];
  readonly stats: DbStats;
}

export interface SnapshotDecode {
  readonly ok: boolean;
  readonly value: DbSnapshot;
  readonly detail: Bytes;
}

const MAX_SAFE_U64 = 9007199254740991;
const MAX_SNAPSHOT_BYTES = 98304;
const MAX_TASKS = 256;
const MAX_TITLE_BYTES = 240;
const MAX_RECENT_SESSIONS = 14;

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

function encodeU32Part(value: number): Bytes {
  const out = new Uint8Array(4);
  let rest = value;
  for (let i = 0; i < 4; i++) {
    out[i] = rest % 256;
    rest = intDiv(rest, 256);
  }
  return out;
}

function encodeU64Part(value: number): Bytes {
  const out = new Uint8Array(8);
  let rest = value;
  for (let i = 0; i < 8; i++) {
    out[i] = rest % 256;
    rest = intDiv(rest, 256);
  }
  return out;
}

function mutationPrefix(revision: number, nowMs: number): Bytes {
  const out = new Uint8Array(24);
  out[0] = 0x46;
  out[1] = 0x43;
  out[2] = 0x4d;
  out[3] = 0x31;
  out.set(encodeU32Part(1), 4);
  out.set(encodeU64Part(revision), 8);
  out.set(encodeU64Part(nowMs), 16);
  return out;
}

class BinaryReader {
  data: Bytes;
  at: number;
  failed: boolean;

  constructor(data: Bytes) {
    this.data = data;
    this.at = 0;
    this.failed = false;
  }

  remaining(): number {
    return this.data.length - this.at;
  }

  magic(a: number, b: number, c: number, d: number): boolean {
    if (this.remaining() < 4) {
      this.failed = true;
      return false;
    }
    const ok =
      this.data[this.at] === a &&
      this.data[this.at + 1] === b &&
      this.data[this.at + 2] === c &&
      this.data[this.at + 3] === d;
    this.at += 4;
    if (!ok) this.failed = true;
    return ok;
  }

  u8(): number {
    if (this.remaining() < 1) {
      this.failed = true;
      return 0;
    }
    const value = this.data[this.at];
    this.at += 1;
    return value;
  }

  u32(): number {
    if (this.remaining() < 4) {
      this.failed = true;
      return 0;
    }
    let value = 0;
    let factor = 1;
    for (let i = 0; i < 4; i++) {
      value += this.data[this.at + i] * factor;
      factor *= 256;
    }
    this.at += 4;
    return value;
  }

  u64(): number {
    if (this.remaining() < 8) {
      this.failed = true;
      return 0;
    }
    const high = this.data[this.at + 7];
    const upper = this.data[this.at + 6];
    if (high !== 0 || upper > 31) {
      this.failed = true;
      this.at += 8;
      return 0;
    }
    let value = 0;
    let factor = 1;
    for (let i = 0; i < 7; i++) {
      value += this.data[this.at + i] * factor;
      factor *= 256;
    }
    this.at += 8;
    if (value > MAX_SAFE_U64) this.failed = true;
    return value;
  }

  bytes(length: number): Bytes {
    if (length < 0 || length > this.remaining()) {
      this.failed = true;
      return new Uint8Array(0);
    }
    const value = this.data.slice(this.at, this.at + length);
    this.at += length;
    return value;
  }

  session(): DbSession {
    const id = this.u64();
    const taskId = this.u64();
    const modeWire = this.u8();
    const stateWire = this.u8();
    const reasonWire = this.u8();
    const startedMs = this.u64();
    const endsMs = this.u64();
    const remainingMs = this.u64();
    const plannedMs = this.u64();
    const focusedMs = this.u64();
    const endedMs = this.u64();
    if (
      id === 0 ||
      modeWire > 2 ||
      stateWire > 3 ||
      reasonWire > 3 ||
      plannedMs === 0 ||
      remainingMs > plannedMs ||
      focusedMs > plannedMs
    ) {
      this.failed = true;
    }
    return {
      id: id,
      taskId: taskId,
      mode: sessionModeFromWire(modeWire),
      state: sessionStateFromWire(stateWire),
      completionReason: completionReasonFromWire(reasonWire),
      startedMs: startedMs,
      endsMs: endsMs,
      remainingMs: remainingMs,
      plannedMs: plannedMs,
      focusedMs: focusedMs,
      endedMs: endedMs,
    };
  }
}

function taskStateFromWire(value: number): TaskState {
  if (value === 1) return "completed";
  if (value === 2) return "archived";
  return "open";
}

function sessionModeFromWire(value: number): SessionMode {
  if (value === 1) return "short";
  if (value === 2) return "long";
  return "focus";
}

function sessionStateFromWire(value: number): SessionState {
  if (value === 1) return "paused";
  if (value === 2) return "completed";
  if (value === 3) return "cancelled";
  return "running";
}

function completionReasonFromWire(value: number): CompletionReason {
  if (value === 1) return "natural";
  if (value === 2) return "manual";
  if (value === 3) return "recovered";
  return "none";
}

function quickShortcutKeyFromWire(value: number): QuickShortcutKey {
  if (value === 1) return "q";
  if (value === 2) return "k";
  if (value === 3) return "t";
  if (value === 4) return "p";
  if (value === 5) return "space";
  return "f";
}

function quickShortcutModifiersFromWire(value: number): QuickShortcutModifiers {
  if (value === 1) return "command_option";
  if (value === 2) return "control_shift";
  if (value === 3) return "control_option";
  if (value === 4) return "command_control";
  if (value === 5) return "command_control_shift";
  return "command_shift";
}

function quickShortcutKeyWire(value: QuickShortcutKey): number {
  if (value === "q") return 1;
  if (value === "k") return 2;
  if (value === "t") return 3;
  if (value === "p") return 4;
  if (value === "space") return 5;
  return 0;
}

function quickShortcutModifiersWire(value: QuickShortcutModifiers): number {
  if (value === "command_option") return 1;
  if (value === "control_shift") return 2;
  if (value === "control_option") return 3;
  if (value === "command_control") return 4;
  if (value === "command_control_shift") return 5;
  return 0;
}

function settingsValid(settings: DbSettings): boolean {
  return (
    settings.focusMinutes >= 1 &&
    settings.focusMinutes <= 180 &&
    settings.shortBreakMinutes >= 1 &&
    settings.shortBreakMinutes <= 60 &&
    settings.longBreakMinutes >= 1 &&
    settings.longBreakMinutes <= 120 &&
    settings.dailyGoalMinutes >= 1 &&
    settings.dailyGoalMinutes <= 1440
  );
}

function titleCodepointRejected(codepoint: number): boolean {
  return (
    codepoint <= 0x1f ||
    (codepoint >= 0x7f && codepoint <= 0x9f) ||
    codepoint === 0x2028 ||
    codepoint === 0x2029 ||
    codepoint === 0x061c ||
    codepoint === 0x200e ||
    codepoint === 0x200f ||
    (codepoint >= 0x202a && codepoint <= 0x202e) ||
    (codepoint >= 0x2066 && codepoint <= 0x2069)
  );
}

function titleCodepointWhitespace(codepoint: number): boolean {
  return (
    codepoint === 0x20 ||
    codepoint === 0x00a0 ||
    codepoint === 0x1680 ||
    (codepoint >= 0x2000 && codepoint <= 0x200a) ||
    codepoint === 0x2028 ||
    codepoint === 0x2029 ||
    codepoint === 0x202f ||
    codepoint === 0x205f ||
    codepoint === 0x3000 ||
    codepoint === 0xfeff
  );
}

// Bounded UTF-8 walk shared semantically with the SQLite host validator.
// The TS core has no TextDecoder; decoding explicitly also makes malformed,
// overlong, surrogate, and out-of-range sequences fail closed.
function validTaskTitle(title: Bytes): boolean {
  if (title.length === 0 || title.length > MAX_TITLE_BYTES) return false;
  let at = 0;
  let hasNonWhitespace = false;
  while (at < title.length) {
    const first = title[at];
    let codepoint = 0;
    let width = 0;
    if (first <= 0x7f) {
      codepoint = first;
      width = 1;
    } else if (first >= 0xc2 && first <= 0xdf) {
      if (at + 1 >= title.length) return false;
      const second = title[at + 1];
      if (second < 0x80 || second > 0xbf) return false;
      codepoint = (first - 0xc0) * 64 + (second - 0x80);
      width = 2;
    } else if (first >= 0xe0 && first <= 0xef) {
      if (at + 2 >= title.length) return false;
      const second = title[at + 1];
      const third = title[at + 2];
      if (second < 0x80 || second > 0xbf || third < 0x80 || third > 0xbf) return false;
      if (first === 0xe0 && second < 0xa0) return false;
      if (first === 0xed && second > 0x9f) return false;
      codepoint = (first - 0xe0) * 4096 + (second - 0x80) * 64 + (third - 0x80);
      width = 3;
    } else if (first >= 0xf0 && first <= 0xf4) {
      if (at + 3 >= title.length) return false;
      const second = title[at + 1];
      const third = title[at + 2];
      const fourth = title[at + 3];
      if (
        second < 0x80 ||
        second > 0xbf ||
        third < 0x80 ||
        third > 0xbf ||
        fourth < 0x80 ||
        fourth > 0xbf
      ) {
        return false;
      }
      if (first === 0xf0 && second < 0x90) return false;
      if (first === 0xf4 && second > 0x8f) return false;
      codepoint =
        (first - 0xf0) * 262144 + (second - 0x80) * 4096 + (third - 0x80) * 64 + (fourth - 0x80);
      width = 4;
    } else {
      return false;
    }
    if (titleCodepointRejected(codepoint)) return false;
    if (!titleCodepointWhitespace(codepoint)) hasNonWhitespace = true;
    at += width;
  }
  return hasNonWhitespace;
}

function hasDuplicateTasks(tasks: readonly DbTask[]): boolean {
  for (let i = 0; i < tasks.length; i++) {
    for (let j = i + 1; j < tasks.length; j++) {
      if (tasks[i].id === tasks[j].id) return true;
    }
  }
  return false;
}

function hasDuplicateSessions(active: DbSession | null, sessions: readonly DbSession[]): boolean {
  for (let i = 0; i < sessions.length; i++) {
    if (active !== null && active.id === sessions[i].id) return true;
    for (let j = i + 1; j < sessions.length; j++) {
      if (sessions[i].id === sessions[j].id) return true;
    }
  }
  return false;
}

function decodeFailure(detail: Bytes): SnapshotDecode {
  const value: DbSnapshot = {
    revision: 0,
    settings: {
      focusMinutes: 25,
      shortBreakMinutes: 5,
      longBreakMinutes: 15,
      dailyGoalMinutes: 120,
      soundEnabled: true,
      quickShortcutEnabled: true,
      quickShortcutKey: "f",
      quickShortcutModifiers: "command_shift",
    },
    nextTaskId: 1,
    tasks: [],
    activeSession: null,
    recentSessions: [],
    stats: {
      todayFocusMs: 0,
      todayCompletedSessions: 0,
      todayCompletedTasks: 0,
      todayWeekday: 0,
      weekFocusMs: [],
    },
  };
  return { ok: false, value: value, detail: detail };
}

export function decodeSnapshot(data: Bytes): SnapshotDecode {
  if (data.length > MAX_SNAPSHOT_BYTES) {
    return decodeFailure(asciiBytes("database snapshot exceeds 96 KiB"));
  }
  const reader = new BinaryReader(data);
  if (!reader.magic(0x46, 0x43, 0x53, 0x32)) {
    return decodeFailure(asciiBytes("invalid database snapshot header"));
  }
  const version = reader.u32();
  if (version !== 3) {
    return decodeFailure(asciiBytes("unsupported database snapshot version"));
  }
  const revision = reader.u64();
  const focusMinutes = reader.u32();
  const shortBreakMinutes = reader.u32();
  const longBreakMinutes = reader.u32();
  const dailyGoalMinutes = reader.u32();
  const soundWire = reader.u8();
  const quickShortcutEnabledWire = reader.u8();
  const quickShortcutModifiersWireValue = reader.u8();
  const quickShortcutKeyWireValue = reader.u8();
  const settings: DbSettings = {
    focusMinutes: focusMinutes,
    shortBreakMinutes: shortBreakMinutes,
    longBreakMinutes: longBreakMinutes,
    dailyGoalMinutes: dailyGoalMinutes,
    soundEnabled: soundWire === 1,
    quickShortcutEnabled: quickShortcutEnabledWire === 1,
    quickShortcutKey: quickShortcutKeyFromWire(quickShortcutKeyWireValue),
    quickShortcutModifiers: quickShortcutModifiersFromWire(quickShortcutModifiersWireValue),
  };
  if (
    soundWire > 1 ||
    quickShortcutEnabledWire > 1 ||
    quickShortcutModifiersWireValue > 5 ||
    quickShortcutKeyWireValue > 5 ||
    !settingsValid(settings)
  ) reader.failed = true;

  const nextTaskId = reader.u64();
  const taskCount = reader.u32();
  if (nextTaskId === 0 || taskCount > MAX_TASKS) reader.failed = true;
  const tasks: DbTask[] = [];
  if (taskCount <= MAX_TASKS) {
    for (let i = 0; i < taskCount; i++) {
      const id = reader.u64();
      const stateWire = reader.u8();
      const sortOrder = reader.u32();
      const estimateMinutes = reader.u32();
      const createdMs = reader.u64();
      const updatedMs = reader.u64();
      const completedMs = reader.u64();
      const titleLength = reader.u32();
      const title = reader.bytes(titleLength);
      if (
        id === 0 ||
        stateWire > 2 ||
        estimateMinutes === 0 ||
        estimateMinutes > 480 ||
        titleLength === 0 ||
        titleLength > MAX_TITLE_BYTES ||
        !validTaskTitle(title) ||
        updatedMs < createdMs
      ) {
        reader.failed = true;
      }
      tasks.push({
        id: id,
        state: taskStateFromWire(stateWire),
        sortOrder: sortOrder,
        estimateMinutes: estimateMinutes,
        createdMs: createdMs,
        updatedMs: updatedMs,
        completedMs: completedMs,
        title: title,
      });
    }
  }

  const activePresent = reader.u8();
  if (activePresent > 1) reader.failed = true;
  const activeSession = activePresent === 1 ? reader.session() : null;
  if (activeSession !== null && activeSession.state !== "running" && activeSession.state !== "paused") {
    reader.failed = true;
  }

  const recentCount = reader.u32();
  if (recentCount > MAX_RECENT_SESSIONS) reader.failed = true;
  const recentSessions: DbSession[] = [];
  if (recentCount <= MAX_RECENT_SESSIONS) {
    for (let i = 0; i < recentCount; i++) {
      const session = reader.session();
      if (session.state !== "completed") reader.failed = true;
      recentSessions.push(session);
    }
  }

  const todayFocusMs = reader.u64();
  const todayCompletedSessions = reader.u32();
  const todayCompletedTasks = reader.u32();
  const weekCount = reader.u32();
  if (weekCount !== 7) reader.failed = true;
  const todayWeekday = reader.u8();
  if (todayWeekday > 6) reader.failed = true;
  const weekFocusMs: DbDayFocus[] = [];
  if (weekCount === 7) {
    for (let i = 0; i < 7; i++) weekFocusMs.push({ milliseconds: reader.u64() });
  }

  if (
    reader.failed ||
    reader.remaining() !== 0 ||
    hasDuplicateTasks(tasks) ||
    hasDuplicateSessions(activeSession, recentSessions)
  ) {
    return decodeFailure(asciiBytes("malformed or trailing database snapshot data"));
  }

  return {
    ok: true,
    detail: asciiBytes(""),
    value: {
      revision: revision,
      settings: settings,
      nextTaskId: nextTaskId,
      tasks: tasks,
      activeSession: activeSession,
      recentSessions: recentSessions,
      stats: {
        todayFocusMs: todayFocusMs,
        todayCompletedSessions: todayCompletedSessions,
        todayCompletedTasks: todayCompletedTasks,
        todayWeekday: todayWeekday,
        weekFocusMs: weekFocusMs,
      },
    },
  };
}

export function encodeLoad(nowMs: number): Bytes {
  const out = new Uint8Array(16);
  out[0] = 0x46;
  out[1] = 0x43;
  out[2] = 0x4c;
  out[3] = 0x31;
  out.set(encodeU32Part(1), 4);
  out.set(encodeU64Part(nowMs), 8);
  return out;
}

export function encodeTaskCreate(revision: number, nowMs: number, estimateMinutes: number, title: Bytes): Bytes {
  const out = new Uint8Array(32 + title.length);
  out.set(mutationPrefix(revision, nowMs), 0);
  out.set(encodeU32Part(estimateMinutes), 24);
  out.set(encodeU32Part(title.length), 28);
  out.set(title, 32);
  return out;
}

export function encodeTaskRename(revision: number, nowMs: number, taskId: number, title: Bytes): Bytes {
  const out = new Uint8Array(36 + title.length);
  out.set(mutationPrefix(revision, nowMs), 0);
  out.set(encodeU64Part(taskId), 24);
  out.set(encodeU32Part(title.length), 32);
  out.set(title, 36);
  return out;
}

export function encodeTaskState(revision: number, nowMs: number, taskId: number, state: TaskState): Bytes {
  const out = new Uint8Array(33);
  out.set(mutationPrefix(revision, nowMs), 0);
  out.set(encodeU64Part(taskId), 24);
  let stateWire = 0;
  if (state === "completed") stateWire = 1;
  if (state === "archived") stateWire = 2;
  out[32] = stateWire;
  return out;
}

// Archive Undo is stricter than an ordinary state change. SQLite validates
// that the row is still archived and retains its authoritative completion
// timestamp when restoring a completed task.
export function encodeTaskUndoArchive(revision: number, nowMs: number, taskId: number, state: TaskState): Bytes {
  return encodeTaskState(revision, nowMs, taskId, state);
}

export function encodeTaskPurge(revision: number, nowMs: number, taskId: number): Bytes {
  const out = new Uint8Array(32);
  out.set(mutationPrefix(revision, nowMs), 0);
  out.set(encodeU64Part(taskId), 24);
  return out;
}

export function encodeSettings(revision: number, nowMs: number, settings: DbSettings): Bytes {
  const out = new Uint8Array(44);
  out.set(mutationPrefix(revision, nowMs), 0);
  out.set(encodeU32Part(settings.focusMinutes), 24);
  out.set(encodeU32Part(settings.shortBreakMinutes), 28);
  out.set(encodeU32Part(settings.longBreakMinutes), 32);
  out.set(encodeU32Part(settings.dailyGoalMinutes), 36);
  let soundWire = 0;
  if (settings.soundEnabled) soundWire = 1;
  out[40] = soundWire;
  let quickShortcutEnabledWire = 0;
  if (settings.quickShortcutEnabled) quickShortcutEnabledWire = 1;
  out[41] = quickShortcutEnabledWire;
  out[42] = quickShortcutModifiersWire(settings.quickShortcutModifiers);
  out[43] = quickShortcutKeyWire(settings.quickShortcutKey);
  return out;
}

export function encodeTimerStart(
  revision: number,
  nowMs: number,
  taskId: number,
  mode: SessionMode,
  plannedMs: number,
): Bytes {
  const out = new Uint8Array(41);
  out.set(mutationPrefix(revision, nowMs), 0);
  out.set(encodeU64Part(taskId), 24);
  let modeWire = 0;
  if (mode === "short") modeWire = 1;
  if (mode === "long") modeWire = 2;
  out[32] = modeWire;
  out.set(encodeU64Part(plannedMs), 33);
  return out;
}

export function encodeTimerSession(revision: number, nowMs: number, sessionId: number): Bytes {
  const out = new Uint8Array(32);
  out.set(mutationPrefix(revision, nowMs), 0);
  out.set(encodeU64Part(sessionId), 24);
  return out;
}

export function encodeTimerComplete(
  revision: number,
  nowMs: number,
  sessionId: number,
  reason: TimerCompleteReason,
): Bytes {
  const out = new Uint8Array(33);
  out.set(mutationPrefix(revision, nowMs), 0);
  out.set(encodeU64Part(sessionId), 24);
  let reasonWire = 0;
  if (reason === "manual") reasonWire = 1;
  out[32] = reasonWire;
  return out;
}

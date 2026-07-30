# Focus Tracker

Focus Tracker is a native macOS task ledger and focus timer built with
[Native SDK](https://native-sdk.dev). Its interface is written in Native
markup, its deterministic app core is TypeScript compiled to native Zig, and
its local data is stored by a narrowly scoped SQLite extension. No JavaScript
runtime or web-content layer is used by the application.

The visual system is called **Cobalt Ledger**: a quiet editorial task rail and
a precision timer chamber joined by the animated **Focus Gate** split. The app
uses native controls, system light/dark/high-contrast appearances, and reduced
motion behavior.

## Product scope

- Add, rename, complete, archive, restore, and select tasks.
- Commit a 25, 50, or 90 minute focus block to one task.
- Pause, resume, finish, cancel, and recover a block across sleep or relaunch.
- Configure break lengths, daily focus goal, and completion sound.
- Review today’s totals, a seven-day focus chart, and recent sessions.
- Keep an active timer running when the main window is hidden.
- Control the current block from a real macOS menu-bar item.
- Open a 392 pt Quick Focus companion to add/select work, start, pause,
  resume, finish, and resolve a completed block without opening the ledger.

Cloud sync, accounts, projects, tags, due dates, and collaboration are
deliberately outside the first release.

## Architecture

| Layer | Source | Responsibility |
| --- | --- | --- |
| App core | `src/core.ts` | Pure model/update loop, task and timer state machines, commands, derived view bindings |
| Binary protocol | `src/protocol.ts` | Strict, bounded, versioned TypeScript ↔ SQLite messages |
| Interface | `src/app.native` | Native macOS layout, controls, accessibility semantics, and application states |
| Settings view | `src/settings.native` | Fixed model-declared Settings window with live, locally persisted controls |
| Quick Focus view | `src/quick.native` | Compact always-on-top controller driven by the same model and SQLite snapshots |
| Host runner | `src/native/main.zig` | Standard Native SDK runner plus the explicit host-call binding |
| SQLite extension | `src/native/sqlite_extension.zig` | Migrations, prepared statements, transactional domain operations, authoritative snapshots |

The TypeScript layer never sends SQL. Every mutation is a typed domain request
executed under `BEGIN IMMEDIATE`; the UI adopts the returned state only after
SQLite commits. Timer sessions use an absolute deadline and a database
constraint that permits at most one running or paused session.

Deadlines follow the Mac system wall clock. If an observed time is earlier
than the session's last persisted transition, the database atomically pauses
the block without overcounting; resuming rebases the deadline from the current
clock. A smaller backward clock change that never crosses that persisted
transition is indistinguishable from ordinary elapsed wall time in v0.1.

The database lives outside the project at:

```text
~/Library/Application Support/focus-tracker/focus.sqlite3
```

SQLite uses foreign keys, WAL journaling, full synchronous durability, a short
busy timeout, and a boot-time integrity check. An unreadable or future-schema
database is surfaced as a recovery error and is never silently replaced.

## Keyboard

| Shortcut | Action |
| --- | --- |
| `⌘N` | New task |
| `⌘1` | Today |
| `⌘2` | Focus ledger |
| `⌘,` | Settings |
| `⌘⇧Space` | Start, pause, or resume the current focus block |
| `⌘⇧F` | Open or refocus Quick Focus |

The window close button hides the app while an active timer continues. Quitting
the application is a distinct, explicit action.

Quick Focus and Settings are mutually exclusive auxiliary windows. This keeps
the Native SDK key fallback deterministic: `Escape` dismisses the active
dialog first, then the one open auxiliary window, and can never close a sibling
behind it.

The menu-bar shortcut is a native `NSStatusItem`. Native SDK 0.6.2 exposes a
system command menu but not a custom anchored canvas popover, so the rich
controller is an honest, fixed-size native companion window opened by the first
menu item. It never creates a second app core or database connection.

## Requirements

- macOS 11 or later on Apple Silicon (`arm64`)
- Native SDK CLI `0.6.2` (`ef1f8d9`)
- Node.js 22.15+ (23.5+ on the Node 23 line) and npm
- Xcode command-line tools / Zig runtime supplied by Native SDK

The application links Apple’s system `libsqlite3`; it does not depend on a
Homebrew SQLite installation. The Native SDK source archive is pinned by both
version and Zig content hash, while `package-lock.json` pins the build-only
TypeScript compiler alias. No dependency points to a machine-specific SDK
installation path.

## Develop and verify

```sh
npm ci
native validate app.zon
native markup check src/app.native src/settings.native src/quick.native --strict
native test
native check --strict
native build
```

`npm ci` installs authoring tools only. The packaged application still contains
neither Node.js nor a JavaScript runtime.

For real UI automation:

```sh
native build -Dautomation=true
native dev -Dautomation=true
native automate wait
native automate snapshot
native automate screenshot main-canvas
native automate tray-action 30
native automate screenshot quick-canvas
```

Runtime verification can use an isolated database without touching the normal
ledger by launching the binary with an absolute `FOCUS_TRACKER_DATA_DIR` path.
Normal launches without that environment variable continue to use Application
Support.

Build the ReleaseFast binary and package a local ad-hoc signed application only
after the verification gates are green:

```sh
./scripts/package-app.sh
```

The packaging script always creates a fresh temporary bundle, verifies its
ReleaseFast manifest, resources, Mach-O executable, and ad-hoc signature, then
replaces the canonical app with rollback protection. This avoids stale files
surviving from an earlier Native SDK package.

Create the polished drag-to-Applications disk image from that verified bundle:

```sh
./scripts/build-dmg.sh
```

The command creates both artifacts below. The image and checksum are verified
before publication, and replacement is rollback-protected so a previous pair
is restored if publication or the final pair check fails.

```text
zig-out/release/Focus-Tracker-0.1.0-macOS-arm64.dmg
zig-out/release/Focus-Tracker-0.1.0-macOS-arm64.dmg.sha256
```

The image contains only `Focus Tracker.app` and an `Applications` link in its
visible root. Its controlled Finder presentation is stored in `.DS_Store`,
with packaging-only artwork under `packaging/macos`: a 2× Cobalt Ledger
background and a branded volume icon. Those files are not bundled into the
runtime application. Verify a published image independently with:

```sh
./scripts/verify-dmg.sh \
  --expect-background \
  --expect-volume-icon \
  zig-out/release/Focus-Tracker-0.1.0-macOS-arm64.dmg
```

Building the DMG requires macOS with `hdiutil`, Finder, and the Xcode command
line tools (`SetFile` and `GetFileInfo`). Keep the desktop session unlocked
while the script writes the controlled Finder presentation metadata. The DMG
is intentionally not byte-reproducible: HFS volume identifiers, timestamps,
and Finder metadata can vary between otherwise equivalent builds.

The v0.1 artifact deliberately targets reliable local use on Apple Silicon.
Ad-hoc signing is suitable for local verification; it is not presented as a
public-distribution build. A public Intel/universal release still requires its
own architecture build, an Apple Developer identity, hardened signing, and
notarization.

The status-item icon path is repository-relative during development and is
resolved from the executable to an absolute
`Contents/Resources/assets/tray-template.png` path inside a packaged app. This
keeps the menu-bar icon independent of the launch working directory.

Open [PROGRESS.html](./PROGRESS.html) for the auto-refreshing implementation and
quality-gate dashboard.

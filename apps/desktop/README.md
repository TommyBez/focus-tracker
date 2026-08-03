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

The chamber is composed as an instrument rather than a form. It states the
block about to start (or running), the length being committed, and — pinned
under every state — what the day already contains. The workspace switcher in
the titlebar names the section, so the pane never spends height repeating a
heading above the timer.

## Product scope

- Add, rename, complete, archive, restore, and select tasks, including while a
  block is running: an interruption belongs in the ledger, not in your head.
- Commit a focus block of any length from 5 to 180 minutes to one task. The
  15/25/50/90 presets and a ±5 minute stepper set *this* block; Settings owns
  the durable default and is the only place a duration is written to SQLite. A
  break never consumes the length chosen for the next focus block.
- Pause, resume, finish, cancel, and recover a block across sleep or relaunch.
- Configure default focus length, break lengths, daily focus goal, and
  completion sound, each with presets plus a stepper over the full range the
  database accepts.
- See today’s recorded focus, block count, seven-day total, and goal progress
  under the timer at every moment, from the same snapshot the Ledger renders.
- Review a seven-day focus chart, days focused, average active day, best day,
  and recent sessions.
- Keep an active timer running when the main window is hidden.
- Control the current block from a real macOS menu-bar item.
- Open a 392 pt Quick Focus companion to add/select work, set the block length,
  start, pause, resume, finish, and resolve a completed block without opening
  the ledger.

The task a block is running against is owned by the transport: its row cannot
be completed or archived mid-flight, and it is labelled in the rail. Every
other row stays live.

The Today strip and the Ledger tiles state recorded facts only. The product
carries no streak, score, or attention grade, and nothing in the interface
nudges a session that has not happened.

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
transition is indistinguishable from ordinary elapsed wall time in this release.

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
| `Space` | Pause or resume a running block, when no control has focus |

`Space` is a last-resort fallback: a focused control answers its own keys and
editable text keeps typing, so it only reaches the transport when nothing is
focused. It never *starts* a block — beginning one is always explicit.

`⌘⇧Space` starts the block at the length currently shown in the chamber, which
is the persisted default until the stepper or a preset changes it for this
block only. A completed, cancelled, or newly loaded session returns the
chamber to the persisted default.

The window close button hides the app while an active timer continues. Quitting
the application is a distinct, explicit action.

Quick Focus and Settings are mutually exclusive auxiliary windows. This keeps
the Native SDK key fallback deterministic: `Escape` dismisses the active
dialog first, then the one open auxiliary window, and can never close a sibling
behind it.

The menu-bar shortcut is a native `NSStatusItem`. The pinned Native SDK exposes a
system command menu but not a custom anchored canvas popover, so the rich
controller is an honest, fixed-size native companion window opened by the first
menu item. It never creates a second app core or database connection.

## Requirements

- macOS 11 or later on Apple Silicon (`arm64`)
- Node.js and pnpm versions satisfying the root `package.json`
- Xcode command-line tools / Zig runtime supplied by Native SDK

The application links Apple’s system `libsqlite3`; it does not depend on a
Homebrew SQLite installation. The Native SDK source archive is pinned by both
version and Zig content hash. The root `pnpm-lock.yaml` pins the workspace CLI,
core package, and TypeScript compiler alias. No dependency points to a
machine-specific SDK installation path.

## Workspace setup

This package is the `@focus-tracker/desktop` member of the repository pnpm
workspace. Install dependencies once from the repository root; do not create a
second lockfile inside `apps/desktop`.

From the repository root:

```sh
pnpm install --frozen-lockfile
pnpm --filter @focus-tracker/desktop check
pnpm --filter @focus-tracker/desktop build
```

From `apps/desktop`, the equivalent package-local commands are:

```sh
pnpm check
pnpm build
```

The pnpm install supplies authoring and packaging tools only. The packaged
application contains neither Node.js nor a JavaScript runtime.

## Develop and verify

```sh
cd apps/desktop
pnpm dev
pnpm check
pnpm build
```

`pnpm check` validates `app.zon`, runs the native tests, and checks the Native
markup and TypeScript model contracts in strict mode. Run it again for the
exact commit being packaged; historical test totals are not release evidence.

For real UI automation:

```sh
pnpm exec native build -Dautomation=true
pnpm exec native dev -Dautomation=true
pnpm exec native automate wait
pnpm exec native automate snapshot
pnpm exec native automate screenshot main-canvas
pnpm exec native automate tray-action 30
pnpm exec native automate screenshot quick-canvas
```

Runtime verification can use an isolated database without touching the normal
ledger by launching the binary with an absolute `FOCUS_TRACKER_DATA_DIR` path.
Normal launches without that environment variable continue to use Application
Support.

## Package the beta

From `apps/desktop`, build the ReleaseFast app and then its disk image only
after the verification gates are green:

```sh
pnpm package:app
pnpm package:dmg
```

From the repository root, the Turbo task runs those stages in order:

```sh
pnpm package:desktop
```

`package-app.sh` always builds a fresh temporary bundle, verifies its
ReleaseFast manifest, resources, Mach-O executable, and signature, and replaces
the canonical app with rollback protection. The bundle and DMG carry this exact
disclosure:

```text
Beta build: ad-hoc signed; not Developer ID signed or notarized.
```

`build-dmg.sh` writes a version-derived image and matching checksum sidecar:

```text
zig-out/release/Focus-Tracker-<version>-macOS-<arch>.dmg
zig-out/release/Focus-Tracker-<version>-macOS-<arch>.dmg.sha256
```

The image contains only `Focus Tracker.app` and an `Applications` link in its
visible root. Packaging is headless: it mounts the writable image with
`-nobrowse` in a temporary directory and, with the default background, copies
the version-controlled `packaging/macos/dmg-layout.DS_Store`. It never launches
Finder or AppleScript and does not require an unlocked desktop session. The
template preserves the window presentation, background reference, and
app/Applications icon positions; verification requires the mounted `.DS_Store`
to match it byte-for-byte. `package:dmg --no-background` instead omits both
`.background` and `.DS_Store`; `--expect-no-background` verifies that neither
stale background content nor metadata remains.

The remaining packaging-only assets are the 2× Cobalt Ledger background and
branded volume icon under `packaging/macos`. They are excluded from the runtime
app. Verify any local candidate independently with:

```sh
./scripts/verify-dmg.sh \
  --expect-background \
  --expect-volume-icon \
  zig-out/release/<DMG-file>
```

When the version-neutral SVG artwork changes, regenerate its committed 2× PNG
from `apps/desktop` with:

```sh
rsvg-convert --width 1320 --height 860 \
  --output /tmp/focus-tracker-dmg-background.png \
  packaging/macos/dmg-background.svg
sips --setProperty dpiWidth 144 --setProperty dpiHeight 144 \
  /tmp/focus-tracker-dmg-background.png \
  --out packaging/macos/dmg-background.png
```

Building the DMG requires macOS with `hdiutil` and the Xcode command-line tools
(`SetFile` and `GetFileInfo`). The image is intentionally not byte-reproducible:
HFS volume identifiers and timestamps can vary between equivalent builds, so
the generated sidecar is authoritative for that exact output.

## GitHub Releases

Desktop changes merged to `main` are packaged by
`.github/workflows/release-desktop.yml`; `workflow_dispatch` is the recovery
path. The workflow creates a new `v<version>` release titled
`Focus Tracker v<version> (Beta)` and uploads stable asset names:

```text
Focus-Tracker-macOS-arm64.dmg
Focus-Tracker-macOS-arm64.dmg.sha256
```

It refuses to overwrite an existing tag or release. Download both files from
[GitHub Releases](https://github.com/TommyBez/focus-tracker/releases), keep them
together, and verify the sidecar before opening the image:

```sh
shasum -a 256 -c Focus-Tracker-macOS-arm64.dmg.sha256
```

## Install and Gatekeeper

Open the verified DMG and drag `Focus Tracker.app` onto `Applications`. This is
a beta artifact with an ad-hoc signature, not a Developer ID signature or an
Apple notarization ticket. macOS Gatekeeper may therefore warn or block the
first launch even when the checksum and structural signature checks pass.

Only after confirming that the files came from the project’s GitHub Release,
use Finder’s Control-click **Open** flow and confirm the warning; if macOS still
blocks it, use **System Settings → Privacy & Security → Open Anyway**. Those
steps express local trust in this specific beta—they do not turn it into a
notarized public-distribution build. A broadly trusted release still requires
Developer ID signing, hardened runtime validation, and Apple notarization.

The beta deliberately targets Apple Silicon. Intel/universal distribution
requires its own architecture build and release validation.

The status-item icon path is repository-relative during development and is
resolved from the executable to an absolute
`Contents/Resources/assets/tray-template.png` path inside a packaged app. This
keeps the menu-bar icon independent of the launch working directory.

Open [PROGRESS.html](./PROGRESS.html) for the auto-refreshing implementation and
quality-gate dashboard. Treat recorded hashes, versions, and test totals there
as historical evidence, not as the identity of a newly built candidate.

The reproducible acceptance method lives in [UX-GATE.md](./UX-GATE.md).
Screenshots are visual evidence only; UX judgments require completing the
documented journeys against running applications.

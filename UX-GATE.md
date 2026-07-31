# Focus Tracker UX gate

This gate evaluates use, not screenshots. A visual capture can document a
state, but it cannot prove that a person can discover an action, complete a
journey, recover from a mistake, use the keyboard, or trust persisted data.

## Evidence classes

1. **Journey evidence** — real pointer and keyboard input against a running
   build, with the resulting model and SQLite state checked where relevant.
2. **Recovery evidence** — interruption, relaunch, stale input, failed writes,
   and window hand-off exercised deliberately.
3. **Accessibility evidence** — reachable controls, logical focus order,
   accurate roles, labels, values, selected states, and reduced-motion and
   high-contrast behavior.
4. **Visual evidence** — equivalent-size captures of the states reached during
   a journey. This supports a visual critique only; it never supplies a UX
   score.

## Focus Tracker journeys

Every release candidate must complete all of these from a fresh, isolated
database and repeat the persistence-sensitive journeys after relaunch.

| ID | Journey | Required proof |
| --- | --- | --- |
| F1 | Cold start to a first focus block | Create, select, choose duration, and start using visible controls and keyboard |
| F2 | Running transport | Pause, resume, and finish; no duplicate session or lost elapsed time |
| F3 | Completed focus decision | Recorded time is acknowledged; task completion, keeping it open, and starting a break are explicit and unambiguous |
| F4 | Break lifecycle | Start, pause, resume, finish, and acknowledge a break without changing a task silently |
| F5 | Quick Focus hand-off | Open from menu bar and shortcut, control the same session, then return to the main app with one coherent window state |
| F6 | Ledger | Find the just-recorded session and verify duration, task, mode, and completion reason |
| F7 | Settings | Discover, change by pointer and keyboard, observe exactly one selected value, close, reopen, and verify SQLite persistence |
| F8 | Relaunch recovery | Relaunch while running and paused; preserve the authoritative session and expose the correct next action |
| F9 | Error recovery | Exercise retryable writes, destructive confirmation, Escape, and stale callbacks without silent data loss |
| F10 | Installed artifact | Mount the DMG, drag to Applications, launch the copied app, repeat a short journey, quit cleanly, and verify SQLite integrity |

For every journey record task success, critical errors, recovery success,
unexpected windows, input-to-feedback latency, focus order, and the final
database state. Any silent data loss, dead end, incorrect accessibility state,
or ambiguous destructive action is a veto regardless of visual quality.

## Current Focus-only evidence — 2026-07-31

The current candidate passes its independent single-instance operational
re-audit. This is a product-journey result for Focus Tracker, not a comparative
preference claim:

- The run began with one instrumented Debug process and a fresh isolated
  SQLite store containing zero tasks and zero sessions. It ended with
  `dispatch_errors=0` and no runtime error event.
- Main selection → Start, Quick open → Start, and Quick task change → Start
  each passed three consecutive repetitions with the intended control focused.
- Create, Unicode input, Start, Pause, Resume, Finish, End/Escape recovery,
  Rename, Archive, Restore, Purge, Settings, Tab, Shift+Tab, Enter, Space, and
  Escape were exercised through real widget input. Rename accepts input
  immediately and reports stable editor focus by the following observed frame.
- End and Purge dialogs remained inside their actual windows. Purge opened on
  Cancel and returned focus to its visible destructive-action trigger after
  Cancel and Escape.
- Settings changed from 25 to 50 minutes through keyboard input, persisted to
  SQLite, and reopened selected and focused. A separate process restart
  recovered the same three tasks, two sessions, and 50-minute preference with
  `PRAGMA integrity_check` returning `ok`.
- A fresh-cache native acceptance run passed 51/51 authored tests: 29
  app/runtime, 20 isolated SQLite, and 2 theme tests. All 11/11 build steps,
  the manifest, and all three strict markup/model contracts passed in the same
  run.
- Real IME composition, spoken VoiceOver output, and keyboard traversal of the
  operating-system status menu were not re-proved in this run. Source-aware IME
  cancellation remains covered by the native test suite.
- Native SDK 0.6.2 does not expose a dynamic role/description hook for the
  secondary GPU surface. Quick Focus and Settings expose labelled root groups
  and native child widgets, but a complete spoken-VoiceOver claim remains open
  until the SDK surface can expose that semantic metadata.

The final installed-artifact journey also passes. The published DMG was mounted
read-only, its app copied into an isolated `Applications` directory, and the
copied executable and outer CDHash matched the packaged source. The exact copied
app accepted a real keyboard-created task, started and paused its focus block,
opened Quick Focus against that same paused session, resumed, quit, and
relaunched through macOS LaunchServices (`open -n`) on the same SQLite store.
The app visibly recovered the running session with elapsed wall time intact.
It then recorded the elapsed focus, started and ended a short break, returned
to the ready state, exposed the focus and break entries in Ledger, changed the
default focus from 25 to 50 minutes in Settings, and reloaded that selection
after closing and reopening the window. It then quit cleanly. The final database
had revision 8, zero live sessions, the persisted 50-minute preference, and
`PRAGMA integrity_check=ok`; a final process check found zero Focus Tracker
processes. Direct invocation of the raw Mach-O is not treated as an
installed-app launch and is outside this pass.

Current artifact identity:

```text
DMG bytes:          7,116,453
DMG SHA-256:        b85af3c7ae1ecd6997c92386a8a0f79a8a267bc70134ae5a9bc0c6c2c97eb6e1
Executable SHA-256: bec1e63b64fb07e835b65a8595de51c27c0c5618b9ba50f3a03de9c176ee8d5f
Outer app CDHash:   9820dab6a0fa804c77765f8b83dc7c8674c6d56f
```

### Run identity and validity

Before a judged journey, the harness must prove that exactly one Focus Tracker
process is running and record its executable path, PID, build, and isolated
data directory. The judge then confirms a unique sentinel (for example the
fresh task count and the task just created) in both the visible pixels and the
accessibility state before continuing. Critical transitions such as Start,
Pause, completion, and relaunch require a retained visual observation as well
as semantic state.

If pixels and accessibility describe different tasks, counts, copy, or timer
states, the run is invalid: stop it, close every duplicate bundle instance,
and repeat from a fresh database. Cross-instance evidence is neither a product
PASS nor a product VETO.

## Comparative UX protocol

A comparison with another desktop product is valid only when an independent
evaluator can use both products end to end. The task order is randomized and
the products are called A and B in the score sheet; identity is hidden only
where doing so does not alter the actual interface or interaction.

Tasks are matched by user intent rather than copied feature names: orient from
a cold start, begin the primary job, pause or cancel safely, navigate to
history, change a preference, recover after relaunch, and find help for a
mistake. The evaluator records completion, time, wrong turns, recoveries,
keyboard coverage, confidence, and a short rationale before learning which
product was A or B.

The only permitted outcomes are:

- **PASS** — every Focus journey passes and the comparative evaluator prefers
  Focus for the tested intents with no critical regression.
- **VETO** — a journey fails, a critical defect is found, or the comparator is
  preferred for a material reason that has not been addressed.
- **NO RESULT** — either product cannot be exercised under the same protocol,
  the tasks or framing are not comparable, or the evidence is incomplete.

One expert audit can discover defects and issue a veto. It cannot establish
human learnability or a population-level preference. Those claims require
fresh participants, recorded task outcomes, and a declared sample; they must
never be inferred from a screenshot score.

## Current comparative status

`NO RESULT`. Focus Tracker now passes its own operational journey re-audit, but
the available computer-use harness explicitly refuses control of Codex Desktop.
A separate attempted blind run also lost its Focus window and was invalidated
instead of being scored. The earlier screenshot-only A/B remains withdrawn and
supplies no UX score, preference, or AAA claim.

## Gate closeout checkpoint — 2026-07-31

The delegated closeout started from clean commit
`8ba22254890c30c282113b1cca37d1337a90d591`. The supplied worktree was detached
at that commit rather than attached to
`codex/focus-tracker-ux-checkpoint-20260731`; no branch switch or history rewrite
was performed.

A ReleaseFast automation build was launched against the isolated data directory
`/private/tmp/focus-tracker-ux-gate-019fb972`. An initial Computer Use attempt
was invalidated immediately because its accessibility tree showed four tasks
while the instrumented process showed zero; no cross-instance observation was
used as product evidence. The valid single-process run used publisher PID
`25000`, then PID `27021` after relaunch, and the unique task sentinel
`UX gate sentinel 019fb972` was present in the visible widget state and SQLite.

The valid run re-exercised the critical path across F1-F8: create and select the
sentinel, start, pause, open Quick Focus, resume the same session, quit cleanly,
relaunch on the same database, recover the running session, open the explicit
end confirmation, dismiss it with Escape, record elapsed focus, start/pause/
resume/end and record a break, inspect Ledger, and change Settings from 25 to
50 minutes using Tab and Space. Escape closed Settings; reopening created a new
window with 50 minutes as the sole selected and focused value. The final SQLite
rows contained one recorded focus session linked to the sentinel and one
recorded break, no live session, the 50-minute preference, and
`PRAGMA integrity_check=ok`. Every retained runtime checkpoint reported
`dispatch_errors=0`, with input latency inside the reported 8.33 ms budget.

F9 remains supported by the complete recovery evidence already recorded above
and by the current 52/52 native test pass, including retry-slot/deadline and
SQLite failure coverage; this closeout introduced no new product behavior or
reproducible blocker. F10 remains the unchanged installed-artifact PASS above:
no product file changed, so the published DMG and its verified identity did not
become obsolete and were not regenerated.

The current technical gate passes: `native build -Dautomation=true`, all 11/11
`native test` build steps and 52/52 tests, all three strict markup/model checks,
and `native validate app.zon`. The visual gate was not rescored. The Focus-only
UX gate passes. The comparative gate is finally `NO RESULT`: a fresh attempt to
attach the same Computer Use judge to Codex Desktop returned the explicit
policy error `Computer Use is not allowed to use the app 'com.openai.codex' for
safety reasons.` No comparative PASS, score, or preference is claimed.

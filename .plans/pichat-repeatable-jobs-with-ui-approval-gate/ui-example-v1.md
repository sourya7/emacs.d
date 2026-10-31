# PiChat Jobs — UI example v1

Status: proposed; awaiting explicit user acceptance. Scope amended 2026-10-31
per user feedback: no stable phase IDs or plan-modification detection. Other
conversational UX refinements await consolidation into the next revision.
Text mockup only, not a
working UI or another execution checklist. The authoritative tasks remain in
plan.org. Names, times, IDs, outcomes, and model values below are illustrative.

## 1. Entry points and navigation

Proposed commands: `M-x pichat-jobs` and `M-x pichat-job-new`.
From an Org phase, `Run with PiChat…` prefills the exact selected phase.

One global `*PiChat Jobs*` buffer, using the runtime manager's table conventions.
Two filters in that same view: Jobs (saved definitions) and Runs (all attempts,
including unsaved one-offs). No separate plan dashboard. Default: Jobs, with a
count/link for runs needing attention. Nothing executes when browsing.

```text
PiChat Jobs                         [Jobs]  Runs (2 need attention)
Filter: all projects                 Running 2 / limit 3

Job                   Project    State          Trigger       Next
Dependency review     emacs.d    Running        Every 6h      06:00
Docs summary          emacs.d    Running        Manual        —
Implement parser      emacs.d    Waiting        Manual        —
Plan: UI phase        emacs.d    Needs review   Once          —

RET Details   C-o Preview   + New   r Run…   e Edit   h Runs
s Schedule…   g Refresh    q Bury   ? Help
```

- RET opens definition details with instructions, captured launch settings,
  trigger controls, latest run, and history. C-o toggles a read-only preview.
- Runs displays attempts with job/title, state/result, start time, project and
  trigger. RET opens the exact run, not whichever runtime is current.
- `h` filters Runs to this job; switching back restores the prior selection.
- Narrow windows abbreviate columns, never identity; full values stay in details.
- `g` redraws cached state only. New/edit may deliberately discover tools/models.
- Suggested keys are native Emacs bindings. Optional Evil integration preserves
  movement keys and exposes actions through the existing local-menu conventions.
- Notifications update Jobs and issue a bounded message; they do not select chats,
  steal focus, or prompt over unrelated work.

## 2. Ordinary job, with no plan

`+ New` opens a setup Transient reusing existing launch choices. Instructions
are edited in an ordinary multiline compose buffer; applying returns to setup
without submitting. An unsaved new job defaults to Now, Afterward Stop, and
conservative workspace coordination.

```text
New PiChat job
Work:          Prompt                         [Change]
Instructions:  Review dependency files and summarize updates. [Edit…]
Project:       emacs.d                        [Choose…]

Preset:        review       Tools: preset     [Preset…] [Tools…]
Model:         provider/model-id              [Choose…]
Target:        local                          [Choose…]
Conversation:  fresh independent; saved
Workspace use: Read-only, needs stable files   [Change…]

Start:         Every 6 hours                   [Change…]
Afterward:     Stop
Save as:       Dependency review               [Change…]

[Review and enable schedule]   [Save disabled]   [Cancel]
```

Read-only is an explicit coordination declaration, not a sandbox. Offer three
plain choices: May modify files (default), Read-only / needs stable files, and
Read-only / accepts changing files. Preset Tools remain the actual startup
selection; choosing a read-only declaration never secretly changes tools.
Show a warning if selected tools can write/execute; don't claim safety from a
label. For plan execution, May modify files includes plan bookkeeping.

Settings must resolve to concrete values before submission; no deferred model
picker at timer time. The final review shows full workspace/target, instructions,
model, resolved preset/Tools, timezone, resource policy and stop boundary.
Changing material job settings after authorization requires renewed review.
Editing never mutates an already-running attempt's snapshot.

### Unsaved one-off

```text
Work:         Prompt — Summarize README changes; do not edit files.
Start:        Now
Save as:      Not saved
Afterward:    Stop

[Review and run]   [Save as job…]   [Cancel]
```

No name or plan is required. The submitted run appears in Runs with the prompt
summary and an Unsaved label; its settings/instructions remain inspectable.
Save as job later creates a disabled definition, not another execution.
Saving/enabling a schedule requires a named definition. Simply saving doesn't run.

## 3. Manual start and workspace waits

`r Run…` opens a short review of the selected definition's current settings.
The action is Run now, not an implicit rerun of historical settings. Run details
separately offers Run again with that run's captured settings, subject to fresh
eligibility and authorization checks.

```text
Run: Implement parser
Workspace: local · /home/mojo/Dev/emacs.d
Use:       May modify files
Afterward: Stop

[Run now]   [Cancel]
```

Submitting queues without changing focus/current-runtime selection. Run details:

```text
Implement parser · run r-103
State:    Waiting
Reason:   Dependency review needs stable files in this workspace.
Trigger:  Manual

[Open blocking run]   [Cancel queued run]   [Back]
```

Two read-only jobs may run together in emacs.d. A modifier waits for stable
readers and other modifiers; tolerant readers may overlap a modifier. Different
workspaces/worktrees can run in parallel unless they share another mutable
resource, including the same authoritative plan. No per-project blanket lock.
The global cap still applies. Manual requests use a bounded queue with visible
rejection when full; one active/queued occurrence per saved definition prevents
self-overlap. Waiting work is revalidated at dispatch; it never silently upgrades
scope. Claims don't cover manual edits/external agents.

## 4. One exact plan phase, scheduled once

From an Org phase, setup shows its plan file and full heading path. No Org ID
is required or inserted. At dispatch, the path must identify one unique phase;
missing or ambiguous targets require reselection. It never guesses by number.

```text
Work:       Plan phase
Plan:       .plans/example-parser/plan.org          [Open plan]
Scope:      Phase 2 — Parser implementation         [Inspect scope]
Selection:  plan file + full heading path
Project:    emacs.d
Preset:     coding     Tools: preset     Model: provider/model-id
Target:     local
Use:        May modify files (including plan updates)

Start:      Once · 2026-11-01 22:00 UTC             [Change…]
Afterward:  Stop; no other phase authorized
Save as:    Parser phase

[Review and schedule]   [Review and run now]   [Cancel]
```

Review authorizes this selected phase and resolved settings, not later phases.
It shows current eligibility and approval requirements. Completed,
paused/cancelled/archived plans, missing/ambiguous phase paths, or unresolved
prerequisites/gates cannot dispatch. Due-time checks use current saved plan
contents; no comparison against setup-time instructions is performed.
Scheduling review states: "Uses the phase's contents at execution time. Plan
edits are not tracked; disable or review this job when changing intended scope."
Rename/move tracking and replacement content at the same heading path are not
covered. Ineligible occurrences show a reason, not an automatic retry.
No ID insertion/save-confirmation step is needed. Unsaved buffer edits are not
silently saved or included; setup identifies the saved file as the execution source.

### Agent finished, human acceptance still required

```text
Parser phase · run r-104
State:       Finished
Result:      Needs review — live Emacs acceptance remains
Trigger:     Scheduled once · 2026-11-01 22:00 UTC
Scope:       Phase 2 — Parser implementation
Plan state:  Phase incomplete; acceptance task remains
Afterward:   Stopped; Phase 3 is not authorized

Summary: Implementation and automated checks finished.
         Human verification is still required; see plan evidence.

[Open plan]   [Open chat]   [Run details]   [Continue selected scope…]
```

The example summary is illustrative, not trusted proof. Structured outcomes and
plan evidence are validated separately. Neither agent prose nor a result flag
constitutes human acceptance. This Jobs view does not provide a competing
"Approve phase" button. Review/accept through the existing user interaction and
plan evidence workflow; later continuation reviews current eligibility and scope.
If that trusted evidence contract isn't available, automation stops for review.
The runtime need not stay alive solely because a plan gate remains unresolved.

## 5. Run inspection and history

```text
Dependency review · run r-105
State:      Finished
Result:     Completed
Started:    2026-11-01 00:00 UTC      Finished: 00:02 UTC
Trigger:    Fixed interval · due 00:00 UTC
Workspace:  local · /home/mojo/Dev/emacs.d
Summary:    2 dependency changes identified; no files modified.

[Open chat]   [Instructions & settings]   [Diagnostics]
[Run again…] [Job history]               [Back]
```

Instructions/settings contains immutable run inputs and exact model, tools,
working directory, target, job/run IDs, and saved-session reference. Outcomes
never imply current plan completion or tool confinement. History rows:

```text
Run     Started (UTC)    Result               Trigger
r-105   Nov 01 00:00     Completed            Interval
r-098   Oct 31 18:00     Failed               Manual
r-091   Oct 31 12:00     Execution uncertain  Interval
```

Open chat displays the exact owning live runtime. If stopped, show its retained
transcript if available; offer a separately labelled Open saved session
independently action when appropriate. That explicitly launches a runtime and
does not resume or rerun the job. Never silently substitute another chat.

Presentation keeps state, result, and attention separate. Small state vocabulary:
Waiting / Running / Finishing / Finished / Execution uncertain. Results when
finished: Completed / Needs review / Failed / Cancelled. Running may additionally
show Needs input or Cancelling; Finishing means awaiting authoritative sync.
Plan eligibility and schedule notices are not fake failed agent runs.

## 6. Required input, failure, cancellation, and recovery

- Running · Needs input: show reason and Open chat; existing owning-chat UI handles
  extension requests/approvals only when focused. Never auto-approve. Waiting
  input retains the active slot/resource claims; no silent timeout/retry by
  default. Explicit cancellation remains available.
- Failed: bounded reason, Open chat if available, Diagnostics, Run again….
  Failed synchronization is labelled Result not synchronized, not Completed;
  provisional output remains inspectable. Retry means a new explicit attempt.
- Cancel queued: removes this attempt from dispatch and records cancellation.
- Cancel active: confirm the exact job/run/target, request abort and show
  Cancelling until stopped evidence meets the resource-release criterion.
- Lost connection/uncertain cancellation: show Execution uncertain, captured
  target, diagnostics and held workspace. No retry or conflicting dispatch.
  Reuse existing SSH lifetime evidence; Pi exit alone doesn't prove active tool
  descendants stopped. Any manual resolution must explicitly acknowledge the
  remaining uncertainty, not relabel it as verified cancellation.
- After Emacs restart: previously active attempts are Interrupted / needs review
  (display reason under Execution uncertain when survival is unknown). Never
  resume, replay, or release conflicting work merely because Emacs restarted.
- Closing a window or burying Jobs doesn't stop anything. Killing an active
  owning chat requires a job-specific warning and an explicit cancel path, or
  keeping its owner alive; it must not silently forget the run/resource claims.

## 7. Schedule controls and missed starts

```text
Dependency review — Schedule
Enabled:    yes
Trigger:    Every 6h, anchored at 2026-11-01 00:00 UTC
Next due:   2026-11-01 06:00 UTC

[Disable schedule]   [Change…]   [Run now…]   [Back]
```

- Interval ticks use fixed due times. Skip an occurrence if this definition is
  active/queued or admission is busy; show last skipped reason in job details.
  Don't accumulate missed ticks or create a failed-run row for every skip.
- Disable prevents future occurrences; it does not cancel active/queued attempts.
  Offer a separate Cancel run action. Re-enabling starts a new interval anchor
  with the next due time shown for confirmation; it doesn't run immediately.
- Restore enabled intervals after restart at a fresh future anchor; disclose the
  restoration, no backlog. Missed one-shot: Missed while Emacs was closed with
  Review and run now / Reschedule / Dismiss. No automatic late execution.
- A one-shot waiting for a resource stays visible as Waiting until cancelled or
  admitted; eligibility is checked again at dispatch. It is not a missed start.
- Plan-phase failure/interruption suspends automatic execution pending explicit
  review; completion disarms its trigger. Recurrence never implies phase retry.
- Ordinary recurring checks may execute on the next scheduled occurrence after a
  settled failure; this is a new occurrence, not immediate retry. Uncertain
  execution suspends the definition and retains conflicting resource claims.
- Times show an explicit timezone and absolute date in review/details, even if
  the list uses compact relative time. Emacs must remain running for timers.

## 8. Future chaining preview — separately authorized later

Not an initial active feature or a reason to add disabled workflow controls now.
When authorized, extend the same review/details surfaces:

```text
Afterward: If validated result says updates_found = true,
           run Prepare update report with explicit mapped inputs.

[Run with authorized successor]   [Run this job only]   [Cancel]
```

A downstream run shows Trigger: After Dependency review / r-105 and links to
that exact upstream run. Conditions that don't match show Not triggered in the
upstream details, not a failed downstream run. Chain scope/rules are captured;
diagnostic Run again defaults to this job only. For plan sequences explicitly
show authorized phases and Stop before Phase N. No inferred adjacency, cycles,
joins, graph editor, or automatic advancement past acceptance gates.

## Review request

Accept or revise v1 as the UI/workflow direction. Acceptance does not authorize
Phase 2 automatically. New interactions beyond this accepted scope require
further review. No live prototype or implementation is included in this artifact.

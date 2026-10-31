# Manual Jobs UI design audit

Reviewed 2026-10-31 after the user reported the raw configuration shown by RET
on a saved job. This is supporting review evidence, not another task checklist.
The authoritative tasks/status remain in plan.org. Findings below are the
pre-repair snapshot, not a claim that those defects remain in the working copy.

## Repair follow-up

The user subsequently authorized Phase 2 repairs and fewer, behavior-focused test
files. The recorded code gaps have been addressed and checked by the regular,
full optional, real-SSH and expanded graphical automation suites; execution,
ownership and UI tests now share pichat-test-jobs.el. See plan.org for current
results, file sizes and the remaining visible-layout review. Graphical automation
does not constitute human visual acceptance: a separate screenshot attempt found
this environment's frame remained iconified, so no visible layout signoff is
claimed. No later phase or implementation commit was included.

## Baseline and scope

- ui-accepted.md is authoritative over conflicting ui-example-v1.md choices.
  The original example supplies compatible details/navigation expectations.
- Reviewed all of pichat-jobs.el, relevant pichat-evil.el bindings, launch
  capture/decoding, cached runtime attention handling, shared view lifecycle,
  README manual-job documentation and the UI/live-smoke tests.
- Source/render/isolated behavioral audit, not a new graphical human acceptance
  pass or full execution-safety audit. No user's running Emacs, metadata,
  provider or SSH runtime was used. Existing pichat/jobs.json left untouched.
- No implementation changes made by this audit.

## What already matches

- New job is directly accessible without a chat/runtime. Instructions use a
  multiline editor; Apply returns without submission. Project and execution
  controls are available from setup.
- Save job does not run; Run once creates an unsaved attempt. Jobs/Runs share
  one global buffer. The job list separates Schedule from Latest run.
- Browsing/refresh reads cached records. Submission uses an independent runtime
  without selecting its chat or replacing the current/preferred runtime.
- Existing Tools/model controls are reused without preferred-runtime reuse,
  source selection or reconfiguration. Changed presets are warned about in setup.
- Current-definition Run job and historical Repeat this run are distinct.
  Repeat opens a captured-settings draft rather than dispatching immediately.
- Run details distinguish execution/result, label agent prose as reported,
  retain saved-session references and expose exact-chat and diagnostics actions.
- Required input routes to the owning chat; hidden input does not prompt or
  auto-approve. Cancellation and explicit uncertain/manual-release paths exist.
- Native/Evil list actions are implemented; auxiliary details have q-to-return
  through the shared view lifecycle. A literal Back button is not required where
  that working native equivalent supplies the same navigation.
- The accepted simple setup supersedes the original Transient mockup. Direct
  unchanged manual Run job without a redundant confirmation is also accepted;
  restoring the old generic review screen would not be a required repair.

## Phase 2 gaps

### Setup and execution settings

- Tools are presented as raw Lisp (or `nil`) rather than an understandable
  preset/default/customized summary. The default summary is not consistently
  resolved; a missing concrete model is shown as `prompt` rather than an
  actionable setup status until submission fails.
- The active coordination choice is hidden. Although it is editable under
  Execution settings, returning to setup does not show May modify / Stable
  read-only / Accepts changing files. The general sandbox disclaimer is not a
  replacement for showing the selected policy. Details omit it too: the raw
  configuration dump does not include the spec's resource declarations.
- **Behavioral defect:** invalidating a captured configuration builds a profile
  with preset/target/model but omits its Tools customization. Changing only Model
  therefore silently drops the old subset in favor of the preset baseline.
  Workspace changes pass through the same invalidation path. The Tools picker
  also starts without the previous customization. Generic re-resolution
  confirmation does not explain this loss of otherwise unchanged settings.
  Preset/target changes may require different validation, not indiscriminate
  loss on every execution edit.

### Jobs/Runs lists and history

- There is no overview attention count/link or running-versus-limit summary.
  A Needs input row exists, but users must locate it themselves.
- Runs omits project/workspace/target context. Job names can be shared and list
  rows abbreviate projects, leaving unrelated work hard to distinguish without
  opening each record.
- The history filter has no visible job/filter label. Returning to Jobs does
  not restore the previous selected job (reproduced with the second of two jobs).
- Fixed-width columns/header text do not implement the mockup's narrow-window
  adaptation. This was found by source review, not a new graphical layout test.

### Job definition and run details

- Raw command/preset/transport Lisp is always expanded, including potentially
  sensitive arguments. Use readable summaries and an explicit secondary raw
  inspection action; this applies to both definition and run details.
- Definition details lack Latest run, direct latest-run opening, and history.
  Run details lack a direct related-job/history route and a separate human-readable
  Instructions/settings action. Generic q-to-return already works.
- Runs shows a `Started / queued UTC` column populated only from created-at.
  Details show only queued time, not the designed start/finish timeline. Records
  currently have created-at/updated-at, not distinct durable start/finish fields;
  updated-at must not be misrepresented as an actual finish time.
- Queued details display a blocking run ID but offer no Open blocking run action.
- Needs input has a state label and Open chat, but no reason/actionable attention
  summary in details. Existing pending chat requests should supply that context
  without inventing a second approval UI.

### Cancellation, uncertainty and retained results

- Cancel confirms title/run ID, but omits the captured target/workspace specified
  in the design. Execution can show Starting/Finishing in preference to Cancelling;
  cancellation attention is not consistently preserved across those phases.
- All uncertain runs show Recheck remote Pi exit, even local runs or restored
  records without a retained observer-capable process. These actions then error;
  expose only applicable actions and explain unavailable evidence.
- When the owning runtime/chat is unavailable, Open chat remains an active button
  that errors and directs users to the saved-session reference. The designed
  separately labelled Open saved session independently action is missing. It
  must remain an explicit runtime launch, not rerun/resumption of the job.
- Held coordination resources/policy are not explained alongside uncertainty.
  Existing manual acknowledgement correctly does not claim verified shutdown.

## Correctly deferred, not Phase 2 defects

- Org phase selection/eligibility/human authorization: Phase 3.
- Schedule enable/disable, once/interval/timezones/missed starts: Phase 4.
- Conditional successors/chaining: separately authorized Phase 5.
- Stable Org IDs and plan-content-change detection remain explicitly deferred.
- Schedule Off is appropriate now; the implementation-phase parenthetical is
  development-oriented presentation, not evidence of a missing scheduler.
- No requirement to expose disabled schedule/graph/plan controls in manual setup.

## Evidence and test coverage limits

- Existing jobs UI tests check browsing non-dispatch, Save versus Run, multiline
  apply, picker cancellation, Tools roundtrip and model cancellation. The graphical
  smoke checks a happy-path save/run/inspect/exact-chat flow. They do not assert
  the accepted content/navigation of every screen or preservation on a successful
  model edit. Passing these was insufficient evidence for design acceptance.
- Four temporary isolated design-contract ERT probes in
  /tmp/pichat-jobs-ui-audit.el all failed as expected against the present code:
  inherited-Tools explanation, visible stable-read coordination, selected-job
  restoration, and successful model-edit preservation of a captured Tools subset.
  The log is /tmp/pichat-jobs-ui-audit.log. Failures were contract assertions,
  not provider/network/setup failures. No external Pi process was started.
- These probes are review evidence, not permanent regression tests. Repairs need
  durable coverage and a fresh graphical check of the actual designed screens,
  including narrow windows, history roundtrips, input, waits and unavailable
  runtime actions. Prior execution-suite results remain historical evidence;
  they do not close these newly identified UI acceptance gaps.

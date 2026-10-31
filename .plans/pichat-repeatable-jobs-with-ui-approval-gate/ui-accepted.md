# Accepted PiChat Jobs UI direction

Accepted 2026-10-31. User: “so the designs look good to me. we can procees”.
This records the revised conversational examples and supersedes conflicting
choices in ui-example-v1.md. It is supporting design evidence, not a task list.

- Entry: New job directly (`pichat-job-new`), or `+ New` from Jobs. No chat or
  runtime is required first. Later, Run phase with PiChat from an Org heading
  prefills the same setup with the selected phase.
- Simple setup: instructions, project, compact resolved execution summary and
  Change action. Actions: Run once, Save job, Cancel. A multiline draft survives
  round trips through preset/Tools/model/target pickers. Cancelling a sub-picker
  leaves the rest of the draft untouched.
- Reuse the launch controls, not preferred-runtime reuse, saved-conversation
  selection, or reconfiguration. Each attempt starts a fresh independent saved
  Pi session without changing current/preferred runtime or focus.
- Execution settings expose preset, Tools, model, target and workspace. Advanced
  coordination settings are distinct from permissions and cannot promise a
  sandbox. Default conservatively; expose stable versus tolerant readers without
  forcing every ordinary submission through a concurrency questionnaire.
  Follow-up after visible user review: omit the default modifier policy and
  generic coordination/sandbox/save boilerplate from ordinary setup/details.
  Show non-default policies there; keep every policy inspectable in captured
  settings and editable in the coordination picker. Actual blocking/uncertainty
  and consequential-action warnings remain.
- Run once executes without saving. Save job creates a disabled reusable
  definition and never runs it. Run job uses its current definition and doesn't
  change its schedule. Enabling a schedule is a separate explicit action.
- One Jobs view: Jobs rows separate Schedule from Latest run; Runs shows attempts,
  including unsaved one-offs. Browsing/refresh never dispatches execution.
- Run details show execution state, outcome, trigger, scope/target, bounded result
  and exact-chat/settings/diagnostic/history actions. Agent statements about file
  changes are labelled as reported, not independent filesystem verification.
- Repeat this run reviews captured historical settings; Run job uses the current
  definition. Explicit edits/refreshes don't change existing run snapshots.
  Captured preset/model/tool choices do not freeze remote extension code or the
  entire environment. Make changed preset definitions visible, not silent refresh.
- Avoid redundant confirmation for unchanged ordinary manual submissions. Review
  consequential actions: scheduling, plan authorization, changed settings,
  historical repetition and successors. Don't add another generic confirmation
  after an explicit authorization screen.
- Needs input opens the owning chat's existing UI; no focus stealing or implicit
  approvals. Needs setup is distinct from input during execution. Scheduled
  startup must defer/fail visibly rather than prompt over unrelated work.
- Future schedules: once or every interval, explicit dates/timezones, no catch-up,
  skipped busy interval occurrences, missed one-shot offers Run now/Reschedule/
  Dismiss. Disabling doesn't cancel existing work. Emacs must be open; tool/setup
  interaction may still be needed.
- Future plan adapter: plan file plus full heading path, current saved contents
  at dispatch, no stable ID requirement/insertion and no modification checking.
  No implicit save of unrelated Org edits. Missing/ambiguous selections require
  reselection. Current eligibility, explicit approval gates and phase stop
  boundaries remain. No next-phase inference.
- Phase completion needing human review is distinct from agent completion.
  Open plan/Open chat and Continue selected scope preserve existing evidence and
  authorization workflow; no generic Approve phase action in Jobs.
- Cancellation uncertainty must have an explicit inspect/recheck/manual-resolution
  path without mislabelling manual acknowledgement as verified shutdown. Reuse
  existing SSH lifetime confirmation; active descendants remain a separate limit.
- Chaining is separately authorized later, with visible successors and Run this
  job only. No disabled graph controls in the initial interface.

The acceptance closes Phase 1. The same message authorizes proceeding with
Phase 2 only; later phases still require their own execution scope.

# Intake protocol and operation

## Org source contract

Capture remains an ordinary direct child of the single `* Ideas` heading.
Unmarked direct `**` children are IDEA; deeper headings and notes belong to that
idea. No metadata is required at capture. Install this file-local declaration:

```org
#+TODO: IDEA QUEUED NEEDS-INPUT | PLANNED DECLINED
```

- IDEA: captured, not authorized for unattended selection.
- QUEUED: explicitly authorized for one planning attempt; use Org's TODO picker.
- NEEDS-INPUT: questions need a user answer. Answer in the idea notes and explicitly
  convert it or requeue; the helper does not silently requeue it.
- PLANNED: a validated draft handoff, not completed implementation.
- DECLINED: explicit user decision with a reason recorded in the idea. The helper
  never automatically declines ideas; finding related work is not such a decision.

Supported syntax: UTF-8 LF text with a final newline, ordinary star headings,
optional standard uppercase intake states, uppercase A–Z priority cookies and
trailing Org tags, a property drawer immediately after the heading or one
standard planning line, nested headings, balanced `#+begin_NAME`/`#+end_NAME`
blocks and ordinary drawers. Heading-like lines inside blocks are ignored.
IDs and properties must be unique within the direct-child inventory. Property
updates preserve unrelated property lines, notes and text exactly; a new drawer,
state prefix and dated single-line note are the only additions.

This is a deliberately bounded scanner, not a general Org parser. Dynamic blocks,
includes, custom TODO sequences, CRLF, misplaced/duplicate property drawers,
unterminated blocks/drawers and headings inside drawers fail visibly. Do not
silently rewrite unsupported structure. Arbitrary user text is never evaluated.

Properties owned by the helper:

```org
:PROPERTIES:
:ID: standard-org-id
:IDEA_PROJECT: /absolute/execution-checkout
:IDEA_PLAN_ID: idea-derived-uuid
:IDEA_PLAN_STORE: /absolute/authoritative/plan-directory
:IDEA_PLAN_FILE: /absolute/authoritative/plan-directory/idea-derived-uuid/plan.org
:END:
```

New IDs are UUID4; existing Org IDs are preserved. Plan IDs use the UUID itself,
or UUID5 for an existing non-UUID ID. Plans have exact `SOURCE_IDEA_ID` and
`SOURCE_IDEA_FILE` keyword fields plus an Org `id:` source link. The idea's
IDEA_PLAN_FILE and dated handoff note provide the reverse reference. Paths are
runtime-local metadata; they can be private. Review before publishing records.
Moving source, checkout or store requires explicit inspected reconciliation; no
local/SSH fallback, implicit reference repair or second authoritative record.

## Helper commands

Run with `python3 <skill-directory>/scripts/ideas.py`. Global options precede
the command:

```sh
python3 scripts/ideas.py --source /workspace/ideas.org --root /workspace/project list
python3 scripts/ideas.py --source /workspace/ideas.org --root /workspace/project convert 'Unique title'
python3 scripts/ideas.py --source /workspace/ideas.org next --unattended
python3 scripts/ideas.py --source /workspace/ideas.org --root /workspace/project needs-input IDEA-ID --expect HASH --question 'Which backend should this target?'
python3 scripts/ideas.py --source /workspace/ideas.org --root /workspace/project publish IDEA-ID --expect HASH
python3 scripts/ideas.py --source /workspace/ideas.org --root /workspace/project reconcile IDEA-ID
python3 scripts/ideas.py --source /workspace/ideas.org --root /workspace/project reconcile IDEA-ID --publish --expect HASH
```

Use actual absolute paths, not these placeholders. `--source` is mandatory;
`--root` is optional only if the selected idea already records IDEA_PROJECT or
when listing. Missing project during conversion records NEEDS-INPUT. The helper
never guesses it from the current directory. Explicit `--root` applies to the
one selected idea and conflicts with a different recorded project.

`--plans` defaults to `~/.pi/agent/skills/plans/scripts/plans.py`; resolve another
installed skill explicitly when appropriate (including PI_CODING_AGENT_DIR).
`--config`, `--project` and `--local` delegate to plans. The helper imports its
inspected `root_path`/`storage_path` functions for pre-creation store reservation
and uses its subprocess CLI for inventory, creation and checks. That API is a
version dependency: fail if unavailable, never implement a parallel storage
resolver or modify the shared plans skill. Inherited plans environment/config is
live; changing it to another store fails against IDEA_PLAN_STORE.

JSON stdout is one value; 0 means a handled outcome (including no-op or
needs-input), 1 means conflict/failure. Argument errors use argparse stderr and
exit 2. Inventory includes titles, IDs, states, properties and source_sha256.
Handled conversion outcomes include idea_id, state, plan_path (nullable),
source_sha256 and next_action; publication includes plans validation results.
Errors include an actionable error/next_action but may lack identity/path if
failure prevented trustworthy resolution. Keep any preceding `created` result
in the agent report so provisional paths remain visible after a later failure.

## Handoff, concurrency and recovery

1. Lock the canonical source's sibling `.FILENAME.idea-to-plan.lock` using Unix
   `flock` (nonblocking). It serializes cooperating helpers across projects that
   share a source. Never unlink the persistent inode: that can split the lock.
   Its JSON PID/time is diagnostic only. Kernel locks release at process exit,
   including crashes; there is no timeout-based lock stealing or abandoned lock
   deletion. Inspect the owning process if busy. Distributed/NFS flock behavior
   is filesystem-dependent and is not promised.
2. Parse/revalidate source state; inventory **active and archived** plans through
   the selected store. Reject multiple claimants, missing references, changed
   stores/project, and a reserved ID claimed by a different identity.
3. Atomically save idea ID, project, reserved deterministic plan ID and resolved
   store **before** creating the plan. If interrupted, explicit convert can retry
   that same reservation. Reconcile alone never creates a missing record.
4. Use plans `new --id RESERVED --title 'Title [idea:ID]'`. Identity is present
   in the very first template write; a crash before adding SOURCE fields remains
   discoverable. Even an interrupted zero/partial plan file blocks reuse of the
   reserved ID and needs inspection, not another ID. Append source fields while
   removing the title marker in one atomic file replacement, then link the source.
5. The agent researches/drafts outside the helper lock. A later invocation can
   discover this provisional record but must not blindly overwrite it. Agents
   must coordinate concurrent prose editing; flock covers helper operations, not
   arbitrary plan editors or a whole model turn.
6. Publication verifies expected source hash, exact source identity/file, draft
   status, meaningful non-template required sections and plans structural check.
   It rechecks plan contents and source before marking PLANNED. The structural
   checks are not a quality certification. Existing PLANNED handoffs are
   idempotent; non-draft/archived records are reported, not implicitly requeued.

Source writes use a same-directory temp file, preserve permissions, fsync,
stale-content checks and atomic replacement. Two files are **not a cross-file
atomic transaction**. A race with an arbitrary editor after the last stale check
cannot be excluded. A crash can retain a reservation, provisional draft or
unlinked draft, each recoverable via the recorded IDs and selected inventory.
No automatic deletion, record overwrite, rollback or requeue occurs.

Save first. `. #`-style Emacs locks (actual prefix `.#`) and `#FILENAME#` autosaves
are conservatively refused, including dangling lock symlinks; source symlinks are
also refused. No helper can fully detect unsaved buffers when lockfiles/autosaves
are disabled, and no Emacs bridge is required or used. Do not force-save/revert
buffers or claim full editor safety. Saved-file changes during drafting reject
publication; inspect changes and reconcile rather than merely refreshing HASH.

## PiChat use

See `pichat/GLOSSARY.md` for **job run**, **runtime**, **Pi session** and **target**.
An ordinary one-off/scheduled job run starts independent work; it does not inherit
this chat's memory. Source/plan files hold durable recovery. PiChat does not lock
workspaces; same-job exclusion does not coordinate different jobs or chat runs.

1. On the execution target, verify skill discovery and plans availability. For
   this checkout, trust reviewed project resources and `/reload` after creating
   the skill; inspect `/skill:idea-to-plan`. No global copy is installed. SSH must
   have its own runtime-accessible checkout, source and installed plans helper.
2. Use `M-x pichat-job-new`; choose Workspace, a concrete model, target and an
   execution-capable preset such as `coding`. Default `manual` omits bash. Missing
   execution tools are a blocker, not a claim that helpers or checks ran.
3. Review instructions, then explicitly **Run once**. Example prompt:

```text
Use the idea-to-plan and plans skills in /workspace/project. Process at most one
explicitly QUEUED idea from /workspace/ideas.org using next --unattended. The
execution checkout is /workspace/project; the installed plans helper is
/agent/skills/plans/scripts/plans.py. Use its configured authoritative store.
Read the selected subtree and actual project code. Missing context or material
questions must become NEEDS-INPUT with actionable questions, never an interactive
wait or guessed decision. Finish only a draft handoff and validate before PLANNED.
Report outcome, idea ID/state, provisional/final plan path, checks and next action.
Do not implement ideas, approve/execute plans, loop to another idea, save/revert
Emacs buffers, commit, push, import jobs or enable schedules.
```

For a shared multi-project file, omit the explicit checkout only when each queued
idea records its own execution project; do not assign the job workspace to every
idea by assumption. Replace all example paths before submission. To schedule
later, explicitly save/review the job and separately authorize its timing; a
successful one-off is not schedule authorization. No authored JSON definition is
provided until concrete model/preset/target choices are requested.

## Tests

```sh
PYTHONDONTWRITEBYTECODE=1 python3 .pi/skills/idea-to-plan/scripts/test_ideas.py -v
```

Tests create disposable projects and an isolated config/store. They use the
installed plans helper (override with IDEAS_TEST_PLANS), never the real ideas or
plans. Real Pi/PiChat acceptance (from this checkout, with Pi available):

```sh
PI_OFFLINE=1 PI_TELEMETRY=0 PYTHONDONTWRITEBYTECODE=1 \
  emacs -Q --batch -L pichat -L pichat/test \
  -l .pi/skills/idea-to-plan/scripts/test_runtime.el \
  --eval '(ert-run-tests-batch-and-exit "^intake-real-pi-")'
```

This uses the existing deterministic offline provider and private projects,
agent directories, session files and job store. It verifies automatic trusted
project skill discovery, explicit skill loading in an ordinary one-off job,
actual tool dispatch, validated handoff, repeated existing/no-op outcomes and
untouched implementation. Scripted tool choices are not proof of autonomous
model research or drafting quality. No real model credentials or schedule used.
Set IDEAS_TEST_PLANS_SKILL when plans is installed outside its conventional path.

The same file's `intake-live-org-capture-and-states` test requires a **separate
non-batch Emacs**, never the user's live conversations. Give that instance a
private user-emacs-directory (retain it until Emacs has finished shutdown), load
the test file with the same load-path, and run selector `"^intake-"`. Use a real
terminal or GUI and a result/exit wrapper as described in
`pichat/TESTING_GUIDELINES.md`. It captures only into a disposable source, verifies
simple capture and local intake states. These are programmatic live checks, not
human visual acceptance. In an existing standalone Pi TUI use `/reload`; RPC
runtimes can discover the skill at startup (no invented RPC reload operation).
Do not enable a real schedule.

# Report, lifecycle and explicit-input revision

Planning revision, 2026-10-31. Requested by the user after conversational UI and
source review. This supplements `ui-accepted.md`; it is not a second task list.
The authoritative implementation/checklist remains `plan.org`. No implementation
or visible-layout acceptance is claimed. This revision supersedes the generic
agent-reported disclaimer and retained-idle-runtime direction in earlier designs.

## Intended run report

```text
Hacker News top article
Run completed · Manual · 33s · Oct 31, 20:50 UTC
Workspace: …/agent · Target: local

Task
Find the best article on Hacker News currently and summarize it.

Response
[Rendered final response: headings, lists, emphasis, code, tables and links]

Actions
[View transcript]  [Continue in chat…]  [Repeat…]  [Save as job…]
[Instructions & settings]  [Diagnostics]

▸ Execution details
```

One title, compact context and timing, expandable long task, response first.
No generic “Agent-reported; not independently verified” note. Execution outcome
is not proof of task/domain completion. Show actual errors, incomplete previews,
rendering fallback, blocking conditions and uncertainty where actionable.
Diagnostics is applicable only when evidence is available; preserve bounded
inspection evidence before runtime cleanup rather than inventing availability.
Expanded details contain exact IDs/timestamps/paths, captured configuration,
trigger and repeat provenance, with copy/navigation actions. Sensitive raw
settings remain a separate explicit inspection. No synthetic progress feed.

Use existing `pichat-response-view.el` sanitized Markdown-to-HTML/SHR renderer
through a small shared public rendering/face API. Do not duplicate its sanitizer,
link policy, fallback or theme faces, nor inherit its chat-origin-dependent mode.
Keep `pichat-view-mode`, source viewing/copy, ordinary search/selection and Evil
motions. `pichat-markdown-fontification.el` is the exact-source face-only option,
not a replacement for rendered links/tables. Refresh at displayed window width,
retaining semantic reading position, focus and expansion state. Inspect/refresh
must never start Pi, submit work or fetch remote images.

## Response and conversation identity

Current `pichat-job-executor--cache-result` concatenates all canonical assistant
prose and truncates it to 2,000 display columns. That is a preview, not necessarily
the final response, and may truncate Markdown syntax. Separate preview from full
settled response and record response/source identity at completion. Choose bounded
storage with explicit overflow handling (versioned record or private sidecar),
not an unlimited expansion of the job store. Resolve no-prose/tool-only/error
endings explicitly. Legacy records remain previews unless exact evidence can be
recovered; never silently substitute the latest response in an evolved session.
Capture the run-end boundary for transcript inspection as well as the report.

Currently the original job runtime retains its input guard after completion.
Killing its chat buffer does not stop its runtime. Saved-session independent open
rejects a managed duplicate writer, then creates an ordinary unguarded runtime
with the current default preset. Further prompts extend the same saved Pi session
file; independent runtime does not mean cloned conversation (see GLOSSARY.md).

Intended actions:
- View transcript: read-only run-bounded evidence, without starting Pi, including
  after Emacs restart and after later conversation continuation.
- Continue in chat…: explicit ordinary interactive continuation, not a new job run
  or a mutation of the original report. Use the current default preset and the
  captured target/path context, review those settings concisely, reuse existing
  source reservations and fail safely for missing files or unresolved ownership.
  Do not silently stop an unrelated writer or weaken the job input guard.
- Repeat…: existing captured-settings review followed by a fresh job attempt.

Concise continuation review:

```text
Continue this conversation?
Preset: standard
New messages will extend the saved conversation.
The completed job report will not change.
[Continue]  [Cancel]
```

Show remote target when applicable. Move full paths and runtime terminology to
inspection. Do not use “Open saved session independently…” as the primary label.

## Runtime lifecycle and truthful state

After synchronized, durably captured completion, stop the owned runtime safely;
keep an already visible chat readable as a stopped/read-only transcript. Preserve
saved sessions, reports and diagnostics needed for inspection. Cleanup failure
must be visible and cannot imply safe release of claims/source ownership. Reuse
existing local/SSH lifecycle evidence; Pi exit does not prove descendant safety.
Retain required runtime/recovery tracking for pending input, cancellation and
uncertain execution. No idle process solely to represent a finished result.

Keep execution state, result and attention separate. Pending input means an
explicit queued extension UI request, not a question detected in prose or silence
from a subprocess. Queued blockers, input requests, failure reasons and uncertain
claims remain visible above secondary details. Answering a pending request goes
to the exact owning chat; no focus stealing. Ordinary textual questions can still
end a run; an ask tool is guidance/interaction, not a guarantee of domain success.

## pi-ask-user source review

Repository: https://github.com/edlsh/pi-ask-user
Reviewed main commit: df1df70acf1f7521d24f9518a702064930340df2
Package metadata at review: 0.17.1, MIT. Reviewed README, package metadata and
relevant execution/RPC fallback source; not installed or executed. Main is mutable;
pin an immutable reviewed revision for the integration experiment.

Useful existing behavior:
- Model-only `ask_user`, sequential execution, structured answer/cancellation
  details, free text, choices, optional comments and batches.
- `ctx.ui.custom()` fallback explicitly uses `ctx.ui.select`/`input`; Pi 1.4.0 RPC
  has UI and supports these methods. PiChat already queues them with focus gating
  and exposes pending-request attention. No custom RPC protocol is needed for
  basic integration, and `herdr:blocked` is not the source of Jobs truth.
- Abort propagation and timeouts are implemented; upstream has tests, but their
  presence is not evidence of passing PiChat integration.

Tradeoffs and checks:
- Most implementation is terminal UI (index.ts is 3,374 lines at this revision).
  Emacs gets fallback dialogs, not searchable rich panels/review pages.
- Single-select fallback sends option titles, not descriptions. Multi-select
  accepts parsed typed text rather than a native validated multi-choice form.
  Batch fallback is sequential and cancellation discards the whole batch.
- Single-question timeouts apply per dialog stage; batches have one deadline.
  The supported Pi RPC protocol does not document a dialog-withdrawal event.
  PiChat's reviewed queue removes requests on local response or session end;
  timeout/agent-side abort while the chat is hidden needs a real integration test
  and a safe stale-request reconciliation mechanism, whichever extension we use.
- Cancellation returns a cancelled tool result, not necessarily termination of
  agent work. A refusal, dismissal, timeout, unavailable UI or malformed answer
  must never become authorization. Define stop/wait behavior for dependent work;
  sequential tool execution alone does not make an approval boundary.
- The bundled skill encourages mandatory decision gates, and guidelines include
  asking when multiple valid options exist. This is broader than “only when
  necessary.” Evaluate extension-only loading and precise prompt guidance; do not
  automatically enable the bundled skill globally or declare two ask_user tools.
- Full answer/context event broadcasting is opt-in, but default events still
  include question text. Review privacy and installed-extension trust; tool
  answers are conversation content, not a secret-input mechanism.

Recommendation: evaluate pinned upstream first using isolated real-Pi fixtures,
without adopting its entire TUI or skill policy. Prefer a small upstream fix if
only fallback presentation is deficient. If strict structured choices, distinct
cancellation outcomes, or native Emacs question presentation require a substantial
adapter, choose a small PiChat-owned model-only tool over a fork of the terminal
implementation. Reuse standard ctx.ui dialogs and the owning-chat queue where
possible. Do not confuse this tool with the trusted plan-phase approval contract.
Final adoption versus custom implementation remains a user decision after the
compatibility/UX evaluation; the report/lifecycle work does not depend on it.

### Real-Pi evaluation (2026-10-31)

Checked out the pinned revision to `/tmp/pichat-ask-user-phase2` and loaded only
its `index.ts` with `-e`, alongside PiChat's offline fake provider. No dependency
installation, global extension/skill activation, user credentials or real model.
An isolated temporary Emacs harness exercised five cases against Pi 1.4.0:

- Choice plus optional comment: existing native completion/input worked, correct
  answers reached the canonical tool result, focus stayed unchanged until explicit
  chat selection. Context was present; single-select descriptions were absent.
- Batch free-text followed by multi-select: two ordered native input dialogs.
- Dismissal: tool result said Cancelled, but the scripted next model turn still
  ran. It is not an execution/approval stop boundary.
- Hidden timeout: Pi completed the tool and next model turn, but PiChat retained
  the expired UI request. The revised executor conservatively marked execution
  uncertain at settlement rather than releasing pending-input work as successful.
- Hidden abort: similarly left a stale pending UI request; no completion or
  authorization was inferred.

Final harness 5/5 expected observations passed in 3.32s; log:
`/tmp/pichat-phase2-ask-evaluation.log`. Harness:
`/tmp/pichat-ask-user-phase2-evaluation.el`. These are compatibility observations,
including demonstrated deficiencies, not five passing product acceptance cases.
An initial invalid fixture used string options; the current declared schema
requires option objects despite source coercion accepting strings. Fixed only
the fixture. A separate isolated JSON/print-mode run confirmed missing UI returns
an “Ask requires interactive mode” tool result, then permits the scripted next
turn (`/tmp/pichat-phase2-ask-no-ui.log`); it is not an answer/approval boundary.

**Decision recommendation:** do not enable this revision unmodified for jobs.
Prefer upstream plus small RPC presentation/policy changes over maintaining a
custom TUI fork. First reconcile expired/aborted dialog ownership in PiChat,
retain descriptions and enforce explicit handling of necessary-answer cancellation
before dependent work. A custom ask tool alone would not fix the generic stale
RPC queue issue. If the user wants stricter native structured choice semantics,
a small PiChat-owned model-only tool remains an alternative. Do not globally
adopt either yet; show the actual native question flow for approval first.

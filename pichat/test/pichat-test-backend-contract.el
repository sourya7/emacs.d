;;; pichat-test-backend-contract.el --- Native backend contract targets -*- lexical-binding: t; -*-

;;; Commentary:
;; Phase 0 targets, intentionally skipped until a backend boundary exists.
;; Activate each target in the phase named by its TODO reason, using mocked HTTP
;; around the real pinned llm lifecycle and the shared chat path.  Codex proxy and
;; Vertex protocol fixtures remain offline.  No speculative production API is
;; frozen here.  Existing Pi input/projection tests remain active regressions.

;;; Code:
(require 'ert)

(ert-deftest pichat-backend-contract-memory-liveness-and-optional-dependency ()
  "An idle memory session is alive with no process; stop makes it not alive.
Pi-only startup must not load or require llm or provider modules and must not
probe CLIProxyAPI or gcloud.  Backend identity must prevent preferred Pi and
native sessions in the same directory from being reused as one another.  Stop
and cleanup are idempotent."
  (ert-skip "TODO Phase 1: backend dispatch and non-process session fixture"))

(ert-deftest pichat-backend-contract-capability-rejection-preserves-draft ()
  "Unsupported operations fail before side effects or input consumption.
Reject images without image-input, concurrent submits while busy, and Pi-only
commands on a memory session.  Exact prompt text and pending attachments remain
available, with no new journal entry, request, or implicit Pi startup."
  (ert-skip "TODO Phases 1–3: capability guards through shared input path"))

(ert-deftest pichat-backend-contract-inline-completion-does-not-leak-submission ()
  "Inline provider callbacks obey the same lifecycle as delayed callbacks.
Initialize identity and pending state before provider invocation.  Acceptance
precedes visible user/live events; rejection creates no canonical user entry.
After inline final success, no pending submission or in-flight attachment
remains, and a returned handle cannot resurrect the completed run."
  (ert-skip "TODO Phase 2: mocked-HTTP llm callback fixture"))

(ert-deftest pichat-backend-contract-acceptance-is-not-settlement ()
  "Acceptance does not clear a running tail or announce the assistant done.
After acceptance the authoritative user entry exists exactly once.  Tool-only
model responses do not settle the agent.  On terminal success, error, or abort,
commit terminal journal entries before exactly one settlement notification.
A settlement-triggered snapshot must already contain those entries.  An llm
round callback is not whole-run settlement when PiChat will resubmit the retained
prompt after tools."
  (ert-skip "TODO Phases 2/4: llm text and application-owned tool rounds"))

(ert-deftest pichat-backend-contract-cancel-query-is-not-abort-run ()
  "Cancelling one owned snapshot subscription does not abort the model run.
Aborting a run invalidates its callbacks and pending tool approvals first,
then requests transport cancellation.  Late partial/success/error callbacks
cannot mutate the journal, clear a newer run's handle, or emit settlement."
  (ert-skip "TODO Phase 2: distinct owned-query and run cancellation fixtures"))

(ert-deftest pichat-backend-contract-source-rebind-rejects-old-callbacks ()
  "New conversation, source rebind, stop, and chat death invalidate old work.
Deliver callbacks from the previous source after starting a new source/run;
new transcript, input, attachments, source generation, and journal are unchanged.
A callback after buffer death neither recreates the chat nor leaks a timer.
Separate sessions never share retained llm prompts, provider objects, request
handles, cumulative stream state, or entry journals."
  (ert-skip "TODO Phase 2: delayed provider and stale snapshot fixtures"))

(ert-deftest pichat-backend-contract-streaming-chunks-settle-authoritatively ()
  "Streaming text/reasoning callbacks are cumulative snapshots, not chunks.
Repeated prefixes replace/diff idempotently; final output may correct the last
partial snapshot.  Empty output and final success/error callbacks still produce
exactly one canonical terminal outcome.  Repeated full and cursor snapshots
project identical settled text without duplicate entries."
  (ert-skip "TODO Phases 2/3: llm cumulative streams and canonical replay"))

(ert-deftest pichat-backend-contract-tools-are-approved-correlated-and-bounded ()
  "Tools execute only under the owning session's policy while the run is live.
Repeated equal tool calls receive different local IDs; out-of-order completions
retain their own arguments/results.  Denial becomes a result, not execution.
Cancellation during approval and exhausted round/call budgets cause no further
side effects or model calls.  Continuation reuses the prompt without a user turn."
  (ert-skip "TODO Phase 4: asynchronous tools, approvals, and bounded loop"))

(provide 'pichat-test-backend-contract)
;;; pichat-test-backend-contract.el ends here

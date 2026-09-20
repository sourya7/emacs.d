---
schema_version: 1
last_verified_pi: null
last_verified_pi_commit: null
last_verified_rpc_doc_blob: null
last_reviewed_pi: 0.84.4
last_reviewed_pi_commit: b79e4cc834970cca69daebffab7df1da7d1e52c4
last_reviewed_rpc_doc_blob: 52dbf884f53c281329e83444574c74c142564181
---

# Pi compatibility record

This is the durable record of Pi versions tested with PiChat and upstream RPC
changes already reviewed. `last_verified_pi` advances only after the complete
real-Pi suite passes against that exact version. `last_reviewed_pi` may advance
when every intervening RPC documentation change has a disposition below, even
if verification remains blocked by a known failure.

The upstream contract history is
[`packages/coding-agent/docs/rpc.md`](https://github.com/earendil-works/pi/commits/main/packages/coding-agent/docs/rpc.md).
Store immutable Pi release commit and RPC document blob IDs with each watermark;
a version alone cannot distinguish a moved tag or an unchanged RPC document.

## Current status

- The verified-release watermark has not yet been advanced. Phase 0 baseline
  runs against Pi 0.85.1 passed with the optional-dependency skips noted below;
  this scoped backend investigation does not advance compatibility watermarks.
- The persisted-session fixture baseline is Pi 0.80.6; this is fixture provenance,
  not proof that the current complete suite passed on that release.
- RPC documentation changes through Pi 0.84.4 have been reviewed.
- The earlier verification attempt against Pi 0.84.4 failed. It remains in the
  history independently of the later successful baseline runs.

## RPC change ledger

Every upstream RPC-document change between two reviewed versions must appear
here. Use one of these dispositions:

- `implemented` — PiChat has explicit behavior and tests for the change.
- `compatible-no-change` — additive or otherwise compatible with existing
  PiChat behavior; relevant tests or rationale are recorded.
- `intentionally-unsupported` — PiChat deliberately does not expose it.
- `not-applicable` — PiChat does not use the affected RPC surface.
- `pending` — reviewed, but work or a decision remains.

| Upstream change | First relevant release | Disposition | PiChat evidence or follow-up |
|---|---:|---|---|
| [`c17939521`](https://github.com/earendil-works/pi/commit/c179395218416b0352d2d11a4025fac0668a2676) `get_available_thinking_levels` | 0.81.0 | compatible-no-change | PiChat derives levels from model metadata and exercises thinking controls in `pichat/test/pichat-test-chat-controls.el` and the real-Pi integration suite. |
| [`f8b74a450`](https://github.com/earendil-works/pi/commit/f8b74a4507a0505cc8275a8f5afcdd9072cc75f0) nested extension/compaction usage accounting | 0.81.0 | compatible-no-change | PiChat consumes `contextUsage`; additive usage and cost fields are safely ignored where they are not presented. Context and compaction accounting have real-Pi integration coverage. |
| [`7540da401`](https://github.com/earendil-works/pi/commit/7540da4016bdbf405b9c4dc62d401cca15e270d1) summarization retry events | 0.81.1 | compatible-no-change | Unknown/additive events are accepted through generic dispatch, while `agent_settled` remains PiChat's synchronization boundary. |
| [`fc85bdd88`](https://github.com/earendil-works/pi/commit/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc) direct-RPC `bash_execution_update` | 0.82.0 | not-applicable | PiChat does not issue Pi's direct `bash` RPC command; agent tool execution uses `tool_execution_*`. |
| [`a4475344f`](https://github.com/earendil-works/pi/commit/a4475344fb765850ec5321efe3c67e6f364ead5c) delta-only `message_update` | 0.84.0 | implemented | `pichat/pichat-pi.el` assembles indexed deltas and treats `message_end` as authoritative. Unit and real-Pi tests cover 0.83/0.84 stream equivalence and delta rendering. |
| [`c93ea6ccf`](https://github.com/earendil-works/pi/commit/c93ea6ccf0a398c293641e8001db06b8f7997c79) streaming usage field | 0.84.2 | compatible-no-change | The top-level field is additive; transcript reduction ignores it without rejecting the event. |
| [`830a0a59e`](https://github.com/earendil-works/pi/commit/830a0a59e975ed3a4e551be18dc60d45479f5118) tool metadata at `toolcall_start` | 0.84.3 | implemented | Live tool correlation and enrichment are covered by `pichat/test/pichat-test-transcript.el` and `pichat/test/pichat-test-tool-enrichment.el`. |
| [`a79b37334`](https://github.com/earendil-works/pi/commit/a79b3733421ead0dcea3cbe32247ea2464400dcb) `clear_queue` | 0.84.4 | pending | PiChat has no `clear_queue` wrapper. Decide whether abort should retrieve and restore queued text before claiming this behavior. |
| [`bea67d90d`](https://github.com/earendil-works/pi/commit/bea67d90d1a74dde8852c63cac72d476013d3879) abort cancels compaction/branch summary and waits for idle | Reviewed in 0.85.1 | compatible-no-change | Phase 0 reviewed the RPC and implementation diff. PiChat retains event-based settlement; `pichat-test-lifecycle.el` covers aborted compaction. No new abort/compaction UI behavior is claimed. |

Do not delete rows after implementation. Change their disposition and add the
implementation and test locations so later upgrades do not rediscover the same
feature.

## Verification history

| Date | Pi version | Pi release commit | Command | Result |
|---|---:|---|---|---|
| 2026-09-06 | 0.84.4 | [`b79e4cc8`](https://github.com/earendil-works/pi/commit/b79e4cc834970cca69daebffab7df1da7d1e52c4) | `pichat/test/run-tests.sh --full` | **Failed:** 632 expected, 2 failed, 3 skipped. Failures: `pichat-consult-archive-process-classifies-caller-and-availability-failures` and `pichat-integration-mutation-timing-requires-pre-execution-hook`. |
| 2026-09-20 | 0.85.1 | [`d981de12`](https://github.com/earendil-works/pi/commit/d981de1229ef899957bbe968bc8dcda02a21f477) | `pichat/test/run-tests.sh --full` (native-backend Phase 0 baseline) | **Passed:** 635 passed, 0 unexpected, 3 optional-dependency skips (two Consult/Embark tests, one Orderless test). No production changes. |
| 2026-09-20 | 0.85.1 | [`d981de12`](https://github.com/earendil-works/pi/commit/d981de1229ef899957bbe968bc8dcda02a21f477) | `pichat/test/run-tests.sh --full` (Phase 0 final) | **Passed:** 635 passed, 0 unexpected, 11 skips: the same 3 optional-dependency skips plus 8 explicit future-backend contract targets. No production changes. |
| 2026-09-20 | 0.85.1 | [`d981de12`](https://github.com/earendil-works/pi/commit/d981de1229ef899957bbe968bc8dcda02a21f477) | `pichat/test/run-tests.sh --full` (corrected gptel decision) | **Failed:** 634 passed, 1 failed, 11 skipped. The timing-sensitive `pichat-rpc-unexpected-exit-retains-stderr-outside-normal-error-event` observed Emacs's process-sentinel suffix in stderr; it passed 5/5 focused reruns. |
| 2026-09-20 | 0.85.1 | [`d981de12`](https://github.com/earendil-works/pi/commit/d981de1229ef899957bbe968bc8dcda02a21f477) | `pichat/test/run-tests.sh --full` (corrected gptel decision rerun) | **Passed:** 635 passed, 0 unexpected, 11 skips. No production changes; eight skips remain future native-backend contracts. |
| 2026-09-20 | 0.85.1 | [`d981de12`](https://github.com/earendil-works/pi/commit/d981de1229ef899957bbe968bc8dcda02a21f477) | `pichat/test/run-tests.sh --full` (llm/CLIProxy Phase 0R) | **Failed:** 634 passed, 1 failed, 11 skipped. The timing-sensitive `pichat-consult-archive-process-classifies-caller-and-availability-failures` passed 5/5 focused reruns. |
| 2026-09-20 | 0.85.1 | [`d981de12`](https://github.com/earendil-works/pi/commit/d981de1229ef899957bbe968bc8dcda02a21f477) | `pichat/test/run-tests.sh --full` (llm/CLIProxy Phase 0R rerun) | **Passed:** 635 passed, 0 unexpected, 11 skips. No production changes; eight skips remain future native-backend contracts. Compatibility watermarks unchanged. |

A failed attempt is retained because it records what was actually tested, but it
must never update the `last_verified_*` fields.

## Upgrade workflow

1. Run `pichat/test/report-upstream-rpc-changes.sh [OLD_REF] [NEW_REF]`.
   With no refs, it compares `last_reviewed_pi` to the installed `pi --version`.
2. Review each reported upstream commit and add it to the RPC change ledger with
   a disposition. Inspect the corresponding implementation diff when the docs
   are ambiguous.
3. Implement or explicitly defer pending changes and add focused tests.
4. Run `pichat/test/run-tests.sh --full` using the exact target Pi release.
5. Record every attempt in the verification history. Only on a complete pass,
   update `last_verified_pi`, its release commit, and its RPC document blob.
6. Once every intervening RPC change has a ledger row, update the three
   `last_reviewed_*` fields.

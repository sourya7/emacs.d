---
schema_version: 1
last_verified_pi: 1.6.0
last_verified_pi_commit: faac585884ae2c013a6b1400f3e9e77f10b34bac
last_verified_rpc_doc_blob: 211bfb81c742d3a6293a0736e6c2d8d6874da77f
last_reviewed_pi: 1.6.0
last_reviewed_pi_commit: faac585884ae2c013a6b1400f3e9e77f10b34bac
last_reviewed_rpc_doc_blob: 211bfb81c742d3a6293a0736e6c2d8d6874da77f
---

# Pi compatibility record

This is the durable record of Pi versions tested with PiChat and upstream RPC
changes already reviewed. `last_verified_pi` advances only after the complete
real-Pi suite passes against that exact version. `last_reviewed_pi` may advance
when every intervening RPC documentation change has a disposition below, even
if verification remains blocked by a known failure.

The upstream contract history includes
[`rpc.md`](https://github.com/earendil-works/pi/commits/main/packages/coding-agent/docs/rpc.md),
[`rpc-commands.md`](https://github.com/earendil-works/pi/commits/main/packages/coding-agent/docs/rpc-commands.md),
[`json.md`](https://github.com/earendil-works/pi/commits/main/packages/coding-agent/docs/json.md),
[`session-format.md`](https://github.com/earendil-works/pi/commits/main/packages/coding-agent/docs/session-format.md), and
[`compaction.md`](https://github.com/earendil-works/pi/commits/main/packages/coding-agent/docs/compaction.md).
Store immutable Pi release commit and `rpc.md` blob IDs with each watermark;
a version alone cannot distinguish a moved tag or an unchanged RPC document.

## Current status

- Pi 1.6.0 is the latest release with both complete-suite verification and a
  reviewed RPC/session-format/compaction contract. The dependency-enabled full
  suite passed with 1723 expected results, zero unexpected results, and only
  two explicitly opted-in Docker skips (1725 total). No production changes
  were required.
- The persisted-session fixture baseline is Pi 0.80.6; this is fixture provenance,
  not proof that the current complete suite passed on that release.
- RPC overview, command, and event documentation changes through Pi 1.6.0
  have been reviewed. The expanded session-format/compaction audit includes the
  0.87.0 canonical-context baseline and every intervening documentation commit;
  its historical backfill is complete. Linked message types and relevant RPC,
  session-manager, tool-schema, and shutdown implementation diffs were also
  inspected. RPC command/response types and the JSON event adapter are unchanged
  between 1.3.0 and 1.6.0.
- Upgrade verification uses the isolated offline fake provider and installed
  optional Emacs dependencies. Separate real-SSH, live-UI, Docker, and real
  provider/OAuth checks were not run for 1.6.0.
- Earlier failed verification attempts remain in the history independently of
  later successful runs.

## RPC change ledger

Every upstream RPC, session-format, or compaction contract change between two reviewed versions must appear
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
| [`a79b37334`](https://github.com/earendil-works/pi/commit/a79b3733421ead0dcea3cbe32247ea2464400dcb) `clear_queue` | 0.84.4 | implemented | Abort clears Pi's queue first and prepends returned steering/follow-up text to the current editor. RPC, fallback, lifecycle, and real-Pi coverage is in `pichat-test-rpc.el`, `pichat-test-lifecycle.el`, and `pichat-test-integration.el`. |
| [`bea67d90d`](https://github.com/earendil-works/pi/commit/bea67d90d1a74dde8852c63cac72d476013d3879) abort cancels compaction/branch summary and waits for idle | 0.85.0 | compatible-no-change | PiChat retains event-based settlement; `pichat-test-lifecycle.el` covers aborted compaction and the real-Pi abort tests wait for `agent_settled`. |
| [`9e05370b`](https://github.com/earendil-works/pi/commit/9e05370b298d0a6b8d9bc2c02e4bfae189ef1616) transcript-carried system prompt and tool declarations | 0.86.0 | implemented | The bridge mutates per-turn structured tool selection, and the fake provider replays `toolsAdded`/`toolsRemoved` while retaining the legacy top-level tool fallback. Bridge schema and deactivation integration tests cover both transitions. |
| [`faa9863c`](https://github.com/earendil-works/pi/commit/faa9863cb8b54689f1d0c2df9dbab1ee1fa9de19) RPC queued messages pass through input handlers | 0.86.0 | compatible-no-change | PiChat uses ordinary `steer` and `follow_up` RPC commands; the real-Pi queue-mode integration test covers their delivery and settlement. |
| [`466db0fec`](https://github.com/earendil-works/pi/commit/466db0fecdc20996a553116984d18c0d362b035a) canonical context boundaries and `ContextEditEntry` | 0.87.0 | implemented | Historical session-format/compaction baseline reviewed: edits and retain-none compaction affect Pi's future model context, not raw history. `pichat/pichat-pi.el` retains edits without rendering or diagnosing them; Session History exposes a safe summary under `all` only. Covered by `pichat-test-transcript.el`, `pichat-test-sessions-visibility.el`, and real-Pi overflow/compaction integration tests. |
| [`25cc5c7bf`](https://github.com/earendil-works/pi/commit/25cc5c7bf4cbc76b2e134c729eb8d57d521ed749) RPC documentation refresh and reference split | 0.87.1 | compatible-no-change | The command, response, and event wire types and RPC implementation are unchanged from 0.86.1. PiChat already uses LF-delimited JSON records, correlates responses by ID, treats prompt success as acceptance rather than completion, and waits for `agent_settled`; the complete 0.87.1 suite exercises these contracts. Historical backfill also reviewed the extracted message/SDK references, ISO entry timestamps, nullable parents, summary formats, and Pi-owned file tracking; PiChat does not parse summary headings or generate compaction context. |
| [`e473b5cd`](https://github.com/earendil-works/pi/commit/e473b5cd8b6f2e82f1295aeee81cb697ffde2ed5) prompt, steer, and follow-up response dispositions | 0.99.0 | implemented | `pichat/pichat-chat-input.el` restores a prompt consumed by an input handler without waiting for a settlement, while retaining the older extension-command fallback. `pichat-test-chat-input.el` and `pichat-test-integration.el` cover `started`, `queued`, and `handled` against real Pi, including handled steer/follow-up. |
| [`36a686ee`](https://github.com/earendil-works/pi/commit/36a686ee8dd73afe8242011db387040890e24093) tool execution `durationMs` | 1.1.0 | compatible-no-change | Additive tool-end field is ignored by PiChat's live reducer; the real-Pi nested-tool integration test checks that it is delivered and rendering still completes. |
| [`503c6055`](https://github.com/earendil-works/pi/commit/503c605528f9af993c0e37ede468cf884fb0ff5b) `agent_settled.aborted` | 1.1.0 | compatible-no-change | PiChat uses settlement as the idle/synchronization boundary regardless of the abort cause. The real-Pi abort integration test checks `aborted: true` and idle state. |
| [`540e174c7`](https://github.com/earendil-works/pi/commit/540e174c72cd793170b73db8160c6d5f6c5a2236) virtual-model session metadata (historical backfill) | 0.99.0 | compatible-no-change | Additive assistant `thinkingLevel` and `pi.virtual-model-state` custom entries do not change existing entry shapes. PiChat's generic entry cache/transcript handling preserves source records; routing remains Pi-owned. No dedicated virtual-router UI or real-router integration verification is claimed. |
| [`15e7bdc14`](https://github.com/earendil-works/pi/commit/15e7bdc14cae38786c4cde24870ffce888e062cd) omit thinking from summary requests (historical backfill) | 1.2.0 | compatible-no-change | Only Pi's model-context serialization changes; raw thinking and summary entry shapes remain intact. PiChat delegates summarization to Pi. Existing real-Pi compaction and transcript tests cover the client boundary. |
| [`6fcb48670`](https://github.com/earendil-works/pi/commit/6fcb48670fc0e6672a644f3b2691010321734426) remove fixed summary output limits | 1.4.0 | compatible-no-change | `reserveTokens` now controls only the compaction trigger; Pi sizes summary output. PiChat does not construct summary request budgets. Real-Pi manual/automatic compaction, context-usage, and failure/recovery tests pass without client changes. |
| [`14c811841`](https://github.com/earendil-works/pi/commit/14c8118412bffc8f8df7a088fde51d2ffa74fd8f) provider-reported `responseModel` (linked message-types audit) | 1.5.0 | compatible-no-change | The optional field can now equal the requested model; existing assistant entry shapes are unchanged. PiChat does not infer source identity from this field. No dedicated physical-model display is added. |
| [`6536f8012`](https://github.com/earendil-works/pi/commit/6536f80129a266c3619c044f8487c0279fc39cd9) JSON Schema tool validation via pi-schema (implementation audit) | 1.5.0 | compatible-no-change | Reviewed tool types and extension loader: arbitrary JSON Schema objects are accepted and extension TypeBox compatibility remains. PiChat's bridge still imports `typebox` directly; real-Pi bridge schema, tool execution, and approval tests exercise the existing fixture and bridge against 1.6.0. |
| [`7c22a93d0`](https://github.com/earendil-works/pi/commit/7c22a93d0ed02092142fa63823e63d76aa4e2406), [`cae8d69e5`](https://github.com/earendil-works/pi/commit/cae8d69e572e038d584c881efd1818e40571fb7c) provider-reported cost totals (implementation audit) | 1.5.0 | compatible-no-change | Additive `cost.totalFromProvider`; `cost.total` may be billed cost rather than the sum of catalog component estimates. PiChat delegates session accounting to Pi and does not reconstruct billed cost from those components. Real provider billing is outside the offline suite. |
| [`1708b4788`](https://github.com/earendil-works/pi/commit/1708b47889664ec9838f6734ff57df58b079a50a) idle extension shutdown | 1.5.1 | compatible-no-change | `pichat-integration-extension-shutdown-flushes-response-and-exits-idle` checks both command-requested shutdown with a successful prompt response and shutdown after an already completed command's dialog, without a client stop or extra RPC poke. Existing discovery shutdown workaround is retained for older Pi. |
| [`ace560c30`](https://github.com/earendil-works/pi/commit/ace560c302068be9fe84b18ad6d460fa55c58a14) orderly shutdown survives EOF plus one signal | 1.5.1 | compatible-no-change | Reviewed `rpc-mode.ts`: EOF/SIGTERM/SIGHUP start one disposal; repeated signals can force exit. PiChat's bounded process-lifetime/reconfiguration barriers still require observed exit rather than assuming a signal completed shutdown. Covered by existing lifecycle tests; the exact EOF/signal interleaving is source-reviewed, not newly fault-injected. |
| [`b2cb62923`](https://github.com/earendil-works/pi/commit/b2cb629237496524e745ff668ec5bd5d47130164) await credential writes during disposal | 1.5.1 | compatible-no-change | Reviewed `AgentSessionRuntime.dispose()` and credential-settlement changes. No RPC schema changes. PiChat retains bounded shutdown/escalation; the isolated offline suite does not verify real OAuth refresh durability or guarantee preservation after forced termination. |
| [`ede360e4d`](https://github.com/earendil-works/pi/commit/ede360e4d6548531c008dfd508d7e37f9bd47529) skip answerless turns in `get_last_assistant_text` | 1.6.0 | not-applicable | PiChat does not issue this command; its RPC inspection classification is not a call site. Response views, Jobs response copying, and Markdown export read canonical or captured transcript data instead. |
| [`beffcde92`](https://github.com/earendil-works/pi/commit/beffcde92dea5253fecefc052320e8c8e97082fb) deliver startup entries and bind once on replacement (implementation audit) | 1.6.0 | compatible-no-change | `pichat-integration-source-start-entries-arrive-once` checks one streamed startup marker at launch and after switch, fork, clone, and new session, with matching authoritative `get_entries` records. Existing chat/source-rebinding tests check transcript synchronization. |
| [`c47ad0432`](https://github.com/earendil-works/pi/commit/c47ad0432bb8877e8f46afdc3f197cf5595b8a77) replacement diagnostics on stderr (implementation audit) | 1.6.0 | compatible-no-change | `pichat-integration-source-replacement-warnings-stay-on-stderr` checks successful replacement, warning capture/deduplication, and clean RPC stdout. PiChat retains stderr separately; proactive successful-switch warning presentation is not implemented by this compatibility update. |

Do not delete rows after implementation. Change their disposition and add the
implementation and test locations so later upgrades do not rediscover the same
feature.

## Observed Pi behavior relied on

Behavior checked in a shipped release rather than documented upstream. Recheck
it when upgrading.

- **RPC `ui.editor` ignores dialog options (Pi 1.5.1; rechecked on 1.6.0).** In RPC mode,
  `select`, `confirm` and `input` resolve with their default value when
  `opts.signal` aborts, but `editor(title, prefill)` takes no options and waits
  for an `extension_ui_response` indefinitely. Pi sends the client no notice
  when an extension stops waiting, and ignores a late response for an unknown
  ID. The bridge (`untilAborted` in `bridge/pichat-bridge.ts`) therefore stops
  waiting on the tool's abort signal itself, and the chat withdraws pending
  bridge tool calls when the agent run settles. Covered by
  `pichat-integration-bridge-abort-withdraws-pending-tool-approval`: without
  the bridge change an aborted run never settles and the `abort` RPC never
  responds. If a later Pi honours `signal` for `editor`, the race is redundant
  but harmless.

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
| 2026-09-22 | 0.86.1 | [`13cbf77d`](https://github.com/earendil-works/pi/commit/13cbf77df2396303013a41646bcfa77b4271ae56) | `pichat/test/run-tests.sh --full` (initial upgrade run) | **Failed:** 674 expected, 2 failed, 3 optional-dependency skips. The fake provider still expected pre-0.86 top-level provider tools, causing both bridge tool tests to fail. |
| 2026-09-22 | 0.86.1 | [`13cbf77d`](https://github.com/earendil-works/pi/commit/13cbf77df2396303013a41646bcfa77b4271ae56) | `pichat/test/run-tests.sh --full` | **Passed:** 679 passed, 0 unexpected, 3 optional-dependency skips (two Consult/Embark tests and one Orderless test). |
| 2026-09-22 | 0.87.1 | [`f07218c4`](https://github.com/earendil-works/pi/commit/f07218c4d4bbc12bef056a7058c3dd49dfe41abe) | `pichat/test/run-tests.sh --full` (initial upgrade run) | **Failed:** 678 expected, 1 failed, 3 optional-dependency skips. Pi 0.87 image normalization rejected the integration test's text placeholder masquerading as PNG. |
| 2026-09-22 | 0.87.1 | [`f07218c4`](https://github.com/earendil-works/pi/commit/f07218c4d4bbc12bef056a7058c3dd49dfe41abe) | `pichat/test/run-tests.sh --full` | **Passed:** 679 passed, 0 unexpected, 3 optional-dependency skips (two Consult/Embark tests and one Orderless test). The image integration test now supplies a valid PNG fixture. |
| 2026-10-17 | 1.3.0 | [`71023aec`](https://github.com/earendil-works/pi/commit/71023aec1546d6d677a65669c5665c0927ce0dd0) | `pichat/test/run-tests.sh --full` | **Passed:** 671 passed, 0 unexpected, 4 optional-dependency skips (two Consult/Embark tests, one Evil test, one Orderless test). Prompt disposition, handled input, abort, and tool-duration coverage included. |
| 2026-10-24 | 1.4.0 | [`4a080252`](https://github.com/earendil-works/pi/commit/4a080252f06caf63a525d7873c5d94d3c23887e0) | `pichat/test/run-tests.sh --full` (test tool, Pi `--version`: 1.4.0) | **Passed:** 832 passed, 0 unexpected, 4 optional-dependency skips. Includes `context_edit` transcript and Session History unit regressions; the fake-provider integration suite does not generate a real context edit. Contract review and historical backfill still pending; watermarks unchanged. |
| 2026-10-30 | 1.4.0 | [`4a080252`](https://github.com/earendil-works/pi/commit/4a080252f06caf63a525d7873c5d94d3c23887e0) | `pichat/test/run-tests.sh --full` (SSH reconfiguration final acceptance) | **Passed:** 975 passed, 0 unexpected, 8 skips. Separate real-SSH suite 12/12 and graphical SSH reconfiguration UI 1/1 passed. Contract review/backfill still pending; watermarks unchanged. |
| 2026-10-30 | 1.4.0 | [`4a080252`](https://github.com/earendil-works/pi/commit/4a080252f06caf63a525d7873c5d94d3c23887e0) | `pichat/test/run-tests.sh --full --with-optional` (SSH reconfiguration final acceptance) | **Passed:** 981 passed, 0 unexpected, only 2 explicitly opted-in Docker tests skipped. Contract review/backfill still pending; watermarks unchanged. |
| 2026-11-22 | 1.6.0 | [`faac5858`](https://github.com/earendil-works/pi/commit/faac585884ae2c013a6b1400f3e9e77f10b34bac) | `pichat/test/run-tests.sh --full --with-optional` (initial upgrade baseline, before adding three contract regressions; pinned 1.6.0 binary directory on PATH) | **Passed:** 1720 passed, 0 unexpected, only 2 opted-in Docker tests skipped (1722 total). |
| 2026-11-22 | 1.6.0 | [`faac5858`](https://github.com/earendil-works/pi/commit/faac585884ae2c013a6b1400f3e9e77f10b34bac) | `pichat/test/run-tests.sh --full --with-optional` (final upgrade verification; pinned 1.6.0 binary directory on PATH) | **Passed:** 1723 passed, 0 unexpected, only 2 opted-in Docker tests skipped (1725 total; 257.94 seconds). Includes new startup-entry/rebinding, stderr-warning, and extension-shutdown regressions. RPC review and session-format/compaction historical backfill completed; both watermarks advanced to 1.6.0. |

A failed attempt is retained because it records what was actually tested, but it
must never update the `last_verified_*` fields.

## Upgrade workflow

1. Run `pichat/test/report-upstream-rpc-changes.sh [OLD_REF] [NEW_REF]`.
   With no refs, it compares `last_reviewed_pi` to the installed `pi --version`.
   The report scans `rpc.md`, `rpc-commands.md`, `json.md`,
   `session-format.md`, and `compaction.md`; the watermark blob records
   `rpc.md` only. The session-format/compaction backfill from the 0.87.0
   baseline through 1.6.0 is recorded above. If extending the scanned paths,
   backfill their earlier changes too. Review relevant implementation changes.
2. Review each reported upstream commit and add it to the RPC change ledger with
   a disposition. Inspect the corresponding implementation diff when the docs
   are ambiguous.
3. Implement or explicitly defer pending changes and add focused tests.
4. Run `pichat/test/run-tests.sh --full` using the exact target Pi release.
5. Record every attempt in the verification history. Only on a complete pass,
   update `last_verified_pi`, its release commit, and its RPC document blob.
6. Once every intervening RPC change has a ledger row, update the three
   `last_reviewed_*` fields.

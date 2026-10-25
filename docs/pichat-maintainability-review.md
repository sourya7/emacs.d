# PiChat maintainability review

## Review record

- **Passes:** 1 — inventory/reachability/test baseline; 2 — simplification/extensibility review and probes; **3 — evidence revalidation, full-suite execution, isolated loads, and targeted draft/target lifecycle review**.
- **Reading guide:** sections 1–10 retain the first-pass findings; sections 11–15 contain the second-pass analysis with explicit third-pass corrections. **Section 16 is the current verification ledger; section 17 records the targeted lifecycle pass.** This is an evolving review, not an exhaustive audit.
- **Baseline commits:** passes 1–2 used `14cd767`. Pass 3 used `9107cea`, which only added this document under `docs/`; package/config/test sources are unchanged. Working tree was clean at the start of each review.
- **Environment:** GNU Emacs 31.1; pass 3's real-Pi tests used installed Pi **1.4.0**.
- **Changes made:** this review plus review scripts/logs under `.tmp/`. No package implementation or tracked test changes. The tracked `docs/` document supersedes the historical `.tmp/pichat-maintainability-review.md` copy.
- **Terminology:** [PiChat glossary](../pichat/GLOSSARY.md) is authoritative. A **runtime** is not a **Pi session** or a **saved session file**. **Session History** means entries/branches inside the current Pi session, not saved-session browsing.
- **Status:** recommendations, not approved implementation work. Finding IDs are stable so subsequent passes can amend or reject them.
- **Execution backlog:** `../.plans/pichat-maintainability/plan.org` is the single authoritative work-package checklist; the former `docs/pichat-maintainability-plan.org` was moved there without starting implementation.

### Executive assessment

PiChat already makes substantial use of native Emacs facilities. Its maintenance problem is not simply “too much custom UI.” It is a combination of large orchestration modules, remnants of earlier extraction work, multiple command-discovery surfaces, and safety-sensitive state ownership spread across features.

**Second-pass refinement:** the highest-leverage goal is fewer independent owners and fewer private-state dependencies, not fewer files or commands. Prioritize a public draft/target boundary, validated action context, honest extension contracts, and thin adapters to Emacs's existing navigation/completion facilities. Dead-code cleanup remains useful groundwork, not the architecture strategy. See §15 for the revised order.

The first-pass improvement list was:

1. Remove genuinely unused private extraction leftovers, with tests retargeted where necessary.
2. Decide which compatibility APIs and speculative features are still supported.
3. Share command discovery/validation between the slash-command picker and completion-at-point.
4. Add a small, context-aware **chat actions** Transient, separate from the launch/reconfigure menus.
5. Keep the runtime manager's existing `tabulated-list-mode`; use Ibuffer/Consult as complementary buffer navigation, not runtime lifecycle replacements.
6. Improve test relevance and optional-integration execution before pursuing blanket test deletion.
7. Extract cohesive orchestration domains only after pruning, preserving existing generation and rollback safeguards.

**Do not simplify away:** canonical transcript authority, source/process generation checks, runtime/file ownership, reconfiguration verification, prompt recovery, untrusted-HTML sanitization, or remote execution provenance.

## 1. Scope, method, and limitations

Read `README.md`, `GLOSSARY.md`, and `TESTING_GUIDELINES.md` completely. Inventoried all top-level package Lisp files and test Lisp files; searched definitions, references, suite registration, compatibility aliases, and command bindings. Inspected selected implementation and test bodies for the findings below, plus repository integration in `user/pichat.el`. Compared PiChat's custom async Consult stage with the installed Consult source under `.local/elpaca/sources/consult/consult.el`.

This is **not** a line-by-line audit of all code. Pass 2 additionally read the TypeScript bridge and traced its Emacs execution path, inspected restart ownership/commit paths and display rollback, checked native Emacs integration contracts, and rechecked selected dead-code candidates over tracked repository files. Pass 3 revalidated those claims, ran the complete local suite with real Pi, checked all 51 module loads in fresh Emacs processes, and added bounded lifecycle observations and two in-memory mutation checks. Coverage instrumentation was attempted but failed; it supplies no usable coverage metric. The full restart transition matrix, remote failure matrix, and every test assertion still require deeper passes. No live GUI session or SSH execution was performed; see §16 for precise results and limits.

### Evidence classifications

- **Confirmed static:** directly supported by inspected bodies/reference searches; not necessarily a runtime bug.
- **Reproduced observation:** exercised at a named boundary, possibly with stubs or injected failures; not automatically an end-to-end user incident. Tests asserting an existing gap are observations, not regression tests for the desired fix.
- **Strong candidate:** no in-repository production caller, but external Lisp callers, autoloads, or dynamic invocation may exist.
- **Design proposal:** a potential simplification requiring a prototype/behavioral comparison.
- **Keep:** superficially duplicate or custom behavior that currently has a substantive reason to exist.

Reference screening counted exact symbol tokens across package Lisp, tests, repository `core/` and `user/`, and package documentation/fixtures. Counts are not a Lisp call graph. Interactive commands, generated struct accessors, macros, hooks, aliases, and external configuration must be assessed separately. “Only tests call this” does not alone prove that a public API is dead.

Line numbers below refer to the reviewed baseline; use the accompanying symbol names after edits.

## 2. Functionality and ownership inventory

The package contains **51 production Lisp files / 24,054 lines** and **57 test/support Lisp files / 24,444 lines**. Counts include comments and blank lines, and exclude TypeScript/shell fixtures.

| Functional area | Main ownership | Maintainability assessment |
|---|---|---|
| Runtime registry, scope, preferred-runtime selection, launch profiles | `pichat.el`, `pichat-session.el` | Core domain logic; currently shares a large file with model discovery and Transient presentation. |
| Backend dispatch | `pichat-backend.el`, `pichat-backend-pi.el` | Thin boundary worth retaining; only Pi ships, so avoid speculative expansion. |
| Local/SSH process lifecycle, JSONL RPC, request cancellation | `pichat-rpc.el`, `pichat-transport.el`, `pichat-events.el`, `pichat-pi-environment.el` | Necessary protocol/transport responsibilities. Not replaceable by ordinary buffer management. |
| Presets, MCP discovery, run-local Tools | `pichat-presets.el`, `pichat-tool-selection.el`, `pichat-mcp-discovery.el`, `pichat-tool-picker.el` | Already uses Transient. Preserve startup-only semantics and explicit-tool policy. |
| Guarded restart/recovery | `pichat-reconfigure.el`, menus in `pichat.el` | High-complexity, safety-critical domain. Needs separate transition review rather than generic cleanup. |
| Canonical transcript/live tail | `pichat-transcript.el`, `pichat-pi.el`, `pichat-render.el`, `pichat-chat.el` | Pure model/reducer boundaries are useful; chat projection orchestration remains large. |
| Thinking/activity/tool presentation | `pichat-activity-presentation.el`, `pichat-chat-activity-ui.el`, `pichat-chat-tool-ui.el`, enrichment/shell modules | Good extraction direction, with unused old chat wrappers still present. |
| Prompt, queued input, recovery, images | `pichat-chat-input.el`, `pichat-attachments.el`, chat integration | Distinct from ordinary text insertion; do not replace recovery with a plain history ring. |
| Slash commands/templates/skills | `pichat-commands.el`, `pichat-chat-completion.el` | Overlapping discovery with materially different freshness handling. |
| Navigation, compose, Markdown export | `pichat-chat-navigation.el`, chat command wrappers | Reasonable native editor integration; compose/source ownership remains necessary. |
| Rendered response snapshots | `pichat-response-view.el`, `pichat-markdown-fontification.el` | Already uses Markdown/SHR. Sanitization and exact-source fallback are not redundant rendering code. |
| Settled artifacts and execution | artifact parser, Embark adapter, subprocess/Elisp runners, common result view | Shared result handoff is a good boundary. Execution is separate from Pi tool permissions. |
| Runtime manager | `pichat-session-manager.el` | Already native `tabulated-list-mode`; owns retained-runtime actions and source-scoped previews. |
| Session History and source navigation | `pichat-sessions.el` | Overloaded: tree normalization/UI, file browsing, loading, branch preview, fork/clone navigation, permission-file utilities. |
| Saved-session search | `pichat-archive.el`, `pichat-consult.el`, basic picker in `pichat-sessions.el` | Optional Consult integration already exists; archive protocol and fallback picker solve different problems. |
| Diagnostics/setup | `pichat-diagnostic.el`, `pichat-chat-diagnostics.el`, collectors | Cached safe inspector and explicit raw inspector should stay distinct. |
| Emacs tools/approval/bridge | tools, approval, permissions, bridge transport modules, TypeScript bridge | Some apparently unused API surface; end-to-end capability audit still needed. |
| References | `pichat-reference.el` | Already integrates file locations, Dired, compilation, and native temporary files. |
| View lifecycle/Evil/config integration | `pichat-view.el`, `pichat-evil.el`, `user/pichat.el` | Native defaults with optional adapters; avoid multiplying parallel action menus. |
| VUI entry points | `pichat-vui.el` | No VUI implementation: four forwarding commands. Strong retirement candidate. |

### Size hotspots

| Production file | Lines | Recommended treatment |
|---|---:|---|
| `pichat-chat.el` | 4,507 | Prune stale wrappers; then consider projection and extension-UI orchestration as separate domains. |
| `pichat-sessions.el` | 2,851 | Separate saved-file browsing/loading from Session History model/UI. |
| `pichat.el` | 1,678 | Separate launch/reconfigure menu presentation from lifecycle/registry logic. |
| `pichat-consult.el` | 1,364 | Keep archive-query, candidate identity, preview, and navigation responsibilities explicit. |
| `pichat-archive.el` | 964 | Protocol/provenance boundary; review process mechanics separately from normalization. |
| `pichat-session-manager.el` | 916 | Size is partly preview lifecycle, not a hand-built table framework. |
| `pichat-rpc.el` / `pichat-reconfigure.el` | 901 each | Safety-critical; refactor only with transition tests. |

The three largest production files account for 9,036 lines, approximately **38%** of production Lisp. Splitting files alone will not reduce conceptual complexity: each extraction needs a clear owner and explicit inputs, not just relocated buffer-local variables.

## 3. Code duplication

### DUP-01 — Command discovery has two implementations with different freshness guarantees

**Priority: high. Evidence: confirmed overlap; pass 3 reproduced a source-change gap during argument collection.**

- `pichat/pichat-commands.el:14–47`: `pichat-command-run` fetches `get_commands`, schedules a picker, and submits directly through the backend. The picker checks runtime liveness.
- `pichat/pichat-chat-completion.el:41–133`: completion has source-generation/source-key/request-sequence tracking, validated command records, explicit loading/failure state, and stale-callback rejection.

Both expose commands/templates/skills, but command picker work can outlive its original source context. Its liveness checks do not themselves establish that the runtime still hosts the same Pi session. Pass 3 changed the runtime's Pi session ID during the stubbed argument prompt and observed submission to the rebound source through a stubbed backend. This reproduces the command-boundary gap after discovery, without claiming that every late RPC callback bypasses transport guards. No actual prompt was submitted by that probe.

**Recommendation:** one command-catalog service, with CAPF and picker as consumers. Keep their UX distinct: CAPF edits a draft; the picker currently executes. Capture and validate origin/source identity before delayed prompting and before submission. Explicitly decide whether picker execution should continue to submit immediately or insert into the draft; do not change that behavior as an incidental refactor.

**Validation:** delayed response followed by source rebinding; source changes while reading arguments; failure/malformed command list; cancellation; current CAPF behavior; picker execution versus draft insertion.

**W02 resolution (2026-10-25): freshness gap resolved; catalog duplication remains for W14.** The picker captures process identity/generation, Pi session ID and saved-file path before discovery, plus associated chat ownership/source generation when present. It revalidates the response runtime and captured context before scheduling, before the deferred picker, after command selection, and after argument entry immediately before submission. Stale work reports cancellation without backend submission or draft changes. Tests exercise each boundary, same-ID generation changes, chat death/ownership changes and runtime stop/replacement-generation changes, with a valid unchanged-source control. The existing cancellation test now uses a live inert process and proves both prompts were reached. Picker execution remains immediate; CAPF remains draft-only. Unit/full suites and focused command/CAPF tests pass. Re-entrancy is fixture-driven, not a claim of manual GUI or live SSH verification; command normalization/error handling and shared catalog work are not changed here.

### DUP-02 — Marker-table navigation repeats small algorithms

**Priority: low/medium. Evidence: confirmed similar code.**

- `pichat-chat-tool-ui.el:467–501`: block-at, next-position, previous-position.
- `pichat-chat-activity-ui.el:268–303`: analogous activity-header operations.

Next/previous scans are almost the same. Tool block selection explicitly chooses the innermost matching block; activity selection does not. Activity navigation tolerates detached start markers while the tool scan directly compares the returned position.

**Recommendation:** if these paths need maintenance, extract a narrowly scoped marker-position traversal helper with defined detached-marker handling. Keep containment policy at each caller. Do not build a generic UI framework to save a few loops.

**Validation:** detached markers, no match, nested blocks, equal positions, folded/hidden children, and boundaries. Preserve semantic differences rather than mechanically merging functions.

### DUP-03 — Extraction left forwarding wrappers in chat

**Priority: high for pruning, low risk after reference validation.**

`pichat-chat.el:3494–3555` contains several adapters to `pichat-chat-tool-ui-*`. Some no longer have callers; others are only exercised by tests. This is redundant surface rather than duplicated algorithms. See DEAD-01 and TEST-02.

**Recommendation:** delete unused private wrappers rather than adding another abstraction. Retain wrappers that actually assemble chat-owned context or enforce edit/view transactions for production callers.

### DUP-04 — Source tokens look alike but are not interchangeable

**Priority: medium audit. Evidence: confirmed variation; keep semantics.**

- `pichat-session-manager.el:243`: runtime ID + Pi session ID + saved file.
- `pichat-sessions.el:1049`: Pi session ID + saved file, with other request-owner checks elsewhere.
- `pichat-chat.el:4392`: chat source token used by response/compose/artifact workflows.
- `pichat-artifact-result.el:22`: obtains the chat token rather than inventing another one.
- RPC process-generation checks additionally exist in `pichat-rpc.el`.

**Recommendation:** first write an ownership/invalidation matrix for each async consumer. Only then introduce shared token constructors/predicates where the required identity really is identical. A source token alone is not a process-lifetime token, and an immutable preview has different allowed operations from a live request.

**Do not:** replace all tokens with a saved-file string or collapse source and process generations. Such “deduplication” can enable stale callbacks after restarts.

### DUP-05 — Consult async process mechanics partly mirror Consult

**Priority: medium investigation, not an immediate rewrite.**

`pichat-consult.el:134–275` repeats process cancellation, chunk-to-line framing, flush, indicator, and sentinel mechanics found in installed `consult.el:2489` (`consult--async-process`). But PiChat adds transport-qualified process creation, output/time limits, helper-error classification, and archive-capability invalidation.

**Recommendation:** preserve the custom stage unless a small adapter can retain all of those guarantees. Prefer sharing PiChat-owned bounded process mechanics with archive discovery/query execution, if their lifetimes align, over globally advising Consult internals.

`pichat-consult.el:461` also contains a fallback implementation of Consult's invisible identity encoding. Determine whether this is required for a supported Consult version or principally for dependency-free tests. A documented minimum version and small adapter may be cheaper than maintaining a private-protocol fallback.

**Acceptance gate:** compare cancellation, final unterminated line, stale process events, remote invocation, output overflow, timeout, and capability invalidation. Generic Consult streaming is not automatically an equivalent replacement.

### DUP-06 — Key/action descriptions are repeated across integration layers

**Priority: medium. Evidence: confirmed multiple maintained surfaces.**

Commands appear in native maps, `pichat-evil.el`, `user/pichat.el` General/which-key menus, README key lists, and keymap tests. Some repetition is intentional: Evil should preserve Vim motions and package core should not depend on General.

**Recommendation:** keep native and Evil bindings explicit. Route discovery of infrequent actions through shared package Transient prefixes instead of maintaining another long personal menu for each view. Avoid a generated mega-registry unless drift remains a recurring problem.

### Existing sharing worth preserving

- `pichat-artifact-result.el` already shares copy/share/source-validation behavior between runner types.
- `pichat-view.el` already shares owned auxiliary-view lifecycle.
- `pichat-diagnostic.el` already shares diagnostic vocabulary without taking ownership from collectors.
- Basic saved-file completion and archive search intentionally differ in data availability; they are not duplicate backends to delete.
- Canonical and live rendering have different authority and rollback requirements. Similar-looking paths do not make one obsolete.

## 4. Dead code and obsolete surface

### DEAD-01 — Private helpers with no other exact-symbol reference

**Priority: high. Confidence: strong static removal candidates.**

The following symbols occurred only at their definitions in the scanned source/config/test/documentation corpus:

| File | Symbol / line | Assessment |
|---|---|---|
| `pichat-chat.el` | `pichat-chat--tool-explicit-view` :699 | Forwarder left after tool UI extraction. |
| `pichat-chat.el` | `pichat-chat--label` :1397 | Standalone label propertizer, no callers found. |
| `pichat-chat.el` | `pichat-chat--truncate-tool-output` :3494 | Unused forwarding wrapper. |
| `pichat-chat.el` | `pichat-chat--truncate-tool-args` :3500 | Unused forwarding wrapper. |
| `pichat-chat.el` | `pichat-chat--tool-text` :3504 | Unused forwarding wrapper. |
| `pichat-chat.el` | `pichat-chat--replace-tool-block-region` :3537 | Unused forwarding wrapper. |
| `pichat-chat.el` | `pichat-chat--collapse-tool-block` :3551 | Unused forwarding wrapper. |
| `pichat-sessions.el` | `pichat-sessions--short-id` :378 | Unused helper; other views have their own active short-ID helpers. |
| `pichat-chat-tool-ui.el` | `pichat-chat-tool-ui-merge-block-tables` :250 | No caller found; do not confuse with active activity merge helper. |

Deleting the collapse wrapper would leave `pichat-chat-tool-ui-collapse-block` without its sole known caller. Review this dependent removal in the same change.

**Caution:** tool-table merge mutates its first argument, while the active activity-table merge allocates a new table. Their similar names do not establish equivalent semantics.

**Validation before deletion:** search the full tracked repository and any supported external configuration, check dynamic symbol construction, then run the unit suite. These are private/internal helpers; no deprecation ceremony is normally needed unless external use is known.

### DEAD-02 — Production functions kept alive only by tests

**Priority: medium/high. Confidence: strong candidate, not blanket deletion.**

| Symbol(s) | Evidence | Recommended disposition |
|---|---|---|
| `pichat-chat--cycle-tool-state`, `pichat-chat--render-tool-block` | Tests in chat-core and modification-hooks; no production caller found. | Retarget tests to active tool UI commands/helpers, then remove wrappers. Preserve modification-hook coverage. |
| `pichat--session-for-scope` (`pichat.el:333`) | Scope tests call it; current launch paths use newer selection logic. | Move assertions to actual public launch/reuse behavior before removal. |
| `pichat-sessions--model-node-label`, `--model-node-label-timestamp`, `--model-node-tool-calls`, `--model-node-tool-call`, `--model-node-kind`, `--model-node-summary` (`:563–588`) | Accessor wrappers referenced only by Session History model tests. | Assert normalized model fields or active rendered behavior; remove needless private accessor surface if no contract exists. |
| `pichat-render-thinking-texts` (`:136`), `pichat-render-entry-text` (`:196`) | Chat-core tests call them; no production use found. | Audit old versus canonical renderer contracts. Retarget security/normalization assertions, not merely delete tests. |
| `pichat-tool-enrichment-infer-old-text-location` (`:149`) | Four direct test calls, no production consumer found. | Decide whether this is intentionally supported pure API or an abandoned feature. Remove implementation/tests together if abandoned. Do not introduce file reads just to make it used. |

Public names without `--` deserve an API decision even if not documented. Record supported API boundaries before a larger cleanup.

### DEAD-03 — VUI commands are placeholders, not an optional VUI frontend

**Priority: medium. Evidence: confirmed.**

`pichat-vui.el:18–39` forwards four commands to status, reference insertion, policy-file opening, and Session History. It does not use VUI. `pichat.el:34` nevertheless requires the module. The only test found exercises status delegation (`pichat-test-sessions-reference.el:452`).

**Recommendation:** retire the module and load-time dependency, or retain explicitly deprecated aliases for users who have bound the commands. The UI names promise a dashboard/context manager/tree implementation that does not exist. Do not build new VUI components merely to justify the placeholders.

### DEAD-04 — Unused public/tool extension APIs need a policy decision

**Priority: medium. Evidence: no callers found, not proven dead API.**

- `pichat-tool-selection-baseline` (`pichat-tool-selection.el:20`). Small unused baseline-copy convenience function.
- `pichat-tools-instructions` (`pichat-tools.el:77`). No consuming path found for collected tool instructions.
- `pichat-tools-call-async` (`pichat-tools.el:111`). No caller found. `pichat-tools-execute-json` uses synchronous `pichat-tools-call`, which rejects async tools.
- `pichat-rpc-get-messages` (`pichat-rpc.el:812`). Unused RPC wrapper; canonical synchronization uses entries.

The async tool API is more concerning than an unused RPC convenience wrapper: `pichat-define-tool` accepts `:async`, but the inspected bridge execution path rejects such tools. Also, the defining macro produces a one-argument function while the async dispatcher describes a two-argument callback convention. Manually constructed tool records may differ. ARCH-04 records the stronger pass-2 reproduction, reconfirmed in pass 3; the retirement/support decision remains open.

**Recommendation:** audit the full bridge contract, then either support async tools end-to-end or remove/deprecate the exposed async option. Treat this as a capability/API mismatch candidate, not a claim that every possible external caller is broken. Apply the same question to tool `:instructions`: is it intentionally metadata-only, or expected to affect prompts?

### DEAD-05 — Unbound interactive commands are not dead code

**Keep / reorganize.**

No ordinary production caller is expected for many useful `M-x` commands: clear attachments, discard recoverable submissions, choose thinking level, copy shell output, export transcript, probe Pi, validate mappings, and set the future default model. These belong in the command-surface review, not the deletion list.

Likewise `pichat-open-permissions-file` and `pichat-open-permission-log` (`pichat-sessions.el:2827–2848`) are public interactive commands, not dead helpers. Their placement in the Session History file is inappropriate. Move them to a permission/setup integration module if retained. Their use of `pichat-session-cwd` plus `expand-file-name` also merits a local/SSH path-ownership review before advertising them more widely.

Compatibility aliases such as compose-send, branch-preview names, diagnostic command aliases, and old artifact Elisp copy/share commands need an explicit retirement policy. Lack of in-repository calls is insufficient to remove user-facing aliases silently.

## 5. Dead, weak, or redundant tests

### Baseline execution

Ran:

```sh
pichat/test/run-tests.sh
```

Result: **759 selected; 755 passed; 0 unexpected; 4 skipped**. Captured output: `.tmp/pichat-maintainability-tests.log`.

Skipped:

- `pichat-consult-embark-relations-preserves-complete-candidate`
- `pichat-consult-embark-reruns-the-recorded-project-search-command`
- `pichat-evil-read-only-views-keep-vim-navigation-and-owned-quit`
- `pichat-session-completion-orderless-matches-identity-and-metadata-aliases`

These are guarded by optional dependency availability in the isolated `emacs -Q` runner. They are **not dead tests**. The default runner does not add the configured Elpaca dependency paths. Most Consult tests can still run through mocks, so a green minimal unit suite does not establish real Consult/Embark compatibility.

**Pass 2 update:** reran the same 759 tests with the installed source directories for Consult, Embark, Evil, Orderless, Compat, and goto-chg on `load-path`: **759 passed, 0 skipped, 0 unexpected**. No packages were installed. Log: `.tmp/pichat-maintainability-pass2-tests.log`. This closes the four skip gaps for this review environment, but does not replace a repeatable integration job or interactive UI testing.

Static scan found **830 literal `ert-deftest` forms** across test Lisp, with **no duplicate names**. Pass 3 reconciled this as **759 unit + 63 conditional real-Pi + 8 separate SSH tests**. The real-Pi definitions span `pichat-test-integration.el` (59) and `pichat-test-sessions-integration.el` (4). No `:expected-result` declarations or obvious `(should t)` placeholders were found by the targeted scan. The explicit `ert-skip` found in SSH testing concerns a host lacking Python; `skip-unless` also guards optional integrations.

### TEST-01 — Documentation wording test is low-value and brittle

**Priority: medium. Evidence: confirmed.**

`pichat-test-sessions-command-map.el:33`, `pichat-sessions-phase-twelve-command-documentation-is-current`, asserts phrases in docstrings, including “projected visible-model index” and “active leaf.” These assertions constrain editorial wording rather than actual navigation behavior. Its obsolete-property check has a separate compatibility purpose.

**Recommendation:** remove the phrase-matching assertions or move terminology lint to a separate documentation check. Keep a focused obsolete-alias/API check only if that compatibility guarantee remains supported. Behavioral tests immediately below already test active-chat jumping, hidden-entry handling, stale-history rejection, and return-to-chat behavior.

### TEST-02 — Test-only wrappers disguise unused production paths

**Priority: high.**

Examples:

- `pichat-test-chat-core.el:430`: cycle-state test targets an unused chat forwarding wrapper.
- `pichat-test-chat-modification-hooks.el:92`: calls the unused chat render wrapper, but its modification-hook invariant remains valuable.
- `pichat-test-sessions-tree.el:85–139`: private accessors exist only to provide test access to normalized model fields.
- `pichat-test-tool-enrichment.el:105–117`: tests a location-inference feature without an active consumer.

**Recommendation:** distinguish dead test *target* from useless test *intent*. Move assertions to the production path, keep the invariant, then remove obsolete seams. A test passing through an unused wrapper contributes little confidence about the active UI.

### TEST-03 — VUI forwarding test can retire with the facade

`pichat-vui-status-command-falls-back-without-vui-dependency` checks that a stub was called. It is valid while that public command is supported, but has little value after retiring the facade. Remove it together with the API, or retain a minimal alias-compatibility test during deprecation. Do not preserve the facade merely to keep the test green.

### TEST-04 — Keep security and lifecycle assertions even when helpers disappear

`pichat-test-chat-core.el:441`, `pichat-render-unknown-data-never-uses-raw-printer-fallback`, partly exercises an otherwise unused renderer. Its underlying privacy invariant is important. Retarget it to the active canonical/live normalization and rendering paths and retain malformed/circular-data coverage where applicable.

Also keep tests for read-only transcript enforcement, rejected-submission recovery, stale callback rejection, restart snapshots, rollback, exact artifact extraction, unsafe HTML/resource rejection, spill-file privacy, and independent-open cleanup. These may look verbose because failure paths are genuinely different.

### TEST-05 — Formatting tests require case-by-case judgment

Do not classify every exact string or keymap assertion as useless. User-visible distinctions such as **open independently versus switch**, **new Pi session versus new runtime**, and **same saved source versus new empty Pi session ID on restart** are safety-relevant. Concise restart/confirmation tests in `pichat-test-launch.el:708–848` protect more than cosmetic wording.

Prefer structured facts and bounded text assertions over whole-buffer snapshots. Parameterize repeated cases only when setup and expected invariant are genuinely shared; preserve clear failure labels.

### TEST-06 — Test organization and execution gaps

Largest focused suites, following the repository's requested size review:

| Test file | Lines |
|---|---:|
| `pichat-test-integration.el` | 2,342 |
| `pichat-test-consult.el` | 1,212 |
| `pichat-test-artifacts.el` | 1,195 |
| `pichat-test-lifecycle.el` | 1,010 |
| `pichat-test-launch.el` | 889 |
| `pichat-test-chat-view.el` | 857 |
| `pichat-test-rpc.el` | 851 |
| `pichat-test-session-manager.el` | 813 |
| `pichat-test-chat-projection.el` | 793 |

These are organization signals, not failure gates. Restart coverage is distributed among lifecycle, launch, and real-Pi integration suites; consider a cohesive reconfiguration suite without making test suites require one another for fixtures.

**Recommended matrix:**

1. Minimal dependency-free unit run, retained as now.
2. Optional-integration run with explicit load paths for actual supported Consult, Embark, Evil, and Orderless; require those tests not to skip in that job.
3. Real-Pi fake-provider `--full` run before protocol/lifecycle changes.
4. Opt-in isolated SSH run before transport-sensitive changes.
5. Coverage analysis as triage, followed by targeted mutation/fault injection for high-risk state transitions.

No packages were installed. Pass 3 ran the dependency-enabled full suite successfully and attempted coverage, which failed during instrumentation/reporting (§16). Test deletion should be justified by replaced/retired behavior, not by line counts or lack of recent failures.

## 6. Native Emacs / Consult simplification opportunities

Consult and Embark are external packages, not built-in Emacs. Keep optional integrations optional unless deliberately changing the package dependency contract.

| Area | Existing implementation | Best fit | Decision |
|---|---|---|---|
| Open chat buffer switching | Ordinary Emacs buffers + runtime manager | `consult-buffer`, Ibuffer filters/groups | Add/configure navigation, do not replace runtime registry. |
| Retained-runtime lifecycle | `tabulated-list-mode` manager | Existing native table | Keep. Ibuffer has buffer identity, not immutable runtime identity. |
| Saved-session search | Archive-backed Consult + basic completion fallback | Existing Consult pipeline | Already appropriate; simplify adapter internals selectively. |
| Session History | Branch model, folding, filters, jump/fork/preview | Keep tree UI; optional completion-based jump | Consult can complement selection, not own the branch model. |
| Visible transcript search | Text buffer with canonical/live regions | Isearch/Occur/`consult-line` | Reuse for textual navigation; never infer canonical semantics from displayed text. |
| Tool/group navigation | Marker tables and text properties | Shared marker traversal; potentially buttons | Small extraction opportunity, not a mode rewrite. |
| Compose editor | Dedicated editing buffer with source validation | Existing native editing | Keep source-target checks; optional edit-mode customization is simpler than new UI. |
| Prompt history | Custom submitted/recoverable state | Native completion for selecting history | Separate selecting old text from recovery of failed submissions/images. |
| Read-only auxiliary views | `special-mode` parent, `pop-to-buffer`, `quit-window` | Existing shared lifecycle | Already native; retain ownership guard. |
| Tool locations | Explicit visit/copy commands | `button.el`, `next-error-function`, Embark | Prototype if reducing bespoke mouse/key plumbing; preserve host path mapping. |
| Shell diagnostics | Optional compilation rerun | `compilation-mode` for supported local paths | Useful narrowly, not a remote/container-equivalent runner. |
| Rendered responses | Markdown conversion + sanitized SHR | Existing native renderer | Keep security boundary. Do not replace with unrestricted HTML browsing. |
| Artifact actions | Embark/Avy | Existing context actions | Better here than in a global Transient. |
| Tool selection | Paginated Transient + async discovery | Existing menu; possibly searchable multi-select | Benchmark large catalogs before introducing a second picker. |
| Settings and policy files | Direct `find-file` helpers | Native file editing / Customize | Put discovery in a setup menu, not bespoke editors. |

### NATIVE-01 — Ibuffer is a complement, not a manager replacement

`pichat-session-manager.el:854` derives from `tabulated-list-mode`. It already gets native columns, sorting, and a revert hook. Manager rows include stopped/failed runtimes, and a runtime need not have a currently useful chat buffer. Ibuffer would require fake buffers or a second registry model to represent those states.

A simple Ibuffer group for `pichat-chat-mode` and `pichat-view-mode`, plus existing `consult-buffer` filtering, would solve “find my open PiChat views” with little/no package code. **Do not attach stop/forget automatically to generic buffer-kill actions.** Existing chat-kill policy is a separate explicit lifecycle choice.

Only add a custom Consult runtime source if actual usage shows frequent need to select runtimes without opening the manager. It must select by runtime ID, not name/short Pi ID. This would be a new surface, not necessarily a net simplification.

### NATIVE-02 — History selection can use completion without replacing the tree

A focused “jump to entry” picker could reuse the normalized visible-entry model, expose entry IDs as identity, and call existing jump/preview functions. Native `completing-read` suffices; Consult adds preview if warranted. Keep the current tree for branch topology and folding. A flat picker cannot communicate the same structure and should never reinterpret selecting a history entry as selecting a saved session file.

Do not silently replace metadata AND-token search with buffer text search: those have different scope and filter semantics.

### NATIVE-03 — View ownership is justified custom code

`pichat-view.el:50–157` wraps `pop-to-buffer`/`quit-window`, recording the originating buffer/window and ensuring a later user-repurposed window is not closed. Nested result-to-chat completion also has semantics beyond a plain `quit-window`.

This is a good abstraction to keep, not duplicate native window management to delete blindly. Simplification should remove per-view bypasses and use the common lifecycle consistently. Regression tests for repurposed windows and nested view completion are important.

### NATIVE-04 — Avoid a Comint rewrite as a cosmetic cleanup

The chat combines canonical transcript, provisional live tail, status/widgets, immutable regions, and editable prompt. Comint's process-buffer assumptions would not automatically model that structure. Likewise, `read-only-mode` over the whole buffer would prevent prompt editing. A rewrite would likely recreate the current region and transaction machinery on top of another abstraction.

The more credible incremental move is to shrink chat orchestration while keeping the current transcript authority and native buffer editing primitives.

## 7. Transient menu versus directly invokable commands

### Important distinction

Transient suffixes are themselves Emacs commands. The goal should be **discoverable, scoped actions with state shown together**, not removing `M-x`, keyboard bindings, accessibility, or programmatic APIs. Keep reusable commands and add menus as thin callers.

Current package menus cover launch, reconfiguration/recovery, and Tools. They do not form a complete chat actions menu. `user/pichat.el` supplies many personal General/which-key menus, but those are not available to package users in a minimal Emacs configuration.

### MENU-01 — Add a separate chat actions prefix

**Priority: high UX/maintenance proposal.**

Capture the owning runtime and source when opening the prefix. Show concise target/model/source status. Group actions rather than adding all of them to `pichat-launch`:

| Group | Candidate commands/actions | Why menu-first |
|---|---|---|
| Runtime controls | Select active model, choose thinking level, toggle thinking display, name session | Related settings currently split across clicks, cycling, and `M-x`. Show current values and availability. |
| Queue delivery | Set steering mode, set follow-up mode | Infrequent configuration; no need for scarce direct keys. |
| Draft management | Attach file/clipboard/screenshot, remove/clear images, recover/discard submissions, compose | Makes lifecycle choices discoverable while retaining common direct shortcuts. |
| Conversation/source | New session, switch saved session, Session History, related sessions, source back/forward | Explicit grouping reduces ambiguity; keep independent-open separate. |
| Transcript | Repaint, rendered response, export canonical Markdown | Infrequent actions with well-defined semantics; display which operations fetch data. |
| Maintenance | Compact, cached diagnostics, raw diagnostics, stop runtime | Destructive/sensitive actions benefit from context and labels; preserve confirmation where applicable. |
| Startup configuration | Open existing launch/reconfigure menus | Reuse established captured-runtime menus; do not apply preset/Tools to the live process directly. |

**Keep direct fast paths:** send, abort, prompt editing/newline, common recovery, tool/group folds, response/turn navigation, reference insertion, ordinary `pichat`, and manager opening. Menu invocation must not become required for emergency abort.

Active model changes must state that Pi RPC `set_model` also updates Pi's persistent default. Distinguish that from launch-only `--model` and PiChat's `pichat-default-model` for future processes.

### MENU-02 — Add a small diagnostics/setup prefix

**Priority: medium.**

Offer cached diagnostics, explicit raw transport inspection, `pi --version` probe, interactive Pi setup, settings file, transport customization, and mapping validation. Potentially include permission files/logs after their remote path audit.

Keep safe cached inspection the default. Clearly mark raw views as potentially sensitive and probes/setup as process-starting actions. Preserve the difference between Pi-native permission packages and Emacs-defined-tool approval policy.

`pichat-smoke-test` is a development/setup action, not a primary everyday top-level workflow. It belongs here as an advertised entry while remaining callable directly.

### MENU-03 — Runtime manager menu can expose, not replace, row commands

`RET`, stop, forget, name, make preferred, diagnostics, and preview already have native row bindings. A `?`-adjacent action prefix could help occasional users, but should call those same implementations and capture the selected **runtime ID**, not whatever row is selected when an async operation completes.

Avoid adding a second bulk-action layer until needed. Ibuffer-style batch deletion is particularly dangerous if it becomes runtime stopping by implication.

### MENU-04 — Do not move point-sensitive artifact/tool actions wholesale into Transient

Artifacts already use Embark with structured target identity. Copy/open/run/table-preview actions belong with that target. Tool location, shell output, and rerun actions could be grouped in a point-sensitive submenu, but must capture/validate the original tool and source rather than rediscovering “at point” after a repaint.

Keep direct folding/navigation keys. Transient is suitable for choosing an infrequent action, not repeated local movement.

### Menu safety and implementation constraints

- A menu is not authorization: the underlying command must recheck capabilities, liveness, source identity, and writable/busy state.
- Capture runtime/source explicitly; `current-buffer` at suffix execution may be a preview, minibuffer, or different chat.
- Invalidated context should fail clearly, not silently fall back to a preferred runtime.
- Show unavailable actions as inapt with a reason where practical.
- Do not persist transient draft values that could accidentally repeat ephemeral/reconfigure choices.
- Test direct invocation and menu invocation against the same command implementation.
- Avoid merging launch and live-chat controls into a giant menu: startup-only preset/Tools and source-changing operations have different lifetimes.

## 8. Prioritized action register

Effort estimates are relative, not calendar commitments. Every row is **proposed**.

| Work item | Findings | Priority / effort | Completion evidence |
|---|---|---|---|
| Prune no-reference private helpers | DEAD-01, DUP-03 | P1 / small | Full-repo reference check; dependent dead chain reviewed; unit suite green. |
| Retarget test-only seams | DEAD-02, TEST-02/04 | P1 / small–medium | Same invariants exercised through active production path; obsolete wrappers removed. |
| Resolve async/instructions tool API contract | DEAD-04 | P1 / medium | Bridge capability decision documented; end-to-end test or explicit rejection/deprecation. |
| Unify command catalog/freshness | DUP-01 | P1 / medium | Picker and CAPF share catalog normalization; delayed source-change tests pass. |
| Establish optional-integration test job | TEST-06 | P1 / small–medium | Actual supported dependencies loaded; four current skips execute. |
| Retire or deprecate VUI facade | DEAD-03, TEST-03 | P2 / small | Supported migration path; unnecessary require removed. |
| Remove wording-only test coupling | TEST-01 | P2 / small | Behavioral coverage retained; editorial changes no longer break ERT. |
| Chat actions/setup Transients | MENU-01/02 | P2 / medium | Captured context, clear model/source semantics, shared command implementation. |
| Separate Session History and saved-file browsing | Architecture | P2 / medium–large | Dependency graph improves without new global coupling; fork/clone/open/switch tests green. |
| Extract chat projection / extension request orchestration | Architecture | P2 / large | Explicit context boundary; transaction and stale-callback suites unchanged in intent. |
| Audit source-token ownership matrix | DUP-04 | P2 / medium | Every async consumer has documented invalidation conditions and focused tests. |
| Small marker traversal extraction | DUP-02 | P3 / small | Nil/detached marker behavior specified and tested. |
| Consult process/identity adapter review | DUP-05 | P3 / medium | Demonstrable net reduction with remote/timeout/identity guarantees retained. |
| Configure Ibuffer/Consult chat-buffer navigation | NATIVE-01 | P3 / small | Config-level improvement; no lifecycle side effects. |

P1 means “start here for maintenance work,” not “confirmed production incident.” This is the **first-pass register**; §15 supersedes its ordering, and §§16–17 distinguish subsequent reproductions from remaining risks.

## 9. Subsequent passes

### Original follow-up workstream — Reachability and API retirement

Pass 2 addressed selected items here and broadened the review; the remaining work is recorded in §16.

- Recheck candidate symbols over the entire tracked repository, including dynamic symbol construction and downstream configuration.
- Classify public API, interactive command, compatibility alias, and internal helper explicitly.
- Audit defvars/custom options/struct fields, which this pass did not systematically classify for deadness.
- Inspect bridge TypeScript and Emacs tool dispatch together, especially async tools and instruction metadata.
- Produce exact removal groups, including tests to retarget rather than delete.

### State/lifecycle ownership workstream

Pass 3 completed a targeted slice in §17, not the entire following workstream.

Build a compact matrix for runtime stop/start/restart, source switch/new/fork/clone, chat death, and preview death. For each, list canonical/live state, owned requests/timers, compose editors, attachments/recovery, view snapshots, and caches. Compare ownership against generation checks, not just function names.

Focus on reconfiguration and independent saved-session open. They superficially overlap in start/switch/synchronize/cleanup, but failure recovery and immutable identity guarantees differ. Do not force both into one transaction abstraction until the differences are explicit.

### Pass 4 — Test value and mutation analysis

- Map high-risk user invariants to unit, real-Pi, and SSH tests.
- Run coverage analysis; treat uncovered functions as prompts for investigation, not automatic deletion.
- Inject targeted failures: stale generation, wrong source identity, missing callback, renderer exception, process exit, and failed output publication.
- Identify tests that remain green when their intended guarantee is violated.
- Consolidate repeated fixture construction in support modules only when setup is truly reusable.

### Pass 5 — Native UX and command-surface prototype

Review real workflows in live Emacs. Test Ibuffer/Consult for buffer navigation, keep the runtime manager, and sketch chat/setup Transients. Compare key count, action discoverability, runtime/source ambiguity, and number of implementations—not simply number of commands.

### Pass 6 — Structural refactoring plan

After removals and contract decisions, propose module boundaries with before/after dependency arrows and test ownership. Avoid cyclic requires and a generic `utils` module containing unrelated state machinery.

### Decisions needed from the maintainer

1. Are the VUI facade commands supported public compatibility, or removable placeholders?
2. Are async Emacs tools and tool instruction metadata intended supported features today?
3. Is a new package-level chat actions Transient preferred over the current personal leader menus?
4. Should slash-command picking execute immediately or insert a reviewable draft?
5. What minimum Consult/Embark/Transient versions are supported?
6. How long should obsolete command aliases remain?
7. Is Session History's tree/folding interface a core workflow, or is most use quick entry selection?

## 10. Acceptance criteria for the overall cleanup

A successful maintainability effort should yield fewer unused/internal APIs, one implementation per command behavior, clearer state ownership, fewer tests tied to retired seams, and better execution of optional integration tests. It should **not** achieve a lower line count by discarding safety checks or flattening distinct PiChat concepts.

Retain a minimal-core Emacs path; preserve direct commands and native bindings; keep saved-session browsing distinct from Session History; keep runtime management distinct from buffer management. Evaluate every extraction by whether future changes require editing fewer independent implementations and whether failures remain diagnosable.

## 11. Second-pass perspective: simplify the cost of adding a capability

### What the first pass underweighted

The original five topics are symptoms and useful review categories, but not a complete design objective. The more useful question is:

> Can a new capability consume stable PiChat data/actions and standard Emacs interfaces without learning chat markers, source-reset internals, process lifetime rules, and every optional UI?

Today the answer varies. Pure transcript/presentation components and the backend generic functions are promising. Draft integration, action context, artifact execution, and runtime/source orchestration expose much more internal state.

**Preferred direction:** a small PiChat domain layer, a small set of explicit command/data contracts, and thin native/optional UI adapters. Not a universal plugin framework, new event system, or generic workflow engine.

### Corrections and qualifications to pass 1

1. **More menus are not automatically simpler.** A new Transient is useful only if it reuses existing commands and replaces duplicated discovery/menu maintenance. Do not add every proposed menu and picker.
2. **Extracted files are not necessarily decoupled modules.** Avoiding `require 'pichat-chat` does not establish independence when a module calls private chat functions and manipulates its buffer-local state.
3. **Artifact target capture is only partially enforced.** Copying a captured source is different from executing it on a captured host. Pass 1 was too optimistic about the latter; see ARCH-03.
4. **The backend contract is useful but not a complete backend-neutral implementation.** Session state and chat normalization still contain Pi-specific assumptions. Do not promise cheap alternate backends merely because generic methods exist.
5. **The apparent Consult/Session History dependency cycle is partly lazy.** `pichat-sessions.el:1830` requires Consult integration inside a function, while `pichat-consult.el:14` requires sessions at load time. This is maintenance coupling, not evidence of an existing recursive-load failure.
6. **The optional-test gap is now experimentally narrowed:** all four previously skipped tests executed and passed when dependencies were made available.
7. **No blanket removal of low-reference variables.** Mode maps can have no explicit callers because `define-derived-mode` uses naming conventions. The scan correctly surfaced `pichat-chat-compose-mode-map` and `pichat-consult-preview-mode-map`; neither is dead.

### Second-pass evidence

- Same baseline commit, still no tracked modifications.
- All 759 unit tests passed with optional dependency source directories available.
- `.tmp/pichat-maintainability-pass2-probes.el` exercises isolated seams with execution stubbed; output is in `.tmp/pichat-maintainability-pass2-probes.log`.
- The probes started no Pi process, executed no artifact code or tool body, and made no network request.
- Additional inventory: 84 top-level `defcustom` forms; 66 `defvar-local` forms in `pichat-chat.el`, 32 in `pichat-sessions.el`, and 20 in the subprocess artifact runner. These indicate ownership/repetition to inspect, not inherently bad counts.
- Native Emacs documentation checked for `imenu-create-index-function`, `bookmark-make-record-function`, `next-error-function`, `revert-buffer-function`, and `project-switch-commands`.

Reproduce the dependency-enabled unit check from the repository root (uses already installed sources):

```sh
emacs -Q --batch -L pichat -L pichat/test \
  -L .local/elpaca/sources/compat -L .local/elpaca/sources/consult \
  -L .local/elpaca/sources/embark -L .local/elpaca/sources/evil \
  -L .local/elpaca/sources/goto-chg -L .local/elpaca/sources/orderless \
  --eval '(setq pichat-test-include-integration nil)' \
  -l pichat/test/pichat-test.el -f ert-run-tests-batch-and-exit

emacs -Q --batch -L pichat \
  -l .tmp/pichat-maintainability-pass2-probes.el
```

The probes print observations of current defects/gaps; they are not new passing regression tests and do not modify the authoritative test suite.

## 12. Architectural simplification findings

### ARCH-01 — Introduce a small public draft API before adding integrations

**Priority: high. Evidence: confirmed private-state coupling.**

Examples:

- `pichat-reference.el:260–280` directly reads the input marker, deletes the prompt range, and inserts merged reference text.
- `pichat-artifact-result.el:58–78` requires the chat module, obtains the private source token, reads the private input marker, and calls private prompt-editing functions.
- `pichat-chat-input.el:20–53` declares private chat variables/functions; many callers assume execution in the owning buffer.
- Compose editing already supplies a better pattern: `pichat-chat-navigation-open-compose` (`:156`) accepts replacement and target-validation functions explicitly.

Adding an Org capture action, Dired attachment action, code-review handoff, or another runner should not require duplicating those private marker/source rules.

**Recommendation:** expose a few narrowly named operations for reading/replacing/appending a draft, capturing its target identity, and validating that target. Preserve source checking and editor-generation semantics behind that boundary. Let reference merging remain a pure text transformation. Use the compose callback design as a precedent; do not create an all-purpose context dictionary containing every chat variable.

**Native fit:** normal Emacs buffers, buffer-local state, ordinary functions, `with-current-buffer`, and existing mode hooks. No framework dependency is needed.

**Acceptance (proposed, not all existing guarantees):** reference insertion, result sharing, compose apply, and future integrations use the same mutation boundary; attachments remain intact; a stale origin cannot write into a different source; failed insertion preserves the original target draft. Public functions must distinguish append/replace from submit.

**Pass 3:** direct reference insertion does advance editor generation through the normal edit hook; bypassing the setter does **not** mean it bypasses all edit bookkeeping. However, collection has no captured-source recheck before insertion, and the setter itself is not an atomic text transaction. Injected re-entrancy and mid-insert failure reproduced these separate gaps (§17). Compose is a useful explicit-callback precedent, not a complete implementation of the proposed API: it intentionally overwrites concurrent prompt edits and preserves its own editor on failure, but does not promise rollback of the old target draft.

### ARCH-02 — Group state by ownership and lifetime, not by whichever UI first needed it

**Priority: high design work; gradual implementation.**

`pichat-chat-mode` (`pichat-chat.el:460–564`) initializes many independent variables and kill hooks. `pichat-chat--reset-for-source` (`:712`) reconstructs source-owned state. Projection snapshot/restore (`:2137` onward) has another explicit list of fields/markers. Restart staging adds a further preservation policy.

This makes adding a field error-prone: the author must decide whether it participates in initialization, source reset, rollback, stop, restart staging, or kill. The risk is a missing lifecycle rule, not simply the number of variables.

A useful ownership partition is:

| Owner | Examples | Lifetime |
|---|---|---|
| Runtime | ID, immutable owner scope, captured target/preset, preferred-runtime relation | Survives source rebinding and guarded restart |
| Process lifetime | Process, readiness queue/timer, pending requests | Ends on process replacement |
| Active source model | Entry cache, canonical transcript, generation, source-specific enrichment | Ends or changes on source rebinding |
| Chat presentation | Region markers, projected blocks/fragments, view positions | Belongs to a buffer/display projection |
| Draft/editor | Unsent text, attachments, recovery, compose origin | Preserved or retargeted only by explicit policy |
| Async operation | Request IDs, cancellation, phase, captured context | Ends on completion/cancellation/invalidation |

**Recommendation:** give each cohesive subsystem a constructor/reset/dispose or snapshot/restore pair, using `cl-defstruct` where fields are mutable and long-lived. Do not convert every plist. Protocol records and small immutable argument plists can remain plists.

A restart operation is a strong typed-record candidate: `pichat-reconfigure--owned-p`, `--finish`, and `--send` (`:510–586`) already define an operation identity and phase boundary. Preserve `eq` ownership and the intentional copy-on-failure behavior. A record conversion must not silently change that cancellation mechanism.

**Boundary caveat:** the canonical cache currently lives in chat buffer-local state; the manager explicitly reuses it. That is a choice to review, not automatically a defect. If future capabilities need a headless runtime, a second chat view, or data without opening chat, move authoritative synchronized state to a source-owned model and keep markers in the view. Do not implement headless/multiple-view support speculatively.

### ARCH-03 — Captured artifacts need a validated execution context

**Priority: high. Evidence: confirmed action-boundary gap, isolated probe reproduced.**

- `pichat-chat-artifacts-all` (`pichat-chat-artifacts.el:33`) captures origin buffer, source token, node, and source text in artifact identity.
- `pichat-chat-artifacts-valid-bounds` (`:55`) can validate that identity, but has only test callers in the inspected implementation.
- `pichat-artifacts-embark-run` (`pichat-artifacts-embark.el:79–91`) obtains captured code, then uses **current** buffer, `default-directory`, and `pichat-chat-session` for execution. It does not validate the captured artifact origin.
- The runner captures its sharing token when execution starts (`pichat-artifact-runner.el:393`), which cannot repair a wrong origin chosen before that point.

The pass-2 probe supplies a target captured from one buffer and invokes Run in another chat context. The stub runner receives the other runtime. This demonstrates the command-boundary gap, **not** that normal Embark dispatch always changes buffers or that wrong-host execution was observed end to end.

**Pass 3 strengthens this:** captured a target using the real artifact finder, reset its originating chat source, confirmed `pichat-chat-artifacts-valid-bounds` rejects it, then invoked the installed **real `embark--act` dispatcher**. Run still reached the stub runner with captured old code in the rebound chat. This is a batch delayed-action reproduction, not GUI collect/export validation or actual code execution. The installed Embark source selects an action window; it does not interpret PiChat's captured source identity for the adapter.

**Recommendation:** distinguish content-only operations from context-bearing operations. Copy/inspect may keep working on immutable captured source. Run/share/jump must validate the captured target or explicitly ask for a new destination. Capture host/cwd provenance deliberately; never silently substitute the current or preferred runtime.

This is a concrete reason to establish the target/draft API before adding more Embark, bookmark, Transient, or runner integrations.

**Initial W01 resolution (2026-10-25; superseded below):** The captured descriptor now retains its runtime and Emacs working directory alongside the source token and prose identity. Run rejects a dead/rebound origin, invocation outside its originating chat, runtime replacement, changed working directory, or stale prose before runner selection and again after potentially interactive selection. It never retargets implicitly; users must reselect in the intended chat. Copy/edit/preview remain content-only. Unit tests cover direct Run, changed context, and real Embark dispatch in batch with execution stubbed; the full real-Pi suite passed on Pi 1.4.0. GUI Embark collect/export and live SSH execution were not exercised for this change; batch checks do not prove their interactive behavior.

**Revised W01 resolution (2026-10-25): resolved through execution provenance, not source freshness.** Maintainer feedback rejected the blanket origin restriction: explicit execution of captured content should remain useful after source rebinding or chat death. Runner specs now declare `origin-host`, `local-independent`, or `emacs` context policies. Artifact capture snapshots transport, working directory and publication mappings rather than retaining a mutable runtime as execution authority. Delayed actions use that destination, never the currently selected chat's context. Mermaid is one local-independent runner, not a special case in action dispatch; a generic fixture verifies another renderer can follow the same policy. In-process evaluation retains SSH rejection. The captured result-handoff token is independent: stale/dead origins still cannot receive automatic draft insertion, while viewing/copying remain available. Destination pickers are deferred. Unit/full suites and dependency-enabled batch Embark dispatch pass; real Docker, live SSH, and GUI collect/export were not exercised.

### ARCH-04 — Make the tool extension contract honest and smaller

**Priority: high. Evidence: strengthened from DEAD-04 by bridge trace and probes.**

Read `bridge/pichat-bridge.ts` completely and traced `pichat-bridge-transport.el` → tool bridge → `pichat-tools-execute-json`.

Findings:

- The TypeScript bridge awaits an editor-style response; the Emacs execution path remains synchronous.
- `pichat-define-tool :async t` still generates a one-argument `(params)` function.
- The async dispatcher invokes such a function with two arguments. The probe returns a wrong-number-of-arguments error before the body executes.
- The bridge's synchronous path rejects the same registered tool as requiring asynchronous execution.
- Tool definitions sent across the bridge include neither `async` nor `instructions`. The bridge derives `promptSnippet` from description, not the Emacs tool's `instructions` slot.
- The bridge execute function receives `_signal` but does not consume it. Supporting asynchronous Emacs work requires an explicit cancellation design, not merely routing through the unused dispatcher.

**Decision:** either expose a documented synchronous-only API now and reject unsupported options at registration, or implement async execution/cancellation end to end. A future async extension should provide one callable convention and one result/error/cancel contract. There is no benefit in preserving two contradictory execution contracts for hypothetical expansion.

**W05 contract decision (2026-10-25): complete; implementation pending W06.** The maintainer chose direct-return synchronous Emacs-defined tools, early rejection of truthy async declarations/registrations rather than silent downgrade, and support for `:instructions` through Pi's native `promptGuidelines`. Preserve existing synchronous tools and description/`promptSnippet` behavior; use Pi's active-tool guidance machinery rather than a separate global prompt accumulator. Installed Pi 1.4.0 extension docs and its shipped dynamic-tools example informed the instructions decision. Repository searches found no async consumers; external consumers remain unknown, and public helper retirement is not implicitly authorized. Async may be added later without changing synchronous definitions. This does not restrict Pi-native tools, artifact runners, or existing extension UI requests. W06 is unblocked but not selected; no production code changed for this decision.

The automatically registered `echo` tool at `pichat-tools.el:164` also deserves a product decision: if it is only a demonstration fixture, move it out of normal tool registration. It is a real bridge-visible tool today, not dead code. Do not remove it before checking bridge smoke/integration tests and user expectations.

### ARCH-05 — Separate optional UI adapters from the public entry module

**Priority: medium. Evidence: confirmed load and dependency coupling.**

`pichat.el:12–34` eagerly requires launch/reconfigure/Tools, chat, Session History, archive/Consult, permissions/bridge, and the VUI facade. The isolated probe confirms that requiring core loads the archive, Consult adapter, and VUI facade even with no browsing operation.

This is not proof of a startup performance problem; no load-time benchmark was run. The maintainability cost is that core loading and tests encompass unrelated optional surfaces, and shared helpers in the sessions module pull browsing/history concepts together.

**Recommendation:** keep the public launch commands small and autoload optional commands/modules at their entry points. Separate normalized saved-session records/loading actions from Consult presentation and history tree presentation. Extract only helpers with real consumers, not a miscellaneous `utils` file. Keep explicit dependencies where a feature truly needs them.

Use Emacs autoloads and `with-eval-after-load` for adapters. Preserve independent entry-point loading. **Pass 3 checked all 51 production modules with separate `emacs -Q --batch -L pichat` require invocations: all loaded successfully.** This narrows the finding to coupling/load footprint, not an existing load-order failure. It does not test interactive commands, compilation, or startup latency. Do not claim that lazy loading alone creates clean APIs: ARCH-01 addresses the cross-module calls that autoloads cannot fix.

### ARCH-06 — Keep the existing backend/event mechanisms modest

**Priority: medium policy decision. Evidence: inspected implementations.**

The backend already uses native `cl-defgeneric`/`cl-defmethod`. Keep it; replacing it with a homegrown provider registry would not simplify anything. However, `pichat-session` includes RPC bookkeeping and chat still calls Pi-specific normalization and optional Pi controls. An advertised capability is a supported operation check, not proof of an entirely portable backend.

**Recommendation:** describe the current contract accurately. Add generic operations when a real second implementation needs them. Avoid abstracting every Pi command in anticipation of another backend.

Likewise `pichat-events.el` is only 62 lines and supports global plus runtime-local handlers, isolating handler errors. Ordinary Emacs hooks are appropriate for public customization; buffer-local hooks are not a complete replacement for events on a runtime without a selected buffer. Do not replace this bus just because Emacs has hooks. Use a small number of documented post-commit hooks for extensions, keep ordering explicit, and never make correctness-critical cleanup depend on third-party hook success.

### ARCH-07 — Extension points should be data-driven where variation is already real

**Priority: medium; target specific extension axes.**

Good existing examples:

- `pichat-attachments-clipboard-image-handlers`: configurable acquisition adapters.
- `pichat-tool-enrichment-kind-alist`: known tool-name classification before conservative heuristics.
- Chat display functions: configuration can supply Bufferlo/tab policy without a package dependency.
- Backend generic functions and compose callbacks.

Less extensible example: `pichat-artifact-runner-specs` (`pichat-artifact-runner.el:35`) is a fixed positional table; dispatch special-cases Elisp, and the subprocess invocation shape is executable plus temporary script. Another language/interpreter invocation may require editing core.

**Recommendation:** when adding the next runner, define a validated runner descriptor with named fields for aliases, executable/argv construction, script suffix, and supported host kind. Reuse current transport, output capture, publication, result rendering, and draft handoff. Keep in-process Elisp distinct where timeout and host semantics differ.

Do not merge editing-mode selection with execution selection. Markdown's language-mode mapping is already reused for editing and does not authorize execution. Do not adopt Org Babel as the default execution engine simply for language breadth: it adds session, header-argument, confirmation, result-insertion, and remote behavior that PiChat does not currently promise. An explicit optional Babel adapter could be considered later with those differences stated.

A reference collector function list or generic method is another sensible extension seam if new source modes are needed. Preserve region precedence, destination path mapping, and explicit snapshot limits. A universal capability/plugin registry is not justified.

### ARCH-08 — Reduce accidental configuration combinations

**Priority: medium. Evidence: concrete overlapping options.**

`pichat-chat-collapse-tools-by-default` overrides `pichat-chat-tool-default-display` (`pichat-chat.el:56–71`). A user can choose `output` and see `summary` because another option takes precedence. Group disclosure adds a separate, legitimate parent policy.

**Recommendation:** choose one canonical completed-tool display policy; migrate/deprecate the older boolean if compatibility permits. Retain group-versus-child distinction and explicit user overrides. Keep policy resolution pure and test its small decision table. Group related Custom settings by behavior and lifecycle instead of adding more independent flags whenever a presentation case arises.

More generally, distinguish startup-only settings, live runtime settings, future-default settings, and buffer-local display settings. A menu can present those distinctions; it should not invent a second configuration store.

## 13. Existing Emacs infrastructure: higher-leverage integrations

These are prioritized **adapters**, not a request to implement every item. Prefer one adapter that opens an existing ecosystem over another custom picker.

| Integration | PiChat data/action to expose | Benefit and constraints | Priority |
|---|---|---|---|
| **Imenu** | Settled turns or selected logical headings → source-validated locations | Native `imenu` and `consult-imenu` work without a bespoke transcript picker. Invalidate/rebuild indexes after source change/repaint; distinguish canonical entries from provisional live nodes. | High-value prototype |
| **Completion metadata** | Structured command/session/runtime records with stable identity, category, annotations/affixation | Lets native completion, Vertico/Orderless, Consult, and Embark reuse one data contract. Saved-session completion already does much of this; extend rather than replace it. | High |
| **Project integration** | Ordinary `pichat` entry in `project-prefix-map` / `project-switch-commands` | Reuses standard project workflow. Manager already uses `project-prompter` and `project-remember-project`; no separate project registry is needed. | Low-cost config |
| **Revert protocol** | Per-view explicit refresh action | Manager already supplies `revert-buffer-function`; history/previews can expose appropriate equivalent operations. Chat refresh must preserve drafts and define fetch versus repaint clearly. | Medium |
| **Buttons** | Actionable tool locations/headers with typed payload | Standard button keymap/help/navigation can reduce custom mouse plumbing. Keep markers/text ownership compatible with exact-source projection. | Targeted prototype |
| **`next-error-function`** | Actual diagnostic locations, not every arbitrary tool visit | Standard next/previous diagnostic navigation can be reused where semantics fit. Do not hijack global next-error behavior merely for generic activity navigation. | Conditional |
| **Bookmarks** | Persistent saved-session provenance + optional entry ID + custom handler | Native bookmark list/Consult bookmarks could reopen stable conversation locations. Never persist runtime IDs or raw buffer positions as durable identity. Reject ephemeral sources; preserve target qualification and second-writer checks. | Later, after target API |
| **Display rules** | Common view display + configurable policy | Already uses `pop-to-buffer`, `quit-window`, and display function hooks. Keep Bufferlo/tab logic outside core and continue honoring `display-buffer-alist`. | Keep/improve consistency |
| **Isearch/Occur/Consult line** | Current visible transcript text | Already available; no custom search needed for this scope. Content removed by fold rendering or truncation is not recovered by searching the buffer; ordinary invisibility overlays may instead be searchable/revealable, depending on the command. Full history search needs canonical data, not a promise that `consult-line` sees everything. | Document/configure |
| **Minor modes/hooks** | Optional Evil/Embark/navigation adapters | Keep native major-mode behavior useful alone. Use hooks for user customization, not for hidden required initialization. | Keep |

### INFRA-01 — Imenu before a new transcript-search UI

No PiChat `imenu-create-index-function` integration was found. The canonical transcript and existing navigation properties already contain the logical identities needed to construct one. Start with settled user turns (bounded prompt labels) and call the existing reveal/jump path. If marker positions alone cannot safely survive projection, use a source-aware resolution path and invalidate Imenu's cache explicitly.

This could replace the proposed additional history-jump picker for common **active transcript** navigation. It does not replace Session History's alternate branches or saved-session search. Measure whether it actually removes custom UI work before adding more surfaces.

### INFRA-02 — Do not force native packages onto incompatible domain models

- `jsonrpc.el` is not a drop-in replacement for Pi's JSONL request/event protocol. Adapting an incompatible wire contract may cost more than the current transport wrapper. Reuse native process primitives, not an unrelated protocol abstraction.
- `outline-minor-mode`/`hs-minor-mode` do not automatically model activity groups, independent child tool disclosure, branch filters, and canonical/live settlement. A folding rewrite must preserve those semantics and exact copied source.
- Comint, Ibuffer, Org Babel, and unrestricted SHR/EWW are not complete substitutes for PiChat's transcript, runtime, execution, and safe-rendering contracts.
- `atomic-change-group`/change groups are useful for buffer text, but do not themselves roll back hash tables, markers, overlays, model references, or external side effects. PiChat already uses a private change group for focused live rollback (`pichat-chat.el:2453`). Its remaining projection rollback cannot be deleted just by naming a native transaction primitive.

The simplification principle is **use native extension interfaces at the edge; keep domain-specific authority and lifetime rules explicit**.

## 14. Additional correctness, responsiveness, and diagnostic findings

### REL-01 — SSH startup classification has an escaping defect

**Priority: small correctness fix. Evidence: source and isolated reproduction.**

`pichat-chat-diagnostics.el:99–101` uses single backslashes for regexp alternation inside a Lisp string (`tramp\|connection refused…` as source text, rather than doubled string escaping). The runtime regexp therefore does not express the intended alternatives.

The probe supplied a `file-error` condition with `TRAMP: connection refused` and `Could not resolve hostname example.invalid`; both classified as nil rather than `connection-failed`. This affects diagnostic specificity, not evidence of SSH transport failure. Use `regexp-opt`/`rx` or correctly escaped literals and add focused tests. Existing passing suites did not catch this case.

### REL-02 — Separate parse failures from dispatch/consumer failures

`pichat-rpc--handle-line` (`pichat-rpc.el:461`) wraps both JSON decoding and object dispatch in one `condition-case`, reporting every caught error as `rpc-parse` / “Failed to parse Pi RPC output.” A valid record that fails in dispatch can be mislabeled.

`pichat-emit` also catches handler errors and reports them only through `message`, without the unified diagnostic record path. Isolation is desirable; swallowing causal context is not.

**Pass 3 reproduction:** dispatched a valid JSON response whose registered success callback deliberately raised `consumer failed`; the recorded origin was `rpc-parse`. This confirms misattribution at the callback boundary. Event-handler errors caught inside `pichat-emit` follow its separate message-only path; they do not all escape to this parse handler.

**Recommendation:** keep decode/protocol-validation/dispatch/UI-projection stages distinct in diagnostics. Record bounded structural context such as event kind and stage, avoid raw prompts/secrets in ordinary summaries, and retain explicitly requested raw inspection. Use typed internal errors (`define-error`) for decisions owned by PiChat; retain conservative text classification only for unstructured external errors. Do not build a logging framework.

### REL-03 — Audit memory/work bounds, not only displayed output bounds

**Evidence: inspected control flow; no memory exhaustion reproduced.**

- `pichat-archive-run` (`pichat-archive.el:288–344`) collects helper output in a process buffer and checks stdout size in the terminal sentinel. The configured limit bounds accepted results, **not peak capture while the helper runs**. Stderr has no corresponding streaming cap there. The Consult stage checks stdout bytes incrementally, so these paths have different resource semantics.
- `pichat-rpc--process-filter` (`:440–459`) concatenates the unfinished JSONL record without an explicit record-size limit. A malformed wrapper emitting an indefinitely unterminated line can retain growing data. Valid full `get_entries` responses may be large, so a naive low cap would break normal transcripts.
- Diagnostic records cap record count and stderr, but `:response` is copied without a size bound (`pichat-chat-diagnostics.el:232–264`). Event-log count limits likewise are not byte limits.
- The basic file picker synchronously scans files and parses uncached JSONL summaries (`pichat-sessions.el:1228–1242,1298–1336`). This is especially relevant over TRAMP. The summary cache does prune absent files; it should not be described simply as a never-pruned leak.
- Clipboard/screenshot acquisition uses blocking `call-process` (`pichat-attachments.el:190–243`) and validates file size afterward. A slow acquisition helper can block Emacs; interactive screenshot selection is a case where cancellation/timeout policy needs care.

**Recommendation:** define a small resource policy per operation: result-size limit, capture-size limit, timeout, cancellation owner, and cleanup. Share bounded subprocess mechanics only across genuinely similar helper operations. Use native `make-process`/filters/sentinels for acquisition if blocking becomes a problem; maintain binary-safe capture and explicit user cancellation. Never silently truncate canonical transcript data and pretend synchronization succeeded.

### PERF-01 — Artifact lookup scans more than the selected target needs

`pichat-chat-artifacts-at-point` calls `pichat-chat-artifacts-all`, which scans and parses all settled assistant prose before selecting the artifact at point (`pichat-chat-artifacts.el:12–53`). Visible Avy selection also parses all artifacts before filtering to the window (`:69` onward).

**Recommendation:** find the current prose run before parsing for point actions, and restrict parsing to relevant visible runs for Avy. If profiling justifies caching, key by source/node/prose content and keep cache lifetime explicit; do not add another global cache first. This is a likely scaling opportunity, not a measured latency claim.

### DEAD-06 — Additional state/declaration candidates

Tracked-repository reference checks reconfirmed DEAD-01. Additional candidates:

- `pichat-archive--session-metadata-keys` (`pichat-archive.el:58`): declaration only.
- `pichat-sessions--visible-roots` (`pichat-sessions.el:95,938`): declared and assigned, no read found.
- `rpc` and `tool-registry` slots in `pichat-session`: no accessor or constructor-key use found in tracked package/config sources. Inspect downstream API expectations before altering the public struct.

Do not remove `backend-state`: it is used by the fake backend contract tests and represents the documented backend-state extension point, even though Pi does not use it today. Do not remove conventionally named mode maps. This illustrates why symbol frequency is triage rather than a deletion rule.

## 15. Revised simplification roadmap

### A. Establish contracts before adding interfaces

1. **Fix/decide concrete gaps:** ARCH-03 action context; ARCH-04 tool contract; REL-01 escaping; REL-02 error attribution. Add focused tests first. These are proposals, not changes made in this review.
2. **Expose the minimal draft/target API** (ARCH-01), then migrate existing reference/result/compose consumers. This reduces the knowledge required by every future integration.
3. **Unify the command catalog** (DUP-01) behind validated source context; retain separate draft completion and explicit execution semantics.
4. **Prune verified dead helpers/state** while retargeting useful tests. Small cleanup should accompany the relevant boundary work rather than become a standalone architectural goal.

### B. Reuse Emacs's existing interfaces

5. Prototype **Imenu** for active-transcript navigation and a small project integration in configuration. Evaluate these before adding another custom jump/search picker.
6. Use existing completion metadata/action records consistently. Keep Consult/Embark as adapters; do not require them for basic workflows.
7. Add one **chat actions Transient** only after command context is reliable. Fold relevant personal discovery menus into it rather than maintaining both. Defer manager/setup submenus unless real usage warrants them.

### C. Reduce ownership complexity incrementally

8. Group source/projection/operation state and define lifecycle operations (ARCH-02). Start with one subsystem; measure reduction in reset/snapshot lists and private cross-module access.
9. Separate optional adapters and Session History/saved-file services (ARCH-05). Test independent entry-point loading.
10. Introduce only demanded extension descriptors (ARCH-07), and consolidate conflicting configuration (ARCH-08).
11. Apply resource bounds and profile long-transcript/remote-picker paths (REL-03/PERF-01) before adding concurrency, caches, or background services.

### Proposed extension acceptance tests

Use these as design exercises, not new features to implement now:

| Hypothetical addition | Desired implementation footprint |
|---|---|
| Add a Ruby subprocess runner | One descriptor plus runner-specific tests; no change to sharing, process cleanup, view ownership, or chat markers |
| Add an Org-region reference action | One collector using public draft/target operations; no direct prompt-marker mutation |
| Navigate turns through `consult-imenu` | Native Imenu adapter; no second transcript parser or custom Consult process |
| Add a diagnostics menu action | One thin suffix calling an existing context-validating command |
| Add a new structured tool location kind | Extend presentation normalization/data adapter; reuse location actions and transport mapping |
| Add a backend-specific capability | One honest capability/method implementation; unsupported operations fail before side effects |

**Measure success by:** fewer modules touched per feature, fewer private chat accesses outside orchestration, fewer independently maintained lifecycle lists, fewer duplicated picker/menu behaviors, and no reduction in safety or supported host semantics. Lower line count is a secondary outcome.

## 16. Current verification ledger — updated by pass 3

This replaces the old “pass 2 work / still needed” table. **Executed tests, inspected contracts, synthetic reproductions, and design proposals are different kinds of evidence.** A completed suite is not proof that every scenario in its domain was covered.

### 16.1 Revalidated data and outcomes

- Source/config/test diff between `14cd767` and `9107cea`: **none**. Only this review was added to Git. Existing source line references remain applicable.
- Recounted **51 production files / 24,054 lines**, **57 test/support files / 24,444 lines**, **830 literal test definitions with no duplicate names**, **84 top-level custom options**, and the **66/32/20** buffer-local declaration counts. These figures remain correct.
- Rechecked DEAD-01, selected DEAD-02/04 entries, DEAD-06, and artifact-validator references against tracked text, excluding this review itself. Results support the existing candidates; they are still not proof about external or dynamically constructed calls.
- **Full local suite, Pi 1.4.0, optional dependencies enabled: 822 passed, 0 skipped, 0 unexpected.** This comprises 759 unit and 63 real-Pi tests. Fixtures use isolated agent/session/project directories and deterministic offline providers. No SSH tests were selected.
- Existing real-Pi tests exercised bridge schema refresh/deactivation/errors, ordinary abort/queue behavior, fork/clone/switch, independent saved-session open, and guarded restart. They do **not** establish async Emacs-tool cancellation support.
- **51/51 isolated module loads passed**, each in a new Emacs process. This was a source-load check, not byte-compilation or performance measurement.
- **9/9 review observations passed**, including tests which intentionally assert the current gaps. They are separate from the 822 authoritative tests and must not be advertised as regression tests for fixes.
- **Two deliberately broken in-memory variants were detected:** bypassing compose source validation and accepting a retired restart operation each caused the selected test to fail. Functions were restored automatically; no source was mutated. This is a two-guard sanity check, not a mutation score.
- **Coverage attempt failed:** 759 selected, 691 expected results, **68 unexpected**, followed by an `args-out-of-range` report-generation error. Instrumented traces include Edebug counter-array index errors in the focused projection path. The uninstrumented full suite passed. Treat this as an unusable instrumentation/reporting run; neither coverage percentages nor 68 production regressions are established. Root cause was not fully diagnosed.
- Pi 1.4.0 is the exact executable tested here. `pichat/PI_COMPATIBILITY.md` still records the earlier verified/reviewed release; this review did **not** audit upstream changes or advance that compatibility ledger.

### 16.2 Coverage and remaining work

| Area | Evidence now obtained | Still unverified / decision needed |
|---|---|---|
| Dead helpers/state | Counts and tracked exact references reconfirmed; no new callers found for checked candidates | External configuration, generated calls, supported public API/alias policy; not all DEAD-02 accessors reaudited in this pass |
| Tool bridge | Prior async/instructions probes reconfirmed; current real-Pi schema/deactivation/error tests passed | End-to-end async Emacs-tool execution and cancellation; support/deprecation choice |
| Artifact actions | Real finder → stale source → real Embark dispatcher → stub runner reproduction; existing stale-share tests passed | Interactive collect/export/window routing and wrong-host impact; durable regression for the desired rejection |
| Draft/target contracts | Exact source-token fields traced; source reset, share, compose, reference collection and injected edit failure exercised (§17) | Policy for pathname availability changes; validated collection/execution contexts; transactional target mutation |
| Dependencies | Core footprint reconfirmed; 51 fresh-process loads passed | Compile matrix, autoload/API design, measured startup cost |
| Restart/projection | Targeted ownership matrix (§17); existing fault-injection and full real-Pi restart tests passed; retired-operation mutant detected | Exhaustive phase × failure × cancellation × re-entrancy matrix; no universal rollback proof |
| Native integration | Existing hooks/contracts inspected; no integration implementation changed | Live Imenu/revert/bookmark prototypes and UX comparison; proposals remain proposals |
| Tests | 822/822 uninstrumented full run; two selected mutation checks | SSH suite; repair/diagnose coverage instrumentation; broader mutation analysis |
| Resource use | Static resource/scan observations remain supported | Peak memory/latency measurements, stalled-helper tests, large transcripts and remote scans; no measured bottleneck claimed |
| Configuration/API | Display-option precedence and backend/runner extension boundaries rechecked | Minimum optional-package versions and product decisions; Pi version coverage is separate from API policy |

### 16.3 Evidence artifacts and reproduction

All artifacts below are under `.tmp/` and are gitignored, not permanent test-suite additions:

| Artifact | Purpose |
|---|---|
| `pichat-maintainability-pass3-full-tests.log` | Successful 822-test uninstrumented full run |
| `pichat-maintainability-pass3-static.log` | Counts and exact tracked-text reference locations |
| `pichat-maintainability-pass3-loads.log` | Fresh-process require result for every production module |
| `pichat-maintainability-pass3-recheck.log` | Rerun of pass-2 SSH/async/artifact/load-footprint probes |
| `pichat-maintainability-pass3-probes.el` / `.log` | Nine named current-behavior observations, including synthetic gaps |
| `pichat-maintainability-pass3-mutations.el` / `.log` | Two in-memory variants detected by assertion failure |
| `pichat-maintainability-pass3-coverage.log` | Failed instrumented run and report-generation error; no usable coverage report |

Full run: use the dependency-enabled command in §11 with `pichat-test-include-integration` set to `t` and `PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0` in the environment. This is the full runner's suite with the optional load paths added.

Observation run:

```sh
emacs -Q --batch -L pichat -L pichat/test \
  -L .local/elpaca/sources/compat -L .local/elpaca/sources/embark \
  -l .tmp/pichat-maintainability-pass3-probes.el \
  --eval '(ert-run-tests-batch-and-exit "^review-")'
```

For the mutation check, use the same load paths and load `pichat-maintainability-pass3-mutations.el` instead, without the final ERT expression. It reports the two **expected assertion failures** and exits successfully only when both variants are detected. Coverage used `pichat/test/run-coverage.sh --format lcov`, a `.tmp/` report destination via `PICHAT_COVERAGE_REPORT_FILE`, and the §11 dependency directories via `PICHAT_COVERAGE_LOAD_PATH`.

The initial draft of the observation script had a parenthesis error and an uninitialized process-generation fixture; these were corrected before the final 9/9 run. They were probe-authoring errors, not package findings.

## 17. Targeted draft/target lifecycle pass

### 17.1 Identity is a set of contracts, not one universal token

The chat source token is exactly **`(source-generation Pi-session-ID saved-file-path)`** (`pichat-chat--source-token`). It includes neither runtime ID, process generation, nor editor generation. Consumers separately retain their origin buffer. Other owners use different combinations:

| Consumer | Identity/ownership checks | Consequence |
|---|---|---|
| Compose apply | Live target buffer + callback validating captured chat source token | Rejects ordinary rebind; intentionally permits concurrent prompt edits to be overwritten; does not require a live Pi process |
| Result share | Live chat origin + equal chat source token + optional runner-ready predicate | Can append to a stopped runtime's draft; no automatic submission; process replacement alone is not invalidation |
| Response navigation/refresh | Live origin callbacks + source token + canonical assistant node, and projected position for return | Snapshot copying remains independent of live navigation |
| Submission recovery | Request identity + source generation + editor generation + current draft/image state | Prevents late rejection from replacing newer input; source reset moves pending records/images to manual recovery |
| Slash CAPF | Source generation/key + request sequence | Same-ID pathname availability does not change its ID-based key |
| Command picker | Runtime liveness before prompting and submission | Source change during argument collection is not rejected (DUP-01) |
| Artifact Run | Captured code descriptor, but current-buffer execution context | Descriptor's stored source identity is not validated (ARCH-03) |
| Reference insertion | Chosen target buffer; captured path context/transport for collection | No source revalidation after potentially re-entrant collection |
| Restart request | `eq` operation ownership, phase, chat ownership, and replacement process/generation | Retired callbacks must not acquire a replacement attempt; copy-on-cancel is substantive |
| History/manager previews | Source token plus their own request generation, runtime/row/buffer/window ownership checks | Do not replace these with the chat token without preserving the additional checks |

These checks are necessary but not universally interchangeable. In particular, **draft editing is not execution or submission**: requiring Pi liveness for every draft edit, or invalidating every editor on a verified same-source restart, would change existing behavior.

### 17.2 Bounded transition matrix

This is an inspected/tested slice, not the exhaustive matrix originally proposed in §9.

| Transition | Draft/attachments and targets | Async/model ownership | Evidence |
|---|---|---|---|
| Ordinary new/switch/fork/clone source rebind | Draft and pending images retained; in-flight submissions become recoverable; old compose/result tokens rejected. Fork may explicitly replace/copy returned prompt text. | Source generation advances; canonical/live/enrichment state and owned sync/stats/projection work reset; CAPF reset | `--reset-for-source`, `pichat-chat-input-abandon-in-flight`; existing fork/clone/input/projection tests; new observation |
| A → B → A in one chat | Old A token stays invalid despite equal final Pi ID/path | Generation distinguishes visits | New round-trip observation |
| Same Pi ID, pathname field nil → path | Generation and ID-based completion key remain unchanged, but compose/result token changes | No ordinary source reset | Existing file-materialization generation test plus new compose observation; see REL-04 below |
| Stop/process generation change without source reset | Draft/source token need not change; result share remains an edit-only operation | RPC lifetime guards and pending-request cancellation are separate from draft identity | Source trace, existing RPC stop tests, synthetic stopped-share observation |
| Verified saved-source restart | Draft and compose token retained; old canonical snapshot held through staging/failure | Process generation changes; owned operation verifies full source/entries/settings before commit | `pichat-chat-restart-staging-retains-snapshot-until-verified-commit`; full real-Pi restart tests |
| Verified unwritten-empty restart | New source generation/ID; compose explicitly retargeted only after successful projection; draft retained | New metadata-only cache verified; failed projection preserves staging and old generation | `pichat-chat-empty-restart-projection-failure-retains-snapshot-and-draft`; real-Pi restart coverage |
| Chat death | Compose retains its own text; result snapshot remains copyable but cannot share to dead origin; no migration to another chat | Chat releases handlers/requests/timers; active restart is cancelled/stopped even if normal stop-on-kill is disabled | Existing compose, artifact, chat cleanup and lifecycle tests |
| Preview death or selected-row/source change | Immutable snapshots are not authority to mutate a different source | Preview request cancellation/generation/owner checks remain independent | Inspected history/manager request ownership and existing preview tests; no new interactive preview run |
| Independent saved-source open fails | Origin runtime/draft remains separate; new runtime must be stopped/forgotten | Launch owns its new runtime and synchronization/reservation; not a rollback of the origin runtime | Existing manager cancellation/failure tests and full independent-open integration tests |

A source reset is not a blanket cancellation of every runtime-owned extension facility; do not infer that from the shorthand row above. Dialog activation, process exit, restart staging, and chat kill have separate cancellation paths. Their full cross-product remains unverified.

### 17.3 Corrections and newly narrowed gaps

**REL-04 — Pathname availability and source-token semantics differ.** The same Pi session ID with a newly supplied pathname is treated as the same source by `pichat-chat--source-identity-changed-p`, but changes the tuple used by compose/results/responses. The new observation confirms compose rejects that transition even though source generation stays equal. This is a conservative rejection/consistency issue, not stale content being accepted. Merely writing a file whose pathname was already known does **not** change the token. The probe supplies the nil → path transition; its frequency in real Pi was not measured. Decide the contract before centralizing tokens, and do not weaken remote provenance checks to remove a false rejection.

**ARCH-01 follow-up — Reference collection is not source-validated.** A synthetic callback during `pichat-reference--dwim-text` reset the selected chat source; `pichat-add-reference` still inserted the collected text. No real TRAMP/confirmation race was executed. The fix proposal is a source check immediately before insertion, not a claim that references currently fail to advance editor generation: the probe confirmed that their direct edit runs that hook.

**W03 resolution (2026-10-25): reference destination revalidation implemented.** `pichat-add-reference` captures the chosen chat's runtime ownership and source token before collection, then rejects a dead/non-chat destination, changed owner, or changed token immediately before insertion. Nine public-entry-point regressions cover injected source transitions during the file prompt (including A → B → A and path-only changes), ownership changes, origin death without retargeting, valid merging/bookkeeping, stopped-runtime editing, concurrent same-source draft edits, and mapped region precedence. Existing reference/path tests remain green. No process-liveness gate or public draft API migration was introduced; ARCH-01's broader API work remains W09. Unit/full suites pass with seven optional skips; no live SSH or end-to-end interactive Pi session-switch reproduction is claimed.

**REL-05 — Compose failure preservation does not imply target-draft rollback.** The existing `pichat-compose-replacement-failure-preserves-text` test asserts the compose buffer survives a callback error; it does not assert the old target prompt is restored. Injecting an `insert` error after `pichat-chat--set-input-text` deletes the old prompt leaves that target prompt empty, while compose text survives and editor generation has not advanced. This is a bounded fault-injection result, not observed spontaneous data loss. ARCH-01's stronger acceptance criterion requires a text transaction and explicit bookkeeping commit. That small draft transaction is distinct from full canonical/live projection rollback.

**W04 decision (2026-10-25): deferred pending a realistic trigger.** The maintainer approved setting aside implementation, not declaring the rollback weakness fixed or permanently rejected. Inspection found no ordinary built-in UI action that reliably produces the required insertion error; replacement inhibits modification hooks, and compose text survives the injected failure. Reconsider for a reproducible ordinary workflow, a user report, or a related change that makes this failure boundary relevant. Implementation requires renewed approval. The managed plan retains the original evidence and incomplete acceptance checks.

**Existing test value confirmed:** projection tests already inject failures after insertion, indexing, decoration, fontification, and before commit; the uninstrumented suite passed them. The earlier “fault injection still needed” wording must not suggest there are no such tests. Remaining work is systematic transition coverage and additional failure boundaries, not starting from zero.

### 17.4 Next pass

The next useful correctness work is to turn the reproduced **stale execution/submission/reference** observations into tests for desired rejection, after agreeing on the narrow target/draft contract. Separately diagnose the coverage instrumentation failure before using coverage to justify deletions. Interactive Embark collect/export, SSH, broad mutation testing, and exhaustive restart/resource matrices remain open. No implementation change is authorized or made by this review.


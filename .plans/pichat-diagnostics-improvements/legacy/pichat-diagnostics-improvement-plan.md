# PiChat diagnostics improvement plan

Status: proposed; no implementation changes made.

## Goal

Make safe diagnostics the primary troubleshooting entry point, preserve explicit access to sensitive raw evidence, and ensure every action operates on the runtime being inspected.

Use the terminology in `pichat/GLOSSARY.md`: a runtime is not its loaded Pi session; Session History is not saved-session browsing.

## Findings

- `pichat-show-diagnostics` provides useful, safe cached summaries across runtime/transport, canonical transcript, live tail, and Session History domains.
- `pichat-show-transport-diagnostics` serves a distinct purpose: bounded raw failure evidence and recent RPC events. It can expose secrets and prompt content.
- `pichat-session-manager-diagnostics` is a necessary row-context adapter, not a duplicate inspector.
- `pichat-diagnostics-probe-pi` checks executable/version availability through a transport, not full RPC health or the configured wrapper command.
- Interactive Pi and settings-file access are useful recovery/configuration actions, not read-only diagnostics.
- `pichat-diagnostics-customize-transport` currently opens the entire `pichat` customization group despite its narrow name.
- Both inspector buffers currently have shared names and do not retain the inspected runtime as action context. Reinvoking a command from a report can fall back to another runtime.
- The single interactive setup buffer can reuse a live process launched for a different target/context.

## Scope and constraints

- Keep both inspectors and the manager shortcut.
- Do not fetch history or issue RPC requests when opening or refreshing safe diagnostics.
- Preserve domain-owned retention and source validation; do not copy transcript/history warnings into the runtime failure log.
- Never automatically open, include, copy, or export raw transport data from the safe view.
- Setup, probing, and configuration changes require explicit actions.
- Do not turn the version probe into a comprehensive health checker in this work.
- Before implementation, read `pichat/README.md`, `pichat/GLOSSARY.md`, and `pichat/TESTING_GUIDELINES.md`, and verify relevant existing tests and view conventions.

## Phase 1 — Runtime-owned inspector views

### Changes

- Introduce diagnostics view modes derived from `pichat-view-mode`, sharing runtime ownership and action helpers where appropriate.
- Store the inspected runtime in buffer-local state; all view actions pass it explicitly rather than relying on directory/global fallback.
- Prefer one safe buffer and one raw buffer per runtime, named with a stable runtime identifier. Reopening the same runtime reuses its view.
- Show a compact identity header: runtime ID, backend/target, runtime state, and snapshot time.
- Avoid exposing raw paths, command arguments, credentials, or prompt content in the safe header. Sanitize any optional display labels.
- Preserve `q` return/bury behavior through the existing view presentation API, including nested safe-to-raw navigation.
- Keep reports readable for stopped/failed runtimes. Define behavior for forgotten runtimes: retain the existing snapshot, but reject actions requiring a registered owner with a clear message rather than selecting another runtime.

### Acceptance criteria

- Reports for runtimes A and B can coexist.
- Refresh and secondary actions in A's report still target A after the global current runtime changes to B.
- Closing a raw view opened from a safe view returns to that safe view.
- No diagnostic action silently switches owners when the runtime stops or is forgotten.

## Phase 2 — Primary safe diagnostics interface

### Changes

- Retain the four current sections:
  - Runtime / transport
  - Canonical transcript
  - Live tail
  - Session History
- State prominently that this is a cached snapshot, not a live health check.
- Distinguish `none` from `unavailable`; explain that unavailable means no current cached snapshot, not necessarily a failure.
- Add an explicit refresh command that rebuilds from current caches without network/process activity.
- Offer a clearly labelled raw-details action with a sensitive-data warning. Opening it remains an explicit user action.
- Where records provide them, display concise severity/category and failure time without printing raw records. Do not invent timestamps for domains that do not retain them.
- Ensure stale source-bound sections are excluded after source rebinding. Preserve runtime failure records according to their existing lifetime.

### Proposed bindings

These are proposals to validate against existing maps, Evil behavior, and personal mode-key conventions before implementation:

- Safe diagnostics: `g` refresh in the native map; `g r` in Evil Normal state.
- Safe diagnostics: `r` open raw transport details explicitly.
- Safe diagnostics: `s` open a setup/troubleshooting action chooser.
- Both inspectors: `q` return/bury.
- Raw diagnostics: native `g` and Evil `g r` rebuild the bounded raw snapshot.
- Runtime manager: retain native `D`, Evil `g D`, and the existing personal mode-key entry.
- Chat: add a personal mode-key entry for safe diagnostics after checking conflicts; do not change existing chat bindings incidentally.

## Phase 3 — Separate inspection from setup

### Setup/troubleshooting chooser

Expose the existing helpers from the safe view using its explicit runtime context:

- **Check Pi executable/version** — runs a process; does not validate authentication, model configuration, RPC startup, or arbitrary wrappers.
- **Open interactive Pi setup** — starts or selects a separate setup terminal.
- **Open settings file** — visits an editable configuration file.
- **Customize PiChat** — opens Emacs customization.

Apply backend capability checks per action. Disable or explain unsupported actions rather than presenting Pi-specific operations as universal backend features.

### Probe clarification

- Preserve the bounded purpose of `pichat-diagnostics-probe-pi`.
- Update labels, docstrings, and documentation to describe executable/version checking accurately.
- State explicitly that it does not exercise `pichat-rpc-command` wrappers.
- Keep results in the echo area/`*Messages*` unless usability testing demonstrates a need for another report buffer.

### Interactive setup ownership

- Associate setup terminals with an explicit launch context, including target/transport, working directory, and effective setup command.
- Reuse a live setup process only when the context matches; otherwise open a separately identified terminal or require an explicit choice.
- Do not stop an existing setup process merely to serve another runtime.
- Preserve explicit wrapper/container setup-command requirements; do not guess how to strip RPC flags.

### Customization naming

- Prefer an accurately named `pichat-diagnostics-customize` command opening the existing `pichat` group.
- Retain `pichat-diagnostics-customize-transport` as a compatibility alias if renamed.
- Do not introduce a new customization hierarchy solely to justify the old command name.

## Phase 4 — Documentation and compatibility

- Update `pichat/README.md` with the Inspect versus Setup distinction, view contents, bindings, cache semantics, raw-data warning, and probe limitations.
- Update `pichat/GLOSSARY.md` only if a new user-facing concept needs definition; preserve its existing runtime/source terminology.
- Update `user/pichat.el` with the agreed chat/view mode-key entries.
- Retain existing public commands and aliases unless there is an explicit migration decision.
- Keep the manager action described as unified cached diagnostics, not transport-only diagnostics; update misleading internal capability-action text where appropriate.

## Verification

Extend tests around `pichat/test/pichat-test-chat-diagnostics.el`, shared views, and Evil bindings:

- Exact owner resolution despite changed global/directory context.
- Separate buffers for separate runtimes and reuse for the same runtime.
- Stopped/failed and forgotten-runtime behavior.
- Safe refresh issues no RPC requests, history fetches, or process launches.
- Empty versus unavailable sections and stale-source rejection.
- Safe rendering excludes raw command/response/stderr fields and redacts supported sensitive patterns.
- Raw view remains bounded and explicitly opened; warning remains visible.
- Snapshot metadata and optional record metadata render correctly when fields are absent.
- Native/Evil actions and nested `q` behavior.
- Setup actions receive the viewed runtime and obey backend capabilities.
- Version probe remains distinct from RPC-wrapper validation.
- Setup terminal reuse matches context and never substitutes another target silently.
- Existing command aliases remain callable.

Run `pichat/test/run-tests.sh`; use `--full` for relevant RPC integration coverage, following the isolation rules in `pichat/TESTING_GUIDELINES.md`. Verify personal `user/` binding changes in a live Emacs session rather than relying on isolated byte compilation.

## Suggested delivery order

1. Runtime ownership, per-runtime inspector buffers, and regression tests.
2. Cached refresh, safe-to-raw navigation, identity headers, and view bindings.
3. Setup chooser, probe wording, customization naming, and setup-terminal ownership.
4. Personal bindings, documentation, full regression checks, and live Emacs usability review.

## Out of scope

- Automatic repair, login, settings edits, or runtime restarts.
- Automatic raw-log export or issue-report generation.
- Unifying all diagnostic records into one retention store.
- Comprehensive provider/model/network health checks.
- Removing useful context-specific wrapper commands simply to reduce command count.

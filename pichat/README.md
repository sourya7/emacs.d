# PiChat

PiChat is an Emacs frontend for the Pi coding agent over Pi RPC.

## Rendering architecture

PiChat treats Pi's persisted active-branch entries as the authority for settled
transcripts.  RPC events feed a generation-scoped live draft while the agent is
running.  After settlement, an incremental `get_entries` synchronization builds
and validates a new canonical transcript before atomically replacing the
canonical region and clearing the live tail.

The chat buffer has separate persistent extension-status, canonical, live-tail,
transient status, extension-widget, and prompt regions. Extension statuses stay
below the header while conversation content grows beneath them. Fire-and-forget
extension notifications render as buffer-local, read-only conversation content
anchored where they arrive; they preserve multiline command output but are not
persisted to Pi sessions. Dialog-like extension requests are queued without
opening a minibuffer over unrelated work. The oldest request becomes interactive
only when its exact chat is selected and focused; `UI:N` in that chat's mode line
shows the queued count. High-frequency live updates are coalesced; final messages
flush immediately. Source rebinding invalidates stale caches, requests, timers,
and callbacks before new state is accepted. Failed synchronization preserves
the visible live result and shows a bounded not-synchronized status. Each live
candidate is reduced and rendered before a projection transaction; candidates
with identical text, properties, tool interaction state, decorations, and
source identity commit no buffer edit. Changed candidates are split at stable
node and tool boundaries, replace only one changed logical span, and retain
unaffected tool markers and overlays. Missing, stale, or ambiguous fragment
state falls back to exact full live-tail replacement. Safe live updates use a
private change group plus focused marker, block, overlay, and projection-state
rollback; their edits never enter prompt undo history. Canonical reconstruction,
status changes outside the live tail, and uncertain marker topology retain the
complete-display rollback transaction.

Completed assistant prose also has a derived Markdown presentation layer.
Inline Markdown links display as compact clickable labels, while their exact
source remains in the buffer. PiChat parses and displays pipe tables with its
own bounded renderer: each preview row stays on one visual line, wide cells are
ellipsized, and omitted rows or columns have explicit counts. Incomplete
streaming Markdown remains unrendered. Presentation overlays are recreated after
projection and rollback; malformed tables or presentation failures leave exact
raw Markdown visible rather than failing transcript projection. Shell Maker is
not used by PiChat's table path. When Embark is installed, compact and expanded
PiChat links are exposed as URL targets rather than their visible labels.

User messages are rendered only from authoritative Pi events.  Unknown protocol
data is normalized to bounded diagnostics rather than printed as raw objects.
Consecutive thinking and tool calls are presented in source-ordered activity
groups. Group headers summarize bounded enriched tool kinds plus visible
thinking, and can fold the whole run; expanded groups retain each tool's
independent header/arguments/output control while thinking remains an indented
child. A `toolUse` assistant stop reason is an intermediate continuation marker,
so it does not split an activity group or produce a terminal annotation. Actual
terminal stops and explicit assistant errors remain boundaries. Disabling
`pichat-chat-show-thinking` hides thinking text and thought-only groups but
retains tool activity grouping and controls.
`pichat-chat-activity-group-display` defaults to `latest`, which keeps current
live tail activity open and folds older or settled groups. It also accepts
`collapsed` and `expanded`; an explicit group choice overrides any policy.
Assistant prose and tool rows share a shallow visual gutter without adding
spaces to copied or exported transcript text.

Running tools show their available arguments and output; completed, errored,
orphaned, and settled-incomplete tools use the configured completed display
(defaulting to a folded header). Only explicit user fold choices survive live
reprojection and transfer transactionally to matching canonical tools after
settlement. Group and tool choices are independent: closing and reopening a
group does not reset a child's selected tool view. Derived file locations appear
as actionable overlay text without changing canonical/live source text. Location records associate with matching
canonical tools by source generation and tool-call ID and remain available from
settlement until source rebinding or chat-buffer death. They are never persisted
as transcript data. Non-persisted auxiliary execution details are available only
before canonical synchronization and are explicitly reported as unavailable
afterward. Compatibility diagnostics are deduplicated and displayed as bounded
status entries.

## Module dependency direction

`pichat-chat.el` is the mode and event-orchestration layer. It may consume
focused presentation modules, but those modules do not require or mutate the
chat layer's state implicitly. `pichat-chat-input.el` owns prompt submission,
history, recovery, and pending/in-flight attachment coordination without
requiring the chat layer; orchestration supplies prompt markers and compact
status presentation. `pichat-attachments.el` owns bounded image records, file
encoding, wire conversion, and optional acquisition adapters without knowing
about chat buffers or transcript state. `pichat-chat-diagnostics.el` owns
conservative transport/Pi-response classification, bounded session diagnostic
records, safe summaries, explicit raw inspection, and setup launch policy; it
does not depend on the chat mode. `pichat-chat-completion.el` owns the
source-generation-scoped slash-command cache and completion logic; chat
orchestration supplies source identity and prompt boundaries, and stale RPC
callbacks cannot replace a rebound source's cache. `pichat-tool-enrichment.el`
depends only on path
translation and pure Lisp helpers: it normalizes partial live tool arguments,
derives presentation-only classification and locations, and performs no file
I/O. `pichat-shell-presentation.el` consumes execute-kind enrichment and Pi's
cumulative tool observations to derive command layout and distinct success,
exit, signal, timeout, and tool-error labels; it owns no chat or transcript
state. `pichat-activity-presentation.el` derives generic source-ordered activity
members, groups, identities, aggregate status, and bounded summaries without
owning buffers or protocol state. `pichat-chat-activity-ui.el` consumes that
pure model to format enriched headers and index marker-backed disclosure blocks;
it never fetches source data or edits transcript regions.
`pichat-chat-tool-ui.el` receives transcript, block, view, enrichment, and
buffer-edit context explicitly; it supplies pure specialized tool text to the
initial render pass, then indexes that final text without editing it. It owns
explicit fold replacements, details, and derived location overlays but never
requires `pichat-chat.el`.
`pichat-chat-navigation.el` owns logical turn/active-target selection, expanded
prompt-editor lifecycle, and canonical-model Markdown serialization without
requiring the chat layer; orchestration supplies source tokens, markers, block
tables, and the prompt replacement callback. `pichat-archive.el` owns exact-RPC
capability discovery, helper provenance, process execution, and protocol
normalization without depending on Consult or querying SQLite; `pichat-consult.el`
consumes only normalized archive records. The chat layer owns event orchestration
and its generation-scoped enrichment table.
Canonical transcript and Pi reducer modules remain independent authorities and
never consume this ephemeral state.

## Launching runtimes

PiChat requires Transient for its advanced launcher. The package requires it
explicitly and does not rely on configuration load order.

Set `pichat-pi-extra-env` to an alist of environment variables that every
Pi process started by PiChat should receive. Configured values override the
environment inherited from Emacs without changing Emacs's global environment:

```elisp
(setq pichat-pi-extra-env
      '(("PI_OFFLINE" . "1")
        ("PI_TELEMETRY" . "0")))
```

This applies to RPC runtimes, model listing, the diagnostic `pi --version`
probe, and interactive Pi setup. It also controls local settings discovery when
`PI_CODING_AGENT_DIR` is set. Existing processes must be restarted. Wrapper
commands receive these values in the wrapper's environment; Docker and similar
wrappers must explicitly forward them into the contained runtime.

The public launch commands are deliberately small:

- `M-x pichat` opens the preferred runtime for the current project, or the
  preferred global runtime outside a project. If none is live, it creates and
  remembers one. This is the fast default.
- `M-x pichat-global` does the same for explicit global scope.
- `M-x pichat-launch` opens a Transient for advanced launch profiles.
- `C-u M-x pichat` opens that same Transient.

The Transient starts with no switches, which is equivalent to ordinary
`pichat`. It does not restore saved switch values, preventing an old ephemeral
choice from being repeated accidentally.

| Key | Choice | Effect |
|---|---|---|
| `g` | Global | Use global instead of current-project scope |
| `n` | Independent runtime | Start an additional runtime instead of reusing the preferred one |
| `t` | Target | Use inferred, local, or a configured runtime target |
| `e` | Ephemeral | Start Pi with `--no-session`; implies independent |
| `m` | Choose/enter model | Select a listed model or enter an unlisted ID for only this run; implies independent |
| `RET` | Launch | Execute the normalized profile shown in the action label |

The switches compose. For example, `g e m` creates an independent global,
ephemeral runtime and asks for its model. `n` alone creates an independent
persistent/default-model runtime in the current scope. `g` alone opens the
preferred global runtime. With no switches, PiChat opens the preferred current
runtime.

An independent runtime is a separate Pi RPC process retained in the manager but
not marked `★` as the scope's preferred runtime. “Independent” does not mean
Pi's `new_session` operation inside an existing runtime. For a run-local model,
PiChat lists and prompts for models before creating the target runtime, then
passes the exact selection through that process's startup `--model`. The launch
prompt also accepts an unlisted `provider/model-id` when that provider appears
in Pi's available-model list; nested slashes in the model ID are preserved.
Unlisted IDs cannot include a Pi thinking-level suffix. Pi supplies fallback
metadata for such IDs from another model on the provider, so this facility is
best for temporarily trying a newly released ID. Define the model in
`~/.pi/agent/models.json` when accurate context limits, reasoning, input,
compatibility, or cost metadata matters.

The launch flow never uses Pi's globally persistent RPC `set_model` operation
and never changes `pichat-default-model` or another runtime. Active-runtime and
default-model selection remain catalog-only. Cancelling model selection creates
no runtime; invalid manual input creates no runtime; startup or verification
failure stops and forgets the selected runtime.

Persistent versus ephemeral describes Pi source-file storage, not Emacs runtime
management. Ephemeral runtimes still appear in the manager while retained, but
are never made preferred automatically. When `pichat-rpc-command` supplies a
complete argv, ordinary persistent launch remains supported, but ephemeral and
run-local-model launches fail before runtime registration because PiChat cannot
safely inject `--no-session` or `--model` into an arbitrary wrapper command.

## Global runtime-session manager

`M-x pichat-session-manager` opens one global `*PiChat Sessions*` buffer for all
retained PiChat RPC runtimes across project and global scopes. A runtime is the
Emacs-side process/session object; the persisted Pi source loaded into it may
change after new-session, switch, fork, or clone operations. Manager rows use an
immutable Emacs runtime identity, so such source changes do not replace or
misidentify a row. The compact table shows an unlabeled `★` for the preferred
runtime in an owner scope, followed by the current Pi source ID, runtime status,
source storage (`file` or `none`), friendly owner project (or `global`), target, model, and explicit session name. A warning-faced `!` appended to Status, such as
`running!`, means that the runtime is waiting for user input; it disappears when
the final queued request is answered or cancelled. Unnamed sessions show `—`
rather than repeating their ID. Full runtime identity, source
path, scope, working directory, and recent branch context remain available in
the `C-o` preview.

Ordinary `pichat` still reuses one preferred live runtime per scope.
Independent profiles from `pichat-launch`, manager-created runtimes, and
independently opened saved sessions are additional runtimes and do not replace
that preferred entry unless
`m` is used in the manager. Stopped, failed, and unexpectedly ended runtimes
remain inspectable until explicitly forgotten. Killing a chat retains the
existing `pichat-chat-stop-session-on-kill` behavior and forgets that chat's
runtime after stopping it; killing or quitting the manager never stops any
runtime.

Manager keys:

- `RET` — open the exact selected runtime's chat;
- `C-o` — toggle a bounded active-branch preview which follows the selected row;
- `n` — start an independent runtime in a recent known project, with an
  explicit manual-directory fallback;
- `N` — start one in the selected runtime's immutable owner scope;
- `+` — open the shared launch Transient; current scope prompts for an exact
  project/directory and global scope does not;
- `b` — search saved sessions and open the selection in a new runtime associated
  with its recorded project (using archive-backed Consult when available, with
  the basic file picker as fallback);
- `k` — stop only the selected live runtime;
- `d` — forget and clean up a stopped or failed runtime;
- `m` — make the selected live runtime preferred for its owner scope;
- `D` — show that runtime's transport diagnostics;
- `g` — redraw rows from cached state, without broadcasting RPC requests;
- `q` — bury the manager;
- `?` — describe the mode.

The runtime preview reports persistence from immutable launch metadata as
`persisted source file` or `none (--no-session)`; it does not infer persistence
from whether state synchronization has produced a source path yet.

The runtime preview reuses the owning chat's settled canonical entry cache when
available, including after a runtime stops. Otherwise a live runtime is queried
explicitly when previewing; ordinary manager refresh remains cached-only. The
preview is source-scoped, rejects stale row/source callbacks, and shows only the
most recent `pichat-session-manager-preview-max-entries` entries. Use `g` in the
preview to refresh it and `q` to close it.

Archive-backed Consult candidates also expose Embark action `o` to open a saved
source in a new independent runtime. Independent loading starts a separate
process, switches and synchronizes that exact process, and stops/forgets it if
startup, switching, cancellation, or synchronization fails. It never mutates
the runtime from which browsing was invoked.

By default the manager opens chats in the current tab. Customize
`pichat-session-manager-display-chat-function` to select a frame or tab before
calling `pichat-session-manager-display-chat-current-tab`. PiChat has no Tab Bar
or Bufferlo dependency. This repository's `user/pichat.el` demonstrates an
optional Bufferlo-aware policy: it reuses a chat's existing Bufferlo location,
otherwise selects or creates the owner project's tab, and finally falls back to
the current tab. The manager itself remains on demand; showing the same global
buffer in a tab lets Bufferlo record normal local membership there.

## Evil integration

PiChat does not depend on Evil. Evil users can start editable chat buffers ready
for typing while leaving read-only PiChat views under their native Emacs
bindings:

```elisp
(with-eval-after-load 'evil
  (evil-set-initial-state 'pichat-chat-mode 'insert)
  (evil-set-initial-state 'pichat-chat-compose-mode 'insert)
  (evil-set-initial-state 'pichat-view-mode 'emacs))
```

`pichat-view-mode` is the common parent of PiChat's read-only history, preview,
details, diagnostics, and report buffers. Configuring that parent does not alter
unrelated `special-mode` buffers. Non-Evil users need no additional setup.

## Local verification

This repo loads PiChat through `user/pichat.el`.

Commands:

- `M-x pichat` — open the preferred current-scope chat
- `M-x pichat-global` — open the preferred global chat
- `M-x pichat-launch` or `C-u M-x pichat` — configure an advanced launch
- `M-x pichat-session-manager` — manage all retained RPC runtimes
- `M-x pichat-smoke-test` — start Pi RPC and call `get_state`
- `M-x pichat-stop-session` — stop current RPC process
- `M-x pichat-add-reference` — insert a DWIM Emacs reference into a PiChat prompt

Chat keys:

- `RET` — send prompt
- `S-RET` — insert newline
- `C-c C-k` — abort
- `C-c C-y` — recover a rejected or ambiguously failed submission, including
  its images
- `M-x pichat-chat-discard-recoverable-submissions` — discard saved recovery drafts
- `C-c C-i` — attach a bounded PNG, JPEG, GIF, or WebP file
- `C-c C-q` — select and remove one pending image
- `C-c C-u` — attach an image through the first available clipboard adapter
- `C-c C-j` — capture and attach a screenshot
- `M-x pichat-chat-clear-attachments` — clear pending images without affecting
  submissions already in flight
- Image-only prompts are controlled by
  `pichat-attachments-allow-image-only-prompts` and are disabled by default
- `M-x pichat-show-transport-diagnostics` — explicitly inspect bounded raw
  stderr, failed RPC responses, the configured command, and recent RPC events;
  this view may contain secrets, paths, and prompt content
- `M-x pichat-diagnostics-open-interactive-pi` — launch plain Pi in a terminal
  for `/login`, `/model`, and `/settings`
- `M-x pichat-diagnostics-open-settings` — visit Pi's global `settings.json`
- `M-x pichat-diagnostics-customize-transport` — customize diagnostic/setup
  behavior; wrapper and container transports must set
  `pichat-diagnostics-interactive-command` explicitly because PiChat does not
  guess how to remove RPC arguments from arbitrary commands
- Ordinary chat status shows only bounded, redacted diagnostic summaries and
  distinguishes local startup/process exit failures from valid Pi RPC errors
- `C-c C-o` — compact
- `M-<up>` / `M-<down>` — browse submitted prompt history
- `M-x pichat-chat-steer` / `M-x pichat-chat-follow-up` — queue messages during a run
- `M-x pichat-chat-set-steering-mode` / `M-x pichat-chat-set-follow-up-mode` — configure Pi queue delivery
- `C-c C-n` — new session
- `C-c C-e` — name current session
- `C-c C-m` — cycle model
- `C-c C-t` — cycle thinking level when supported by the selected model
- `M-x pichat-chat-set-thinking-level` — choose a specific level from those
  supported by the selected model
- `M-x pichat-select-default-model` — asynchronously search Pi's available
  models and set `pichat-default-model` for future plain Pi RPC processes. The
  setting is passed through `--model`; invoke the command with `C-u` to clear
  the override. A complete `pichat-rpc-command` remains authoritative and
  disables model selection, but does not prevent clearing the override
- Click the model ID in the compact `MODEL.THINKING` mode-line control — change
  the active runtime's model through Pi RPC. In the installed Pi 0.83,
  `set_model` also writes that choice as Pi's global default for future
  processes. Use the `m` switch in `pichat-launch` when the selection must be
  run-local. Model availability comes from the current Pi runtime's cached
  snapshot and does not force a catalog refresh
- Click the thinking suffix in that control (for example, `.H`) — cycle Pi's
  model-supported thinking levels; non-reasoning models omit the suffix, while
  unavailable and failed controls display `.?` and `.!`
- `C-c C-x` — Pi command/template/skill picker
- At the beginning of the prompt, type `/` and invoke completion-at-point to
  complete currently available Pi commands, templates, and skills
- `C-c C-p` — open **Session History** for the current session file
- `C-c C-b` — select an archive project, search saved sessions, and switch to
  one when the exact active local Pi process exposes a compatible `pi-archive`,
  or when an explicitly trusted standalone source is configured without a live
  process; otherwise use the basic saved-file picker. `C-u C-c C-b` always
  forces the basic picker
- `C-c C-r` — browse the active persisted session's resolved archive parent and
  direct children; this uses the same bounded relation picker, preview, and
  loading actions as archive search and does not alter the live source
  back/forward stacks until a related source is explicitly loaded
- `M-x pichat-sessions-return-to-origin` — return to the previous persisted
  source session in the current fork/clone chain
- `M-x pichat-sessions-forward-to-fork` — move forward again in that persisted
  fork/clone chain

Session History and saved-session browsing are separate operations. Session
History displays every branch in the current file and identifies Pi's active
path; it never treats an entry as a session file. Rich saved-session browsing
normally uses the archive maintained by a compatible `pi-archive` extension
loaded in the exact active Pi RPC process. PiChat
recognizes the versioned `pi-archive-status-v1` command, resolves
`../bin/pi-archive-query.mjs` from that command's extension source, and validates
query protocol 1, physical schema 3, stable API 1, search policy 1, and the
standard `~/.pi/agent/archive.db` path. Without a live process, an explicitly
configured `pichat-archive-standalone-source` supplies the trusted extension
source and uses the same relative helper and status validation. A live process
remains authoritative when one exists. Standalone browsing is read-only and does
not refresh an archive that no Pi process is currently maintaining. PiChat
invokes the matching helper with argv and never queries or mutates SQLite. It
does not start Pi merely to discover this capability.

Protocol v1 accepts local capabilities and live SSH capabilities validated
through the owning session's exact transport. Extension provenance is checked
in runtime path space, and the matching helper executes beside Pi against the
standard archive under that runtime's home. PiChat never translates package
provenance through presentation mappings or opens/copies SQLite itself. Docker,
legacy wrappers, custom databases, inaccessible sources, and ambiguous
capabilities use the basic picker. Missing
Consult or Node.js, an unavailable archive, or incompatible status also uses the
basic picker. A prefix argument bypasses discovery and immediately uses that
picker.

Archive browsing first offers the current project, all projects, and exact
nonblank cwd groups returned by the archive. An Embark collect/export rerun
reopens the selected project's search directly, with the prior query restored;
the project picker remains the entry point for a new browse command. Search
results are one candidate per session: explicit session-name and fallback-title
matches rank ahead of visible
user/assistant content matches, while thinking, tool calls, tool results, and
other archive document kinds remain excluded. Empty input lists recent sessions.
Unqualified terms are conservatively quoted and joined with FTS `AND`.

Saved-session completion uses a compact-ID-first identity followed by a bounded
human-readable title. Activity time, match kind, relation state, CWD, and hit
count occupy aligned display-annotation fields after a visible separator. This
keeps stable fields comparable across rows and prevents one long title from
pushing all metadata out of view. The complete session record remains the
selection, preview, and Embark target, so duplicate visible ID/title prefixes
cannot select the wrong session. Customize
`pichat-sessions-completion-title-width` to adjust the identity column.

Field queries can be combined: `name:"session name"` searches explicit names,
`text:"exact phrase"` requires one visible message to match, and `role:user` or
`role:assistant` restricts a free/text content query. Role-only and
name-plus-role-only queries are rejected. The relation annotation uses `↑` for a
resolved parent, `↑!` for a missing parent reference, `↑?` for an ambiguous
parent reference, and `↓N` for the number of direct children. Indicators combine,
as in `↑↓2`, because a session can have both a parent and children. Set
`pichat-consult-relation-indicator-style` to `ascii` for `P`, `P!`, `P?`, `CN`,
and combined forms such as `P/C2`.

An archive compatibility title remains the explicit session name, complete
transcript's first prompt, or session ID. The displayed title prefers an
explicit name and then a conservatively identified prompt introduced by the
child. Empty children and children whose branch prompt cannot be established
safely retain the inherited compatibility title; the relation indicator and
short session ID still distinguish them.

`C-o` previews bounded archived conversation context, the immediate relation
summary, and lazily loaded fork-point evidence without changing Pi's active
session. `C-c C-r` opens a bounded Consult picker for the selected session's
resolved parent and direct children; use Consult narrowing key `p` for the
parent and `c` for children. `RET` continues to load the selected session. With
Embark, `j` loads and opens Session History at a loadable best entry, and `r`
also browses relations. Relation candidates support the same preview and Embark
actions. `RET` loads only a resolved nested session whose source exists, and
loading still goes through ordinary PiChat path-mapping checks. Relation
metadata has no content-match entry, so `j` opens Session History at its normal
current position rather than treating fork evidence as loadable. `C-g` returns
one browser level: to the prior relation set, or to the same archive project and
query. Empty or failed drill-downs likewise return to the prior picker while the
capability remains current; a stale or invalidated archive capability returns to
the originating non-minibuffer view.

The raw `parentSessionPath` is historical header metadata, not a loadable parent.
Resolved relations are separate records. `forkPointStatus: observed` provides an
exact historical `selectedEntryId` and `before`/`at` position, while `derived`
provides only conservative shared-base evidence. Neither proves current entry
loadability, and no relation indicator or view distinguishes `/fork` from
`/clone`. Archive relations never modify PiChat's live source back/forward
stacks.

Session History does not implement Pi's same-file `/tree` navigation: activating
history creates and rebinds to a new session with `fork`, rather than changing
the active leaf in the current file. `clone` likewise creates and rebinds to a
new session, always from Pi's current active branch rather than the selected
history row.

Session History filters cycle with `F` in this order:

- `default` — conversation entries and tool results, without bookkeeping rows;
- `no-tools` — `default` without tool-result rows;
- `user-only` — user-message rows only;
- `labeled-only` — entries carrying resolved Pi labels, not raw label records;
- `all` — every valid entry, including bookkeeping rows.

A non-current assistant entry containing only tool calls is hidden unless it
represents an error or abort. The current position remains represented when a
filter would otherwise hide it. `/` searches visible metadata
case-insensitively and requires every whitespace-separated token to match;
empty input clears the query.

Session History keys:

- `RET` — jump to and reveal the selected entry when it is present in the
  owning chat's active transcript; use `v` for entries on alternate branches
- `f` — explicitly fork the selected user prompt; direct RPC fork targets must
  be user-message entries
- `v` — preview the immutable root-to-entry branch, including explicit tool
  calls and results, with point positioned at the selected entry
- `TAB` — fold or unfold the current branch segment
- `n` / `p`, `<down>` / `<up>` — move between visible entries
- `M-n` / `M-p` — move between visible branch segments
- `<` / `>` — move to the first / last visible entry
- `/` — search visible history metadata with AND-token matching
- `F` — cycle the filter described above
- `g` — refresh history from the current source
- `d` — show bounded raw details for the selected entry
- `C` — clone Pi's current active branch, regardless of the selected row
- `b` — browse saved session files
- `q` — return to the owning live chat buffer
- `?` — describe the mode and its bindings

A successful fork waits for the rebound session state, restores Pi's returned
prompt text into the chat editor, and focuses the prompt without an extra
repaint. If the editor is non-empty when state arrives, PiChat asks before
replacing it; declining keeps the draft and copies the fork prompt to the kill
ring. Pending, in-flight, and recoverable attachments are preserved. Fork
cancellation or failure leaves Session History and the chat editor unchanged.
Pi's fork response restores historical prompt text only; historical image
attachments are not restored.

Cloning asks for confirmation, rebinds to a new session, waits for its refreshed
identity, and focuses the chat prompt. The existing draft and image attachment
lifecycle are preserved. Cancellation, RPC failure (including an empty session),
or state-sync failure is reported without an extra repaint or a false success
message.

Branch preview keys:

- `f` — resolve the nearest preceding user prompt on this exact branch, then
  confirm its summary and entry ID before forking
- `t` — return to the exact originating Session History buffer
- `d` — show raw details for the selected preview entry
- `q` — close the preview

A preview remains readable after its owning session rebinds, but is marked stale
and cannot fork. If the resolved historical user prompt contained images, the
confirmation explains that Pi restores its text only.

Source back/forward navigation is scoped to one Pi RPC session and is available
only when both the source and target have nonblank persisted session-file paths;
the paths need not exist on disk yet. Cancellation and switch failure leave both
stacks unchanged. Starting a new session or browsing to an unrelated saved
session clears the fork/clone chain.

Additional chat keys:

- `C-c C-v` — repaint from authoritative Pi session entries
- `C-c C-l` — toggle the Markdown link at point between compact and source
- `C-c C-a` — toggle the Markdown table at point between rendered and source
- `RET` over a Markdown table, `C-c C-<return>`, or
  `M-x pichat-chat-open-table-at-point` — open its complete immutable table
  viewer; the explicit chat binding remains available when a modal keymap masks
  the contextual `RET`
- Inline tables show conservative plain cell text rather than nested Markdown
  styling or clickable cell links. They preserve exact source, never wrap a
  cell, use `…` for truncation, and show explicit omitted-row/column counts.
  `pichat-chat-table-preview-max-rows`,
  `pichat-chat-table-preview-max-columns`,
  `pichat-chat-table-min-column-width`,
  `pichat-chat-table-max-width-fraction`, and
  `pichat-chat-table-unicode-borders` control supported preview behavior.
- The complete table viewer is read-only and horizontally scrollable. Its keys
  are `q` to kill, `t` to return to a still-current origin, `<`/`>` to scroll,
  `n`/`p` to move by semantic rows, `g` to reset position and horizontal scroll,
  `w` to copy exact Markdown, `s` to toggle normalized/raw views, and `a` to
  explicitly align a snapshot that exceeded automatic alignment limits. Built-in
  Org table support loads only when this viewer opens; PiChat never evaluates
  formulas, Babel, links, or exports from assistant table content.
- `M-x pichat-chat-open-link-at-point` — open an allowed link (`http`, `https`, or `mailto`)
- `M-x pichat-chat-copy-link-at-point` — copy a link destination
- `M-x pichat-chat-describe-link-at-point` — show a link destination
- `M-x pichat-chat-toggle-link-display` — toggle all links in the buffer
- `M-x pichat-chat-toggle-table-display` — toggle all tables in the buffer
- `RET`, `TAB`, or mouse-1 on an activity header — expand or collapse that
  source-ordered tool group
- `C-c C-;` — expand or collapse the activity group header at point
- `M-x pichat-chat-next-activity` / `M-x pichat-chat-previous-activity` — move
  between visible activity group headers
- `C-c C-z` — cycle a visible child tool block between header and arguments;
  the selected child view survives parent-group folding
- `C-c C-d` — show full tool details/output, kind, title, and location at point
- `C-c C-g` — visit the local tool location at point
- `C-c C-w` — copy the local tool location at point
- `M-x pichat-chat-copy-tool-path` — copy only the local tool path at point
- Execute-kind tools display a concise title, explicit non-interactive command
  section, cumulative output snapshot, and normalized completion cause
- `M-x pichat-chat-copy-shell-command` — copy the exact execute command
- `M-x pichat-chat-copy-shell-output` — copy the complete retained output,
  including text omitted from the bounded inline display
- `M-x pichat-chat-rerun-shell-in-compilation` — optionally rerun the command
  through host Emacs compilation when
  `pichat-shell-presentation-enable-compilation-rerun` is enabled; this never
  uses Pi RPC and does not reproduce container or SSH execution
- `M-n` / `M-p` — next/previous tool block
- `C-c M-n` / `C-c M-p` — next/previous user turn using stable logical node
  properties rather than fontification
- `C-c C-.` — jump by explicit priority to the latest running tool, pending
  extension request, non-empty live tail, or active prompt
- `C-c C-,` — open an expanded editor initialized from the trimmed current
  prompt, or return to its existing unsaved editor
- `C-c C-c` in compose — trim its text, replace the chat prompt without
  submitting, close compose, and return to the corresponding prompt position
- `C-c C-k` in compose — discard the compose editor without changing the prompt
- Compose editors are never silently reassigned after target-buffer death or
  source rebinding; failed replacement leaves their text intact
- `M-x pichat-chat-export-transcript-to-markdown` — export authoritative
  canonical transcript model data, including complete canonical tool output,
  without reading rendered, folded, or truncated buffer text

## Emacs references

`pichat-add-reference` inserts a lightweight reference into the active PiChat
prompt instead of maintaining persistent Emacs-side context.  It is DWIM:
active regions become file/line references, file buffers reference the current
defun/symbol/line, Dired references marked files, compilation buffers reference
the source error location, and non-file buffers insert a snapshot.

## Saved session storage

The basic saved-file picker reads local sessions from the configured directory
and remote session roots through the owning session's TRAMP transport.
It uses the same compact-ID-plus-bounded-title primary identity and annotates
each row with aligned modification-time and abbreviated-CWD fields. Its
structured completion table can filter by title, full or compact ID, CWD,
modification time, and relative session filename without placing those aliases
in the selected candidate or history. Annotations themselves remain display
metadata.

Archive-backed search uses the exact active Pi process and its validated local
or SSH archive capability or, when no process is live, the explicitly configured
local `pichat-archive-standalone-source`; it does not depend on
`pichat-sessions-default-root` being readable. The directory used by the basic
picker can contain the authoritative host files or a mirror that an external
tool maintains.  PiChat does not create mounts, synchronize files, check mirror
freshness, resolve conflicts, or write a mirror back to its runtime.

Set `pichat-sessions-default-root` to the host-visible session directory.  When
the host and Pi runtime paths differ, add mappings for both the session root and
the project.  PiChat translates a selected host session file before it sends
`switch_session` to Pi.  It translates the saved runtime working directory back
to a host path before it changes the Emacs session scope and
`default-directory`.

When `pichat-path-mappings` is non-nil, a selected saved session file must be
covered by a mapping.  PiChat rejects an uncovered file instead of sending a
host-only path to Pi.  If the saved working directory is not covered, PiChat
loads the session but keeps its current host working directory and reports the
missing mapping.  If an external mirror is stale or its runtime file no longer
exists, Pi reports the normal `switch_session` error.

For example, an external process can mirror Lima session files into a local
host directory:

```elisp
(setq pichat-sessions-default-root
      "/Users/me/Library/Caches/pichat/lima-sessions/")

(setq pichat-path-mappings
      '(("/Users/me/Library/Caches/pichat/lima-sessions"
         . "/home/me/.pi/agent/sessions")
        ("/Users/me/project" . "/workspace")))
```

The external process owns the copy schedule and direction.  A one-way,
read-only host mirror is recommended.

## SSH/TRAMP runtime

SSH runtimes are structured targets. PiChat uses TRAMP file handlers for RPC,
model listing, setup, session files, and archive helpers; it does not construct
an `ssh` shell command. A TRAMP project infers its remote target. A locally
visited mounted project uses the longest matching
`pichat-project-target-alist` entry.

```elisp
(setq pichat-targets
      '((lima-devbox
         :kind ssh
         :tramp-prefix "/ssh:lima-devbox:"
         :pi-executable "/etc/profiles/per-user/dev/bin/pi"
         :remote-path (tramp-own-remote-path)
         :runtime-home "/home/dev.guest"
         :path-mappings
         (("/home/mojo/Dev" . "/home/mojo/Dev")
          ("/ssh:lima-devbox:/home/dev.guest" . "/home/dev.guest")))))

(setq pichat-project-target-alist
      '(("/home/mojo/Dev" . lima-devbox)))
```

Mappings are `(EMACS-PREFIX . RUNTIME-PREFIX)` and use longest-prefix matching.
The example opens mounted `/home/mojo/Dev` files locally and guest-private
`/home/dev.guest` files through TRAMP. Equal reverse prefixes are rejected as
ambiguous. Target state is captured by each runtime, so local and SSH sessions
can coexist and later customization changes do not reinterpret settled links.

Remote Pi loads its own settings, credentials, extensions, skills, and session
store. PiChat does not inject host extension paths into SSH startup. An explicit
SSH target never falls back to local Pi. Automatic reconnect, host/guest
session synchronization, and remote compilation reruns are not provided.

Use `M-x pichat-path-validate-mappings` from a chat to inspect its mappings,
`M-x pichat-diagnostics-open-settings` for the owning settings file, and
`M-x pichat-diagnostics-probe-pi` to run `pi --version` through the transport.

## Docker runtime

PiChat talks JSONL over stdin/stdout, so Docker works by running Pi with `-i`
and no TTY.  A host bind mount gives PiChat direct access to saved sessions and
requires no synchronization:

```elisp
(setq pichat-rpc-command
      '("docker" "run" "--rm" "-i"
        "-v" "/home/me/project:/workspace"
        "-v" "/home/me/pi-agent:/home/pi/.pi"
        "-w" "/workspace"
        "my-pi-image"
        "pi" "--mode" "rpc"))

(setq pichat-sessions-default-root
      "/home/me/pi-agent/agent/sessions/")

(setq pichat-path-mappings
      '(("/home/me/project" . "/workspace")
        ("/home/me/pi-agent" . "/home/pi/.pi")))

;; Separate terminal command for /login, /model, and /settings.
(setq pichat-diagnostics-interactive-command
      '("docker" "run" "--rm" "-it"
        "-v" "/home/me/project:/workspace"
        "-v" "/home/me/pi-agent:/home/pi/.pi"
        "-w" "/workspace" "my-pi-image" "pi"))
```

Use `M-x pichat-path-validate-mappings` to inspect mappings. Because this
example sets a complete `pichat-rpc-command`, ephemeral and run-local-model
profiles from `pichat-launch` are not yet supported; use a plain Pi command for
those launches until a wrapper-aware command builder is implemented.

## Permissions

Pi-native tools should be governed by Pi permission packages such as
`pi-permission-gate`. PiChat's local approval layer is only for Emacs-defined
tools, because those execute in Emacs. A mutating Emacs tool whose effective
policy is `ask` waits for its owning chat to be selected before prompting;
stored allow/deny decisions and non-mutating tools remain immediate.

### claude code bridge needs the following auto-approved -
  "permissions": {
    "allow": [
        "mcp__custom-tools__*"
    ]
  }

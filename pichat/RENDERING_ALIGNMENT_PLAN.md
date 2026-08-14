# PiChat live and historical rendering alignment plan

This plan follows the findings in
[`RENDERING_CURRENT_STATE.md`](./RENDERING_CURRENT_STATE.md). It replaces the
original migration-oriented common-reducer design with a simpler architecture
appropriate for a single-user project where compatibility with the existing
renderer is not required.

This design is now implemented.  The implementation is covered by sanitized
unit/integration fixtures and uses the module boundaries and authority rules
described below.

## Goal

Adopt this invariant:

> After a successful synchronization, the chat transcript is a projection of
> Pi's persisted active branch, and no live draft remains in the transcript.

A manual repaint uses the same cached/persisted entries, active-branch selector,
normalizer, and renderer. Settled live/history parity is therefore true by
construction rather than established by comparing two independently reduced
sources.

Exact parity excludes data Pi does not persist:

- token-by-token animation;
- pending/running tool state and partial output;
- elapsed tool duration;
- retry, queue, approval, and extension UI state;
- non-persisted tool execution details;
- local diagnostics and command-recovery notices.

## 1. Make persisted entries authoritative

Pi RPC events are authoritative for what is happening now. SessionManager
entries returned by `get_entries` are authoritative for what happened after the
operation settles. In this document, “persisted entries” means those authoritative
session entries; under `--no-session` they still exist in memory even though Pi
does not write them to disk.

```text
Pi RPC events ─────────────────────→ transient live draft
                                             │
                                             │ replaced after synchronization
                                             ▼
get_entries → entry cache → active branch → canonical transcript → renderer
```

Do not make live events and persisted entries produce equivalent canonical
operation streams. They are intentionally different sources:

- live events contain deltas, progress, retries, queues, and temporary UI;
- entries contain durable ids, branch parents, final messages, and persisted
  metadata;
- some persisted records have no live message event;
- some live details are never persisted.

The shared boundary is normalized message/tool/activity data and final
rendering—not a synthetic common event history.

### Settlement synchronization

On `agent_settled`:

1. Flush any pending live-tail render.
2. Request entries from Pi.
3. Merge the response into the entry cache.
4. select the path from the root to `leafId`;
5. build a fresh canonical transcript from that path;
6. render the canonical region;
7. clear the live draft and live-tail region only after projection succeeds.

Pi emits `agent_settled` only after retries, overflow recovery, compaction retry,
and queued continuations are exhausted. Message persistence has completed by
then, making it the correct synchronization boundary.

If synchronization fails, keep the finalized live draft visible and mark it as
`[not synchronized with Pi session]` in the diagnostic region. Never discard the
only visible result on a failed fetch or failed projection.

## 2. Maintain an append-only entry cache

Use a buffer-local cache with durable Pi identities:

```elisp
(cl-defstruct (pichat-entry-cache
               (:conc-name pichat-entry-cache-))
  session-id
  session-file
  entries-by-id
  append-order
  last-seen-id
  leaf-id)
```

Use `equal` hash tables for JSON ids and composite keys.

### Initial and incremental fetches

- Initial chat load, manual full repaint, and session switch call `get_entries`
  without `since`.
- Normal settlement calls `get_entries` with `last-seen-id`.
- Merge returned entries by id and update `leafId` even when no new entries were
  returned. The active leaf can move to an already cached entry.
- `last-seen-id` is the last entry in append order, not the active leaf.
- If Pi rejects the cursor, retry once with a full fetch.
- A full fetch replaces, rather than incrementally patches, the cache.

A full repaint must never use `since`; an incremental response may not contain
the parent chain needed without the existing cache.

### Cache validation

Before replacing current state:

- every entry has a non-empty id;
- ids are unique;
- `leafId` is nil only when the cache is empty;
- a non-nil leaf exists in `entries-by-id`;
- each non-nil parent exists when selecting the active branch;
- parent traversal contains no cycle.

Build and validate a candidate cache/transcript before changing the buffer. On
failure, preserve the old cache and display.

A missing parent may occur in malformed or externally edited files. Treat it as
a failed canonical synchronization rather than silently presenting a partial
conversation. The sessions browser can diagnose orphan roots separately.

## 3. Select exactly one active branch

Canonical transcript construction follows `parentId` from `leafId` to the root
and reverses the path. Append order is used only for cache cursors, never as the
conversation order.

The normal chat buffer does not combine abandoned branches. Branch browsing and
labels remain responsibilities of the sessions/tree UI.

Branch/session operations trigger synchronization explicitly:

- `switch_session`, `new_session`, `fork`, and `clone` rebind Pi RPC to a new
  `AgentSession`. After a successful non-cancelled response, immediately advance
  the source generation and invalidate old callbacks/draft/view state; then
  refresh `get_state`, reset the cache with the new `sessionId`/`sessionFile`, and
  perform a full fetch. Ignore transcript-mutating events while the new identity
  is being established; status/diagnostic events may still update their separate
  region.
- A future operation that moves the leaf inside the same session performs at
  least an incremental fetch; `leafId` must be applied even with zero new
  entries.
- Manual repaint performs a full fetch.
- Successful compaction schedules an incremental fetch.
- A displayed custom `message_end` received while the session is idle schedules
  an idle incremental fetch, because extensions can persist a custom message
  without starting an agent run or producing `agent_settled`.
- Any PiChat command that directly persists a visible entry without starting an
  agent run schedules an idle incremental fetch.

Use one synchronization coordinator. Requests are coalesced, and a pending full
sync dominates an incremental one.

## 4. Separate canonical transcript, live draft, and view state

These are different data structures with different lifetimes.

### Canonical transcript

The canonical transcript is rebuilt only from the selected persisted branch.
Top-level nodes are messages and activities. Assistant content is ordered child
data.

```elisp
(:kind message
 :key ENTRY-ID
 :role user-or-assistant-or-custom
 :content ...)

(:kind message
 :key ENTRY-ID
 :role assistant
 :stop-reason STOP-REASON
 :error-message ERROR-MESSAGE
 :content
 ((:kind thinking :index 0 :text TEXT)
  (:kind prose :index 1 :text TEXT)
  (:kind tool
   :index 2
   :tool-call-id TOOL-CALL-ID
   :name NAME
   :args ARGS
   :status done-or-error-or-incomplete
   :output OUTPUT
   :is-error BOOLEAN)))

(:kind activity
 :key ENTRY-ID
 :type compaction
 :summary SUMMARY
 :tokens-before TOKENS)
```

Use `cl-defstruct` for identity-bearing mutable containers and immutable
normalized child descriptors where practical. Constructors copy normalized data
that PiChat owns. Callers treat transcript nodes as read-only.

Canonical state contains no markers, overlays, buffers, timers, folds, or raw
RPC events.

### Live draft

The live draft represents everything since the last successful entry sync:

- authoritative user/custom message events;
- streaming/final assistant messages;
- declared/running/completed tools;
- partial accumulated output;
- successful compaction awaiting entry synchronization.

Local draft identities need only be unique inside one source generation. Use
Pi's `toolCallId` to correlate tool declaration/execution/result events.

`message_end.message` is authoritative for a draft message. Pi extension hooks
may replace message content before listeners observe `message_end`, so final
content replaces streamed previews rather than merely terminating them.

At `agent_settled`, unresolved live tools become `incomplete` for the fallback
preview. Successful entry synchronization soon replaces that preview with the
canonical result.

### View and command state

Keep these outside both transcript models:

- canonical and live region markers;
- tool folds and navigation state;
- point/window preservation;
- projection timers and pending damage;
- queue/status/widget/dialog state;
- submitted-draft recovery records;
- non-persisted tool auxiliary details;
- bounded diagnostics.

Canonical tool view state is keyed by `(entry-id . tool-call-id)`. Live tool
view state is keyed by `(source-generation . tool-call-id)`. At synchronization,
PiChat may transfer an explicitly selected live fold to the canonical tool with
the same `toolCallId`; otherwise use the configured completed default.

## 5. Use one Pi compatibility module

Create `pichat-pi.el` as the only module that understands Pi transcript/session
schemas.

It owns:

- live message/event normalization;
- persisted entry normalization;
- assistant content-part normalization;
- tool-call/result correlation for persisted branches;
- active-branch selection;
- entry-role/type visibility policy;
- compatibility aliases for older supported sessions;
- bounded malformed/unknown-input diagnostics.

`pichat-rpc.el` remains responsible only for JSONL framing, process lifecycle,
request correlation, and dispatch.

### Generic raw event dispatch

Add one backward-compatible `rpc-event` notification carrying every raw Pi event
and its normalized PiChat event symbol. The new backend subscribes only to this
generic stream. Existing specialized consumers may continue to use named events.

Emit `rpc-event` exactly once after the session-state cache is updated and before
the named event. The new renderer must not subscribe to both forms.

This prevents every additive Pi event from requiring another chat-handler
registration and gives compatibility code one place to diagnose unknown data.

### Schema handling rules

- Normalize snake_case event names, camelCase fields, role strings, delta types,
  stop reasons, and old entry aliases at this boundary.
- Distinguish missing, JSON `false`, JSON `null`, and empty values where needed.
  The current decoder collapses false/null to nil, so use `plist-member` at
  minimum and migrate to an explicit false sentinel as one deliberate transport
  change, not piecemeal.
- Validate `contentIndex` and `toolCallId` before correlation.
- Treat `tool_execution_update.partialResult` as accumulated replacement data,
  not a delta. An empty result still replaces stale prior output.
- Do not retain every partial/raw event in transcript structures. The bounded RPC
  event log is the debugging source.
- Never display unknown/custom data using `%S`.
- Normalize unknown content parts to a stable placeholder plus a bounded
  diagnostic.
- Strip image base64 and other opaque payloads when the renderer currently needs
  only a placeholder; retain a bounded descriptor.
- Deduplicate diagnostics by source generation, category, and correlation key.
- Do not signal out of the RPC event handler for malformed additive input.

Record the Pi version/source shape in sanitized fixtures. The initial baseline
is Pi 0.80.6.

## 6. Define persisted visibility explicitly

Some source records cannot have live/history parity unless they are hidden or
synchronized from entries. Use this table as executable policy:

| Pi fact | Live source | Persisted source | Canonical policy |
|---|---|---|---|
| user/assistant message | message lifecycle | `message` entry | visible |
| tool result | execution + message events | `message` entry | owning tool child |
| displayed custom message | `custom` lifecycle | `custom_message`, `display: true` | visible |
| hidden custom message | `custom` lifecycle | `custom_message`, `display: false` | hidden |
| successful compaction | `compaction_end.result` | `compaction` entry | compact activity |
| model/thinking/name/label | responses/state events | metadata entries | metadata only |
| plain extension state | `entry_appended` may expose it | `custom` entry | hidden |
| RPC `bash` execution | no message event | `bashExecution` message | hidden by default |
| branch summary | no normal stream equivalent | `branch_summary` entry | hidden by default |
| unknown entry/role | unknown | unknown | diagnostic, hidden |

Honor `custom_message.display` exactly. Plain `custom` entries are extension
state, may contain private/large data, and never become transcript content.

If a currently hidden row is displayed later, define an explicit presentation
for both live and canonical views first. Do not add a generic raw fallback.

### Compaction

Only successful compaction becomes canonical activity. Aborted/failed
compaction remains an ephemeral diagnostic.

Normalize only fields shared by `compaction_end.result` and the persisted
`compaction` entry. Do not put live-only `estimatedTokensAfter` into canonical
state. Keep the summary available to a details command, but render only a compact
activity line inline.

### Tool auxiliary details

`tool_execution_end.result.details` and fields such as `fullOutputPath` are not
reliably persisted in the later `toolResult` message. Preserve them in a
session-local auxiliary table for the live details UI, keyed by session and
`toolCallId`, but exclude them from canonical transcript semantics and inline
rendering.

After repaint/restart, details UI must say that non-persisted execution details
are unavailable rather than fabricate them.

## 7. Normalize persisted entries directly

Canonical construction walks the selected branch once.

For each entry:

- user message → user node;
- assistant message → one assistant node with ordered normalized content;
- assistant `toolCall` content → tool child at its content-array index;
- following/matching `toolResult` message → update tool child by `toolCallId`;
- tool call with no result by end of branch → `incomplete`;
- orphan tool result → standalone orphan tool node at the result entry position;
- displayed custom message → custom message node;
- successful compaction → activity node;
- metadata/hidden entries → update metadata or skip projection according to the
  visibility table.

Maintain these invariants:

- top-level node keys are unique persisted entry ids;
- assistant content order exactly follows the final content array;
- one `toolCallId` identifies at most one declared tool on the active branch;
- a tool child has at most one authoritative final result;
- duplicate equivalent results are idempotent;
- conflicting duplicates produce a diagnostic and deterministic last-entry
  resolution;
- no canonical node retains raw entry/event plists unnecessarily.

Provide `pichat-transcript-validate` for tests and optional debug assertions.
Validation does not run for every streaming delta.

## 8. Keep live rendering deliberately transient

The live adapter updates a small draft reducer:

```text
message_start             → start draft message
text/thinking delta       → append preview content
toolcall partial/final    → declare/enrich tool
tool_execution_start      → running
tool_execution_update     → replace accumulated output
tool_execution_end        → done/error
toolResult message_end    → idempotently confirm final result
message_end               → replace with authoritative final message
agent_settled             → mark unresolved tools incomplete, then synchronize
```

A tool execution event received before its declaration creates an unattached
live tool. Declaration attaches it by `toolCallId`. An unattached tool remains
visible as an orphan in the fallback preview.

Pi emits `tool_execution_end` and later a `toolResult` message. Applying both
must update one live tool, never duplicate it. The later final message may enrich
or replace content but must preserve user-selected live view state.

### Live-tail rendering strategy

Start with a simple implementation:

- render the whole live tail from draft state;
- throttle high-frequency updates with one buffer-local idle timer;
- retain only the newest accumulated result;
- flush before finalization, synchronization, session switch, and teardown;
- render streamed prose as a plain preview;
- apply full Markdown only to final draft messages and canonical messages.

This limits mutable rendering to the current unsettled run. Optimize individual
live children only if profiling demonstrates a real problem.

## 9. Render user messages only from Pi events

Do not insert an optimistic transcript message on local submission. RPC command
ids and user-message events have no shared correlation id; events may precede
the response; templates/skills may transform content; and extension commands
may succeed without emitting a user message.

On local submission:

1. Clear the editor.
2. Save an ephemeral recovery record containing the exact draft, images,
   request id, source generation, and editor generation.
3. Render user content only when Pi emits user `message_start`/`message_end`.
4. On success response, discard the recovery record; success means accepted,
   queued, or handled, not necessarily persisted.
5. On explicit `success: false`, restore the draft only when the session/editor
   generations still match and the editor is empty.
6. On timeout/process loss, do not restore automatically: Pi may have accepted
   the command before the response was lost. Preserve it in submission history
   and expose an explicit recovery command.
7. Never overwrite newer input or automatically resend an ambiguous submission.

Extend `pichat-rpc-prompt` with a final optional error callback without changing
existing positional arguments. Tag synthetic request failures with a
machine-readable kind (`timeout`, `process`, or `cancelled`); never classify them
by matching error text.

Steering, follow-up, extension-originated, transformed, and external user
messages all use the same authoritative event path.

## 10. Use coarse, explicit buffer regions

Use four logical regions:

```text
header
canonical transcript
live tail
diagnostic/status
prompt/editor
```

Initially maintain markers only for region boundaries, not every transcript
node. Whole canonical projection occurs after synchronization; whole live-tail
projection occurs on throttled draft updates.

Canonical nodes and tools receive text properties such as:

```elisp
pichat-node-key
pichat-tool-key
pichat-content-kind
```

Navigation uses property changes and canonical/live lookup tables. Tool details
look up structured state by the property key rather than storing large objects
in buffer text properties.

### Emacs buffer invariants

- Canonical data contains no markers or overlays.
- Centralize marker construction, insertion types, and separator ownership.
- Do not rely on insertion types alone when adjacent boundaries coincide;
  explicitly reset affected boundaries after edits.
- Projection edits inhibit read-only/modification hooks and do not enter
  transcript changes into user undo history.
- Preserve buffer modified state, point, selected-window point, and window start.
- Never call user-facing commands or start timers inside an edit transaction.
- Remove owned overlays/properties and set obsolete markers to nil on reset.
- Install handlers once per buffer/session object and unregister them with
  `pichat-off` on backend/session-object change and `kill-buffer-hook`.
- Cancel every projection/synchronization timer on teardown.
- Deferred callbacks capture synchronization/source generations and become
  no-ops when stale.

A permanent raw-event handler dispatches into the buffer's current source
generation; it must not capture a generation that becomes stale after repaint.

## 11. Keep rendering pure and policy-driven

`pichat-render.el` consumes normalized canonical/live nodes, never raw Pi plists
or entries. It returns display fragments plus logical subranges.

Pass an explicit immutable render context containing:

- thinking visibility;
- tool default view;
- argument/output truncation limits;
- faces and placeholder policy;
- lifecycle/diagnostic visibility.

Pure render functions must not read dynamic buffer/global state implicitly.
Changing a display option rebuilds the context and reprojects the relevant
region without refetching or renormalizing Pi data.

The renderer owns:

- user/custom styling;
- thinking face and visibility;
- image/unknown placeholders;
- assistant Markdown policy;
- tool header, args, output, status, and error face;
- incomplete/orphan presentation;
- inter-node and intra-message whitespace;
- logical properties needed for navigation/details.

Re-rendering is idempotent. Tests assert a documented whitelist of owned
faces/properties rather than incidental font-lock properties that vary by Emacs
or package version.

## 12. Define completed error presentation

Assistant stop metadata is an annotation owned by its assistant node. Tool
errors are status owned by the tool child. Do not create duplicate top-level
error nodes for the same fact.

Minimum presentation:

```text
[assistant aborted: MESSAGE]
[assistant error: MESSAGE]
[assistant stopped: length]
[tool:NAME error]
[tool:NAME incomplete]
[tool:NAME orphan result]
```

Render at most one assistant annotation, with precedence `aborted`, `error`, then
`length`. Use `errorMessage` where available. Normal `stop` and `toolUse` need no
annotation.

Retry, queue, approval, process, RPC, and extension errors are ephemeral. Render
them only in the dedicated diagnostic/status region, never between transcript
nodes. Clear transient lifecycle notices at settlement. A terminal process error
may remain in that region and is excluded from transcript parity.

Approval prompts/decisions are UI state. Historical rendering shows only the
persisted final tool success/error, never a fabricated approval sequence.

## 13. Synchronization and generation safety

Maintain separate monotonically increasing values:

- source generation: changes when Pi session identity changes;
- sync generation: changes for every synchronization request;
- editor generation: changes when prompt text is edited/replaced.

A synchronization callback applies only if:

- the buffer is live;
- the session object still matches;
- `sessionId` and `sessionFile` still match the captured identity;
- source generation matches;
- sync generation is still current.

Use `sessionId` even when `sessionFile` is nil. Never erase a buffer before a
candidate cache, active branch, transcript, and rendered fragment have all been
built successfully.

An interactive repaint requested while Pi is streaming/compacting/retrying is
coalesced into one deferred full synchronization at `agent_settled`. Do not
replace canonical/live state halfway through a message stream.

## 14. Proposed file boundaries

### `pichat-rpc.el`

Transport only:

- strict JSONL/process/request handling;
- session process-state cache;
- generic raw `rpc-event` plus backward-compatible named events;
- machine-readable local request failure kinds.

### `pichat-pi.el`

Pi schema compatibility:

- event/message/entry normalization;
- visibility policy;
- active-branch selection;
- compatibility aliases;
- bounded diagnostics.

### `pichat-transcript.el`

Pi-independent data/state:

- entry cache;
- canonical transcript structures/construction inputs;
- live draft structures/reducer;
- transcript validation and semantic snapshots;
- canonical/live lookup indexes.

It contains no buffers, markers, faces, timers, or user options.

### `pichat-render.el`

Pure display data:

- immutable render context;
- normalized node-to-fragment rendering;
- Markdown/placeholder/tool formatting policy;
- owned logical properties/subranges.

It does not parse raw Pi data or edit the target chat buffer.

### `pichat-chat.el`

Emacs interaction/projection:

- region projection and markers;
- synchronization coordinator;
- handler/timer lifecycle;
- point/window/undo preservation;
- tool navigation/folds/details;
- prompt/editor and submission recovery;
- diagnostic/status region.

Dependencies remain one-way:

```text
pichat-chat → pichat-rpc
           → pichat-pi → pichat-transcript
           → pichat-render → pichat-transcript
```

Lower layers return values/diagnostics; they do not callback into
`pichat-chat`.

## 15. Implementation sequence

The existing renderer need not constrain the new design.

### Step 0: Freeze contracts in tests

Define and test:

1. entry-cache replacement/merge/cursor rules;
2. active-branch validation;
3. canonical node schema and persisted visibility table;
4. live draft transitions;
5. source/sync/editor generations;
6. render-context and owned property policy;
7. canonical/live/status region invariants;
8. command rejection and ambiguous-failure recovery.

### Step 1: Add sanitized fixtures

Cover:

- thinking/prose/tools in mixed order;
- parallel tools and errors;
- aborted/incomplete/orphan tools;
- images and unknown content;
- multiple assistant turns;
- steering/follow-up/custom messages;
- branched sessions and moved leaves;
- compaction and metadata entries;
- hidden `bashExecution`, branch summary, and extension state;
- current Pi 0.80.6 plus an older supported session shape.

Fixtures may be derived from `/home/mojo/.pi/agent/sessions`, but committed files
must be minimal and manually sanitized. Tests never read that absolute path or
include original prompts, paths, credentials, timestamps, large output, base64,
or extension-private data.

### Step 2: Add transport compatibility

- generic `rpc-event` dispatch;
- machine-readable synthetic failure kinds;
- callback/generation tests;
- no renderer changes yet.

### Step 3: Implement canonical entry rendering

- `pichat-pi.el` normalization/visibility;
- entry cache and active branch;
- canonical transcript builder;
- pure renderer and whole canonical projection;
- switch manual repaint to this path.

### Step 4: Implement live draft/tail

- authoritative user/custom messages;
- assistant deltas/final reconciliation;
- tool declaration/progress/result reconciliation;
- throttled whole-tail rendering;
- settlement synchronization replacing the tail.

### Step 5: Add command/status interaction

- rejected/ambiguous draft recovery;
- diagnostic/status region;
- fold transfer and details lookup;
- option-driven reprojection.

### Step 6: Replace and delete old paths

Choose the backend once per buffer. A debugging switch may change it only by
unregistering handlers, cancelling timers, advancing generations, clearing view
state, and performing a full synchronization. Never run old/new render handlers
simultaneously.

After acceptance tests pass, remove repaint-only/live-only mutation functions,
obsolete marker tables, and migration switches. Update `README.md`.

### Implementation status

All migration steps are complete:

- sanitized current and legacy-shape persisted-session fixtures and protocol
  compatibility tests exist;
- generic RPC event dispatch feeds a transient normalized live draft;
- full and incremental entry caches select only the persisted active branch;
- canonical and live renderers use explicit pure rendering contexts;
- canonical, live-tail, status, extension-widget, and prompt regions are
  projected separately and transactionally;
- live updates are throttled and settlement synchronization is generation-safe;
- source rebinds cancel stale state and synchronization requests, timers, and
  callbacks;
- prompt rejection and ambiguous-failure recovery preserve user drafts;
- running tools default to expanded output while all completed fallback states
  use the configured completed display; only explicit fold choices transfer;
- tool fold state and logical viewport anchors survive reprojection;
- compatibility diagnostics are deduplicated, bounded, and projected outside
  transcript regions;
- display-option changes reproject normalized state without refetching;
- live-only tool details have explicit pre/post-synchronization availability;
- legacy direct event mutation, append rendering, and historical repaint paths
  have been removed.

## 16. Acceptance tests

### Canonical identity test

1. Feed a full `get_entries` fixture into a fresh cache.
2. Build/select/render the canonical transcript.
3. Feed the same entries through manual repaint.
4. Assert identical semantic snapshots and normalized buffer presentation.

There is no separate historical rendering implementation to compare.

### Settlement test

1. Feed RPC events through the live draft.
2. Assert expected transient live-tail states.
3. Feed the authoritative incremental `get_entries` response.
4. Synchronize.
5. Assert the live tail is empty and canonical output equals fresh full repaint.

### Required edge cases

- valid incremental merge and invalid-cursor full fallback;
- leaf movement with zero new entries;
- duplicate/missing ids, unknown leaf, missing parent, and parent cycle;
- stale sync callback after newer sync/session switch/buffer death;
- deferred/coalesced repaint during a stream;
- final-message repair of missing/duplicated/reordered deltas;
- multiple content indexes and final image/unknown placeholders;
- tool event before declaration;
- parallel tool completion order;
- `tool_execution_end` followed by `toolResult` without duplication;
- unresolved tool fallback and persisted incomplete reconstruction;
- orphan and conflicting duplicate results;
- authoritative transformed/duplicate/extension user events;
- explicit rejection restoring only an unchanged empty editor;
- timeout/process loss preserving explicit recovery without resending;
- successful extension command with no user message event;
- displayed custom message persisted while idle synchronizing without
  `agent_settled`;
- successful/aborted/failed compaction policy;
- hidden `custom`, hidden custom message, `bashExecution`, and branch summary;
- unknown protocol additions producing bounded diagnostics, not raw dumps;
- live-only tool details never changing canonical inline rendering;
- whole-tail timer flush/cancel lifecycle;
- handler unregister and buffer-kill cleanup;
- region marker boundaries, adjacent edits, undo isolation, and modified-state
  preservation;
- thinking/fold/render-option changes without source refetch;
- lifecycle notices outside transcript regions and cleared at settlement;
- Markdown owned-property whitelist and idempotent reprojection.

Semantic snapshots exclude entry-cache implementation order, markers, overlays,
timestamps, durations, live draft state, auxiliary details, diagnostics, and
user-selected folds unless a test specifically targets them.

## 17. Core decision

Do not make live RPC events another durable transcript authority, and do not
synthesize historical RPC events.

> Persisted active-branch entries define the settled transcript. RPC events
> define only the live draft. Successful synchronization atomically replaces the
> draft with canonical entry rendering.

This removes durable live-message identity reconciliation, makes branch behavior
explicit, handles Pi's source asymmetries honestly, and ensures repaint parity
through one canonical construction/rendering path.

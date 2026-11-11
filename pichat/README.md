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

Pi skill invocations in user messages appear as compact `▶ [skill] name`
headers, with any trailing request shown as a separate user block. On a header,
press `RET` or `TAB` (or click) to expand the exact skill block and request;
repeat to collapse it. Press `w` on the header to copy the original full Pi
message (ordinary region copying copies only visible text). Explicit choices
survive repaint of the same source but reset on source rebinding. This is
display-only: Pi's message, canonical export, and saved session file remain
unchanged. Mixed image/text messages and unrecognized
skill markup retain the ordinary user display.

Ordinary submitted user messages fold after five visual lines at the narrowest
window displaying the chat. A long message ends in `…`; `RET`, terminal or
graphical `TAB`, or a click within the read-only block toggles it. Expanded
messages offer **Show less**. Short messages need no disclosure. Drafts always
remain fully expanded, including history recall, fork restoration, submission
recovery and compose-editor application. Only authoritative Pi user-message
events create submitted blocks; sending does not fabricate a local message.
Explicit choices survive streaming, settlement, same-source repaint and resize,
but reset on source rebinding (see `GLOSSARY.md`). Skill disclosures remain
separate; image indicators are never hidden by prose folding.

On a long submitted block, `w` copies the complete original message text without
display bars (not image data). With optional Evil integration, use `g y` in Normal
state; `w` retains word motion, and `RET`/`TAB` toggle only on disclosures. Chat
folding uses non-destructive display overlays: ordinary region copying includes
hidden source text and display bars, **not** the ellipsis or Show less control.
This differs from skill-header region copying described above. Canonical export,
messages sent to Pi, and saved session files are unchanged.

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
`pichat-chat-activity-group-display` defaults to `collapsed`, which folds
activity groups, including the live tail. Set it to `latest` to keep current
live tail activity open while folding older or settled groups, or `expanded`
to open all groups. An explicit group choice overrides any policy.
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

## Chat buffer names

Chat buffers use `*pi:project:7*` for project runtimes and `*pi:8*` for
global runtimes. The integer identifies the runtime, not its loaded Pi session
(see `GLOSSARY.md`). Numbers increase across all scopes for this Emacs lifetime
and are not reused. Switching, forking, cloning, or reopening the same runtime's
chat preserves its number; restarting Emacs resets the counter.

## Persistent chat header

The fixed header stays visible while scrolling or composing. It shows the
**runtime working directory** (not necessarily the Emacs-visible path; see
`GLOSSARY.md`) on the left and **context-window occupancy** on the right.
Each displayed window adapts independently: paths shorten, optional information
is omitted, and token counts take precedence over optional information. Only
exceptionally small windows clip context itself. This works in desktop splits and tablet/phone-sized
windows without a wrapping dashboard, at the cost of one fixed display row.
Unknown/unavailable usage is explicit; accumulated request totals are labelled
**Requests**, never context occupancy. Warning/error faces apply above 70%/90%.

There is no duplicate scrolling title or mode-line context segment. The mode
line retains model/thinking controls, runtime state, names and queue/UI indicators.
Usage still updates at existing state/settlement/compaction boundaries, not by
polling or on every streamed token. The header does not change context accounting.

Two boolean options control the built-in presentation:

```elisp
(setq pichat-chat-header-show-directory t
      pichat-chat-header-show-percentage nil)
```

Context counts omit the `Context` prefix and percentage by default. The latest
extension `usage` status appears beside them when it fits, instead of in the
buffer body. A leading `codex `, `claude `, or `go ` is omitted; the tooltip
retains the original status text. Other extension statuses remain in the body.

Set either option to nil to hide it even when space is available. Set them globally
or buffer-locally; width fallback is automatic, with no device breakpoints.
The header is a normal `header-line-format`, which a mode hook may override.

### Optional cached information

`pichat-chat-header-functions` is a global or buffer-local ordered list of
functions taking `(SESSION WINDOW)`. Each returns nil when unavailable or a
plist: `:id` (unique symbol), `:text` (full string), optional `:compact` (short
string), `:side` (`left`, the default, or `right`), and `:priority` (number,
default 0). Right-side segments appear beside context with the same middle-dot
separator as extension usage. Higher priorities appear/admit first; ties retain
list order. Strings must be single-line, at most 256 characters.
Faces and tooltips are preserved; errors or invalid records omit only that
segment. Optional segments can never displace context, regardless of priority.

Example with a **mock account-wide cache**, not a provider/quota integration:

```elisp
(defvar my-pichat-plan-left nil) ; nil = unavailable; e.g. set to 62
(defun my-pichat-plan-header (_session _window)
  (when (numberp my-pichat-plan-left)
    (list :id 'plan-left
          :text (format "Plan left %d%%" my-pichat-plan-left)
          :compact (format "Plan %d%%" my-pichat-plan-left)
          :priority 10)))
(add-hook 'pichat-chat-header-functions #'my-pichat-plan-header)
;; After updating the cache asynchronously, request redisplay for each affected
;; runtime (SESSION is its existing pichat-session object):
;; (pichat-chat-refresh-header session)
```

Callbacks run during redisplay against cached data only: **no network, RPC,
file access, or buffer edits**. Acquisition, async cancellation and stale-result
rejection belong to the integration, not the header. `pichat-chat-refresh-header`
requests redisplay without editing transcripts or fetching anything.

Cache ownership must match the data: account-wide allowances can survive source
changes (key by account/provider if there are several); runtime-specific values
must be keyed by the supplied runtime, not the selected chat. Source-specific
values must be invalidated on every source rebinding, including A → B → A.
An integration can capture the existing public source guard with
`pichat-chat-draft-capture` in the owning chat, and return nil / reject async
results unless `pichat-chat-draft-current-p` still holds. Using that guard for
cached presentation does not edit or submit a draft. Buffer-local configuration
alone does **not** make a cache source-scoped. Subscription allowance must stay
labelled separately from context-window occupancy. No quota backend, timers,
cache registry, or general widget framework is supplied.

## Markdown source and rendered responses

The interactive chat buffer keeps assistant Markdown as exact visible source.
Completed assistant prose receives theme-aware Markdown faces when
`markdown-mode` is available, but PiChat does not replace links, pipe tables, or
other markup with custom inline displays. Streaming prose remains unfontified
until its existing final-message boundary. Chat buffers use
`visual-line-mode` and wrap at the window edge without `visual-fill-column`.
Thinking and tool activity keep their independent folding behavior.

Use `C-c C-h` or `M-x pichat-chat-view-response` for a rendered, read-only
snapshot of a settled canonical assistant response. If point identifies a
canonical assistant message, PiChat selects that response; otherwise it selects
the latest canonical assistant message. Selection and extraction read the
canonical transcript model rather than folded, truncated, fontified, or
overlaid buffer display. The snapshot concatenates that response's exact prose
segments in source order and excludes thinking, tool calls, and tool output. A
response with no prose opens an explicit empty-response view.

Native Emacs response-view keys are:

- `g` — explicitly refresh and rerender the same canonical response at the
  current window width
- `n` / `p` — show the next / previous settled assistant response with prose
  from the same canonical transcript, skipping tool-only messages; boundaries
  leave the current snapshot unchanged
- `t` — return to the currently displayed response in its originating chat
- `w` — copy the snapshot's exact canonical Markdown
- `q` — close the response view
- `RET`, `w`, or `?` on a rendered link — open, copy, or describe its destination
  (in Evil Normal state, `w` and `?` keep Vim word motion and backward search;
  copy the link using the local `SPC m y` menu or its `M-x` command)

Response views are snapshots and do not update automatically while an assistant
streams. Navigation reuses the same view buffer and starts at the beginning of
its next response; `g`, `t`, and `w` then refer to that response. Refresh,
navigation, and return validate both the source identity and assistant node;
if the chat dies, rebinds, or the response disappears from the canonical
transcript, the existing snapshot remains readable but those operations are
rejected. Return also requires that the response is still projected in chat. Copying exact
Markdown remains available from the snapshot.

Assistant Markdown and embedded HTML are untrusted. PiChat uses the configured
`markdown-mode` conversion boundary, parses the result with libxml, retains only
a strict inert element and attribute allowlist, and renders through isolated SHR
handlers. Active or resource-bearing HTML is discarded, remote images are never
fetched, unknown elements are omitted, and unrelated SHR extension renderers are
not invoked. Only explicitly configured URL schemes in
`pichat-response-view-safe-link-schemes` (`https`, `http`, and `mailto` by
default) may be opened. Disallowed destinations remain available for explicit
copying or inspection but cannot be opened by the view. If Markdown conversion,
HTML parsing, sanitization, or SHR rendering fails—or the required conversion
support is unavailable—the view shows a labelled exact-Markdown fallback rather
than losing the response.

## Settled chat artifacts

In a chat, put point on a settled assistant prose artifact and invoke Embark
(`SPC a` in this configuration). `SPC m A` (or
`M-x pichat-chat-select-visible-artifact`) places Avy hints on visible artifact
starts and opens the selected artifact's Embark menu. Cancelling Avy leaves the
prompt and point untouched. Active regions take precedence; prompts, tool
output, streaming prose, and rendered response views are not targeted. The
optional integration lives in `user/pichat.el` and requires Embark and Avy; the
PiChat package does not require either.

- Complete backtick/tilde fences of at least three characters: `c` copies the
  exact body (default), `f` copies the exact fenced source, `e` opens a separate
  editable buffer using the fence language's mode, and `r` explicitly runs the
  body. Mode selection uses `markdown-code-lang-modes` and
  `markdown-get-lang-mode` when available, with built-in Python, JavaScript,
  shell, and Emacs Lisp aliases as fallbacks; unknown languages use `text-mode`.
  This only selects an editing mode; it does not add an execution runner.
  Fence lines are included in selection, not in the body. Unclosed and
  cross-prose fences are ignored.
- Simple `[label](destination)` links: `o` opens using the configured browser,
  `x` opens in an external browser; both allow only `http`, `https`, or `mailto`
  by default (shared with the rendered-view scheme setting). `c` copies and
  `?` inspects the destination. Complex nested/escaped Markdown
  links are deliberately not recognized.
- Pipe tables with a Markdown alignment row and equal-width rows: `c` copies
  exact source; `p` opens a separate, read-only `markdown-mode` buffer and runs
  `markdown-table-align` on its display copy. The preview adds missing outer
  pipes when needed; it never changes the chat or the source copied by `c`.
  Without `markdown-mode`, or if alignment fails, the preview retains exact
  source instead. Escaped pipes and simple backtick code spans are counted as
  cell contents; ambiguous tables are ignored.
- Single-line `$...$`, `$$...$$`, `\\(...\\)`, and `\\[...\\]`: `c` copies
  exact LaTeX; `p` opens a read-only source preview, not a TeX renderer.
  Currency-like dollar amounts are excluded conservatively.

Table and LaTeX previews retain their appropriate Markdown or plain-text
presentation; `q` closes the preview and returns to its origin without leaving
another copy behind. The separate code-edit buffer remains an ordinary editor.

Run supports Python (`python`, `python3`, `py` -> `python3`), JavaScript
(`javascript`, `js`, `node` -> `node`), shell (`sh`, `shell`, `bash` -> `sh`),
Docker-backed Mermaid (`mermaid`, `mmd`), and in-process Emacs Lisp
(`elisp`, `emacs-lisp`). Missing or unknown language
prompts for a runner; selecting an editing mode does not select a runner.
Python, JavaScript, and shell runners use an argv-based temporary script on the
captured execution host: locally for a local runtime, or through its captured
SSH/TRAMP transport and runtime working directory for SSH. A locally mounted project with SSH Pi
still runs on the SSH host. Captured code remains runnable after its chat switches
sources, stops, or closes, including from a delayed Embark action. Run never
substitutes the currently selected chat's host or directory; an unavailable
captured destination fails without a local fallback. Result handoff is separate:
`s` still requires the original chat source; otherwise copy the report.

Runner specifications declare a `:context` policy: `origin-host` for captured
host/cwd execution, `local-independent` for local temporary-workspace execution
(such as Mermaid), or `emacs` for in-process evaluation with SSH-origin rejection.
New runners must declare a policy; missing or unknown policies are rejected.
The shared dispatcher supplies the selected context; each runner retains its own
execution, permission/download, resource-limit, and cleanup controls. Its `:start`
function creates and sets up any result view before returning, so the existing
result API retains the captured handoff destination independently of execution. The result view identifies the host, cwd, code,
argv, merged stdout/stderr and exit status. Missing interpreters are checked
on the execution host. The default timeout is 120 seconds
(`pichat-artifact-runner-timeout`); `q` stops a running process and removes its
temporary script.

`pichat-artifact-runner-output-limit` (default 65,536 characters) bounds the
live preview, **not** the process. The independent
`pichat-artifact-result-share-limit` (default 4,000 characters) bounds each
section inserted into the draft. Output exceeding **either** limit spills to
a private file without stopping the process or shortening the view preview:
for example, 10,000 characters are shown in full in the view, but the agent
receives a 4,000-character excerpt and a path to the entire output. At exactly
the smaller threshold no file is needed. Limits are captured at the start of
each run so changing customization mid-run cannot leave a truncated report
without a file. Once the run finishes, the bounded report contains an excerpt
and a path Pi can read: local runtime-accessible temporary storage or the
owning SSH host's `/tmp` (a native remote path, not a TRAMP filename).
Output files remain after `s`, `q`, and session closure so Pi can read them; they are not managed or deleted by PiChat, and retention depends on the
OS's temp cleanup. Delete sensitive output explicitly when no longer needed.
Set `pichat-artifact-runner-output-directory` for a mapped/shared alternative;
unmapped local wrapper/container paths are not advertised as Pi-readable.

Spill files are private (0600), including files needed only because of the
agent-sharing limit. `pichat-artifact-runner-output-max-bytes`
(default 32 MiB) caps captured file size without killing the run: the report
explicitly marks a file **incomplete** and counts discarded bytes. A failed
capture or publication leaves a bounded preview and an error, never a false
Pi-readable path; a failed local staging file is shown only in the result view
for inspection and retained until OS temp cleanup. SSH output travels through
Emacs once before publication to remote storage; high-volume SSH runs can
therefore incur network overhead. `s` waits for completion and publication;
`w` can copy a labelled partial report while the run is active. Nothing is
sent automatically.

Mermaid fences render only on explicit `r`, using **local Docker beside Emacs**,
including when the originating Pi runtime uses SSH. No Docker, Mermaid, or
project access is needed on the remote host. Install Docker locally; the default
image is `ghcr.io/mermaid-js/mermaid-cli/mermaid-cli:11.12.0`. Customize
`pichat-artifact-mermaid-image` to use another pinned version or digest.
If the image is missing and the daemon is reachable, PiChat asks before
asynchronously downloading it. Declining leaves the source unchanged. Image
pulls use host network access; the renderer container itself has no network.
Docker checks, downloads, rendering, and cleanup are asynchronous, with bounded
logs in the result view. Each execution stage uses the runner timeout; downloads
have a five-minute timeout. Docker itself is never installed automatically.

The Docker daemon must be local (a Unix socket); remote Docker contexts and
`DOCKER_HOST` overrides are rejected. Only a private temporary workspace is
mounted, not the project or home directory. CPU, memory, process count, PNG
size, and dimensions are limited. The container is created before being started,
so cancelling during creation can wait for that operation before removing it.
Cleanup continues asynchronously after quit. If Docker does not respond,
PiChat reports the owned container and workspace for manual inspection instead
of claiming cleanup succeeded. Forcefully exiting Emacs can interrupt cleanup.
These controls are defense in depth, **not a sandbox guarantee**.

The result view shows the local PNG path and, where supported, an image preview.
A successful PNG is retained in Emacs's temporary directory after closing or
sharing the view, until OS cleanup or explicit deletion. Disposable input,
configuration, and intermediate output are removed after container cleanup.
Failed publication removes its incomplete retained copy. There is no separate
SSH preview copy and no automatic remote upload. For SSH-origin chats, `s`
shares source/status/diagnostics but does not advertise the local PNG as a remote
path. For local runtimes, a resolved PNG path can appear in the report. Sharing
never attaches an image or sends the draft automatically; remote image
publication/attachment is a separate, currently unimplemented action.

Emacs Lisp instead evaluates synchronously **in this running Emacs process**,
with access to its live packages, variables, and functions; it does not need
`emacsclient` or a daemon. Forms use lexical evaluation in a private temporary
buffer with the chat's cwd, not in the chat buffer. No major-mode hooks or
file-local variables are applied to that private buffer. The result view
shows cwd, submitted code, output written via `print`/`princ` (not minibuffer
`message` calls), and the last value, error, or quit status. Read/evaluation
errors include the condition type where useful; output printed before a failure
is retained in both the view and the bounded report for the agent. Output and
printed values are bounded by `pichat-artifact-elisp-output-limit`. This synchronous runner
has **no timeout**: an infinite loop can block Emacs, and side effects are not
rolled back on error. Emacs Lisp is rejected for SSH Pi sessions rather than
silently executing on the wrong machine; it remains local to this Emacs.

Subprocess reports shared with the agent use a compact handoff: interpreter
basename and outcome, the executed script snapshot, and combined output.
Script and output sections are fenced and bounded for sharing. An output
excerpt is labelled up front with its full-output path when available;
incomplete capture and publication failures remain explicit. Host, cwd, and
routine byte counts stay in the result view instead of repeating session
context in the report. A long script retains an explicit truncation marker;
source-file publication is not currently provided.

Runner results use Emacs's normal `pop-to-buffer` display rules (which can
create a split); after invoking `r` through Embark, focus follows the result
window. Quitting closes the owned view without disturbing unrelated windows. In every runner result view, `s` inserts a bounded labelled report
into the originating chat's existing draft for review, closes the result, and
returns to the chat; send the draft normally to share it with the agent. A
failed share leaves the result open. Nothing sends automatically or creates a
Pi tool result. `w` copies the report, including when that chat is gone or has
switched sources; `q` closes the view. Under Evil Normal state, `s` shares,
`g y` copies, and `q` closes; `w` retains Vim word motion. Customize
`pichat-artifact-result-share-limit` to change the per-section prompt limit
(`pichat-artifact-elisp-share-limit` remains an alias). **None of these runners is a sandbox:** model
code can access files, credentials, and the network or modify your system.
Elisp also has your running Emacs's privileges and state. Pi tool permissions
do not apply. Only choose `r` for code you trust.

## Module dependency direction

`pichat-backend.el` defines the backend contract, capability checks,
and backend-qualified scope identity without requiring Pi RPC. Sessions own a
backend object and opaque backend state; legacy and ordinary sessions default
to `pi`. `pichat-backend-pi.el` is a thin delegation
to the existing RPC functions. Shared lifecycle, prompt, abort, state,
transcript, stats, and owned-request cancellation paths dispatch through this
boundary, while Pi-only controls are rejected by capability checks before side
effects.

`pichat-chat.el` is the mode and event-orchestration layer. It consumes focused
presentation modules, but those modules do not require or mutate the chat
layer's state implicitly. `pichat-markdown-fontification.el` is a fail-open,
fontification-only component: it copies face runs from a temporary
`markdown-mode` buffer onto exact completed prose and has no chat, link, table,
overlay, or cache dependency. `pichat-response-view.el` owns secure rendered
response snapshots and depends on the canonical selection API plus the common
read-only view lifecycle; chat orchestration supplies source validation and
origin callbacks explicitly, so the response module never requires
`pichat-chat.el`. `pichat-chat-input.el` owns prompt submission,
history, recovery, and pending/in-flight attachment coordination without
requiring the chat layer; orchestration supplies prompt markers and compact
status presentation. `pichat-attachments.el` owns bounded image records, file
encoding, wire conversion, and optional acquisition adapters without knowing
about chat buffers or transcript state. `pichat-chat-diagnostics.el` owns
conservative transport/Pi-response classification, bounded session diagnostic
records, safe summaries, explicit raw inspection, and setup launch policy; it
does not depend on the chat mode. `pichat-chat-notices.el` owns notice
acknowledgment and narrowly captured recovery without editing chat buffers or
deleting retained records; RPC and chat orchestration supply lifecycle boundaries.
`pichat-command-catalog.el` supplies shared command/template/skill discovery,
validated records, and ordered completion metadata for both the command picker
and CAPF, without owning a cache or action policy.
`pichat-chat-completion.el` owns the source-generation-scoped slash-command
cache and draft completion logic; chat orchestration supplies source identity
and prompt boundaries, and stale RPC callbacks cannot replace a rebound
source's cache. The picker retains its separately captured runtime/source
context and immediately submits after command selection and argument entry;
CAPF only inserts into the draft. Both use exact command names as action keys
and source/description annotations as display metadata, without requiring
Consult or Embark. `pichat-tool-enrichment.el`
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
`pichat-chat-navigation.el` owns logical turn/active-target selection, canonical
assistant-response selection and exact prose extraction, expanded prompt-editor
lifecycle, and canonical-model Markdown serialization without requiring the
chat layer; orchestration supplies source tokens, markers, block tables, and the
prompt replacement callback. `pichat-archive.el` owns exact-RPC
capability discovery, helper provenance, process execution, and protocol
normalization without depending on Consult or querying SQLite; `pichat-consult.el`
consumes only normalized archive records. Archive/Consult browsing is loaded on
demand, not by requiring `pichat` or initializing a chat or Session History.
Basic saved-session completion bypasses both modules. Rich browsing loads the
adapter at its availability check; archive discovery is independently autoloaded
and does not depend on Consult presentation. Embark actions register when both
packages have loaded, in either order. This is a dependency boundary, not a
startup-speed claim. Session History and saved-file services still share
`pichat-sessions.el`; launch/reconfiguration UI remains in `pichat.el`.
The chat layer owns event orchestration
and source-scoped presentation metadata (tool/activity/skill choices, auxiliary
details and enrichment). A shared reset/snapshot/restore boundary owns those
tables; full and focused projection transactions retain their distinct text,
marker and overlay rollback policies. Canonical caches remain chat-owned.
Canonical transcript and Pi reducer modules remain independent authorities and
never consume this ephemeral state. `pichat-diagnostic.el` supplies a pure shared
record vocabulary and formatting helpers. Domain-owned collectors supply cached,
source-validated sections to the unified diagnostics inspector; they do not
acquire a runtime or UI dependency through that shared record module.

Job storage/admission lives in `pichat-job-core.el`; `pichat-job-executor.el` owns
runtime orchestration, and `pichat-job-launch.el` captures/prepares ordinary launch
settings. `pichat-job-followup.el` supplies pure snapshot/event/prompt policy without
requiring the store, executor or UI. Manual, scheduled and lifecycle submissions
share the same run constructor, queue and admission path. Follow-up dispatch joins the
originating transition's atomic store transaction; it is not a UI change-hook side
effect. Bounded immutable context capture is shared with continuation, while their
authorization prompts remain distinct. `pichat-job-schedule.el` validates versioned
native timing data and computes the next occurrence from an explicit reference
instant; it owns no store, clock or timers. The executor owns one-shot wakeups;
core consumes an occurrence and creates its ordinary run in one transaction.
`pichat-jobs.el` owns the shared composer: explicit origin/record identity,
detached staging, per-picker/final-action ownership and nested-editor return.
Capture and admission remain separate from that presentation lifecycle.
`pichat-job-schedule-ui.el` supplies the compact saved-job timing Transient and
shared absolute-time picker. `pichat-job-conversation.el` validates exact live
conversation captures and attributable outcomes without acquiring or stopping a
runtime. The executor retains that live authority only for this Emacs lifetime;
stored provenance is not authorization to reconnect.

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

The Transient starts with no switches, which selects the same runtime profile
as ordinary `pichat`. It does not restore saved switch values, preventing an old
ephemeral choice from being repeated accidentally. Direct Transient launches
use `pichat-launch-display-chat-function` to display the chat (current tab by
default); manager-initiated launches retain the manager's display policy. This
repository configures direct launches to use the same optional Bufferlo-aware
project-tab policy as the manager. Ordinary `pichat` retains its current-tab
display behavior.

| Key | Choice | Effect |
|---|---|---|
| `g` | Global | Use global instead of current-project scope |
| `n` | Independent runtime | Start an additional runtime instead of reusing the preferred one |
| `t` | Target | Use inferred, local, or a configured runtime target |
| `e` | Ephemeral | Start Pi with `--no-session`; implies independent |
| `m` | Model | Stage this launch's model: the preset's model, Pi's default, a listed or entered ID, or a choice when launching; a concrete or deferred choice implies independent |
| `p` | Preset | Choose a named tool/prompt preset; explicit selection implies independent and restores its model |
| `x` | Tools | Choose that preset's built-ins, extension tools and direct MCP tools for a new independent runtime |
| `s` | Conversation | Default, new independent conversation, existing chat route, or select a saved session |
| `r` | Reconfigure this runtime | From its owning chat, enter a separate captured-runtime menu; never implied by launching |
| `c` | Save preset as… | Save the selected preset, Tools and model under a name; see [Saving presets from the launcher](#saving-presets-from-the-launcher) |
| `RET` | Open / launch | Execute the normalized profile summarized in the action label |

The switches compose. For example, `g e`, then `m` **Choose when launching**,
creates an independent global, ephemeral runtime and asks for its model at `RET`. `n` alone creates an independent
persistent/default-model runtime in the current scope. `g` alone opens the
preferred global runtime. With no switches, PiChat opens the preferred current
runtime. The picker starts at `default (manual)`; this policy reuses the
preferred runtime if one exists, even when that runtime was created with a
different preset. Choosing a named preset (including `manual`) starts an
**independent** runtime without stopping or changing the preferred runtime.
Choose `default` again to restore normal reuse, unless another switch requires
an independent runtime. The manager's Preset column and the chat's `P:name`
mode-line label identify the captured startup choice. Presets belong to Emacs
runtimes, not saved Pi transcripts. Changing a retained runtime's preset or
Tools requires an explicit guarded restart, not a change to its live process.

`s` retains its choice only while this launcher is open. **Default** preserves
ordinary reuse; **New conversation** launches a fresh independent runtime and
Pi session without switching an existing runtime. **Current conversation…**
only routes to opening the captured chat or entering its reconfiguration menu;
it never applies pending launch choices. **Choose saved session…** selects a
transport-qualified file without loading it. Consult search, related-session
navigation, preview, and Embark in this selection-only context cannot open,
switch, or jump to a runtime; the built-in file picker is the fallback. `RET`
starts the selected preset/Tools in a new independent runtime, then loads the
saved Pi session and waits for authoritative transcript synchronization. The
menu keeps the choice short and shows the saved title, ID, cwd and resolved
owner scope in full-width details above the action; loading it does not move
the process's working directory to that cwd.
Selected saved sessions require persistent storage and the same target as the
selected file. Changed target/path context, missing files, and PiChat runtimes
hosting or retaining an uncertain restart writer claim for the file block a
second writer; concurrent PiChat launches reserve the file until synchronization
succeeds or fails. This Emacs-local managed-runtime check cannot detect external
Pi processes. Canceling the picker leaves the prior selection untouched. The ordinary saved-session browser still
uses its own independent-open ownership and actions.

From an owning chat, `r` opens **Reconfigure this runtime**. The menu captures
that exact runtime, its current conversation, and its resolved preset/Tools
snapshots, not the present registry defaults. `p` explicitly resolves the
selected current definition; `x` edits Tools against the captured draft. `b`
returns to the untouched launch draft. `RET` with no effective prompt/tool
change is a no-op. Otherwise PiChat checks fresh Pi state, asks for confirmation,
stops the old process (confirming remote exit for supported SSH targets),
starts the validated replacement with the active
run-local model, reloads the same saved Pi session, restores supported settings,
and commits the transcript and configuration only after verifying the source,
active branch, settings and selected extension tools. Extension tools are checked
again after the initial saved-session reload, since Pi can replace its extension
runtime while loading the source. For a persistent **unwritten** Pi session
containing only startup model/thinking metadata (no messages, extension entries, name, or
navigation history), PiChat instead confirms fresh empty entries and restarts
into a **new Pi session ID**; the old nonexistent file cannot be reloaded. The
runtime identity, manager row, chat, unsent draft, and owner scope remain;
compose editors for the empty source are retargeted, while extension-owned
state is reset. A failed
post-stop attempt retains the last synchronized conversation as a read-only
snapshot. Reopen `r` from that chat for **Retry requested**, **Restore previous**,
or **Leave stopped**. A quit during the restart is handled like an error and
still propagates: before the snapshot is staged nothing is changed; afterwards
the attempt fails once, the previous preset, Tools and model stay installed,
and the snapshot is retained for recovery. If the error or quit comes before
PiChat asks Pi to stop, the original Pi process keeps running, local or SSH;
**Retry requested** or **Restore previous** stops it only then. A failure after
the stop request leaves a local runtime stopped. Preferred-runtime designation returns only if no newer
preference was chosen in that scope. Busy, ephemeral, unsynchronized, missing-
file with conversation history, unsupported-wrapper, and historical-active-leaf
cases are blocked before stopping Pi. An empty but named, pending, or
extension-modified session is not treated as safely disposable. SSH restart
requires verified Linux actual-Pi identity and an exit observer established
before stopping Pi; ending the transport alone is never confirmation. SSH
saved-session launch and restart use the captured target and path mappings.
See “SSH reconfiguration guarantees and limits” below for shutdown evidence,
recovery, and verification boundaries.

The built-in `manual` preset retains Pi's base prompt and selects
`read,grep,find,ls,edit,write` without adding execution restrictions to the
system prompt. It omits built-in `bash`; what the agent can do depends on its
available tools, including any separately selected extension or MCP tools. Other
built-ins: `coding` (includes bash), `review`
(read-only built-in tools), and `standard` (Pi's defaults). The old shipped
`discuss` preset is no longer registered; define your own if you relied on its
specific supplied-context instructions. Set `pichat-default-preset` to change
the creation default.
Define or replace a preset in `user/pichat.el`, for example:

```elisp
(pichat-make-preset 'manual
  :description "Inspect and edit files without built-in bash."
  :tools '("read" "grep" "find" "ls" "edit" "write"))
(setq pichat-default-preset 'manual)
```

The file must exist and be readable **by Emacs** when a new runtime starts;
PiChat sends its contents as literal text, including to SSH Pi. Prompts can be
literal strings, `(:file ABSOLUTE-PATH)`, or ordered lists of those fragments.
Resolved prompts end with a newline so Pi does not mistake literal text that
looks like a filename for a runtime-side file reference.
`:system-prompt` replaces Pi's base prompt; `:append-system-prompt` adds to it.

Set `pichat-append-system-prompt` for shared instructions across all presets,
including `manual` and `standard`. It accepts the same prompt source formats
and defaults to nil. For example:

```elisp
(setq pichat-append-system-prompt
      "Prefer bare URLs over descriptive Markdown links.
Prefer bullets unless a table materially helps comparison.
Keep tables narrow and pad columns for monospace readability.")
```

PiChat concatenates the preset's additions followed by these shared instructions
and sends one `--append-system-prompt` argument. A replacement `:system-prompt`
remains separate. The resolved text is captured in the runtime snapshot;
changing the setting or its files does not update existing runtimes. Start a
new runtime, or explicitly select the preset again in the reconfiguration menu
to resolve the current instructions before confirming the restart.


`:tools :default` (or omission) leaves tool selection to Pi;
`:tools nil` disables built-in tools. Explicit lists select exactly those
built-ins. Explicit-tool presets default to no extension tools and disable MCP
unless a direct MCP tool is selected. `standard` and custom presets with
inherited tools (`:default` or omission) remain Pi-controlled: they cannot use
the Tools picker or declare an extension baseline.

In `x Tools`, the preset's built-ins are prechecked and can be deselected.
**Extension tools** have enabled/disabled checkboxes and descriptions; MCP tools
remain grouped by server, and **Emacs-defined tools** by their registered group
(see [Emacs-defined tools](#emacs-defined-tools)). `RET` applies the draft, `q`
cancels it, `d` resets all choices to the captured preset, and `r` refreshes
discovery. `a` selects all eligible built-in, extension and MCP tools
(Emacs-defined tools are chosen per group); `n` deselects all.
`[` and `]` page longer lists.
Cancel does not change the launch/reconfiguration draft. Reset restores all of
the preset's baseline: built-ins, extension, Emacs-defined and MCP tools
(none, unless the preset declares `:mcp`). Deselecting a baseline MCP tool is a
customization: an empty MCP selection launches with `--no-mcp` rather than
falling back to the preset.
The picker configures a new independent runtime, or the captured replacement
in **Reconfigure this runtime**; it never edits a live process in place.

MCP discovery connects configured servers and reports failures. Non-direct,
hidden, disabled, unavailable, and normalization-colliding MCP tools cannot be
selected through the MCP group. Customizations are runtime properties, not
Pi session or saved-session-file properties (see `GLOSSARY.md`). Presets reject
conflicting generic Pi tool/prompt flags before runtime creation; use `standard`
when generic Pi arguments should govern, and leave
`pichat-append-system-prompt` nil if supplying a generic appended-prompt flag.
Changes to definitions affect future runtimes only.

### Preset MCP tools and models

An explicit-tool preset can also select direct MCP tools by default with exact
`(SERVER . TOOL)` pairs, and pin a model for runtimes launched by naming it:

```elisp
(pichat-make-preset 'web-search
  :description "Read files and search the web through Ketch."
  :tools '("read" "grep" "find" "ls")
  :mcp '(("ketch" . "search") ("ketch" . "fetch"))
  :model "anthropic/claude-sonnet-4-5")
```

`:mcp` requires explicit `:tools`; pass-through presets cannot declare it.
Malformed, duplicate or normalization-colliding pairs, and names that overlap an
extension or Emacs-defined tool, are rejected. Before a new runtime starts with
an unchanged MCP baseline, the launch checks those exact tools with the same
destination discovery as `x Tools` (target and directory). A missing, hidden,
non-direct or disconnected tool cancels the launch with a message; no other tool
is enabled instead. Reusing a live preferred runtime does not repeat the check,
and Tools applied in the launcher were already checked. Complete local
`pichat-rpc-command` wrappers cannot use MCP baselines.

`:model` is an exact `provider/model` (no thinking-level suffix) or `default`,
which is the same as omitting it: Pi's normal model policy. Naming the preset
in the launcher (or a programmatic profile with no `:model`) uses its model as a
run-local model, verified at startup like `m`; an unavailable model fails
startup instead of falling back. `m` overrides it for one launch. The launcher's
`default` preset choice keeps Pi's default model so that it can reuse the
preferred runtime, even when `pichat-default-preset` declares a model.
Reconfiguring a runtime keeps its active model; selecting a preset there does
not change models.

### Saving presets from the launcher

To reuse a configuration, set it up in `pichat-launch` and press `c`:

1. Choose a preset with `p`, adjust `x Tools`, and optionally choose `m Model`.
2. Press `c` (**Save preset as…**) and enter a name, such as `web-search`.
3. For a new name the preset is saved immediately. An existing name, including
   a shipped or programmatic preset, asks `Replace preset web-search?` first;
   declining changes nothing.

The launcher returns with the new name selected and the same effective tools,
prompts and model; nothing is launched. A saved preset records the effective
built-in, extension, Emacs-defined and MCP tools, the source preset's own prompt
sources (not `pichat-append-system-prompt`, which still applies to every
preset), and the model: an exact ID, or `default` for Pi's default policy. A
**Choose when launching** model cannot be saved; pick a concrete model or the
default first. Target, scope, persistence, conversation and runtime state are
not saved. Saving does not start, stop or reconfigure a runtime, or change Pi's
global model or `pichat-default-preset`. Tools Apply/Cancel stay run-local; only
`c` saves. Save several names to keep several presets; all appear under `p`.

Saved presets are stored in the `pichat-saved-presets` user option through
Emacs's Custom mechanism, in your existing `custom-file`, and reload in a fresh
Emacs whether that file loads before or after PiChat. Only that option is newly
saved: other unsaved Custom changes are not written, and text outside Custom's
`custom-set-variables` form is kept. Saving requires `custom-file` to be set
and refuses, with nothing changed, when the file's buffer has unsaved edits or
changed on disk, when the file cannot be parsed or has several
`custom-set-variables` forms, or when it holds saved settings this Emacs has not
loaded (for example, saved by another Emacs). A saved definition takes
precedence over a programmatic one with the same name, regardless of load order.
To rename or delete saved presets, edit `pichat-saved-presets` with
`M-x customize-option`.

### Extension tools

An explicit-tool preset can precheck exact extension tool names with
`:extensions`. For example, **after configuring a trusted extension that
registers `project_search`**:

```elisp
(pichat-make-preset 'project-review
  :description "Read files and use the configured project search tool."
  :tools '("read" "grep" "find" "ls")
  :extensions '("project_search"))
```

Existing shipped explicit presets have an empty extension baseline. Extension
choices are opt-in; discovering tools never selects them automatically. Hidden
tools and names that cannot safely be expressed as exact Pi tool selections are
unavailable. Missing or stale checked names cause a clear Apply/startup failure
rather than silently broadening the selection.

Opening `x Tools` starts an asynchronous, temporary no-session Pi probe using the
intended executable, target, working directory, environment, resource/trust
configuration, prompts and relevant model. It omits the preset's tool allowlist
so registered but initially disabled tools can be listed. Progress and errors
appear in the picker. Successful results belong to that launch/reconfiguration
draft: redraws and reopening with the same captured context reuse them; `r` or
reopening after a relevant context change refreshes them. Leaving the picker
cancels pending discovery. The default probe timeout is 25 seconds
(`pichat-tool-discovery-timeout`), excluding synchronous TRAMP connection/file
setup. Startup dialogs fail discovery rather than being approved automatically.

**Discovery executes trusted extension startup code.** It does not request a
model turn or add conversation entries, but `--no-session` is not a sandbox and
does not prevent extension side effects. Complete command wrappers, generic
tool/session filters, positional prompts and unsupported custom CLI arguments
cannot be safely adapted for discovery and are rejected. Configure custom
extension options in Pi settings instead of relying on unknown CLI flags.

Checked extension names join the runtime's startup allowlist. PiChat then uses
supported Pi APIs to enable and verify those exact tools in the **actual
process**, after startup handlers and any initial saved-session reload, before
accepting startup/replacement readiness. Missing tools, unsupported activation,
helper errors or rejected activation fail startup without a model request.
**This is an initial startup guarantee, not continuous enforcement.** Later
extension-managed changes and ordinary Pi session switches do not trigger
automatic reactivation. Checked does not force direct model exposure or bypass
Pi's tool/security policy. PiChat does not run loader tools, infer dependencies,
expand activation groups, or supply extension-specific adapters.

The catalogue is a snapshot of registered tools available under Pi policy, not
a complete package inventory: tools registered later may require refresh.
Exact known built-in and MCP choices are separated without guessing provenance
from name prefixes. The separate shell MCP listing cannot discover
extension-registered MCP servers; their tools may appear in **Extension tools**
instead. Neither listing promises universal completeness.

The bundled `bridge/pichat-tool-control.ts` helper is separate from the optional
Emacs-defined-tool bridge. PiChat explicitly loads it for probes and runtimes
with selected extension tools, and for every SSH runtime so actual-Pi identity
can be captured; no global extension installation is needed. Local startup uses
its package-relative path. SSH stages a private helper on the target rather
than passing a host-only path. Forced SSH teardown cannot prove the remote
child stopped, so runtime cleanup retains that helper and reports uncertain
shutdown. Successful SSH catalogue probes explicitly request helper-owned
shutdown rather than relying on stdin EOF through TRAMP. Local and real-SSH
discovery/activation are covered by isolated Pi 1.4.0 tests, including activation
after reloading a saved Pi session.

### Tool-policy boundaries

If you choose to run a shell block through PiChat's artifact runner, request
`sh`-compatible code: the runner uses `sh` even when a fence is labelled `bash`. Run with Embark `r`,
then `s` to place results in the draft; review and send it to continue. The
subprocess timeout defaults to 120 seconds.

The explicit tool allowlist limits direct and indirect tool availability in Pi,
but selected extension and MCP tools themselves may execute code or mutate
files. Extensions (including an optional PiChat tool bridge) may also provide
other execution paths; this is a workflow, **not a sandbox**. PiChat's explicit
runners execute code
outside Pi's tool permissions on the selected host. Presets and subprocess
code execution work on local and structured SSH targets: SSH code runs remotely
even when the project is mounted locally. The in-process Elisp runner is
unavailable for SSH Pi sessions. A complete local `pichat-rpc-command` wrapper
cannot be amended safely: presets with tool or prompt overrides are rejected
before startup. Set the default preset to `standard` for such a wrapper, and
leave `pichat-append-system-prompt` nil, and put any desired tool/prompt flags
in its complete command instead.

### Runtime and model choices

An independent runtime is a separate Pi RPC process retained in the manager but
not marked `★` as the scope's preferred runtime. “Independent” does not mean
Pi's `new_session` operation inside an existing runtime. For a run-local model,
`m` either lists and prompts for models immediately (**Select or enter
model…**, staging the choice in the launcher) or defers that prompt until `RET`
(**Choose when launching**), before creating the target runtime. PiChat then
passes the exact selection through that process's startup `--model`. A preset
model (see [Preset MCP tools and models](#preset-mcp-tools-and-models)) is used
the same way. Model listings superseded by another `m` or launcher are ignored.
The model prompt also accepts an unlisted `provider/model-id` when that provider appears
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

`M-x pichat-session-manager` opens one global `*PiChat Sessions*` buffer for
retained Pi runtimes across project and global scopes. The table identifies
backend (`pi`), storage (`file` or `none`), and model. Redraw does not contact
Pi. Open, stop, forget, and naming use the owning backend. A runtime is the
Emacs-side process/session object; the persisted Pi source loaded into it may
change after new-session, switch, fork, or clone operations. Manager rows use an
immutable Emacs runtime identity, so such source changes do not replace or
misidentify a row. The responsive table starts with an unlabeled `★` gutter for the preferred
runtime, **ID**, and **Name**, then progressively admits Status, Project, Preset,
Target, Model, Pi source ID, Backend and Store as space permits. ID is the same
runtime number used in chat buffer names, not the loaded Pi session ID; it sorts
numerically and stays visible in narrow layouts. Name receives spare width up
to 40 display cells. Exceptionally small windows show only ID (clipped if needed);
the preferred-runtime gutter appears when it fits. The narrowest visible manager window across frames determines
the shared layout; resizing and preview splits update it without querying Pi.
Full cell values are available as help text. Project sorting is the default;
a chosen sort and its direction remain effective even while the column is hidden.
A warning-faced `!` appended to Status, such as `running!`, means that the
runtime is waiting for user input; it disappears when the final queued request
is answered or cancelled. Full runtime identity, source path, scope, working
directory, and recent branch context remain available in the `C-o` preview.

Unnamed rows receive a stable two-word runtime alias, such as `calm fox`.
Aliases survive manager closure and source rebinding for this Emacs uptime;
they are display-only, never stored as Pi session names or used as action IDs.
An explicit Pi session name takes precedence; a subsequently unnamed source
restores that runtime's alias. Generated aliases are unique among themselves,
not against user-supplied names; truncation can also make labels look alike.
After all 1,024 pairs are reserved, new unnamed runtimes fall back to their Pi
source ID or runtime ID. Naming through `e` waits for setter success and
an authoritative state refresh. Pi 1.4.0 rejects blank names rather than clearing
them. External name changes appear on normal state synchronization, not polling.

Ordinary `pichat` still reuses one preferred live runtime per scope.
Independent profiles from `pichat-launch`, manager-created runtimes, and
independently opened saved sessions are additional runtimes and do not replace
that preferred entry unless
`m` is used in the manager. Stopped, failed, and unexpectedly ended runtimes
remain inspectable until explicitly forgotten. Killing a chat retains the
existing `pichat-chat-stop-session-on-kill` behavior and, when configured,
forgets that chat's runtime after stopping it. An uncertain SSH restart writer
blocks both chat closure and Forget, preserving its owner and recovery snapshot
until all writer exits are verified. Killing or quitting the manager never
stops any runtime.

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
- `e` — name the selected session through its backend;
- `k` — stop only the selected live runtime;
- `d` — forget and clean up a stopped or failed runtime;
- `m` — make the selected live runtime preferred for its owner scope;
- `D` — show that runtime's unified cached diagnostics;
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
source in a new independent runtime (the same behavior as `RET`). Independent loading starts a separate
process, switches and synchronizes that exact process, and stops/forgets it if
startup, switching, cancellation, or synchronization fails. It never mutates
the runtime from which browsing was invoked.

Opening a runtime reuses its owning chat, including its in-progress live tail
and draft, even if the Pi session ID or buffer display name has changed. A new
chat for a live runtime requests authoritative transcript synchronization;
active turns retain the normal settlement barrier. Stopped runtimes are never
queried merely to open a chat.

By default the manager opens chats in the current tab. Customize
`pichat-session-manager-display-chat-function` to select a frame or tab before
calling `pichat-session-manager-display-chat-current-tab`. PiChat has no Tab Bar
or Bufferlo dependency. This repository's `user/pichat.el` demonstrates an
optional Bufferlo-aware policy: it selects or creates the owner's project tab
first, otherwise chooses an existing Bufferlo location without prompting, and
finally falls back to the current tab. The manager itself remains on demand; showing the same global
buffer in a tab lets Bufferlo record normal local membership there.

## Jobs

Jobs are optional reusable instructions and captured execution settings. A **job
run** is one attempt with its own durable identity. Ordinary runs use a fresh
independent Pi runtime/Pi session; explicitly scheduled continuation instead
borrows the exact originating chat's live runtime and Pi session (see
`GLOSSARY.md`). Jobs do not require a plan. Supported flows are **manual prompt
jobs, explicit manual continuation, optional after-run jobs, native saved-job
one-shot/interval schedules, and one-shot continuation in this conversation**.
Jobs may declare a [run input](#run-input), and after-run jobs can form
[review loops](#review-loops).
Plan work uses ordinary instructions and the installed plans skill, not a special
phase adapter. Scheduling always requires explicit authorization.

- `M-x pichat-job-new` opens the shared compact Transient composer without
  starting a runtime or opening a setup buffer. Job fields are `n` Name,
  `i` Instructions, `d` Workspace and `a` After this run; execution fields are
  `p/m/x/t` for Preset/Model/Tools/Target, with inline values and customized Tools
  highlighted. Choose a concrete model before saving/submitting if none is configured.
  `v` inspects complete instructions and settings; `q` there returns to the composer.
  Multiline editing uses `C-c C-c` Apply / `C-c C-k` Cancel. Sub-picker Apply
  returns to the composer without saving or running. The menu shows actions,
  current values and context-specific warnings, not usage guidance. Use Transient's
  standard help or `C-h f pichat-job-edit-menu` for behavior and lifetime caveats.
- New and Repeat offer explicit `r` **Run once**, `s` **Save job** and `q`
  **Cancel**. Run once submits without saving a definition;
  Save requires a nonempty reviewed Name, saves only, and opens the saved job's
  report. A later **Run job** remains a separate explicit action. New has no
  ambiguous `RET` action. Save as job offers Save/Cancel; Continue work offers
  Run once/Cancel. Closing or replacing a composer discards its detached draft,
  including staged changes, without a resumable setup buffer. Errors retain it
  for correction. New from a chat never borrows its runtime or consumes its
  prompt or attachments.
- `M-x pichat-jobs` opens one global Jobs/Runs view. Native `TAB` switches between
  definitions and attempts, `RET` opens details, `C-o` toggles a read-only details
  preview, `+` creates, `r` runs a selected job's current definition, `e` edits,
  `h` shows its attempts, `a` toggles the input/review attention filter on/off, and `g`
  redraws cached state. `q` buries the list. The overview shows active/limit and
  attention counts plus the current history filter; returning to Jobs restores
  the selected definition. In the Jobs list, `M-x pichat-jobs-delete` deletes the
  selected definition after a short title-based `y`/`n` confirmation. Run history
  is preserved; queued, active or uncertain runs prevent deletion. There is no
  dedicated deletion keybinding. In Runs, `M-x pichat-jobs-delete-run` deletes
  the selected finished run after confirmation; its report offers **Actions →
  Delete run…** (`D`) too. Runs referenced by other runs or a saved schedule's
  last occurrence cannot be deleted; delete their whole
  [run chain](#review-loops) with **Actions → Delete chain…** (`C`) instead.
  Definitions, saved session files and captured evidence are retained; this
  removes history metadata, not files or runtime chats.
  Compact Runs tables show Work, Queued, and State / result;
  queue times use local date/time to the minute; Project / target stays in wide tables and
  run details. Compact Jobs tables retain their project/target context.
- `M-x pichat-job-definitions` (Jobs `i`, Evil `g i`) discovers authored job
  files for the current project and effective global agent root; a prefix selects
  another project. Like Jobs, it uses native sortable column headers, width-aware
  rows and a compact mode-line overview; its body contains only file rows.
  `RET` opens a compact, read-only import Transient using the Jobs editor's
  Job/Execution column layout and value faces, without field-editing keys.
  Inspect/Open file and reviewed Settings occupy supporting groups; Review/Save
  and Close/Cancel have a separate bottom action group.
  `g` (Evil `g r`) rediscovers
  the same roots, and `q` returns. In the menu, `i` **Review** resolves
  settings and stages a Create/Update review in that same menu;
  **Already up to date** means ordinary reimport did not recapture settings.
  In the reviewed stage, the secondary Settings action `r` **Use current settings**
  prepares fresh settings from the current named preset/target definitions, even
  when the file is unchanged. It still requires Save; it does not refresh the
  file listing or run the job.
  Only `RET` **Save** writes the saved job; `q`/Transient quit discards
  staging. Save closes the menu and keeps the selected file row. Errors retain
  the review for inspection/retry; stale sources or stores require rediscovery
  and a new review. Replacing native edits requires explicit confirmation.
  `d` **Inspect** opens one reusable read-only inspector using Jobs instruction
  styling, header title and compact status/file/workspace context. **Details**
  discloses settings once; nonempty prompt content is under **Prompts**. **Changes**
  appears only for actual differences and discloses before/after values.
  **Technical details** discloses scoped identity/root and raw captures. These use
  Jobs disclosure controls: TAB toggles a disclosure at point, otherwise navigates;
  RET/click also toggles. Inspector `q` returns to the same menu without resolving again.
  In the initial menu, `o` **Open file** closes staging and opens the
  ordinary file editor; imported fields are not editable in the menu. Save the
  file, then rediscover/review explicitly. Nothing auto-imports or runs.
  `D` (Evil `g D`) in the file table separately inspects cached file diagnostics
  and full root context. Inspector refresh redraws snapshots without rescanning
  files. Empty lists show zero files in the overview. Opening the initial menu
  or its inspector does not access the job store, resolve settings, initialize
  an executor or start Pi. Import never enables timing or changes follow-ups
  (other than a file's own `after_job` link), queued captures or historical attempts; Run and timing remain separate.
- Saved-job details put instructions first, followed by a clickable latest-run
  summary, schedule and workspace/target. Completed summaries use the recorded
  finish time; older records without one label their queue time instead. Enabled
  schedules show their next occurrence; disabled timing does not imply authorization.
  Imported jobs show **Imported from** in Details; identity/root and internal job
  IDs remain available through Actions → **Inspect raw settings…**, not normal
  job details. Replacement warnings remain visible when saved edits differ.
  Open the exact run to read its answer, without a duplicate response preview.
  The latest-run link includes manual runs. In Details, **Last occurrence: …**
  itself links to the run submitted by that occurrence, not a future run; it can
  still be queued/running. Occurrences without a submitted run remain plain text.
  That run and Latest run coincide only when no newer attempt exists.
- Run reports put the compact outcome/time and rendered answer first. **Details**
  expands the original instructions, continuation guidance, workspace/target,
  model/preset/Tools, full identities, trigger, local
  timeline and related-run links. Normal follow-up status is there too; failed
  dispatch, input requests, blockers and uncertainty stay visible without opening
  a menu. **View chat** and active **Cancel run…** remain directly available.
- Both reports show the captured title in their header. Saved-job headers omit
  internal IDs; run headers append an abbreviated saved-job ID when applicable.
  One-off runs have no saved-job ID. Full identities remain available through
  explicit raw inspection (and run **Details**); all operations use exact
  identities, including duplicate titles.
  `q` still returns without a permanent Back hint.
- Native `a`, or Evil Normal `g a` in detail buffers, opens the context-sensitive
  **Actions** Transient. There is no permanent Actions label/button in reports. Saved jobs offer **Run job**, **Edit…**, **Run history**
  and schedule commands. **Delete job…** (`D`) confirms deletion of that exact
  definition, preserving run history and retiring its schedule timer; it is
  omitted while the job has unfinished work. **Run job** is omitted while this job has unfinished
  work or the shared queue is full, and rechecked when invoked. Run reports offer
  conversation preview, diagnostics,
  response copy/source, repeat, chat continuation, saving and related navigation
  when applicable. **Continue work…** comes first for recoverable runs; it remains
  distinct from **Continue in chat…**. Uncertain runs offer reservation release and
  supported remote-exit inspection, retaining their existing safeguards.
  Commands recheck the exact report/current state; closing the menu does nothing.
  **Set schedule…** / **Change…** opens the existing staged timing Transient;
  those timing controls remain saved-job-only. Existing-conversation one-shots
  are authorized separately from their chat's composer. **Run now** consumes an
  authorized one-shot occurrence (including a pending scheduled continuation or
  a missed saved-job one-shot), whereas **Run job** is an additional manual
  attempt that leaves saved-job timing unchanged.
  **Diagnostics** uses the recorded execution note when no runtime is retained.
- Saved-job **Edit…** and the Jobs row's `e` (Evil `g e`) open the same compact
  staged Transient over the originating view, without a setup buffer. Job fields
  are `n` Name, `i` Instructions, `d` Workspace and `a` After this run; execution
  fields are `p/m/x/t` for Preset/Model/Tools/Target, with inline values.
  The multiline instructions editor's Apply returns to this menu without saving;
  its Cancel keeps the previously staged text. Other pickers return here too.
  `RET` **Save** updates that exact definition without another name prompt or
  starting work; `q`/explicit Transient quit discards all staged changes.
  Save preserves timing and historical runs; no-op Save preserves the entire
  definition and captured settings. Validation/write errors retain the editable
  draft. Pending pickers block Save; deleted, changed or retargeted origins are
  rejected. Opening another editing menu invalidates late returns from the old one.
- **Details** holds information and contextual links; routine operations live in
  **Actions**. **Inspect raw settings…** is under **Inspect** (`I`) in both reports.
  Run reports also offer **Copy saved-session path** (`f`) there when a path is
  recorded; it copies the reference without opening or checking the file.
  **Recheck remote Pi exit** (`x`) is menu-only when supported; uncertainty stays
  visible and rechecking never releases a reservation by itself.
  Raw inspection shows the complete record directly, including exact UTC times,
  internal IDs, all policies and captured configuration/inputs. There is no
  intermediate settings screen or raw-record detour for ordinary navigation.
  Execution completion remains distinct from task quality or domain success.
  **Repeat…** reviews historical settings and records repeat provenance; it does
  not silently use a changed definition or undo effects. It may repeat file changes
  or external actions and retains the definition's overlap exclusion.
  **Save as job…** opens the shared composer, not execution. Existing-conversation
  attempts omit Repeat, Continue work, Continue in chat and Save as job. Use
  **Reschedule…** when available, or start a new schedule from the chat, to
  capture fresh authorization.
- Reports use the chat's read-only input-bar styling and five-visual-line
  instruction folding at the narrowest displayed width. Run instructions live
  inside **Details**; continuation guidance folds independently. Click or press
  `RET`/`TAB` within report folds to toggle them; short blocks need no control.
  A folded block ends in `…`; expanded blocks offer **Show less**. Elsewhere
  `TAB`/`S-TAB` navigate without activating commands or links. Open Actions with
  its keybinding. Native/Evil and terminal/GUI follow the same rules.
  Refresh/resize retain folding choices and reading position; editors and
  exact-source views remain plain text.
- Optional `pichat-evil-setup` gives the list Normal-state `RET`, `TAB`, `zv`
  preview, `gr` refresh, `gc` new, `gx` run, `ge` edit, `gh` history and `ga`
  attention. Native `R` or Evil `g R` invokes **Release reservation** on the
  selected uncertain run; `M-x pichat-jobs-release-reservation` does the same.
  Details use buttons with `RET`; these do not take over Vim movement keys.
  The attention counter's shortcut hint shows `g a` in Evil Normal state and `a`
  in native Emacs state.

Run reports reuse the rendered response view's sanitized Markdown/SHR rendering,
link policy and exact-source fallback, without requiring the originating runtime.
Rendered links are navigable buttons; explicit `RET`/click uses the same checked
URL action in native Emacs and Evil, while TAB navigation never opens a link.
The final active-branch assistant message's exact prose is captured, not all
intermediate commentary. An original error from the last captured assistant
message is shown directly, without replacing it with an executor interpretation.
When neither prose nor an error was captured, the report says **No response
captured.** Technical executor reasons remain in diagnostics/raw records, not the
main report. **View response source**, **Copy response Markdown** (native `w`, Evil `g y`) and explicit
refresh (native `g`, Evil `g r`) remain available. Refresh and resize retain
response reading position and disclosures. Older summary-only records are labelled
**Response preview**; missing or changed evidence is reported rather than replaced
with the latest response from a potentially continued conversation.

Submitting does not select/display the new chat or change your current/preferred
runtime. **View chat** displays the exact owning chat while work needs attention.
**Preview conversation** displays immutable run-end entries through the same
read-only renderer as Session History and runtime-manager previews, without
starting Pi or reading the current saved session file, including after Emacs
restart. It has no fork/switch actions and is not Session History or saved-session
browsing. Older Markdown-only captures remain readable with a labelled fallback;
PiChat never reconstructs historical evidence from a subsequently continued file.
Finished runs with saved-session references offer **Continue in chat…** under
**Actions**: an explicit
new ordinary runtime on the captured target using the current default preset,
not rerunning the job. New prompts extend the same saved Pi session file, not a
clone, but cannot alter the historical run report or captured transcript.
Managed duplicate writers are refused; uncertain execution must be resolved first.
Job-owned chats allow
inspection and existing extension UI responses, not additional prompts, source
switching, reconfiguration or preferred designation; use Jobs to repeat/cancel.
Required interactions show Needs input and retain the concurrency slot until
answered or cancelled. There is no automatic approval or waiting-input timeout.
Killing an active owning chat is refused; closing a window or burying Jobs is
harmless. For ordinary independent jobs, after synchronized evidence is durably
captured, the owning runtime is stopped through the existing backend shutdown
barrier before completion releases
its concurrency slot. During that stop barrier the report status says **Answer captured ·
Stopping runtime**; finished reports show no pending-cleanup message.
SSH additionally requires verified actual-Pi exit; transport EOF alone is
insufficient. Cleanup failure retains uncertainty, the slot and captured evidence.
An existing chat remains read-only; stopped manager entries are retained until
explicitly forgotten. Runtime, saved Pi session and durable run evidence have
independent lifetimes. Pending input, cancellation and uncertain execution do not
automatically discard their runtime tracking.

Execution settings are captured, including resolved preset prompts, Tools,
model, command and target/path mappings. Instruction/name edits preserve them.
Changing execution explicitly re-resolves the preset/target after confirmation;
cancelling a sub-picker retains earlier staged choices in the composer.
Closing the composer discards all staged choices. Model/workspace/target edits preserve
the selected Tools; changing preset explicitly confirms resetting them.
There is no workspace coordination setting or workspace locking. Old resource
metadata is retained for historical inspection only, not used for admission or
as a read-only guarantee. Routine screens omit generic sandbox/save disclaimers. The composer warns
when the current preset no longer matches its capture. The environment, credentials and installed
extension code remain live: this is not a frozen or sandboxed environment.
Complete command wrappers, ephemeral sessions and conversation-loading flags are
not supported by jobs. Explicit targets never fall back locally.

### Authored job files

An **authored job definition** is a JSON source file, not the saved job or its
run history (see `GLOSSARY.md`). PiChat discovers direct, non-dot `*.json` files in:

- Project: `<selected-project-root>/.pi/jobs/`.
- Global: `<effective-Emacs-agent-directory>/jobs/`, normally `~/.pi/agent/jobs/`.
  Resolution honors `PI_CODING_AGENT_DIR`, including `pichat-pi-extra-env` overrides.

Sources must be local to Emacs; mounted files are supported, TRAMP roots are not.
An SSH execution target does not synchronize files or make its remote agent
folder an Emacs discovery root. Symlink source files and resource directories
are rejected; scanning is not recursive. Missing directories are empty; invalid,
unreadable or conflicting files appear in the file table's diagnostics.
Every matching filename is a candidate, including `name.example.json`. To keep
an example out of discovery, use a non-JSON suffix such as `name.json.example`.
Git ignore rules do not control discovery.

A project definition can omit directory to use the selected project root:

```json
{
  "version": 1,
  "id": "dependency-review",
  "title": "Review dependencies",
  "instructions": "Inspect dependencies and report risks. Do not change files.",
  "model": "provider/model-id",
  "preset": "review",
  "target": {"name": "local"}
}
```

Replace `provider/model-id` with a concrete model. Version 1 accepts only the
fields above plus optional `directory`, `input` and `after_job`. Global files require an absolute,
Emacs-visible directory; project-relative directories resolve against the project
root, not `.pi/jobs/`. No tilde expansion or environment interpolation occurs.
Omitted target means local; a different name must identify a configured target.
Preset must be an explicit named preset, not `default`. Names resolve at Review,
not discovery. Tools and prompts come from that preset; schedules, inline target
configuration and arbitrary command arguments are not source fields.

Optional `"input": "Plan and scope"` declares a run input prompt: one nonblank
line of at most 200 characters. **Run job** then asks for the input (at most
4,000 characters) and the job cannot be scheduled. Optional
`"after_job": {"scope": "global", "id": "plan-reviewer"}` sets the saved
after-run default. Scope is required: `global` names an imported job from the
global folder, `project` names an imported job from the same repository's
`.pi/jobs/`. Scopes never fall back to each other, another repository's job
cannot be named, and a global file can only name a global job. Review resolves
the link to exactly one saved job, which must be imported first; it shows the
linked job's title and scope, and warns when that job has its own after-run
job (ignored when it runs as a follow-up). A file without `after_job` keeps a
native after-run default; a file that sets one owns it, so reimport restores the
file's link and removing the field clears it. Changing `input` natively counts
as a native edit; changing the after-run default does not.

Use strict UTF-8 JSON with unique keys, integer version `1`, no nulls or NUL text,
and at most 256 KiB. ID is lowercase kebab-case, at most 64 characters. Nonblank
text limits are: title 200, instructions 131072, directory 4096, model 1024,
preset/target name 200 characters. Model must be `provider/model` without a
thinking suffix; model, preset and target names cannot contain whitespace.

Identity is scope kind + canonical scope root + authored ID, not filename or
job title. Same-scope duplicate IDs diagnose every claimant; project/global and
separate projects never shadow one another. Rename within a scope retains
identity; moving scope creates a distinct saved job. Missing sources never delete
saved jobs or run history. Ordinary unchanged reimport is a true no-op, including
captured settings, timestamps and the last modifying import path. Explicit
**Use current settings** prepares recapture and still requires Save.

Native saved-job edits never write back into source files. Reimport over native
edits requires reviewed replacement confirmation. Updates preserve timing,
follow-ups, queued captures and historical evidence. Stale source/store errors
require fixing the source and discovering/reviewing again, not editing runtime
metadata. Project files are untrusted data; import is not a Pi trust gate or a
sandbox. Import saves only; execution and timing require separate authorization.

PiChat bundles the `pichat-jobs` authoring skill for actual structured launches,
including job runs. It teaches file creation/editing and explicit Emacs review;
it cannot import or execute a job automatically. Standalone Pi does not receive
this bundled skill. PiChat adds no global/project skill installation or settings
writes. Complete command wrappers are not amended. Explicit `--no-skills`/`-ns`
suppresses PiChat's injection without changing user skill arguments/settings;
`enableSkillCommands` controls command discovery rather than resource loading.
Local launches use the bundled asset; SSH launches privately stage it on the
execution target with the existing helper cleanup/uncertain-exit policy. Capture
and preview never stage it, and saved job arguments retain no temporary skill path.

### Run input

A job can declare a **run input** prompt (editor field `u` **Run input**, or
`input` in an [authored file](#authored-job-files)): one line of at most 200
characters, such as `Plan and scope`. A job that declares one requires its
input; one that does not refuses input and behaves as before.

- **Run job** and the composer's **Run once** ask for the input in the
  minibuffer (at most 4,000 characters; blank or longer input queues nothing).
  `pichat_job_run_now` takes it as `input`.
- The run stores the input. Its prompt is the job's instructions followed by a
  section labelled "Run input (from the user or the job that started this
  run):". Run details, `pichat_job_run_inspect` and a follow-up's stop envelope
  show it.
- **Repeat** and **Continue work** reuse the earlier run's input without asking.
  It is separate from Continue work's additional instructions.
- Scheduled runs have no input, so a job that declares one cannot be scheduled.
  A follow-up never asks either: it runs without input and reads its origin's
  input from the stop envelope.

Input is plain text from you or another job, added to the prompt; it adds no
permission the job's instructions and tools do not already give.

### Continuing interrupted work

**Continue work…** is offered for failed, cancelled, or manually released
review-needed runs. It opens the shared composer, not a running agent. Review
captured settings, optionally choose a different provider/model with `m`, or
edit additional guidance with `i`, then select `r` **Run once**.
The original instructions, workspace and target/path identity
remain fixed; the settings Transient omits the target control for
continuations. Explicit execution edits still re-resolve configuration and are
rejected if the captured target/path identity changes; no silent target fallback.
Continuation is one run, not a reusable job definition.

The new run links to **Previous run**, starts a fresh independent runtime/Pi
session and receives the original scope plus **previous run context**: the saved
response, conversation/tool activity, and recorded outcome or error. The old
report and saved session file are not changed or loaded for this operation.
Context is embedded in the new prompt, so remote continuations do not depend on
local evidence-file paths. Up to 32,000 characters of captured conversation data
are included; missing, corrupt or truncated context is explicit and requires
acknowledgment before submission. Later edits to the original saved session are
never substituted. Context sent to the newly selected model may contain sensitive
tool output. It is a record of what happened, not proof that the work succeeded.

Continuation instructions require inspecting actual work and current checkpoints,
avoiding repeated side effects and stopping at original scope/acceptance boundaries.
These are agent instructions, not a sandbox or certification of plan progress.
Provider failure may have prevented checkpoint writing. There is no quota detector,
automatic retry, gate approval or adjacent-phase permission. Repeat and Continue
require the original run to be stopped; uncertain execution must be separately
inspected/released first. Merely opening/cancelling the composer creates no new run.

### After-run jobs

The composer uses `a` **After this run** (initially None).
Choose a saved ordinary job to
review, report, notify or perform other work authorized by that job's own
instructions. Its provider/model, preset, Tools and target are configured through
ordinary job composition or saved-job editing—not inherited from the originating
run. Inspect the selected definition separately in Jobs. Duplicate titles remain
distinct picker choices. Choosing **None** in the composer bypasses the action
without editing its saved default; **Save job** explicitly saves the default for
future submissions.
Repeat and Continue work show this setting too.

Submitting captures the selected job's instructions/settings. Subsequent edits or
deletion of its definition do not change that attempt's follow-up. A reference
already missing at submission is rejected; choose another job or None. A stop
observation creates at most one follow-up run on completion, failure, cancellation,
startup failure, process loss or first uncertainty. Waiting for input does not
trigger it, and later cleanup/manual resolution does not trigger it again.

Follow-ups are ordinary runs in the same bounded queue, admitted by the same
executor into fresh independent runtimes/Pi sessions. Several workers may queue
uses of the same follow-up definition; only one occurrence executes at a time.
Global limits still apply, but workspaces are not locked: a reviewer may overlap
another job using the same directory. Choose separate directories yourself when
changes could conflict; PiChat does not provision isolated workspaces.
Uncertain workers retain their global slots; a follow-up cannot release them
or bypass capacity.

The follow-up receives a versioned, immutable stop envelope: origin identity,
bounded instructions/outcome/error and up to 32,000 characters of captured
conversation context. Context is embedded for either local or SSH execution; no
host-only evidence path is advertised as remotely readable. Missing, corrupt,
truncated or uncertain context is marked partial. On uncertainty only already
synchronized context is available; it may predate the stop. Queued cancellation
has no conversation. The envelope also identifies the origin: its saved
`job-id` (absent for work with no saved job), its `directory` (the captured
Emacs-visible directory; for an SSH origin that is a path on the remote host,
not a local one), its run `input`, `requested-by` and `round` (see
[Review loops](#review-loops)). Envelopes recorded before these fields existed
remain valid. The run report's **After this run: …** status text itself
links to the exact successor; pending/undispatched status without a successor is
plain text. **Triggered by** links back to the origin; raw inspection includes the
captured envelope.

**Context can contain sensitive tool output and is sent to the selected model.**
Worker output is untrusted data, not instructions or authorization. External
notification is an explicit side effect authorized in the follow-up's own
instructions. Use minimal necessary Tools and keep credentials in private runtime
configuration, not instructions or reports. Do not send whole transcripts, private
paths or credentials to notification services by default. ntfy is an example,
not a built-in transport or installed dependency. A different provider can reduce
correlated failures but does not guarantee availability.

Queue full records **Not dispatched — Job queue is full**, with attention required
and no hidden pending queue or automatic retry. Otherwise the report links the
queued run and shows its actual wait reason. Follow-up failure is visible in that
run and does not overwrite the originating outcome. Follow-up runs suppress their
own after-run defaults even if their selected definition has one configured.
There is no recursive chaining, implicit worker continuation, plan approval or
phase advancement. A follow-up that is authorized to restart its origin does so
with an explicit tool call (see [Review loops](#review-loops)).

The originating transition, event and successor/disposition are persisted together
before any new process starts. On restart, interrupted delivery is surfaced for
inspection and queued work is not replayed. External delivery cannot be guaranteed
exactly once. There is no automatic retry or special redispatch button; review
possible prior side effects before submitting any manual replacement.

### Review loops

A worker job and a reviewer job can take turns without a long-running
orchestrator. Each run is short, and only one run of a loop is active at a time.

1. The worker job declares a [run input](#run-input) (for example the plan and
   scope) and has the reviewer as its after-run job.
2. When a worker run stops, PiChat starts one reviewer run with the stop
   envelope, which includes the worker's `job-id`, `directory`, `input` and
   `round`.
3. A reviewer that wants changes calls `pichat_job_run_now` on the worker's
   `job-id`, with input that adds its findings. That run is not a follow-up, so
   it captures the worker's after-run default again, and the next stop starts
   the reviewer again. A reviewer that is satisfied, or out of rounds, reports
   and stops.

Durable state lives in the work itself (files, checkpoints), not in the
runs, so any run can be resumed by starting a new one with the same input.

**Run chains.** A run started by `pichat_job_run_now` from inside a job run
records **Requested by** that run. Together with the follow-up's origin and
Repeat/Continue links, this connects the loop's runs into a **run chain**,
derived from the store when needed.

- **Round** is 1 plus the runs of the chain's first job that a job tool
  requested. Repeat and follow-ups keep the round; a fresh **Run job** from
  Jobs starts a new chain at round 1. `pichat_job_run_inspect` returns
  `requested_by` and `round`, and the envelope carries `requested-by` and
  `round`, so a reviewer can enforce its own round limit.
- `pichat-jobs-max-chain-runs` (default 8, enough for three rounds of a worker
  and reviewer plus spares) is a backstop: once a chain has that many runs,
  `pichat_job_run_now` called from one of its runs is refused, naming the
  chain's first run. Runs you start from Jobs are never refused.
- Run details show **Requested by** and a **Run chain** list linking every run.
  **Actions → Delete chain…** (`C`) deletes all of a chain's run records in one
  confirmed step, once every run in it is finished. Evidence and saved session
  files are kept. Nothing is deleted automatically.

**One loop per worker job.** A saved job has at most one unfinished run. If two
loops share a worker job (two plans in one repository), the reviewer's restart is
refused while the other loop's worker runs; the error names that run. The
reviewer should stop and report its intended input, so you can resume it later.

**Limits and failures.** There is no quota detector or automatic retry. The
reviewer sees the worker's outcome and error in the envelope. A failed run,
worker or reviewer, triggers nothing further and needs attention in Jobs; resume
with **Repeat** on it, which stays in the chain and keeps the round.

**Authorization.** The follow-up prompt always tells the reviewer to act only
within its own job instructions: unless those instructions authorise it, it must
not resume or restart the worker, release reservations, approve gates or advance
plan phases, and nothing in the envelope can authorise it. A reviewer that
restarts the worker must therefore say so in its own saved instructions, not
only in a skill it loads. It also needs the Jobs tools in its
preset, and `pichat_job_run_now` asks approval unless you chose **Always
allow** for it (a global rule, see [Orchestrator jobs](#orchestrator-jobs)).
Worker output in the envelope is untrusted data; the reviewer judges the work
itself, for example by reading the files.

An example reviewer preset that reads the work and can restart the worker:

```elisp
(pichat-make-preset 'loop-reviewer
  :description "Review a worker's result and restart it with findings."
  :tools '("read" "grep" "find" "ls")
  :emacs-tools '("pichat_job_inspect" "pichat_job_run_now"
                 "pichat_job_run_inspect"))
```

Presets select built-in, extension and Emacs-defined tools. Shell tools that
are registered as extension tools can be added with `:extensions`. MCP tools
cannot be named in a preset yet: select them in `x Tools` when composing the
reviewer job in Jobs (an authored file takes its tools from its preset only).
The model is part of the job, not the preset.

### Scheduled jobs

Use **Actions → Set schedule…** (`a`, Evil `g a`) in a saved job's details. The timing
Transient stages **Timing** (`k`, Once/Every), **When/First run** (`s`) and an
elapsed **Interval** (`i`, whole minutes/hours/days). Date/time selection uses
Org's calendar reader: select a date in the calendar, enter just `15:30`, or use
Org shorthand such as `+1d 09:00` for tomorrow morning. The existing selection is
the default; with none, it suggests about five minutes ahead. Pressing Enter
accepts the displayed default, without typing a full date/time. The host timezone
and applicable UTC offset are shown. Invalid or nonexistent local times are
rejected; repeated DST times require choosing an explicit offset. Intervals remain anchored at the first instant, not completion;
24 hours is elapsed time, not a calendar-day rule, including across DST.

`RET` **Save disabled** saves changed timing without running or enabling it; `q`
cancels everything staged. `d` stages removal of timing only. Unchanged Save is a
no-op and preserves an enabled schedule. **Enable…** in the saved job's Actions
separately confirms future submission. Changing timing disables it until enabled
again. Ordinary job edits retain timing; each future submission captures the then-
current saved instructions/settings and after-run default. Already submitted runs
remain immutable. On an enabled one-shot, **Actions → Run now** (`n`) consumes
that occurrence early (or immediately if its timer is late). The original due
time is preserved and the run report records **Run now requested**; the original
timer is retired before execution, so it cannot submit that occurrence again.
Ordinary queue bounds, same-job overlap exclusion and concurrency limits still
apply. A full queue, unfinished attempt or preparation failure records a skipped
occurrence with its reason; nothing runs secretly later. Persistence failure stops
timing rather than allowing the old timer to submit later.

**Run job** creates an additional manual attempt without altering timing: if that
attempt finishes before the scheduled time, the scheduled occurrence can still
run. Disabled future timing must be enabled before it offers Run now. Interval
schedules offer only Run job for additional manual work; their anchor and next
occurrence remain unchanged. **Disable** prevents
future submissions but does not cancel queued or active work. Remove schedule and
delete job invalidate the old timer ownership; deletion retains its existing
unfinished-run guard. The wide Jobs table separates Schedule from Latest run;
narrow layouts retain timing in definition details only.

**Initialize Jobs once per Emacs session** (open `M-x pichat-jobs` or New job) to
restore enabled timers. Merely loading PiChat does not initialize the store.
Closing/burying its views does not stop timers; Emacs must remain running. At
initialization, missed intervals advance directly to the next future occurrence;
missed one-shots show their status in definition details and offer **Run now**,
**Reschedule…**, **Dismiss** under Actions. Reschedule saves disabled; Dismiss does not run. No queued work
or missed occurrences are replayed after restart.

While Emacs remains running, a delayed owned timer attempts submission once when
it fires, even after sleep. Recurring timing then advances strictly past now,
without firing all missed ticks or drifting with completion. A live one-shot may
therefore run hours late. Any unfinished occurrence of that definition, including
queued/uncertain work, makes the tick skip. Global capacity waits use the
ordinary bounded queue/admission. Full queue or preparation failure records a
bounded last-occurrence reason, not a failed worker run or a backlog. A one-shot
not submitted offers the same explicit intervention actions. Successful one-shots
become inactive on submission, not worker completion; worker failure never rearms
them. The definition's Details links to the exact submitted run; the run's Details
retains the scheduled due time and Once/Interval trigger.

Occurrence consumption and ordinary run creation commit together before launch;
there is still no exactly-once guarantee for external effects. Timer callbacks
revalidate durable ownership after edits/disable/delete, and restart never infers
that interrupted external work is safe to replay. A persistence error stops all
owned schedule timers and shows a bounded error in definition details; inspect
storage and restart Emacs after fixing it rather than silently retrying.

Schedules grant no tool approvals, plan acceptance or automatic phase advancement.
Runtime setup/input still uses the owning execution's existing noninteractive
startup and attention rules. No cron parser/dependency, external daemon, backend
selector or execution while Emacs is closed is provided. Timing data is versioned;
a future cron replacement requires explicit migration, disabling non-equivalent
rules for review rather than running two timing engines or silently translating
arbitrary elapsed intervals into cron field steps.

An agent can manage the same saved-job timing, and run, follow and cancel job
runs, through the Jobs tools (see [Saved-job tools](#saved-job-tools)).

### Scheduled continuation in this conversation

From an **idle, synchronized Pi chat**, use
`M-x pichat-job-schedule-continuation`. The shared composer starts with
`continue`, no selected time, and the exact originating runtime/Pi session.
This is not **Continue work**, which starts fresh independent work, nor a Pi
follow-up message queued behind an active run; see `GLOSSARY.md`.

- `i` edits the prompt with the same multiline Apply/Cancel controls. The chat's
  unsent draft and attachments stay untouched; this attempt has no attachments.
- `w` **When** opens the same Org calendar/date-time reader as saved-job timing,
  defaulting to the selected time or about five minutes ahead. Short inputs such
  as `15:30` and `+1d 09:00` avoid typing a full date. The resolved local time and
  UTC offset remain visible, and repeated DST times require choosing an offset.
  Choose a future time; opening the composer alone still selects no time.
- `v` inspects full prompt, provenance and inherited settings read-only.
  Workspace, model, preset, Tools and target are not editable in this mode;
  reusable Save, Run once and after-run actions are absent.
- `s` **Schedule** explicitly authorizes the reviewed one-shot and opens its
  Jobs Run report. Scheduling sends no prompt and starts no runtime. `q` or
  Transient quit discards staging only. Ordinary New job still creates
  independent work, even when invoked from this chat.

The pending attempt appears in **Runs**, not as a reusable definition. Its
report prominently shows the due time, destination and cancellation. While the
attempt is still scheduled, use **Actions → Run now** (`n`) to consume that same
attempt immediately instead of waiting. This preserves the original due time
and records when Run now was requested; it retires the original timer rather
than creating another run. Ordinary queue/concurrency limits and fresh
conversation verification still apply, so Run now does not guarantee immediate
delivery to a busy or changed conversation. It cannot retry a finished/not-sent
attempt or reconnect a lost runtime. At most
one unfinished scheduled attempt targets a runtime. Replacing a pending
scheduled/queued attempt requires confirmation; active or uncertain work must
be inspected rather than silently replaced. Cancel before submission sends
nothing. Finished unreferenced attempts can be deleted with ordinary run deletion.

While waiting, normal chat use is not locked. Renaming the Pi session or selecting
another model does **not** cancel the attempt. It uses the authoritative model
verified immediately before dispatch, not the scheduling-time model; reports keep
those two settings separate. Failed/same-model selections do not invent a change.
Submitted prompts, steering and follow-up messages still cancel before competing
input is sent, even if Pi later rejects/handles that input. Editing an unsent draft
is harmless. Source changes (including switching away and back), actual history
changes, process replacement or loss of chat ownership invalidate the intent.
A due attempt that is busy, changed or cannot be verified becomes visibly
**Not sent**; it does not poll until the chat is idle.
An unchanged due attempt uses ordinary queue/concurrency limits and is checked
again after any capacity wait and immediately before submission. A full queue
records not sent, without a hidden backlog or retry. There is no preferred-runtime,
saved-file, fresh-conversation or local-target fallback.

Invalidation records a bounded cause, triggering command/event where known, and
changed field names—never prompt bodies or raw RPC payloads. The still-matching
originating chat receives one source-qualified status without stealing focus;
it survives repaint but is cleared with the source. Use
`M-x pichat-job-review-continuation` there to inspect the exact attempt, or
`M-x pichat-job-reschedule-continuation` to review its prompt with a fresh capture
and **no selected time**. Choose When and explicitly Schedule again; neither
command sends automatically. The run report also offers **Actions → Reschedule…**
(`s`) for pending scheduled/queued attempts and not-sent attempts with a matching
notice still retained by the originating chat. The exact source must still be
live, idle and synchronized; reports never reconnect or find a runtime from stored
IDs. This opens the same composer with a fresh capture, the previous prompt and
**no selected time**. Cancel leaves the original attempt unchanged; explicitly
scheduling a replacement of pending work retains the existing confirmation.
Stale notices cannot act on a rebound source. Legacy reports without
cause/dispatch-model evidence remain readable.

Emacs, the captured chat and its runtime **must remain alive**. A late timer,
including after sleep, attempts delivery once when it wakes; the chosen time is
not a delivery deadline. Scheduling does not detect quota/reset times or establish
that provider capacity will be available. Closing a pending chat cancels the
intent and retains that chat's ordinary close/stop policy. On Emacs restart,
pending scheduled/queued attempts are cancelled; possibly dispatched attempts
remain uncertain. Live bindings are never restored or reconnected from metadata.

During dispatch/execution a temporary guard blocks competing prompts, source
changes and reconfiguration. Extension UI responses remain available. A valid
attempt sends one normal prompt, not a steering/follow-up message. Existing
automatic retry/compaction settings remain in force: one submission is not a
promise of one provider call. Completion requires an attributable new result,
settlement, canonical synchronization and fresh idle/empty-queue verification.
Earlier answers/errors cannot stand in for this attempt. Handled/queued prompts,
transformed input that cannot be attributed, process loss or ambiguous dispatch
remain uncertain and are never automatically retried.

Successful completion restores prior guards/hooks and leaves the runtime and
ordinary writable chat alive, with its settings and preferred designation
unchanged. Due-time execution does not select the chat. Active cancellation
requires the report's confirmation and source-qualified abort; its acknowledgment
is not proof that tools stopped. Uncertain attempts retain capacity and guarded
ownership until explicit inspection and **Release reservation**. Release restores
input only after durable acknowledgment, without stopping or resuming the runtime.
There are no recurring schedules, after-run chains, automatic reconnect/replay,
or authored/reusable definitions targeting a live conversation. Local Pi is
covered by offline real-Pi and live-UI checks; SSH uses the same exact live RPC
endpoint and has deterministic coverage. Real-SSH acceptance for this mode
remains separately opt-in; do not infer it from local or inert-endpoint fixtures.

### Plan work is an ordinary prompt job

Install the plans skill on the chosen target and ensure it can access the
execution checkout and authoritative plan. For example, submit ordinary multiline
instructions (fill the placeholders before running):

```text
Use the plans skill to run <plan-id> at <authoritative-plan.org>, only the exact
heading <full phase heading path>, in <execution-checkout>. Inspect the current
plan and actual work first. Stop at that phase boundary or a human-acceptance
gate. Do not start adjacent phases, infer approval, commit or push. Update the
authoritative record and report checks/blockers. If the plan, phase or skill is
missing or ambiguous, stop; do not create a substitute execution record.
```

Choose a preset with the tools that work requires. PiChat does not parse phase
headings or prove human approval; the agent and plans skill handle bookkeeping.
Avoid simultaneous changes to a shared authoritative plan from different worktrees:
PiChat does not lock workspaces or discover plan references in prompts. Skill use and
plan access are not guaranteed merely by putting these instructions in a job.

`pichat-jobs-max-concurrency` defaults to 3 and the shared bounded queue to 20
(`pichat-jobs-queue-limit`). Manual submissions reject a second queued/active
occurrence of the same definition; lifecycle submissions may queue but are
serialized by definition during admission.
Different jobs may execute concurrently in the same workspace, including old
jobs with saved resource/access metadata. There is no workspace lock, access-mode
inference, or automatic worktree/workspace isolation. Arrange separate workspaces
or avoid concurrent submissions when changes could conflict. Same-job exclusion,
global concurrency, runtime ownership and saved-session duplicate-writer guards
remain independent safeguards; they do not prevent conflicting file edits.

Prompt acknowledgment is not completion. A run finishes only after agent
settlement, a snapshot requested after that settlement, and authoritative idle
state verification. Synchronization failure, process loss and interrupted
execution retain uncertain state and a concurrency slot; no work is retried/replayed.
Cancellation requests abort but does not equate its acknowledgment with stopped
tools. Aborted/abnormally ended work requires descendant/workspace
inspection before its slot can be released; legacy read-only declarations do not
waive this requirement. **Recheck remote Pi exit** reuses the
existing verified SSH lifetime observer where its process is retained; it cannot
prove descendant exit. The action is offered only with a retained verified SSH
lifetime, under Actions; local runs have no irrelevant SSH message.
Uncertain runs display **Needs inspection** in the existing table and report,
without extra scheduling columns or sections. Their reservations still occupy
global admission capacity, not a workspace lock. Same-job waits link to the blocking run.
**Release reservation…** (under Actions or via the selected-row command)
asks for an inspection note and confirms that queued jobs may start and running
tools are not stopped. It records an explicit human acknowledgement as Needs
review, not verified shutdown or success. Cancelling the prompts changes nothing.
Release does not retry or continue work; **Continue work…** is separate. Its resolution
time is separate from verified finish time. Older records without timeline fields
show unavailable times rather than inferring them from the last metadata update.

Metadata defaults to `pichat-jobs-file` (`pichat/jobs.json` under
`user-emacs-directory`). This repository overrides it in `user/pichat.el` with
`(my/emacs-local-dir "pichat/jobs.json")`, keeping runtime data in the gitignored
`.local/pichat/` directory rather than the package sources. It is versioned
data-only JSON, atomically replaced with 0600 permissions, and may contain
sensitive prompts/arguments. Use one owning
Emacs per metadata file; changed-file/foreign-lock checks fail rather than
silently overwrite history. Opening Jobs first initializes restart reconciliation:
queued work and pending existing-conversation schedules are cancelled,
potentially dispatched work remains uncertain, and
old runs are not replayed. Reconciliation never generates new follow-up runs;
interrupted follow-up dispatch remains visible for inspection. Enabled schedules
restore future timers under the missed-start policy above. Subsequent browsing/
refresh never contacts Pi or dispatches execution. Metadata
has a 16 MiB limit. New run evidence is stored in content-addressed JSON beside
that file, in `<pichat-jobs-file>.evidence/` (0700 directory, 0600 files), with an
8 MiB UTF-8 JSON limit per run. Version-2 evidence includes the exact response,
response entry/source identity, run-end leaf and structured active-branch entries,
including tool output/thinking; it can be sensitive. Existing-conversation
captures additionally retain their pre-submit boundary and prompt entry, and
can include earlier conversation history. Data-only destination provenance does
not authorize reconnecting after restart. Version-1 Markdown-only
captures remain readable without migration. Overflow or publication failure retains
uncertainty and its slot instead of silently truncating a report or declaring completion.
Evidence is published before the metadata reference; interrupted commits may leave
unreferenced files. Back up/move evidence with metadata. There is no automatic
pruning of records, evidence, or saved Pi sessions; explicit run deletion retains
its evidence and saved Pi session file. Archive only when no
work/uncertain executions need preservation. Control waits default to 30 seconds
(`pichat-jobs-control-timeout`); active model work has no implicit timeout.

## Diagnostics: inspect versus setup

Start with `M-x pichat-show-diagnostics`, or `D` on a runtime-manager row
(Evil Normal `g D`). This is a **safe cached snapshot, not a live health
check**. It shows four independently retained sections:

- Runtime / transport failures.
- Canonical transcript compatibility notices.
- Live-tail compatibility notices.
- Available current Session History normalization warnings.

Opening or refreshing this report reads caches only: no history fetch, RPC
request, process launch, or automatic raw-data access. `none` means the current
cache contains no diagnostic records; `unavailable` means there is no current
cached snapshot, not necessarily a failure. Source-bound sections are excluded
when their source is stale or rebound. Their warnings are not copied into the
runtime failure log. Safe summaries are redacted and bounded; severity/category
and failure time appear only where retained, alongside a runtime identity and
snapshot-time header.

Safe and raw inspectors use separate buffers per runtime. Their actions retain
the inspected runtime even after it stops; after it is forgotten, the existing
snapshot remains readable but owner-dependent actions are rejected rather than
selecting another runtime. See `GLOSSARY.md` for runtime versus Pi session and
Session History terminology.

Chat notices are separate from retained diagnostic history. Each new failure's
notice disappears automatically after **5 seconds**, without deleting history,
changing the draft or attachments, or stopping the runtime. Customize
`pichat-diagnostics-notice-timeout` to change this delay in seconds, or set it to
`nil` for manual-only dismissal; the setting applies to newly recorded failures.
Reopening a chat or receiving unrelated updates does not restart a notice's clock.
Use `C-c C-0` or `M-x pichat-chat-dismiss-diagnostic-notices` to acknowledge
**all active chat notices** immediately. The notice displays this shortcut.
Dismissed or resolved notices do not reappear when the chat is reopened; a new
failure with identical text is a new notice. Active independent errors remain
visible together.

Successful compaction resolves only compaction failures captured before that
manual RPC request or matched automatic compaction-start/end attempt, within the
same source and process lifetime. Polling, unrelated successful RPCs,
failed/aborted compaction, and duplicate completions do not resolve them.
Successful authoritative transcript synchronization similarly resolves previously
captured malformed-RPC notices. Other errors remain until expiration or explicit
dismissal. Source-specific notices are not replayed after source rebinding
(including switching away and back); process-start/exit notices remain runtime-wide
until expiration, dismissal or process replacement. Retained history stays
available in the inspectors below, within the existing record limit.
See `GLOSSARY.md` for source, runtime and process-generation distinctions.

Inspector keys:

- `g` (Evil Normal `g r`) — rebuild the current safe or raw snapshot.
- Safe view `r` — ask before opening sensitive raw details for that runtime.
  The raw view can contain stderr, failed RPC responses, command arguments,
  recent RPC events, paths, prompt content, and credentials. It retains bounded
  records/values; **review before sharing**. Direct explicit inspection remains
  available via `M-x pichat-show-transport-diagnostics`.
- Safe view `s` — choose an explicit setup action, separate from inspection.
- `q` — return/bury; raw details opened from a safe report return to that
  report, then to its origin. Refresh preserves this return chain.

Setup actions may launch a process or open editable configuration:

- **Check Pi executable/version** (`pichat-diagnostics-probe-pi`) runs the target
  executable with `--version` and reports in the echo area/`*Messages*`. It does
  not validate authentication, model configuration, RPC startup, or
  `pichat-rpc-command` wrappers.
- **Open interactive Pi setup** (`pichat-diagnostics-open-interactive-pi`) opens
  a separate terminal for `/login`, `/model`, and `/settings`. A live terminal
  is reused only when its target/transport, working directory, effective command,
  environment, and executable search context match. A mismatch opens another
  terminal without stopping the existing process. Local wrappers/containers
  require explicit `pichat-diagnostics-interactive-command`; PiChat does not
  guess how to remove RPC arguments from arbitrary commands.
- **Open settings file** (`pichat-diagnostics-open-settings`) visits the owning
  local or SSH target's settings file, not `auth.json`.
- **Customize PiChat** (`pichat-diagnostics-customize`) opens the `pichat` group.
  `pichat-diagnostics-customize-transport` remains a compatibility alias.

The chooser explains and omits unavailable Pi actions for backends without the
required capability; Emacs customization remains available. No setup action is
automatic, and opening diagnostics never repairs, restarts, or edits a runtime.

This repository's personal menus add chat `SPC m D` for safe diagnostics and
inspector `SPC m r` / `SPC m q` for refresh/return (including raw inspectors).
The manager's existing `SPC m D` remains unchanged. In Insert state use
`M-SPC m`; native mode keys remain usable without these personal menus or Evil.

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

For Vim-first navigation, the optional `pichat-evil.el` layer keeps those views
and the runtime manager in Evil Normal state while preserving their native
Emacs keymaps for other users:

```elisp
(with-eval-after-load 'pichat
  (require 'pichat-evil)
  (pichat-evil-setup))
```

This repository enables that layer in `user/pichat.el`. In chat, Normal-state
`RET` toggles a submitted-message disclosure when on one, otherwise retaining
Evil's movement; enter Insert state to send with `RET`, or use
`C-c C-c` / `SPC m s` from either state. In read-only views, `q` uses the
PiChat-specific close/return policy instead of Evil Collection's generic
`quit-window`. History uses `j/k` for entries, `RET` to jump, `za` to fold,
`zv` to preview, and `gr` to refresh. The runtime manager uses `RET` to open,
`zv` to toggle its preview, and `gr` to refresh. Runtime and response previews
also use `gr` to refresh. In rendered response views, `]r` / `[r` navigate
next/previous settled prose responses without taking over Evil's `n` / `N`
search repeat. The local
`SPC m` menus provide preview, details, and other PiChat actions without
taking over Vim's `/`, `n/N`, `v`, `f`, `t`, or `C-o` in Normal state. In chat,
`[[` / `]]` move between user messages, `[a` / `]a` between activity-group
headers, and `[t` / `]t` between visible tool blocks. These Normal-state
bindings leave literal brackets available in Insert state. Consult's
`C-o` preview remains a minibuffer control. The single-key lists below describe
native Emacs bindings; the Evil-specific keys above and `SPC m` menus apply
when this optional layer is enabled.

## Local verification

This repo loads PiChat through `user/pichat.el`.

Exact tested Pi releases and previously reviewed upstream RPC changes are
recorded in [`PI_COMPATIBILITY.md`](./PI_COMPATIBILITY.md). Before testing an
upgrade, run `pichat/test/report-upstream-rpc-changes.sh` to list changes to
Pi's RPC and session-format/compaction documentation since the recorded review
watermark. Earlier session-format changes require a separate backfill. Compatibility is advanced only after the
complete real-Pi suite passes; see [`TESTING_GUIDELINES.md`](./TESTING_GUIDELINES.md).

Commands:

- `M-x pichat` — open the preferred current-scope chat
- `M-x pichat-global` — open the preferred global chat
- `M-x pichat-launch` or `C-u M-x pichat` — configure an advanced launch;
  choose `p` for an independent named preset, or use the default manual preset
- `M-x pichat-session-manager` — manage all retained RPC runtimes
- `M-x pichat-smoke-test` — start Pi RPC and call `get_state`
- `M-x pichat-stop-session` — stop current RPC process
- `M-x pichat-add-reference` — insert a DWIM Emacs reference into a PiChat prompt

Chat keys:

- `RET` / `TAB` or mouse-1 on a skill header — expand/collapse that invocation
- `w` on a skill header — copy its original full Pi message

- `RET` / `TAB` or mouse-1 on a long submitted user block — expand/collapse it
- `w` on that block (Evil Normal `g y`) — copy its original full message text
- `RET` — send prompt in Emacs state or Evil Insert state; in Evil Normal state,
  toggle a submitted-message disclosure or otherwise move as usual
- `S-RET` — insert newline
- `C-c C-k` — abort; queued steering and follow-up text is cleared from Pi
  and prepended to the current editor draft before the run is stopped
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
- `M-x pichat-show-diagnostics` / local `SPC m D` — safe cached diagnostics;
  see “Diagnostics: inspect versus setup” above for inspector keys, raw-data
  warnings, setup actions, and ownership rules
- Ordinary chat status shows only bounded, redacted diagnostic summaries and
  distinguishes local startup/process exit failures from valid Pi RPC errors
- `C-c C-0` — dismiss active diagnostic notices, preserving diagnostic history
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
  the active runtime's model through Pi RPC. Pi's `set_model` also writes that
  choice as its global default for future processes. Use the `m` switch in `pichat-launch` when the selection must be
  run-local. Model availability comes from the current Pi runtime's cached
  snapshot and does not force a catalog refresh
- Click the thinking suffix in that control (for example, `.H`) — cycle Pi's
  model-supported thinking levels; non-reasoning models omit the suffix, while
  unavailable and failed controls display `.?` and `.!`
- `C-c C-x` — Pi command/template/skill picker
- At the beginning of the prompt, type `/` and invoke completion-at-point to
  complete currently available Pi commands, templates, and skills
- `C-c C-p` — open **Session History** for the current session file
- `C-c C-b` (or the chat-local `SPC m b` menu in this repository) — switch the
  active runtime to a selected saved session, keeping its owner scope and tab.
  `C-u C-c C-b` forces the basic picker. In the archive-backed switch picker,
  Consult Embark `j` switches the originating runtime and opens Session History
  at the selected content match; `RET` switches without jumping.
- `M-x pichat-sessions-browse-files` (or global `C-c p b` in this repository)
  — browse saved sessions and open a selection in a new independent runtime
  rooted at its recorded working directory; the existing runtime is untouched.
  A compatible live `pi-archive` or explicitly trusted standalone archive
  enables Consult search; otherwise the basic file picker is used. A prefix
  argument forces the basic picker. In this repository, independently opened
  chats use the same project-tab display policy as manager `b`.
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

Capability validation and ordinary archive metadata, preview, and relation
requests use `pichat-archive-run`. Each helper captures an 8 MiB stdout limit
(`pichat-archive-output-limit`) and a separate 64 KiB stderr limit
(`pichat-archive-stderr-limit`) at startup. Exceeding either fails and terminates
that helper; PiChat never accepts truncated JSON or a truncated helper error as
a successful result. A zero byte limit permits only an empty stream. These are
retained-capture bounds, not limits on a single delivered chunk, OS/transport
buffers, or the helper's own memory.

Status validation defaults to five seconds (`pichat-archive-discovery-timeout`),
and ordinary queries to fifteen (`pichat-archive-query-timeout`), after process
startup returns; synchronous TRAMP setup is not timed. Direct callers of the
helper runner can disable its timer with nil or a nonpositive timeout; this does
not change the separate RPC command-discovery deadline. Discovery owns
cancellation of its status helper;
request callers may cancel the returned process, and `pichat-archive-reset`
cancels archive-boundary helpers. Capture buffers, pipe endpoints and timers
are released before terminal callbacks. Endpoint cleanup does not certify remote
or descendant shutdown. Consult's separate streaming search stage retains its
existing stdout/timeout checks; the new stderr limit does not apply there.
These settings never cap or truncate canonical Pi RPC transcript data.

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
When the active pi-archive helper recognizes a complete Pi skill invocation as
the title prompt, its display title shows `[skill] name — trailing request`
(or `[skill] name` without a request). The saved-session browser uses that
archive-provided title without changing the original archived prompt or the
compatibility title; explicit session names still take precedence.

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
parent and `c` for children. `RET` opens the selected session independently in independent-open browsers,
while the chat's switch browser uses `RET` to switch. With Embark, `j` in the
switch browser switches the originating runtime and opens Session History at a
loadable best entry; independent-open browsers omit switch/jump actions.
`r` also browses relations, and relation candidates inherit the browser's actions. `RET` loads only a resolved nested session whose source exists, and
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

Session History starts with the `no-tools` filter. Filters cycle with `F` in this order:

- `default` — conversation entries and tool results, without bookkeeping rows;
- `no-tools` — `default` without tool-result rows;
- `user-only` — user-message rows only;
- `labeled-only` — entries carrying resolved Pi labels, not raw label records;
- `all` — every valid entry, including bookkeeping rows. Pi `context_edit`
  entries are hidden by the default filters and shown here with their target and
  omission/replacement kind; replacement content is not rendered. These edits
  affect future model context, not the raw conversation transcript.

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
- `C-c C-h` — render the canonical assistant response at point, or the latest
  canonical assistant response when point does not identify one
- `RET`, `TAB`, or mouse-1 on an activity header — expand or collapse that
  source-ordered tool group
- `C-c C-;` — expand or collapse the activity group header at point
- `C-c C-l a` / `C-c C-l A` — next/previous visible activity group header
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
- `C-c C-l t` / `C-c C-l T` — next/previous visible tool block
- `C-c C-l u` / `C-c C-l U` — next/previous user message using stable logical
  node properties rather than fontification
- `C-c C-.` — jump by explicit priority to the latest running tool, pending
  extension request, non-empty live tail, or active prompt
- `C-c C-,` — open an expanded editor initialized from the trimmed current
  prompt, or return to its existing unsaved editor
- `C-c C-c` in compose — trim its text, replace the chat prompt without
  submitting, close compose, and return to the corresponding prompt position
- `C-c C-k` in compose — discard the compose editor without changing the prompt
- Compose editors are never silently reassigned after target-buffer death or
  source rebinding; failed replacement leaves their text intact. Applying or
  cancelling closes only the owned editor display, leaving later changes to
  unrelated windows alone
- `M-x pichat-chat-export-transcript-to-markdown` — export authoritative
  canonical transcript model data, including complete canonical tool output,
  without reading rendered, folded, or truncated buffer text

## Emacs references

`pichat-add-reference` inserts a lightweight reference into a PiChat draft
instead of maintaining persistent Emacs-side context; it does not send the
draft. Invoke it from a source file, Dired, or compilation buffer. With
Bufferlo enabled, a sole chat local to the selected tab receives the reference;
multiple local chats require a choice, and no local chat prompts for a chat
rather than silently targeting another tab. Without Bufferlo, chats in the
source project's owner scope are preferred; ambiguity or no match prompts for
a chat. `C-u M-x pichat-add-reference` always asks for the destination.
An invocation in a chat targets that chat; without a region it prompts for a
file to reference rather than referencing the entire transcript.

Active regions in file buffers become file/line references, file buffers
reference the current defun/symbol/line, Dired references marked files, and
compilation buffers reference the source error location. Non-file buffers and
regions (including selected chat text) write their contents to a temporary
`.txt` file and insert its path as a reference; compilation buffers without a
resolvable error do the same.
Only the selected text is written for a region. PiChat uses Emacs's
`make-temp-file` and does not track or delete these files. Their lifetime depends
on the operating system's cleanup policy for the chosen directory; Emacs exit
and PiChat session closure do not remove them. Large contents (over 80,000
characters by default) require confirmation.

The temporary file must be readable by the destination Pi runtime. Local
runtimes default to Emacs's `temporary-file-directory`; SSH runtimes default
to the remote host's `/tmp` through TRAMP, without requiring a path mapping.
For mapped/container runtimes, or to override either default, set
`pichat-reference-temp-directory` to a writable directory shared with or mapped
to Pi; an unmapped override is rejected before writing. A custom directory
may not be cleaned automatically by the OS.

## Draft target boundary

Emacs integrations may capture a chat's unsent draft destination with
`pichat-chat-draft-capture`, then check `pichat-chat-draft-current-p` and use
`pichat-chat-draft-text`, `pichat-chat-draft-append`, or
`pichat-chat-draft-replace`. A target belongs to one chat buffer, its owning
runtime, and its exact captured Pi session source (including the reported
saved-session pathname). These are draft-editing operations, **not** prompt
submission: a stopped runtime can still receive draft text, while sending
requires the separate live RPC submission path. They do not alter pending
images or recoverable submissions.

If PiChat learns a saved-session pathname after an action captured a nil
pathname—even for the same Pi session ID—the old action is conservatively
invalidated. Start the action again; it never silently retargets a different
source. This transition has been reproduced synthetically, not measured in an
ordinary Pi workflow. A verified restart of the same saved source retains
its draft target; an ordinary switch, including A → B → A, does not. A
verified unwritten-empty restart intentionally retargets existing compose
editors only after the new source has committed. Compose replacement still
preserves compose text on failure but does not roll back target text after an
injected insertion failure (W04 was closed without implementing rollback).

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
`switch_session` to Pi. It translates the saved runtime working directory back
to a host path. Independent opens start a new runtime owned by that directory;
explicit switches update the existing chat's `default-directory` but do not
change its immutable owner scope.

When `pichat-path-mappings` is non-nil, a selected saved session file must be
covered by a mapping.  PiChat rejects an uncovered file instead of sending a
host-only path to Pi.  If the saved working directory is not covered, PiChat
loads the session using its startup host working directory and reports the
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
store. PiChat does not inject host extension paths into SSH startup; the bundled
tool-control helper is explicitly copied to private target storage when needed,
not passed as an inaccessible host path. An explicit SSH target never falls
back to local Pi. Automatic reconnect, host/guest
session synchronization, and remote compilation reruns are not provided.

Use `M-x pichat-path-validate-mappings` from a chat to inspect its mappings,
`M-x pichat-diagnostics-open-settings` for the owning settings file, and
`M-x pichat-diagnostics-probe-pi` to check executable/version availability
through the transport, not RPC, authentication, model, or wrapper health.

### SSH reconfiguration guarantees and limits

Guarded reconfiguration is supported on **Linux targets with readable procfs**.
The bundled helper must have reported the actual Pi process's PID, procfs start
time and boot ID when that runtime started. TRAMP's shell PID is not a substitute.
Older runtimes without this identity, other platforms and inaccessible procfs
remain blocked; there is no force-restart bypass.

Before stopping Pi, PiChat establishes an observer against the captured SSH
target and verifies that exact process is still present. Replacement requires
both an identity-qualified disappearance record and the observer's clean exit.
A dead local SSH endpoint, a successful signal command or transport EOF alone
is **not** remote-exit evidence. PiChat does not search for and signal remote
PIDs to force this transition.

`pichat-reconfigure-shutdown-timeout` (default 5 seconds) bounds observation,
not synchronous TRAMP connection/file setup or connection prompts. Timeout,
connection loss and probe failure retain the shutdown obligation and readable
restart snapshot. Retry/restore must freshly verify every unconfirmed original
or failed replacement process before starting another writer; Leave stopped
also requires confirmed exit. The restart retains its transport-qualified
saved-file key independently of active-attempt or endpoint liveness, without
reconnecting during claim lookup. The launcher's selected-session admission and
Jobs **Continue in chat** honor that claim, including after failed retry/restore
or an explicit Stop. Forget and chat closure refuse to discard an uncertain
writer's owner/snapshot; there is no acknowledgment bypass. Unknown writer
identities remain blocked when automatic recovery cannot verify them. Ordinary
verified local stopped-runtime behavior is unchanged. This does not extend the
duplicate-writer policy of other saved-session open/switch entry points.
A replacement must acquire its own verified identity before a saved source can
load or an unwritten source can commit.
Private helpers can remain on the target while shutdown is uncertain; their
housekeeping is separate from exit confirmation. These actions never delete the
saved session file.

Runtime identity, owner scope, chat/draft, run-local model and captured target
remain stable. Saved Pi sessions retain their source and active branch; eligible
unwritten, conversation-free Pi sessions intentionally receive a new Pi session
ID, as defined in `GLOSSARY.md`. This is not reconnection or resumption of an old
remote process. Source claims are Emacs-local: there is no distributed lock or
guarantee against unrelated external Pi writers.

Isolated real-SSH tests on Pi 1.4.0, Emacs 31.1 and TRAMP 2.8.2.31.1 cover saved
and unwritten restart, actual preset/Tools declarations, old-process absence
before each replacement, and injected post-reload failure/restore. Background-job
checks additionally cover captured-target completion, manual continuation into a
fresh Pi session with transferred previous run context, and an interval-triggered
worker followed by an ordinary captured review job. They independently verify
actual-Pi absence before each new process and after completion; they do not certify
modifying descendants or workspace safety. A separate live graphical Emacs check
drives the launcher, preset chooser, SSH Tools picker and confirmed restart. The
SSH target used for this verification is the same host reached through real
SSH/TRAMP, not a cross-host/network-failure lab.
Malformed evidence, lost probes, timeouts, cancellation and stale callbacks
are covered deterministically offline; shared network connections are not
interrupted by tests. See `TESTING_GUIDELINES.md` for reproduction commands.

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
profiles and presets that override tools or prompts are not supported;
use a plain Pi command for those launches until a wrapper-aware command builder
is implemented.

## Emacs-defined tools

The PiChat bridge exposes Emacs-defined tools to Pi. Local runtimes load the
bundled bridge automatically when Emacs-defined tools are selected
(`pichat-bridge-extension-file` overrides it); SSH runtimes cannot use it.
Before each agent turn the bridge asks Emacs for the runtime's selected tool
definitions; there is no separate handshake. If Emacs answers with another
protocol version, the bridge declares no tools and its extension status reads
`incompatible-protocol:VERSION`. Use `pichat-define-tool` for short,
synchronous operations: the body receives `params` and returns its final result
directly. For example:

```elisp
(pichat-define-tool buffer-summary
    (:description "Summarize an Emacs buffer"
     :group "Buffers"
     :instructions "Prefer this tool when the buffer has unsaved changes"
     :parameters (:type "object"
                  :properties (:name (:type "string"))
                  :required ["name"]))
  (with-current-buffer (get-buffer (plist-get params :name))
    (format "Buffer %s has %d characters" (buffer-name) (buffer-size))))
```

The body must return a string; for structured data return JSON text from
`pichat-tools-json`. Any other value, including nil, reaches Pi as a tool error
"Emacs tool NAME returned no text". Registration refuses a tool Pi could not
declare: a name outside letters, digits, `_` and `-`, a label or description
that is not a string, parameters that are not a JSON object schema, or a
definition `json-serialize` cannot encode. The error names the tool. If
building the definitions still fails while a runtime asks for them, PiChat
declares no Emacs-defined tools for that turn and records a diagnostic.

While a tool runs, `pichat-tools-calling-session` is the runtime that called
it (nil outside bridge calls). A mutating tool can pass
`:approval-summary #'my-summary`: a function of `params` returning a short
description (for example the title of the thing it changes) shown in the
approval prompt beside the raw arguments. It runs only when a prompt is shown;
if it fails, the prompt shows the arguments alone. For strict argument handling
and compact results, tools can use `pichat-tools-check-params`,
`pichat-tools-count-param`, `pichat-tools-boolean-param` (the bridge decodes
JSON `false` as nil), `pichat-tools-id-param`, `pichat-tools-display-text`,
`pichat-tools-truncate` and `pichat-tools-json`.

**Registering a tool makes it selectable, not exposed.** Each runtime offers
only the Emacs-defined tools selected for it; the default is none. Select them
in `x Tools` under **Emacs-defined tools**: groups show selected/available
counts (`x1`, `x2`, … open a group), and inside a group `a`/`n` select all or
none, or toggle individual tools. Or give an explicit-tool preset a baseline:

```elisp
(pichat-make-preset 'jobs-agent
  :description "Inspect and schedule saved jobs."
  :tools '("read" "grep" "find" "ls")
  :emacs-tools '("pichat_jobs_list" "pichat_job_inspect" "pichat_job_schedule"
                 "pichat_job_run_now" "pichat_job_run_inspect"))
```

Selections are exact names: tools registered later are listed but never
selected automatically. If a selected tool isn't loaded, the runtime starts
without it and says so; the Tools section shows the same note, and also when
the runtime has no bridge (SSH). Calls to unselected tools
are refused. Change a live runtime's selection with **Reconfigure this
runtime**. Pass-through presets (`:tools :default`, such as `standard`) offer
no Emacs-defined tools.

Earlier PiChat versions offered every registered tool to every bridge-enabled
runtime; now add `:emacs-tools` to your preset or select them in `x Tools`.
Selecting a tool does not approve it: mutating tools keep their own approval
policy (see [Permissions](#permissions)).

### Saved-job tools

The **Jobs** group is always registered (and, like any group, offered only when
selected). It lets an agent inspect saved jobs, manage their timing, and run,
follow and cancel job runs; it cannot create or edit jobs. The mutating tools
(`pichat_job_schedule`, `pichat_job_run_now`, `pichat_job_run_cancel`) ask
approval by default; their prompts name the job, its target and directory.

- `pichat_jobs_list` and `pichat_job_inspect` return job IDs, summaries, timing,
  whether a timer is running, the next occurrence and recent runs. Times are
  Unix seconds with UTC and local forms.
- `pichat_job_schedule` does one of:
  - `kind` `once`/`interval` with `start` (and `interval_seconds` ≥ 60): save
    that timing and enable it, unless `enabled` is `false`;
  - `kind` `none`: remove timing;
  - only `enabled`: switch existing timing on or off.

  Repeating an identical request changes nothing, and neither does a request
  that returns an error: the job's configuration and the future start are
  checked before any timing is saved. Removing or disabling timing never
  cancels queued or active runs.
- `pichat_job_run_now` starts a saved job exactly like Jobs → Run job, without
  changing its timing, and returns the job run ID. As in Jobs, a saved job has at
  most one unfinished run, so the error names the run already pending; a job run
  therefore cannot start its own saved job. A queued run says what it waits for.
  `input` (at most 4,000 characters) is required exactly when the job declares a
  run input prompt, which `pichat_job_inspect` shows as `input_prompt`; jobs
  without one refuse it. The approval prompt shows the input's first line.
  Called from a job run, the new run records `requested_by` and continues that
  run's [run chain](#review-loops); a chain at `pichat-jobs-max-chain-runs` runs
  is refused.
- `pichat_job_run_inspect` returns one job run's state, result, reason, run
  `input` if any, `requested_by` if a job run started it, its chain `round` and,
  once finished, its final response (up to 4000 characters, truncation marked)
  from the captured run-end evidence, so it stays readable after the run's chat
  is closed. If the evidence is missing or changed, the stored 2000-character
  summary is returned and labelled. While the run's runtime is retained (and
  still bound to the run's saved session file, since runtime IDs restart with
  Emacs), its `runtime_id` can be passed to `pichat_chat_read`.
- `pichat_job_run_cancel` removes a scheduled or queued run. For an active run
  it asks the runtime to abort and reports the state recorded afterwards. A run
  whose prompt was not sent yet finishes as cancelled. Once the prompt was sent,
  the run becomes uncertain when the agent stops (or after
  `pichat-jobs-control-timeout` if it does not), exactly as when cancelling in
  Jobs: PiChat cannot verify that processes started by its tools have stopped,
  so the run keeps its job slot and blocks its saved job until you release it
  in Jobs. Finished and uncertain runs, and a run whose completion is already
  being cleaned up, cannot be cancelled. A job run cannot cancel itself.

The tools use the same Jobs owner as `M-x pichat-jobs`, starting it if needed
just as opening Jobs would (which also resumes your other enabled schedules).
Intervals are elapsed time, not calendar recurrence, so local times shift
across DST. As with all saved-job timing, Emacs must keep running and missed
occurrences are not replayed.

### Chat tools

The **Chats** group is always registered and read-only. It never creates,
selects, opens or changes a chat or runtime, and listing chats never starts
Jobs.

- `pichat_chats_list` describes each retained runtime: `runtime_id`, name,
  directory, target, state, whether it is waiting for user input, model,
  preset, whether its chat buffer is open, the `job_run_id` of the latest job
  run it executed, and `self` for the caller. An unnamed job worker is named
  after its job. Runtime IDs are valid only in the current Emacs session.
- `pichat_chat_read` returns the recent user and assistant messages of one
  runtime (`messages`, default 10, at most 30; each message's text up to 1000
  characters, truncation marked). Settled messages come first, then those of
  the reply in progress, marked `settled: false`, which may still change. Tool
  calls are named only; thinking, tool arguments and tool results are omitted. A
  runtime whose chat buffer is closed reports `transcript_available: false`.

### Orchestrator jobs

A saved job whose preset selects the Jobs and Chats tools can act as an
orchestrator, for example on an elapsed-interval schedule: it checks what other
chats are doing, starts saved jobs, reads their results and cancels runs.

```elisp
(pichat-make-preset 'orchestrator
  :description "Start, follow and cancel saved jobs; read other chats."
  :tools '("read")
  :emacs-tools '("pichat_jobs_list" "pichat_job_inspect" "pichat_job_run_now"
                 "pichat_job_run_inspect" "pichat_job_run_cancel"
                 "pichat_chats_list" "pichat_chat_read"))
```

- **Approval.** Without a rule, a mutating tool's approval waits until you select
  the orchestrator's chat and answer (see [Permissions](#permissions)), so an
  unattended run stalls. Choose **Always allow** for the tools it must use
  without you. That rule is global: the per-runtime Tools selection is what
  keeps other runtimes from using those tools.
- **Capacity.** The orchestrator is itself a job run and occupies one of
  `pichat-jobs-max-concurrency` slots while it runs. Cancelling a run whose
  prompt was sent leaves it uncertain, holding a slot and blocking its saved
  job until you release it in Jobs; the tools cannot release it.
- **Target.** The orchestrator must run locally, since SSH runtimes have no
  bridge; the jobs it starts may use SSH.
- **Trust.** Chat messages and job responses come from other agents; the tool
  instructions tell the agent to treat them as data, not instructions.

## Permissions

Pi-native tools should be governed by Pi permission packages such as
`pi-permission-gate`. PiChat's local approval layer is only for Emacs-defined
tools, because those execute in Emacs. Approval applies after availability: an
Emacs-defined tool must first be selected for the runtime, and selecting it (or
its whole group) does not approve it. A mutating Emacs tool whose effective
policy is `ask` waits for its owning chat to be selected before prompting;
stored allow/deny decisions and non-mutating tools remain immediate, and are
answered even when the runtime has no chat open.
The prompt shows the tool's summary of the call first, then its name and its
arguments (cut to 300 characters). It offers **Allow once**, **Always allow**
and **Deny** (the default); `C-g` also denies. Only **Always allow** is
remembered, as a global rule in `pichat-approval-policy-file`. To stop being
asked, deselect the tool for the runtime instead; a `deny` rule written in that
file is still honoured.
A waiting approval belongs to the agent run that issued the call. When that run
ends (for example on abort), the request is withdrawn: it no longer counts in
`UI:N`, never prompts later, and if its prompt was already open, choosing Allow
does not run the tool. A tool that is already running is not cancelled.

# PiChat glossary

Shared terms for discussing PiChat. **Runtime**, **Pi session**, **saved session file**, and **Session History** refer to different things. For commands, keybindings, configuration, and operational details, see [README.md](README.md).

## Keeping this glossary minimal

- Define shared, user-facing concepts only when their meaning or distinction needs clarification.
- Reuse existing terms rather than naming each implementation mechanism or behavior.
- Keep definitions brief. Put configuration syntax, file paths, protocols, guarantees, limitations, and operational instructions in README.md or implementation documentation.

## Identity and lifetime

| Term | Meaning |
|---|---|
| **Runtime** | A PiChat-managed Pi RPC process and its Emacs-side session object. Its identity remains stable when the loaded Pi session changes; manager rows identify runtimes. |
| **Pi session** | Pi's conversation state, identified by a Pi session ID. It can have a saved session file and an active branch; it is not the RPC process hosting it. |
| **Saved session file** | A Pi JSONL file containing persisted session history that can be loaded into a runtime. It does not store a PiChat preset or runtime identity. |
| **Source** (active source) | The Pi session currently loaded in a runtime. |
| **Source rebinding** | Changing the Pi session loaded in a runtime, for example by switching, starting a new session, forking, or cloning. The runtime's identity remains unchanged. |
| **Live runtime** | A runtime whose RPC process is running. Stopped or failed runtimes may remain listed in the manager without being live. |
| **Persistent runtime** | A runtime launched with Pi session storage enabled. Its saved session file may not exist yet; persistence does not describe retention in the manager. |
| **Ephemeral runtime** | A runtime launched with `--no-session`, so its conversation is not saved as a Pi session file. It can still be retained in the manager. |
| **Chat buffer** | The Emacs conversation UI attached to a runtime. Its transcript follows that runtime's active source; closing the buffer and stopping the runtime are distinct operations. |
| **Runtime manager** | PiChat's global view of retained runtimes, including live, stopped, and failed ones. It is not a browser of saved session files. |

## Launch and ownership

| Term | Meaning |
|---|---|
| **Owner scope** | The project or global scope captured when a runtime starts. It remains unchanged when a different Pi session is loaded. |
| **Preferred runtime** | The live runtime designated for ordinary reuse within an owner scope, marked with `★` in the manager. |
| **Independent runtime** | An additional runtime started rather than reusing an existing one, without automatically becoming preferred. This differs from creating a new Pi session inside an existing runtime. |
| **Launch profile** | The choices governing runtime selection or creation: scope, reuse, persistence, target, model, preset, optional Tools customization, and optional conversation intent. |
| **Conversation intent** | A normal-launch choice: default reuse/fresh behavior, a fresh independent conversation, a selection-only saved session, or an explicit route to the current chat. It does not itself mutate a runtime. |
| **Reconfiguration** | An explicitly confirmed restart of a runtime to replace startup preset/Tools without changing its runtime ID or owner scope. An existing saved Pi session is reloaded and verified; an unwritten, verified conversation-free Pi session instead receives a **new Pi session ID**. It is not a Pi session switch or clone. |
| **Restart snapshot** | The last synchronized canonical transcript retained as read-only while a reconfigured runtime is stopping, loading, synchronizing, or failed. For an unwritten session it may contain only startup model/thinking metadata. It is not authoritative state from a replacement process until verified commit. |
| **Source reservation** | An Emacs-local, transport-qualified saved-file claim held during an independent launch; together with retained active restarts it prevents another PiChat-managed writer. It does not detect external Pi processes. |
| **Preset** | A named startup configuration of tools and system-prompt additions or replacement, captured as a resolved snapshot when a runtime starts. It belongs to the runtime, not its saved Pi sessions, and cannot be applied to an already-running process. Explicit-tool presets also provide the baseline for the launch Tools picker; pass-through presets leave Pi defaults unchanged. |
| **Tools customization** | A run-local selection that can remove built-in tools from an explicit preset, enable or disable eligible extension tools, and opt into directly exposed MCP tools. It configures a new independent runtime or an explicitly confirmed replacement, not a live edit or a Pi session/saved-session-file property; an unchanged preset baseline is not a customization. |
| **Default preset** | The preset configured for a new runtime when no named preset is explicitly selected. It differs from the launcher's `default` choice, which permits reuse of a preferred runtime regardless of its captured preset. |
| **Target** | The execution destination for Pi, such as the local machine or a configured SSH host. |
| **Transport** | The mechanism used to start and communicate with Pi at its target, such as local process execution or SSH. |
| **Runtime working directory** | Pi's working directory as seen on its execution host. |
| **Host working directory** | The corresponding working directory as seen by Emacs. Path mappings may translate between Emacs-visible and runtime-visible paths. |

## Loading and rebinding operations

| Term | Meaning |
|---|---|
| **Open a live runtime** | Display an existing runtime's chat without changing its active source or reloading a saved file. |
| **Open a saved session independently** | Start a new runtime and load a saved session into it, leaving existing runtimes untouched. Browser-initiated independent opens use the configured default preset. |
| **Switch to a saved session** | Load a saved session into the current runtime, replacing its active source while retaining its owner scope and startup preset. |
| **Source back/forward navigation** | Switching within one runtime along its recorded fork/clone chain of saved session files. This chain is distinct from archive parent/child relations. |
| **New session** | Create a fresh Pi session in the existing runtime. This does not start another runtime or change its preset. |
| **Fork** | Create and rebind to a new Pi session from a selected historical user prompt, restoring that prompt's text for editing. The fork point is a history entry, not a saved session file selection. |
| **Clone** | Copy the current active branch into a new Pi session and rebind the existing runtime to it. Unlike a fork, a clone does not select a historical prompt. |
| **Stop** | End a runtime's RPC process without deleting its saved Pi session file. |
| **Forget** | Remove a retained, stopped or failed runtime from the manager without deleting its saved Pi session file. |

## Browsing and history

| Term | Meaning |
|---|---|
| **Saved-session browser** | A picker of saved sessions, rather than entries within one session. Its selection context determines whether a file opens independently, replaces the current runtime's source, or is returned to the launcher without opening anything. |
| **Selection-only browse context** | A launcher's saved-session search that returns structured file, Pi session and target provenance to the launch draft; preview and related navigation stay read-only, and mutating Embark open/switch/jump actions are unavailable. |
| **Basic picker** | Saved-session file completion that does not require archive or Consult integration; used when archive-backed browsing is unavailable or explicitly bypassed. |
| **Archive-backed Consult picker** | Search and selection of indexed saved sessions through a compatible `pi-archive` integration. The basic picker is the fallback when this integration is unavailable. |
| **Related-session browser** | A picker of a saved session's resolved archive parent and children. It explores relations between sessions, not branches within one session. |
| **Session History** | A view of entries and branches within the current Pi session, distinct from browsing saved sessions. |
| **Entry / entry ID** | An entry is a Pi record within a session's history; an entry ID identifies that record. An entry ID is not a saved session file path. |
| **Active branch** | The current root-to-leaf conversation path within a Pi session. |
| **Branch preview** | A read-only view of a root-to-entry path in Session History. Previewing does not change the runtime's source or Pi's active branch. |
| **Archive relation** | An indexed parent/child link between distinct saved Pi sessions. It is separate from branches within one session and from a runtime's source back/forward chain. |

## Transcript and rendering

| Term | Meaning |
|---|---|
| **Canonical transcript** | PiChat's synchronized representation of Pi's active-branch entries, used as the authority for settled chat content. It also applies to ephemeral sessions. |
| **Live tail** | Provisional chat content derived from RPC events while an agent run is in progress, before canonical synchronization. |
| **Settlement** | The transition from an agent run's provisional output to synchronized canonical content after the run ends. |
| **State synchronization** | Fetching Pi's state or entries to update PiChat after a run or source rebinding. |
| **Source generation** | A PiChat generation marker used to invalidate stale events, callbacks, or caches after source rebinding. It is not a Pi session ID. A verified same-source runtime restart does not create a navigation entry. |
| **Process generation** | A distinct runtime-process lifetime marker; events and transport buffers from a stopped process cannot act on its replacement, even when it hosts the same Pi session. |
| **Repaint** | Refreshing the chat display from PiChat's synchronized transcript model, rather than treating visible buffer text as the source of truth. |
| **Rendered response view** | A read-only rendering of one settled assistant response's prose. The chat itself retains the response's exact Markdown source. |

## Messages and tool display

| Term | Meaning |
|---|---|
| **Activity group** | A source-ordered, foldable presentation group for thinking and tool activity. It is distinct from an individual tool call. |
| **Tool block** | The chat presentation of an individual tool call, including available arguments, output, status, and folding controls. |
| **Tool enrichment** | Presentation-only classification or file locations derived from tool activity; it does not change Pi's recorded transcript. |
| **Settled tool result** | Tool output represented in synchronized Pi entries, as opposed to provisional output shown while a tool is running. |

## Prompt and input

| Term | Meaning |
|---|---|
| **Draft** | Unsent text in the chat prompt; placing text in a draft does not send it to Pi. |
| **Steering message** | A message queued to redirect the agent during an ongoing run. |
| **Follow-up message** | A message queued for delivery after the agent finishes its current work. |
| **Recoverable submission** | Prompt content retained by PiChat after a rejected or ambiguously failed submission so the user can restore it. |
| **Attachment** | An image associated with a pending draft or submission. |
| **Compose editor** | A separate buffer for editing a draft before returning its text to the chat prompt without submitting it. |

## Tools, extensions, and permissions

| Term | Meaning |
|---|---|
| **Built-in tool** | A tool supplied by Pi itself, such as `read`, `edit`, or `bash`. |
| **Extension tool** | A tool registered by a Pi extension, distinct from a Pi built-in or an MCP tool. |
| **MCP tool** | A tool provided through a Model Context Protocol (MCP) server. |
| **Tool declaration** | Offering a tool directly to the model, distinct from loading the extension or MCP server that provides it. |
| **Tool catalogue** | A target-specific snapshot of tools available for selection, including initially disabled extension tools. |
| **PiChat bridge** | The optional Pi extension that connects a Pi runtime to PiChat's Emacs-side tool and UI facilities. |
| **Emacs-defined tool** | A PiChat tool implemented on the Emacs side and exposed to Pi through the bridge, rather than a Pi built-in tool. |
| **Approval policy** | PiChat's allow/ask/deny policy for Emacs-defined tools. It does not govern Pi-native tools. |
| **Extension UI request** | An extension's request for interaction with the user, routed to the owning chat. |

## Code artifacts and execution

| Term | Meaning |
|---|---|
| **Settled chat artifact** | A selectable code fence, link, table, or LaTeX span in settled assistant prose. It is not a live tool call. |
| **Artifact runner** | PiChat's explicit action to execute code from a selected fence, outside Pi's tool-call and permission flow. |
| **Artifact result view** | The buffer showing an artifact runner's executed code, output, and outcome. |
| **Result handoff** | Inserting a bounded runner report into the chat draft for review; it is not sent to Pi automatically. |
| **Spill file** | A file retaining runner output that exceeds a preview or sharing limit; it may outlive the result view. |

## Configuration and integration

| Term | Meaning |
|---|---|
| **Built-in tool selection** | The selection of Pi built-in tools offered for a run, using Pi's defaults or startup tool flags. Explicit-tool presets allow a subset through the Tools picker and disable MCP when no MCP tool is selected; pass-through presets retain Pi's normal tool behavior. |
| **Base system prompt** | Pi's normal system instructions, which a preset can retain or replace. |
| **Appended system prompt** | Instructions added to the system prompt without replacing its base text. |
| **Run-local model** | A model selected for one newly launched runtime rather than changed as Pi's persistent default. |
| **Path mapping** | Translation between Emacs-visible paths and paths accessible to the Pi runtime, including saved session files and working directories. |
| **Archive capability** | A validated `pi-archive` integration that permits archive-backed browsing of saved sessions. |

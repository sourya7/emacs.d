# PiChat glossary

Terms for PiChat lifecycle and session operations. **Runtime**, **Pi session**, **saved session file**, and **Session History** refer to different things. For commands, keybindings, configuration, and operational details, see [README.md](README.md).

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
| **Launch profile** | The choices governing runtime selection or creation: scope, reuse, persistence, target, model, and preset. |
| **Preset** | A named startup configuration of tools and system-prompt additions or replacement, captured as a resolved snapshot when a runtime starts. It belongs to the runtime, not its saved Pi sessions, and cannot be applied to an already-running process. |
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
| **Saved-session browser** | A picker of saved sessions, rather than entries within one session. Its selection context determines whether a file opens independently or replaces the current runtime's source. |
| **Basic picker** | Saved-session file completion that does not require archive or Consult integration. |
| **Archive-backed Consult picker** | Search and selection of indexed saved sessions through a compatible `pi-archive` integration. The basic picker is the fallback when this integration is unavailable. |
| **Related-session browser** | A picker of a saved session's resolved archive parent and children. It explores relations between sessions, not branches within one session. |
| **Session History** | A view of entries and branches within the current Pi session, distinct from browsing saved sessions. |
| **Entry / entry ID** | An entry is a Pi record within a session's history; an entry ID identifies that record. An entry ID is not a saved session file path. |
| **Active branch** | The current root-to-leaf conversation path within a Pi session. |
| **Branch preview** | A read-only view of a root-to-entry path in Session History. Previewing does not change the runtime's source or Pi's active branch. |
| **Archive relation** | An indexed parent/child link between distinct saved Pi sessions. It is separate from branches within one session and from a runtime's source back/forward chain. |

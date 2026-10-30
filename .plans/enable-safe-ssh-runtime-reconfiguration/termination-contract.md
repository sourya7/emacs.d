# SSH termination investigation

Investigation completed 2026-10-30. This records the selected implementation
approach, not implemented behavior or a claim that SSH reconfiguration works.

## Installed implementation

- Emacs 31.1, TRAMP 2.8.2.31.1.
- Installed Lisp source directory:
  `/nix/store/6y2b1b8wiw29iw48ndncnhgv6bdchwd8-emacs-pgtk-31.1/share/emacs/31.1/lisp/net/`.
  Sources are compressed there. The references below are decompressed line numbers.
- `tramp-sh.el:3048-3298`, `tramp-sh-handle-make-process`: ordinary async
  startup takes the remote shell's `echo $$` result and stores `remote-pid`
  (`3198-3202`), then executes `cd ... && ... exec ... env ... PROGRAM ARGS`
  (`3124-3140`). An exec-only executable preserves that PID; an arbitrary
  spawning wrapper need not. This is not proof of the actual RPC writer's PID.
- `tramp.el:5509-5549`, `tramp-direct-async-process-p`, and `5563-5692`,
  `tramp-handle-make-process`: the alternative direct-async path constructs a
  local SSH process; it sets `remote-command` and `tramp-vector`, not
  `remote-pid`. Do not assume every SSH process has the latter property.
- `tramp.el:7573-7613`, `tramp-signal-process`: sends remote `kill` through
  `tramp-send-command-and-check`, returning 0/-1. It neither fingerprints the
  process lifetime nor confirms exit. `tramp-interrupt-process` at 7535-7569
  also attempts process-group signaling and waits on local transport liveness;
  it is not a bounded, PID-reuse-safe restart barrier.
- Emacs 31.1 C source is available at
  `/nix/store/bgsd2zrswpdhf3pssz86v3nv14bja7sh-emacs/` (version confirmed in
  `configure.ac:26`). `src/process.c:1083-1158`, `Fdelete_process`, immediately
  marks the process signaled/exited and notifies its sentinel. It calls
  `record_kill_process`; `src/callproc.c:196-212` sends SIGKILL to the **local**
  process group. There is no remote signal hook or remote wait in this path.
- Consequently local `process-live-p`, `process-status`, a stopped session,
  and an intentional-stop sentinel establish only local transport teardown.
  Neither a successful signal request nor a disconnected transport is an
  exit receipt for the remote Pi process.

## Reproducible evidence

Run the supporting, isolated Linux/SSH fixtures:

```sh
PICHAT_TEST_SSH_DIRECTORY=/ssh:mojo@bigbox.lan:/tmp/ \
  emacs -Q --batch -L pichat \
  -l .plans/enable-safe-ssh-runtime-reconfiguration/tramp-contract-tests.el \
  -f ert-run-tests-batch-and-exit
```

Final run: 2/2 passed, 10.51 seconds. The transport-loss fixture compares the
PID and `/proc/PID/stat` start-time field before/after deleting only its owned
SSH endpoint. It demonstrates the same remote lifetime survives local
`signal` status, then waits for its self-expiration. The second fixture accepts
a successful TERM request while the TERM-immune process remains present, then
verifies normal exit. No forceful remote cleanup or shared connection cleanup is used.
A batch-private control connection is established before opening the owned
async channel; no user's Emacs/TRAMP connections are touched.

Initial fixture runs were not valid passing evidence: starting the async
channel before establishing the control connection produced stale/mixed probe
output and a natural-exit wait failure. Requiring a control connection first,
anchored readiness output, and exact PID validation fixed the fixture. This
also reinforces the need for strictly validated, attempt-qualified responses,
not loose output matching or a zero exit code alone.

The existing `pichat-integration-ssh-rpc-streams-and-stops-cleanly` test passed
1/1 in 5.29 seconds against `/run/current-system/sw/bin/pi` on the same SSH
host. This uses isolated fake-provider/agent/session state. It does **not** test
reconfiguration or abnormal Pi shutdown. The unit suite passed: 875 tests,
867 expected, 8 skipped, 0 unexpected. Full real-Pi and live UI checks belong
to later phases and were not run here.

## Selected minimal design for implementation

Use transport-owned lifetime identity and a pre-established asynchronous
observer, not a persistent remote supervisor or a new remote service.

1. Initially support Linux SSH targets with readable `/proc`, stable boot
   identity, and the bundled lifecycle helper. Other targets and runtimes
   without verified identity remain blocked, with a capability-specific reason.
   Local behavior is unchanged. Existing SSH runtimes lacking the helper do
   not silently acquire support.
2. Stage a small bundled Pi lifecycle helper during SSH RPC startup using the
   existing private target-helper staging pattern. Obtain **actual Pi** PID,
   `/proc/self/stat` start time and boot ID through a versioned internal
   request/reply. Reuse the internal command/UI-input acknowledgement idiom of
   `bridge/pichat-tool-control.ts`, not a model tool, user prompt, conversation
   entry, arbitrary stdout readiness heuristic, or command-line process search.
   Bind replies to a random request token, exact process object and generation.
   Do not rely on TRAMP's shell PID being the actual RPC writer.
3. Before stopping, start a dedicated observer through the captured transport.
   Its strict, token-qualified ready reply must verify the same boot ID and
   actual Pi PID/start-time baseline. Only then may the transaction stop Pi.
   Establishing this observer is preflight: failure must leave the old runtime
   untouched. TRAMP connection setup can be synchronous; do not put a new
   connection attempt inside the shutdown barrier or imply its timers can
   preempt a synchronous TRAMP prompt.
4. The already-running observer checks for that lifetime's disappearance.
   Accept a validated absence of the captured PID, or a different start time
   on the **same boot**, only with a healthy/readable procfs baseline. Start
   time handles PID reuse without signaling a potentially reused PID. Changed
   boot identity, malformed output, permissions errors, unexpected observer
   exit, transport loss, missing baseline or timeout are **unknown**, not gone.
   Use a finite remote loop plus an Emacs deadline and generation/operation
   ownership checks. No replacement starts just because a timer fires or an
   observer disconnects. No remote PID kill is required: normal transport
   teardown may stop Pi; if it does not, timeout safely and retain recovery.
5. Preserve an immutable per-process shutdown obligation until validated exit.
   The final replacement-start boundary must require all previous obligations
   discharged, independently of session state or `process-live-p`. Each new
   replacement must acquire actual-process identity before loading the saved
   source. A replacement whose identity cannot be established is uncertain,
   never an implicit permission to start again.
6. Retry/restore creates a fresh observer/attempt for unresolved identities;
   cancellation retires callbacks but does not erase obligations. Retain
   obligations for both the original process and failed replacements, including
   those stopped by failure cleanup. Confirmed-exit evidence can survive a
   failed load; a failed probe cannot. Leave-stopped must distinguish local
   teardown from confirmed remote exit and cannot discard uncertainty.
7. Capture observer transport, runtime cwd, process identity and generation;
   never resolve the destination from changed user settings or fall back local.
   Stage-file cleanup must follow confirmed remote exit, not the local sentinel.

This avoids Python/pidfd dependencies and PID-based remote signaling. It is
intentionally Linux-only initially; portable non-Linux support, general wrapper
supervision and automatic reconnection remain out of scope. The helper and
observer protocol, strict procfs error handling and failure-race behavior still
require implementation and tests in the next phases. If implementation cannot
establish this identity and observer contract without broader supervision,
stop and escalate rather than weakening the confirmation rule.

## Restart/recovery audit targets

- `pichat-reconfigure.el`: preflight and stop-and-wait have local-only gates;
  `--empty-unwritten-source-p` also has a local-only condition and its path
  checks must use the captured transport.
- `--stop-then-start`'s recovery `allow-stopped` branch currently starts when
  Emacs reports no live process, without remote evidence. This is a critical
  bypass to close before removing any SSH gates.
- `--start-replacement` checks only the original local process's liveness.
  A failed replacement is a separate lifetime that also needs confirmation.
- `--finish` and explicit cancellation copy operation plists to retire late
  callbacks. Preserve that ownership mechanism, but ensure copied recovery
  state retains all unresolved shutdown obligations and evidence.
- `recover` is local-only and checks saved/unwritten paths as local paths;
  both eligibility and revalidation must be transport-qualified.
- `leave-stopped` currently checks only session liveness. Its label and
  retained state must not imply remote shutdown was confirmed.
- `pichat-rpc.el:393-460`: stop and sentinel must not manufacture remote-exit
  evidence. `pichat-tool-runtime.el:25-44` retains staged helpers for uncertain
  SSH shutdown; verified lifecycle evidence should govern later cleanup.
- `pichat.el:1536-1605`: confirmation, retry/restore and leave-stopped UI must
  preserve uncertainty rather than offering recovery that bypasses the barrier.

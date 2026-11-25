# PiChat testing guidelines

This document describes how to write and run PiChat tests. It should not become a behavior specification. PiChat behavior should be documented by the tests themselves.

## Principles

- Test behavior users or Pi integration depend on.
- Prefer real `pi --mode rpc` integration when behavior crosses the Pi boundary.
- Use a deterministic fake Pi provider for integration tests; do not use real model APIs.
- Keep small Emacs-only unit tests for parser edge cases, permission logic, and pure rendering/session fixtures.
- Avoid tests that only lock down private implementation details or incidental formatting.
- Do not require network access, API keys, user input, or the user's real Pi config/session directories.

## Expected suites

- Unit tests: JSONL parsing, callback dispatch, approval policy, tool registry encoding, marker/session fixtures.
- Integration tests: real Pi RPC process with a fake provider extension loaded via `-e`.

The default local run is unit-only. Full mode and CI require a working supported `pi` executable; missing Pi is a test failure, not a skip.

## Running tests

Unit-only batch run:

```sh
pichat/test/run-tests.sh
```

Equivalent direct command:

```sh
emacs -Q --batch -L pichat -L pichat/test \
  --eval '(setq pichat-test-include-integration nil)' \
  -l pichat/test/pichat-test.el \
  -f ert-run-tests-batch-and-exit
```

Full run with real Pi integration:

```sh
pichat/test/run-tests.sh --full
```

Equivalent direct command:

```sh
PI_OFFLINE=1 \
PI_SKIP_VERSION_CHECK=1 \
PI_TELEMETRY=0 \
emacs -Q --batch -L pichat -L pichat/test \
  --eval '(setq pichat-test-include-integration t)' \
  -l pichat/test/pichat-test.el \
  -f ert-run-tests-batch-and-exit
```

## Test timing and temporary storage

ERT prints each test's elapsed time and the suite total. Jobs fixtures perform
real atomic metadata writes with forced filesystem synchronization; on a
persistent disk these writes can dominate unit-test time. Do not stub out
persistence or disable its synchronization to speed up the suite.

For faster local iteration on Linux, a writable, sufficiently sized tmpfs can
hold the disposable fixtures instead:

```sh
TMPDIR=/dev/shm pichat/test/run-tests.sh
TMPDIR=/dev/shm pichat/test/run-tests.sh --full
```

This is opt-in: the ordinary commands retain the system temporary directory.
Use an executable tmpfs mount (some systems mount `/dev/shm` with `noexec`),
since some fixtures launch temporary helper scripts. Tests still write, rename,
synchronize and reread files, but tmpfs does **not** exercise physical-disk
persistence. Keep a normal disk-backed run for storage-sensitive verification.
No real provider or user state is used in either mode. Integration diagnostics
cache successful `pi --version` probes per executable for the test process;
real RPC processes and isolated Pi state are still created per fixture.

## Dependency-enabled local runs

To exercise optional Consult, Embark, Evil and Orderless tests rather than
accepting their default skips, use the repository's existing Elpaca builds (or
sources) of `compat`, `consult`, `embark`, `evil`, `goto-chg`, and `orderless`:

```sh
pichat/test/run-tests.sh --with-optional
pichat/test/run-tests.sh --full --with-optional
```

This mode fails immediately if one of those dependency directories is missing
or one of the optional packages cannot load. Inspect the ERT skip list: with
these dependencies present, only the separately opted-in Docker tests should
skip. The default runs deliberately remain dependency-minimal. Neither mode
installs packages; `--full` still uses an isolated offline fake provider and
requires a working supported `pi` executable.

## Opt-in SSH integration

Run the isolated real-SSH transport test with a writable TRAMP parent and the
remote Pi executable:

```sh
PICHAT_TEST_SSH_DIRECTORY=/ssh:test-host:/tmp/ \
PICHAT_TEST_SSH_PI=/path/on/target/to/pi \
  timeout -s USR2 -k 10s 240s pichat/test/run-ssh-tests.sh
```

Use a disposable SSH target or a private loopback sshd with temporary keys,
private fixture directories and normal TRAMP lockfiles. Set
`PICHAT_TEST_SSH_PEER_DIRECTORY` to a writable TRAMP directory on a **different
SSH connection** (a second loopback port works) to enable the independent-
connection test; without it that test explicitly skips. A second port does not
verify a distinct host or filesystem.

The GNU `timeout` command bounds wall-clock runtime even during synchronous
TRAMP setup, where Lisp `with-timeout` can be suspended. On expiry `SIGUSR2`
asks Emacs for a diagnostic backtrace; `-k` provides a hard stop if it cannot
exit. Capture the command output (or terminal transcript for a live frame)
and treat any watchdog exit as failure. After a hard stop, check the private
fixture for leftover processes and files before removing it; do not delete
helpers for a writer whose exit is unverified.

The RPC test creates and removes a unique remote directory, copies only the
fake provider fixture, uses isolated agent/session state, streams one prompt,
stops the remote process, and checks for an orphan. The reconfiguration suite
also copies the tool-control fixture and starts real persistent RPC runtimes.
It checks saved/unwritten restart, actual prompt/tool declarations, independent
procfs evidence before every replacement spawn, post-reload failure/restore,
and catalogue discovery without changing the live runtime. Those tests use
Linux procfs and fail rather than skip when the required capability is missing.
SSH runner tests also run
an explicit shell script in an isolated remote project, verify that both
preview-limit and share-limit-only overflow files in remote `/tmp` are readable
and included in the draft, and check timeout/temporary-script cleanup.
They remove their own remote output files. No test reads normal remote Pi
settings, credentials, extensions, or sessions.

For live UI acceptance, use a **separate non-batch Emacs**, never `emacsclient`
against an instance containing your conversations. This example runs in a
terminal; use `script` to provide a private pseudo-terminal when needed.
All live UI suites disable Transient's exit-time history saving. Set a private
`user-emacs-directory` before loading any suite so Transient also avoids reading
normal user history. This example uses that directory for the result log too:

```sh
private=$(mktemp -d)
PICHAT_TEST_SSH_DIRECTORY=/ssh:test-host:/tmp/ \
PICHAT_TEST_SSH_PI=/path/on/target/to/pi \
PICHAT_UI_PRIVATE="$private/" \
  timeout -s USR2 -k 10s 240s emacs -Q -nw \
  -L pichat -L pichat/test \
  --eval '(setq user-emacs-directory (getenv "PICHAT_UI_PRIVATE") use-dialog-box nil)' \
  -l pichat-test-ssh-reconfigure-ui \
  --eval '(let ((stats (ert-run-tests-batch "^pichat-integration-ssh-reconfigure-live-ui$")))
    (with-temp-file (expand-file-name "result.log" user-emacs-directory)
      (insert (with-current-buffer "*Messages*" (buffer-string))))
    (kill-emacs (if (and (= 1 (ert-stats-completed-expected stats))
                        (= 0 (ert-stats-completed-unexpected stats))) 0 1)))'
```

The test drives Tools Open/Refresh in ordinary launch, Jobs Tools and a
confirmed reconfiguration in a live frame with an offline provider. It verifies
observable UI and runtime state programmatically; it is not human visual
review. It is not loaded by the batch SSH runner. Shared setup/cleanup lives
in `pichat-test-real-ssh-support.el`. No test disrupts shared SSH connections
to simulate network failure; protocol loss, timeout and stale deliveries are
tested offline.

## Jobs verification

Metadata/admission tests live in `pichat-test-job-core.el`; execution, ownership
and manual UI behavior share `pichat-test-jobs.el` and the fixtures in
`pichat-test-job-support.el`. The former executor/lifecycle/UI test files have
been combined rather than adding another suite per screen. Full mode additionally
runs real local Pi jobs against the offline fake provider, including evidence
capture/overflow, cleanup-failure injection, offline conversation preview and explicit
saved-session continuation. Manual background continuation also exercises a fresh
real Pi runtime against captured failure evidence; core/UI tests cover provenance,
settings edits, uncertainty and missing evidence. Lifecycle follow-up integration
uses the same offline provider under two isolated provider identities and separate
scripts/status files. Its example notification goes only to a disposable loopback
HTTP listener—never real notification services. Shared job fixtures decode UTF-8
serialized scripts before writing, including Unicode context cases. Evidence files use the fixture's
temporary metadata root, never normal user storage.
Schedule calculation/transactions use explicit-clock fixtures in the core suite;
owned timer, staged timing/confirmation and local DST picker checks live in the
Jobs suite. Existing-conversation execution has focused tests in
`pichat-test-job-conversation.el`, reusing the same shared fixtures rather than
importing another test suite. Full mode exercises real native timers through
both independent and borrowed offline Pi execution, including preserved retry,
overflow-compaction recovery and active cancellation. All use temporary metadata
and retire owned timers during teardown;
never enable a test schedule in the user's store or adjust the system clock.
The SSH runner includes captured-target background work, fresh-session manual
continuation carrying captured context, and an interval-triggered worker with an
ordinary follow-up. It checks independent actual-Pi absence before each new process
and after completion, plus the remote Pi's captured prompt for transferred context.
These reuse the existing real-SSH fixture, never the user's project or sessions.
A disposable loopback SSH server with temporary keys is sufficient; this verifies
real transport/procfs behavior, not separate-host or network-failure behavior.

Run the separate graphical manual-flow smoke (never against your live Emacs):

```sh
private=$(mktemp -d)
PICHAT_UI_PRIVATE="$private/" \
  emacs -Q -L pichat -L pichat/test \
  --eval '(setq user-emacs-directory (getenv "PICHAT_UI_PRIVATE") use-dialog-box nil)' \
  -l pichat-test-jobs-live-ui \
  --eval '(let ((stats (ert-run-tests-batch "^pichat-integration-jobs-live-ui-")))
    (with-temp-file "/tmp/pichat-jobs-live-result.log"
      (insert (with-current-buffer "*Messages*" (buffer-string))))
    (kill-emacs (if (> (ert-stats-completed-unexpected stats) 0) 1 0)))'
rm -rf "$private"
```

On a Wayland setup where graphical startup is unavailable from the test process,
use `GDK_BACKEND=x11` with a working X display. The explicit result/exit wrapper
avoids graphical shutdown prompts that can leave `ert-run-tests-batch-and-exit`
waiting indefinitely; `/tmp/pichat-jobs-live-result.log` retains the evidence.
These checks cover a live frame, multiline composition, save-without-running, one-off
and saved-job submission without focus changes, progressive settings disclosure,
latest/history/captured-conversation-preview navigation, report disclosure/refresh and real
narrow/wide window sizes. A separate
inert-process live scenario covers cached input, blockers, cancellation context
and uncertain claims without activating a dialog. Neither uses a real
model provider or normal job metadata. Keep these opt-in live-UI and SSH checks
separate from ordinary batch tests because their execution requirements
differ; reusable mechanics belong in support, not imports of another test suite.
The additional `pichat-integration-jobs-live-ui-continuation` scenario drives
Actions, Continue work, additional guidance, Run once and Previous run in a
live frame with the offline provider. It can run alone in a separate `emacs -Q -nw`
instance when no graphical display exists; select that exact test or the terminal
subset below (the frame-resize scenario requires graphics). The
`pichat-integration-jobs-live-ui-execution-settings` scenario also supports a
separate terminal Emacs: it drives the actual shared-composer keys, staged
field edits/cancellation and nested Tools Apply/Cancel return, with discovery disabled. Batch fixtures
cover capture preservation, stale callbacks, pending pickers and continuation
restrictions. The `pichat-integration-jobs-live-ui-followup` scenario also supports
terminal Emacs: it drives After this run selection, None bypass, Run once and
origin/successor navigation using real Pi with the offline provider. Select that
exact test for a terminal run. The
`pichat-integration-jobs-live-ui-schedule` scenario likewise supports terminal
Emacs: it drives actual timing Transient keys, staged Cancel/Save, separate
Enable/Disable and a real timer-triggered offline Pi run without focus changes.
The `pichat-integration-jobs-live-ui-saved-schedule-run-now` scenario drives
Set schedule, Save disabled, Enable and Run now for a future saved-job one-shot,
then opens Actions → Last occurrence to reach its attributable early result. It supports
isolated native/Evil terminal runs. Batch cases additionally cover atomic early
consumption, manual-run timing preservation, stale/disabled/interval rejection,
capacity/queue bounds, reentrant old callbacks and persistence failure.
The interval scenario checks one real elapsed-interval occurrence, anchored future
rearming and Disable; the cached attention/uncertainty scenario also works without
graphics and checks global capacity without workspace blocking. The selected-phase scenario uses
an explicitly installed plans skill (`PICHAT_TEST_PLANS_SKILL=/path/to/plans`) and
only a temporary local plan/artifact. Scripted offline tool choices read the skill
contracts, complete the selected phase, run structural validation and leave the
adjacent phase untouched. This verifies ordinary prompt/tool dispatch, not autonomous
model reasoning or machine-enforced plan gates; no actual project plan is modified.
Without that explicit skill path the selected-phase scenario reports an opt-in skip.

For all terminal-capable scenarios together, use a separate `emacs -Q -nw` with the
result/exit wrapper above and selector:

```elisp
'(and "^pichat-integration-jobs-live-ui-" (not "graphical-resize$"))
```

The `pichat-integration-jobs-live-ui-conversation-schedule` scenario drives the
chat-originated M-x command, read-only inherited configuration, multiline
Apply/Cancel, absolute-time picking, explicit Schedule, report cancellation and
real timer execution in the same live Pi conversation. It supports native and
Evil terminal runs with private storage and the offline provider. It does not
establish real-SSH or human visual acceptance for this execution mode.
The `pichat-integration-jobs-live-ui-conversation-run-now` scenario drives actual
Actions/Run now keys for a future scheduled continuation, verifies early
completion in the same runtime/Pi session, timer retirement and draft preservation.
It supports the same isolated native/Evil terminal setup.
The separate `pichat-integration-jobs-live-ui-continuation-invalidation-feedback`
scenario drives cancellation feedback, repaint, exact report return and both
chat-command and report-Actions rescheduling with no preselected time. Cancelling
the report-side composer returns to the unchanged report. It then verifies native timer delivery after
rename/model selection. It supports isolated native/Evil terminal runs using the
same private offline-provider fixture.

The manual-flow scenario covers shared-composer New, multiline Apply, explicit
Name/Save, the saved report, independent one-off/saved submission, reports and
history in either live terminal or graphical Emacs. The repeat-and-save-as
scenario drives actual Actions/composer/inspection keys, repeated execution and
save-only creation of a reusable definition. Both use the offline fake provider. The separate graphical-resize scenario
requires a GUI-capable Emacs and working display for real frame-resize assertions.
A terminal-only Emacs build cannot supply that check merely by setting DISPLAY.
The Actions scenario checks the absence of a permanent report label/button and
drives actual native a/Evil g a entry, quit, raw inspection/return and command keys.
The list-actions-and-marks scenario drives those entry keys from Runs, Requested
by navigation, chain-wide d/u/U marks, refresh preservation and x deletion with
both confirmation answers. It uses only finished fixture records and never
starts Pi. The manual-flow scenario enters New through M-x so Transient's
command-loop setup runs before its first suffix key.
Other scenarios enter report commands and related-run navigation through the same
contextual menu, including nested timing. The schedule scenario opens Actions →
Last occurrence to reach its submitted run. Batch cases distinguish that run from
newer manual attempts, offer no entry for occurrences with no run, check that
reports contain no buttons besides folds and answer links, and check TAB
navigation does not activate links or expose raw inspection inline. The
manual-flow scenario also drives the Actions/f path-copy key without leaving its
report; follow-up navigation uses Actions → After-run run and Triggered by. Batch cases cover pending/undispatched plain follow-up
status, guarded path copying/absence and menu-only remote-exit rechecking with
capability loss. The menu-only remote-exit fixture uses an inert process and
stubbed recheck callbacks, never an SSH connection.
The saved-editor scenario drives both list and Actions entry, all field keys,
multiline Apply/Cancel, asynchronous model return, nested Tools Apply/Cancel and
whole-menu Save/Cancel/quit. Discovery/model choices are fixture-only, not normal
provider lookups. Batch cases cover no-op capture/schedule/history preservation,
write/validation failure, stale/deleted/dead/retargeted origins and cross-buffer
late callbacks. Shared-composer cases also exercise chat-origin draft/attachment
preservation, duplicate callbacks during a later picker in the same scope,
replayed already-applied Tools returns (which must leave the installed draft,
the later picker's token and the menu untouched, also after close, replacement,
origin death, save or submission), owned discovery cleanup, reentrant final actions during capture/confirmation and
post-commit dispatch failure without duplicate submission. Conversation-schedule
cases inject `error` and `quit` into the delayed verification replies before and
after the durable commit: before, only that Schedule action is released and the
staged prompt/time remain; after, the run stays authorized and observed and the
composer is not reopened. Instruction drafts must retain plain text, not editor display
properties; the saved-editor scenario also collects garbage after editor cleanup.
Admission cases exercise legacy resource metadata as inert historical data alongside
new captures without it. A real offline-Pi scenario starts two jobs in the same
workspace concurrently while checking the global limit still applies. Error/abort
fixtures require explicit inspection/release before continuation; legacy access
labels never waive descendant uncertainty.
Batch command fixtures invoke the validated dispatch path without a popup; use
`pichat-test-job-goto-button` when asserting a fold toggle or answer link is
present inline.
Optional Evil runs additionally load `evil` and `pichat-evil`, enable `evil-mode`,
and call `pichat-evil-setup` before running tests.
Use a private `user-emacs-directory` for the separate instance; picker history must
not go into normal user state. Never run these scenarios in the user's live Emacs.

These are programmatic checks, not human visual acceptance. A graphical frame can
still be iconified by the window manager: `display-graphic-p` and passing window
geometry assertions do not prove the layout was visible. Review the displayed
screens separately before closing a visible-layout acceptance task.

## Queue panel terminal check

`pichat-test-queue-live-ui.el` is opt-in and is not loaded by the batch runner.
It drives actual editor and panel keys in a live frame against isolated offline
Pi: manual compaction, image-bearing held steering, newest/item recall, deletion,
successful release, busy RET/M-RET, steering-first queue display and recall-all.
It checks that recalled/deleted input never reaches Pi. Run in a separate native
terminal Emacs, for example under `script -q -e -c '<command>' terminal.log`:

```sh
private=$(mktemp -d)
PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 PICHAT_UI_PRIVATE="$private/" \
  emacs -Q -nw -L pichat -L pichat/test \
  --eval '(setq user-emacs-directory (getenv "PICHAT_UI_PRIVATE") use-dialog-box nil)' \
  -l pichat-test-queue-live-ui \
  --eval '(let ((stats (ert-run-tests-batch "^pichat-integration-queue-live-ui-")))
    (with-temp-file "/tmp/pichat-queue-ui-result.log"
      (insert (with-current-buffer "*Messages*" (buffer-string))))
    (kill-emacs (if (> (ert-stats-completed-unexpected stats) 0) 1 0)))'
rm -rf "$private"
```

For a separate Evil run, add the installed Evil/goto-chg load paths, then
`--eval '(progn (require (quote evil)) (require (quote pichat-evil))
(evil-mode 1) (pichat-evil-setup))'` before loading the test. The fixture enters
Insert state through the command loop so deferred Evil initialization completes
before the first chat shortcut. Both runs use private Emacs history and the
shared temporary Pi fixture, never a live user chat or Jobs store. These are
programmatic terminal checks, not human visual acceptance, real clipboard
acquisition or graphical image-preview verification.

## Saved preset live check

`pichat-test-presets-live-ui.el` drives the real launcher `p`, `x` Tools (with
the offline MCP fixture), `m` model listing and reset (offline fake provider)
and `c` Save preset as keys, including replacement refusal and Tools Cancel,
then reloads the saved presets in a fresh Emacs. It also adds the
`tool-control-extension.ts` fixture under `l` Extensions, turns on
**Include future tools** on its `x` Tools group page and saves it, checking
the saved `:extensions` and `(SOURCE . :all)` forms after a fresh-Emacs
reload, and checks that an old-style saved `:extensions` preset stays listed
under `p` while `x` and `RET` refuse it. The preset-saving scenarios use a
private `custom-file` and launch no runtime. The indirect MCP scenario selects
one `codemode` MCP row in `x` Tools, verifies that the derived access tool is
shown but not saved in the draft, and launches a real ephemeral Pi runtime. The
offline provider checks the exact callable MCP set and initial tool declarations
and calls the selected local fixture tool through codemode. Run these scenarios
in a separate `emacs -Q -nw` (for example under `script` when no tty is
available) with the result/exit wrapper above and selector
`"^pichat-integration-presets-live-ui-"`. For Evil, add the optional load
paths and enable `evil-mode` and `pichat-evil-setup` first. It is a programmatic
check, not human visual review or live Ketch access.

## Opt-in Mermaid Docker tests

With local Docker running and the configured pinned image already present:

```sh
PICHAT_TEST_MERMAID_DOCKER=1 pichat/test/run-tests.sh
```

These tests render valid/invalid source and cancel during container creation
and rendering. They wait for asynchronous cleanup before exiting Emacs. They
never approve image downloads. To select an existing cached digest without
changing configuration, use batch Emacs, load `pichat-test.el`, set
`pichat-artifact-mermaid-image`, and run ERT selector
`"^pichat-mermaid-real-docker"`. SSH-origin local rendering is covered by unit
fixtures and needs no SSH connection or remote Docker daemon.

## Coverage

Coverage is a separate, source-only Undercover run. The normal test command
remains the authoritative uninstrumented check. Start the configured Emacs once
after pulling the coverage setup so Elpaca installs the deferred `undercover`
development dependency, then run:

```sh
pichat/test/run-coverage.sh
```

This prints a per-file text report. To create an LCOV report for CI or another
coverage viewer:

```sh
pichat/test/run-coverage.sh --format lcov
# writes coverage/lcov.info
```

Pass `--full` to either form to include real-Pi integration tests. Add
`--with-optional` to load and require the same dependency-enabled integration
set as the ordinary suite. For a repeatable agent-readable analysis, run:

```sh
pichat/test/run-coverage-analysis.sh
```

This prints one self-contained Markdown report and writes the report, LCOV data,
and captured test log under the gitignored `coverage/` directory. Pass `--full`
to include real-Pi integration tests. The report contains test totals, skips,
weighted and per-file coverage, the largest definition-level deficits, source
line ranges, and all completely uncovered definitions.

A CI or one-off environment that does not use this configuration's Elpaca tree
can set `PICHAT_COVERAGE_LOAD_PATH` to a colon-separated list containing
Undercover and its `dash` and `shut-up` dependencies. Coverage runs reject
`pichat/*.elc` because Undercover instruments source loads only. The report is **partial** on Emacs 31.1 / Undercover 0.8.0: Edebug counters
from `pichat-chat.el`'s live projection callback execute under a different
instrumented function's counter scope. The coverage runner excludes
`pichat-chat.el` instead of treating those synthetic `args-out-of-range`
failures as production defects. Percentages describe only the instrumented
subset, **not whole-package coverage**. The coverage runner fails on any
unexpected test result or reporting error; it cannot silently accept a
failed report from Undercover's nonfatal exit hook. Undercover measures Edebug
forms, not conventional branch coverage; use the report to triage missing
scenarios, not to justify deletions or replace behavioral assertions.

### Per-test overlap

To find tests that may duplicate others, record which instrumented forms each
test executes:

```sh
pichat/test/run-test-overlap.sh
```

This runs the default suite under Undercover (offline, no real Pi or user
state), resetting the Edebug counters before each test. It writes per-test
records, `report.md` and `tests.tsv` to the gitignored `coverage/test-overlap/`.
The report lists, per test file, tests with unique forms and tests whose forms
all run in other tests, naming up to three containing tests. Other modes:

- `--selector REGEXP`: record only the matching tests.
- `--output DIR`: write somewhere else, for example to keep a baseline.
- `--report-only`: rebuild the report from existing records.
- `--coupling`: static counts per test file of private (`pichat…--…`) symbol
  references, `symbol-function` stubs and string-literal assertions; no test
  run.
- `--diff DIR_A DIR_B`: list tests whose recorded forms differ between two
  runs.

The same Undercover dependencies and `PICHAT_COVERAGE_LOAD_PATH` apply as for
`run-coverage.sh`. The report shares that run's limits, and more:
`pichat-chat.el` is not instrumented, load-time code belongs to no test, only
passed tests are compared, and executing a form is not asserting its result.

**Coverage alone never justifies deleting a test.** A contained test is only
a candidate to read. A test whose forms all run elsewhere can still be the only
one asserting an outcome, injecting a fault or exercising a race. Remove or
merge a test only when another named test still protects its behaviour: move
any assertion the protector lacks, and where practical break the behaviour in
a scratch copy (never the working tree) to see the protector fail. Prefer
merging shared guards into one table-driven test over deleting them.

Integration tests must isolate Pi state with temporary `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR`, project cwd, and session directory. They must not read normal user credentials, packages, settings, trust decisions, or sessions. CI should pin one supported Pi version and include `pi --version` in failure diagnostics.

## Synthetic browsing profiles

Run the isolated transcript/artifact and saved-session browsing benchmark:

```sh
emacs -Q --batch -L pichat -l pichat/test/benchmark-browsing.el
```

It creates synthetic canonical assistant runs and temporary JSONL files, times
rendering, run enumeration, artifact parsing/selection, file scan/sort,
cold/warm summary choices, completion and annotation separately, then removes
its files. Configure `pichat-benchmark-browsing-sizes` and
`pichat-benchmark-browsing-repetitions` before loading to change fixture sizes.
Cold means an empty PiChat summary cache, not a flushed OS page cache. The
viewport is modeled; these are neither real redisplay/Avy timings nor SSH/TRAMP
latency measurements. Use the same Emacs/build, fixture sizes and GC settings
for comparisons; do not put wall-clock thresholds in ERT.

### Transcript preview pipeline

Run the separate maintained settled-transcript benchmark (requires
`markdown-mode` on the load path):

```sh
emacs -Q --batch -L pichat -L /path/to/markdown-mode \
  -l pichat/test/benchmark-transcript-preview.el
```

The default fixture is deterministic and synthetic: 2,880 entries with thinking,
1,280 settled tools and 160 assistant prose runs. Set `PICHAT_BENCHMARK_5X=1`
to add five concatenated copies with unique entry and tool-call IDs. Explicitly
set `PICHAT_BENCHMARK_SESSION=/path/to/session.jsonl` to read a real local
saved session file instead; its last entry selects the root-to-leaf branch.
The benchmark does not discover private sessions, print their content/paths,
write files, start Pi or contact a runtime. Real inputs can consume substantial
memory, especially with 5x enabled.

It reports cache/build/context/render, insertion, eager Markdown fontification
and tool indexing separately, plus rendered text byte sizes. Legacy preview
baselines remain in the plan record; the per-entry renderer has been removed.
Collapsed/expanded refer to activity groups; tools retain the default summary
view. Each stage is one sample with a preceding untimed GC; in-stage GC remains
enabled and is reported. Compare repeated fresh processes using the same input,
Emacs and GC settings. These are not actual redisplay, first-paint, manager-row
change or interactive toggle measurements; there are no timing-based ERT gates.

A separate component table times complete `render-entries`, activity/thinking
and focused tool-toggle operations, including validation, region replacement,
fontification and indexes. It also compares a 24-node tail from cached canonical
data with one built from cached linear entries (including the full history
build). These are component CPU/wall-clock measurements, not migrated caller
row changes, actual first paint or redisplay. Budget labels apply to the 1x
reference input; 5x reports scaling only. Input reading and branch selection
are outside the timed component operations, and no runtime is contacted.

## Compatibility verification workflow

[`PI_COMPATIBILITY.md`](./PI_COMPATIBILITY.md) is the authoritative record of
exact Pi releases that passed the complete suite and upstream RPC changes that
have already been reviewed. A persisted-session fixture version is provenance,
not a verified compatibility claim.

Before testing a newer Pi release:

1. Run `pichat/test/report-upstream-rpc-changes.sh`. By default it compares the
   recorded `last_reviewed_pi` with the installed `pi --version`; explicit old
   and new refs are also accepted. Set `PI_UPSTREAM_DIR` to reuse a full local
   checkout of the upstream Pi repository. The report scans `rpc.md`,
   `rpc-commands.md`, `json.md`, `session-format.md`, and `compaction.md`;
   watermark blob IDs identify `rpc.md`. Before marking the expanded review
   complete, backfill session-format/compaction changes predating this scan.
2. Give every reported RPC overview, command, or event-document commit a
   disposition in the compatibility ledger. Inspect the implementation diff
   too when the documentation alone does not establish client impact.
3. Add or activate focused tests for behavior PiChat implements.
4. Run `pichat/test/run-tests.sh --full` against the exact target release.
5. Append the result to the verification history. Advance `last_verified_pi`
   and its immutable release-commit and RPC-document-blob identifiers only when
   the complete suite passes. Failed attempts remain recorded without advancing
   that watermark.
6. Advance `last_reviewed_pi` and its identifiers only after every intervening
   RPC documentation change has a ledger row, including changes classified as
   compatible, intentionally unsupported, or not applicable.

Do not remove old ledger entries after implementing them. Updating their
status and adding source/test locations prevents later upgrades from
re-identifying the same upstream feature.

## Development checklist

Report focused test-file sizes while reviewing test organization:

```sh
wc -l pichat/test/pichat-test-*.el | sort -n
```

This report is informational; file size is not a failing test gate.

## Integration test requirements

Integration tests should start real Pi with a command shaped like:

```text
pi --mode rpc --no-session --offline --no-approve --no-builtin-tools \
  --no-context-files --no-skills --no-prompt-templates --no-themes \
  --no-extensions -e pichat/test/fixtures/fake-provider.ts \
  --model pichat-fake/pichat-fake
```

Session persistence tests may omit `--no-session` and pass an isolated `--session-dir`.

Provider-only suites load only the fake provider. Bridge suites additionally load `pichat/bridge/pichat-bridge.ts` with another explicit `-e`; the bridge is not part of unrelated integration startup. Generic extension-UI and lifecycle scenarios may load a dedicated `rpc-test-extension.ts` that exposes deterministic dialog, blocking, and shutdown controls.

Use a successful `get_state` response as the startup readiness barrier. Ordinary scenarios must then disable automatic retry and compaction through RPC before prompting. Tests for those features enable them explicitly.

The fake provider must be deterministic and offline. It should consume a per-test queue of scripted turns, validate expected context, support text/tool/error/delayed responses, honor `AbortSignal`, fail on unexpected extra model calls, and allow the test to verify that all expected turns were consumed. Prompt matching may be a convenience but must not be the primary scripting mechanism.

A registered fake provider must include inert `baseUrl`, `apiKey`, and `api` values because Pi requires them when custom models are defined, even if `streamSimple` performs no HTTP request.

## Shared test support

Keep reusable mechanics in support modules rather than requiring another test
suite for its fixtures:

- `test/pichat-test-support.el`: isolated runtimes, processes, RPC waits, and files.
- `test/pichat-test-history-support.el`: tree builders and temporary history buffers.
- `test/pichat-test-chat-support.el`: chat-buffer cleanup and live-event builders.

Keep scenario-specific display policies, window layouts, and behavioral assertions
in the test suite. Support modules should not register ERT tests.

## Writing good tests

A good PiChat test has:

- a name that states the desired behavior;
- a minimal setup;
- assertions on observable state, emitted events, RPC messages, or visible transcript content;
- bounded event/state waits with useful diagnostics for async behavior;
- separate waiting for prompt acceptance and the later `agent_settled` event;
- cleanup through `unwind-protect` for processes, buffers, temp directories, timers, and event handlers;
- isolation/reset of mutable PiChat globals such as session registries, event handlers, tool registrations, and approval state.

Avoid:

- broad snapshots of entire buffers when only one behavior matters;
- arbitrary sleeps instead of event/state waiters;
- silently skipping real-Pi tests when full mode was requested;
- dependencies on real user config, existing sessions, installed models, or credentials;
- assertions about private helper structure unless there is no better observable seam.

Tests for desired but unimplemented behavior should use standard `ert-skip` with a precise TODO reason and retain the intended assertions where practical. Activate the test in the same change that implements the behavior. Required tests must pass; do not use expected failures as a permanent substitute for implementation.

## Behavior documentation policy

When a behavior is covered by tests, do not duplicate it in prose design documents. Use prose only for testing mechanics, test style, and how to run the suite. Future intended behavior should be represented by skipped/TODO tests rather than long design sections.

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

## Opt-in SSH integration

Run the isolated real-SSH transport test with a writable TRAMP parent and the
remote Pi executable:

```sh
PICHAT_TEST_SSH_DIRECTORY=/ssh:lima-devbox:/tmp/ \
PICHAT_TEST_SSH_PI=/etc/profiles/per-user/dev/bin/pi \
  pichat/test/run-ssh-tests.sh
```

The test creates and removes a unique remote directory, copies only the fake
provider fixture, uses isolated agent/session state, streams one prompt, stops
the remote process, and checks for an orphan. It never reads normal remote Pi
settings, credentials, extensions, or sessions.

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

Pass `--full` to either form to include real-Pi integration tests. For a
repeatable agent-readable analysis, run:

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
`pichat/*.elc` because Undercover instruments source loads only. Macro-heavy
results can be imperfect because Undercover uses Edebug; use coverage to find
missing scenarios, not as a substitute for behavioral assertions.

Integration tests must isolate Pi state with temporary `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR`, project cwd, and session directory. They must not read normal user credentials, packages, settings, trust decisions, or sessions. CI should pin one supported Pi version and include `pi --version` in failure diagnostics.

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

---
description: Run PiChat ERT coverage and analyze the agent-readable report
argument-hint: "[--full]"
---
Run and analyze the PiChat ERT coverage report.

1. Read `pichat/TESTING_GUIDELINES.md` before running the coverage workflow.
2. Run:

   ```sh
   pichat/test/run-coverage-analysis.sh $ARGUMENTS
   ```

3. Verify that the test run completed without unexpected results. If it failed,
   stop and report the failure with the relevant diagnostics from
   `coverage/test-output.log`.
4. Read the complete generated `coverage/coverage-analysis.md`. Use that
   Markdown report directly; do not independently parse `coverage/lcov.info`
   unless the report appears inconsistent or incomplete.
5. Inspect the source and existing ERT tests for the highest-deficit files and
   definitions before deciding what is important.
6. Distinguish among:
   - high-risk behavior that needs tests;
   - optional-dependency tests that were skipped;
   - interactive adapters or thin wrappers with limited risk;
   - potentially obsolete or unreachable code that should be audited rather
     than covered artificially;
   - important error, lifecycle, protocol, permission, and state-transition
     branches despite otherwise high module coverage.

Provide a concise report containing:

- test totals, skipped tests, and weighted overall coverage;
- strongly covered areas;
- the largest meaningful coverage gaps, citing source paths and definitions;
- why each high-priority gap matters behaviorally;
- a prioritized list of the next tests to add;
- coverage-tool limitations or skipped dependencies that affect interpretation.

Do not prioritize solely by percentage: account for absolute missed forms,
module size, reachability, user impact, and boundary/lifecycle risk. Do not edit
source or tests as part of this analysis.

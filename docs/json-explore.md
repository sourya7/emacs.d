# JSON and plans explorer

The generic explorer browses JSON snapshots without editing them. The plans
adapter uses the same interface but knows how to fetch plans CLI details and
visit authoritative Org records. Both load through `user/package.el` after
Elpaca activates the installed `vui` package.

## Browse JSON

- `M-x json-explore-buffer` parses the current buffer, or just the active region.
  Run it again to take a new snapshot after editing the input.
- `M-x json-explore-run-command` prompts separately for an executable and its
  arguments. For example, use `jq` with arguments `. data.json` from the file's
  directory. Quote an argument if it contains spaces. Arguments go directly to
  the program: no shell, pipelines, redirection, or glob expansion. The command
  runs asynchronously in the captured local working directory. Only run
  executables and arguments you trust; the explorer does not sandbox them.

Arrays of objects show the union of their keys; other arrays use index/value
columns. An object opens as a page with an aligned list of scalar fields and
initially folded sections for nested objects and arrays. Expand a section to
browse it inline, or press `RET` on its heading to drill into a separate history
entry. Expanded arrays have their own table headers and sort order. Cell motion,
inspection and path copying also work on inline cells.

Missing members, `null`, `false`, zero, empty strings, and empty containers
remain distinct. Use a table's index cell to open the whole row. Long or
multiline strings open as full text; inspection opens typed JSON rather than
the shortened summary.
The header line shows the source at the root and adds path segments as you
open cells (for example, `Plans list › [0] › tasks`). When you scroll into a
table, the column names take over the header line; scroll back up to see the
breadcrumb again. Drilling and history reuse one explorer buffer and do not
rerun the command. Inspections reuse a companion buffer.

Use explicit refresh to rerun a command for the current history entry, at the
same JSON path if nested. Pending refresh or a failed command/parse does not
replace the last good data; look in the explorer for errors and stderr. Buffer
and region snapshots have no command to refresh.

## Browse plans

- `M-x plans-explore-list` shows ID, title, status and completed/total progress.
  Press `RET` on the row's index to fetch its detail explicitly.
- `M-x plans-explore-show` prompts for a plan ID and opens its detail directly.
- `M-x plans-explore-check` shows validation results, including valid JSON
  findings at exit 1. `C-c C-o` fetches details from the selected list or check
  row.
- `M-x plans-explore-workspaces` shows workspace inventory and orphans. With
  `--local` selection, workspace inventory is unavailable and is not requested.

Use `C-u` before list or check to include archives, or before show to select an
archived record. Details and refresh retain the original CLI selectors. In a
fetched detail, expand `tasks` to browse tasks inline or drill into it with
`RET`. Expand both `workspaces` and `orphans` to see them on the same page.
`RET` on `org` displays a read-only Org snapshot without visiting the file. `gf` (or `C-c C-v`) visits the
actual file in View mode; within a task it jumps to the line from the snapshot,
which may be stale. The adapter does not mutate records or perform workspace
operations.

## Keys

Default Evil normal-state keys (themed bindings respect your Evil Collection
overrides):

- `j`/`k` move vertically; `gh`/`gl` move between columns. `TAB`/`S-TAB` move
  between cells; `g]`/`g[` also work in terminals where Tab and `C-i` coincide.
- `RET` drills into a cell. `S-RET`/`go` opens the full cell in another window;
  `M-RET`/`gO` displays it there without moving focus. `K` inspects typed JSON.
- `za` toggles the section at or enclosing point, `zo` opens it, and `zc`
  closes it. `zR` opens all sections on the page and `zM` closes them.
- `C-o`/`C-i` go back/forward through view history, restoring expansions,
  sort order, cell and scroll position.
- `o` sorts the table or field list at point (toggle direction on that column);
  `O` reverses its sort. `/` and `?` search rendered text; `y` remains Evil yank.
  `Y` copies the selected cell's jq-compatible bracket path.
- `gr` refreshes, `g?` describes the mode, and `q`/`ZZ`/`ZQ` quit.

Without Evil, use `RET`, `TAB`/`S-TAB`, `C-c C-b`/`C-c C-f` for history,
`C-c C-r` for refresh, `C-s`/`C-r` to search, and `q` to quit the explorer
window. Other actions are also available by command name via `M-x`, for example
`json-explore-toggle-section`, `json-explore-sort`, `json-explore-inspect`,
or `json-explore-copy-path`.

## Settings and limits

- `json-explore-row-limit` (default 500) caps rendered rows per table or field
  list; each capped list reports how many rows are shown.
  `json-explore-cell-width` (default 40) caps summary width, not inspection
  text.
- `plans-explore-program` defaults to `plans` on Emacs's `exec-path`; set it to
  the path of an executable wrapper if needed. `plans-explore-selection`
  defaults to `nil` (normal CLI discovery from the current directory). Set it to
  a plist with `:root`, `:config`, `:project`, or `:local t` as needed; `:project`
  and `:local` are mutually exclusive. For example:

  ```elisp
  (setq plans-explore-selection '(:root "~/src/my-project" :project "my-project"))
  ```

The explorer parses finite JSON values in memory. The row limit limits rendering,
not input size. No streaming or TRAMP command execution is supported.

## Fixture tests

From the repository root with the installed `vui` build on disk:

```sh
emacs -Q --batch -L .local/elpaca/builds/vui \
  -l user/json-explore.el -l user/plans-explore.el \
  -l user/test/json-explore-test.el -l user/test/plans-explore-test.el \
  -f ert-run-tests-batch-and-exit
```

If testing in a jj workspace without `.local`, substitute the invoking
checkout's `vui` build path. Tests use fixtures and fake plans commands, not the
real plans store.

## Live terminal smoke test

From the repository root in a terminal (at least 40 rows by 120 columns),
run the walkthrough with default keys and with Evil Collection overrides:

```sh
emacs -Q -nw -l user/test/explorer-live-smoke.el
EXPLORER_OVERRIDE=1 emacs -Q -nw -l user/test/explorer-live-smoke.el
```

Set `ELPACA_BUILDS` to the existing Elpaca builds directory if it is not
`.local/elpaca/builds`. The smoke test uses the repository's explorer module
registration in an isolated session without installing packages or loading
unrelated user modules. It checks cell navigation, fold keys, inline tables,
scroll and history, the breadcrumb and pinned column headers, refresh
diagnostics and read-only visits through the real `plans` CLI. It needs `plans` on PATH and a centrally mapped
checkout. Set
`EXPLORER_PLAN` to a valid active-inventory ID with tasks if `json-data-explorer`
is not in that checkout's inventory. No plans or workspace state is written.

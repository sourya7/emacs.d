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
columns and objects use key/value columns. Missing members, `null`, `false`,
zero, empty strings, and empty containers remain distinct. Use the index/key
cell to open a whole row. Long or multiline strings open as full text; the
inspection command opens typed JSON rather than the shortened table summary.
The breadcrumb shows the current path. Drilling and history reuse one explorer
buffer and do not rerun the command. Inspections reuse a companion buffer.

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
fetched detail, drill into `tasks` to browse tasks. `RET` on `org` displays a
read-only Org snapshot without visiting the file. `gf` (or `C-c C-v`) visits the
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
- `C-o`/`C-i` go back/forward through view history, restoring position and sort.
- `o` sorts by the column at point (toggle direction on that column); `O`
  reverses the sort. `/` and `?` search rendered text; `y` remains Evil yank.
  `Y` copies the selected cell's jq-compatible bracket path.
- `gr` refreshes, `g?` describes the mode, and `q`/`ZZ`/`ZQ` quit.

Without Evil, use `RET`, `TAB`/`S-TAB`, `C-c C-b`/`C-c C-f` for history,
`C-c C-r` for refresh, `C-s`/`C-r` to search, and `q` to quit the explorer
window. Other actions are also available by command name via `M-x`, for example
`json-explore-sort`, `json-explore-inspect`, or `json-explore-copy-path`.

## Settings and limits

- `json-explore-row-limit` (default 500) caps rendered rows per view; the view
  reports how many rows are shown. `json-explore-cell-width` (default 40) caps
  cell summary width, not inspection text.
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

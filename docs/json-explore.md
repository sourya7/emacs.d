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
archived record. Details and refresh retain the original CLI selectors. The
plan page shows status and progress above an initially expanded Tasks table.
Press `RET` on a task index to drill into that task, or `Y` to copy its path.
The workspace page shows Workspaces and Orphans as independent inline tables.
Press `za` on Org text to read it inline, or `RET` to open a read-only Org
snapshot without visiting the file. `gf` (or `C-c C-v`) visits the actual file
in View mode; within a task it jumps to the line from the snapshot,
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

## Writing an adapter

An adapter describes a trusted JSON source, optionally adds buffer-local action
handlers, and can render a page using `vui`. It can derive a mode from
`json-explore-mode`, but does not need command remaps or access to private
explorer state. Plans is one adapter; the explorer does not depend on it.

### Sources and history

- `json-explore-make-source` accepts `:program`, `:argv`, `:directory`, `:label`,
  and opaque `:context`. Without a program, pass parsed JSON as `:value` for a
  static source. Treat sources, contexts and typed values as read-only.
- `:success-codes` defaults to `(0)`. `:validate` is called with the parsed root
  value and accepted exit code before installing it. Signal an error to reject
  the result and retain the last good view. `:columns` selects columns in a root
  array of objects: `(KEY HEADER [FORMATTER])`. A formatter receives the typed
  member and returns a single-line display string, optionally with faces;
  missing members bypass it. Labels never change sorting, paths, or inspection.
- Accessors: `json-explore-source-program`, `json-explore-source-argv`,
  `json-explore-source-directory`, `json-explore-source-label`,
  `json-explore-source-context`, `json-explore-source-success-codes`,
  `json-explore-source-validate`, `json-explore-source-columns`,
  `json-explore-source-view`, and `json-explore-source-value`.
- `json-explore-open-source` takes a source and optional `:buffer-name`, `:mode`,
  and `:no-display`. It returns the explorer buffer immediately and starts a
  command asynchronously. By default the name uses the label plus a hash of
  executable, directory and arguments. Reopening resets that buffer's history.
- `json-explore-push-source` takes a source and optional `:label`, and starts a
  new history entry in the current explorer. Use this for an explicit detail
  fetch. Back/forward reuse snapshots; refreshing runs only the active source.
- `json-explore-show-message` takes a label and text plus the same options as
  `json-explore-open-source`. It shows a non-refreshable message, not an empty
  JSON result. Unknown keyword arguments to the adapter entry points are ignored.

### Queries and actions

- `json-explore-current-source`, `json-explore-current-context`,
  `json-explore-current-value`, `json-explore-current-snapshot`, and
  `json-explore-current-path` query the active entry. The snapshot is the root
  result; the value is the portion at the current path. A path is a list of
  string keys and zero-based array indices (`nil` at the root).
- `json-explore-thing-at-point` returns `nil` off a cell, or a plist with
  `:path`, `:row`, `:row-value`, `:column`, `:value`, `:source`, and `:context`.
  `:row` is an original key or index, not a sorted offset. `:column` is a JSON
  key or a structural symbol such as `index`, `value` or `section`.
- Add an open handler to `json-explore-open-functions` using
  `(add-hook 'json-explore-open-functions #'my-open nil t)` in the derived mode.
  It receives the thing plist and an action (`drill`, `other-window`, or
  `display`, which should keep focus). The first non-nil return handles the
  action. If all decline, the explorer drills or inspects normally.
- A handler on `json-explore-visit-functions` receives the thing plist (or nil
  off a cell) and returns nil, a live buffer, or a location plist with `:file`
  (an absolute local file) or `:buffer` (a live buffer), and optional `:line`
  (one-based). Use `:buffer` with `:line` when the handler needs to control
  how the file is opened. `json-explore-visit` opens the first location in
  View mode and jumps to the supplied line, or reports that there is no location.
  Both hooks also accept global handlers; the usual `add-hook` ordering applies.
- `json-explore-inspect-text` takes a string and optional `:mode`, `:stay`, and
  `:label`; `json-explore-inspect-value` takes typed JSON and optional `:stay`.
  Both return the reused, read-only companion buffer.

### Layout

`:view` is called with `(value view-context)`. The context plist has `:path`,
`:source`, `:context`, and `:snapshot`. Use `json-explore-view-function` as a
buffer-local renderer when a source does not specify one. Return nil to let the
normal renderer take over (for instance, when drilling into a custom page).
Renderers should not fetch data or run actions. They can compose `vui` vnodes
with these builders during rendering:

- `json-explore-table`: render an array at `:path` with optional `:columns`.
- `json-explore-fields`: render an object at `:path` with optional `:fields`
  (`(KEY LABEL [FORMATTER])` entries in order; absent keys are skipped).
- `json-explore-section`: fold a value at `:path` with optional `:title`,
  `:expanded` (initial state), and `:body` (a vnode; defaults to the generic
  page for the value). A fold heading points to the value at its path.

Use absolute JSON paths within the current view. Tables and fields default to
its path; a section needs a descendant path. Render at most one cell layout
per path. The explorer supplies keyed navigation, sort and fold history, and
copy-path without adapters having to name or track individual cells.

### Example: widgets

This small adapter uses a fixed fake command. Replace the source with a real
local executable and arguments to browse your own data.

```elisp
(defun widget-explore-validate (value _exit)
  (unless (and (hash-table-p value) (vectorp (gethash "items" value)))
    (error "Expected a widget object with an items array")))

(defun widget-explore-page (_value view-context)
  (unless (plist-get view-context :path)
    (vui-vstack
     (json-explore-fields :fields '(("name" "Widget")))
     (json-explore-section :path '("items") :title "Items" :expanded t
       :body (json-explore-table :path '("items")
                                :columns '(("n" "Units" number-to-string)))))))

(defun widget-explore-open (thing action)
  (when (equal (plist-get thing :path) '("name"))
    (json-explore-inspect-text (plist-get thing :value)
                               :stay (eq action 'display))))

(defun widget-explore-visit (thing)
  (when-let* ((file (plist-get (plist-get thing :context) :file)))
    (list :file file :line 1)))

(define-derived-mode widget-explore-mode json-explore-mode "Widgets"
  (add-hook 'json-explore-open-functions #'widget-explore-open nil t)
  (add-hook 'json-explore-visit-functions #'widget-explore-visit nil t))

(defun widget-explore (file)
  (interactive "fWidget notes file: ")
  (json-explore-open-source
   (json-explore-make-source
    :program "printf" :argv '("%s" "{\"name\":\"demo\",\"items\":[{\"n\":10},{\"n\":2}]}")
    :label "Widgets" :context (list :file (expand-file-name file))
    :validate #'widget-explore-validate :view #'widget-explore-page)
   :mode #'widget-explore-mode))
```

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

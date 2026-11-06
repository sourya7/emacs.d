---
name: pichat-jobs
description: Create or edit reusable PiChat job definition JSON files when asked to save agent work as a job. Explain explicit Emacs discovery, review and import; never edit the runtime database or start work automatically.
---

# PiChat job authoring

Author files only. Pi does not discover or import these jobs itself. Do not edit
`jobs.json`, evidence, schedules or run history. Do not invoke Emacs APIs or a
bridge tool to import, run or enable timing. Ask the user to review/import in
Emacs. Saving a definition is not permission to execute its instructions.

## Choose the source location

- Project: direct `*.json` files in `<selected-project-root>/.pi/jobs/`.
- Global: direct `*.json` files in `<effective-Emacs-agent-directory>/jobs/`;
  normally `~/.pi/agent/jobs/`. PiChat honors its effective
  `PI_CODING_AGENT_DIR`, including `pichat-pi-extra-env` overrides.
- Confirm the selected project, Emacs-visible source location, named preset,
  concrete model and intended execution target. Do not guess registry names.
- Sources must be local to Emacs (mounted files are supported), not TRAMP paths.
  With SSH Pi, remote home/agent directories are NOT necessarily Emacs's source
  roots. Do not write an unmapped remote copy and claim Emacs will discover it.
  If the intended source is unavailable, provide JSON for the user to save there.
  A named SSH execution target does not synchronize authored files.

## Write strict version-1 UTF-8 JSON

Project example (directory omitted means the selected project root):

```json
{
  "version": 1,
  "id": "dependency-review",
  "title": "Review dependencies",
  "instructions": "Inspect dependencies and report risks. Do not change files.",
  "model": "provider/model-id",
  "preset": "review"
}
```

Replace `provider/model-id` with the user's concrete choice. A global definition
must additionally supply an absolute Emacs-visible `"directory": "/path/to/project"`.
Project-relative directories resolve against the selected project root, not
`.pi/jobs/`. There is no tilde expansion or environment interpolation. Optional
`"target": {"name": "local"}` is the default; use an explicitly configured target
name for SSH. Do not embed executables, credentials, mappings or target definitions.

Only these fields are allowed. Do not add tools, arbitrary argv, schedules,
follow-ups, captured configuration or executable Lisp. Use an explicit named
preset (not `default`) and `provider/model` (no thinking suffix). Names/model
choices are resolved at explicit import, not discovery. Tools and prompts come
from that preset; execution settings/environment are not a sandbox.

- Integer version `1`; unique keys, no nulls or NUL text; at most 256 KiB.
- ID: lowercase kebab-case, at most 64 characters. Keep it stable when editing.
- Nonblank title <=200, instructions <=131072, directory <=4096 characters.
- Model <=1024; preset/target names <=200, without whitespace.
- No recursion, dotfiles or symlink source files/resource directories.
- Identity is scope kind + canonical scope root + ID, NOT the filename.
  Same-scope duplicate IDs are errors; project/global and separate projects do
  not shadow one another. Rename within a scope keeps identity; moving scopes
  creates a distinct job. Missing sources do not delete saved jobs or history.

## Validate and hand off

Check JSON syntax/types/keys, stable ID, source location, cwd, model, preset and
explicit target before reporting the file path. Explain any unverified names.
Then ask the user to:

1. Run `M-x pichat-job-definitions` in the intended Emacs project (prefix argument
   selects another project root). **D** (Evil **g D**) opens file diagnostics.
2. Select a file row and press **RET** for the read-only import menu. Opening it
   does not resolve settings, initialize an executor, write metadata or start Pi.
   **d Inspect** shows full instructions and file path; **q** returns to the menu.
3. Choose **i Review** to resolve settings in the same menu, then
   **RET Save**; **q Cancel** discards staging. In **Inspect**, expand **Details**
   for settings, **Changes** for differences, and **Technical details** for raw
   captures. TAB/RET toggles disclosures; **q** returns without recapturing. Import
   saves only; Run and timing require separate authorization. Project files are
   untrusted data, not a Pi trust gate.
4. Edit the JSON (initial menu **o Open file**), save it, then rediscover
   and review explicitly. **Already up to date** means unchanged semantic data
   is a true no-op, including captured settings and timestamps. In the reviewed
   menu, the secondary Settings action **r Use current settings** explicitly
   prepares current named preset/target settings even if unchanged; **Save** is
   still required. It does not refresh the file listing or run the job.
   An unchanged rename keeps the last modifying import path until an update or
   refresh. Saved native edits never write back into authored files; replacement
   on reimport requires explicit confirmation. Timing/follow-ups and queued or
   historical attempts/evidence remain preserved.

If a source/store changed during review, a name is unavailable, a file is
unreadable/unsupported, or duplicate IDs appear, fix the reported source/config
and discover/review again. Do not repair the live database or bypass confirmation.
This bundled skill is exposed only on PiChat structured launches; explicit
`--no-skills`/`-ns` suppresses it. User skill arguments/settings stay unchanged.
`enableSkillCommands` controls command discovery, not skill resource loading.
No installation or settings changes are needed.

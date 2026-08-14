# Elpaca source-cache workflow

This configuration requires Emacs 30 or later. It can package its Elpaca Git
source trees as a portable cache, allowing a new machine to skip most package
clones while still rebuilding bytecode, autoloads, documentation, native
modules, and absolute build links locally.

The tracked `elpaca-lock.eld` and a source-cache archive form one reproducible
snapshot. Do not mix a lock file with an archive from another snapshot.

## Requirements

Both cache creation and restoration require:

- Emacs 30 or later
- Git
- GNU tar
- zstd
- `sha256sum`
- Bash 4 or later

The cache contains package source code only. Destination machines still need
system dependencies required to build packages such as PDF Tools or vterm.

## Updating and publishing a snapshot

1. Fetch, review, and merge package updates with Elpaca.
2. Restart Emacs and test the configuration.
3. Ensure package source repositories contain no intentional tracked changes.
4. Regenerate the lock file:

   ```sh
   scripts/elpaca-lock-write
   ```

   The interactive equivalent is `M-x my/elpaca-write-lock-file` after Elpaca
   has finished processing its queues.

5. Review the `elpaca-lock.eld` diff.
6. Create the matching source archive:

   ```sh
   scripts/elpaca-cache-create --output /path/to/elpaca-sources-default.tar.zst
   ```

   Alternatively, configure a default artifact directory:

   ```sh
   export ELPACA_CACHE_DIR=/path/to/cache
   scripts/elpaca-cache-create
   ```

The create script writes three files:

- `elpaca-sources-default.tar.zst`
- `elpaca-sources-default.tar.zst.sha256`
- `elpaca-sources-default.tar.zst.manifest`

Publish or copy all three together. The archive also contains the matching lock
file and an internal manifest. Creation fails for Git lock files, dirty tracked
source files, missing source repositories, or missing locked commits.
`--allow-dirty` exists for deliberate source modifications, but such snapshots
should be exceptional and reviewed carefully.

The manifest records the configuration and Elpaca commits, installer and Emacs
versions, profile, lock checksum, archive checksum, and every source remote and
HEAD. The configuration worktree may be recorded as dirty while developing;
release snapshots should normally be generated from a committed configuration.

## Installing on a new machine

1. Install Emacs 30+, Git, GNU tar, zstd, and package-specific native build
   dependencies.
2. Clone this configuration at the configuration commit named in the cache
   manifest.
3. Put the archive and both sidecars together.
4. Before starting Emacs, restore the cache:

   ```sh
   scripts/elpaca-cache-restore \
     --profile default \
     /path/to/elpaca-sources-default.tar.zst
   ```

5. Start Emacs normally. Elpaca sees the restored source directories, skips
   cloning them, checks out locked revisions, and creates `.local/elpaca/builds`
   locally.
6. Restart Emacs after the first build completes.

Restoration verifies the archive checksum, internal and external manifests,
profile, lock checksum, allowed archive paths, source Git repositories, remotes,
HEADs, and locked revisions. It refuses to overwrite an existing Elpaca source
or build tree. Use `--force` only when intentionally replacing that state; it
removes existing source and build directories before extraction.

If restoration reports a lock/archive mismatch, obtain the matching pair. Do
not bypass the check by copying a different lock file. To intentionally update
the snapshot, regenerate the lock and archive together using the publishing
workflow above.

## Conditional machine profiles

The tracked `elpaca-lock.eld` and the `default` archive represent the normal
Linux profile active when the lock was generated. Conditional declarations that
are inactive on that machine are not guaranteed to be present in its lock.

For a work, Android, or OS-specific profile:

1. Run Emacs in an environment where that profile's conditions have their
   intended values.
2. Write a distinct lock file:

   ```sh
   scripts/elpaca-lock-write \
     --profile work \
     --lock-file /path/to/elpaca-lock-work.eld
   ```

3. Create a matching archive:

   ```sh
   scripts/elpaca-cache-create \
     --profile work \
     --lock-file /path/to/elpaca-lock-work.eld \
     --output /path/to/elpaca-sources-work.tar.zst
   ```

The profile option labels and validates artifacts; it does not itself enable
work or Android configuration. Profile conditions must already be active while
the lock is generated. Set `EMACS_ELPACA_LOCK_FILE` to select a non-default
lock during normal Emacs startup.

## Rollback

Keep each archive, checksum, manifest, lock file, and configuration commit
associated as one release. To roll back:

1. Check out the recorded configuration commit.
2. Restore the matching archive with `--force` if replacing existing Elpaca
   state.
3. Start Emacs and let Elpaca rebuild locally.

## Deliberate omissions and limitations

- `.local/elpaca/builds` is excluded because it contains machine-specific
  bytecode and absolute symlinks.
- `*.elc`, `*.eln`, object files, libraries, and VCS-ignored build products are
  excluded.
- Elpaca menu caches are excluded; the lock file supplies the reproducible
  recipes and refs.
- Source caching avoids downloads but does not eliminate local compilation.
- Native package dependencies must be installed separately.
- Separate conditional profiles may need separate lock/archive pairs.
- The checksum detects corruption and accidental mismatch but is not a digital
  signature. Sign artifacts separately when authenticity across an untrusted
  transport matters.

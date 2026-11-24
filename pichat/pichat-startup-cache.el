;;; pichat-startup-cache.el --- Verified SSH startup assets -*- lexical-binding: t; -*-

;;; Commentary:
;; The target must provide a POSIX shell and GNU coreutils.  Reject symlinks
;; and untrusted writable ancestors, not just unsafe files inside the cache.
;; This trusts root and the target account, including its mounts and ACL
;; enforcement.  It is not a sandbox against that account changing files.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-transport)

(defconst pichat-startup-cache--script
  "set -f
export LC_ALL=C
umask 077
op=$1 root=$2 kind=$3 digest=$4 stage=$5
fail() { printf '%s\\n' \"$*\" >&2; exit 1; }
uid=$(id -u) || fail 'cannot determine target uid'
metadata() {
  [ ! -L \"$1\" ] || fail \"symlink is not allowed: $1\"
  info=$(stat -c '%u %a' -- \"$1\") || fail \"cannot stat: $1\"
  owner=${info% *} mode=${info#* }
  case $owner in ''|*[!0-9]*) fail \"invalid owner: $1\";; esac
  case $mode in ''|*[!0-7]*) fail \"invalid mode: $1\";; esac
}
ancestor() {
  metadata \"$1\"
  [ -d \"$1\" ] && { [ \"$owner\" = 0 ] || [ \"$owner\" = \"$uid\" ]; } ||
    fail \"untrusted ancestor: $1\"
  # Root-owned sticky directories (e.g. /tmp) protect root- and uid-owned
  # children from other users.  Each child is itself checked before descent.
  [ $((0$mode & 022)) -eq 0 ] ||
    { [ \"$owner\" = 0 ] && [ $((0$mode & 01000)) -ne 0 ]; } ||
    fail \"writable ancestor: $1\"
}
private_dir() {
  metadata \"$1\"
  [ -d \"$1\" ] && [ \"$owner\" = \"$uid\" ] && [ \"$mode\" = 700 ] ||
    fail \"expected an owned mode-0700 directory: $1\"
}
missing() { [ ! -e \"$1\" ] && [ ! -L \"$1\" ]; }
ensure_dir() {
  if missing \"$1\"; then
    mkdir -m 700 -- \"$1\" 2>/dev/null || : # A peer may have created it.
  fi
  private_dir \"$1\"
}
verify() {
  metadata \"$1\"
  [ -f \"$1\" ] && [ \"$owner\" = \"$uid\" ] && [ \"$mode\" = 400 ] ||
    fail \"expected an owned mode-0400 regular file: $1\"
  hash=$(sha256sum < \"$1\") || fail \"cannot hash: $1\"
  [ \"${hash%% *}\" = \"$digest\" ] || fail \"SHA-256 mismatch: $1\"
}
ancestor /
parent= rest=${root#/}
while [ \"${rest#*/}\" != \"$rest\" ]; do
  parent=$parent/${rest%%/*}
  ancestor \"$parent\"
  rest=${rest#*/}
done
namespace=$root/$kind
if [ \"$op\" = probe ]; then
  ensure_dir \"$root\"
  ensure_dir \"$namespace\"
else
  # An interrupted probe might not have reached mkdir (or even ensure_dir).
  if [ \"$op\" = clean ] && missing \"$root\"; then exit 0; fi
  private_dir \"$root\"
  if [ \"$op\" = clean ] && missing \"$namespace\"; then exit 0; fi
  private_dir \"$namespace\"
fi
if [ \"$op\" = clean ]; then
  if missing \"$namespace/$stage\"; then exit 0; fi
  private_dir \"$namespace/$stage\"
  rm -f -- \"$namespace/$stage/asset\" && rmdir -- \"$namespace/$stage\" ||
    fail \"could not remove owned staging directory: $namespace/$stage\"
  exit 0
fi
version=$namespace/$digest
ensure_dir \"$version\"
case $kind in
  v1-helper) file=$version/pichat-tool-control.ts;;
  v1-skill)
    ensure_dir \"$version/pichat-jobs\"
    file=$version/pichat-jobs/SKILL.md;;
  *) fail 'unknown asset kind';;
esac
case $op in
  probe)
    if [ -e \"$file\" ] || [ -L \"$file\" ]; then
      verify \"$file\"
      printf 'hit\\n'
    else
      if mkdir -m 700 -- \"$namespace/$stage\" 2>/dev/null; then
        printf 'staged\\n'
      elif missing \"$namespace/$stage\"; then
        fail \"cannot create staging directory: $namespace/$stage\"
      else
        printf 'collision\\n'
      fi
    fi;;
  publish)
    private_dir \"$namespace/$stage\"
    staged=$namespace/$stage/asset
    metadata \"$staged\"
    [ -f \"$staged\" ] && [ \"$owner\" = \"$uid\" ] &&
      [ \"$(stat -c '%h' -- \"$staged\")\" = 1 ] || fail \"unsafe staged file: $staged\"
    chmod 400 -- \"$staged\" || fail \"cannot seal: $staged\"
    verify \"$staged\"
    # Hard links publish complete bytes atomically and never replace a peer.
    if ! ln -T -- \"$staged\" \"$file\"; then
      [ -e \"$file\" ] || [ -L \"$file\" ] || fail \"cannot publish: $file\"
    fi
    verify \"$file\";;
  *) fail 'unknown cache operation';;
esac")

(defun pichat-startup-cache--root (transport)
  "Return a literal, absolute cache root for captured TRANSPORT."
  (let ((root (directory-file-name
               (or (pichat-transport-startup-cache-root transport)
                   (concat (file-name-as-directory
                            (pichat-transport-runtime-home transport))
                           ".pichat-assets")))))
    (unless (and (string-prefix-p "/" root)
                 (not (string-match-p "[[:cntrl:]]" root))
                 (not (cl-intersection '("" "." "..")
                                       (split-string (substring root 1) "/")
                                       :test #'equal)))
      (error "Expected an absolute remote-native startup cache root, got %S" root))
    root))

(defun pichat-startup-cache--command (transport op root kind digest &optional stage)
  "Run cache OP at ROOT for KIND and DIGEST, optionally using STAGE."
  (let ((default-directory (pichat-transport-runtime-file-name transport "/")))
    (with-temp-buffer
      (let* ((status (process-file "sh" nil '(t t) nil "-c"
                                   pichat-startup-cache--script "pichat-startup-cache"
                                   op root kind digest (or stage "")))
             (output (string-trim (buffer-string))))
        (unless (eql status 0)
          (error "Cache %s failed at %S (status %s): %s" op root status output))
        output))))

(defun pichat-startup-cache--stage-name ()
  "Choose a staging basename locally, independent of other acquisitions."
  (format ".stage.%06x%06x%06x%06x%06x"
          (random #x1000000) (random #x1000000) (random #x1000000)
          (random #x1000000) (random #x1000000)))

(defun pichat-startup-cache--asset (transport root kind source name)
  "Acquire SOURCE under ROOT/KIND/SHA-256/NAME on TRANSPORT."
  (unless (and (string-prefix-p "/" source) (not (file-remote-p source)))
    (error "Startup asset is not an absolute local path: %S" source))
  (let* ((source (file-truename source)) ; Elpaca builds can be symlinks.
         (digest (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally source)
                   (secure-hash 'sha256 (current-buffer))))
         ;; Know the private name before starting interruptible remote I/O.
         (stage (pichat-startup-cache--stage-name))
         complete)
    (unwind-protect
        (progn
          (pcase (pichat-startup-cache--command transport "probe" root kind digest stage)
            ("hit" (setq stage nil))
            ("staged"
             (copy-file source (pichat-transport-runtime-file-name
                                transport (concat root "/" kind "/" stage "/asset")))
             (pichat-startup-cache--command transport "publish" root kind digest stage))
            ("collision"
             (let ((occupied stage))
               (setq stage nil) ; Never clean a stage known to belong to a peer.
               (error "Startup cache staging name already exists at %S: %s" root occupied)))
            (answer (error "Unexpected startup cache response at %S: %S" root answer)))
          (setq complete t)
          (concat root "/" kind "/" digest "/" name))
      (when stage
        (condition-case err
            (pichat-startup-cache--command transport "clean" root kind digest stage)
          (error (if complete (signal (car err) (cdr err))
                   (message "Startup cache staging %s: %s" stage
                            (error-message-string err)))))))))

(defun pichat-startup-cache-acquire (transport helper &optional skill)
  "Return verified native :path and optional :skill for SSH TRANSPORT.
HELPER and SKILL are local asset files.  The returned :cleanup is a no-op:
only this acquisition's private staging gets removed, before returning.
TRANSPORT must be idle.  Fail closed on unsupported or unsafe storage."
  (let ((connection (pichat-transport--connection transport)))
    (unless connection (error "Startup cache requires a captured SSH transport"))
    (when (pichat-transport-busy-p transport)
      (error "SSH connection is busy; defer startup cache acquisition"))
    (let ((pichat-transport--active-connections
           (cons connection pichat-transport--active-connections))
          (tramp-remote-path (or (pichat-transport-remote-path transport)
                                 tramp-remote-path))
          ;; An absolute asset source must stay local even in a TRAMP buffer.
          (default-directory "/"))
      (condition-case err
          (let ((root (pichat-startup-cache--root transport)))
            (list :path (pichat-startup-cache--asset
                         transport root "v1-helper" helper "pichat-tool-control.ts")
                  :skill (when skill
                           (pichat-startup-cache--asset
                            transport root "v1-skill" skill "pichat-jobs/SKILL.md"))
                  :cleanup #'ignore))
        (error (error "Startup assets for %s: %s"
                      (pichat-transport-description transport)
                      (error-message-string err)))))))

(defun pichat-startup-cache-acquire-when-idle (transport helper skill owned-p callback)
  "Defer acquisition on TRANSPORT; return a canceller.
HELPER and SKILL are as in `pichat-startup-cache-acquire'.  Call CALLBACK with
(ASSETS ERROR) only if OWNED-P still holds, including after reentrant I/O.
This callback must not be awaited by synchronous work on the same connection."
  (let (cancelled)
    (let ((cancel-timer
           (pichat-transport-defer
            transport
            (lambda ()
              (when (and (not cancelled) (funcall owned-p))
                (let (assets failure)
                  (condition-case err
                      (setq assets (pichat-startup-cache-acquire transport helper skill))
                    ((error quit) (setq failure err)))
                  (when (and (not cancelled) (funcall owned-p))
                    (funcall callback assets failure))))))))
      (lambda () (setq cancelled t) (funcall cancel-timer)))))

(provide 'pichat-startup-cache)
;;; pichat-startup-cache.el ends here

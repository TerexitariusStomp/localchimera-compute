;;; module/playnet/utils/paths.scm — where a deployment keeps its state.
;;;
;;; One answer to "where does this file live", because the question was
;;; being answered independently in a dozen places. The expression
;;;
;;;     (or (getenv "PLAYNET_DATA_DIR") "/var/lib/playnet")
;;;
;;; was written out in the lobby, both chat bridges, the static server
;;; twice, and the gateway's boot path — and in the planner service it was
;;; written with a DIFFERENT default ("data"), which nobody chose and
;;; nothing documents. Restating a convention is how it stops being one.
;;;
;;; This module knows about deployment layout and nothing else. It has no
;;; idea what a provider, a credential or a token is; callers name their
;;; own files. Anything that needs to know which file belongs to which
;;; subsystem belongs a layer up — see (playnet fleet paths) for the
;;; provider credentials, which is the shape to copy.
;;;
;;; Resolution, most specific first:
;;;
;;;   an explicit override passed by the caller  — a --data-dir flag, a
;;;                                                boot parameter, a test
;;;   PLAYNET_DATA_DIR                           — the deployment says
;;;   /var/lib/playnet                           — the packaged default
;;;
;;; PROCEDURES, NOT CONSTANTS, and this is load-bearing. A constant is
;;; captured when its module initialises, so whether an override takes
;;; effect depends on setenv running before the module loads — a rule that
;;; can be written in a comment and enforced nowhere. Reading the
;;; environment at call time makes load order stop mattering. That
;;; distinction cost a test-suite failure that read as a race.

;;;
;;; The STATE root, beside the data root: the XDG-aware directory where scopes keep
;;; their key logs, credential stores and vaults. Resolved in priority order:
;;;
;;;   1. $PLAYNET_STATE_DIR  — explicit override (test harness, deploys)
;;;   2. $XDG_STATE_HOME/playnet  — XDG Base Directory spec
;;;   3. ~/.local/state/playnet   — XDG default
;;;
;;; Each scope owns a sub-directory `<state>/scopes/<aid>/` with:
;;;
;;;   acdc/   — content-addressed credential store (one S-expr per SAID)
;;;   kel/    — content-addressed KEL event store (one S-expr per event SAID)
;;;   vault   — optional XSalsa20-Poly1305-encrypted bran (only when no
;;;             Shamir share-holders are configured; see keys/bran-custody.scm)
;;;
;;; Test code can override the resolved root via the parameter
;;; `current-playnet-state-dir-override` rather than mutating env vars.

(define-module (playnet utils paths)
  #:use-module (ice-9 ftw)
  #:use-module ((playnet utils common) #:select (string-or-false env-flag?))
  #:use-module ((ice-9 rdelim) #:select (read-line))
  #:use-module ((srfi srfi-13) #:select (string-trim-both string-null?))
  #:export (playnet-data-dir
            state-file
            current-playnet-state-dir-override
            playnet-state-dir
            scope-state-dir
            scope-acdc-dir
            scope-kel-dir
            witness-mirror-kel-dir
            scope-events-dir
            custodian-share-path
            scope-vault-path
            scope-kind-file
            read-scope-kind
            write-scope-kind!
            scope-aid-name-file
            read-scope-aid-name
            write-scope-aid-name!
            default-scope-aid-name
            durable-default?
            default-scope-witnesses
            ensure-directory!
            remove-tree!))

(define %default-data-dir "/var/lib/playnet")

(define* (playnet-data-dir #:optional override #:key default)
  "The deployment's persistent state directory. OVERRIDE wins when given,
then PLAYNET_DATA_DIR, then DEFAULT, then the packaged default.

DEFAULT is for a component that must stay runnable with nothing
configured — a relative directory a developer can write to without root.
It applies ONLY when nothing else is set, so a deployment that exports
PLAYNET_DATA_DIR still gets one answer everywhere. Pass it deliberately:
an unexplained per-caller default is how three of them appeared."
  (or override
      (getenv "PLAYNET_DATA_DIR")
      default
      %default-data-dir))

(define* (state-file name #:key data-dir env default)
  "Absolute path to NAME inside the deployment's state directory.

ENV, when given, names an environment variable holding the exact path to
this one file; it outranks every directory-level setting, which is what
lets a single file be redirected without moving the whole deployment.
DATA-DIR is the caller's own directory, for a component that was handed
one rather than reading the environment. DEFAULT is passed through to
`playnet-data-dir'."
  (or (and env (getenv env))
      (string-append (playnet-data-dir data-dir #:default default)
                     "/" name)))


;;; ── the state root ──────────────────────────────────────────────────────────

(define current-playnet-state-dir-override
  (make-parameter #f))

(define (env-or-empty name)
  (or (getenv name) ""))

(define (home-dir)
  (or (string-or-false (env-or-empty "HOME"))
      (error "no HOME in environment")))

(define (playnet-state-dir)
  "Resolve the playnet state root.  See module preamble for precedence."
  (or (current-playnet-state-dir-override)
      (string-or-false (env-or-empty "PLAYNET_STATE_DIR"))
      (let ((xdg (string-or-false (env-or-empty "XDG_STATE_HOME"))))
        (if xdg
            (string-append xdg "/playnet")
            (string-append (home-dir) "/.local/state/playnet")))))

(define (scope-state-dir aid)
  "Per-scope state directory: <state>/scopes/<aid>/"
  (string-append (playnet-state-dir) "/scopes/" aid))

(define (scope-acdc-dir aid)
  (string-append (scope-state-dir aid) "/acdc"))

(define (scope-kel-dir aid)
  (string-append (scope-state-dir aid) "/kel"))

(define (witness-mirror-kel-dir aid)
  "Per-mirrored-AID directory for a `^scope-witness`'s copy of a peer
   scope's KEL — distinct from scope-kel-dir so a witness mirroring an
   AID it doesn't itself own never collides with that AID's own home
   directory (e.g. both running against the same PLAYNET_STATE_DIR)."
  (string-append (playnet-state-dir) "/witness-mirrors/" aid "/kel"))

(define (scope-events-dir aid)
  "Per-scope portable event log: <state>/scopes/<aid>/events/ — the
   self-certifying, SAID-chained economic event stream (gap #18)."
  (string-append (scope-state-dir aid) "/events"))

(define (scope-vault-path aid)
  "Path to the encrypted-on-disk bran for AID. Used in vault-mode
   custody (no Shamir share-holders). Filename is `bran.vault` for
   visual clarity that this is an encrypted secret, not a JSON config."
  (string-append (scope-state-dir aid) "/bran.vault"))

(define (custodian-share-path subject-aid holder-aid)
  "Path to a ^bran-custodian's own encrypted Shamir share of SUBJECT-AID's
   bran, as held by HOLDER-AID. Deliberately NOT under scope-state-dir:
   in production a custodian runs on its own host/process (a federation
   peer, a trusted member, a backup service) — this is the custodian's
   own local record of the one share it holds, encrypted under that
   process's own PLAYNET_VAULT_KEY, not something the subject scope's
   directory tree should contain."
  (string-append (playnet-state-dir) "/custodian-shares/"
                 subject-aid "/" holder-aid "/share.vault"))

(define (scope-kind-file aid)
  "Path to the on-disk kind tag for AID. Single line containing the
   symbol's name ('commune', 'federation', 'universal-commune'). Read
   at boot to recover each scope with its correct kind."
  (string-append (scope-state-dir aid) "/kind"))

(define (read-scope-kind aid)
  "Return the on-disk kind for AID as a symbol, or #f if absent.
   #f distinguishes 'never written' (pre-promotion scope) from any
   recorded kind."
  (let ((path (scope-kind-file aid)))
    (and (file-exists? path)
         (call-with-input-file path
           (lambda (port)
             (let ((s (read-line port)))
               (and (string? s)
                    (let ((trimmed (string-trim-both s)))
                      (and (not (string-null? trimmed))
                           (string->symbol trimmed))))))))))

(define (write-scope-kind! aid kind)
  "Persist KIND (symbol) for AID. Idempotent — overwrites any prior
   value. Caller ensures the scope-state-dir exists; we mkdir it here
   too for robustness on first-spawn paths that haven't yet created
   the acdc/kel subdirs."
  (let ((dir  (scope-state-dir aid))
        (path (scope-kind-file aid)))
    (unless (file-exists? dir)
      (ensure-directory! dir))
    (call-with-output-file path
      (lambda (port)
        (display (symbol->string kind) port)
        (newline port)))))

;;; ── aid-name ──────────────────────────────────────────────────────────
;;;
;;; The KERIA-local string alias under which signify references this
;;; scope's AID. Convention is "scope-<aid>" so a scope's identity file
;;; is fully reconstructable from its directory name — important for
;;; cross-gateway portability: tar up <state>/scopes/<aid>/, drop it on
;;; another gateway, and `restore-all-scopes!` rebuilds everything
;;; including the local-alias mapping signify needs to sign on the
;;; scope's behalf.
;;;
;;; The file is one line of plain text (same shape as `kind`). Stored
;;; explicitly (not just derived) so future divergence — e.g. a scope
;;; imported under a non-conventional alias by an operator — round-trips
;;; correctly through restore.

(define (default-scope-aid-name aid)
  "Conventional KERIA alias for a scope's AID. Used at spawn time when
   no explicit aid-name is supplied; matches the `name` field that
   `governance-create-scope-aid!` already bakes into the inception."
  (string-append "scope-" aid))

(define (scope-aid-name-file aid)
  (string-append (scope-state-dir aid) "/aid-name"))

(define (read-scope-aid-name aid)
  "Return the persisted aid-name for AID, or #f if absent. #f means
   either the scope predates the aid-name file or it was spawned
   non-durably — callers should fall back to `default-scope-aid-name`."
  (let ((path (scope-aid-name-file aid)))
    (and (file-exists? path)
         (call-with-input-file path
           (lambda (port)
             (let ((s (read-line port)))
               (and (string? s)
                    (let ((trimmed (string-trim-both s)))
                      (and (not (string-null? trimmed)) trimmed)))))))))

(define (write-scope-aid-name! aid name)
  "Persist NAME (string) as the KERIA alias for AID. Idempotent."
  (let ((dir  (scope-state-dir aid))
        (path (scope-aid-name-file aid)))
    (unless (file-exists? dir)
      (ensure-directory! dir))
    (call-with-output-file path
      (lambda (port)
        (display name port)
        (newline port)))))

(define default-scope-witnesses
  ;; A parameter holding a list of refs to use as default `#:witnesses`
  ;; for spawn-scope when the caller doesn't pass any. Gateway boot
  ;; sets this once to `(list (spawn-oobi-host-mirror …)
  ;; (spawn-http-witness-publisher))` so every durable scope
  ;; auto-publishes its KEL to /oobi/{aid} and to remote witness URLs.
  (make-parameter '()))

(define (durable-default?)
  "Returns #t when scopes should default to durable mode in this
   process: PLAYNET_SCOPES_DURABLE is set to anything other than \"0\"
   or empty.  Used as the default for `#:durable?` on spawn-scope and
   spawn-universal-commune."
  (env-flag? "PLAYNET_SCOPES_DURABLE"))

(define (remove-tree! path)
  "Delete PATH and everything under it. Tolerates an absent PATH and
   swallows per-entry errors (a half-removed tree is still gone enough
   for its one caller: sweeping a failed mint's scope-state dir)."
  (when (file-exists? path)
    (file-system-fold
     (lambda (p s r) #t)                                        ; enter every dir
     (lambda (p s r) (catch #t (lambda () (delete-file p)) (lambda _ #f)) r)
     (lambda (p s r) r)                                         ; down
     (lambda (p s r) (catch #t (lambda () (rmdir p)) (lambda _ #f)) r)
     (lambda (p s r) r)                                         ; skip
     (lambda (p s errno r) r)                                   ; error
     #t path)))

(define (ensure-directory! path)
  "Create PATH and any missing parents.  Idempotent."
  (let loop ((parts (filter (lambda (s) (not (string=? s "")))
                            (string-split path #\/)))
             (acc (if (and (> (string-length path) 0)
                           (eq? (string-ref path 0) #\/))
                      "" ".")))
    (cond
     ((null? parts) #t)
     (else
      (let ((next (if (string=? acc "")
                      (string-append "/" (car parts))
                      (string-append acc "/" (car parts)))))
        (unless (file-exists? next) (mkdir next))
        (loop (cdr parts) next))))))

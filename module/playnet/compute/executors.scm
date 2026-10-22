;;; module/playnet/compute/executors.scm — the executor registry: how a
;;; replay finds something that can actually run the job.
;;;
;;; replay-job's seam is a procedure (executor envelope repro-spec) →
;;; output-hash. Who supplies it is a deployment question: a Wasimoff
;;; broker on this commune's edge, a wasmCloud host running the component,
;;; a local wasmtime for a node that IS the machine. The registry is the
;;; indirection — boot code or a service-facing door registers an executor
;;; under a commune (or the wildcard 'any), compute-replay consults it,
;;; and absent every entry the door still answers 'no-executor. Nothing
;;; here pretends an executor exists; the table is empty until one lands.
;;;
;;; WHAT IS HERE:
;;;   • register-executor! / unregister-executor! — the table.
;;;   • executor-for — commune → the executor fn | #f, exact key first,
;;;     'any wildcard second.
;;;   • executor kinds — 'wasimoff | 'wasmcloud | 'local — a label the row
;;;     carries so an operator sees WHAT would run a job, not just that
;;;     something could.
;;;   • make-replay-executor — adapt a shaped procedure into replay-job's
;;;     calling convention; the shape contract stays thin so each service's
;;;     adapter lives beside its own transport.

(define-module (playnet compute executors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:export (register-executor! unregister-executor! executor-for
            executor-kind executor-name executor-kinds make-replay-executor
            %executor-run
            <executor> executor? executors-list))


;;; ── the record ──────────────────────────────────────────────────────────
;;; kind is a deployment label: 'wasimoff (browser/edge broker), 'wasmcloud
;;; (capability-linked component host), 'local (this process's runtime).
;;; name is human: the broker URL, the host id, "wasmtime-26".

(define-record-type <executor>
  (%make-executor kind name run)
  executor?
  (kind executor-kind)   ; 'wasimoff | 'wasmcloud | 'local
  (name executor-name)   ; string
  (run  %executor-run))  ; (envelope repro-spec) → output-hash

(define executor-kinds '(wasimoff wasmcloud local))

(define* (make-replay-executor #:key kind name run)
  (unless (memq kind '(wasimoff wasmcloud local))
    (error "executor: kind must be wasimoff, wasmcloud or local" kind))
  (unless (procedure? run)
    (error "executor: run must be a procedure (envelope repro) → hash"))
  (%make-executor kind name run))


;;; ── the table ───────────────────────────────────────────────────────────
;;; commune-aid → <executor>; 'any is the wildcard. One executor per
;;; commune keeps the answer unambiguous — a second register replaces, and
;;; the row an operator lists is the one that would run.

(define *executors* (make-hash-table))

(define (register-executor! commune-aid executor)
  (hash-set! *executors* commune-aid executor)
  (executor-name executor))

(define (unregister-executor! commune-aid)
  (hash-remove! *executors* commune-aid))

(define (executor-for commune-aid)
  "The <executor> registered for this commune, else the 'any wildcard,
   else #f — the door composes this with %replay-unavailable."
  (or (hash-ref *executors* commune-aid)
      (hash-ref *executors* 'any)))

(define (executors-list)
  "What an operator asks: (commune kind name) rows, wildcard included."
  (hash-fold (lambda (k v acc) (cons (list k (executor-kind v) (executor-name v)) acc))
             '() *executors*))

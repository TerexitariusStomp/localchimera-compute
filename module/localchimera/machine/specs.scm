;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; compute/specs.scm — compute as a resource the catalogue can name.
;;;
;;; WHAT THE FILE HOLDS. The `compute` ResourceSpecification family: the
;;; catalog type a member's machine conforms to when it offers capacity, and
;;; the two small vocabularies the rest of the port speaks — task classes
;;; (what kind of work) and replay modes (how a challenge may re-run it).
;;;
;;; A compute spec is an ordinary <resource-specification> whose
;;; `resource-classified-as` carries the compute tags, in a fixed order:
;;;
;;;   ("compute" <task-class> "lane:<lane>" "repro:<mode>")
;;;
;;; so matching sees it through the same classification channel every other
;;; spec uses, and so a spec stays a spec — no new record type, nothing the
;;; ontology did not already have a slot for. The tags are the whole of the
;;; wire: `spec->tags` and `tags->spec-facts` are the two directions.
;;;
;;; Task classes are PoI's lanes (see poi-compute's hive-bridge
;;; DEFAULT_LANE_MAP): the bridge groups raw task types into them and a
;;; lender advertises lanes, never raw types. The swarm pair stays declared
;;; but unroutable — BUILD_VERIFY waits on a real sandbox, per the NAOMS
;;; spec's own deferral.
;;;
;;; Replay modes scope what a challenge may assert (naoms-compute.md §10):
;;;   'exact         — hash equality of output: fetches, canaries, storage
;;;   'deterministic — replay under the committed seed + decoding; the
;;;                    prover's per-task-type equivalence predicate decides
;;;   'none          — structural validity only; semantic complaints go to
;;;                    member review, not the prover
;;; A lender that cannot run deterministically commits `none` and takes the
;;; weaker challenge scope — the mode is the lender's claim, not our hope.

(define-module (localchimera machine specs)
  #:use-module (localchimera vf schemas)
  #:use-module (srfi srfi-1)
  #:export (repro-mode?
            task-class?
            *machine-task-classes*
            *machine-usage-units*
            usage-unit?
            lane-tag
            repro-tag
            make-machine-spec
            machine-spec?
            spec-task-class
            spec-lane
            spec-repro-mode))


;;; ── the vocabularies ────────────────────────────────────────────────────

(define *machine-task-classes*
  '(inference storage bandwidth compute research fetch jury canary
    swarm-infer build-verify))

(define (task-class? x)
  (and (memq x *machine-task-classes*) #t))

(define (repro-mode? x)
  (and (memq x '(exact deterministic none)) #t))

;;; the units a machine resource meters in — one vocabulary for offers,
;;; specs and usage meters. "seconds"/"tokens" are the original compute
;;; pair; the rest are the per-kind meters: byte-seconds for storage,
;;; bytes for relay, readings for sense, node-hours for presence.
(define *machine-usage-units*
  '("seconds" "tokens" "bytes" "byte-seconds" "readings" "node-hours"))

(define (usage-unit? x)
  (and (member x *machine-usage-units*) #t))

(define (lane-tag lane)     (string-append "lane:" lane))
(define (repro-tag mode)    (string-append "repro:" (symbol->string mode)))


;;; ── the spec ────────────────────────────────────────────────────────────

;;; (make-machine-spec id name #:task-class #:lane #:repro-mode
;;;                    #:usage-unit ["seconds"] #:substitutable [#t])
;;;
;;; usage-unit is the unit a `use` event meters in — "tokens" or "seconds"
;;; (the UsageMeter of the receipt spec). Effort is always "seconds"; the
;;; two units stay distinct because a token-metered job still took time.
(define* (make-machine-spec id name #:key task-class lane repro-mode
                            (usage-unit "seconds")
                            (substitutable #t))
  (unless (task-class? task-class)
    (error "machine-spec: not a task class" task-class))
  (unless (repro-mode? repro-mode)
    (error "machine-spec: not a repro mode" repro-mode))
  (unless (usage-unit? usage-unit)
    (error "machine-spec: not a usage unit" usage-unit))
  (make-resource-specification
    #:id id
    #:name name
    #:resource-classified-as
      (list "compute" (symbol->string task-class)
            (lane-tag lane) (repro-tag repro-mode))
    #:default-unit-of-resource usage-unit
    #:default-unit-of-effort "seconds"
    #:substitutable substitutable
    #:medium-of-exchange #f))


;;; ── reading the tags back ───────────────────────────────────────────────

(define (machine-spec? spec)
  (let ((cls (resource-specification-resource-classified-as spec)))
    (and (pair? cls) (equal? "compute" (car cls)))))

(define (spec-task-class spec)
  (let ((cls (resource-specification-resource-classified-as spec)))
    (and (machine-spec? spec) (pair? (cdr cls))
         (string->symbol (cadr cls)))))

(define (spec-lane spec)
  (let ((tag (find (lambda (t) (string-prefix? "lane:" t))
                   (or (resource-specification-resource-classified-as spec) '()))))
    (and tag (substring tag 5))))

(define (spec-repro-mode spec)
  (let ((tag (find (lambda (t) (string-prefix? "repro:" t))
                   (or (resource-specification-resource-classified-as spec) '()))))
    (and tag (string->symbol (substring tag 6)))))

;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; infrastructure.scm — Compute infrastructure recipes
;;;
;;; Two recipes that turn shared infrastructure resources (compute,
;;; memory, storage, bandwidth) into digital deliverables (transcripts,
;;; replicated datasets). Infrastructure is `'use`-d not consumed —
;;; it's occupied for the duration of the process and released
;;; afterward, exactly like the cold-chain reefer-van pattern but in
;;; the digital domain.
;;;
;;; Originally inlined in tests/deprecated/test-infrastructure-planning.scm.

;; ─── Resource specifications ────────────────────────────────────────────────

;; Infrastructure (occupied during use, released after).
(define-module (localchimera knowledge recipes infrastructure)
  #:use-module ((localchimera utils units) #:select (%count-unit %effort-unit))
  #:use-module (localchimera vf schemas)
  #:use-module (goblins)
  #:export (infra-machine-spec infra-memory-spec infra-storage-spec
            infra-bandwidth-spec infra-transcript-spec infra-dataset-spec
            infrastructure-specs seed-infrastructure-recipes))

(define infra-machine-spec
  (make-resource-specification
    #:id "spec:compute" #:name "CPU Hours"
    #:resource-classified-as '("infrastructure" "compute") #:default-unit-of-resource "cpu-hours"))

(define infra-memory-spec
  (make-resource-specification
    #:id "spec:memory" #:name "Memory"
    #:resource-classified-as '("infrastructure" "memory") #:default-unit-of-resource "GB"))

(define infra-storage-spec
  (make-resource-specification
    #:id "spec:storage" #:name "Storage"
    #:resource-classified-as '("infrastructure" "storage") #:default-unit-of-resource "GB"))

(define infra-bandwidth-spec
  (make-resource-specification
    #:id "spec:bandwidth" #:name "Network Bandwidth"
    #:resource-classified-as '("infrastructure" "network") #:default-unit-of-resource "GB"))

;; Products.
(define infra-transcript-spec
  (make-resource-specification
    #:id "spec:transcript" #:name "Transcript"
    #:resource-classified-as '("digital" "text") #:default-unit-of-resource %count-unit))

(define infra-dataset-spec
  (make-resource-specification
    #:id "spec:dataset" #:name "Dataset"
    #:resource-classified-as '("digital" "data") #:default-unit-of-resource %count-unit))

(define infrastructure-specs
  (list infra-machine-spec infra-memory-spec infra-storage-spec
        infra-bandwidth-spec infra-transcript-spec infra-dataset-spec))

;; ─── Seed function ──────────────────────────────────────────────────────────

(define (seed-infrastructure-recipes recipe-store)
  "Seed infrastructure specs + the two recipes (transcribe, replicate)
   onto RECIPE-STORE."
  (for-each (lambda (s) ($ recipe-store 'add-resource-spec s))
            infrastructure-specs)

  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec:transcribe" #:name "Audio Transcription"))
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec:replicate" #:name "Data Replication"))

  ;; ── Recipe: Transcribe Audio ────────────────────────────────────────
  ;; 4 cpu-hours + 8 GB memory → 1 transcript (1h)
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp:transcribe" #:name "Transcribe audio"
                          #:process-conforms-to "pspec:transcribe"
                          #:has-duration (make-duration 1 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf:compute-in" #:action 'use #:resource-conforms-to "spec:compute"
                       #:resource-quantity (make-measure 4 "cpu-hours")
                       #:recipe-input-of "rp:transcribe"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf:memory-in" #:action 'use #:resource-conforms-to "spec:memory"
                       #:resource-quantity (make-measure 8 "GB")
                       #:recipe-input-of "rp:transcribe"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf:transcript-out" #:action 'produce #:resource-conforms-to "spec:transcript"
                       #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp:transcribe"))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe:transcribe" #:name "Audio Transcription"
                  #:primary-output "spec:transcript" #:recipe-processes (list "rp:transcribe")))

  ;; ── Recipe: Data Replication ────────────────────────────────────────
  ;; 10 GB bandwidth + 20 GB storage → 1 replicated dataset (2h)
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp:replicate" #:name "Replicate dataset"
                          #:process-conforms-to "pspec:replicate"
                          #:has-duration (make-duration 2 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf:bw-in" #:action 'use #:resource-conforms-to "spec:bandwidth"
                       #:resource-quantity (make-measure 10 "GB")
                       #:recipe-input-of "rp:replicate"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf:storage-in" #:action 'use #:resource-conforms-to "spec:storage"
                       #:resource-quantity (make-measure 20 "GB")
                       #:recipe-input-of "rp:replicate"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf:dataset-out" #:action 'produce #:resource-conforms-to "spec:dataset"
                       #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp:replicate"))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe:replicate" #:name "Data Replication"
                  #:primary-output "spec:dataset" #:recipe-processes (list "rp:replicate"))))

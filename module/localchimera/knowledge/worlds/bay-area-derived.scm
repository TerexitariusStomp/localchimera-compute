;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; worlds/bay-area-derived.scm — GENERATED from vendored raw by data/emit-derived.scm. DO NOT EDIT.
;;; Regenerate: cd data && guile emit-derived.scm bay-area United States tomato,potato,bean,pea > ../bay-area-derived.scm
;;; Verify (CI): make verify-derived  — re-runs the generator, diffs this file, fails on drift.
;;;
;;; The MECHANICAL layer — pure derivations from the vendored record. Human
;;; JUDGMENT (state-yield anchors, stage-physiology multiplier refinements, the
;;; Taleb tail) lives in bay-area-valley.scm / the shed, layered on top explicitly.
;;; Source raw (sha256/16):
;;;   precip.json 869cf1b566686b38
;;;   yield-bean.csv eab31135e9d58a02
;;;   yield-pea.csv 2d308a2cfb670cfb
;;;   yield-potato.csv 0bd7f1f21cb7cbda
;;;   yield-tomato.csv 0be221c7625ad3a4

;; growing season — auto-detected (calendar months above the mean month)
(define-module (localchimera knowledge worlds bay-area-derived)
  #:export (*bay-area-derived-season* *bay-area-derived-warm-quarter-degc*
            *bay-area-derived-annual-mean-degc* *bay-area-derived-scenario-probs*
            *bay-area-derived-scenario-rain* *bay-area-derived-ky-multipliers*
            *bay-area-derived-yields*))

(define *bay-area-derived-season* '(1 2 3 11 12))

;; HOW WARM IT IS WHERE THE WORK HAPPENS (°C, last decade of the record).
;; The shed already knows; anything that needs a working temperature asks here
;; rather than carrying its own table. warm-quarter is bioclim BIO10, the mean
;; of the warmest three consecutive months — NOT of *-season* above, which is
;; detected from rainfall and in a Mediterranean shed is the COLD half of the
;; year. (catalogues/subsistence.scm reads warm-quarter for the sweat curve.)
;;   temp.json d851954754d24e4f
(define *bay-area-derived-warm-quarter-degc* 16.8)
(define *bay-area-derived-annual-mean-degc* 13.8)

;; scenario probabilities — IMD ±1σ classification of 64 growing seasons
(define *bay-area-derived-scenario-probs*
  '(("normal" . 0.718750) ("drought" . 0.140625) ("flood" . 0.140625)))

;; mean growing-season rainfall within each class (mm) — the water reference
(define *bay-area-derived-scenario-rain*
  '(("drought" . 171.3) ("normal" . 383.3) ("flood" . 672.4)))

;; per-scenario yield multipliers — FAO Ky × the local rainfall (agronomy.scm)
(define *bay-area-derived-ky-multipliers*
  '(("normal" ("tomato" . 1.00) ("potato" . 1.00) ("bean" . 1.00) ("pea" . 1.00))
     ("drought" ("tomato" . 0.45) ("potato" . 0.39) ("bean" . 0.36) ("pea" . 0.36))
     ("flood" ("tomato" . 0.92) ("potato" . 0.92) ("bean" . 0.85) ("pea" . 0.85))))

;; national baseline yields (kg/ha, OWID/FAOSTAT) — a cross-check anchor
(define *bay-area-derived-yields*
  '(("bean" . 2222.7) ("pea" . 1950.3) ("potato" . 50563.2) ("tomato" . 97566.0)))


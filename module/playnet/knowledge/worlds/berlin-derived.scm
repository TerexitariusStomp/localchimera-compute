;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; worlds/berlin-derived.scm — GENERATED from vendored raw by data/emit-derived.scm. DO NOT EDIT.
;;; Regenerate: cd data && guile emit-derived.scm berlin Germany wheat,barley,potato,maize > ../berlin-derived.scm
;;; Verify (CI): make verify-derived  — re-runs the generator, diffs this file, fails on drift.
;;;
;;; The MECHANICAL layer — pure derivations from the vendored record. Human
;;; JUDGMENT (state-yield anchors, stage-physiology multiplier refinements, the
;;; Taleb tail) lives in berlin-valley.scm / the shed, layered on top explicitly.
;;; Source raw (sha256/16):
;;;   precip.json 74043d834f95346e
;;;   yield-barley.csv 33c8faaf87d213a0
;;;   yield-maize.csv b0d59dd2a824f4cc
;;;   yield-potato.csv 0bd7f1f21cb7cbda
;;;   yield-wheat.csv 511cca58ee7e657e

;; growing season — auto-detected (calendar months above the mean month)
(define-module (playnet knowledge worlds berlin-derived)
  #:export (*berlin-derived-season* *berlin-derived-warm-quarter-degc*
            *berlin-derived-annual-mean-degc* *berlin-derived-scenario-probs*
            *berlin-derived-scenario-rain* *berlin-derived-ky-multipliers*
            *berlin-derived-yields*))

(define *berlin-derived-season* '(5 6 7 8 12))

;; HOW WARM IT IS WHERE THE WORK HAPPENS (°C, last decade of the record).
;; The shed already knows; anything that needs a working temperature asks here
;; rather than carrying its own table. warm-quarter is bioclim BIO10, the mean
;; of the warmest three consecutive months — NOT of *-season* above, which is
;; detected from rainfall and in a Mediterranean shed is the COLD half of the
;; year. (catalogues/subsistence.scm reads warm-quarter for the sweat curve.)
;;   temp.json f889f5a3a3093767
(define *berlin-derived-warm-quarter-degc* 19.9)
(define *berlin-derived-annual-mean-degc* 10.8)

;; scenario probabilities — IMD ±1σ classification of 64 growing seasons
(define *berlin-derived-scenario-probs*
  '(("normal" . 0.640625) ("drought" . 0.187500) ("flood" . 0.171875)))

;; mean growing-season rainfall within each class (mm) — the water reference
(define *berlin-derived-scenario-rain*
  '(("drought" . 198.1) ("normal" . 301.6) ("flood" . 413.4)))

;; per-scenario yield multipliers — FAO Ky × the local rainfall (agronomy.scm)
(define *berlin-derived-ky-multipliers*
  '(("normal" ("wheat" . 1.00) ("barley" . 1.00) ("potato" . 1.00) ("maize" . 1.00))
     ("drought" ("wheat" . 0.64) ("barley" . 0.66) ("potato" . 0.62) ("maize" . 0.57))
     ("flood" ("wheat" . 0.96) ("barley" . 0.96) ("potato" . 0.96) ("maize" . 0.96))))

;; national baseline yields (kg/ha, OWID/FAOSTAT) — a cross-check anchor
(define *berlin-derived-yields*
  '(("barley" . 6703.5) ("maize" . 9610.0) ("potato" . 43119.5) ("wheat" . 7442.9)))


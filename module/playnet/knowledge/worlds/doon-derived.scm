;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; worlds/doon-derived.scm — GENERATED from vendored raw by data/emit-derived.scm. DO NOT EDIT.
;;; Regenerate: cd data && guile emit-derived.scm doon India rice,maize,ragi,pulses > ../doon-derived.scm
;;; Verify (CI): make verify-derived  — re-runs the generator, diffs this file, fails on drift.
;;;
;;; The MECHANICAL layer — pure derivations from the vendored record. Human
;;; JUDGMENT (state-yield anchors, stage-physiology multiplier refinements, the
;;; Taleb tail) lives in worlds/doon-valley.scm / the shed, layered on top explicitly.
;;; Source raw (sha256/16):
;;;   precip.json 8b40139a32124476
;;;   yield-bean.csv 72719c55d60add70
;;;   yield-maize.csv 1fbfb691f5bb1f6b
;;;   yield-pea.csv 4146a27d6634dcae
;;;   yield-rice.csv 3ca997cb56f115ab
;;;   yield-wheat.csv c882d518c71e75da

;; growing season — auto-detected (calendar months above the mean month)
(define-module (playnet knowledge worlds doon-derived)
  #:export (*doon-derived-season* *doon-derived-warm-quarter-degc*
            *doon-derived-annual-mean-degc* *doon-derived-scenario-probs*
            *doon-derived-scenario-rain* *doon-derived-ky-multipliers*
            *doon-derived-yields*))

(define *doon-derived-season* '(6 7 8 9))

;; HOW WARM IT IS WHERE THE WORK HAPPENS (°C, last decade of the record).
;; The shed already knows; anything that needs a working temperature asks here
;; rather than carrying its own table. warm-quarter is bioclim BIO10, the mean
;; of the warmest three consecutive months — NOT of *-season* above, which is
;; detected from rainfall and in a Mediterranean shed is the COLD half of the
;; year. (catalogues/subsistence.scm reads warm-quarter for the sweat curve.)
;;   temp.json fd494bbf390fef2f
(define *doon-derived-warm-quarter-degc* 26.8)
(define *doon-derived-annual-mean-degc* 20.7)

;; scenario probabilities — IMD ±1σ classification of 64 growing seasons
(define *doon-derived-scenario-probs*
  '(("normal" . 0.671875) ("drought" . 0.140625) ("flood" . 0.187500)))

;; mean growing-season rainfall within each class (mm) — the water reference
(define *doon-derived-scenario-rain*
  '(("drought" . 782.5) ("normal" . 1175.3) ("flood" . 1812.3)))

;; per-scenario yield multipliers — FAO Ky × the local rainfall (agronomy.scm)
(define *doon-derived-ky-multipliers*
  '(("normal" ("rice" . 1.00) ("maize" . 1.00) ("ragi" . 1.00) ("pulses" . 1.00))
     ("drought" ("rice" . 0.60) ("maize" . 0.58) ("ragi" . 0.70) ("pulses" . 0.70))
     ("flood" ("rice" . 1.00) ("maize" . 0.95) ("ragi" . 0.97) ("pulses" . 0.89))))

;; national baseline yields (kg/ha, OWID/FAOSTAT) — a cross-check anchor
(define *doon-derived-yields*
  '(("bean" . 671.0) ("maize" . 3346.3) ("pea" . 1373.4) ("rice" . 4225.6) ("wheat" . 3515.5)))


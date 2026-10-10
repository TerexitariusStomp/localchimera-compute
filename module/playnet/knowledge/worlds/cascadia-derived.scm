;;; worlds/cascadia-derived.scm — GENERATED from vendored raw by data/emit-derived.scm. DO NOT EDIT.
;;; Regenerate: cd data && guile emit-derived.scm cascadia United States wheat,potato,bean,pea > ../cascadia-derived.scm
;;; Verify (CI): make verify-derived  — re-runs the generator, diffs this file, fails on drift.
;;;
;;; The MECHANICAL layer — pure derivations from the vendored record. Human
;;; JUDGMENT (state-yield anchors, stage-physiology multiplier refinements, the
;;; Taleb tail) lives in cascadia-valley.scm / the shed, layered on top explicitly.
;;; Source raw (sha256/16):
;;;   precip.json 7ac8cfee2c79bb34
;;;   yield-bean.csv 72719c55d60add70
;;;   yield-pea.csv 4146a27d6634dcae
;;;   yield-potato.csv 1711a5df7dea7899
;;;   yield-wheat.csv c882d518c71e75da

;; growing season — auto-detected (calendar months above the mean month)
(define-module (playnet knowledge worlds cascadia-derived)
  #:export (*cascadia-derived-season* *cascadia-derived-warm-quarter-degc*
            *cascadia-derived-annual-mean-degc* *cascadia-derived-scenario-probs*
            *cascadia-derived-scenario-rain* *cascadia-derived-ky-multipliers*
            *cascadia-derived-yields*))

(define *cascadia-derived-season* '(1 2 3 11 12))

;; HOW WARM IT IS WHERE THE WORK HAPPENS (°C, last decade of the record).
;; The shed already knows; anything that needs a working temperature asks here
;; rather than carrying its own table. warm-quarter is bioclim BIO10, the mean
;; of the warmest three consecutive months — NOT of *-season* above, which is
;; detected from rainfall and in a Mediterranean shed is the COLD half of the
;; year. (catalogues/subsistence.scm reads warm-quarter for the sweat curve.)
;;   temp.json c019ce61897f07ed
(define *cascadia-derived-warm-quarter-degc* 20.2)
(define *cascadia-derived-annual-mean-degc* 12.1)

;; scenario probabilities — IMD ±1σ classification of 64 growing seasons
(define *cascadia-derived-scenario-probs*
  '(("normal" . 0.656250) ("drought" . 0.140625) ("flood" . 0.203125)))

;; mean growing-season rainfall within each class (mm) — the water reference
(define *cascadia-derived-scenario-rain*
  '(("drought" . 497.8) ("normal" . 737.6) ("flood" . 1045.9)))

;; per-scenario yield multipliers — FAO Ky × the local rainfall (agronomy.scm)
(define *cascadia-derived-ky-multipliers*
  '(("normal" ("wheat" . 1.00) ("potato" . 1.00) ("bean" . 1.00) ("pea" . 1.00))
     ("drought" ("wheat" . 0.66) ("potato" . 0.64) ("bean" . 0.63) ("pea" . 0.63))
     ("flood" ("wheat" . 0.96) ("potato" . 0.96) ("bean" . 0.92) ("pea" . 0.92))))

;; national baseline yields (kg/ha, OWID/FAOSTAT) — a cross-check anchor
(define *cascadia-derived-yields*
  '(("bean" . 2222.7) ("pea" . 1950.3) ("potato" . 50563.2) ("wheat" . 3232.9)))


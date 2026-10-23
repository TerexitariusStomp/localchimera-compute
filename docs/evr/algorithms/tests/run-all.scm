;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; run-all.scm — Run every test file in this directory, in order.
;;;
;;; Run: guile --no-auto-compile -q -L module -L . \
;;;        -l docs/evr/algorithms/tests/run-all.scm

(load "test-billings.scm")
(load "test-culcus.scm")
(load "test-nac.scm")
(load "test-simulation.scm")

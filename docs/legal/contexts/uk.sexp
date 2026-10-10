;;; uk.sexp — the two insurances the United Kingdom makes a condition of an act.
;;; Hand-authored from cited statute, like fr-national.sexp: this is code, not a
;;; dataset, and no open service publishes it as rules.
;;;
;;; The pack says what the LAW demands and nothing more. Public liability
;;; insurance is voluntary (HSE40), and a volunteer is no employee under the
;;; 1969 Act — "employee" is a person under a contract of service or
;;; apprenticeship (s.2(1)) — so a body with volunteers and no staff owes
;;; neither cover by statute. What a body buys beyond this is its own risk
;;; decision (docs/legal/insurance/README.md). Both rules verified against the
;;; statute.
;;;
;;; Scope: the 1969 Act applies in Great Britain; Northern Ireland has its own
;;; order to the same effect. One nation place stands for both until a steward
;;; places them apart.
((places
  ("uk" "United Kingdom" "world" nation ((iso . "826")) 54.0 -2.5))
 (rules
  ;; Wage labour: every employer carrying on business must insure against
  ;; liability for injury or disease to its employees, with an authorised
  ;; insurer, for at least £5m (the sum is set by regulation, not the Act).
  ((all-of (in-jurisdiction "uk") (on-crossing wage-labour))
   ((obtain "Employers' liability insurance" entity
     (employers-liability)
     ((issuer . "authorised insurer") (per . one-time) (direction . #f)
      (retain . #f) (renew . (every . year)))))
   "uk/employers-liability"
   "Employers' Liability (Compulsory Insurance) Act 1969, s.1 and s.2(1); HSE40"
   "20260101" verified "uk")

  ;; A titled vehicle on public ways: using, or causing or permitting the use
  ;; of, a motor vehicle on a road without third-party cover is an offence.
  ((all-of (in-jurisdiction "uk") (on-crossing public-vehicle))
   ((obtain "Third-party motor insurance" entity
     (third-party-motor)
     ((issuer . "authorised insurer") (per . each-vehicle) (direction . #f)
      (retain . #f) (renew . (every . year)))))
   "uk/motor-third-party"
   "Road Traffic Act 1988, s.143"
   "20260101" verified "uk"))
 ;; The UK's words for federation aspects (law/aspects.scm `clause-aspect`).
 (aspects
  (employers-liability . injury-cover)
  (third-party-motor . third-party-liability)))

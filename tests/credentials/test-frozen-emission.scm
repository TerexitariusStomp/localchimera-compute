;;; tests/credentials/test-frozen-emission.scm — a constructor's emission is frozen; a SAID commits to it.
;;;
;;; Every credential kind in credentials/ and keri/first-person is one
;;; define-credential statement (keri/acdc.scm) or, for the few that compute,
;;; a body over make-credential. What each emits for given inputs is frozen:
;;; the SAID a verifier re-derives commits to the claim set and the edges, so
;;; a change to a constructor's claims is a change to every credential it ever
;;; issued. Pinned here: the SAID of each kind, bare and with every optional
;;; given, as the hand-written constructors emitted them before the move to
;;; define-credential (harnessed on 2026-10-10). A new claim on a kind is a new
;;; schema version, and a new pin.
;;;
;;; Run from project root:
;;;   tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/credentials/test-frozen-emission.scm

(use-modules (playnet test harness)
             (playnet keri acdc) (playnet credentials delegation) (playnet credentials membership)
             (playnet credentials keys) (playnet credentials recomposition) (playnet credentials voting)
             (playnet credentials custody) (playnet credentials audit) (playnet credentials declarations)
             (playnet credentials commitments) (playnet credentials work) (playnet keri first-person credentials)
             (srfi srfi-1))

(define-syntax-rule (frozen name said form)
  (let ((c form))
    (check (symbol->string 'name) (cred-said c) said)
    (check (string-append (symbol->string 'name) " re-derives") (cred-recompute-said c) (cred-said c))))

(define U "0ANONCE000000000000000000")
;; delegation
(frozen delegation.bare "ECrbM3EFYpUnJqI7WkWgI2VvTggQVz8hsnk-hZxgka4x"
  (make-delegation-credential #:issuer-aid "I"
                              #:holder-aid "H"
                              #:franchise 'federation
                              #:fraction 0.5
                              #:mandate-spec #f))
(frozen delegation.full "EKJQn5vBm2U13NwxDrqYdkmjBdhNAlYatoLHZWrVYRep"
  (make-delegation-credential #:issuer-aid "I"
                              #:holder-aid "H"
                              #:franchise '(scope "S")
                              #:fraction 0.25
                              #:mandate-spec '(equal-position yes)
                              #:mandate-text "t"
                              #:at "2026-01-01T00:00:00Z"))
;; membership
(frozen ccf "EIg_zeWhS75NNW6SG0J88ZiQfGob_wtR0NKIzmfT0yMf"
  (make-ccf-credential #:issuer-group-aid "G"
                       #:holder-aid "H"
                       #:commune "C"
                       #:ccf 1
                       #:assessed-at "2026-01-01T00:00:00Z"
                       #:reason "r"))
(frozen exclusion "ENMNmECVwnM6d1NyRnFoMEHpKR8HgkV8NaN3FvEPzMg2"
  (make-exclusion-credential #:issuer-group-aid "G"
                             #:holder-aid "H"
                             #:commune "C"
                             #:excluded-at "2026-01-01T00:00:00Z"))
(frozen fed-membership.bare "EEiC7vmUc-xG3qQb0xc3kN0EjsydFLpzlUY8nsu_my1Q"
  (make-federation-membership-credential #:issuer-group-aid "G"
                                         #:commune-aid "CA"
                                         #:federation "F"
                                         #:commune-id "cid"
                                         #:admitted-at "2026-01-01T00:00:00Z"))
(frozen fed-membership.full "EMt1HrwbIUINmbSSW36VbaYJQX55mdNJpXKBMBgfoja_"
  (make-federation-membership-credential #:issuer-group-aid "G"
                                         #:commune-aid "CA"
                                         #:federation "F"
                                         #:commune-id "cid"
                                         #:admitted-at "2026-01-01T00:00:00Z"
                                         #:edges (list (cons 'x (make-edge "E1" #:operator 'NI2I #:schema #f)))))
(frozen membership "EMA0dk8plaV3eDjhYxS2_cB303eRoE1XdCuHkivEedAF"
  (make-membership-credential #:issuer-group-aid "G"
                              #:holder-aid "H"
                              #:commune "C"
                              #:admitted-at "2026-01-01T00:00:00Z"))
(frozen sturdyref "EOi6lAFoQkSWKuAOfrcpM5_2oBWZZuuWL7psrq3W_cOH"
  (make-federation-sturdyref-credential #:issuer-group-aid "G"
                                        #:commune-aid "CA"
                                        #:commune-id "cid"
                                        #:sturdyref-uri "ocapn://x"
                                        #:netlayer "ws"
                                        #:registered-at "2026-01-01T00:00:00Z"))
(frozen census.bare "EI3JNWlWOS2Hbb0aX1z2_6P67AAcXaPPh3-wvG53Yjko"
  (make-federation-census-credential #:commune-aid "CA"
                                     #:federation-aid "F"
                                     #:goods '("y" "x")
                                     #:told-at "2026-01-01T00:00:00Z"))
(frozen census.full "ENIa_yQXXv9ZN_zl8GMw3PenCV-x2ZQSX0KWyEE-moEF"
  (make-federation-census-credential #:commune-aid "CA"
                                     #:federation-aid "F"
                                     #:goods '("y" "x")
                                     #:told-at "2026-01-01T00:00:00Z"
                                     #:kel '((icp . 1))
                                     #:units '(("x" . "kg"))))
;; keys
(frozen bran-share.bare "EEWN7_LvO3XIPD3CMrDz815tM1c6NwUUMKd27hvBgtni"
  (make-bran-share-credential #:issuer-group-aid "G"
                              #:holder-aid "H"
                              #:share-index 1
                              #:threshold 2
                              #:total-shares 3
                              #:share-data-hex "ab"))
(frozen bran-share.full "ENl3sOLOVOtjMMcgv-_j63OIz8XkGx2GJ_0IL3APC7b4"
  (make-bran-share-credential #:issuer-group-aid "G"
                              #:holder-aid "H"
                              #:share-index 1
                              #:threshold 2
                              #:total-shares 3
                              #:share-data-hex "ab"
                              #:subject-aid "S"))
(frozen witness-assignment "EC_Pkn68vk6iZV-NvZDtnkAXP2Oi5dcgwHAzuASOQSzw"
  (make-witness-assignment-credential #:federation-aid "F"
                                      #:member-aid "M"
                                      #:witness-aid "W"
                                      #:witness-oobi "oobi"
                                      #:group-aid "GA"
                                      #:assigned-at "2026-01-01T00:00:00Z"))
;; recomposition
(frozen merger.bare "ENEiRYPTHMC82yiPwC03IPFyMSNU9Vzp10JNeRMw9FX8"
  (make-scope-merger-credential #:predecessor-a-aid "A"
                                #:predecessor-b-aid "B"
                                #:new-scope-aid "N"
                                #:kind 'commune
                                #:merged-at "2026-01-01T00:00:00Z"))
(frozen merger.full "EB3RSJsU0S_hzO1wn9NNoq-jKS9ABl9SkFDdHa-L6McZ"
  (make-scope-merger-credential #:predecessor-a-aid "A"
                                #:predecessor-b-aid "B"
                                #:new-scope-aid "N"
                                #:kind 'commune
                                #:merged-at "2026-01-01T00:00:00Z"
                                #:predecessors '("P" "Q")
                                #:edges (list (cons 'x (make-edge "E1" #:operator 'NI2I #:schema #f)))))
(frozen split.bare "EHbsFAX9eiQCB2aTbpPakFUeSViCWKrXfPWjd8PoglRO"
  (make-scope-split-credential #:parent-scope-aid "P"
                               #:sub-scope-aids '("S1" "S2")
                               #:kind 'commune
                               #:split-at "2026-01-01T00:00:00Z"))
(frozen split.full "EN9Y6hQ-1rsqmojmE-CO07YnAtw4DburGq41mZYYboDn"
  (make-scope-split-credential #:parent-scope-aid "P"
                               #:sub-scope-aids '("S1" "S2")
                               #:kind 'commune
                               #:split-at "2026-01-01T00:00:00Z"
                               #:edges (list (cons 'x (make-edge "E1" #:operator 'NI2I #:schema #f)))))
(frozen conflict "EB4KkmXTdXGjWP-1MzIQ3-oxoM4yKMJWSMJlqMT0CrP8"
  (make-conflict-resolution-credential #:meta-scope-aid "M"
                                       #:resource-id "r"
                                       #:conflicting-commitments '("c1" "c2")
                                       #:prevailing-commitment "c1"
                                       #:resolution-method 'earliest
                                       #:resolved-at "2026-01-01T00:00:00Z"))
(frozen rejoin.bare "EERkskXb0P5XftfIN90XnKB1rQppQXD74zoOy_WEqoki"
  (make-scope-rejoin-credential #:scope-aid "S"
                                #:old-federation-aid "OF"
                                #:new-federation-aid "NF"
                                #:rejoined-at "2026-01-01T00:00:00Z"))
(frozen rejoin.full "EGnQ_TFnIyi-uzlDQ4wepuus2IdHalwC6ml_nX7KXCoN"
  (make-scope-rejoin-credential #:scope-aid "S"
                                #:old-federation-aid "OF"
                                #:new-federation-aid "NF"
                                #:rejoined-at "2026-01-01T00:00:00Z"
                                #:edges (list (cons 'x (make-edge "E1" #:operator 'NI2I #:schema #f)))))
;; voting
(frozen stance.bare "ED6ZnoThTa61F4QMKirJBP66BUZoQR1Gi6jeHHyQYU5m"
  (make-stance-credential #:citizen-aid "C"
                          #:governance-group-aid "G"
                          #:domain 'policy
                          #:proposal-id "p1"
                          #:position 'yes
                          #:timestamp "2026-01-01T00:00:00Z"
                          #:u U))
(frozen stance.full "EJnhXavcWsQ7t7r1-Fyfc2W5XjA_EfH1uzLCmaO-fN5E"
  (make-stance-credential #:citizen-aid "C"
                          #:governance-group-aid "G"
                          #:domain 'policy
                          #:proposal-id "p1"
                          #:position 'yes
                          #:timestamp "2026-01-01T00:00:00Z"
                          #:u U
                          #:ballot-snapshot-said "ESNAP"))
(frozen expression-stance "EDasfA0lAG2LZ2tqaHey7gd7FY_b8Cvwm_H995Tiz29f"
  (make-expression-stance-credential #:citizen-aid "C"
                                     #:governance-group-aid "G"
                                     #:domain 'policy
                                     #:expression-id "e1"
                                     #:distribution '((t . 1))
                                     #:timestamp "2026-01-01T00:00:00Z"
                                     #:u U))
(frozen ballot-snapshot.bare "EInxGKH3tnTQ8B5a_cY0bAHbyjt4HTgpLwspRHcAOyYG"
  (make-ballot-snapshot-credential #:governance-group-aid "G"
                                   #:domain 'policy
                                   #:proposal-id "p1"
                                   #:franchise 'federation
                                   #:snapshot-said "ESNAP"
                                   #:opened-at "2026-01-01T00:00:00Z"))
(frozen ballot-snapshot.full "ENx3xx_lGhJixgPCSUyNdLmDlKdrO9DU-Kw76xyIPgwa"
  (make-ballot-snapshot-credential #:governance-group-aid "G"
                                   #:domain 'policy
                                   #:proposal-id "p1"
                                   #:franchise 'federation
                                   #:snapshot-said "ESNAP"
                                   #:opened-at "2026-01-01T00:00:00Z"
                                   #:description "d"
                                   #:voice-snapshot-entries '(("c" 1 ()))
                                   #:citizen-registry-aids '("c")))
(frozen tally.bare "EDpqT1zPVO76FBS_TiIPXMyKmxeEX9pKPQ_FX6LqXaoC"
  (make-tally-result-credential #:governance-group-aid "G"
                                #:domain 'policy
                                #:proposal-id "p1"
                                #:franchise 'federation
                                #:winner 'yes
                                #:tally-data '((yes . 1))
                                #:abstain-weight 0.1
                                #:closed-at "2026-01-01T00:00:00Z"))
(frozen tally.full "ECIZ9I7mKTWhc-Zo75lTkktU9Mm2MEAWLhtP8BKXTHnK"
  (make-tally-result-credential #:governance-group-aid "G"
                                #:domain 'policy
                                #:proposal-id "p1"
                                #:franchise 'federation
                                #:winner 'yes
                                #:tally-data '((yes . 1))
                                #:abstain-weight 0.1
                                #:closed-at "2026-01-01T00:00:00Z"
                                #:ballot-snapshot-said "ESNAP"))
(frozen ratification.bare "EGqild4S3hrPCDUcftxPS_4H1iryWd-ZJfpSUn4qi8kh"
  (make-recomposition-ratification-credential #:scope-aid "S"
                                              #:proposal-type 'merge
                                              #:proposal-spec '(a b)
                                              #:ballot-said "EB"
                                              #:tally '((yes . 1))
                                              #:ratified-at "2026-01-01T00:00:00Z"))
(frozen ratification.pred "ENmo4HFruPwG2r8_E4oFZXNZaC-3L9tB643gjz2P15i3"
  (make-recomposition-ratification-credential #:scope-aid "S"
                                              #:proposal-type 'merge
                                              #:proposal-spec '(a b)
                                              #:ballot-said "EB"
                                              #:tally '((yes . 1))
                                              #:ratified-at "2026-01-01T00:00:00Z"
                                              #:issuer-aid "PARENT"
                                              #:predecessors '("A" "B")))
(frozen ratification.succ "EL2bRLh__JxaIgJAYKp0l-ziIIWMK8xh7qePTCfauJiw"
  (make-recomposition-ratification-credential #:scope-aid "S"
                                              #:proposal-type 'merge
                                              #:proposal-spec '(a b)
                                              #:ballot-said "EB"
                                              #:tally '((yes . 1))
                                              #:ratified-at "2026-01-01T00:00:00Z"
                                              #:successor-spec '((kind . commune))))
(frozen ratification.full "ENF0WvY4p9ThYoAKEpqfRFxtL9G5OL3Pxee3-S1tXev4"
  (make-recomposition-ratification-credential #:scope-aid "S"
                                              #:proposal-type 'merge
                                              #:proposal-spec '(a b)
                                              #:ballot-said "EB"
                                              #:tally '((yes . 1))
                                              #:ratified-at "2026-01-01T00:00:00Z"
                                              #:threshold 0.6
                                              #:threshold-met? #f
                                              #:issuer-aid "PARENT"
                                              #:predecessors '("A" "B")
                                              #:successor-spec '((kind . commune))))
;; custody
(frozen custody.bare "EMcNxCeJTbpRwjIciHqFuo0gD-DSZoPRAEgAF0BgjTqM"
  (make-custody-attestation-credential #:issuing-authority-aid "AU"
                                       #:custodian-aid "CU"
                                       #:resource-spec "spec"
                                       #:qty 3))
(frozen custody.full "EAkfg-OsEf02NgZFnk7kxspSOmkk51CmjuoSW_MJToMq"
  (make-custody-attestation-credential #:issuing-authority-aid "AU"
                                       #:custodian-aid "CU"
                                       #:resource-spec "spec"
                                       #:qty 3
                                       #:valid-from "vf"
                                       #:valid-until "vu"
                                       #:supersedes "ESUP"
                                       #:movable #t
                                       #:return-to "RT"
                                       #:condition-floor 1
                                       #:resource "R"
                                       #:qty-unit "kg"
                                       #:kind "k"
                                       #:ref "ref"
                                       #:eligible '("E")))
(frozen ownership.bare "EDeHOnUM3pdoR64dn1hGO-mmekSwuDghNo3QLaGWmuvA"
  (make-ownership-attestation-credential #:owner-aid "O" #:resource-id "R" #:resource-spec "spec"))
(frozen ownership.full "EIXwL0L4upScDqkz5zhRhx65IN5QSMlXh6fSs9wIqBgT"
  (make-ownership-attestation-credential #:owner-aid "O"
                                         #:resource-id "R"
                                         #:resource-spec "spec"
                                         #:kind "passage"
                                         #:holder "H"
                                         #:valid-from "vf"
                                         #:valid-until "vu"
                                         #:qty 2
                                         #:qty-unit "kg"
                                         #:ref "ref"
                                         #:supersedes "ESUP"
                                         #:stake "EST"))
(frozen transfer.bare "EMyFUrRaGyTHAWp1CzpXVneB0ddHGz-FiaLmZ7x0K3Ao"
  (make-custody-transfer-commitment-credential #:from-scope-aid "F"
                                               #:to-scope-aid "T"
                                               #:resource-spec "spec"
                                               #:qty 3
                                               #:new-attestation-said "ENEW"
                                               #:revoked-attestation-said "EOLD"))
(frozen transfer.full "ELnX5VAPJCM15J15-fow_aYlISTnT6IjN_Cu3WCJyL8z"
  (make-custody-transfer-commitment-credential #:from-scope-aid "F"
                                               #:to-scope-aid "T"
                                               #:resource-spec "spec"
                                               #:qty 3
                                               #:new-attestation-said "ENEW"
                                               #:revoked-attestation-said "EOLD"
                                               #:carries-commitments '("K1" "K2")
                                               #:effective-at "ea"))
(frozen reversion "EIqwrpQu77Zt0m8QmKPDt1BgHpHLSW3ZtEXGWhUvkTwl"
  (make-reversion-attestation-credential #:authority-aid "AU"
                                         #:default-custodian-aid "DC"
                                         #:resource-spec "spec"
                                         #:qty 3
                                         #:expired-attestation-said "EEXP"
                                         #:effective-at "ea"))
;; audit
(frozen audit-pass "ED6mt5YqTjtoZIWiRJWRwaOeHzabeVw2xJMcHLrdcVOv"
  (make-audit-pass-credential #:auditor-aid "AU" #:federation-aid "F" #:audited-at "aa" #:cycle 3))
(frozen incoherence "EA_hj746nDrKlnOyOoSeiQdwNk0AmXTkZ73wSeASsVj-"
  (make-incoherence-alert-credential #:auditor-aid "AU"
                                     #:federation-aid "F"
                                     #:violations '("v1")
                                     #:audited-at "aa"
                                     #:cycle 3))
(frozen snapshot.bare "EG2ktKXBJsgbMjQNhOotDiawG3bfVGscsuc6QH0eKvMi"
  (make-derived-state-snapshot-credential #:auditor-aid "AU"
                                          #:scope-aid "S"
                                          #:snapshot-data '((x . 1))
                                          #:snapshot-at "sa"))
(frozen snapshot.full "EPkZ14PUJx8JuBAAySXG_WKU18ErCeyteFRIZnfGjrZ1"
  (make-derived-state-snapshot-credential #:auditor-aid "AU"
                                          #:scope-aid "S"
                                          #:snapshot-data '((x . 1))
                                          #:snapshot-at "sa"
                                          #:input-saids '("I1" "I2")))
;; declarations
(frozen span "EEWA8Pfiy4atne1jMdD0thgEka4WtH8meHbg7eygdLMp"
  (make-span-declaration-credential #:scope-aid "S"
                                    #:resource-id "R"
                                    #:span-place "place"
                                    #:valid-from "vf"
                                    #:valid-until "vu"))
(frozen hosting "EA3Z6mpP4ega5kijE6mtdZncfX-mQbZAH2llEJdpwGSn"
  (make-hosting-willingness-credential #:scope-aid "S" #:resource-spec "spec" #:ceiling 10))
(frozen regime "EBRbu7_PYnSacYUDkCuRmqxh-EkLjMsEg7cC8HTJrXfz"
  (make-regime-claim-credential #:scope-aid "S"
                                #:domain-spec "dom"
                                #:tails 'thin
                                #:process "proc"
                                #:valid-from "vf"))
;; commitments
(frozen commitment.bare "EGHGnkHbQNd_7AEwZ40K3oQpE8hUgY5iBqET0v4mSyNU"
  (make-commitment-credential #:provider-aid "P"
                              #:receiver-aid "R"
                              #:commitment-id "c1"
                              #:action 'work))
(frozen commitment.full "ENx06t-XPVFRu_-2jBUvhpTiuyQzDkZ8jcmg82jqTfqp"
  (make-commitment-credential #:provider-aid "P"
                              #:receiver-aid "R"
                              #:commitment-id "c1"
                              #:action 'work
                              #:resource-conforms-to "spec"
                              #:resource-classified-as '("t")
                              #:resource-quantity 1
                              #:effort-quantity 2
                              #:due "d"
                              #:plan-id "pl"
                              #:process-id "pr"
                              #:satisfies "i1"
                              #:resource-inventoried-as "res"
                              #:triggered-by "tb"))
(frozen redistribution "EICq0y3gHsgOdVklw4HPP9sLNSqwRPaPLrn2-8e-xQU2"
  (make-redistribution-mandate-credential #:federation-aid "F"
                                          #:scope-aid "S"
                                          #:threshold-spec 'spec
                                          #:recipient-policy 'pol
                                          #:period "weekly"
                                          #:effective-from "ef"))
(frozen fulfillment "EPPJ6Zlg_MjhNi8UUczs8JfE06YQ1we_nCeUiA1JKnLB"
  (make-commitment-fulfillment-credential #:receiver-aid "R"
                                          #:provider-aid "P"
                                          #:commitment-said "ECOM"
                                          #:fulfilled-at "fa"
                                          #:note "n"))
(frozen agreement.bare "EOZqa73JG908_KY4v0wDstiP0UG-V_WG9id2jMX5q9aJ"
  (make-agreement-credential #:acceptor-aid "A" #:proposer-aid "P" #:agreement-id "ag1"))
(frozen agreement.full "EECFjhBKojXE1kWFLnpyePkIuvuY9ymebp8Je0SBMi78"
  (make-agreement-credential #:acceptor-aid "A"
                             #:proposer-aid "P"
                             #:agreement-id "ag1"
                             #:proposal-id "pp"
                             #:primary-commitment-ids '("c1")
                             #:reciprocal-commitment-ids '("c2")
                             #:counterparty-provider "cp"
                             #:counterparty-receiver "cr"
                             #:accepted-at "at"))
(frozen intent.bare "EFpTymd6zEyhROcZ8uzEd9XFPmKkBX23l3gINWxfvNP1"
  (make-intent-credential #:issuer-aid "I" #:intent-id "i1" #:action 'work))
(frozen intent.full "EONrl3wu2QzTczRXWR5WDX6ZqWsZ6K2P1HwU-WzXMGig"
  (make-intent-credential #:issuer-aid "I"
                          #:intent-id "i1"
                          #:action 'work
                          #:provider "P"
                          #:resource-conforms-to "spec"
                          #:resource-classified-as '("t")
                          #:resource-quantity 1
                          #:effort-quantity 2
                          #:available-quantity 3
                          #:minimum-quantity 1
                          #:due "d"
                          #:plan-id "pl"
                          #:process-id "pr"
                          #:satisfies "s"
                          #:holder-aid "H"))
;; work
(frozen work-event.bare "EIzca25InJv3MzGr9atSpwMQ-r1X2A8FrT9IOaRrcr9c"
  (make-work-event-credential #:scope-aid "S"
                              #:worker-aid "W"
                              #:event-id "e1"
                              #:hours 2.0
                              #:unit "h"))
(frozen work-event.full "EFb27e_l8hXUieF6y2OGkah920SvI-WPQ9CaTGIvV6M1"
  (make-work-event-credential #:scope-aid "S"
                              #:worker-aid "W"
                              #:event-id "e1"
                              #:hours 2.0
                              #:unit "h"
                              #:scope-id "sid"
                              #:process-id "pr"
                              #:timestamp "ts"
                              #:resource-conforms-to "skill"
                              #:fulfills "ECOM"
                              #:satisfies "EINT"
                              #:skill-said "ESK"))
(frozen observation.bare "EA2majO32dtvsdx5tZoZHd_t1tOSIV6dXSOSht-cITA1"
  (make-observation-event-credential #:scope-aid "S"
                                     #:holder-aid "H"
                                     #:event-id "e1"
                                     #:action 'produce))
(frozen observation.full "ELJ6Dq8Yesre5gyI_56D7Yl1swJ5OQw5fusdBixpbhPC"
  (make-observation-event-credential #:scope-aid "S"
                                     #:holder-aid "H"
                                     #:event-id "e1"
                                     #:action 'produce
                                     #:qty 1
                                     #:unit "kg"
                                     #:scope-id "sid"
                                     #:resource-conforms-to "spec"
                                     #:at-location "L"
                                     #:to-location "L2"
                                     #:timestamp "ts"
                                     #:fulfills "ECOM"
                                     #:evidence "ev"))
(frozen contrary "EMJZuLre1yXinIAGCM0tMmCgeCKBM2AL37a6dsK3CWU1"
  (make-contrary-observation-credential #:observer-aid "O"
                                        #:scope-id "sid"
                                        #:process "proc"
                                        #:action 'produce
                                        #:spec "spec"
                                        #:nominal 1
                                        #:reading 2
                                        #:witness "W"
                                        #:observed-at "oa"))
(frozen skill.bare "EMjOnGzYFq44m0BEcxj3PXNnWspQiPtCcA_jsr1NL7cU"
  (make-skill-credential #:issuing-aid "I"
                         #:worker-aid "W"
                         #:skill "skill"
                         #:founding-event-said #f))
(frozen skill.full "EBgwG43TBRMpPN86ccFFLESCUemaEs0IS4_AlV0TlRGg"
  (make-skill-credential #:issuing-aid "I"
                         #:worker-aid "W"
                         #:skill "skill"
                         #:founding-event-said "EFOUND"
                         #:valid-from "vf"
                         #:valid-until "vu"))
(frozen claim.bare "EMuj3bNuJxnaKDcaQHs3bV_VLlvFnjq699BK0kG7yMNd"
  (make-claim-event-credential #:scope-aid "S"
                               #:claimant-aid "C"
                               #:event-id "e1"
                               #:labor-cost 5
                               #:unit "h"))
(frozen claim.full "EH66y3ku-f4Zv0mBK1QGNVrEW0ZeQmV2EVvFeLLZ-Mjc"
  (make-claim-event-credential #:scope-aid "S"
                               #:claimant-aid "C"
                               #:event-id "e1"
                               #:labor-cost 5
                               #:unit "h"
                               #:resource-spec "spec"
                               #:qty 1
                               #:timestamp "ts"
                               #:settles "ESET"))
(frozen external-index.bare "EMOUmjLQS7HyXIAIGrQCnCDWfDJEqQK_0iflPMaHlnae"
  (make-external-index-observation-credential #:oracle-aid "O"
                                              #:index-uri "uri"
                                              #:observed-value 7
                                              #:observed-at "oa"))
(frozen external-index.full "EMvn51y3ZmvB7KGD6BacTOuqABR8hR3i2tJ74QJR_VwN"
  (make-external-index-observation-credential #:oracle-aid "O"
                                              #:index-uri "uri"
                                              #:observed-value 7
                                              #:observed-at "oa"
                                              #:holder-aid "H"
                                              #:source-note "n"))
;; first-person
(frozen device.bare "EMGuDa8OQqGKLjXzV7uMkXzVcsHx87JjOEC7HfN89np7"
  (make-device-authorization-credential #:person-aid "P"
                                        #:device-aid "D"
                                        #:label "lab"
                                        #:tier 'device
                                        #:enrolled-at "ea"))
(frozen device.full "EE9WOcEng1dmpWKhigefL_5goOjpHg2i4lzU4HDvRrVy"
  (make-device-authorization-credential #:person-aid "P"
                                        #:device-aid "D"
                                        #:label "lab"
                                        #:tier 'device
                                        #:enrolled-at "ea"
                                        #:expires-at "x"
                                        #:active #f
                                        #:doors '("d")))
(frozen authorized-issuer "EHEC6Fkcqt-54EdDqqhuT6pMBBiMmakOKSE1sQGV2gLn"
  (make-authorized-issuer-credential #:root-aid "ROOT"
                                     #:ecosystem-aid "ECO"
                                     #:blessed-at "ba"
                                     #:active #f
                                     #:expires-at "x"))
(frozen personhood.bare "EBIE0c4_SCXWbiexd7QoBsvQ03StoEdji6A1u3gHPJ3b"
  (make-personhood-credential #:ecosystem-aid "ECO" #:holder-aid "H" #:enrolled-at "ea"))
(frozen personhood.full "EHF7FiIHGi6voQrj44j7WIm4fD_TAxsXcVxr_bEUpgOP"
  (make-personhood-credential #:ecosystem-aid "ECO"
                              #:holder-aid "H"
                              #:enrolled-at "ea"
                              #:enrollment-evidence-digest "dg"
                              #:active #f
                              #:sponsor-aid "SP"
                              #:expires-at "x"
                              #:witness-edges (list (cons 'w1 (make-edge "EW" #:operator 'NI2I #:schema #f)))
                              #:issuer-authz-said "EAIC"))
(frozen relationship "EHw6jEb2isSBWDUyHWe0ofz1VHhmzAuNKqcMI3A_B9bq"
  (make-relationship-credential #:issuer-aid "I"
                                #:subject-aid "SUB"
                                #:relationship-type 'guardian
                                #:issuer-phc-said "EPHC"
                                #:issued-at "ia"
                                #:subject-persona "per"
                                #:expires-at "x"))
(frozen contact-point "EFzMzUei69RXxZwLU2HMbCi9mh_vF3O6qVsUMdDAHruC"
  (make-contact-point-credential #:subject-aid "S"
                                 #:kind 'email
                                 #:ctx "a@b"
                                 #:style 'rich
                                 #:issued-at "ia"
                                 #:expires-at "x"
                                 #:u U))
(frozen body.bare "ELAsl6NO3lh6BQjZzEB9lNKBjr1pZ4WMuiUxA_aAOhgs"
  (make-body-credential #:ecosystem-aid "ECO" #:body-aid "B" #:admitted-at "aa" #:u U))
(frozen body.full "ELK5B9y2Uva9bF73ERjnVp5E2B5xVOdtM-pxXgXo4Nkg"
  (make-body-credential #:ecosystem-aid "ECO"
                        #:body-aid "B"
                        #:admitted-at "aa"
                        #:u U
                        #:kind "coop"
                        #:jurisdiction "de"
                        #:legal-ids '("L")
                        #:quorum 2
                        #:expires-at "x"
                        #:issuer-authz-said "EAIC"))
(frozen body-role.bare "EHFB-otudBnOKXrPt2tLUx5hSUxTcRv87INk2XAWqX0r"
  (make-body-role-credential #:body-aid "B" #:holder-aid "H" #:role 'steward #:since "s" #:u U))
(frozen body-role.full "EEZZskfvXAq9yRig3KDp9pFfHwvNT25fR--J6GVcq75K"
  (make-body-role-credential #:body-aid "B"
                             #:holder-aid "H"
                             #:role 'steward
                             #:since "s"
                             #:u U
                             #:until "u"
                             #:quorum 2
                             #:body-cred-said "EBODY"))

;; Every argument is a keyword and a missing one is named.
(check "a required keyword left out is an error naming it"
       (catch #t
         (lambda () (make-audit-pass-credential #:auditor-aid "A") #f)
         (lambda (key . args) (and (member #:federation-aid (apply append (filter list? args))) #t))))
(check "a positional call is an error"
       (catch #t
         (lambda () (make-audit-pass-credential "A" "F") #f)
         (lambda _ #t)))

(display "\n")
(test-summary!)

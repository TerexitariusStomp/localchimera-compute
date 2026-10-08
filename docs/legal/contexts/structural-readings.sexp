;;; structural-readings.sexp — what a structural demand's incumbent function is
;;; in a place: the `readings` section of a context pack (law/incumbent-readings.scm).
;;; Hand-authored from cited law.
;;;
;;; A reading lists the clauses of a demand's incumbent that are IN FORCE in the
;;; place. The clauses come from the demand itself (law/structural-demands.scm); a
;;; coercive clause the reading leaves out is one the place has already shed, and
;;; the law face shows it as won there.
;;;
;;; This pack reads ONE demand, "Separate church from state", at the level of the
;;; nation. Its clauses:
;;;
;;;   public-education     the state provides schooling
;;;   civil-registry       the state keeps births, marriages and deaths
;;;   established-worship  the state recognises, pays or collects for a creed
;;;   religious-schooling  the state runs or funds confessional schooling
;;;
;;; A region that differs from its nation carries its own reading and the nation's
;;; stands everywhere else. Berlin is read here, under Art. 141 GG; Bremen under
;;; the same article, Alsace-Moselle under the 1801 concordat and a US state with
;;; a voucher programme are the next readings to write. Every other demand is
;;; unread in every place: its general case, registered on the root by
;;; law/structural-demands.scm, is what a place inherits.
;;;
;;; `uncertain` marks a reading whose mapping onto the clauses is a judgement a
;;; steward should check; the note says what the judgement is.
((places
  ;; the pack stands alone; a pack that also places these merges with it
  ("us" "United States" "world" nation ((iso . "840")) #f #f)
  ("mexico" "Mexico" "world" nation ((iso . "484")) #f #f)
  ("canada" "Canada" "world" nation ((iso . "124")) #f #f)
  ("eu" "European Union" "world" region () #f #f)
  ("germany" "Germany" "eu" nation ((iso . "276")) 51.0 10.0)
  ("berlin" "Berlin" "germany" region ((ags . "11")) 52.52 13.4)
  ("france" "France" "eu" nation ((iso . "250")) 46.6 2.3))
 (rules)
 (readings
  ((place . "france") (demand . "Separate church from state")
   (in-force public-education civil-registry religious-schooling)
   (source . "Loi du 9 décembre 1905 concernant la séparation des Églises et de l'État, art. 2; Loi n° 59-1557 du 31 décembre 1959 (loi Debré), contrats d'association")
   (as-of . "2026-10-02") (confidence . reported) (steward . "scope:civic")
   (note . "The Republic recognises, pays and subsidises no creed since 1905. Private schools under contract, most of them Catholic, are funded by the state since 1959."))
  ((place . "germany") (demand . "Separate church from state")
   (in-force public-education civil-registry established-worship religious-schooling)
   (source . "Grundgesetz Art. 7 Abs. 3 (Religionsunterricht als ordentliches Lehrfach); Art. 140 GG i.V.m. Art. 137 Abs. 6 WRV (Kirchensteuer)")
   (as-of . "2026-10-02") (confidence . uncertain) (steward . "scope:civic")
   (note . "Religious instruction is a regular subject in state schools. Art. 137 Abs. 1 WRV says there is no state church; the church levy collected by the tax offices is read here as established worship, and that mapping is the uncertain part."))
  ((place . "berlin") (demand . "Separate church from state")
   (in-force public-education civil-registry established-worship)
   (source . "Grundgesetz Art. 141 (Bremer Klausel); Schulgesetz für das Land Berlin §§ 12–13 (Ethik als Pflichtfach, Religionsunterricht in Verantwortung der Religionsgemeinschaften)")
   (as-of . "2026-10-02") (confidence . uncertain) (steward . "scope:civic")
   (note . "Art. 141 GG exempts Berlin from Art. 7 Abs. 3: religious instruction is a voluntary offer of the religious communities and ethics is the compulsory subject. The church levy is collected as in the rest of Germany, read as established worship with the same uncertainty."))
  ((place . "us") (demand . "Separate church from state")
   (in-force public-education civil-registry)
   (source . "U.S. Const. amend. I (Establishment Clause); Everson v. Board of Education, 330 U.S. 1 (1947)")
   (as-of . "2026-10-02") (confidence . uncertain) (steward . "scope:civic")
   (note . "No creed is established and state schools are secular. Public money reaches religious schools through state voucher and tuition programmes (Zelman v. Simmons-Harris, 536 U.S. 639 (2002); Carson v. Makin, 596 U.S. 767 (2022)); that varies by state and belongs to state readings."))
  ((place . "mexico") (demand . "Separate church from state")
   (in-force public-education civil-registry)
   (source . "Constitución Política de los Estados Unidos Mexicanos, art. 3 (educación laica), art. 24, art. 130 (separación del Estado y las iglesias)")
   (as-of . "2026-10-02") (confidence . reported) (steward . "scope:civic")
   (note . "State education is secular by art. 3 and the separation of state and churches is a constitutional principle by art. 130."))
  ((place . "canada") (demand . "Separate church from state")
   (in-force public-education civil-registry religious-schooling)
   (source . "Constitution Act, 1867, s. 93 (denominational school rights)")
   (as-of . "2026-10-02") (confidence . reported) (steward . "scope:civic")
   (note . "No church is established. Roman Catholic separate schools are publicly funded in Ontario, Alberta and Saskatchewan under s. 93 and its provincial counterparts."))))

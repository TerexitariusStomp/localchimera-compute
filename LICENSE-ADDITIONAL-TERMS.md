# Additional Terms for Free Association

## Supplementing AGPL-3.0 (Section 7)

Copyright © 2026 Free Association Contributors

These additional terms supplement the GNU Affero General Public License v3.0
under which Free Association is licensed, pursuant to Section 7 of that license.

---

## 1. Attribution Requirement (Section 7b)

Any use of this software in user-facing applications, including modified
versions and network services, must display prominent attribution visible
to end users:

**"Powered by Free Association coordination infrastructure
https://github.com/interplaynetary/free-association"**

This attribution must appear in at least one of:
- Web interfaces (footer or about page)
- Desktop/mobile applications (about or credits section)
- Command-line tools (help text or version info)

**Rationale:** This preserves credit to the project and its contributors while
allowing full freedom to use and modify the software.

---

## 2. Protocol Fidelity Notice (Section 7c)

Modified versions that alter the coordination protocol — specifically the
recognition weight calculation, capacity allocation algorithm, or convergence
mechanism as defined in the project's protocol specification — must be clearly
marked as experimental or derivative.

Modified versions must not be represented as the canonical Free Association
protocol unless they pass the reference conformance test suite (located in
`tests/conformance/` when available).

**Required notice for modified versions:**

"This is a modified version of Free Association with changes to [specify
what changed]. It may not be compatible with the canonical protocol."

**Rationale:** Prevents fragmentation while allowing innovation. Modified
versions are fully permitted under AGPL but must be clearly identified so
users can make informed choices about compatibility.

---

## 3. Interoperability Commitment (Community Norm)

**Note:** This section is a community norm, not a license term. It is not
enforceable under copyright law but represents the shared values of the
Free Association community.

Network services using this software are encouraged to maintain
interoperability with other Free Association implementations by:
- Using standard data formats as documented in the protocol specification
- Enabling data export/import in canonical format
- Not creating artificial barriers to user data portability

**Rationale:** Ensures the coordination infrastructure remains open and
prevents vendor lock-in. The AGPL's source disclosure requirements (Section 13)
already provide the legal foundation; this norm builds the cultural one.

---

## 4. Interpretation

These additional terms are specifically designed to:
- Prevent invisible use without attribution
- Maintain protocol integrity and trust
- Enable ecosystem growth through interoperability
- Protect users from fragmented, incompatible implementations

These terms do NOT:
- Restrict who can use the software (anyone can)
- Require payment or licensing fees (free as in freedom and beer)
- Prevent commercial use (commercial use is permitted and encouraged)
- Prevent forking (forks are encouraged — just attribute and label properly)

---

## 5. Enforcement

The enforceable additional terms (Sections 1 and 2) are part of the license
and are enforceable under copyright law. Violation of these terms constitutes
copyright infringement.

We strongly prefer dialogue over litigation. If you're uncertain about
compliance, please contact: info@openassociation.org

---

## 6. Removal of Terms

Per AGPL-3.0 Section 7, you may remove these additional terms from copies
you convey. Removing them does not grant permission to violate the base
AGPL-3.0 requirements, which include source code availability for network
services (Section 13).

---

The enforceable additional terms in this document are valid under AGPL-3.0
Section 7(b) and 7(c).

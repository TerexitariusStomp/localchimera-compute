# SPDX-License-Identifier: AGPL-3.0-or-later
# localchimera/egress — destination policy for egress relay claims.
#
# An egress relay asks the lender's tab to exit to the open internet on the
# borrower's behalf. What destinations a commune permits is commune policy —
# this package is the decision the node's allowDest consults when the lender
# wires OPA as its egress gate:
#
#   POST /v1/data/localchimera/egress/allow
#   input.node        — the lender's did:key answering the claim
#   input.commune     — the commune's AID the claim lives under
#   input.scheme      — the destination URL's scheme ("https", "wss")
#   input.host        — the destination URL's host
#   input.destination — the full URL, for audit
#
# Permitted destinations live at data.localchimera.egress:
#   {"<commune-aid>": {"schemes": ["https", "wss"],
#                      "allowed_hosts": ["cdn.example", "api.example"]}}
#
# Default deny: a commune that pushed no egress data exits to nothing —
# the fail-closed answer, matching the doors policy's own rule.

package localchimera.egress

default allow := false

allow if {
	input.scheme in data.localchimera.egress[input.commune].schemes
	input.host in data.localchimera.egress[input.commune].allowed_hosts
}

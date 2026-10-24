# SPDX-License-Identifier: AGPL-3.0-or-later
# localchimera/doors/machine — the OPA policy the compute doors consult.
#
# The delegate posts /v1/data/localchimera/doors/machine with:
#   input.citizen — the actor's did:key / keri AID
#   input.door    — the door name (machine-offer, machine-claim, …)
#   input.commune — the commune's AID the door's scope lives under
#   input.action  — create | read | update | delete | administer
#
# Membership data is pushed into OPA at data.localchimera.members:
#   {"<commune-aid>": {"members": ["<did>", …], "admins": ["<did>", …]}}
# A door keeps its own checks — this policy is the second opinion, and
# default deny means a door without pushed membership data fails closed.

package localchimera.doors.compute

default allow := false

# a commune member may create and read
allow if {
	input.action in {"create", "read"}
	is_member
}

# only the commune's admins administer
allow if {
	input.action == "administer"
	is_admin
}

is_member if input.citizen in data.localchimera.members[input.commune].members
is_admin if input.citizen in data.localchimera.members[input.commune].admins

# the parity live leg's fixture answers a decision, not a hang — OPA
# returns {"result": {"allow": false}} when membership data is absent,
# which is the fail-closed answer, not an error.

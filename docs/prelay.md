Next: Prelay Utils, Previous: libp2p, Up: Netlayers [Contents][Index]
7.5.4 Prelay (Unencrypted, v0)

The purpose of the prelay netlayer is to permit connections between two parties which cannot feasibly directly connect. For instance, some users may be able to feasibly connect unidirectionally via the TCP + TLS netlayer to a “public” node, but may not be themselves reachable over a consistent IP address. For this reason, the Prelay netlayer exists.

The surprising thing about the Prelay netlayer is that it is a netlayer which runs _over another netlayer_ by passing messages through an intermediate object, which itself speaks to other intermediate objects routing to other likely isolated users, bridging those users with the illusion of being direct peers. (The users need not use relays on the same node; “federation” is achieved automatically through the underlying OCapN netlayer’s connectivity properties.)

The primary limitation of the prelay netlayer at present is that messages are delivered in cleartext through the chosen relay, unauthenticated, which means the relay has the power to both snoop on and modify messages. A fully end-to-end-encrypted Relay netlayer is on schedule to replace the present unencrypted, unauthenticated design. At present the prelay netlayer has characteristics similar to IRC, vanilla ActivityPub, and many multiplayer game systems which also tend to rely on trusting a provider, but we would like to (and will!) do better in the future.

Some simpler APIs for the prelay netlayer are coming, particularly a convenient daemon for managing prelay nodes for users.

In the meanwhile, there are two essential APIs. The first is run on relay nodes, which act as the routers:

Procedure: spawn-prelay-pair enliven ¶

    Spawn a pair of prelay objects: the endpoint (public) and controller (private). The endpoint permits other nodes to send messages, and the controller permits sending messages to other nodes.

    enliven is a capability to enliven a sturdyref, and returns a promise. Probably a facet of the MyCapN object.

    Returns two values to its continuation, the endpoint and controller respectively.

In order for the endpoint to be useful as a public identity, a sturdyref must be made for it and then converted with the following procedure:

Procedure: prelay-sturdyref->prelay-node prelay-endpoint-sref ¶

    This transforms prelay-endpoint-sref into an OCapN prelay node identifier and returns that object and identifies this node on the network. (This is done by transforming and serializing relevant information about the sturdyref into a data structure that is then packed into the ocapn-node-designator object, but this detail is not particularly important for most users.)

This transformation can be reversed with the following procedure:

Procedure: prelay-node->prelay-sturdyref prelay-node ¶

    Do the reverse of prelay-sturdyref->prelay-node, which is to say, transform the node back into a sturdyref which represents the endpoint which handles routing messages for this node.

    Whew, that’s a lot! The above procedures are essential for setting up prelay-as-relay-host infrastructure, but setting up a prelay-using netlayer is much simpler:

Constructor: ^prelay-netlayer bcom prelay-endpoint-sref prelay-controller ¶

    Constructs the prelay netlayer which lives on the client.

    Takes two arguments at spawn time. prelay-endpoint-sref is a sturdyref of the endpoint we will use to communicate with. prelay-controller is a live, probably remote, reference which we use to pilot the relay we communicate through.

Persistence Environment: prelay-env ¶

Next: Prelay Utils, Previous: libp2p, Up: Netlayers [Contents][Index]

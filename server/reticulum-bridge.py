#!/usr/bin/env python3
"""reticulum-bridge.py — Bridge between Goblins OCapN and Reticulum

Follows the same pattern as Goblins' go-libp2p-daemon bridge:
- Control socket: line-delimited text commands from Guile
- Per-connection Unix socket pairs: raw byte shuttle between
  Guile (Syrup) and Reticulum (Channel)

Usage:
  python3 reticulum-bridge.py [--control-socket PATH] [--socket-dir PATH]

Requires: rnsd running (or this becomes the Reticulum instance).
"""

import argparse
import os
import socket
import struct
import sys
import threading
import time
import RNS

# --- OCapN Message type for Reticulum Channel ---

class OCapNMessage(RNS.MessageBase):
    """Raw byte container for OCapN/Syrup messages over Reticulum Channel."""
    MSGTYPE = 0x0CA0  # "OCA" in hex, unique message type

    def __init__(self):
        super().__init__()
        self.data = b""

    def pack(self):
        return self.data

    def unpack(self, raw):
        self.data = raw


# --- Bridge ---

class ReticulumBridge:
    def __init__(self, control_path, socket_dir):
        self.control_path = control_path
        self.socket_dir = socket_dir
        self.connections = {}  # dest_hash -> (link, guile_sock)

        # Ensure socket directory exists
        os.makedirs(socket_dir, exist_ok=True)

        # Initialize Reticulum (connects to rnsd if running)
        self.reticulum = RNS.Reticulum()

        # Create our identity
        identity_path = os.path.join(socket_dir, "identity")
        if os.path.exists(identity_path):
            self.identity = RNS.Identity.from_file(identity_path)
            RNS.log(f"Loaded identity from {identity_path}")
        else:
            self.identity = RNS.Identity()
            self.identity.to_file(identity_path)
            RNS.log(f"Created new identity, saved to {identity_path}")

        # Create destination for incoming OCapN connections
        self.destination = RNS.Destination(
            self.identity,
            RNS.Destination.IN,
            RNS.Destination.SINGLE,
            "goblins", "ocapn"
        )
        self.destination.set_link_established_callback(self._on_incoming_link)
        self.destination.accepts_links(True)

        # Announce ourselves
        self.destination.announce()
        self.dest_hash = self.destination.hash.hex()
        RNS.log(f"OCapN destination: {self.dest_hash}")

        # State set by NEW command
        self.incoming_sock_path = None
        self.outgoing_sock_path = None
        self.incoming_server = None

    def _on_incoming_link(self, link):
        """Called when a remote peer establishes a Reticulum Link to us."""
        RNS.log(f"Incoming link from {link.get_remote_identity()}")

        # Set up Channel for OCapN messages
        channel = link.get_channel()
        channel.register_message_type(OCapNMessage)

        if not self.incoming_sock_path:
            RNS.log("No incoming socket path set, dropping link")
            link.teardown()
            return

        # Connect to Guile's incoming socket
        try:
            guile_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            guile_sock.connect(self.incoming_sock_path)
        except Exception as e:
            RNS.log(f"Failed to connect to Guile incoming socket: {e}")
            link.teardown()
            return

        peer_hash = link.destination.hash.hex() if link.destination else "unknown"
        self.connections[peer_hash] = (link, guile_sock)

        # Start shuttling bytes
        self._start_shuttle(link, channel, guile_sock, peer_hash)

    def _start_shuttle(self, link, channel, guile_sock, peer_hash):
        """Shuttle bytes between Guile Unix socket and Reticulum Channel."""

        # Reticulum → Guile: Channel message handler
        def on_channel_message(message):
            try:
                # Length-prefix the message for Guile
                data = message.data
                guile_sock.sendall(struct.pack("!I", len(data)) + data)
            except Exception as e:
                RNS.log(f"Error forwarding to Guile: {e}")
                link.teardown()
            return True

        channel.add_message_handler(on_channel_message)

        # Guile → Reticulum: read from Unix socket, send via Channel
        def guile_to_reticulum():
            try:
                while link.status == RNS.Link.ACTIVE:
                    # Read length-prefixed message
                    header = _recv_exact(guile_sock, 4)
                    if not header:
                        break
                    length = struct.unpack("!I", header)[0]
                    data = _recv_exact(guile_sock, length)
                    if not data:
                        break

                    msg = OCapNMessage()
                    msg.data = data
                    channel.send(msg)
            except Exception as e:
                RNS.log(f"Guile→Reticulum shuttle error: {e}")
            finally:
                guile_sock.close()
                if peer_hash in self.connections:
                    del self.connections[peer_hash]

        threading.Thread(target=guile_to_reticulum, daemon=True).start()

        # Link closure handler
        def on_link_closed(link):
            RNS.log(f"Link closed: {peer_hash}")
            try:
                guile_sock.close()
            except:
                pass
            if peer_hash in self.connections:
                del self.connections[peer_hash]

        link.set_closed_callback(on_link_closed)

    def connect_to(self, dest_hash_hex):
        """Initiate an outgoing Reticulum Link to a remote peer."""
        dest_hash = bytes.fromhex(dest_hash_hex)

        if not RNS.Transport.has_path(dest_hash):
            RNS.log(f"No path to {dest_hash_hex}, requesting...")
            RNS.Transport.request_path(dest_hash)
            # Wait for path (up to 15 seconds)
            for _ in range(150):
                time.sleep(0.1)
                if RNS.Transport.has_path(dest_hash):
                    break
            else:
                RNS.log(f"Path discovery timeout for {dest_hash_hex}")
                return None

        # Recall the destination identity
        identity = RNS.Identity.recall(dest_hash)
        if not identity:
            RNS.log(f"Cannot recall identity for {dest_hash_hex}")
            return None

        dest = RNS.Destination(
            identity,
            RNS.Destination.OUT,
            RNS.Destination.SINGLE,
            "goblins", "ocapn"
        )

        link = RNS.Link(dest)

        # Wait for link establishment
        for _ in range(100):
            time.sleep(0.1)
            if link.status == RNS.Link.ACTIVE:
                break
        else:
            RNS.log(f"Link establishment timeout for {dest_hash_hex}")
            return None

        RNS.log(f"Link established to {dest_hash_hex}")

        # Set up Channel
        channel = link.get_channel()
        channel.register_message_type(OCapNMessage)

        # Connect to Guile's outgoing socket
        if not self.outgoing_sock_path:
            RNS.log("No outgoing socket path set")
            link.teardown()
            return None

        try:
            guile_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            guile_sock.connect(self.outgoing_sock_path)
        except Exception as e:
            RNS.log(f"Failed to connect to Guile outgoing socket: {e}")
            link.teardown()
            return None

        self.connections[dest_hash_hex] = (link, guile_sock)
        self._start_shuttle(link, channel, guile_sock, dest_hash_hex)
        return link

    def handle_control(self, conn):
        """Handle control commands from Guile over the control socket."""
        with conn.makefile("r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue

                parts = line.split()
                cmd = parts[0]

                if cmd == "NEW":
                    # Parse: NEW incoming:<path> outgoing:<path> protocol:ocapn version:1.0
                    params = {}
                    for part in parts[1:]:
                        if ":" in part:
                            key, val = part.split(":", 1)
                            params[key] = val

                    self.incoming_sock_path = params.get("incoming")
                    self.outgoing_sock_path = params.get("outgoing")
                    RNS.log(f"NEW: incoming={self.incoming_sock_path} outgoing={self.outgoing_sock_path}")

                    # Respond with our destination hash
                    response = f"destination:{self.dest_hash}\n"
                    conn.sendall(response.encode())

                elif cmd == "CONNECT":
                    dest_hash = parts[1] if len(parts) > 1 else ""
                    RNS.log(f"CONNECT: {dest_hash}")
                    result = self.connect_to(dest_hash)
                    if result:
                        conn.sendall(b"OK\n")
                    else:
                        conn.sendall(b"FAIL\n")

                elif cmd == "ANNOUNCE":
                    self.destination.announce()
                    conn.sendall(b"OK\n")

                elif cmd == "QUIT":
                    conn.sendall(b"OK\n")
                    return

    def run(self):
        """Main loop: listen on control socket for Guile commands."""
        # Clean up stale socket
        if os.path.exists(self.control_path):
            os.unlink(self.control_path)

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.control_path)
        server.listen(5)
        RNS.log(f"Control socket listening on {self.control_path}")

        try:
            while True:
                conn, _ = server.accept()
                threading.Thread(
                    target=self.handle_control,
                    args=(conn,),
                    daemon=True
                ).start()
        except KeyboardInterrupt:
            RNS.log("Shutting down")
        finally:
            server.close()
            if os.path.exists(self.control_path):
                os.unlink(self.control_path)


def _recv_exact(sock, n):
    """Receive exactly n bytes from socket."""
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def main():
    parser = argparse.ArgumentParser(description="Reticulum bridge for Goblins OCapN")
    parser.add_argument("--control-socket",
                        default="/var/run/reticulum-bridge.sock",
                        help="Unix socket path for control commands")
    parser.add_argument("--socket-dir",
                        default="/tmp/goblins-reticulum",
                        help="Directory for per-connection Unix sockets")
    args = parser.parse_args()

    bridge = ReticulumBridge(args.control_socket, args.socket_dir)
    bridge.run()


if __name__ == "__main__":
    main()

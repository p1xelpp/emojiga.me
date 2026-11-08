import argparse
import json
import math
import socket
import socketserver
import threading
import time
import uuid
from pathlib import Path
from queue import Empty, Queue


DEFAULT_PORT = 27016


class _ClientConnection:
    def __init__(self, player_id, socket_file):
        self.player_id = player_id
        self.socket_file = socket_file
        self.send_lock = threading.Lock()
        self.position = [0.0, 0.0, 0.0]
        self.rotation_y = 0.0

    def send(self, message):
        data = (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")
        with self.send_lock:
            self.socket_file.write(data)
            self.socket_file.flush()


class HostServer:
    """Serves a world JSON file and relays connected players' positions."""

    def __init__(self, host="0.0.0.0", port=DEFAULT_PORT, world_path=None):
        self.host = host
        self.port = port
        self.world_path = (
            Path(world_path)
            if world_path
            else Path(__file__).resolve().with_name("world.json")
        )
        self._lock = threading.Lock()
        self._clients = {}
        self._flood_expires_at = 0.0
        self._comet_used = False
        self._opened_chests = {}
        self._beacon_stop = threading.Event()
        self._beacon_thread = threading.Thread(target=self._run_beacon, daemon=True)
        self._beacon_thread.start()
        self._server = self._make_server()

    def _run_beacon(self):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("", 27015))
            sock.settimeout(1.0)
            while not self._beacon_stop.is_set():
                try:
                    data, addr = sock.recvfrom(256)
                    if data == b"EMOJI_MATCH_PING":
                        sock.sendto(f"EMOJI_MATCH_PONG:{self.port}".encode("utf-8"), addr)
                except socket.timeout:
                    continue
                except OSError:
                    break
            sock.close()
        except OSError:
            pass

    def _make_server(self):
        owner = self

        class RequestHandler(socketserver.StreamRequestHandler):
            def handle(self):
                line = self.rfile.readline()
                if not line:
                    return

                try:
                    request = json.loads(line.decode("utf-8"))
                    if not isinstance(request, dict) or request.get("type") != "join":
                        raise ValueError("First message must be a join request")
                    world = json.loads(owner.world_path.read_text(encoding="utf-8"))
                    owner._validate_world(world)
                except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
                    self.wfile.write(
                        (json.dumps({"type": "error", "message": str(error)}) + "\n").encode("utf-8")
                    )
                    self.wfile.flush()
                    return

                player_id = uuid.uuid4().hex
                client = _ClientConnection(player_id, self.wfile)
                with owner._lock:
                    existing = [
                        {
                            "id": peer.player_id,
                            "position": peer.position,
                            "rotation_y": peer.rotation_y,
                        }
                        for peer in owner._clients.values()
                    ]
                    flood_remaining = max(0, owner._flood_expires_at - time.time())
                    comet_struck = owner._comet_used
                    now = time.time()
                    opened_chests = [
                        int(cid)
                        for cid, t in owner._opened_chests.items()
                        if now - t < 20.0
                    ]
                    owner._clients[player_id] = client
                    client.send(
                        {
                            "type": "welcome",
                            "id": player_id,
                            "world": world,
                            "players": existing,
                            "flood_remaining": flood_remaining,
                            "comet_available": not comet_struck,
                            "comet_struck": comet_struck,
                            "opened_chests": opened_chests,
                        }
                    )
                owner._broadcast(
                    {"type": "player_join", "id": player_id, "position": client.position},
                    exclude=player_id,
                )
                print(f"Player {player_id[:8]} connected from {self.client_address[0]}")

                try:
                    for line in self.rfile:
                        try:
                            message = json.loads(line.decode("utf-8"))
                        except (UnicodeDecodeError, json.JSONDecodeError):
                            continue
                        owner._handle_message(client, message)
                finally:
                    with owner._lock:
                        owner._clients.pop(player_id, None)
                    owner._broadcast({"type": "player_leave", "id": player_id})
                    print(f"Player {player_id[:8]} disconnected")

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        return Server((self.host, self.port), RequestHandler)

    @staticmethod
    def _validate_world(world):
        if (
            not isinstance(world, dict)
            or world.get("version") != 1
            or not isinstance(world.get("blocks"), list)
            or not isinstance(world.get("block_size"), (int, float))
            or world["block_size"] <= 0
        ):
            raise ValueError("world.json has an unsupported or invalid format")

    def _handle_message(self, client, message):
        if not isinstance(message, dict):
            return

        if message.get("type") == "attack":
            attack_type = message.get("attack")
            origin = message.get("origin")
            direction = message.get("direction")
            if (
                attack_type
                not in ("sob", "moai", "knockback", "fire", "bomb", "ice", "comet")
                or not self._valid_vector(origin)
                or not self._valid_vector(direction)
            ):
                return
            if attack_type == "comet":
                with self._lock:
                    if self._comet_used:
                        accepted = False
                    else:
                        self._comet_used = True
                        accepted = True
                if not accepted:
                    client.send({"type": "comet_unavailable"})
                    return
            self._broadcast(
                {
                    "type": "attack",
                    "id": client.player_id,
                    "attack": attack_type,
                    "origin": origin,
                    "direction": direction,
                },
                exclude=client.player_id,
            )
            if attack_type == "sob":
                with self._lock:
                    self._flood_expires_at = time.time() + 3
                self._broadcast(
                    {
                        "type": "flood_start",
                        "remaining": 3,
                    }
                )
            if attack_type == "comet":
                self._broadcast({"type": "match_end", "reason": "comet_used"})
                self._shutdown()
            return

        if message.get("type") == "player_hit":
            target_id = message.get("target_id")
            attack_type = message.get("attack")
            direction = message.get("direction")
            if (
                not isinstance(target_id, str)
                or target_id == client.player_id
                or attack_type
                not in ("moai", "knockback", "fire", "bomb", "ice")
                or not self._valid_vector(direction)
            ):
                return
            with self._lock:
                if target_id not in self._clients:
                    return
            self._broadcast(
                {
                    "type": "player_hit",
                    "source_id": client.player_id,
                    "target_id": target_id,
                    "attack": attack_type,
                    "direction": direction,
                }
            )
            return

        if message.get("type") == "comet_strike":
            with self._lock:
                if self._comet_used:
                    accepted = False
                else:
                    self._comet_used = True
                    accepted = True
            if accepted:
                self._broadcast({"type": "comet_strike", "source_id": client.player_id})
            else:
                client.send({"type": "comet_unavailable"})
            return

        if message.get("type") == "death":
            print(f"Player {client.player_id} died")
            return

        if message.get("type") == "chest_opened":
            chest_id = message.get("chest_id")
            if not isinstance(chest_id, int):
                return
            with self._lock:
                self._opened_chests[chest_id] = time.time()
            self._broadcast(
                {
                    "type": "chest_opened",
                    "chest_id": chest_id,
                    "player_id": client.player_id,
                },
                exclude=client.player_id,
            )
            return

        if message.get("type") != "position":
            return

        position = message.get("position")
        rotation_y = message.get("rotation_y")
        if (
            not self._valid_vector(position)
            or not isinstance(rotation_y, (int, float))
            or not math.isfinite(rotation_y)
        ):
            return

        client.position = position
        client.rotation_y = rotation_y
        self._broadcast(
            {
                "type": "player_update",
                "id": client.player_id,
                "position": position,
                "rotation_y": rotation_y,
            },
            exclude=client.player_id,
        )

    @staticmethod
    def _valid_vector(value):
        return (
            isinstance(value, list)
            and len(value) == 3
            and all(
                isinstance(component, (int, float)) and math.isfinite(component)
                for component in value
            )
        )

    def _broadcast(self, message, exclude=None):
        with self._lock:
            clients = [
                client
                for player_id, client in self._clients.items()
                if player_id != exclude
            ]
        for client in clients:
            try:
                client.send(message)
            except OSError:
                pass

    def _shutdown(self):
        self._beacon_stop.set()
        self._server.shutdown()

    def serve_forever(self):
        print(
            f"Hosting {self.world_path} on {self.host}:{self.port}. "
            "Press Ctrl+C to stop."
        )
        try:
            self._server.serve_forever()
        except KeyboardInterrupt:
            print("\nStopping host server.")
        finally:
            self._beacon_stop.set()
            self._server.server_close()


def find_match(timeout=0.6):
    """Finds an active match via LAN broadcast beacon or localhost probe."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.settimeout(timeout)
        sock.sendto(b"EMOJI_MATCH_PING", ("<broadcast>", 27015))
        try:
            data, addr = sock.recvfrom(256)
            if data.startswith(b"EMOJI_MATCH_PONG"):
                parts = data.decode("utf-8").split(":")
                port = int(parts[1]) if len(parts) > 1 else DEFAULT_PORT
                sock.close()
                return addr[0], port
        except socket.timeout:
            pass
        sock.close()
    except OSError:
        pass

    try:
        sock = socket.create_connection(("127.0.0.1", DEFAULT_PORT), timeout=0.25)
        sock.close()
        return "127.0.0.1", DEFAULT_PORT
    except OSError:
        pass

    return None


class WorldClient:
    """Connects a game client to HostServer and queues received events."""

    def __init__(self, host="127.0.0.1", port=DEFAULT_PORT, timeout=5):
        self.host = host
        self.port = port
        self.events = Queue()
        self._send_lock = threading.Lock()
        self._socket = socket.create_connection((host, port), timeout=timeout)
        self._socket_file = self._socket.makefile("rwb")
        self.connected = True
        self._send({"type": "join"})
        response = self._read_message()
        if response.get("type") != "welcome":
            self.close()
            raise ConnectionError(response.get("message", "Host rejected the connection"))

        self.player_id = response["id"]
        self.world = response["world"]
        self.flood_remaining = response.get("flood_remaining", 0)
        self.comet_available = response.get("comet_available", True)
        self.comet_struck = response.get("comet_struck", False)
        self.opened_chests = response.get("opened_chests", [])
        self.events.put({"type": "initial_players", "players": response["players"]})
        self._socket.settimeout(None)
        self._receiver = threading.Thread(target=self._receive_loop, daemon=True)
        self._receiver.start()

    def _send(self, message):
        data = (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")
        with self._send_lock:
            self._socket_file.write(data)
            self._socket_file.flush()

    def _read_message(self):
        line = self._socket_file.readline()
        if not line:
            raise ConnectionError("Host closed the connection")
        message = json.loads(line.decode("utf-8"))
        if not isinstance(message, dict):
            raise ConnectionError("Host sent an invalid message")
        return message

    def _receive_loop(self):
        try:
            while True:
                self.events.put(self._read_message())
        except (
            OSError,
            UnicodeDecodeError,
            json.JSONDecodeError,
            ConnectionError,
            ValueError,
        ) as error:
            self.connected = False
            self.events.put({"type": "disconnected", "message": str(error)})

    def send_position(self, position, rotation_y):
        if not self.connected:
            return
        try:
            self._send(
                {
                    "type": "position",
                    "position": [float(value) for value in position],
                    "rotation_y": float(rotation_y),
                }
            )
        except OSError as error:
            self.connected = False
            self.events.put({"type": "disconnected", "message": str(error)})

    def send_attack(self, attack_type, origin, direction):
        if not self.connected:
            return
        try:
            self._send(
                {
                    "type": "attack",
                    "attack": attack_type,
                    "origin": [float(value) for value in origin],
                    "direction": [float(value) for value in direction],
                }
            )
        except OSError as error:
            self.connected = False
            self.events.put({"type": "disconnected", "message": str(error)})

    def send_hit(self, target_id, attack_type, direction):
        if not self.connected:
            return
        try:
            self._send(
                {
                    "type": "player_hit",
                    "target_id": target_id,
                    "attack": attack_type,
                    "direction": [float(value) for value in direction],
                }
            )
        except OSError as error:
            self.connected = False
            self.events.put({"type": "disconnected", "message": str(error)})

    def send_comet_strike(self):
        if not self.connected:
            return
        try:
            self._send({"type": "comet_strike"})
        except OSError as error:
            self.connected = False
            self.events.put({"type": "disconnected", "message": str(error)})

    def send_death(self):
        if not self.connected:
            return
        try:
            self._send({"type": "death"})
        except OSError as error:
            self.connected = False
            self.events.put({"type": "disconnected", "message": str(error)})

    def send_chest_opened(self, chest_id):
        if not self.connected:
            return
        try:
            self._send({"type": "chest_opened", "chest_id": int(chest_id)})
        except OSError as error:
            self.connected = False
            self.events.put({"type": "disconnected", "message": str(error)})

    def poll(self):
        messages = []
        while True:
            try:
                messages.append(self.events.get_nowait())
            except Empty:
                return messages

    def close(self):
        self.connected = False
        try:
            self._socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._socket_file.close()
        finally:
            self._socket.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Host world.json for multiplayer")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--world", default=None, help="Path to world.json")
    args = parser.parse_args()
    HostServer(host=args.host, port=args.port, world_path=args.world).serve_forever()

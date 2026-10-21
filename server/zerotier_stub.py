"""Stands in for the iOS ZeroTier plugin (project/ios/plugins/pokewilds_zerotier)
so the game's side of it runs on a PC: the same control connection and calls,
with the ZeroTier network replaced by plain loopback forwarding and the lobby
directory by a list in memory. Runs server/zerotier_bridge_test.gd against it.

    python server/zerotier_stub.py GODOT            (GODOT = editor binary, runs project/)

Run from the repository root. Exits 0 on success."""
import json, os, re, secrets, socket, struct, subprocess, sys, threading, time

ADDRESS = "fd80:56c2:e21c:0:199:93aa:aaaa:1"  # this node's made-up ZeroTier address


class Stub:
    def __init__(self):
        self.token = secrets.token_hex(16)
        self.control = socket.create_server(("127.0.0.1", 0))
        self.port = self.control.getsockname()[1]
        self.started_at = None
        self.host = None  # [generation, ZeroTier port, local game port]
        self.join = 0
        self.http = {}
        self.http_ids = 0
        self.lobbies = {}
        self.calls = []
        self.lock = threading.Lock()
        threading.Thread(target=self.serve, daemon=True).start()

    def env(self):
        return f"{self.port} {self.token}"

    def serve(self):
        while True:
            client, _ = self.control.accept()
            threading.Thread(target=self.client, args=(client,), daemon=True).start()

    def client(self, client):
        def read(size):
            data = b""
            while len(data) < size:
                part = client.recv(size - len(data))
                if not part: raise ConnectionError
                data += part
            return data
        try:
            while True:
                fields = read(struct.unpack("<I", read(4))[0]).decode().split("\t")
                if fields[0] != self.token: break
                answer = self.call(fields[1:]).encode()
                client.sendall(struct.pack("<I", len(answer)) + answer)
        except (ConnectionError, OSError):
            pass
        client.close()

    def call(self, f):
        self.calls.append(f[0])
        if f[0] == "start":
            if self.started_at is None: self.started_at = time.time()
            return ""
        if f[0] == "status":
            if self.started_at is None: return "stopped\t\t"
            # Joining for a moment, as a real node does.
            return "ready\t%s\t" % ADDRESS if time.time() - self.started_at > 0.3 else "joining\t\t"
        if f[0] == "hostOpen":
            self.host = [self.host[0] + 1 if self.host else 1, int(f[1]), int(f[2])]
            return "1"
        if f[0] == "hostClose":
            if self.host: self.host = [self.host[0] + 1, 0, 0]
            return ""
        if f[0] == "connectOpen":
            self.join += 1
            listener = socket.create_server(("127.0.0.1", 0))
            threading.Thread(target=self.guest, args=(listener, self.join, f[1], int(f[2])), daemon=True).start()
            return str(listener.getsockname()[1])
        if f[0] == "connectClose":
            self.join += 1
            return ""
        if f[0] == "httpStart":
            with self.lock:
                self.http_ids += 1
                id = self.http_ids
                body = f[2] if len(f) > 2 else ""
                if body:
                    record = json.loads(body)
                    self.lobbies[record["key"]] = record
                    self.http[id] = "200\n{}"
                else:
                    self.http[id] = "200\n" + json.dumps({"lobbies": list(self.lobbies.values())})
            return str(id)
        if f[0] == "httpTake":
            with self.lock: return self.http.pop(int(f[1]), "")
        return ""

    def guest(self, listener, generation, address, port):
        """A connection to the loopback port reaches the host's game server."""
        listener.settimeout(0.5)
        while self.join == generation:
            try: local, _ = listener.accept()
            except socket.timeout: continue
            host = self.host
            if address != ADDRESS or not host or host[1] != port:
                local.close(); continue
            remote = socket.create_connection(("127.0.0.1", host[2]))
            for a, b in ((local, remote), (remote, local)):
                threading.Thread(target=self.pipe, args=(a, b), daemon=True).start()
        listener.close()

    @staticmethod
    def pipe(a, b):
        try:
            while data := a.recv(65536): b.sendall(data)
        except OSError:
            pass
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass


def run(command):
    """Runs the bridge test against a fresh stub; returns (ok, output)."""
    stub = Stub()
    test = os.path.abspath(os.path.join(os.path.dirname(__file__), "zerotier_bridge_test.gd"))
    result = subprocess.run(command + ["--headless", "-s", test], capture_output=True, text=True, errors="replace",
        timeout=300, env=dict(os.environ, POKEWILDS_ZEROTIER=stub.env()))
    found = re.search(r"ZEROTIER BRIDGE TEST: (\d+) checks, (\d+) failed", result.stdout)
    return bool(found and found.group(2) == "0"), result.stdout + result.stderr


if __name__ == "__main__":
    ok, output = run([sys.argv[1], "--path", "project"])
    print(output[-4000:])
    sys.exit(0 if ok else 1)

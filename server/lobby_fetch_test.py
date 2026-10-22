"""JOIN A GAME's online list over a 4G-like link: serves the lobby directory
locally (node), lists a dedicated server in it, puts server/netem_proxy.py in
front with 300 ms round trips and the first connection reset, and runs
server/lobby_fetch_test.gd through it twice: with Godot's HTTPRequest and
through the phone bridge's calls.

    python server/lobby_fetch_test.py GODOT [--budget SECONDS] [--stall]

--budget: seconds the first list may take (default 6). --stall: the first
connection goes silent instead of being reset (a link that died), which costs
one request timeout: use a larger budget. Run from the repository root with
node on the PATH. Exits 0 on success."""
import asyncio, json, os, socket, subprocess, sys, tempfile, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netem_proxy import PROFILES, Proxy

godot = sys.argv[1]
budget = sys.argv[sys.argv.index("--budget") + 1] if "--budget" in sys.argv else "6"
stall = "--stall" in sys.argv
test = os.path.abspath(os.path.join(os.path.dirname(__file__), "lobby_fetch_test.gd"))
work = tempfile.mkdtemp(prefix="pw-lobby-fetch-")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]


class Dropping(Proxy):
    """Loses the first `drop` connections, as a phone network can: reset at once, or silent."""
    def __init__(self, port, target_port, drop, silent=False):
        super().__init__(port, "127.0.0.1", target_port, dict(PROFILES["4g"], delay=150))
        self.drop, self.silent, self.connections = drop, silent, 0

    async def _client(self, c_reader, c_writer):
        self.connections += 1
        if self.connections <= self.drop:
            if self.silent: await asyncio.sleep(60)
            c_writer.transport.abort(); return
        await super()._client(c_reader, c_writer)


lobby_port = free_port()
directory = f"http://127.0.0.1:{lobby_port}"
node = subprocess.Popen(["node", "lobby-directory/test/local_server.mjs", str(lobby_port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
failed = False
try:
    node.stdout.readline()
    # The directory stays reachable for the test, but answers nothing: every connection is reset.
    dead = free_port(); Dropping(dead, lobby_port, 10 ** 9).start()
    for mode in ["desktop", "native"]:
        # Listed afresh for each run: an entry lasts 75 s.
        record = {"key": "ab" * 16, "address": "203.0.113.7", "name": "4G TEST", "kind": "server", "players": 0, "max": 4, "version": "0.10.245"}
        urllib.request.urlopen(urllib.request.Request(directory + "/v1/lobbies", json.dumps(record).encode(), {"Content-Type": "application/json"})).read()
        proxy_port = free_port(); Dropping(proxy_port, lobby_port, 1, stall).start()
        data = os.path.join(work, mode); os.makedirs(data)
        try:
            result = subprocess.run([godot, "--path", "project", "--headless", "-s", test, "--",
                f"http://127.0.0.1:{proxy_port}", mode, f"http://127.0.0.1:{dead}", budget, data],
                capture_output=True, timeout=180)
            output, failed = (result.stdout + result.stderr).decode(errors="replace"), failed or result.returncode != 0
        except subprocess.TimeoutExpired as hung:
            output, failed = (hung.stdout or b"").decode(errors="replace") + "\nLOBBY FETCH: timed out", True
        print("\n".join(line for line in output.splitlines() if "LOBBY FETCH" in line or "ERROR" in line))
finally:
    node.kill()
print("LOBBY FETCH:", "FAIL" if failed else "OK")
sys.exit(1 if failed else 0)

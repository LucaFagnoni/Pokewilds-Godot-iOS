"""A TCP proxy that makes a link look like a phone on 4G: one-way delay with
jitter, a bandwidth limit each way, a bounded queue (bufferbloat), and now and
then a stall (a lost packet being sent again). Bytes keep their order.

    python server/netem_proxy.py LISTEN_PORT TARGET_HOST:TARGET_PORT [--profile 4g|bad4g|lan]

Also used in-process by coop_latency_probe.py: Proxy(...).start() in a thread."""
import asyncio, random, socket, sys, threading, time

PROFILES = {
    # one-way ms, jitter +-ms, up kbit/s (client -> server), down kbit/s, stall chance per chunk, stall ms
    "lan": dict(delay=0, jitter=0, up=0, down=0, stall=0.0, stall_ms=0),
    "4g": dict(delay=65, jitter=20, up=1500, down=8000, stall=0.01, stall_ms=250),
    "bad4g": dict(delay=90, jitter=40, up=600, down=3000, stall=0.03, stall_ms=600),
}
CHUNK = 1400  # about one TCP segment: delay and bandwidth apply per segment
QUEUE_BYTES = 192 * 1024  # what the radio link buffers before the sender is held back


class Pipe:
    def __init__(self, reader, writer, kbits, profile, rng):
        self.reader, self.writer, self.kbits, self.p, self.rng = reader, writer, kbits, profile, rng
        self.queue, self.queued, self.link_free, self.last = asyncio.Queue(), 0, 0.0, 0.0
        self.bytes = 0
        self.room = asyncio.Event(); self.room.set()

    async def pump_in(self):
        try:
            while True:
                data = await self.reader.read(CHUNK)
                if not data: break
                now = time.monotonic()
                # Serialisation on the limited link, then propagation delay with jitter.
                self.link_free = max(self.link_free, now) + (len(data) * 8 / (self.kbits * 1000) if self.kbits else 0)
                delay = (self.p["delay"] + self.rng.uniform(-self.p["jitter"], self.p["jitter"])) / 1000
                if self.p["stall"] and self.rng.random() < self.p["stall"]: delay += self.p["stall_ms"] / 1000
                # A later segment never overtakes an earlier one (TCP delivers in order).
                self.last = max(self.last, self.link_free + max(0.0, delay))
                self.queued += len(data)
                await self.queue.put((self.last, data))
                if self.queued > QUEUE_BYTES:
                    self.room.clear(); await self.room.wait()
        except (ConnectionError, OSError): pass
        await self.queue.put((0, None))

    async def pump_out(self):
        try:
            while True:
                due, data = await self.queue.get()
                if data is None: break
                wait = due - time.monotonic()
                if wait > 0: await asyncio.sleep(wait)
                self.writer.write(data)
                await self.writer.drain()
                self.bytes += len(data); self.queued -= len(data)
                if self.queued <= QUEUE_BYTES: self.room.set()
        except (ConnectionError, OSError): pass
        try: self.writer.close()
        except Exception: pass


class Proxy:
    def __init__(self, listen_port, target_host, target_port, profile="4g", seed=1):
        self.listen_port, self.target = listen_port, (target_host, target_port)
        self.profile = dict(PROFILES[profile]) if isinstance(profile, str) else dict(profile)
        self.rng = random.Random(seed)
        self.loop = None
        self.ready = threading.Event()

    async def _client(self, c_reader, c_writer):
        try: s_reader, s_writer = await asyncio.open_connection(*self.target)
        except OSError: c_writer.close(); return
        for writer in (c_writer, s_writer):
            sock = writer.get_extra_info("socket")
            if sock is not None: sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        up = Pipe(c_reader, s_writer, self.profile["up"], self.profile, self.rng)
        down = Pipe(s_reader, c_writer, self.profile["down"], self.profile, self.rng)
        await asyncio.gather(up.pump_in(), up.pump_out(), down.pump_in(), down.pump_out())

    async def _main(self):
        server = await asyncio.start_server(self._client, "127.0.0.1", self.listen_port)
        self.ready.set()
        async with server: await server.serve_forever()

    def run(self):
        self.loop = asyncio.new_event_loop()
        self.loop.run_until_complete(self._main())

    def start(self):
        threading.Thread(target=self.run, daemon=True).start()
        self.ready.wait(10)
        return self


if __name__ == "__main__":
    args = sys.argv[1:]
    profile = args[args.index("--profile") + 1] if "--profile" in args else "4g"
    host, port = args[1].rsplit(":", 1)
    print(f"netem proxy 127.0.0.1:{args[0]} -> {host}:{port} profile {profile} {PROFILES[profile]}")
    Proxy(int(args[0]), host, int(port), profile).run()

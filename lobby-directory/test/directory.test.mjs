import assert from "node:assert/strict";
import { Directory, TTL_MS, MAX_PER_ADDRESS, MAX_PLAYERS } from "../src/directory.js";
let clock = 1000;
const d = new Directory(() => clock);
const key = (n) => String(n).padStart(32, "0");
const post = (n, extra = {}, client = "1.1.1.1") => d.handle("POST", "/v1/lobbies",
    JSON.stringify({ key: key(n), address: "fce3:d51b:d59d:9e6a:6790::1", name: "World " + n, host: "RED", players: 1, max: 4, ...extra }), client);
const list = async () => (await d.handle("GET", "/v1/lobbies", "", "")).body.lobbies;

assert.equal((await post(1)).status, 200);
let all = await list();
assert.equal(all.length, 1);
assert.equal(all[0].name, "World 1");
assert.ok(!("key" in all[0]) && !("client" in all[0]) && !("seen" in all[0]), "secrets stay private");
assert.equal((await post(1, { players: 3 })).status, 200);
assert.equal((await list())[0].players, 3, "re-announce updates in place");
assert.equal((await post(2, { players: 9, private: true, name: "x".repeat(99) })).status, 200);
all = await list();
assert.equal(all[1].players, 4); assert.equal(all[1].private, true); assert.equal(all[1].name.length, 24);
assert.equal((await d.handle("DELETE", "/v1/lobbies", JSON.stringify({ key: key(9) }), "")).status, 200);
assert.equal((await list()).length, 2, "a wrong key removes nothing");
assert.equal((await d.handle("DELETE", "/v1/lobbies", JSON.stringify({ key: key(2) }), "")).status, 200);
assert.equal((await list()).length, 1);
assert.equal((await post(1, { remove: true })).status, 200);
assert.equal((await list()).length, 0, "a host can remove its lobby with POST");
assert.equal((await post(1)).status, 200);
assert.equal((await post(3, { address: "not an address!" })).status, 400);
assert.equal((await d.handle("POST", "/v1/lobbies", "{", "")).status, 400);
assert.equal((await d.handle("POST", "/v1/lobbies", JSON.stringify({ key: "short" }), "")).status, 400);
for (let n = 10; n < 10 + MAX_PER_ADDRESS; n++) await post(n, {}, "2.2.2.2");
assert.equal((await post(99, {}, "2.2.2.2")).status, 429, "one address cannot flood the list");
// What the worker stores must be enough to rebuild the list after a restart.
const stored = new Map();
const d2 = new Directory(() => clock);
const apply = (r) => { if (r.saved) stored.set(r.saved.id, r.saved); for (const id of r.removed) stored.delete(id); };
const post2 = (n) => d2.handle("POST", "/v1/lobbies", JSON.stringify({ key: key(n), address: "fce4::1", name: "Kept " + n }), "3.3.3.3");
apply(await post2(1)); apply(await post2(2));
apply(await d2.handle("DELETE", "/v1/lobbies", JSON.stringify({ key: key(2) }), ""));
const restarted = new Directory(() => clock);
for (const [id, lobby] of stored) restarted.lobbies.set(id, lobby);
const kept = (await restarted.handle("GET", "/v1/lobbies", "", "")).body.lobbies;
assert.deepEqual(kept.map((l) => l.name), ["Kept 1"], "the list survives a restart");
clock += TTL_MS + 1;
const expiry = await restarted.handle("GET", "/v1/lobbies", "", "");
assert.equal(expiry.body.lobbies.length, 0); assert.equal(expiry.removed.length, 1, "expired lobbies are cleared from storage");
assert.equal((await list()).length, 0, "silent lobbies expire");

// Dedicated servers: their own kind, reached directly on their port, listed
// only for builds that ask for them.
{
    const d3 = new Directory(() => clock);
    const announce = (n, extra, client = "5.6.7.8") => d3.handle("POST", "/v1/lobbies", JSON.stringify({ key: key(n), name: "S" + n, ...extra }), client);
    const listed = async (query = "") => (await d3.handle("GET", "/v1/lobbies" + query, "", "")).body.lobbies;
    assert.equal((await announce(1, { kind: "server", address: "auto", port: 60000, players: 0, max: 8, version: "1.2.3",
        compat: "ab".repeat(20), accounts: true })).status, 200);
    let [server] = await listed("?servers=1");
    assert.equal(server.address, "5.6.7.8", "auto takes the caller's address");
    assert.equal(server.kind, "server"); assert.equal(server.port, 60000); assert.equal(server.players, 0);
    assert.equal(server.max, 8); assert.equal(server.version, "1.2.3"); assert.equal(server.compat, "ab".repeat(20)); assert.equal(server.accounts, true);
    assert.equal((await listed()).length, 0, "older builds are not shown servers");
    assert.equal((await announce(1, { kind: "server", address: "auto" }, "::ffff:9.9.9.9")).status, 200);
    assert.equal((await listed("?servers=1"))[0].address, "9.9.9.9", "an IPv4 caller seen over IPv6 is listed as IPv4");
    assert.equal((await announce(2, { kind: "server", address: "auto" }, "")).status, 400, "auto needs a caller address");
    assert.equal((await announce(3, { kind: "server", address: "evil.example" })).status, 400, "explicit addresses are still checked");
    assert.equal((await announce(4, { kind: "server", address: "1.2.3.4", max: 99, players: 50, port: 0, compat: "not hex", version: "v".repeat(40) })).status, 200);
    server = (await listed("?servers=1")).find((l) => l.name === "S4");
    assert.equal(server.max, MAX_PLAYERS); assert.equal(server.players, MAX_PLAYERS); assert.equal(server.port, 1);
    assert.equal(server.compat, ""); assert.equal(server.version.length, 24);
    // A phone host from before this change: no kind, port or version.
    assert.equal((await announce(5, { address: "fce3::5", players: 0, max: 4 })).status, 200);
    const old = (await listed()).find((l) => l.name === "S5");
    assert.equal(old.kind, "game"); assert.equal(old.port, 54555); assert.equal(old.players, 1); assert.equal(old.max, 4);
    assert.equal((await announce(6, { address: "fce3::6", max: 8, players: 6 })).status, 200);
    assert.equal((await listed()).find((l) => l.name === "S6").players, 6, "games of more than 4 players");
    // Records stored by the previous version (no kind) are still listed after an upgrade.
    d3.lobbies.set("old", { id: "old", address: "fce3::7", name: "Stored", players: 1, max: 4, seen: clock, client: "" });
    assert.ok((await listed()).some((l) => l.name === "Stored"));
    assert.equal((await announce(1, { remove: true })).status, 200);
    assert.ok(!(await listed("?servers=1")).some((l) => l.name === "S1"), "a server removes itself");
}
console.log("directory tests passed");

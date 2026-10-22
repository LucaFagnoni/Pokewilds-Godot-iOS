// Embedded ZeroTier node (libzt) for ONLINE play on iPhone: the iOS twin of
// android/build/src/main/java/com/godot/game/PokeWildsZeroTier.java, with the
// same calls, answers and behaviour, so scripts/coop_network.gd treats both
// alike. Read that file for the why of each step; this one only notes where
// iOS differs.
//
// The game's own transport keeps using ordinary TCP sockets. This only carries
// those bytes across the ZeroTier ad-hoc network through loopback:
//   host:  ZeroTier listener  -> 127.0.0.1:<game port>
//   guest: 127.0.0.1:<random> -> ZeroTier connection to the host
//
// GDScript cannot call native code without Godot's headers, so the calls go
// over a loopback control connection that this plugin announces in the
// process environment, like pokewilds_battery does its value:
//   POKEWILDS_ZEROTIER="<port> <token>"
// A request is "<token>\t<call>\t<argument>..." and an answer a string, both
// framed like StreamPeer.put_utf8_string (u32 little-endian length, then the
// UTF-8 bytes); scripts/coop_zerotier_ios.gd is the other end. Other apps on
// the phone share the loopback; without the token they are cut off.
//
// CI builds libpokewilds_zerotier.a from this file and libzt
// (tools/build_libzt_ios.sh); Godot's export links it and calls the two
// functions named in the .gdip.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "ZeroTierSockets.h"

static const int ONLINE_TIMEOUT_MS = 60000;
static const int NETWORK_TIMEOUT_MS = 90000;
static const int CONNECT_TIMEOUT_MS = 15000;
static const int PACE_BYTES = 4096;

// State strings, lobby key and HTTP results.
static std::mutex lock;
// libzt reports errors through one global value shared by all threads, so
// socket calls from different threads must not overlap or they read each
// other's results. Every such call here is non-blocking and takes this lock.
static std::mutex zt;
static std::string state = "stopped", address, message;
static std::atomic<uint64_t> network_id{ 0 };
static std::atomic<bool> ready{ false }, started{ false };
static std::atomic<int> host_generation{ 0 }, join_generation{ 0 };

typedef std::function<bool()> Live;

static long long now_ms() {
	return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static void sleep_ms(int ms) {
	std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

static std::string current_state() {
	std::lock_guard<std::mutex> guard(lock);
	return state;
}

static void fail(const std::string &reason) {
	std::lock_guard<std::mutex> guard(lock);
	ready = false;
	message = reason;
	state = "error";
	NSLog(@"PokeWildsZeroTier: %s", reason.c_str());
}

// -1 means "see zts_errno"; when another thread cleared it in between, say
// "try again" (a real error repeats). Below -1 the node itself failed.
static ssize_t zt_result(ssize_t result) {
	return result >= 0 || result < -1 ? result : -(zts_errno ? zts_errno : ZTS_EAGAIN);
}

static ssize_t zt_read(int fd, void *buffer, size_t size) {
	std::lock_guard<std::mutex> guard(zt);
	return zt_result(zts_bsd_read(fd, buffer, size));
}

static ssize_t zt_write(int fd, const void *data, size_t size) {
	std::lock_guard<std::mutex> guard(zt);
	return zt_result(zts_bsd_write(fd, data, size));
}

static int zt_socket() {
	std::lock_guard<std::mutex> guard(zt);
	return zts_bsd_socket(ZTS_AF_INET6, ZTS_SOCK_STREAM, 0);
}

static void zt_close(int fd) {
	std::lock_guard<std::mutex> guard(zt);
	zts_bsd_close(fd);
}

// ------------------------------------------------------------------- node

static void on_event(void *data) {
	int code = ((zts_event_msg_t *)data)->event_code;
	if (code == ZTS_EVENT_NETWORK_NOT_FOUND) fail("The multiplayer network was not found.");
	else if (code == ZTS_EVENT_NETWORK_ACCESS_DENIED) fail("The multiplayer network refused this device.");
	else if (code == ZTS_EVENT_NETWORK_CLIENT_TOO_OLD) fail("This game version is too old for the multiplayer network.");
	else if (code == ZTS_EVENT_NODE_FATAL_ERROR) fail("ZeroTier identity error. Reinstalling resets it.");
}

static bool await_up(int timeout_ms, bool network) {
	long long deadline = now_ms() + timeout_ms;
	while (now_ms() < deadline) {
		if (current_state() == "error") return false;
		if (network) {
			if (zts_net_transport_is_ready(network_id) == 1 && zts_addr_is_assigned(network_id, ZTS_AF_INET6) == 1) return true;
		} else if (zts_node_is_online() == 1) {
			return true;
		}
		sleep_ms(100);
	}
	return false;
}

static void bring_up(const std::string &storage, uint64_t id) {
	BOOL folder = NO;
	[NSFileManager.defaultManager createDirectoryAtPath:@(storage.c_str()) withIntermediateDirectories:YES attributes:nil error:nil];
	if (![NSFileManager.defaultManager fileExistsAtPath:@(storage.c_str()) isDirectory:&folder] || !folder) {
		fail("ZeroTier storage could not be created.");
		return;
	}
	zts_init_from_storage(storage.c_str());
	zts_init_set_event_handler(on_event);
	int error = zts_node_start();
	if (error != ZTS_ERR_OK) {
		fail("ZeroTier could not start (" + std::to_string(error) + ").");
		return;
	}
	if (!await_up(ONLINE_TIMEOUT_MS, false)) {
		fail("Could not reach ZeroTier. Check the internet connection.");
		return;
	}
	{
		std::lock_guard<std::mutex> guard(lock);
		state = "joining";
	}
	zts_net_join(id);
	if (!await_up(NETWORK_TIMEOUT_MS, true)) {
		if (current_state() != "error") fail("The multiplayer network did not respond.");
		return;
	}
	char assigned[ZTS_IP_MAX_STR_LEN] = { 0 };
	if (zts_addr_get_str(id, ZTS_AF_INET6, assigned, ZTS_IP_MAX_STR_LEN) != ZTS_ERR_OK || !assigned[0]) {
		fail("The multiplayer network did not assign an address.");
		return;
	}
	std::lock_guard<std::mutex> guard(lock);
	address = assigned;
	message = "";
	state = "ready";
	ready = true;
}

// Starts the node once and joins the ad-hoc network that allows only
// game_port. Every copy using the same port lands on the same network.
static std::string start(const std::string &storage, int game_port) {
	if (game_port <= 0 || game_port > 65535) {
		fail("Invalid multiplayer port.");
		return "Invalid multiplayer port.";
	}
	if (started.exchange(true)) return "";
	// ffSSSSEEEE000000: controller-less network, destination ports SSSS..EEEE.
	uint64_t id = 0xff00000000000000ULL | ((uint64_t)game_port << 40) | ((uint64_t)game_port << 24);
	network_id = id;
	{
		std::lock_guard<std::mutex> guard(lock);
		state = "starting";
		message = "";
	}
	std::thread(bring_up, storage, id).detach();
	return "";
}

// "state\taddress\tmessage"; state is stopped, starting, joining, ready or error.
static std::string status() {
	std::string answer, note;
	{
		std::lock_guard<std::mutex> guard(lock);
		answer = state + "\t" + address + "\t";
		note = message;
	}
	// Asked live, of the game's own network (see the Java bridge).
	if (ready && note.empty() && zts_net_transport_is_ready(network_id) != 1) note = "Reconnecting...";
	return answer + note;
}

static bool await_ready(const Live &live) {
	while (live() && !ready) {
		if (current_state() == "error") return false;
		sleep_ms(100);
	}
	return live();
}

// ------------------------------------------------------------- loopback

static void tune_local(int fd) {
	int on = 1;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
	// Writing to a closed socket must fail, not kill the app with SIGPIPE.
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
}

static sockaddr_in loopback(int port) {
	sockaddr_in where = {};
	where.sin_len = sizeof(where);
	where.sin_family = AF_INET;
	where.sin_port = htons(port);
	where.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	return where;
}

// A listening socket on 127.0.0.1 and a free port; -1 on failure.
static int loopback_listen(int backlog, int *port) {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) return -1;
	sockaddr_in where = loopback(0);
	socklen_t size = sizeof(where);
	if (bind(fd, (sockaddr *)&where, sizeof(where)) != 0 || listen(fd, backlog) != 0 || getsockname(fd, (sockaddr *)&where, &size) != 0) {
		close(fd);
		return -1;
	}
	*port = ntohs(where.sin_port);
	return fd;
}

static int loopback_connect(int port) {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) return -1;
	tune_local(fd);
	sockaddr_in where = loopback(port);
	if (connect(fd, (sockaddr *)&where, sizeof(where)) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

// ---------------------------------------------------------------- link

static bool write_remote(int remote, const char *data, ssize_t count) {
	long long deadline = now_ms() + 20000;
	while (count > 0) {
		ssize_t written = zt_write(remote, data, count);
		if (written > 0) {
			data += written;
			count -= written;
		} else if (written == 0 || written == -ZTS_EAGAIN) {
			if (now_ms() > deadline) return false;
			sleep_ms(1);
		} else {
			return false;
		}
	}
	return true;
}

// The local side is non-blocking; a game that does not read (busy, or the app
// in the background) holds the link here, as Java's blocking write does.
static bool write_local(int local, const char *data, ssize_t count, const Live &live) {
	while (count > 0) {
		ssize_t written = send(local, data, count, 0);
		if (written > 0) {
			data += written;
			count -= written;
		} else if (written < 0 && (errno == EAGAIN || errno == EINTR)) {
			if (!live()) return false;
			pollfd wait = { local, POLLOUT, 0 };
			poll(&wait, 1, 100);
		} else {
			return false;
		}
	}
	return true;
}

// One thread owns both ends, so a ZeroTier socket is never used from two
// threads at once. The ZeroTier side is non-blocking and the loop only pauses
// (for a millisecond, on the local socket) when neither direction has data.
static void forward(const char *role, int local, int remote, Live live) {
	std::thread([=] {
		const char *ended = "stopped";
		long long sent = 0, received = 0;
		fcntl(local, F_SETFL, fcntl(local, F_GETFL) | O_NONBLOCK);
		zts_set_no_delay(remote, 1);
		zts_set_blocking(remote, 0);
		std::vector<char> up(PACE_BYTES), down(32768);
		while (live()) {
			bool moved = false;
			ssize_t count = recv(local, up.data(), up.size(), 0);
			if (count == 0) { ended = "game closed its side"; break; }
			if (count < 0 && errno != EAGAIN && errno != EINTR) { ended = "local socket error"; break; }
			if (count > 0) {
				if (!write_remote(remote, up.data(), count)) { ended = "ZeroTier write failed"; break; }
				sent += count;
				moved = true;
				// Small steps with a 1 ms pause between them: a large message
				// enters ZeroTier over a few hundredths of a second instead of
				// in one burst, which the network layer otherwise drops parts of.
				if (count == PACE_BYTES) sleep_ms(1);
			}
			ssize_t got = zt_read(remote, down.data(), down.size());
			if (got > 0) {
				if (!write_local(local, down.data(), got, live)) { ended = "game socket closed"; break; }
				received += got;
				moved = true;
			} else if (got == 0) {
				ended = "other player closed the connection";
				break;
			} else if (got != -ZTS_EAGAIN) {
				ended = "ZeroTier read error";
				break;
			}
			if (!moved) {
				// Idle: wait up to 1 ms on the local socket, which also notices it closing.
				pollfd wait = { local, POLLIN, 0 };
				poll(&wait, 1, 1);
			}
		}
		NSLog(@"PokeWildsZeroTier %s: link ended (%s), sent %lld bytes, received %lld", role, ended, sent, received);
		close(local);
		zt_close(remote);
	}).detach();
}

// ---------------------------------------------------------------- host

// Accept ZeroTier connections on zt_port and forward each to the local game server.
static bool host_open(int zt_port, int local_port) {
	int generation = ++host_generation;
	std::thread([=] {
		Live live = [=] { return host_generation == generation; };
		if (!await_ready(live)) return;
		int listener = zt_socket();
		if (listener < 0) {
			NSLog(@"PokeWildsZeroTier: host socket failed %d", listener);
			return;
		}
		zts_set_reuse_addr(listener, 1);
		if (zts_bind(listener, "::", zt_port) < 0 || zts_listen(listener, 8) < 0) {
			NSLog(@"PokeWildsZeroTier: host bind failed");
			zt_close(listener);
			return;
		}
		zts_set_blocking(listener, 0);
		while (live()) {
			int accepted;
			{
				std::lock_guard<std::mutex> guard(zt);
				accepted = zts_bsd_accept(listener, nullptr, nullptr);
			}
			if (accepted < 0 || accepted == listener) {
				// Nobody is connecting right now (never treat the listener as a player).
				sleep_ms(25);
				continue;
			}
			int local = loopback_connect(local_port);
			if (local < 0) {
				NSLog(@"PokeWildsZeroTier host: game server on port %d refused the forwarded player", local_port);
				zt_close(accepted);
				continue;
			}
			NSLog(@"PokeWildsZeroTier host: player connected over ZeroTier");
			forward("host", local, accepted, live);
		}
		zt_close(listener);
	}).detach();
	return true;
}

// --------------------------------------------------------------- guest

// Opens a loopback port. A connection made to it is carried to
// remote_address:remote_port on the ZeroTier network. Returns the loopback
// port, or 0 on failure. The previous one stops: its thread closes its own
// listener within half a second, so a descriptor is never closed under it.
static int connect_open(const std::string &remote_address, int remote_port) {
	int generation = ++join_generation;
	int port = 0;
	int listener = loopback_listen(2, &port);
	if (listener < 0) {
		NSLog(@"PokeWildsZeroTier: loopback listener failed");
		return 0;
	}
	std::thread([=] {
		Live live = [=] { return join_generation == generation; };
		while (live()) {
			pollfd wait = { listener, POLLIN, 0 };
			if (poll(&wait, 1, 500) <= 0) continue;
			int local = accept(listener, nullptr, nullptr);
			if (local < 0) continue;
			tune_local(local);
			if (!await_ready(live)) {
				close(local);
				break;
			}
			NSLog(@"PokeWildsZeroTier join: connecting to %s port %d", remote_address.c_str(), remote_port);
			long long began = now_ms();
			int remote = zt_socket();
			if (remote < 0) {
				close(local);
				continue;
			}
			if (zts_connect(remote, remote_address.c_str(), remote_port, CONNECT_TIMEOUT_MS) < 0) {
				NSLog(@"PokeWildsZeroTier: ZeroTier connect failed");
				zt_close(remote);
				close(local);
				continue;
			}
			NSLog(@"PokeWildsZeroTier join: connected after %lld ms", now_ms() - began);
			forward("join", local, remote, live);
		}
		close(listener);
	}).detach();
	return port;
}

// ------------------------------------------------------ lobby directory

// The lobby list is fetched here rather than with Godot's HTTPRequest: Godot
// 4.7 leaks a /dev/urandom handle for every TLS connection it opens, and iOS
// gives an app only 256 descriptors.
static NSURLSession *http;
static std::map<int, std::string> http_results;
static std::atomic<int> http_ids{ 0 };
static std::string lobby_key;

// Starts a GET (empty body) or JSON POST. Returns an id for http_take().
static int http_start(const std::string &url, const std::string &body) {
	int id = ++http_ids;
	NSURL *where = [NSURL URLWithString:@(url.c_str())];
	if (!where) {
		std::lock_guard<std::mutex> guard(lock);
		http_results[id] = "0\n";
		return id;
	}
	// A phone network's first lookup and TLS handshake can take seconds (coop_lobby.gd REQUEST_TIMEOUT).
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:where cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
	NSURLSession *session;
	{
		std::lock_guard<std::mutex> guard(lock);
		if (!lobby_key.empty()) [request setValue:@(lobby_key.c_str()) forHTTPHeaderField:@"X-Lobby-Key"];
		session = http;
	}
	if (!body.empty()) {
		request.HTTPMethod = @"POST";
		[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
		request.HTTPBody = [NSData dataWithBytes:body.data() length:body.size()];
	}
	[[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		std::string result = "0\n";
		bool failed = error || ![response isKindOfClass:NSHTTPURLResponse.class];
		if (!failed) {
			result = std::to_string(((NSHTTPURLResponse *)response).statusCode) + "\n";
			if (data) result.append((const char *)data.bytes, MIN(data.length, (NSUInteger)262144));
		} else {
			NSLog(@"PokeWildsZeroTier: lobby directory request failed: %@", error);
		}
		std::lock_guard<std::mutex> guard(lock);
		// The session keeps one HTTP/2 connection to the directory. A mobile
		// network can drop it without a word while it idles, and every later
		// request would wait on it until it times out too: after a failure the
		// next request opens a new connection.
		if (failed && session == http) {
			[http finishTasksAndInvalidate];
			http = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
		}
		// Answers nobody took (a goodbye, a list the menu left) go once 64 newer requests started.
		http_results.erase(http_results.begin(), http_results.lower_bound(id - 63));
		http_results[id] = result;
	}] resume];
	return id;
}

// "" while pending, else "status\nbody" once; status 0 means it failed.
static std::string http_take(int id) {
	std::lock_guard<std::mutex> guard(lock);
	auto found = http_results.find(id);
	if (found == http_results.end()) return "";
	std::string result = found->second;
	http_results.erase(found);
	return result;
}

// ------------------------------------------------------------- control

static std::string token;
static int control = -1;

static std::string call(const std::vector<std::string> &fields) {
	auto text = [&](size_t i) { return i < fields.size() ? fields[i] : std::string(); };
	auto number = [&](size_t i) { return atoi(text(i).c_str()); };
	const std::string name = text(0);
	if (name == "start") return start(text(1), number(2));
	if (name == "status") return status();
	if (name == "hostOpen") return host_open(number(1), number(2)) ? "1" : "0";
	if (name == "hostClose") { ++host_generation; return ""; }
	if (name == "connectOpen") return std::to_string(connect_open(text(1), number(2)));
	if (name == "connectClose") { ++join_generation; return ""; }
	if (name == "httpStart") return std::to_string(http_start(text(1), text(2)));
	if (name == "httpTake") return http_take(number(1));
	if (name == "setLobbyKey") {
		std::lock_guard<std::mutex> guard(lock);
		lobby_key = text(1);
	}
	return "";
}

static bool read_all(int fd, void *buffer, size_t size) {
	char *at = (char *)buffer;
	while (size > 0) {
		ssize_t count = recv(fd, at, size, 0);
		if (count < 0 && errno == EINTR) continue;
		if (count <= 0) return false;
		at += count;
		size -= count;
	}
	return true;
}

static bool write_all(int fd, const std::string &data) {
	const char *at = data.data();
	size_t size = data.size();
	while (size > 0) {
		ssize_t count = send(fd, at, size, 0);
		if (count < 0 && errno == EINTR) continue;
		if (count <= 0) return false;
		at += count;
		size -= count;
	}
	return true;
}

static void announce(int port) {
	std::string value = std::to_string(port) + " " + token;
	// The game reads the environment on the main thread: write it there.
	if (NSThread.isMainThread) setenv("POKEWILDS_ZEROTIER", value.c_str(), 1);
	else dispatch_async(dispatch_get_main_queue(), ^{ setenv("POKEWILDS_ZEROTIER", value.c_str(), 1); });
}

static bool open_control() {
	int port = 0;
	control = loopback_listen(4, &port);
	if (control < 0) return false;
	announce(port);
	return true;
}

// One game connection at a time, one request at a time.
static void serve() {
	for (;;) {
		int client = control < 0 ? -1 : accept(control, nullptr, nullptr);
		if (client < 0) {
			if (control >= 0 && errno == EINTR) continue;
			// iOS can take a listening socket away while the app is suspended
			// (it then fails every call): open a new one; the game reads the
			// new port on its next call.
			if (control >= 0) close(control);
			control = -1;
			sleep_ms(200);
			open_control();
			continue;
		}
		tune_local(client);
		for (;;) {
			uint32_t size = 0;
			if (!read_all(client, &size, 4) || size > (1u << 20)) break;
			std::string request(size, '\0');
			if (!read_all(client, &request[0], size)) break;
			std::vector<std::string> fields;
			size_t from = 0;
			for (size_t tab; (tab = request.find('\t', from)) != std::string::npos; from = tab + 1) fields.push_back(request.substr(from, tab - from));
			fields.push_back(request.substr(from));
			if (fields.size() < 2 || fields[0] != token) break;
			fields.erase(fields.begin());
			std::string answer = call(fields);
			uint32_t length = (uint32_t)answer.size();
			if (!write_all(client, std::string((const char *)&length, 4) + answer)) break;
		}
		close(client);
	}
}

// ------------------------------------------------------------ lifecycle

// A short trip out of the app (a message, the control centre) keeps the node
// and its links running for the half minute iOS allows; the game itself is
// frozen meanwhile and the others wait for it (coop_game.gd).
static UIBackgroundTaskIdentifier background = UIBackgroundTaskInvalid;
static NSArray *observers;

static void end_background() {
	if (background == UIBackgroundTaskInvalid) return;
	[UIApplication.sharedApplication endBackgroundTask:background];
	background = UIBackgroundTaskInvalid;
}

void pokewilds_zerotier_init() {
	unsigned char secret[16];
	arc4random_buf(secret, sizeof(secret));
	char hex[33];
	for (int i = 0; i < 16; i++) snprintf(hex + i * 2, 3, "%02x", secret[i]);
	token = hex;
	http = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
	if (!open_control()) {
		NSLog(@"PokeWildsZeroTier: no control port, ONLINE stays on the local network");
		return;
	}
	std::thread(serve).detach();
	NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
	observers = @[
		[center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
			if (!started || background != UIBackgroundTaskInvalid) return;
			background = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ZeroTier" expirationHandler:^{ end_background(); }];
		}],
		[center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
			end_background();
		}],
	];
}

void pokewilds_zerotier_deinit() {
	for (id observer in observers) {
		[NSNotificationCenter.defaultCenter removeObserver:observer];
	}
	observers = nil;
	end_background();
}

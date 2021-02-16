@safe:

import vibe.vibe;
import vibe.core.sync;

import std.bitmanip;
import std.range;

import config;

//enum ReverseProxy = true;
enum ReverseProxy = false;
static immutable string ANY_HOST = "wants.pet";

struct Database
{
	static immutable DB_PATH = "clicks_db.bin";

	struct Entry
	{
		ulong clicks;
		long createDate;
		long lastClickDate;
	}

	bool dirty;
	MonoTime lastSave;
	Entry[string] _clicks;
	InterruptibleTaskMutex mutex;

	Entry get(string host)
	{
		if (host.length == 0 || host.length >= 255)
			throw new Exception("Invalid host length");

		with (mutex.scopedMutexLock)
		{
			return _clicks.get(host, Entry.init);
		}
	}

	void incr(string host, int num)
	{
		if (host.length == 0 || host.length >= 255)
			throw new Exception("Invalid host length");

		with (mutex.scopedMutexLock)
		{
			auto now = Clock.currStdTime();
			_clicks.update(host, delegate() { return Entry(num, now, now); }, delegate(
					ref Entry v) { v.clicks += num; v.lastClickDate = now; });
			dirty = true;
		}
	}

	void save()
	{
		if (!dirty)
			return;

		with (mutex.scopedMutexLock)
		{
			if (dirty)
			{
				{
					scope db = openFile(DB_PATH, FileMode.createTrunc);
					db.write([cast(ubyte) 1]); // version

					uint numClicks = cast(uint) _clicks.length;
					db.write(numClicks.nativeToLittleEndian[]);

					foreach (host, clicks; _clicks)
					{
						ubyte hostLength = cast(ubyte) host.length;
						db.write(hostLength.nativeToLittleEndian[]);
						db.write(host);
						db.write(clicks.clicks.nativeToLittleEndian[]);
						db.write(clicks.createDate.nativeToLittleEndian[]);
						db.write(clicks.lastClickDate.nativeToLittleEndian[]);
					}

					dirty = false;
				}
				auto now = MonoTime.currTime;
				if (now - lastSave > 55.minutes)
				{
					copyFile(DB_PATH, DB_PATH ~ '_' ~ Clock.currTime.toISOString);
				}
			}
		}
	}

	static Database load()
	{
		Database ret;
		ret.mutex = new InterruptibleTaskMutex();
		ret.lastSave = MonoTime.currTime;

		if (existsFile(DB_PATH))
		{
			scope db = openFile(DB_PATH, FileMode.read);

			ubyte[256] buffer;

			db.read(buffer[0 .. 1]);
			enforce(buffer[0] == 1, "Database version mismatch");

			db.read(buffer[0 .. 4]);
			uint numClicks = buffer[0 .. 4].littleEndianToNative!uint;
			foreach (i; 0 .. numClicks)
			{
				db.read(buffer[0 .. 1]);
				ubyte nameLen = buffer[0];
				db.read(buffer[0 .. nameLen]);
				string name = cast(string) buffer[0 .. nameLen].idup;
				db.read(buffer[0 .. 3 * 8]);
				ret._clicks[name] = (() @trusted => Entry(
						buffer[].peek!(ulong, Endian.littleEndian)(0),
						buffer[].peek!(long, Endian.littleEndian)(1),
						buffer[].peek!(long, Endian.littleEndian)(2)))();
			}
		}

		return ret;
	}
}

__gshared Database database;

struct Sites
{
	PrivateConfig[] configs;
}

__gshared Sites sites;

void main()
{
	(() @trusted {
		database = Database.load();
		setTimer(10.minutes, &database.save, true);

		sites = deserializeJson!Sites(readFileUTF8("tmpconfig.json"));
	})();

	scope (exit)
	{
		(() @trusted => database.save())();
	}

	auto settings = new HTTPServerSettings;
	settings.port = 3000;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	auto router = new URLRouter();
	router.get("/ws", handleWebSockets(&handleWSClient));
	router.get("/", &index);
	router.get("*", serveStaticFiles("public/"));
	listenHTTP(settings, router);

	runApplication();
}

string makeNonce()
{
	import vibe.crypto.cryptorand;

	auto rng = secureRNG();
	ubyte[20] buf;
	rng.read(buf);
	return Base64URLNoPadding.encode(buf).idup;
}

void index(HTTPServerRequest req, HTTPServerResponse res)
{
	if (req.host == ANY_HOST)
	{
		res.writeBody("TODO: registration, message @WebFreak#0001 on discord or @WebFreak001 on twitter for now for your own petting site");
	}
	else
	{
		auto config = findConfig(req.host).config;
		if (config == typeof(config).init)
		{
			return;
		}
		auto nonce = makeNonce();
		Stats stats;
		res.render!("main.dt", config, req, nonce, stats);
	}
}

version (Posix)
{
	import core.sys.posix.netinet.in_;
	struct IPBan
	{
		ubyte[sockaddr_in6.sizeof] ip;
		ubyte ipLen;
		MonoTime until;
		Duration d;

		bool expired() const
		{
			return MonoTime.currTime >= until;
		}
	}
	IPBan[64] ipBans;

	ubyte[sockaddr_in6.sizeof] getIP(scope const HTTPServerRequest req, out ubyte ipLen) @trusted
	{
		typeof(return) ret;
		auto addr = req.clientAddress;
		static if (ReverseProxy)
		{
			string ip = req.headers.get("X-Forwarded-For", req.headers.get("X-Real-IP", ""));
			if (ip.length)
			{
				import std.algorithm : all;
				if (ip.all!(a => (a >= '0' && a <= '9') || a == '.'))
				{
					ipLen = 4;
					int i = 0;
					foreach (c; ip)
					{
						if (c == '.')
						{
							i++;
							if (i >= 4)
								break; // malformed
							continue;
						}
						else
						{
							int n = c - '0';
							ret[i] *= 10;
							ret[i] += n;
						}
					}
					return ret;
				}
				else
				{
					import core.sys.posix.arpa.inet : inet_pton, AF_INET6;
					inet_pton(AF_INET6, ip.ptr, &ret[0]);
					ipLen = 128 / 8;
					return ret;
				}
			}
		}
		ipLen = cast(ubyte)addr.sockAddrLen;
		ret[0 .. ipLen] = (cast(ubyte*)addr.sockAddr)[0 .. ipLen];
		return ret;
	}

	bool warnRequestIP(scope const HTTPServerRequest req)
	{
		ubyte len;
		auto ip = req.getIP(len);

		size_t free = size_t.max;

		foreach (i, ref ban; ipBans)
		{
			if (ban.ipLen == 0)
			{
				free = i;
			}
			else if (ban.ip[0 .. ban.ipLen] == ip[0 .. len])
			{
				if (ban.expired)
					ban.d = 10.seconds;
				else
				{
					if (ban.d >= 10.seconds && ban.d < 20.seconds)
						logInfo("Banned ip %s", ip[0 .. len]);

					if (ban.d < 10.minutes)
						ban.d *= 2;
				}
				ban.until = MonoTime.currTime + ban.d;
				return true;
			}
			else if (ban.expired)
			{
				free = i;
			}
		}

		if (free == size_t.max)
			return false;

		ipBans[free].ipLen = len;
		ipBans[free].ip = ip;
		ipBans[free].d = 5.seconds;
		ipBans[free].until = MonoTime.currTime + ipBans[free].d;
		return true;
	}

	enum BanState
	{
		none,
		warned,
		banned
	}

	BanState checkRequestIP(scope const HTTPServerRequest req)
	{
		ubyte len;
		auto ip = req.getIP(len);

		foreach (i, ref ban; ipBans)
		{
			if (ban.ipLen && ban.ip[0 .. ban.ipLen] == ip[0 .. len])
			{
				if (ban.expired)
					return BanState.none;
				else if (ban.d >= 20.seconds)
				{
					ban.until = MonoTime.currTime + ban.d;
					return BanState.banned;
				}
				else
					return BanState.warned;
			}
		}

		return BanState.none;
	}
}
else
{
	BanState checkRequestIP(scope const HTTPServerRequest req)
	{
		return BanState.none;
	}

	bool warnRequestIP(scope const HTTPServerRequest req)
	{
		return false;
	}
}

void handleWSClient(scope WebSocket socket)
{
	auto privConfig = findConfig(socket.request.host);
	if (privConfig == typeof(privConfig).init)
	{
		return;
	}

	MonoTime last = MonoTime.currTime - 5.seconds;
	ulong lastValue = ulong.max;

	Duration loopTimeout = 500.msecs;

	void send(ulong value)
	{
		if (lastValue != value)
		{
			loopTimeout = 200.msecs;
			lastValue = value;
			ubyte[8] buf = nativeToLittleEndian(value);
			if (socket.connected)
				socket.send(buf[]);
		}
	}

	int numSent = 0;
	auto state = checkRequestIP(socket.request);
	if (state == BanState.banned)
		return;
	else if (state == BanState.warned)
	{
		sleep(500.msecs);
		if (!socket.connected)
			return;
		if (socket.dataAvailableForRead)
			goto DataReceiver;
	}

	while (true)
	{
		while (socket.connected && !socket.dataAvailableForRead)
		{
			send(privConfig.readClicks());

			if (!socket.connected)
				break;
			socket.waitForData(loopTimeout);
			if (loopTimeout < 500.msecs)
				loopTimeout += 50.msecs;
		}
DataReceiver:
		if (!socket.connected)
			break;
		auto b = socket.receiveBinary();
		auto now = MonoTime.currTime;
		auto dur = now - last;
		if (dur > 5.seconds)
			dur = 5.seconds;
		last = now;
		int n = b.length ? b[0] : 0;
		numSent++;
		if (n > 0 && n * 20.msecs < dur)
		{
			if (numSent == 0 && n > 70)
			{
				warnRequestIP(socket.request);
				if (state == BanState.warned)
				{
					socket.close();
					return;
				}
			}
			privConfig.increment(n);
		}
	}

	if (numSent <= 2)
	{
		warnRequestIP(socket.request);
	}
}

PrivateConfig findConfig(string host) @trusted
{
	if (host.endsWith(chain(".", ANY_HOST)))
	{
		string domain = host[0 .. $ - ".wants.pet".length];

		foreach (ref site; sites.configs)
		{
			// lul linear search
			if (site.namespace == domain)
			{
				return site;
			}
		}
	}
	else
	{
		return sites.configs[0];
	}

	return PrivateConfig.init;
}

ulong readClicks(ref PrivateConfig c) @trusted
{
	return database.get(c.namespace).clicks;
}

void increment(ref PrivateConfig c, int n) @trusted
{
	database.incr(c.namespace, n);
}

struct Stats
{
	int global;
}

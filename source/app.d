@safe:

import vibe.vibe;
import vibe.core.sync;

import std.bitmanip;

import config;

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
		}
	}

	static Database load()
	{
		Database ret;
		ret.mutex = new InterruptibleTaskMutex();

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
		setTimer(10.seconds, &database.save, true);

		sites = deserializeJson!Sites(readFileUTF8("tmpconfig.json"));
	})();

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
			socket.send(buf[]);
		}
	}

	send(privConfig.readClicks());

	while (true)
	{
		while (socket.connected && !socket.dataAvailableForRead)
		{
			send(privConfig.readClicks());

			socket.waitForData(loopTimeout);
			if (loopTimeout < 500.msecs)
				loopTimeout += 50.msecs;
		}
		if (!socket.connected)
			break;
		auto b = socket.receiveBinary();
		auto now = MonoTime.currTime;
		auto dur = now - last;
		if (dur > 5.seconds)
			dur = 5.seconds;
		last = now;
		int n = b.length ? b[0] : 0;
		if (n * 20.msecs < dur)
			privConfig.increment(n);
	}
}

PrivateConfig findConfig(string host) @trusted
{
	if (!host.endsWith(".wants.pet"))
		return PrivateConfig.init;

	string domain = host[0 .. $ - ".wants.pet".length];

	foreach (ref site; sites.configs)
	{
		// lul linear search
		if (site.namespace == domain)
		{
			return site;
		}
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

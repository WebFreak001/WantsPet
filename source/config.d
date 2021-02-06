module config;

@safe:

struct PrivateConfig
{
	string namespace;
	PublicConfig config;
}

struct PublicConfig
{
	string title;
	string titleShort;
	string description;
	string gif;
	string gifAlt;
	string twitterUser;
	Particle[] particles;
	Style style;
	string tweetTeaser;
}

struct Particle
{
	string image;
	int width, height;
}

struct Style
{
	string bg;
	string color;
	string color_hover;
	string color_pressed;
	string font = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif";

	string applyVariables(string code)
	{
		import std.array : replace;

		foreach (i, member; this.tupleof)
		{
			enum ident = "$" ~ __traits(identifier, this.tupleof[i]) ~ "$";
			code = code.replace(ident, member);
		}

		return code;
	}
}
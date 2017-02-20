// dmd -O -inline -unittest -w -m64 -defaultlib=libphobos2.so archlinux-dmd.d

module archlinux_dmd;

import std.stdio : writefln, readf, write;
import std.exception;
import std.file;
import std.path;
import std.string;
import std.conv;
import std.regex;
import std.algorithm;
import std.array;
import std.range;


auto getOption(string name) {
	string s = import("PKGBUILD_copy");
	do {
		auto endofline = s.countUntil('\n');
		if (endofline < 0 || endofline == s.length) {
			break;
		}
		auto line = s[0..endofline];
		if (line.startsWith(name ~"=")) {
			return line.split('=')[1].strip().strip('\'');
		}
		if (endofline>=s.length - 1) break;
		s = s[endofline+1 .. $];
	} while (s.length>0);
	assert(0, "option "~ name ~" not found");
}
string _currentSymlink = () {
	return buildPath(_dlangdir, "current");
}();


enum pkgver = getOption("pkgver");
enum _dlangdir = getOption("_dlangdir");
enum _prefix = getOption("_prefix");
enum D_APPS = ["ddemangle", "dman", "dmd", "dub", "dumpobj", "dustmite", "obj2asm", "rdmd"];
enum SYSTEM_DMD_CONF = "/etc/dmd.conf";
enum BIN_INSTALL_PATH = buildPath(_prefix, "bin");
enum LIB_STARTSWITH = buildPath(_prefix, "lib/libphobos2.so.");


//current=$(basename `readlink $_dlangdir/current`)
struct SemVer {
	int major,minor,patch;
	string pre_release, build;
	static auto fromMatch(Captures!(string, ulong) match) {
		SemVer ret;
		with (ret) {
			major = match["major"].to!int;
			minor = match["minor"].to!int;
			patch = match["patch"].to!int;
			pre_release = match["pre_release"];
			build = match["build"];
		}
		return ret;
	}
	int opCmp(inout typeof(this) s) const {
		if (major == s.major) {
			if (minor == s.minor) {
				return patch - s.patch;
			}
			return minor - s.minor;
		}
		return major - s.major;
	}

	string toString() const {
		import std.format;
		return "%d.0%d.%d%-(-%s%)%-(+%s%)".format(
			major,
			minor,
			patch,
			pre_release!="" ? [pre_release] : null,
			build!="" ? [build] : null);
	}
}
unittest {
	assert(SemVer(0,1,2)<SemVer(0,1,3));
	assert(SemVer(0,1,2)<=SemVer(0,1,3));
	assert(SemVer(1,1,2)>SemVer(0,1,3));
	assert(SemVer(1,1,2)>=SemVer(0,1,3));
	assert(SemVer(1,1,2)<=SemVer(1,1,2));
	assert(SemVer(1,1,2)>=SemVer(1,1,2));
	assert(SemVer(1,1,2)==SemVer(1,1,2));
}

auto sortSemVer(R)(R items) {
	auto r = regex(`\b(?P<major>[0-9]+)\.(?P<minor>[0-9]+)\.(?P<patch>[0-9]+)(-(?P<pre_release>.*))?(\+(?P<build>.*))?`);

	SemVer[] versions;
	foreach (item; items) {
		auto match = item.matchFirst(r);
		if (match.empty) {
			continue;
		}
		versions ~= SemVer.fromMatch(match);
	}

	string[] ret;
	foreach (item; sort(versions).array.retro) {
		ret ~= item.to!string;
	}
	return ret;
}

auto list_options() {
	import std.file;
	import std.path;
	import std.algorithm;

	debug writefln("getting directories in: %s", _dlangdir);
	auto options = std.file.dirEntries(_dlangdir, SpanMode.shallow)
		.filter!(a => a.isDir)
		.map!(a => std.path.baseName(a.name))
		.sortSemVer;

	string current;
	if (_currentSymlink.exists()) {
		current = baseName(readLink(_currentSymlink));
	}
	foreach (i, d; options) {
		if (d == "current") {
			continue;
		}
		if (current == d) {
			if (d == pkgver) {
				writefln("  [%d] %s (default) - recommended", i, d);
			} else {
				writefln("  [%d] %s (default)", i, d);
			}
		} else if (d == pkgver) {
			writefln("  [%d] %s (recommended)", i, d);
		} else {
			writefln("  [%d] %s", i, d);
		}
	}
	return options;
}

auto set_option(bool testMode) {
	import std.process;

	auto userid = executeShell("id -u");
	if (!testMode && userid.output.strip.to!int != 0) {
		writefln("must be root to select default dmd");
		return;
	}

	auto options = list_options();
	write("select default dmd: ");
	int v;
	try {
		auto r = readf("%d", &v);
		
	
		enforce!Exception(v < options.length);
	} catch (Exception e) {
		writefln("expected number between 0 and %d", options.length - 1);
		return;
	}
	createLinks(options[v], testMode);
}

enum sofilenameAbsoluteTargetString = q{auto sofilenameAbsoluteTarget = buildPath("/usr/local/lib", baseName(sofilename));};
bool managedByArchlinuxDmd(bool testMode) {
	foreach (file; D_APPS) {
		auto filepath = buildPath(BIN_INSTALL_PATH, file);
		if (filepath.exists) {
			if (!isSymlink(filepath) || !readLink(filepath).endsWith("current/bin/"~ file)) {
				writefln("unmanaged: %s", filepath);
				return false;
			} else if (testMode) {
				writefln("managed: %s", filepath);
			}
		} else if (testMode) {
			writefln("missing: %s", filepath);
		}
	}
	return true;
}

void createLinks(string option, bool testMode) {
	if (!managedByArchlinuxDmd(testMode)) {
		writefln("dmd installation not managed by archlinux-dmd");
		return;
	}
	auto newPath = buildPath([_dlangdir, option]);
	if (_currentSymlink.exists && readLink(_currentSymlink) == newPath) {
		writefln("%s -> %s already configured", _currentSymlink, newPath);
		return;
	}

	auto current = "";
	if (_currentSymlink.exists && _currentSymlink.isSymlink) {
		current = readLink(_currentSymlink);
	}
	if (_currentSymlink.exists) {
		if (testMode) {
			writefln("remove: %s", _currentSymlink);
		} else {
			remove(_currentSymlink);
		}
	} else if (testMode) {
		writefln("enable archlinux-dmd");
	}

	if (testMode) {
		writefln("symlink %s -> %s", _currentSymlink, newPath);
	} else {
		symlink(newPath, _currentSymlink);
		writefln("changing default dmd to: %s", baseName(readLink(_currentSymlink)));
	}
	// application symlinks
	foreach (file; D_APPS) {
		auto filepath = buildPath(BIN_INSTALL_PATH, file);
		assert(!filepath.exists || (filepath.exists && isSymlink(filepath)), "fail %s/%s".format(_bin_prefix, file));
		if (filepath.exists) {
			assert(isSymlink(filepath));
			if (testMode) {
				writefln("managed: %s", filepath);
			}
		} else if (!testMode) {
			symlink(buildPath(_dlangdir, "current/bin", file), filepath);
		}
	}


	// at this point we know they are symlinks
	// cleanup old library links
	foreach (i, sofilename; enumerate(std.file.dirEntries(buildPath("/usr/local/lib"), SpanMode.shallow)
		.filter!(sofilename => isSymlink(sofilename.name) && sofilename.name.startsWith(LIB_STARTSWITH))))
	{
		assert(i<3, "trying to remove more than three symlinks %s".format(sofilename));
		assert(!sofilename.exists || (isSymlink(sofilename.name) && readLink(sofilename.name).startsWith(buildPath(current, "lib/libphobos2.so."))), "warning: %s is not managed by archlinux-dmd".format(sofilename.name));
		if (testMode) {
			writefln("remove: %s", sofilename);
		} else {
			sofilename.remove();
		}
	}

	string defaultlib;
	foreach (sofilename; std.file.dirEntries(buildPath(newPath, "lib"), SpanMode.shallow).filter!(f => f.name.canFind("libphobos2.so"))) {
		mixin(sofilenameAbsoluteTargetString);
		if (testMode) {
			writefln("create symlink: %s", sofilenameAbsoluteTarget);
		} else {
			symlink(buildPath(_dlangdir, "current/lib", sofilename), sofilenameAbsoluteTarget);
		}
		defaultlib = sofilenameAbsoluteTarget;
	}
}

void main(string[] args) {
	string cmd;
	bool testMode;
	if (args.length > 1) {
		foreach (arg; args[1..$]) {
			switch (arg) {
				case "-t":
					testMode = true;
					break;
				default:
					cmd = arg;
			}
		}
	} else {
		cmd = "status";
	}
	switch (cmd) {
		case "status":
			writefln("installed dmd versions:");
			list_options();
			return;
		case "set":
			set_option(testMode);
			return;
		default:
			// testMode without "set"
			if (testMode) {
				managedByArchlinuxDmd(testMode);
				return;
			}
			writefln("Usage: %s [-t] [status|set]", baseName(args[0]));
			return;
	}
}

// dmd -O -inline -unittest -w -m64 -defaultlib=libphobos2.so archlinux-dmd.d

module archlinux_dmd;

import std.stdio : writefln, readf;
import std.exception;
import std.file;
import std.path;

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
	assert(0, "option"~ name ~" not found");
}
string _currentSymlink = () {
	return buildPath(_dlangdir, "current");
}();


enum pkgver = getOption("pkgver");
enum _dmdver = getOption("_dmdver");
enum _pkgver_lib_patch = getOption("_pkgver_lib_patch");
enum _pkgver_lib_minor = getOption("_pkgver_lib_minor");
enum _dlangdir = getOption("_dlangdir");

import std.string;
import std.conv;
import std.regex;
import std.algorithm;
import std.array;
import std.range;

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
			writefln("  [%d] %s (default)", i, d);
		} else {
			writefln("  [%d] %s", i, d);
		}
	}
	return options;
}

auto set_option() {
	import std.process;

	auto userid = executeShell("id -u");
	if (userid.output.strip.to!int != 0) {
		writefln("must be root to select default dmd");
		return;
	}

	auto options = list_options();
	writefln("select default dmd:");
	int v;
	try {
		auto r = readf("%d", &v);
		
	
		enforce!Exception(v < options.length);
	} catch (Exception e) {
		writefln("expected number between 0 and %d", options.length - 1);
		return;
	}
	createLinks(options[v]);
}

void createLinks(string option) {
	if (_currentSymlink.exists) {
		remove(_currentSymlink);
	}
	symlink(buildPath([_dlangdir, option]) , _currentSymlink);
	writefln("default dmd: %s", baseName(readLink(_currentSymlink)));

	// application symlinks
	foreach (file; ["ddemangle", "dman", "dmd", "dub", "dumpobj", "dustmite", "obj2asm", "rdmd"]) {
		auto filepath = buildPath("/usr/bin/", file);
		if (filepath.exists) {
			if (!isSymlink(filepath)) {
				writefln("failed selecting default, not a symlink: %s", file);
				continue;
			}
			filepath.remove();
		}
		symlink(buildPath(_dlangdir, "current", file), filepath);
	}
	//ln -s $_dlangdir/current/lib/libphobos2.so.$_pkgver_lib_patch $pkgdir/usr/lib/libphobos2.so
	enum sofilename = "libphobos2.so."~ _pkgver_lib_patch;
	enum sofilenameAbsoluteTarget = "/usr/lib/libphobos2.so."~ _pkgver_lib_patch;
	auto defaultSoOkay = !"/usr/lib/libphobos2.so".exists || isSymlink("/usr/lib/libphobos2.so");
	auto versionedSoOkay = !sofilenameAbsoluteTarget.exists || isSymlink("/usr/lib/"~ sofilename);
	if (!versionedSoOkay || !defaultSoOkay) {
		writefln("failed selecting default, not symlinks: /usr/lib/%s, /usr/lib/libphobos2.so", sofilename);
		return;
	}

	// at this point we know they are symlinks
	if (sofilenameAbsoluteTarget.exists) {
		sofilenameAbsoluteTarget.remove();
	}
	if ("/usr/lib/libphobos2.so".exists) {
		"/usr/lib/libphobos2.so".remove();
	}

	symlink(buildPath(_dlangdir, "current/lib", sofilename), sofilenameAbsoluteTarget);
	symlink(buildPath(_dlangdir, "current/lib", sofilename), "/usr/lib/libphobos2.so");

	if ("/etc/dmd.conf".exists) {
		if (!isSymlink("/etc/dmd.conf")) {
			writefln("failed selecting default, not a symlink: /etc/dmd.conf");
			return;
		}
		"/etc/dmd.conf".remove();
	}
	symlink(buildPath(_dlangdir, "current/bin/dmd.conf"), "/etc/dmd.conf");
}

void main(string[] args) {
	string cmd;
	if (args.length > 1) {
		cmd = args[1];
	} else {
		cmd = "status";
	}
	switch (cmd) {
		case "status":
			writefln("installed dmd versions:");
			list_options();
			return;
		case "set":
			set_option();
			return;
		default:
			writefln("Usage: %s [status|set]", baseName(args[0]));
			return;
	}
}

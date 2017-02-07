// dmd -O -inline -unittest -w -m64 -defaultlib=libphobos2.so archlinux-dmd.d

module archlinux_dmd;
import archlinux_dmd_config;


import std.stdio : writefln, readf;
import std.exception;
import std.file;

enum CURRENT_SYMLINK=DMD_DIR~"/current";

import std.string;
import std.conv;
import std.regex;
import std.algorithm;
import std.array;

//current=$(basename `readlink $DMD_DIR/current`)
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
	foreach (item; sort(versions).array.reverse) {
		ret ~= item.to!string;
	}
	return ret;
}

auto list_options() {
    import std.file;
    import std.path;
    import std.algorithm;

    auto options = std.file.dirEntries(DMD_DIR, SpanMode.shallow)
        .filter!(a => a.isDir)
        .map!(a => std.path.baseName(a.name))
        .sortSemVer;

	foreach (i, d; options) {
		if (d == "current") {
			continue;
		}
		auto current = baseName(readLink(CURRENT_SYMLINK));
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
	import std.path;

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
	if (CURRENT_SYMLINK.exists) {
		remove(CURRENT_SYMLINK);
	}
	symlink(buildPath([DMD_DIR, options[v]]) , CURRENT_SYMLINK);
	writefln("default dmd: %s", baseName(readLink(CURRENT_SYMLINK)));
}

void main(string[] args) {
	if (args.length <= 1) {
		list_options();
		return;
	}
	switch (args[1]) {
		case "status":
			goto case;
		case "list":
			list_options();
			return;
		case "set":
			set_option();
			return;
		default:
			writefln("Usage: %s [list]", args[0]);
			return;
	}
}

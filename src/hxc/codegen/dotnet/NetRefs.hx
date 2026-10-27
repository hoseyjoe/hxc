package hxc.codegen.dotnet;

import sys.FileSystem;
import hxc.context.Context;
import hxc.codegen.dotnet.IlData;

// The assembly that defines a .NET type, for lowering: a loaded library (ctx.netLibs) first, then the
// assemblies the --net-libs reference, transitively and breadth first, each found beside the file that
// references it or else in the .NET reference pack, following type forwarders; and last, for a
// hand-written extern that no assembly references, the reference pack's own types. The assemblies read
// here are reference-only (NetLibrary.refOnly): Haxe 4.3.7's loader never follows references, so typing
// must not see them.
class NetRefs {
	final ctx:Context;
	// the files read, by path; null when one is not an assembly
	final byFile = new Map<String, Null<NetLibrary>>();
	// the assembly a reference names from a directory, keyed by "<dir>\n<lower-case name>"
	final located = new Map<String, Null<NetLibrary>>();
	// definer's answers, by IlPaths.key
	final found = new Map<String, Null<NetLibrary>>();
	// for a type not found, by IlPaths.key: the missing references that could have defined it
	final unresolved = new Map<String, Array<String>>();
	var packSearched = false;
	var pack:Null<String> = null;
	// the reference pack's top-level types (IlPaths.key) and the first file, by name, defining each
	var packIndex:Null<Map<String, String>> = null;

	public static function of(ctx:Context):NetRefs {
		if (ctx.netRefs == null) ctx.netRefs = new NetRefs(ctx);
		return ctx.netRefs;
	}

	function new(ctx:Context) {
		this.ctx = ctx;
	}

	public function definer(path:IlPath):Null<NetLibrary> {
		for (lib in ctx.netLibs) if (lib.definesType(path)) return lib;
		var key = IlPaths.key(path);
		if (found.exists(key)) return found.get(key);
		var notes:Array<String> = [];
		var r = search(path, notes);
		found.set(key, r);
		if (r == null) unresolved.set(key, notes);
		return r;
	}

	// Why no assembly defines `path`: the reference pack was needed and is not installed, or nothing
	// defines it, naming the references that are missing where one could have.
	public function missing(path:IlPath):String {
		var s = NetConverter.ilpathS(path);
		if (definer(path) != null) throw "internal error: " + s + " is defined";
		if (referencePack() == null)
			return "the .NET " + NetSetup.dotnetVersion(ctx) + " reference pack (Microsoft.NETCore.App.Ref) was not found; it is needed for " + s;
		var notes = unresolved.get(IlPaths.key(path));
		var why = notes == null || notes.length == 0 ? "" : " (" + notes.join("; ") + ")";
		return "no referenced assembly defines the .NET type " + s + why;
	}

	function referencePack():Null<String> {
		if (!packSearched) {
			packSearched = true;
			pack = NetSetup.referencePack(ctx);
		}
		return pack;
	}

	static function dirOf(file:String):String {
		var s = file.split("\\").join("/");
		var i = s.lastIndexOf("/");
		return i < 0 ? "." : i == 0 ? "/" : s.substr(0, i);
	}

	static function fileName(file:String):String {
		var s = file.split("\\").join("/");
		return s.substr(s.lastIndexOf("/") + 1);
	}

	function read(file:String):Null<NetLibrary> {
		if (byFile.exists(file)) return byFile.get(file);
		var lib = new NetLibrary(ctx, file, file, false);
		lib.refOnly = true;
		// a file that is not an assembly (a native DLL) does not define the reference
		var ok = try {
			lib.load();
			true;
		} catch (_:Dynamic) false;
		byFile.set(file, ok ? lib : null);
		return ok ? lib : null;
	}

	// The assembly a reference from a file in `dir` names: a loaded library of that name, else the file
	// beside the referencing one, else the reference pack's.
	function locate(name:String, dir:String):Null<NetLibrary> {
		var lower = name.toLowerCase();
		var key = dir + "\n" + lower;
		if (located.exists(key)) return located.get(key);
		var r:Null<NetLibrary> = null;
		for (lib in ctx.netLibs) if (fileName(lib.filePath).toLowerCase() == lower + ".dll") {
			r = lib;
			break;
		}
		if (r == null) {
			var cands = [dir + "/" + name + ".dll"];
			var rp = referencePack();
			if (rp != null && rp != dir) cands.push(rp + "/" + name + ".dll");
			for (c in cands) if (FileSystem.exists(c) && !FileSystem.isDirectory(c)) {
				r = read(c);
				if (r != null) break;
			}
		}
		located.set(key, r);
		return r;
	}

	function notFound(referrer:NetLibrary, verb:String, name:String):String {
		return fileName(referrer.filePath) + " " + verb + " " + name + ", which is neither beside it nor in the reference pack";
	}

	// `lib`, if it defines `path`, else the assembly its forwarders send `path` to.
	function resolveIn(lib:NetLibrary, path:IlPath, notes:Array<String>, depth:Int):Null<NetLibrary> {
		if (lib.definesType(path)) return lib;
		if (depth > 8) return null;
		var to = lib.forwarderTarget(path);
		if (to == null) return null;
		var next = locate(to, dirOf(lib.filePath));
		if (next == null) {
			var note = notFound(lib, "forwards it to", to);
			if (notes.indexOf(note) < 0) notes.push(note);
			return null;
		}
		return resolveIn(next, path, notes, depth + 1);
	}

	// Whether an assembly named `name` might define a type of namespace `ns`, by the usual naming of
	// assemblies after the namespaces they hold.
	static function namedFor(name:String, ns:Array<String>):Bool {
		var n = ns.join(".");
		return n != "" && (name == n || StringTools.startsWith(name, n + ".") || StringTools.startsWith(n, name + "."));
	}

	function search(path:IlPath, notes:Array<String>):Null<NetLibrary> {
		// the --net-libs (not the --net-std directories' libraries), then what they reference
		var queue = [for (lib in ctx.netLibs) if (ctx.netStdFiles.indexOf(lib.filePath) < 0) lib];
		var queued = new Map<String, Bool>();
		for (lib in queue) queued.set(lib.filePath, true);
		var i = 0;
		while (i < queue.length) {
			var lib = queue[i++];
			var r = resolveIn(lib, path, notes, 0);
			if (r != null) return r;
			var dir = dirOf(lib.filePath);
			for (name in lib.assemblyRefs()) {
				var dep = locate(name, dir);
				if (dep == null) {
					var note = notFound(lib, "references", name);
					if (namedFor(name, path.ns) && notes.indexOf(note) < 0) notes.push(note);
				} else if (!queued.exists(dep.filePath)) {
					queued.set(dep.filePath, true);
					queue.push(dep);
				}
			}
		}
		// a hand-written extern that no assembly references
		var top:IlPath = path.nested.length > 0 ? {ns: path.ns, nested: [], name: path.nested[0]} : path;
		var file = indexPack().get(IlPaths.key(top));
		if (file == null) return null;
		var lib = read(file);
		return lib != null && lib.definesType(path) ? lib : null;
	}

	// Reads every assembly of the reference pack once, keeping only which file defines each top-level
	// type; files are read in name order, so the first definer is the same on every machine.
	function indexPack():Map<String, String> {
		if (packIndex != null) return packIndex;
		packIndex = new Map();
		var rp = referencePack();
		if (rp == null) return packIndex;
		var files = [for (f in FileSystem.readDirectory(rp)) if (StringTools.endsWith(f.toLowerCase(), ".dll")) f];
		files.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (f in files) {
			var file = rp + "/" + f;
			var lib = byFile.exists(file) ? byFile.get(file) : {
				var l = new NetLibrary(ctx, file, file, false);
				l.refOnly = true;
				try {
					l.load();
					l;
				} catch (_:Dynamic) null;
			}
			if (lib == null) continue;
			for (p in lib.topLevelTypes()) {
				var key = IlPaths.key(p);
				if (!packIndex.exists(key)) packIndex.set(key, file);
			}
		}
		return packIndex;
	}
}

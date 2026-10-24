package hxc.codegen.dotnet;

import sys.FileSystem;
import hxc.context.Context;
import hxc.context.ModuleLoader;

class NetSetup {
	// Defines the .NET version and target, then locates the std directories that match them and
	// collects their DLLs into ctx.netStdFiles.
	public static function beforeGenerate(ctx:Context):Void {
		var defines = ctx.defines;
		var netcoreVer:Null<String> = defines.rawDefined("netcore_ver") ? defines.rawDefinedValue("netcore_ver") : null;

		var netVer:Int;
		if (defines.rawDefined("net_ver")) {
			var s = defines.rawDefinedValue("net_ver");
			var v = parseInt(s);
			if (v == null) throw "Invalid value for -D net-ver. Expected format: xx (e.g. 20, 35, 40, 45, 50)";
			netVer = v;
		} else if (netcoreVer != null) {
			// 4.7 was released around .NET core 2.1
			defines.rawDefineValue("net_ver", "47");
			netVer = 47;
		} else {
			defines.rawDefineValue("net_ver", "20");
			netVer = 20;
		}
		if (netVer < 20)
			throw ".NET version is defined to target .NET " + netVer
				+ ", but the compiler can only output code to versions equal or superior to .NET 2.0 (defined as 20)";
		for (v in [20, 21, 30, 35, 40, 45, 50]) {
			if (v > netVer) break;
			defines.rawDefine("NET_" + v);
		}

		var netTarget = defines.rawDefined("net_target") ? defines.rawDefinedValue("net_target").toLowerCase() : "net";
		defines.rawDefineValue("net_target", netTarget);
		defines.rawDefine(netTarget);

		// every std directory holding the digraph NET_TARGET-NET_VER
		var digraph = if (netTarget == "netcore") {
			if (netcoreVer == null) throw ".NET target is defined as netcore but -D netcore-ver is missing";
			netTarget + "-" + netcoreVer;
		} else
			netTarget + "-" + netVer;
		// the reference conses both com.net_std and its matches, so the two reversals cancel and the
		// directories are read in command-line order
		var matched = [];
		var stds = ctx.netStd.length == 0 ? ["netlib"] : ctx.netStd;
		for (std in stds) {
			var dir = ModuleLoader.findFileOpt(ctx, std + "/" + digraph);
			if (dir != null && FileSystem.exists(dir) && FileSystem.isDirectory(dir)) matched.push(dir);
		}
		if (matched.length == 0)
			throw "No .NET std lib directory with the pattern '" + digraph + "' was found in the -net-std search path. "
				+ "Try updating the hxcs lib to the latest version, or specifying another -net-std path.";
		for (dir in matched)
			for (f in FileSystem.readDirectory(dir))
				if (StringTools.endsWith(f.toLowerCase(), ".dll")) ctx.netStdFiles.push(dir + "/" + f);
		// each std library is read as soon as it is found
		for (f in ctx.netStdFiles) addNetLib(ctx, f, true, false).load();
	}

	// Registers the library: it is looked up by Haxe path after every library added before it, and
	// its types are built by the first extern loader that has them. The caller reads it with load().
	public static function addNetLib(ctx:Context, file:String, isStd:Bool, isExtern:Bool):NetLibrary {
		var realFile = if (FileSystem.exists(file)) file else {
			var f = ModuleLoader.findFileOpt(ctx, file);
			if (f == null) f = ModuleLoader.findFileOpt(ctx, file + ".dll");
			if (f == null) throw ".NET lib " + file + " not found";
			f;
		}
		var lib = new NetLibrary(ctx, file, realFile, isStd);
		lib.isExtern = isExtern;
		ctx.netLibs.push(lib);
		ctx.loadExternType.push({
			name: realFile,
			load: function(path:hxc.core.Globals.Path, p:hxc.ast.Position) return lib.build(path, p)
		});
		return lib;
	}

	// OCaml's int_of_string for a decimal value: an optional sign and digits only.
	public static function parseInt(s:String):Null<Int> {
		var start = s.length > 0 && (s.charAt(0) == "-" || s.charAt(0) == "+") ? 1 : 0;
		if (s.length == start) return null;
		for (i in start...s.length) {
			var c = s.charCodeAt(i);
			if (c < "0".code || c > "9".code) return null;
		}
		return Std.parseInt(s);
	}
}
